import AppKit
import SwiftUI

// Lyrics window for the track playing in Spotify, synced karaoke-style.
// Lyrics come from LRCLIB (free, open database) and are cached in ~/Library/Caches/Crate/lyrics.
// Floats above other windows without stealing focus; click a line to jump there in the song.
// The button left of × shrinks it to a small strip with just the current line (karaoke, word by word) and the next one
// (remembered between openings). The buttons show when the mouse is over the window, or stay on the strip's right (config).
// It opens at its header's height and unrolls downward, and rolls back up when closed.

let fullSize = NSSize(width: 400, height: 560)
let compactSize = NSSize(width: 400, height: 108)
/// Margin around the window's content: cover, lyrics and buttons line up on it
private let inset: CGFloat = 20

struct Line: Codable {
    let t: Double
    let text: String
}

struct Lyrics: Codable {
    var synced: [Line]?
    let plain: String?
    let instrumental: Bool
    /// The lines were timed by Crate, listening to the song (LRCLIB only had the plain lyrics)
    var learned: Bool?
    /// When it was looked up: "not found" answers are retried after a few days
    var fetchedAt: Double = Date().timeIntervalSince1970
    var found: Bool { synced != nil || plain != nil || instrumental }
}

enum LRCLib {
    private static let folder = cacheDir.appendingPathComponent("lyrics")

    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?
        let duration: Double?
        var useful: Bool { syncedLyrics != nil || plainLyrics != nil || instrumental == true }
    }

    /// Lyrics for a track, from the cache or LRCLIB. nil if LRCLIB couldn't be reached.
    static func lyrics(for track: NowPlaying) async -> Lyrics? {
        let file = file(track.id)
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Lyrics.self, from: data),
           cached.found || Date().timeIntervalSince1970 - cached.fetchedAt < 3 * 24 * 3600 {
            return cached
        }
        let record: Record?
        do { record = try await find(track) } catch { return nil }
        let result = Lyrics(synced: parseLRC(record?.syncedLyrics), plain: record?.plainLyrics, instrumental: record?.instrumental ?? false)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(result).write(to: file, options: .atomic)
        return result
    }

    private static func request(_ path: String, _ params: [String: String]) async throws -> (Data, Int) {
        var components = URLComponents(string: "https://lrclib.net/api" + path)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Crate (https://github.com/amndrd/crate)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Exact match first, otherwise the best search result; nil if there are none
    private static func find(_ track: NowPlaying) async throws -> Record? {
        let (data, status) = try await request("/get", ["artist_name": track.artist, "track_name": track.name,
                                                        "album_name": track.album, "duration": String(Int(track.duration.rounded()))])
        if status == 200, let record = try? JSONDecoder().decode(Record.self, from: data), record.useful {
            // Only the plain text under this exact title: a synced version may exist under a slightly different one
            if record.syncedLyrics == nil, record.instrumental != true, let synced = try await findSynced(track) { return synced }
            return record
        }
        if status != 200 && status != 404 { throw URLError(.badServerResponse) }
        // Spotify titles like "Song - Remastered 2011" or "Song (feat. X)": search with the plain title
        let short = track.name.range(of: #" - | \((?:feat|with)\b"#, options: .regularExpression).map { String(track.name[..<$0.lowerBound]) } ?? track.name
        let (results, _) = try await request("/search", ["artist_name": track.artist, "track_name": short])
        let records = ((try? JSONDecoder().decode([Record].self, from: results)) ?? []).filter(\.useful)
        // Prefer synced lyrics of a version with the same length, otherwise the closest length
        func gap(_ r: Record) -> Double { abs((r.duration ?? 0) - track.duration) }
        let best = records.min { a, b in
            let ka = (a.syncedLyrics == nil || gap(a) > 5), kb = (b.syncedLyrics == nil || gap(b) > 5)
            return ka != kb ? !ka : gap(a) < gap(b)
        }
        if best?.syncedLyrics != nil { return best }
        return try await findSynced(track) ?? best
    }

    /// Nothing synced yet: once more with the bare title ("Song (feat. X) - Remix 2020" -> "Song"),
    /// then with the title alone and the artist checked. Only for songs that have nothing synced, and cached
    private static func findSynced(_ track: NowPlaying) async throws -> Record? {
        let bare = bareTitle(track.name)
        let artist = LyricsAligner.normalize(track.artist)
        func sameSong(_ r: Record) -> Bool {
            guard r.syncedLyrics != nil, let title = r.trackName, let by = r.artistName else { return false }
            let other = LyricsAligner.normalize(by)
            return LyricsAligner.normalize(bareTitle(title)) == LyricsAligner.normalize(bare)
                && !artist.isEmpty && (other.contains(artist) || artist.contains(other))
        }
        func closest(_ records: [Record]) -> Record? {
            records.filter(sameSong).min { abs(($0.duration ?? 0) - track.duration) < abs(($1.duration ?? 0) - track.duration) }
        }
        for params in [["artist_name": track.artist, "track_name": bare], ["track_name": bare]] {
            let (data, status) = try await request("/search", params)
            guard status == 200 else { return nil }
            if let found = closest((try? JSONDecoder().decode([Record].self, from: data)) ?? []) { return found }
        }
        return nil
    }

    /// Title without what's in brackets, after " - " or after "feat."
    static func bareTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let dash = t.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) { t = String(t[..<dash.lowerBound]) }
        if let feat = t.range(of: #"\s+(feat|ft)\.?\s"#, options: [.regularExpression, .caseInsensitive]) { t = String(t[..<feat.lowerBound]) }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t
    }

    /// Plain lyrics timed by listening: kept like LRCLIB's synced ones
    static func saveLearned(_ lines: [Line], plain: String, for track: String) {
        var lyrics = Lyrics(synced: lines, plain: plain, instrumental: false)
        lyrics.learned = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(lyrics).write(to: file(track), options: .atomic)
    }

    private static func file(_ track: String) -> URL {
        folder.appendingPathComponent(track.replacingOccurrences(of: #"[^\w-]"#, with: "_", options: .regularExpression) + ".json")
    }

    /// "[01:23.45] words" -> [Line(t: 83.45, text: "words")], sorted by time
    static func parseLRC(_ text: String?) -> [Line]? {
        guard let text else { return nil }
        let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var lines: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let words = raw.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            for m in stamp.matches(in: raw, range: range) {
                let minutes = Double(raw[Range(m.range(at: 1), in: raw)!]) ?? 0
                let seconds = Double(raw[Range(m.range(at: 2), in: raw)!]) ?? 0
                lines.append(Line(t: minutes * 60 + seconds, text: words))
            }
        }
        return lines.isEmpty ? nil : lines.sorted { $0.t < $1.t }
    }
}

final class Player: ObservableObject {
    /// false until Spotify has answered once
    @Published var ready = false
    @Published var track: NowPlaying?
    /// nil while the lyrics are being looked up
    @Published var lyrics: Lyrics?
    @Published var cover: NSImage?
    /// Line being sung
    @Published var current: Int?
    /// LRCLIB couldn't be reached: retried a bit later
    @Published var unavailable = false
    /// When each word is sung, learned by listening to Spotify (LyricsSync.swift); nil until then
    @Published var timings: WordTimings?
    /// How far LRCLIB's lines are from the song, measured while listening: moves the lines not timed yet
    @Published var listenOffset = 0.0
    /// This song's own adjustment (← → in the window), in seconds: + shows the lyrics later
    @Published var nudge = 0.0
    /// config.txt "delay": + shows all lyrics later
    var delay = 0.0
    /// config.txt "buttons = column": the strip's buttons stay on its right, instead of showing on hover
    @Published var buttonColumn = false
    /// Time the sound takes to come out of the speakers or headphones (Bluetooth: a lot)
    private var outputLatency = 0.0
    /// Window shrunk to the current and next lines
    @Published var compact = UserDefaults.standard.bool(forKey: "compactLyrics") {
        didSet { UserDefaults.standard.set(compact, forKey: "compactLyrics") }
    }
    /// ♪ button: the line being sung lights up word by word, otherwise all at once
    @Published var wordByWord = UserDefaults.standard.object(forKey: "lyricsWordByWord") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wordByWord, forKey: "lyricsWordByWord") }
    }
    /// Opening: the card shows at its header's height and unrolls down (false → true) while the lyrics come in.
    /// Closing: the reverse
    @Published var unrolled = false
    @Published var contentShown = false

    /// Position (s) reported by Spotify at `syncedAt`: interpolated in between
    private var progress = 0.0
    private var syncedAt = CACurrentMediaTime()
    private var polling = false
    /// Last click on a line: positions asked for before it are stale
    private var seekedAt = 0.0
    private var timers: [Timer] = []
    private var observer: NSObjectProtocol?

    var position: Double {
        progress + (track?.isPlaying == true ? CACurrentMediaTime() - syncedAt : 0)
    }

    /// For screenshots: the window as at `position` in `track`, paused
    func preview(_ track: NowPlaying, lyrics: Lyrics, timings: WordTimings?, at position: Double) {
        self.track = track
        self.lyrics = lyrics
        self.timings = timings
        ready = true
        progress = position
        syncedAt = CACurrentMediaTime()
        tick()
    }

    /// Position of what's being heard right now: the lyrics follow this
    var heardPosition: Double { position - outputLatency - delay - nudge }

    /// When line `i` starts: as heard if it was timed by listening, otherwise LRCLIB's time
    func lineStart(_ i: Int) -> Double {
        guard let lines = lyrics?.synced, lines.indices.contains(i) else { return 0 }
        return timings?.words[i]?.first ?? lines[i].t + listenOffset
    }

    /// When each word of line `i` starts
    func wordStarts(_ i: Int) -> [Double] {
        guard let lines = lyrics?.synced, lines.indices.contains(i) else { return [] }
        if let words = timings?.words[i], words.count == lines[i].text.split(separator: " ").count { return words }
        return LyricsAligner.guessedStarts(lines, i).map { $0 + listenOffset }
    }

    func start() {
        poll()
        timers = [
            Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() },
            Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() },
        ]
        timers.forEach { RunLoop.main.add($0, forMode: .common) }
        // Spotify announces track changes and play/pause: react right away
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
                                                                       object: nil, queue: .main) { [weak self] _ in self?.poll() }
        LyricsLearner.shared.onUpdate = { [weak self] id, timings, offset in
            guard let self, self.track?.id == id else { return }
            self.timings = timings
            self.listenOffset = offset
        }
        // Plain lyrics just timed by listening: shown synced right away
        LyricsLearner.shared.onLearned = { [weak self] id, lines in
            guard let self, self.track?.id == id, var lyrics = self.lyrics else { return }
            lyrics.synced = lines
            lyrics.learned = true
            withAnimation(.easeInOut(duration: 0.4)) { self.lyrics = lyrics }
            self.tick()
        }
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        LyricsLearner.shared.stopListening()
    }

    func poll() {
        if polling { return }
        polling = true
        let startedAt = CACurrentMediaTime()
        Spotify.queue.async {
            let now = Spotify.nowPlaying()
            let receivedAt = CACurrentMediaTime()
            DispatchQueue.main.async {
                self.polling = false
                guard startedAt > self.seekedAt else { return }
                self.update(now, receivedAt)
            }
        }
    }

    private func update(_ new: NowPlaying?, _ receivedAt: Double) {
        ready = true
        outputLatency = currentOutputLatency()
        if new?.id != track?.id {
            lyrics = nil
            cover = nil
            current = nil
            unavailable = false
            timings = nil
            listenOffset = 0
            nudge = new.map { Nudges.get($0.id) } ?? 0
            if let new, !new.isAd { fetchLyrics(new); fetchCover(new) }
        }
        let wasPlaying = track?.isPlaying
        track = new
        if let new {
            progress = new.position
            syncedAt = receivedAt
            if !new.isAd { LyricsLearner.shared.record(track: new.id, position: new.position, playing: new.isPlaying, at: receivedAt) }
            if wasPlaying != new.isPlaying { followed() }
        }
    }

    /// Jumps to `time` (s): the line lights up right away, Spotify follows
    func seek(to time: Double) {
        progress = time
        syncedAt = CACurrentMediaTime()
        seekedAt = syncedAt
        if let track { LyricsLearner.shared.record(track: track.id, position: time, playing: track.isPlaying, at: syncedAt) }
        tick()
        Spotify.seek(to: time)
    }

    /// ← → in the window: this song's lyrics a little earlier or later, remembered
    func adjust(by seconds: Double) {
        guard let track else { return }
        nudge = (((nudge + seconds) * 10).rounded() / 10)
        Nudges.set(track.id, nudge)
        let value = String(format: "%+.1f s", locale: Locale.current, nudge)
        Toast.show(nudge == 0 ? L("Lyrics back on time", "Paroles recalées") : L("Lyrics \(value)", "Paroles \(value)"), symbol: "clock.arrow.2.circlepath")
        tick()
    }

    /// Tells the learner what's playing, once the lyrics are known (and again when listening is turned on)
    func followed() {
        LyricsLearner.shared.follow(track: track?.isAd == false ? track?.id : nil, lines: lyrics?.synced,
                                    plain: lyrics?.instrumental == true ? nil : lyrics?.plain, duration: track?.duration ?? 0,
                                    playing: track?.isPlaying == true)
    }

    private func fetchLyrics(_ track: NowPlaying) {
        Task {
            let found = await LRCLib.lyrics(for: track)
            await MainActor.run {
                guard self.track?.id == track.id else { return }   // the song changed meanwhile
                self.unavailable = found == nil
                self.lyrics = found ?? Lyrics(synced: nil, plain: nil, instrumental: false)
                if let lines = found?.synced { self.timings = TimingCache.load(track.id, lines: lines) }
                self.followed()
                if found == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                        if self?.track?.id == track.id { self?.fetchLyrics(track) }
                    }
                }
            }
        }
    }

    private func fetchCover(_ track: NowPlaying) {
        guard let url = track.artworkURL.flatMap(URL.init(string:)) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let image = data.flatMap(NSImage.init(data:)) else { return }
            DispatchQueue.main.async {
                if self.track?.id == track.id { withAnimation(.easeInOut(duration: 0.6)) { self.cover = image } }
            }
        }.resume()
    }

    func tick() {
        guard let track else { return }
        // Song over: ask for the next one right away
        if track.isPlaying && position > track.duration + 0.3 { poll() }
        guard let lines = lyrics?.synced else { return }
        // Slightly early, so a line lights up as it starts
        let now = heardPosition + 0.2
        let index = lines.indices.last { lineStart($0) <= now }
        if index != current { current = index }
    }
}

