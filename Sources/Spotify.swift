import AppKit

/// What Spotify is playing, read from the desktop app
struct NowPlaying: Equatable {
    let id: String
    let name: String
    let artist: String
    let album: String
    /// Seconds
    let duration: Double
    let position: Double
    let isPlaying: Bool
    let artworkURL: String?
    var isAd: Bool { id.hasPrefix("spotify:ad:") }
}

/// Talks to the Spotify desktop app through AppleScript: no account, no API key, no Premium needed.
/// Every call runs on `queue`, one at a time.
enum Spotify {
    static let bundleID = "com.spotify.client"
    static let queue = DispatchQueue(label: "crate.spotify")
    /// Last AppleScript error number (-1743 = the user hasn't allowed Crate to control Spotify)
    private(set) static var lastError: Int?
    private static var compiled: [String: NSAppleScript] = [:]

    static var app: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first }
    static var isRunning: Bool { app != nil }
    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    /// Runs AppleScript code, returns its result or nil on error. Call on `queue`.
    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        dispatchPrecondition(condition: .onQueue(queue))
        let script = compiled[source] ?? NSAppleScript(source: source)!
        compiled[source] = script
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            lastError = error[NSAppleScript.errorNumber] as? Int
            if (error[NSAppleScript.errorMessage] as? String) != "not yet" { log("AppleScript error \(lastError ?? 0): \(error[NSAppleScript.errorMessage] ?? "")") }
            if lastError == -1743 { showPermissionHelp() }
            return nil
        }
        lastError = nil
        return result
    }

    /// Wraps code so it never launches Spotify by accident
    private static func ifRunning(_ body: String, otherwise: String = "return") -> String {
        """
        if application id "\(bundleID)" is not running then \(otherwise)
        tell application id "\(bundleID)"
        \(body)
        end tell
        """
    }

    static func showPermissionHelp() {
        Toast.show(L("Allow Crate to control Spotify: System Settings › Privacy & Security › Automation",
                     "Autorise Crate à contrôler Spotify : Réglages › Confidentialité et sécurité › Automatisation"),
                   symbol: "lock.fill")
    }

    // MARK: Playback

    /// Plays a playlist on shuffle, launching Spotify hidden if needed. Calls `done` with an error message, or nil.
    static func play(_ uri: String, done: @escaping (String?) -> Void) {
        queue.async {
            if !isRunning {
                guard launchHidden() else {
                    return done(L("Spotify isn't installed: get it at spotify.com/download",
                                  "Spotify n'est pas installé : spotify.com/download"))
                }
                // Wait until Spotify answers (up to 30 s)
                var ready = false
                for _ in 0..<100 {
                    if run(ifRunning("return player state", otherwise: "error \"not yet\"")) != nil { ready = true; break }
                    if lastError == -1743 { return done(nil) }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                guard ready else { return done(L("Spotify is taking too long to start", "Spotify met trop de temps à démarrer")) }
                Thread.sleep(forTimeInterval: 0.5)
            }
            for _ in 0..<3 {
                run(ifRunning("""
                set shuffling to true
                play track "\(uri)"
                """))
                if lastError == -1743 { return done(nil) }
                Thread.sleep(forTimeInterval: 1.2)
                // Spotify may reset shuffle when the playlist changes, or ignore the very first command after launch
                let state = run(ifRunning("""
                if not shuffling then set shuffling to true
                if sound volume is 0 then set sound volume to 50
                return player state is playing
                """, otherwise: "return false"))
                if state?.booleanValue == true { break }
            }
            unmuteMac()
            done(nil)
        }
    }

    static func next() {
        queue.async { run(ifRunning("next track")) }
    }

    static func seek(to seconds: Double) {
        queue.async { run(ifRunning("set player position to \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds))")) }
    }

    static func isPlaying() -> Bool {
        run(ifRunning("return player state is playing", otherwise: "return false"))?.booleanValue == true
    }

    /// Current track, or nil if nothing is loaded. Call on `queue`.
    static func nowPlaying() -> NowPlaying? {
        guard let d = run(ifRunning("""
        if player state is stopped then return {}
        set t to current track
        return {id of t, name of t, artist of t, album of t, duration of t, player position, player state is playing, artwork url of t}
        """, otherwise: "return {}")), d.numberOfItems == 8 else { return nil }
        func text(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        return NowPlaying(id: text(1), name: text(2), artist: text(3), album: text(4),
                          duration: Double(d.atIndex(5)?.int32Value ?? 0) / 1000,
                          position: d.atIndex(6)?.doubleValue ?? 0,
                          isPlaying: d.atIndex(7)?.booleanValue ?? false,
                          artworkURL: d.atIndex(8)?.stringValue)
    }

    // MARK: Helpers

    /// Opens Spotify without showing it, then keeps it hidden while it finishes loading
    private static func launchHidden() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        let launched = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in launched.signal() }
        launched.wait()
        DispatchQueue.main.async {
            // Spotify likes to pop its window up when it's done loading
            let start = CACurrentMediaTime()
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
                if let app, !app.isHidden { app.hide() }
                if CACurrentMediaTime() - start > 10 { timer.invalidate() }
            }
        }
        return true
    }

    /// Turns the Mac's sound back on if it's muted or at 0
    private static func unmuteMac() {
        run("""
        try
            set v to get volume settings
            if output muted of v then set volume without output muted
            if output volume of v is 0 then set volume output volume 50
        end try
        """)
    }
}
