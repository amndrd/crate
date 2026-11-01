import AppKit
import SwiftUI

// When a new song starts: a capsule in the top-right corner, under the menu bar, with the record,
// the title, the artist and bars in the cover's color. It leaves on its own after a few seconds.

struct SongCapsule: View {
    let track: NowPlaying
    let cover: NSImage?
    let tint: Color

    /// Room around the capsule for its shadow
    static let margin = EdgeInsets(top: 8, leading: 24, bottom: 32, trailing: 24)

    var body: some View {
        HStack(spacing: 12) {
            RecordDisc(cover: cover, size: 44)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name).font(.system(size: 13.5, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text(track.artist).font(.system(size: 12)).foregroundColor(.white.opacity(0.66)).lineLimit(1)
            }
            .frame(maxWidth: 240, alignment: .leading)
            EqualizerBars(color: tint, playing: true, glow: true)
                .padding(.leading, 4)
        }
        .padding(.leading, 8)
        .padding(.trailing, 22)
        .frame(height: 60)
        .background(ZStack { VisualEffect(); Color.black.opacity(0.3) })
        .clipShape(Capsule())
        // Light catching the top-left and bottom-right edges, like glass
        .overlay(Capsule().strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.42), location: 0),
                                                              .init(color: .white.opacity(0.1), location: 0.32),
                                                              .init(color: .white.opacity(0.04), location: 0.68),
                                                              .init(color: .white.opacity(0.22), location: 1)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .padding(Self.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Now playing: \(track.name), \(track.artist)", "En lecture : \(track.name), \(track.artist)"))
    }
}

final class CapsuleController {
    private var panel: Panel?
    private var hide: DispatchWorkItem?
    private let duration = 4.5

    func show(track: NowPlaying, cover: NSImage?, tint: Color) {
        hide?.cancel()
        panel?.orderOut(nil)

        let host = NSHostingView(rootView: SongCapsule(track: track, cover: cover, tint: tint))
        host.frame.size = host.fittingSize
        let panel = Panel(content: host)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        // Top-right of the screen under the mouse, 9 pt under the menu bar, 12 pt from the edge
        let visible = screenUnderMouse()
        let size = host.frame.size
        let frame = NSRect(x: visible.maxX - size.width + SongCapsule.margin.trailing - 12,
                           y: visible.maxY - size.height + SongCapsule.margin.top - 9,
                           width: size.width, height: size.height)
        // Comes down a little while fading in
        panel.setFrame(frame.offsetBy(dx: 0, dy: 10), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                panel.animator().alphaValue = 0
                panel.animator().setFrame(frame.offsetBy(dx: 0, dy: 6), display: true)
            }, completionHandler: {
                panel.orderOut(nil)
                if self?.panel === panel { self?.panel = nil }
            })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
