// Crate: pick a Spotify playlist from a crate of records, see synced lyrics and skip tracks,
// all from global keyboard shortcuts. Works with free Spotify accounts: it drives the desktop app.
//
// Usage:
//   Crate                     runs in the background (started at login by install.sh)
//   Crate picker|lyrics|next  asks the running Crate to open the picker / toggle lyrics / skip
//   Crate play <link>         plays a playlist, album or artist on shuffle
//   Crate config              opens config.txt

import AppKit
import Carbon

let usage = "Usage: Crate [picker | lyrics | next | play <spotify link> | config]"
let commands = ["picker", "lyrics", "next", "config"]

/// Only one Crate runs at a time: it holds this lock
func takeLock() -> Bool {
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let fd = open(cacheDir.appendingPathComponent("crate.lock").path, O_CREAT | O_RDWR, 0o644)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0   // the descriptor stays open as long as Crate runs
}

func send(_ command: String, link: String? = nil) {
    DistributedNotificationCenter.default().postNotificationName(commandNotification, object: command,
                                                                 userInfo: link.map { ["link": $0] }, deliverImmediately: true)
    // Give the notification time to leave before this process exits
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
}

let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first {
    let link = command == "play" && arguments.count == 2 ? arguments[1] : nil
    guard commands.contains(command) && arguments.count == 1 || link.flatMap(Config.parsePlaylist) != nil else { print(usage); exit(1) }
    if command == "config" { openConfig(); exit(0) }
    if takeLock() {
        FileHandle.standardError.write("Crate isn't running. Run ./install.sh in the Crate folder.\n".data(using: .utf8)!)
        exit(1)
    }
    send(command, link: link)
    exit(0)
}

guard takeLock() else {
    // Already running (e.g. Crate.app double-clicked): the running one says hello
    send("hello")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
