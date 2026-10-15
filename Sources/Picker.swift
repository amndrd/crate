import AppKit
import SwiftUI

// Playlist picker: a grid of record sleeves. The vinyl slides out and spins on hover,
// the background takes the hovered cover's color, and the playlist that's playing keeps spinning.

final class Selection: ObservableObject {
    /// Selected playlist (hover or keyboard); nil when the mouse is over no sleeve
    @Published var index: Int?
    /// Mouse position inside the hovered tile (nil when selecting with the keyboard)
    @Published var pointer: CGPoint?
    /// Playlist currently playing, filled in a moment after opening
    @Published var playingURI: String?
    /// Mouse position at the last key press: hover is ignored until the mouse actually moves
    var keyboardMouse: NSPoint?

    func isActive(_ item: Library.Item) -> Bool { index == item.id || playingURI == item.entry.uri }
}

/// A spinning record, with inertia: spins up fast, slows down gently
final class Disc: ObservableObject {
    @Published var angle = 0.0
    var speed = 0.0
}

let sleeveSize: CGFloat = 132

/// Cover image, or a green gradient with the initial if there's none
struct CoverArt: View {
    let item: Library.Item

    var body: some View {
        if let image = item.cover {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [spotifyGreen, Color(red: 0.05, green: 0.25, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Text(item.name.prefix(1).uppercased()).font(.system(size: 44, weight: .heavy)).foregroundColor(.white.opacity(0.9)))
        }
    }
}

/// Vinyl record: grooves, center label with the cover, fixed light reflections
struct Vinyl: View {
    let item: Library.Item
    let size: CGFloat
    @ObservedObject var disc: Disc

    var body: some View {
        ZStack {
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(white: 0.13), Color(white: 0.07)], center: .center, startRadius: 0, endRadius: size / 2))
                Grooves()
                CoverArt(item: item)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
            }
            .rotationEffect(.degrees(disc.angle))
            // Reflections stay still, like a real light source
            Circle()
                .fill(AngularGradient(
                    colors: [.white.opacity(0), .white.opacity(0.24), .white.opacity(0), .white.opacity(0),
                             .white.opacity(0.18), .white.opacity(0), .white.opacity(0)],
                    center: .center, angle: .degrees(-30)))
                .mask(Circle().strokeBorder(lineWidth: size * 0.31).padding(size * 0.005))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            // Spindle hole
            Circle().fill(Color(white: 0.02)).frame(width: size * 0.035, height: size * 0.035)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.6), radius: 6, x: 2, y: 3)
    }
}

struct Grooves: View {
    var body: some View {
        Canvas { ctx, canvas in
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let outer = canvas.width / 2 - 2
            var r = canvas.width * 0.2
            var i = 0
            while r < outer {
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(i % 3 == 0 ? 0.13 : 0.06)), lineWidth: 0.5)
                r += 1.6
                i += 1
            }
            // Smooth bands between tracks
            for f in [0.55, 0.72, 0.86] {
                let rr = outer * f
                let rect = CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.7)), lineWidth: 1.5)
            }
        }
        .drawingGroup()
    }
}

/// Cardboard sleeve: soft sheen, open edge on the right
struct Sleeve: View {
    let item: Library.Item
    let selected: Bool
    /// Where the light falls on the sleeve (0…1)
    let light: UnitPoint

    var body: some View {
        CoverArt(item: item)
            .frame(width: sleeveSize, height: sleeveSize)
            .clipped()
            .overlay(LinearGradient(colors: [.white.opacity(0.14), .clear, .clear, .black.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                // Lamp reflection following the mouse
                RadialGradient(colors: [.white.opacity(selected ? 0.3 : 0), .white.opacity(0)], center: light, startRadius: 0, endRadius: sleeveSize * 0.75)
                    .blendMode(.screen)
            )
            .overlay(
                // Shadow of the opening on the record side
                HStack { Spacer(); LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .leading, endPoint: .trailing).frame(width: 6) }
            )
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(selected ? 0.7 : 0.45), radius: selected ? 16 : 7, x: 0, y: selected ? 10 : 4)
    }
}

struct Tile: View {
    let item: Library.Item
    let disc: Disc
    let selected: Bool
    let playing: Bool
    let pointer: CGPoint?