// MARK: - View

struct LyricsView: View {
    @ObservedObject var player: Player
    /// Shrink/expand button: LyricsController.setCompact drives the window and the animation
    let toggleCompact: () -> Void
    let onClose: () -> Void
    @State private var hovering = false
    /// Strip: buttons stacked on the right ("buttons = column" in config.txt); otherwise they show on hover only
    private var column: Bool { player.compact && player.buttonColumn }
    /// Buttons on hover (window and strip), over a shade; with "buttons = column" the window keeps them in view
    private var onHover: Bool { !player.buttonColumn }
    private var hidden: Bool { onHover && !hovering }

    var body: some View {
        // Each layout keeps its own fixed size: the animated card crops them instead of laying them out again
        ZStack(alignment: .top) {
            if player.compact {
                compactLayout.transition(.soft)
            } else {
                fullLayout.transition(.soft)
            }
        }
        // Opening: the card unrolls from its header (the strip: from a little shorter), down to its full height
        .frame(width: fullSize.width, height: player.unrolled ? (player.compact ? compactSize : fullSize).height : unrollFrom, alignment: .top)
        // On hover: a shade under the buttons, so they stay readable over the words
        .overlay(alignment: .top) {
            if onHover && hovering { shade.transition(.opacity) }
        }
        .overlay(alignment: column ? .trailing : .topTrailing) {
            Group {
                if column { buttonColumn } else { buttons }
            }
            // Window: centered on the cover. Strip: in the corner, or centered on the right
            .padding(.top, player.compact ? (column ? 0 : 14) : inset + 23 - 10)
            .padding(.trailing, player.compact ? 14 : inset)
            .opacity(hidden || !player.contentShown ? 0 : 1)
        }
        .onHover { over in withAnimation(.easeInOut(duration: 0.2)) { hovering = over } }
        .background(LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
        .background(alignment: .top) { coverBackground }
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        // During the animation the window can be taller than the card: the card stays at the top
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Height the card unrolls from when the window opens, and rolls back up to when it closes: the window's header
    /// (cover, title, artist), the strip a little shorter than itself
    private var unrollFrom: CGFloat { player.compact ? 64 : headerHeight }

    /// From the right edge, as tall as the strip and fading out below it: the same in the window and in the strip,
    /// so it stays put while the card changes size (the card crops it)
    var shade: some View {
        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .trailing, endPoint: UnitPoint(x: 0.45, y: 0.5))
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(height: compactSize.height * 1.6)
            .allowsHitTesting(false)
    }

    /// The lyrics go up under the header, fading out: they can start right below it, and still leave softly
    var fullLayout: some View {
        ZStack(alignment: .top) {
            content(compact: false).frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(SoftFade(amount: player.contentShown ? 0 : 1))   // coming in as the card unrolls
            header.contentShape(Rectangle())   // no click on the lyrics hidden under it
        }
        .frame(width: fullSize.width, height: fullSize.height)
    }

    /// The current line and the next one, centered in the strip whatever their length
    var compactLayout: some View {
        content(compact: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, inset)
            .padding(.trailing, column ? 14 + 20 + 14 : inset)
            .padding(.vertical, 12)
            .frame(width: compactSize.width, height: compactSize.height)
    }

    var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.08))
                if let cover = player.cover { Image(nsImage: cover).resizable().transition(.opacity) }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.track?.name ?? L("Lyrics", "Paroles"))
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Text(player.track?.artist ?? "Spotify")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    // The words are timed by listening to the song
                    if player.timings != nil || player.lyrics?.learned == true {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                            .help(L("Timed by listening to the song", "Calé en écoutant le morceau"))
                            .transition(.opacity)
                    }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 84)   // room for the buttons, laid on top
        }
        .padding(inset)
    }

    var buttons: some View {
        HStack(spacing: 8) {
            // Lit while the words light up one by one; dimmed, the whole line lights up at once
            roundButton("music.note", on: player.wordByWord) {
                withAnimation(.easeInOut(duration: 0.2)) { player.wordByWord.toggle() }
            }
            .help(player.wordByWord ? L("Word by word: on", "Mot à mot : activé") : L("Word by word: off", "Mot à mot : désactivé"))
            roundButton(player.compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                        action: toggleCompact)
            .help(player.compact ? L("Expand", "Agrandir") : L("Shrink", "Réduire"))
            roundButton("xmark", action: onClose)
        }
    }

    /// Strip, "column": × on top, as in a corner
    var buttonColumn: some View {
        VStack(spacing: 8) {
            roundButton("xmark", action: onClose)
            roundButton("arrow.up.left.and.arrow.down.right", action: toggleCompact).help(L("Expand", "Agrandir"))
            roundButton("music.note", on: player.wordByWord) {
                withAnimation(.easeInOut(duration: 0.2)) { player.wordByWord.toggle() }
            }
            .help(player.wordByWord ? L("Word by word: on", "Mot à mot : activé") : L("Word by word: off", "Mot à mot : désactivé"))
        }
    }

    /// `on`: a switch, lit when on and dimmed when off; nil for a plain button
    func roundButton(_ symbol: String, on: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(on == true ? 1 : on == false ? 0.35 : 0.7))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(on == true ? 0.3 : on == false ? 0.06 : 0.12)))
        }
        .buttonStyle(.plain)
    }

    /// `compact` is passed explicitly: during the transition both layouts are on screen
    @ViewBuilder func content(compact: Bool) -> some View {
        if !player.ready || (player.track != nil && player.track?.isAd == false && player.lyrics == nil) {
            ProgressView().controlSize(.small)
        } else if player.track == nil {
            message(L("Nothing playing on Spotify", "Rien ne joue sur Spotify"))
        } else if player.track?.isAd == true {
            message(L("Advertisement", "Publicité"))
        } else if let lines = player.lyrics?.synced {
            if compact {
                CompactLyrics(lines: lines, current: player.current, player: player,
                              width: compactSize.width - inset - (column ? 14 + 20 + 14 : inset)).id(player.track?.id)
            } else {
                SyncedLyrics(lines: lines, current: player.current, player: player) { player.seek(to: $0) }.id(player.track?.id)
            }
        } else if player.lyrics?.plain != nil && compact {
            message(L("Lyrics not synced", "Paroles non synchronisées"))
        } else if let plain = player.lyrics?.plain {
            ScrollView(showsIndicators: false) {
                Text(plain)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, inset)
                    .padding(.top, lyricsTop)
                    .padding(.bottom, 24)
            }
            .mask(fadeEdges)
        } else if player.lyrics?.instrumental == true {
            message("♪  Instrumental")
        } else if player.unavailable {
            message(L("Lyrics service unavailable, retrying…", "Service de paroles indisponible, nouvel essai…"))
        } else {
            message(L("No lyrics found", "Pas de paroles trouvées"))
        }
    }

    func message(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .medium)).foregroundColor(.white.opacity(0.5))
    }

    /// Blurred cover in the background, pinned to the top so it doesn't slide when the card changes size
    var coverBackground: some View {
        ZStack {
            if let cover = player.cover {
                Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 560, height: 560)
                    .blur(radius: 70)
                    .opacity(0.6)
                    .transition(.opacity)
            }
        }
    }
}

