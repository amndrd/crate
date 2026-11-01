import AppKit
import SwiftUI

/// Follows what Spotify is playing, for the capsule and the notch.
/// Spotify announces song changes and play/pause itself: Crate asks for the details right then,
/// and otherwise only checks every few seconds (every second while the notch player is open).
final class PlaybackMonitor: ObservableObject {
    /// Song loaded in Spotify, playing or paused; nil when Spotify is closed or stopped
    @Published var track: NowPlaying?
    @Published var cover: NSImage?
    /// The cover's dominant color, for the capsule's bars
    @Published var tint = Color(white: 0.6)

    /// The song that comes after a skip with the "next" shortcut, with its cover once it has arrived
    var onSkippedTo: ((NowPlaying, NSImage?, Color) -> Void)?

    private var running = false
    private var fast = false
    private var timer: Timer?
    private var polling = false
    private var pollAgain = false
    /// Position (s) reported by Spotify at `syncedAt`: interpolated in between
    private var progress = 0.0
    private var syncedAt = CACurrentMediaTime()
    /// Last seek: positions asked for before it are stale
    private var seekedAt = 0.0
    /// Until when the next song change is announced: set by the "next" shortcut, a few seconds
    private var announceUntil = 0.0
    /// Song waiting for its cover before being announced
    private var pending: String?
    private var coverFor: String?
    private var covers: [String: NSImage] = [:]

    /// Where the song is (s), moving on by itself between Spotify's answers
    var position: Double {
        guard let track else { return 0 }
        return min(track.duration, progress + (track.isPlaying ? CACurrentMediaTime() - syncedAt : 0))
    }

    func setRunning(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(spotifyChanged),
                                                                name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
                                                                object: nil, suspensionBehavior: .deliverImmediately)
            let workspace = NSWorkspace.shared.notificationCenter
            workspace.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
            workspace.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
            schedule()
            poll()
        } else {
            DistributedNotificationCenter.default().removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            timer?.invalidate()
            timer = nil
            track = nil
        }
    }

    /// While the notch player is open, its progress bar stays exact
    func setFast(_ on: Bool) {
        guard on != fast else { return }
        fast = on
        if running { schedule() }
        if on { poll() }
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: fast ? 1 : 6, repeats: true) { [weak self] _ in
            // Spotify closed: nothing to ask
            if Spotify.isRunning || self?.track != nil { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func spotifyChanged() { poll() }

    @objc private func appsChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Spotify.bundleID { poll() }
    }

    /// The "next" shortcut was pressed: the song that comes next will be announced (the capsule).
    /// Songs changing on their own, or from the notch's buttons, aren't.
    func expectSkip() {
        announceUntil = CACurrentMediaTime() + 5
        pollSoon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.poll() }
    }

    /// Asks again in a moment, after a button press (Spotify also announces the change itself)
    func pollSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    func poll() {
        guard running else { return }
        if polling { pollAgain = true; return }
        polling = true
        let askedAt = CACurrentMediaTime()
        Spotify.queue.async {
            let now = Spotify.isRunning ? Spotify.nowPlaying() : nil
            let receivedAt = CACurrentMediaTime()
            DispatchQueue.main.async {
                self.polling = false
                if self.running && askedAt > self.seekedAt { self.update(now, receivedAt) }
                if self.pollAgain { self.pollAgain = false; self.poll() }
            }
        }
    }

    /// Jumps to `time` (s): the bar moves right away, Spotify follows
    func seek(to time: Double) {
        progress = time
        syncedAt = CACurrentMediaTime()
        seekedAt = syncedAt
        objectWillChange.send()
        Spotify.seek(to: time)
    }

    private func update(_ new: NowPlaying?, _ receivedAt: Double) {
        let changed = new?.id != track?.id
        if changed { loadCover(new) }
        track = new
        if let new {
            progress = new.position
            syncedAt = receivedAt
        }
        guard changed, let new, !new.isAd, CACurrentMediaTime() < announceUntil else { return }
        announceUntil = 0
        // Shown with its cover: waits for it a moment, not longer
        pending = new.id
        if coverFor == new.id { announcePending(new.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.announcePending(new.id) }
    }

    private func announcePending(_ id: String) {
        guard pending == id, let track, track.id == id else { return }
        pending = nil
        onSkippedTo?(track, coverFor == id ? cover : nil, tint)
    }

    private func loadCover(_ song: NowPlaying?) {
        guard let song, let link = song.artworkURL, let url = URL(string: link), !link.isEmpty else {
            cover = nil
            coverFor = nil
            return
        }
        if let image = covers[link] { return setCover(image, for: song.id) }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let image = data.flatMap(NSImage.init(data:)) else { return }
            DispatchQueue.main.async {
                if self.covers.count > 30 { self.covers.removeAll() }
                self.covers[link] = image
                if self.track?.id == song.id { self.setCover(image, for: song.id) }
            }
        }.resume()
    }

    private func setCover(_ image: NSImage, for id: String) {
        withAnimation(.easeInOut(duration: 0.3)) {
            cover = image
            tint = dominantColor(image)
        }
        coverFor = id
        announcePending(id)
    }
}