    var body: some View {
        let out = selected || playing
        // Light and tilt follow the mouse; neutral position with the keyboard
        let nx: Double = pointer.map { Double(min(max($0.x / sleeveSize, 0), 1)) } ?? 0.3
        let ny: Double = pointer.map { Double(min(max($0.y / sleeveSize, 0), 1)) } ?? 0.2
        let tilt = selected && pointer != nil

        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .leading) {
                Vinyl(item: item, size: sleeveSize * 0.95, disc: disc)
                    .offset(x: out ? sleeveSize * 0.5 : sleeveSize * 0.2)
                Sleeve(item: item, selected: selected, light: UnitPoint(x: nx, y: ny))
                    .rotation3DEffect(.degrees(tilt ? (nx - 0.5) * 14 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .rotation3DEffect(.degrees(tilt ? (0.5 - ny) * 14 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                    .animation(.easeOut(duration: 0.15), value: pointer)
            }
            .frame(width: sleeveSize * 1.5, height: sleeveSize, alignment: .leading)
            HStack(spacing: 6) {
                if playing { PlayingDot() }
                Text(item.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundColor(.white.opacity(out ? 0.95 : 0.6))
                    .lineLimit(1)
            }
            .frame(width: sleeveSize, alignment: .leading)
        }
        .offset(y: selected ? -4 : 0)
        .saturation(out ? 1 : 0.85)
        .brightness(out ? 0 : -0.06)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: out)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: selected)
    }
}

/// Small glowing green dot next to the playlist that's playing
struct PlayingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(spotifyGreen)
            .frame(width: 7, height: 7)
            .shadow(color: spotifyGreen, radius: pulse ? 7 : 3)
            .background(Circle().fill(spotifyGreen.opacity(0.35)).scaleEffect(pulse ? 2.6 : 1).opacity(pulse ? 0 : 1))
            .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
            .transition(.scale.combined(with: .opacity))
    }
}

struct PickerView: View {
    @ObservedObject var library: Library
    @ObservedObject var selection: Selection
    let discs: [Disc]
    let columns: Int
    let onPick: (Library.Item) -> Void
    @State private var appeared = false

    var body: some View {
        let tint = selection.index.map { library.items[$0].tint } ?? .clear
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(sleeveSize * 1.5), spacing: 18), count: columns), spacing: 26) {
            ForEach(library.items) { item in
                Tile(item: item, disc: discs[item.id],
                     selected: selection.index == item.id,
                     playing: selection.playingURI == item.entry.uri,
                     pointer: selection.index == item.id ? selection.pointer : nil)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            // A tile moving under a still mouse must not steal the keyboard selection
                            if let k = selection.keyboardMouse {
                                if k == NSEvent.mouseLocation { return }
                                selection.keyboardMouse = nil
                            }
                            selection.index = item.id
                            selection.pointer = location
                        case .ended:
                            if selection.keyboardMouse == NSEvent.mouseLocation { return }
                            if selection.index == item.id {
                                selection.index = nil
                                selection.pointer = nil
                            }
                        }
                    }
                    .onTapGesture { onPick(item) }
                    // Cascade in, left to right then row by row
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
                    .scaleEffect(appeared ? 1 : 0.9)
                    .animation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.05 + Double(item.id) * 0.045), value: appeared)
            }
        }
        .padding(.top, 30)
        .padding(.bottom, 24)
        .padding(.leading, 30)
        .padding(.trailing, 12)
        .background(
            ZStack {
                VisualEffect()
                LinearGradient(colors: [Color(white: 0.2).opacity(0.85), Color(white: 0.11).opacity(0.92)], startPoint: .top, endPoint: .bottom)
                // Ambient glow in the hovered cover's color
                RadialGradient(colors: [tint.opacity(0.42), tint.opacity(0.12), .clear], center: .top, startRadius: 0, endRadius: 650)
                    .blendMode(.plusLighter)
                    .animation(.easeInOut(duration: 0.6), value: selection.index)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .fixedSize()
        .onAppear { appeared = true }
    }
}

// MARK: - Window

final class PickerController {
    private var panel: Panel?
    private var library: Library!
    private var selection = Selection()
    private var discs: [Disc] = []
    private var columns = 5
    private var monitors: [Any] = []
    private var timer: Timer?
    /// Called with the chosen playlist
    var onPick: (PlaylistEntry) -> Void = { _ in }
    /// Playlist launched last, to mark it as playing
    var playingURI: () -> String? = { nil }

