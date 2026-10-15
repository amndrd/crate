import AppKit
import SwiftUI

let bundleID = Bundle.main.bundleIdentifier ?? "io.github.amndrd.crate"
let commandNotification = Notification.Name(bundleID + ".command")

/// UI strings follow the system language: French if it comes first, English otherwise
let isFrench = Locale.preferredLanguages.first?.hasPrefix("fr") == true
func L(_ english: String, _ french: String) -> String { isFrench ? french : english }

/// Project folder: the one holding Crate.app and config.txt
let projectDir: URL = {
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    var dir = exe.deletingLastPathComponent()
    // .../crate/Crate.app/Contents/MacOS/Crate -> .../crate
    if dir.path.hasSuffix(".app/Contents/MacOS") {
        dir = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    return dir
}()
let configURL = projectDir.appendingPathComponent("config.txt")
let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Crate")

let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.33)

func log(_ message: String) {
    FileHandle.standardError.write("[Crate] \(message)\n".data(using: .utf8)!)
}

func openConfig() {
    if !FileManager.default.fileExists(atPath: configURL.path) {
        let example = projectDir.appendingPathComponent("config.example.txt")
        try? FileManager.default.copyItem(at: example, to: configURL)
    }
    // TextEdit keeps .txt files as plain text
    NSWorkspace.shared.open([configURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                            configuration: NSWorkspace.OpenConfiguration())
}

// MARK: - Windows

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Borderless floating panel that can still receive keyboard input
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }

    convenience init(content: NSView) {
        self.init(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                  styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        contentView = content
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
    }

    func fadeIn(duration: Double = 0.15) {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            animator().alphaValue = 1
        }
    }
}

/// Clicks act right away (× button) even when the panel isn't focused
final class HostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Visible frame of the screen under the mouse
func screenUnderMouse() -> NSRect {
    let mouse = NSEvent.mouseLocation
    return (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
}

// MARK: - Toast

/// Small message at the bottom of the screen that fades away on its own
enum Toast {
    private static var panel: Panel?
    private static var hide: DispatchWorkItem?

    static func show(_ text: String, symbol: String = "music.note") {
        DispatchQueue.main.async {
            panel?.orderOut(nil)
            hide?.cancel()
            let view = HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundColor(spotifyGreen)
                Text(text).font(.system(size: 13, weight: .medium)).foregroundColor(.white).fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(ZStack { VisualEffect(); Color.black.opacity(0.25) })
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .padding(20)   // room for the shadow
            let host = NSHostingView(rootView: view)
            host.frame.size = host.fittingSize
            let p = Panel(content: host)
            p.ignoresMouseEvents = true
            p.hasShadow = false
            let f = screenUnderMouse()
            p.setFrameOrigin(NSPoint(x: f.midX - host.frame.width / 2, y: f.minY + 60))
            p.fadeIn(duration: 0.2)
            panel = p
            let work = DispatchWorkItem {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.4
                    p.animator().alphaValue = 0
                }, completionHandler: { p.orderOut(nil) })
            }
            hide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
        }
    }
}