/// Fade with a little blur, zoom and slide: to go from one layout to the other
struct SoftFade: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .blur(radius: 8 * amount)
            .scaleEffect(1 - 0.04 * amount, anchor: .top)
            .offset(y: 10 * amount)
    }
}

extension AnyTransition {
    static let soft = AnyTransition.modifier(active: SoftFade(amount: 1), identity: SoftFade(amount: 0))
}

/// Header of the full window: cover, title, buttons
private let headerHeight = inset + 46 + inset
/// Where the lyrics start, just below the header
private let lyricsTop = headerHeight + 4

/// The lyrics fade out under the header (from the bottom of the cover) and at the bottom of the window
let fadeEdges = LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .clear, location: (headerHeight - inset) / fullSize.height),
                                       .init(color: .black, location: lyricsTop / fullSize.height),
                                       .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)

/// While nothing is sung (before the first line, during a break): three dots that light up one after the other
/// until the singing starts again
struct Breath: View {
    let player: Player
    /// When the silence starts and ends in the song (s)
    let from: Double
    let to: Double
    let active: Bool
    var dot: CGFloat = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { _ in
            let now = player.heardPosition
            let progress = active ? min(1, max(0, (now - from) / max(0.5, to - from))) : 0
            HStack(spacing: dot * 0.7) {
                ForEach(0..<3, id: \.self) { k in
                    Circle()
                        .fill(.white.opacity(0.3 + 0.7 * min(1, max(0, progress * 3 - Double(k)))))
                        .frame(width: dot, height: dot)
                }
            }
            // Breathes gently while waiting
            .scaleEffect(active ? 1 + 0.08 * sin(now * 2.6) : 1, anchor: .leading)
        }
    }
}

