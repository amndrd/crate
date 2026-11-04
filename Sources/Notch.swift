import AppKit
import Combine
import SwiftUI

// Around the MacBook's notch, while a song is loaded: its cover on the left of the camera, bars on the right.
// Mouse over it: the notch opens into a player (cover, title, artist, progress, previous / play-pause / next).

enum NotchSize {
    /// Closed: room on each side of the camera, for the cover and the bars
    static let ear: CGFloat = 38
    static let openWidth: CGFloat = 548
    /// Open: height under the notch band
    static let openBelow: CGFloat = 118
    /// Room around the open player for its shadow (radius 24, 12 down): it fades out completely instead of being
    /// cut by the edge of the window
    static let shadow: CGFloat = 64
    static let openFlare: CGFloat = 10
}

/// Notch outline: straight sides, rounded bottom corners, small outward curves where it meets the top of the screen
struct NotchOutline: Shape {
    var flare: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = flare, r = min(radius, (rect.height - f) / 1.2)
        let left = rect.minX + f, right = rect.maxX - f, bottom = rect.maxY
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.minY + f), control: CGPoint(x: left, y: rect.minY))
        p.addLine(to: CGPoint(x: left, y: bottom - r))
        p.addCurve(to: CGPoint(x: left + r, y: bottom), control1: CGPoint(x: left, y: bottom - r * 0.42), control2: CGPoint(x: left + r * 0.42, y: bottom))
        p.addLine(to: CGPoint(x: right - r, y: bottom))
        p.addCurve(to: CGPoint(x: right, y: bottom - r), control1: CGPoint(x: right - r * 0.42, y: bottom), control2: CGPoint(x: right, y: bottom - r * 0.42))
        p.addLine(to: CGPoint(x: right, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

final class NotchModel: ObservableObject {
    @Published var open = false
    let notch: CGSize
    init(notch: CGSize) { self.notch = notch }
}

/// Square cover with rounded corners, or a music note while there's none
struct SquareCover: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.16).overlay(
                    Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .medium)).foregroundColor(.white.opacity(0.4)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var playback: PlaybackMonitor

    var body: some View {
        let open = model.open
        let notch = model.notch
        let width = open ? NotchSize.openWidth : notch.width + 2 * NotchSize.ear
        let height = open ? notch.height + NotchSize.openBelow : notch.height
        let flare: CGFloat = open ? NotchSize.openFlare : 6
        let outline = NotchOutline(flare: flare, radius: open ? 28 : 10)

        ZStack(alignment: .top) {
            if open {
                NotchPlayer(playback: playback, notchHeight: notch.height)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                                            removal: .opacity.animation(.easeIn(duration: 0.1))))
            } else {
                NotchGlance(playback: playback, width: width, height: notch.height)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
                                            removal: .opacity.animation(.easeIn(duration: 0.08))))
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .padding(.horizontal, flare)
        .background(outline.fill(Color.black))
        .clipShape(outline)
        .shadow(color: .black.opacity(open ? 0.4 : 0), radius: 24, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: open)
    }
}

/// Closed: cover on the left of the camera, bars on the right
struct NotchGlance: View {
    @ObservedObject var playback: PlaybackMonitor
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            SquareCover(image: playback.cover, size: 22, radius: 5)
                .frame(width: NotchSize.ear)
            Spacer(minLength: 0)
            EqualizerBars(color: .white.opacity(0.78), playing: playback.track?.isPlaying == true,
                          barWidth: 2.5, spacing: 2.5, height: 13, centered: true)
                .frame(width: NotchSize.ear)
        }
        .frame(width: width, height: height)
    }
}

/// Open: the player. The cover rises next to the camera, everything else stays under the notch
struct NotchPlayer: View {
    @ObservedObject var playback: PlaybackMonitor
    let notchHeight: CGFloat

    var body: some View {
        let track = playback.track
        let playing = track?.isPlaying == true
        let subtitle = [track?.artist ?? "", track?.album ?? ""].filter { !$0.isEmpty }.joined(separator: " - ")

        ZStack(alignment: .topLeading) {
            SquareCover(image: playback.cover, size: 108, radius: 14)
                .offset(x: 21, y: 21)

            VStack(spacing: 0) {
                Text(track?.name ?? "").font(.system(size: 17, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text(subtitle).font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.5)).lineLimit(1)
                    .padding(.top, 3)
                NotchProgress(playback: playback)
                    .padding(.top, 10)
                HStack(spacing: 30) {
                    NotchButton(symbol: "backward.end.fill", size: 19, label: L("Previous", "Précédent")) {
                        Spotify.previous(); playback.pollSoon()
                    }
                    NotchButton(symbol: playing ? "pause.fill" : "play.fill", size: 23, label: playing ? L("Pause", "Pause") : L("Play", "Lecture")) {
                        Spotify.playPause(); playback.pollSoon()
                    }
                    NotchButton(symbol: "forward.end.fill", size: 19, label: L("Next", "Suivant")) {
                        Spotify.next(); playback.pollSoon()
                    }
                }
                .padding(.top, 6)
            }
            .frame(width: 330)
            .offset(x: 142, y: notchHeight + 5)

            EqualizerBars(color: .white.opacity(0.55), playing: playing, barWidth: 5, spacing: 4.5, height: 30, centered: true)
                .offset(x: NotchSize.openWidth - 28 - 33.5, y: 21 + 54 - 15)
        }
        .frame(width: NotchSize.openWidth, height: notchHeight + NotchSize.openBelow, alignment: .topLeading)
    }
}