    var isOpen: Bool { panel != nil }

    func toggle(_ playlists: [PlaylistEntry]) {
        if isOpen { close() } else { show(playlists) }
    }

    func show(_ playlists: [PlaylistEntry]) {
        library = Library(playlists)
        library.refresh()
        selection = Selection()
        discs = playlists.map { _ in Disc() }
        columns = min(5, playlists.count)
        // For screenshots: CRATE_SELECT=3 opens with the 3rd playlist selected, CRATE_DEMO=1 walks through them
        let env = ProcessInfo.processInfo.environment
        if let preset = env["CRATE_SELECT"].flatMap(Int.init), preset > 0, preset <= playlists.count {
            selection.index = preset - 1
            selection.keyboardMouse = NSEvent.mouseLocation
        }
        if env["CRATE_DEMO"] != nil {
            let selection = self.selection
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { [weak self] timer in
                    guard self?.selection === selection, self?.isOpen == true else { return timer.invalidate() }
                    selection.index = ((selection.index ?? -1) + 1) % playlists.count
                    selection.keyboardMouse = NSEvent.mouseLocation
                }
            }
        }

        let host = HostingView(rootView: PickerView(library: library, selection: selection, discs: discs, columns: columns) { [weak self] item in
            self?.pick(item.entry)
        })
        host.frame.size = host.fittingSize
        let panel = Panel(content: host)
        let f = screenUnderMouse()
        panel.setFrameOrigin(NSPoint(x: f.midX - host.frame.width / 2, y: f.midY - host.frame.height / 2 + f.height * 0.08))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        panel.fadeIn()
        self.panel = panel

        startTurntables()
        markPlaying()
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) == true ? nil : event
            } as Any,
            // Clicking outside cancels
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() } as Any,
        ]
    }

    func close() {
        guard let panel else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        panel.orderOut(nil)
        self.panel = nil
        // Give the focus back to the app that was in front
        NSApp.hide(nil)
    }

    private func pick(_ entry: PlaylistEntry) {
        close()
        onPick(entry)
    }

    /// Spins the active records at 33 rpm (200°/s); the others slow down to a stop
    private func startTurntables() {
        var last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            let dt = now - last
            last = now
            for item in self.library.items {
                let disc = self.discs[item.id]
                let target = self.selection.isActive(item) ? 200.0 : 0
                let rate = target > disc.speed ? 5.0 : 0.9   // quick spin-up, slow ~3 s stop
                disc.speed += (target - disc.speed) * min(1, dt * rate)
                if disc.speed < 1 && target == 0 { disc.speed = 0 }
                if disc.speed > 0 { disc.angle = (disc.angle + disc.speed * dt).truncatingRemainder(dividingBy: 360) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Asks Spotify whether it's playing, without delaying the opening
    private func markPlaying() {
        guard let uri = playingURI(), Spotify.isRunning else { return }
        let selection = self.selection
        Spotify.queue.async {
            guard Spotify.isPlaying() else { return }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { selection.playingURI = uri }
            }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let count = library.items.count
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "," {
            close()
            openConfig()
            return true
        }
        // Nothing selected: the first arrow selects the first sleeve
        if selection.index == nil && [123, 124, 125, 126].contains(event.keyCode) {
            selection.index = 0
            selection.keyboardMouse = NSEvent.mouseLocation
            return true
        }
        var i = selection.index ?? 0
        switch event.keyCode {
        case 53: close(); return true                          // esc
        case 36, 76, 49:                                       // return, keypad enter, space
            if let index = selection.index { pick(library.items[index].entry) }
            return true
        case 123: i = (i - 1 + count) % count                  // ←
        case 124: i = (i + 1) % count                          // →
        case 126: i = i - columns >= 0 ? i - columns : i       // ↑
        case 125: i = i + columns < count ? i + columns : i    // ↓
        default:
            // Physical keys 1…0 (top row, then keypad): also works on AZERTY without Shift
            let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
            let keypadKeys: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82]
            if !event.modifierFlags.contains(.command),
               let target = digitKeys.firstIndex(of: event.keyCode) ?? keypadKeys.firstIndex(of: event.keyCode), target < count {
                pick(library.items[target].entry)
                return true
            }
            return false
        }
        selection.index = i
        selection.pointer = nil
        selection.keyboardMouse = NSEvent.mouseLocation
        return true
    }
}
