import AppKit
import SwiftUI

// Lyrics window for the track playing in Spotify, synced karaoke-style.
// Lyrics come from LRCLIB (free, open database) and are cached in ~/Library/Caches/Crate/lyrics.
// Floats above other windows without stealing focus; click a line to jump there in the song.
// The button left of × shrinks it to a small strip with just the current line (karaoke, word by word) and the next one
// (remembered between openings).

let fullSize = NSSize(width: 400, height: 560)
let compactSize = NSSize(width: 400, height: 116)

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
    /// Time the sound takes to come out of the speakers or headphones (Bluetooth: a lot)
    private var outputLatency = 0.0
    /// Window shrunk to the current and next lines
    @Published var compact = UserDefaults.standard.bool(forKey: "compactLyrics") {
        didSet { UserDefaults.standard.set(compact, forKey: "compactLyrics") }
    }

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

    var body: some View {
        // Each layout keeps its own fixed size: the animated card crops them instead of laying them out again
        ZStack(alignment: .top) {
            if player.compact {
                compactLayout.transition(.soft)
            } else {
                fullLayout.transition(.soft)
            }
        }
        .frame(width: fullSize.width, height: (player.compact ? compactSize : fullSize).height, alignment: .top)
        .overlay(alignment: .topTrailing) { buttons.padding(.top, 29).padding(.trailing, 16) }
        .background(LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
        .background(alignment: .top) { coverBackground }
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        // During the animation the window can be taller than the card: the card stays at the top
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var fullLayout: some View {
        VStack(spacing: 0) {
            header
            content(compact: false).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: fullSize.width, height: fullSize.height)
    }

    /// The current line (left of the buttons) and the next one
    var compactLayout: some View {
        content(compact: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
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
            Spacer(minLength: 48)   // room for the buttons, laid on top
        }
        .padding(16)
    }

    var buttons: some View {
        HStack(spacing: 8) {
            roundButton(player.compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                        action: toggleCompact)
            .help(player.compact ? L("Expand", "Agrandir") : L("Shrink", "Réduire"))
            roundButton("xmark", action: onClose)
        }
    }

    func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(0.12)))
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
                CompactLyrics(lines: lines, current: player.current, player: player).id(player.track?.id)
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
                    .padding(24)
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

/// Fade at the top and bottom of the lyrics
let fadeEdges = LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                       .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)

struct SyncedLyrics: View {
    let lines: [Line]
    let current: Int?
    let player: Player
    let onSeek: (Double) -> Void
    @State private var hovered: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let active = i == current
                        Group {
                            if active && !line.text.isEmpty {
                                // The line being sung lights up word by word
                                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in Karaoke.text(player, lines, i, dim: 0.5) }
                            } else {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .foregroundColor(.white.opacity(hovered == i ? 0.7 : i < (current ?? 0) ? 0.28 : 0.42))
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
                .padding(.horizontal, 24)
                .padding(.vertical, 220)
            }
            .mask(fadeEdges)
            .onAppear {
                // No animation: coming back from the small strip, the list must already be on the right line
                guard let current else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.35)) }
            }
            .onChange(of: current) { _, new in
                guard let new else { return }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.35)) }
            }
        }
        .animation(.easeOut(duration: 0.35), value: current)
    }
}

/// Small strip: the current line, and the next one dimmer
struct CompactLyrics: View {
    let lines: [Line]
    let current: Int?
    /// Read on every frame for the words of the current line
    let player: Player

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

    /// Long lines shrink until they fit whole, instead of being cut with "…"
    var pair: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in karaoke(current ?? -1) }
                .font(.system(size: 20, weight: .bold))
                .lineLimit(3)
                .minimumScaleFactor(0.5)
                .frame(maxHeight: 58, alignment: .bottomLeading)
                .padding(.trailing, 60)   // room for the buttons
            Text(text((current ?? -1) + 1))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func karaoke(_ i: Int) -> Text {
        guard i >= 0, i < lines.count, !lines[i].text.isEmpty else { return Text(text(i)).foregroundColor(.white) }
        return Karaoke.text(player, lines, i, dim: 0.38)
    }

    /// Before the first line: ♪ ; after the last one: nothing
    func text(_ i: Int) -> String {
        guard i < lines.count else { return "" }
        return i < 0 || lines[i].text.isEmpty ? "♪" : lines[i].text
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

    /// "listen" changed in config.txt: start (or stop) listening to the song playing now, not from the next one
    func listeningChanged() { player?.followed() }

    func show() {
        let player = Player()
        player.delay = delay
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
        panel.fadeIn(duration: 0.2)
        player.start()
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
        // The window shadow follows the card's shape during the animation
        let shadow = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in panel.invalidateShadow() }
        RunLoop.main.add(shadow, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { shadow.invalidate() }
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
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}