struct SyncedLyrics: View {
    let lines: [Line]
    let current: Int?
    let player: Player
    let onSeek: (Double) -> Void
    @State private var hovered: Int?
    @State private var appearedAt = Date.distantPast

    /// The song starts with music only: dots wait for the first line, at the top
    private var intro: Bool { player.lineStart(0) > 3 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if intro {
                        Breath(player: player, from: 0, to: player.lineStart(0), active: current == nil, dot: 10)
                            .frame(height: 29, alignment: .leading)
                            .shadow(color: .white.opacity(current == nil ? 0.35 : 0), radius: 10)
                            .id(-1)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let active = i == current
                        Group {
                            if line.text.isEmpty {
                                Breath(player: player, from: player.lineStart(i), to: end(of: i), active: active, dot: 10)
                                    .frame(height: 29, alignment: .leading)
                            } else if active && player.wordByWord {
                                // The line being sung lights up word by word
                                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in Karaoke.text(player, lines, i, dim: 0.5) }
                            } else {
                                Text(line.text)
                                    .foregroundColor(.white.opacity(active ? 1 : hovered == i ? 0.7 : i < (current ?? 0) ? 0.28 : 0.42))
                            }
                        }
                            .font(.system(size: 24, weight: .bold))
                            .shadow(color: .white.opacity(active ? 0.35 : 0), radius: 10)
                            .scaleEffect(active ? 1 : 0.94, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onHover { hovered = $0 ? i : hovered == i ? nil : hovered }
                            .onTapGesture { onSeek(max(0, player.lineStart(i) - 0.05)) }
                            .id(i)
                    }
                }
                .padding(.horizontal, inset)
                // Little room above: the first lines start at the top. Plenty below, for the last one to come up
                .padding(.top, lyricsTop)
                .padding(.bottom, 340)
            }
            .mask(fadeEdges)
            .onAppear {
                appearedAt = Date()
                settle(proxy)
            }
            .onChange(of: current) { _, _ in
                // Just opened, the line being sung was found: straight there, without scrolling through the song
                if Date().timeIntervalSince(appearedAt) < 0.6 {
                    settle(proxy)
                } else {
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { scroll(proxy) }
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: current)
    }

    /// The line being sung comes up to 40 % of the window. The first lines can't go that high: they stay at the top
    /// and the light moves down to them
    private func scroll(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(player.current ?? (intro ? -1 : 0), anchor: UnitPoint(x: 0, y: 0.4))
    }

    /// On the line at once, without animation (coming back from the strip, or opening). Again a little later: in a
    /// window that has just opened, the list isn't laid out yet and a scroll right away does nothing (it stayed at the
    /// top, the line being sung out of sight)
    private func settle(_ proxy: ScrollViewProxy) {
        let jump = {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { scroll(proxy) }
        }
        jump()
        for delay in [0.1, 0.3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: jump) }
    }

    private func end(of i: Int) -> Double {
        i + 1 < lines.count ? player.lineStart(i + 1) : (player.track?.duration ?? player.lineStart(i) + 4)
    }
}