/// Elapsed time, bar (drag or click it to move in the song), remaining time
struct NotchProgress: View {
    @ObservedObject var playback: PlaybackMonitor
    /// Share of the song under the mouse while the bar is being dragged
    @State private var dragged: Double?
    private let barWidth: CGFloat = 232

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(playback.track?.duration ?? 0, 1)
            let position = dragged.map { $0 * duration } ?? playback.position
            HStack(spacing: 10) {
                Text(Self.time(position)).frame(width: 38, alignment: .trailing)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22)).frame(height: 4)
                    Capsule().fill(Color.white).frame(width: max(4, barWidth * position / duration), height: 4)
                }
                .frame(width: barWidth, height: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragged = share($0.location.x) }
                    .onEnded {
                        playback.seek(to: share($0.location.x) * duration)
                        dragged = nil
                    })
                Text("-" + Self.time(duration - position)).frame(width: 42, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundColor(.white.opacity(0.7))
        }
    }

    private func share(_ x: CGFloat) -> Double { Double(min(max(x / barWidth, 0), 1)) }

    static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

struct NotchButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundColor(.white)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .accessibilityLabel(label)
    }
}

private struct NotchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Window

/// Where the notch is, in screen coordinates
struct NotchGeometry: Equatable {
    let screen: CGRect
    let notch: CGRect

    /// The screen with a notch, if there's one (MacBooks since 2021, lid open)
    static func find() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            let width = screen.frame.width - left.width - right.width
            let height = screen.safeAreaInsets.top
            guard width > 0 else { continue }
            return NotchGeometry(screen: screen.frame,
                                 notch: CGRect(x: screen.frame.minX + left.width, y: screen.frame.maxY - height, width: width, height: height))
        }
        return nil
    }
}

/// Window over the notch: above the menu bar, on every Space, never takes the keyboard
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        acceptsMouseMovedEvents = true
        // Closed, clicks go through to the menu bar; open, the player takes them
        ignoresMouseEvents = true
    }
}

final class NotchController {
    private let playback: PlaybackMonitor
    private var enabled = false
    private var wanted = false
    private var panel: NotchPanel?
    private var model: NotchModel?
    private var geometry: NotchGeometry?
    private var watcher: AnyCancellable?
    private var mouseMonitors: [Any] = []
    private var opening: DispatchWorkItem?
    private var closing: DispatchWorkItem?
    /// While open: checks where the mouse is even if an event was missed
    private var safety: Timer?

    init(playback: PlaybackMonitor) {
        self.playback = playback
        // Screen plugged in or out, resolution changed, lid closed: the notch is looked for again
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            watcher = playback.$track.map { $0 != nil }.removeDuplicates().sink { [weak self] loaded in
                if loaded { self?.show() } else { self?.hide() }
            }
            let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            mouseMonitors = [
                NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in self?.mouseMoved() } as Any,
                NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in self?.mouseMoved(); return event } as Any,
            ]
        } else {
            watcher = nil
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors = []
            hide()
        }
    }

    private func show() {
        wanted = true
        guard enabled, let found = NotchGeometry.find() else { return }
        if panel == nil || geometry != found { build(found) }
        guard let panel else { return }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        wanted = false
        setOpen(false)
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.wanted != true { panel.orderOut(nil) }
        })
    }

    private func rebuild() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
        geometry = nil
        if wanted { show() }
    }

    private func build(_ g: NotchGeometry) {
        panel?.orderOut(nil)
        geometry = g
        let model = NotchModel(notch: g.notch.size)
        // Big enough for the open player and its shadow; transparent around the black shape
        let size = CGSize(width: NotchSize.openWidth + 2 * NotchSize.openFlare + 2 * NotchSize.shadow,
                          height: g.notch.height + NotchSize.openBelow + NotchSize.shadow)
        let host = HostingView(rootView: NotchView(model: model, playback: playback))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let panel = NotchPanel(frame: NSRect(x: g.notch.midX - size.width / 2, y: g.screen.maxY - size.height,
                                             width: size.width, height: size.height))
        panel.contentView = host
        self.panel = panel
        self.model = model
    }

    private func mouseMoved() {
        guard let panel, panel.isVisible, panel.alphaValue > 0.5, let g = geometry, let model else { return }
        let mouse = NSEvent.mouseLocation
        let zone: CGRect
        if model.open {
            // The player plus a small margin, so a slightly clumsy mouse doesn't close it
            let width = NotchSize.openWidth + 2 * NotchSize.openFlare + 24
            let height = g.notch.height + NotchSize.openBelow + 12
            zone = CGRect(x: g.notch.midX - width / 2, y: g.screen.maxY - height, width: width, height: height + 2)
        } else {
            let width = g.notch.width + 2 * NotchSize.ear
            zone = CGRect(x: g.notch.midX - width / 2, y: g.screen.maxY - g.notch.height, width: width, height: g.notch.height + 2)
        }
        if zone.contains(mouse) {
            closing?.cancel()
            closing = nil
            if !model.open && opening == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.opening = nil
                    self?.setOpen(true)
                }
                opening = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
        } else {
            opening?.cancel()
            opening = nil
            if model.open && closing == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.closing = nil
                    self?.setOpen(false)
                }
                closing = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
    }

    private func setOpen(_ open: Bool) {
        guard let model, let panel, model.open != open else { return }
        safety?.invalidate()
        safety = nil
        panel.ignoresMouseEvents = !open
        playback.setFast(open)
        model.open = open
        if open {
            let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.mouseMoved() }
            RunLoop.main.add(timer, forMode: .common)
            safety = timer
        }
    }
}
