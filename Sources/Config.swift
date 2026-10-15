import AppKit
import Carbon

/// A playlist (or album / artist) from config.txt
struct PlaylistEntry: Equatable {
    /// Name written in config.txt, if any
    let name: String?
    /// spotify:playlist:<id>
    let uri: String
    var id: String { String(uri.split(separator: ":").last ?? "") }
    var webURL: String {
        let parts = uri.split(separator: ":")
        return "https://open.spotify.com/\(parts[1])/\(parts[2])"
    }
}

/// A global keyboard shortcut, by physical key (US layout position)
struct HotKey: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let text: String
}

struct Config: Equatable {
    static let actions = ["picker", "lyrics", "next"]
    static let defaultShortcuts = ["picker": "cmd+option+0", "lyrics": "cmd+option+-", "next": "cmd+option+="]

    var playlists: [PlaylistEntry] = []
    var shortcuts: [String: HotKey] = [:]
    /// Lines that couldn't be understood, to tell the user
    var problems: [String] = []
    /// config.txt exists but macOS won't let Crate read it (folder protected by privacy settings)
    var unreadable = false

    static func load() -> Config {
        var config = Config()
        var shortcutText = defaultShortcuts
        let text: String
        do {
            text = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            config.unreadable = FileManager.default.fileExists(atPath: configURL.path)
            text = ""
        }
        var section = "playlists"
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            if section == "shortcuts" {
                guard let eq = line.firstIndex(of: "=") else { config.problems.append(line); continue }
                let action = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                guard actions.contains(action) else { config.problems.append(line); continue }
                shortcutText[action] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            } else if let entry = parsePlaylist(line) {
                config.playlists.append(entry)
            } else {
                config.problems.append(line)
            }
        }
        for (action, value) in shortcutText {
            if ["", "none", "off"].contains(value.lowercased()) { continue }
            if let hotKey = parseHotKey(value) {
                config.shortcuts[action] = hotKey
            } else {
                config.problems.append("\(action) = \(value)")
            }
        }
        return config
    }

    /// "Chill = https://open.spotify.com/playlist/abc?si=…" -> name "Chill", uri "spotify:playlist:abc"
    static func parsePlaylist(_ line: String) -> PlaylistEntry? {
        let pattern = #"(?:spotify:|open\.spotify\.com/(?:intl-[a-zA-Z-]+/)?)(playlist|album|artist)[/:]([A-Za-z0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let link = Range(match.range, in: line),
              let kind = Range(match.range(at: 1), in: line), let id = Range(match.range(at: 2), in: line) else { return nil }
        // The name is whatever comes before the link (minus the "https://" stuck to it)
        let before = line[..<link.lowerBound]
        let name = (before.lastIndex(where: \.isWhitespace).map { String(before[..<$0]) } ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "=:|-–—").union(.whitespaces))
        return PlaylistEntry(name: name.isEmpty ? nil : name, uri: "spotify:\(line[kind]):\(line[id])")
    }

    /// "cmd+option+0" -> HotKey ; nil if it can't be understood
    static func parseHotKey(_ text: String) -> HotKey? {
        var modifiers: UInt32 = 0
        var keyCode: Int?
        for part in text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "option", "opt", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            default:
                guard keyCode == nil, let code = keyCodes[part] else { return nil }
                keyCode = code
            }
        }
        guard let keyCode, modifiers != 0 else { return nil }
        return HotKey(keyCode: UInt32(keyCode), modifiers: modifiers, text: text)
    }

    /// Physical keys, named after their US-layout character
    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]
}

extension HotKey {
    /// How the shortcut reads on this Mac's keyboard layout, e.g. "⌘⌥à" on AZERTY for cmd+option+0
    var symbol: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (HotKey.character(for: keyCode) ?? text.split(separator: "+").last.map(String.init)?.uppercased() ?? "?")
    }

    private static func character(for keyCode: UInt32) -> String? {
        let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
                                    kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
                                    kVK_F11: "F11", kVK_F12: "F12"]
        if let name = named[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