/// Small strip: the current line, and the next one dimmer. Centered in the strip, however long they are
struct CompactLyrics: View {
    let lines: [Line]
    let current: Int?
    /// Read on every frame for the words of the current line
    let player: Player
    /// Room for the text (pt)
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            pair.id(current)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: current)
    }

    var pair: some View {
        VStack(alignment: .leading, spacing: 6) {
            sung(current)
            upcoming((current ?? -1) + 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line being sung, as big as it can be: smaller only when it wouldn't fit on two lines, never cut with "…".
    /// Dots before the first line and during breaks
    @ViewBuilder func sung(_ index: Int?) -> some View {
        if let i = index, i < lines.count, !lines[i].text.isEmpty {
            let size = Self.fontSize(lines[i].text, width: width)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.wordByWord)) { _ in
                if size > 0 {
                    // Takes just its own height, so the pair stays centered
                    karaoke(i).font(.system(size: size, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                } else {
                    karaoke(i).font(.system(size: 16, weight: .bold)).lineLimit(3).minimumScaleFactor(0.6).frame(maxHeight: 58, alignment: .leading)
                }
            }
        } else if (index ?? -1) < lines.count {
            let next = (index ?? -1) + 1
            Breath(player: player, from: index.map { player.lineStart($0) } ?? 0,
                   to: next < lines.count ? player.lineStart(next) : (player.track?.duration ?? 0), active: true, dot: 8)
                .frame(height: 24, alignment: .leading)
        }
    }

    /// The next line, dimmer: dots if a break comes next, nothing after the last line
    @ViewBuilder func upcoming(_ i: Int) -> some View {
        if i < lines.count && lines[i].text.isEmpty {
            Breath(player: player, from: 0, to: 0, active: false, dot: 6).frame(height: 18, alignment: .leading)
        } else if i < lines.count {
            Text(lines[i].text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    func karaoke(_ i: Int) -> Text {
        player.wordByWord ? Karaoke.text(player, lines, i, dim: 0.38) : Text(lines[i].text).foregroundColor(.white)
    }

    /// 20 pt if the line fits on 2 lines of `width`, otherwise 16 pt on 3; 0 if even that's too long (it then shrinks)
    static func fontSize(_ text: String, width: CGFloat) -> CGFloat {
        for (size, rows) in [(CGFloat(20), 2.0), (16, 3.0)] {
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            let height = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
            if height <= (font.ascender - font.descender + font.leading) * rows + 2 { return size }
        }
        return 0
    }
}

/// A line karaoke-style: each word lights up while it's sung, from the times learned by listening,
/// or, without them, the line shared between its words by length
enum Karaoke {
    static func text(_ player: Player, _ lines: [Line], _ i: Int, dim: Double) -> Text {
        let words = lines[i].text.split(separator: " ")
        let starts = player.wordStarts(i)
        guard starts.count == words.count else { return Text(lines[i].text).foregroundColor(.white) }
        let next = i + 1 < lines.count ? player.lineStart(i + 1) : starts.last! + 4
        let now = player.heardPosition + 0.05
        return words.enumerated().reduce(Text("")) { text, item in
            let (k, word) = item
            let start = starts[k]
            // Last word: held until the next line, but not over a long silence
            let end = k + 1 < starts.count ? starts[k + 1] : min(next, start + 0.12 * Double(word.count) + 0.4)
            let sung = min(1, max(0, (now - start) / max(0.08, end - start)))
            return Text("\(text)\(Text((k == 0 ? "" : " ") + word).foregroundColor(.white.opacity(dim + (1 - dim) * sung)))")
        }
    }
}

/// Each song's own lyrics adjustment (← →), remembered
enum Nudges {
    private static let key = "lyricsNudges"
    static func get(_ track: String) -> Double { (UserDefaults.standard.dictionary(forKey: key)?[track] as? Double) ?? 0 }
    static func set(_ track: String, _ value: Double) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[track] = value == 0 ? nil : value
        UserDefaults.standard.set(all, forKey: key)
    }
}

// MARK: - Window

final class LyricsController {
    private var panel: Panel?
    private var player: Player?
    private var monitor: Any?

    func toggle() {
        if panel != nil { close() } else { show() }
    }

    /// config.txt "delay"
    var delay = 0.0 { didSet { player?.delay = delay } }
    /// config.txt "buttons = column"
    var buttonColumn = false { didSet { player?.buttonColumn = buttonColumn } }

    /// "listen" changed in config.txt: start (or stop) listening to the song playing now, not from the next one
    func listeningChanged() { player?.followed() }

    func show() {
        let player = Player()
        player.delay = delay
        player.buttonColumn = buttonColumn
        let host = HostingView(rootView: LyricsView(player: player,
                                                    toggleCompact: { [weak self] in self?.setCompact(!player.compact) },
                                                    onClose: { [weak self] in self?.close() }))
        host.sizingOptions = []   // the window decides the size, not SwiftUI
        let size = player.compact ? compactSize : fullSize
        // Doesn't take the focus: you keep working in the app in front
        let panel = Panel(content: host)
        // Reopens where it was left, otherwise on the right of the screen under the mouse
        if !panel.setFrameUsingName("CrateLyrics") {
            let f = screenUnderMouse()
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 24, y: f.midY - size.height / 2))
        }
        panel.setFrameAutosaveName("CrateLyrics")
        resize(panel, compact: player.compact)   // the saved size may be the other mode's
        // The card fades in at its header's height, then unrolls downward while the lyrics come in on it. The fade is
        // the window's own: the blurred backdrop is drawn by macOS and only follows the window's opacity
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        player.start()
        // Nothing shows until the song and its lyrics are there (or 0.4 s): no empty card, and laying the lyrics out
        // takes a moment that would stall the animation halfway
        var waited = 0.0
        let unroll = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            waited += 1.0 / 60
            let loaded = player.ready && (player.track == nil || player.track?.isAd == true || player.lyrics != nil)
            guard loaded || waited > 0.4, self?.panel === panel else { return }
            timer.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
                withAnimation(.spring(duration: 0.6, bounce: 0.1).delay(0.14)) { player.unrolled = true }
                withAnimation(.easeOut(duration: 0.45).delay(0.24)) { player.contentShown = true }
                self?.followShadow(panel, for: 1.0)
            }
        }
        RunLoop.main.add(unroll, forMode: .common)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, event.window === self?.panel { self?.close(); return nil }   // esc, after a click in the window
            // ← →: this song's lyrics earlier / later
            if [123, 124].contains(event.keyCode), event.window === self?.panel { self?.player?.adjust(by: event.keyCode == 123 ? -0.1 : 0.1); return nil }
            return event
        }
        self.panel = panel
        self.player = player
    }

    /// The card animates in SwiftUI; the (transparent) window grows before or shrinks after, invisibly
    func setCompact(_ compact: Bool) {
        guard let panel, let player else { return }
        if !compact { resize(panel, compact: false) }
        withAnimation(.spring(duration: 0.5, bounce: 0), completionCriteria: .removed) {
            player.compact = compact
        } completion: { [self] in
            // Clicked again meanwhile: the other animation decides
            if compact && player.compact && self.panel === panel { resize(panel, compact: true) }
            panel.invalidateShadow()
        }
        followShadow(panel, for: 0.7)
    }

    /// The window shadow follows the card's shape while it animates
    private func followShadow(_ panel: Panel, for seconds: Double) {
        let shadow = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in panel.invalidateShadow() }
        RunLoop.main.add(shadow, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { shadow.invalidate() }
    }

    /// Size of the mode, keeping the top of the window in place (without leaving the screen)
    private func resize(_ panel: Panel, compact: Bool) {
        let size = compact ? compactSize : fullSize
        var frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        if let visible = panel.screen?.visibleFrame { frame.origin.y = max(frame.minY, visible.minY) }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    func close() {
        player?.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let panel, let player else { return }
        self.panel = nil
        self.player = nil
        // Rolls back up to its top edge, fading out (the window too, for the backdrop)
        withAnimation(.easeIn(duration: 0.12)) { player.contentShown = false }
        withAnimation(.spring(duration: 0.3, bounce: 0)) { player.unrolled = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
        followShadow(panel, for: 0.3)
    }
}
