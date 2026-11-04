import AppKit
import SwiftUI

/// Follows what Spotify is playing, for the notch.
/// Spotify announces song changes and play/pause itself: Crate asks for the details right then,
/// and otherwise only checks every few seconds (every second while the notch player is open).
final class PlaybackMonitor: ObservableObject {
    /// Song loaded in Spotify, playing or paused; nil when Spotify is closed or stopped
    @Published var track: NowPlaying?
    @Published var cover: NSImage?

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
    }

    private func loadCover(_ song: NowPlaying?) {
        guard let song, let link = song.artworkURL, let url = URL(string: link), !link.isEmpty else {
            cover = nil
            return
        }
        if let image = covers[link] { return setCover(image) }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let image = data.flatMap(NSImage.init(data:)) else { return }
            DispatchQueue.main.async {
                if self.covers.count > 30 { self.covers.removeAll() }
                self.covers[link] = image
                if self.track?.id == song.id { self.setCover(image) }
            }
        }.resume()
    }

    private func setCover(_ image: NSImage) {
        withAnimation(.easeInOut(duration: 0.3)) { cover = image }
    }
}

// MARK: - Shared pieces

/// Four equalizer bars. They dance with Core Animation: macOS animates them, Crate itself stays idle,
/// so they can stay on screen all day. Paused: they stand still, all the same height.
struct EqualizerBars: NSViewRepresentable {
    var color: Color
    var playing: Bool
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    var height: CGFloat = 14
    /// Centered like a waveform, or standing on a line
    var centered = false

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
