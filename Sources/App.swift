import AppKit
import Carbon
import SwiftUI

/// Shortcut id -> action, read by the Carbon hot key handler
private var hotKeyActions: [UInt32: String] = [:]
private weak var shared: AppDelegate?

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config()
    private var configDate: Date?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private let picker = PickerController()
    private let lyrics = LyricsController()
    /// Playlist launched last from the picker
    private var lastPlayed: String? {
        get { UserDefaults.standard.string(forKey: "lastPlayed") }
        set { UserDefaults.standard.set(newValue, forKey: "lastPlayed") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        shared = self
        installHotKeyHandler()
        reloadConfig(announce: false)

        picker.playingURI = { [weak self] in self?.lastPlayed }
        picker.onPick = { [weak self] entry in self?.play(entry) }

        // config.txt is re-read as soon as it's saved
        let watcher = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.reloadConfigIfChanged() }
        RunLoop.main.add(watcher, forMode: .common)

        // Commands from `Crate picker` etc. Delivered even while Crate is in the background
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)), name: commandNotification,
                                                            object: nil, suspensionBehavior: .deliverImmediately)

        if ProcessInfo.processInfo.environment["CRATE_DEMO"] != nil { showDemoBackdrop() }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.perform("hello") }
        }
    }

    @objc private func receive(_ note: Notification) {
        guard let command = note.object as? String else { return }
        log("Command: \(command)")
        if command == "play", let entry = (note.userInfo?["link"] as? String).flatMap(Config.parsePlaylist) {
            play(entry)
        } else {
            perform(command)
        }
    }

    func perform(_ command: String) {
        switch command {
        case "picker":
            if config.playlists.isEmpty {
                Toast.show(L("Add your playlists to config.txt", "Ajoute tes playlists dans config.txt"), symbol: "square.and.pencil")
                openConfig()
            } else {
                picker.toggle(config.playlists)
            }
        case "lyrics":
            lyrics.toggle()
        case "next":
            if Spotify.isRunning { Spotify.next() } else { Toast.show(L("Spotify isn't open", "Spotify n'est pas ouvert"), symbol: "speaker.slash.fill") }
        case "hello":
            let key = config.shortcuts["picker"]?.symbol ?? "?"
            Toast.show(L("Crate is running: press \(key) to pick a playlist", "Crate est lancé : appuie sur \(key) pour choisir une playlist"))
        default:
            break
        }
    }

    private func play(_ entry: PlaylistEntry) {
        lastPlayed = entry.uri
        if !Spotify.isRunning { Toast.show(L("Starting Spotify…", "Lancement de Spotify…")) }
        Spotify.play(entry.uri) { error in
            if let error { Toast.show(error, symbol: "exclamationmark.triangle.fill") }
        }
    }

    /// For screenshots and recordings: a plain wallpaper behind Crate's windows, mouse pointer hidden
    private var backdrop: NSWindow?
    private func showDemoBackdrop() {
        let frame = NSScreen.main?.frame ?? .zero
        let wallpaper = ZStack {
            Color(red: 0.06, green: 0.05, blue: 0.1)
            RadialGradient(colors: [Color(red: 0.45, green: 0.18, blue: 0.5).opacity(0.8), .clear], center: UnitPoint(x: 0.2, y: 0.25), startRadius: 0, endRadius: frame.width * 0.5)
            RadialGradient(colors: [Color(red: 0.05, green: 0.45, blue: 0.4).opacity(0.7), .clear], center: UnitPoint(x: 0.85, y: 0.8), startRadius: 0, endRadius: frame.width * 0.45)
        }
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: wallpaper)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces]
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        backdrop = window
        CGDisplayHideCursor(CGMainDisplayID())
    }

    // MARK: Config

    private func reloadConfigIfChanged() {
        let date = (try? configURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if date != configDate { reloadConfig(announce: true) }
    }

    private func reloadConfig(announce: Bool) {
        configDate = (try? configURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let new = Config.load()
        let shortcutsChanged = new.shortcuts != config.shortcuts || hotKeyRefs.isEmpty
        config = new
        if shortcutsChanged { registerHotKeys() }
        if new.unreadable {
            Toast.show(L("Crate can't open config.txt: move the Crate folder to your home folder and run install.sh again",
                         "Crate n'arrive pas à ouvrir config.txt : déplace le dossier Crate dans ton dossier personnel et relance install.sh"),
                       symbol: "lock.fill")
        } else if let problem = new.problems.first {
            Toast.show(L("config.txt: can't read “\(problem)”", "config.txt : ligne incomprise « \(problem) »"), symbol: "exclamationmark.triangle.fill")
        } else if announce {
            Toast.show(L("\(new.playlists.count) playlists loaded", "\(new.playlists.count) playlists chargées"), symbol: "checkmark.circle.fill")
        }
    }

    // MARK: Global shortcuts (Carbon: work in every app, no Accessibility permission needed)

    private func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let action = hotKeyActions[id.id] { DispatchQueue.main.async { shared?.perform(action) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func registerHotKeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
        hotKeyActions = [:]
        var taken: [String] = []
        for (index, action) in Config.actions.enumerated() {
            guard let hotKey = config.shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, EventHotKeyID(signature: OSType(0x4352_5445), id: UInt32(index)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                hotKeyActions[UInt32(index)] = action
            } else {
                log("Can't register \(action) = \(hotKey.text): \(status)")
                taken.append(hotKey.symbol)
            }
        }
        if !taken.isEmpty {
            Toast.show(L("Shortcut \(taken.joined(separator: ", ")) is used by another app: change it in config.txt",
                         "Raccourci \(taken.joined(separator: ", ")) déjà pris par une autre app : change-le dans config.txt"),
                       symbol: "keyboard")
        }
    }
}