// MARK: - Shared pieces

/// Small vinyl with the cover as its label, spinning
struct RecordDisc: View {
    let cover: NSImage?
    let size: CGFloat
    @State private var angle = 0.0

    var body: some View {
        ZStack {
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(white: 0.15), Color(white: 0.055)], center: .center, startRadius: 0, endRadius: size / 2))
                Grooves()
                label
                    .frame(width: size * 0.48, height: size * 0.48)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 0.5))
            }
            .rotationEffect(.degrees(angle))
            // Reflections stay still, like a real light source
            Circle()
                .fill(AngularGradient(colors: [.white.opacity(0), .white.opacity(0.22), .white.opacity(0), .white.opacity(0),
                                               .white.opacity(0.16), .white.opacity(0), .white.opacity(0)],
                                      center: .center, angle: .degrees(-35)))
                .mask(Circle().strokeBorder(lineWidth: size * 0.3).padding(size * 0.01))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
            Circle().fill(Color(white: 0.02)).frame(width: size * 0.045, height: size * 0.045)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }

    @ViewBuilder private var label: some View {
        if let cover {
            Image(nsImage: cover).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [spotifyGreen, Color(red: 0.05, green: 0.25, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Four equalizer bars. They dance with Core Animation: macOS animates them, Crate itself stays idle,
/// so they can stay on screen all day. Paused: they stand still, all the same height.
struct EqualizerBars: NSViewRepresentable {
    var color: Color
    var playing: Bool
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    var height: CGFloat = 14
    /// Centered like a waveform (notch) or standing on a line (capsule)
    var centered = false
    var glow = false

    static let count = 4
    var width: CGFloat { CGFloat(Self.count) * barWidth + CGFloat(Self.count - 1) * spacing }

    func makeNSView(context: Context) -> BarsView { BarsView() }

    func updateNSView(_ view: BarsView, context: Context) {
        view.update(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarsView, context: Context) -> CGSize? {
        CGSize(width: width, height: height)
    }
}

final class BarsView: NSView {
    private var bars: [CALayer] = []
    private var shape: (playing: Bool, barWidth: CGFloat, spacing: CGFloat, height: CGFloat, centered: Bool)?

    /// Heights (share of the full height) each bar goes through, and how long a round takes
    private static let steps: [[CGFloat]] = [[0.35, 0.9, 0.5, 1, 0.42], [1, 0.45, 0.8, 0.3, 0.95], [0.55, 1, 0.35, 0.75, 0.6], [0.8, 0.4, 1, 0.55, 0.9]]
    private static let durations: [CFTimeInterval] = [1.1, 0.85, 1.25, 0.95]
    private static let paused: CGFloat = 0.55

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ bars: EqualizerBars) {
        if self.bars.isEmpty {
            for _ in 0..<EqualizerBars.count {
                let bar = CALayer()
                layer?.addSublayer(bar)
                self.bars.append(bar)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in self.bars.enumerated() {
            let level = bars.playing ? Self.steps[i][0] : Self.paused
            bar.backgroundColor = NSColor(bars.color).cgColor
            bar.cornerRadius = bars.barWidth / 2
            bar.anchorPoint = CGPoint(x: 0.5, y: bars.centered ? 0.5 : 0)
            bar.position = CGPoint(x: CGFloat(i) * (bars.barWidth + bars.spacing) + bars.barWidth / 2, y: bars.centered ? bars.height / 2 : 0)
            bar.bounds = CGRect(x: 0, y: 0, width: bars.barWidth, height: max(bars.barWidth, bars.height * level))
            bar.shadowColor = NSColor(bars.color).cgColor
            bar.shadowOpacity = bars.glow ? 0.6 : 0
            bar.shadowRadius = 3
            bar.shadowOffset = .zero
        }
        CATransaction.commit()

        // The dance only restarts when it has to: a new color alone keeps it going
        let shape = (bars.playing, bars.barWidth, bars.spacing, bars.height, bars.centered)
        if let old = self.shape, old == shape { return }
        self.shape = shape
        for (i, bar) in self.bars.enumerated() {
            bar.removeAnimation(forKey: "dance")
            guard bars.playing else { continue }
            let dance = CAKeyframeAnimation(keyPath: "bounds.size.height")
            dance.values = (Self.steps[i] + [Self.steps[i][0]]).map { max(bars.barWidth, bars.height * $0) }
            dance.duration = Self.durations[i]
            dance.calculationMode = .cubic
            dance.repeatCount = .infinity
            dance.isRemovedOnCompletion = false
            bar.add(dance, forKey: "dance")
        }
    }
}
