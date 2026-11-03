import Foundation
import QuartzCore

// Learns word timings while the lyrics window is open and "listen = on": AudioListener hears Spotify,
// LyricsAligner (LyricsSync.swift) lines the words up with the lyrics, the results are cached per song.

// MARK: - Cache

enum TimingCache {
    private static let folder = cacheDir.appendingPathComponent("lyrics")
    private static func file(_ track: String) -> URL {
        folder.appendingPathComponent(track.replacingOccurrences(of: #"[^\w-]"#, with: "_", options: .regularExpression) + ".timing.json")
    }

    /// Timings for these lyrics, if they were learned for exactly these lines
    static func load(_ track: String, lines: [Line]) -> WordTimings? {
        guard let data = try? Data(contentsOf: file(track)), let timings = try? JSONDecoder().decode(WordTimings.self, from: data),
              timings.version == WordTimings.currentVersion, timings.signature == WordTimings.signature(of: lines),
              timings.words.count == lines.count else { return nil }
        return timings
    }

    static func save(_ timings: WordTimings, _ track: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(timings).write(to: file(track), options: .atomic)
    }
}

// MARK: - Learning while listening

/// Listens while the lyrics window is open, and turns what it hears into word timings, song by song.
/// Lives on after the window closes: the last words come in up to ~20 s late. Main thread only.
final class LyricsLearner {
    static let shared = LyricsLearner()
    /// "listen = on" in config.txt
    var enabled = false { didSet { if !enabled { stopListening() } } }
    /// New timings for a track (and how far LRCLIB's lines are from what was heard), for the lyrics window
    var onUpdate: (String, WordTimings, Double) -> Void = { _, _, _ in }
    /// Plain lyrics now timed by listening, for the lyrics window
    var onLearned: (String, [Line]) -> Void = { _, _ in }
    /// Tests only: everything heard so far, song by song
    var onHeard: ((String, [HeardWord]) -> Void)?
    /// Songs with plain lyrics only: their lines and length, to time them once heard
    private var plainSongs: [String: (texts: [String], plain: String, duration: Double)] = [:]

    private struct Sample { let host: Double; let position: Double; let playing: Bool; let track: String }
    /// Where Spotify was, when: to place each heard word in its song
    private var history: [Sample] = []
    private var heard: [String: [HeardWord]] = [:]
    private var lyrics: [String: [Line]] = [:]
    private var aligned: [String: Int] = [:]
    private var timer: Timer?
    private var listener: AnyObject?
    private var listenerLocale: String?
    private var current: String?
    private var locales: [String: Locale] = [:]
    private var warnedVersion = false
    private var lastWord = 0.0

    /// After this many complete listens, a song is known: Crate stops listening to it
    private let listensNeeded = 2

    /// Spotify's position, as the lyrics window polls it
    func record(track: String, position: Double, playing: Bool, at host: Double) {
        history.append(Sample(host: host, position: position, playing: playing, track: track))
        if history.count > 3000 { history.removeFirst(1000) }
    }

    /// The song playing and its lyrics (synced, or plain only): listen to it if it's still worth it
    func follow(track: String?, lines: [Line]?, plain: String? = nil, duration: Double = 0, playing: Bool) {
        if let track, current != track { restarted(track) }
        current = track
        var lines = lines
        if lines == nil, let track, let plain, duration > 30 {
            // Only plain lyrics: listening to the whole song may time them
            let texts = LyricsAligner.plainLines(plain)
            if texts.count >= 4 {
                plainSongs[track] = (texts, plain, duration)
                lines = texts.map { Line(t: 0, text: $0) }
            }
        }
        guard enabled, let track, let lines, !lines.isEmpty, playing else { return stopListening(keepTimer: true) }
        if plainSongs[track] == nil { lyrics[track] = lines }
        if let timings = TimingCache.load(track, lines: lines), timings.listens >= listensNeeded { return stopListening(keepTimer: true) }
        guard #available(macOS 26, *) else {
            if !warnedVersion {
                warnedVersion = true
                Toast.show(L("Listening to time the lyrics needs macOS 26", "L'écoute pour caler les paroles demande macOS 26"), symbol: "waveform")
            }
            return
        }
        startTimer()
        Task { @MainActor in
            let locale: Locale?
            if let known = self.locales[track] { locale = known } else { locale = await AudioListener.locale(for: lines); self.locales[track] = locale }
            guard self.current == track, self.enabled else { return }
            guard let locale else { return self.stopListening(keepTimer: true) }   // a language macOS doesn't recognize
            if self.listenerLocale == locale.identifier, self.listener != nil { return }
            self.stopListening(keepTimer: true)
            let listener = AudioListener(locale: locale)
            listener.onWords = { [weak self] words in self?.place(words) }
            listener.onSilence = { Spotify.warnIfSilent() }
            self.listener = listener
            self.listenerLocale = locale.identifier
            if await !listener.start() {
                if self.listener === listener { self.listener = nil; self.listenerLocale = nil }
            }
        }
    }

    /// The lyrics window closed: stop listening, but keep lining up the words still coming
    func stopListening(keepTimer: Bool = true) {
        if #available(macOS 26, *) { (listener as? AudioListener)?.stop() }
        listener = nil
        listenerLocale = nil
        if !keepTimer { timer?.invalidate(); timer = nil }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 6, repeats: true) { [weak self] _ in self?.alignAll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Each heard word goes to the song that was playing then, at its position in it
    private func place(_ words: [TimedWord]) {
        lastWord = CACurrentMediaTime()
        for word in words {
            guard let start = songTime(word.start), let end = songTime(word.end), start.track == end.track,
                  end.position >= start.position, end.position - start.position < 3 else { continue }
            heard[start.track, default: []].append(HeardWord(text: word.text, start: start.position - captureLead, end: end.position - captureLead))
        }
    }

    /// How much earlier Spotify's position runs than the audio it hands to macOS (measured on a MacBook Pro)
    private let captureLead = 0.0

    private func songTime(_ host: Double) -> (track: String, position: Double)? {
        guard let i = history.lastIndex(where: { $0.host <= host }) else { return nil }
        let sample = history[i]
        let gap = host - sample.host
        guard gap < 4 else { return nil }   // too far from a known position
        return (sample.track, sample.position + (sample.playing ? gap : 0))
    }

    /// Lines up what's new, song by song, and keeps the results
    private func alignAll() {
        if let onHeard { heard.forEach(onHeard) }
        // Plain lyrics: once most of the song has been heard, try to time every line
        for (track, song) in plainSongs {
            guard let words = heard[track], words.count != aligned[track], let last = words.map(\.end).max(), last > 0.8 * song.duration else { continue }
            aligned[track] = words.count
            guard let lines = LyricsAligner.alignPlain(song.texts, heard: words, duration: song.duration) else { continue }
            log("Listen: timed the plain lyrics of \(track)")
            LRCLib.saveLearned(lines, plain: song.plain, for: track)
            plainSongs[track] = nil
            lyrics[track] = lines
            heard[track] = nil
            aligned[track] = nil
            onLearned(track, lines)
        }
        for (track, words) in heard where words.count != aligned[track] && plainSongs[track] == nil {
            guard let lines = lyrics[track] else { continue }
            aligned[track] = words.count
            guard let result = LyricsAligner.align(lines, heard: words), result.reliable else { continue }
            var timings = LyricsAligner.merge(TimingCache.load(track, lines: lines), result, lines: lines)
            // A listen counts once most of the song has been heard
            if Double(result.linesHeard) >= 0.8 * Double(lines.filter { !$0.text.isEmpty }.count), !timings.counted.contains(listenID(track)) {
                timings.listens += 1
                timings.counted.append(listenID(track))
            }
            TimingCache.save(timings, track)
            onUpdate(track, timings, result.offset)
        }
        // Words of songs over a while ago won't change any more
        if heard.count > 6, let old = heard.keys.first(where: { $0 != current }) { heard[old] = nil; aligned[old] = nil }
        // Not listening any more and no late word for a minute: nothing left to do
        if listener == nil && CACurrentMediaTime() - lastWord > 60 { timer?.invalidate(); timer = nil }
    }

    /// One id per time a song is played, so a listen is counted once
    private var playIDs: [String: String] = [:]
    private func listenID(_ track: String) -> String {
        if let id = playIDs[track] { return id }
        let id = UUID().uuidString.prefix(8).description
        playIDs[track] = id
        return id
    }

    /// The song starts again from the top (or is played again later): a new listen
    func restarted(_ track: String) {
        playIDs[track] = nil
        heard[track] = nil
        aligned[track] = nil
    }
}
