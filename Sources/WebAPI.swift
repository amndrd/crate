import AppKit
import CryptoKit
import Network
import SystemConfiguration

/// Optional link to Spotify's Web API, for Premium accounts that ran `Crate connect`.
/// A playlist started from the API leaves the Spotify window alone, where AppleScript's `play track`
/// always brings it to the front. Without a connection, or if the API fails, Crate falls back to AppleScript.
/// Calls block until Spotify answers: run them on `Spotify.queue`.
enum WebAPI {
    static let redirectURI = "http://127.0.0.1:8888/callback"
    private static let scopes = "user-read-playback-state user-modify-playback-state"
    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Crate")
    private static let tokensURL = folder.appendingPathComponent("spotify.json")

    private struct Tokens: Codable {
        let clientID: String
        var accessToken: String
        var refreshToken: String
        /// Unix time
        var expiresAt: Double
        enum CodingKeys: String, CodingKey {
            case clientID = "client_id", accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at"
        }
    }

    static var isConnected: Bool { FileManager.default.fileExists(atPath: tokensURL.path) }

    private static func loadTokens() -> Tokens? {
        (try? Data(contentsOf: tokensURL)).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
    }

    private static func save(_ tokens: Tokens) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? data.write(to: tokensURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokensURL.path)
    }

    // MARK: Playback

    /// This Mac's id in Spotify's device list
    private static var deviceID: String?
    private static var warnedPremium = false

    /// Starts a playlist, album or artist on shuffle on this Mac.
    /// false if the API can't do it (not connected, offline, not Premium…): play it through AppleScript then.
    static func play(_ uri: String) -> Bool {
        guard isConnected else { return false }
        for _ in 0..<2 {
            guard let device = deviceID ?? findThisMac() else {
                log("Web API: this Mac isn't in Spotify's devices")
                return false
            }
            deviceID = device
            // Picked again while it plays: the API would restart it on the same song, so skip to another one instead
            if isPlaying(uri) {
                let status = api("POST", "/me/player/next?device_id=\(device)").status
                if !(200..<300).contains(status) { log("Web API next: \(status)") }
                return (200..<300).contains(status)
            }
            // Shuffle first, so the playlist doesn't start on its first song. Spotify only takes it from the active device
            if api("PUT", "/me/player/shuffle?state=true&device_id=\(device)").status == 404 {
                _ = api("PUT", "/me/player", body: ["device_ids": [device], "play": false])
                Thread.sleep(forTimeInterval: 0.5)
                _ = api("PUT", "/me/player/shuffle?state=true&device_id=\(device)")
            }
            let (status, data) = api("PUT", "/me/player/play?device_id=\(device)", body: ["context_uri": uri])
            if (200..<300).contains(status) {
                // Spotify sometimes says yes and the app doesn't follow: check it really started
                for _ in 0..<10 {
                    Thread.sleep(forTimeInterval: 0.3)
                    if isPlaying(uri) { return true }
                }
                log("Web API: Spotify accepted \(uri) but didn't start it")
                return false
            }
            log("Web API play: \(status) \(String(decoding: data, as: UTF8.self))")
            if status == 404 { deviceID = nil; continue }   // Spotify gave this Mac a new id: look it up again
            if status == 403, !warnedPremium {
                warnedPremium = true
                Toast.show(L("Spotify's API needs Premium to start playlists: Crate uses the app instead",
                             "L'API de Spotify demande Premium pour lancer une playlist : Crate passe par l'app"),
                           symbol: "exclamationmark.triangle.fill")
            }
            return false
        }
        return false
    }

    /// Whether Spotify is playing this playlist, album or artist right now
    private static func isPlaying(_ uri: String) -> Bool {
        let (status, data) = api("GET", "/me/player")
        guard status == 200, let player = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return player["is_playing"] as? Bool == true && (player["context"] as? [String: Any])?["uri"] as? String == uri
    }

    /// This Mac in the list of Spotify devices. It shows up a few seconds after Spotify starts
    private static func findThisMac() -> String? {
        let names = Set([SCDynamicStoreCopyComputerName(nil, nil) as String?, ProcessInfo.processInfo.hostName.components(separatedBy: ".").first]
            .compactMap { $0?.lowercased() })
        for _ in 0..<20 {
            let (status, data) = api("GET", "/me/player/devices")
            guard status == 200 else { return nil }
            let devices = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["devices"] as? [[String: Any]] ?? []
            let computers = devices.filter { $0["type"] as? String == "Computer" }
            let mac = computers.first { names.contains(($0["name"] as? String ?? "").lowercased()) } ?? (computers.count == 1 ? computers[0] : nil)
            if let id = mac?["id"] as? String { return id }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    // MARK: Requests

    /// Calls the Web API. Status 0: not connected, or Spotify couldn't be reached
    private static func api(_ method: String, _ path: String, body: [String: Any]? = nil) -> (status: Int, data: Data) {
        var result = (status: 0, data: Data())
        for forceRefresh in [false, true] {
            guard let token = accessToken(forceRefresh: forceRefresh) else { return result }
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!, timeoutInterval: 5)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            } else if method != "GET" {
                request.httpBody = Data()   // Spotify wants a Content-Length, even when there's nothing to send
            }
            result = send(request)
            if result.status != 401 { break }   // 401: the access token is no longer valid, get a new one once
        }
        return result
    }

    /// A valid access token, refreshed when it's about to expire
    private static func accessToken(forceRefresh: Bool) -> String? {
        guard var tokens = loadTokens() else { return nil }
        if !forceRefresh, Date().timeIntervalSince1970 < tokens.expiresAt - 60 { return tokens.accessToken }
        let (status, json) = tokenRequest(["grant_type": "refresh_token", "refresh_token": tokens.refreshToken, "client_id": tokens.clientID])
        guard let json, let access = json["access_token"] as? String else {
            if status == 400 {
                // Access revoked on Spotify's side, or the developer app was deleted: this connection is dead
                log("Web API: connection refused by Spotify, removing it")
                try? FileManager.default.removeItem(at: tokensURL)
                Toast.show(L("Spotify connection expired: run “Crate connect” again", "Connexion à Spotify expirée : relance « Crate connect »"),
                           symbol: "exclamationmark.triangle.fill")
            }
            return nil
        }
        tokens.accessToken = access
        tokens.expiresAt = Date().timeIntervalSince1970 + (json["expires_in"] as? Double ?? 3600)
        // Spotify replaces the refresh token as it goes: always keep the latest one
        if let refresh = json["refresh_token"] as? String { tokens.refreshToken = refresh }
        save(tokens)
        return access
    }

    private static func tokenRequest(_ params: [String: String]) -> (status: Int, json: [String: Any]?) {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (status, data) = send(request)
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    /// Sends a request and waits for the answer. Status 0 if Spotify couldn't be reached
    private static func send(_ request: URLRequest) -> (status: Int, data: Data) {
        var result = (status: 0, data: Data())
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    // MARK: Connecting (command line)

    static let connectHelp = """
    Connect Crate to Spotify's Web API (Premium only), so starting a playlist never shows the Spotify window:
      1. Go to https://developer.spotify.com/dashboard and click Create app (any name and description).
      2. Redirect URI: \(redirectURI)   API: tick Web API.
      3. Copy the app's Client ID and run:  Crate connect <Client ID>
    """

    /// `Crate connect <client id>`: signs in to Spotify in the browser, then keeps the tokens.
    /// Runs in the command-line process, not in the running Crate, which reads the tokens when it next plays.
    static func connect(clientID: String) -> Never {
        let verifier = randomString(bytes: 48)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomString(bytes: 16)
        var authorize = URLComponents(string: "https://accounts.spotify.com/authorize")!
        authorize.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
        ]

        // Spotify sends the browser back to 127.0.0.1:8888 with a one-time code
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: 8888) else { finish(false, "Can't listen on port 8888.") }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { finish(false, "Can't listen on port 8888 (\(error)). Close what uses it and try again.") }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                // "GET /callback?code=…&state=… HTTP/1.1"
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let query = URLComponents(string: target)
                func value(_ name: String) -> String? { query?.queryItems?.first { $0.name == name }?.value }
                guard query?.path == "/callback", value("state") == state else {
                    return respond(connection, status: "404 Not Found", html: "")
                }
                var tokens: Tokens?
                if let code = value("code") {
                    let (_, json) = tokenRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                                                  "client_id": clientID, "code_verifier": verifier])
                    if let json, let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String {
                        tokens = Tokens(clientID: clientID, accessToken: access, refreshToken: refresh,
                                        expiresAt: Date().timeIntervalSince1970 + (json["expires_in"] as? Double ?? 3600))
                    }
                }
                if let tokens { save(tokens) }
                let message = tokens != nil
                    ? L("Crate is connected to Spotify. You can close this tab.", "Crate est connecté à Spotify. Tu peux fermer cet onglet.")
                    : L("Spotify didn't allow the connection: \(value("error") ?? "unknown error").", "Spotify a refusé la connexion : \(value("error") ?? "erreur inconnue").")
                respond(connection, status: "200 OK", html: "<meta charset=utf-8><body style='font:16px -apple-system;margin:40px'><h2>\(message)</h2>") {
                    finish(tokens != nil, tokens != nil
                           ? "✓ Connected. Crate now starts playlists through Spotify's API: the Spotify window stays out of the way."
                           : "Not connected: \(value("error") ?? "Spotify refused the code"). Check the Client ID and the redirect URI (\(redirectURI)).")
                }
            }
        }
        listener.start(queue: .main)
        print("Opening Spotify in your browser: log in and click Agree…")
        fflush(stdout)
        NSWorkspace.shared.open(authorize.url!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { finish(false, "No answer from the browser after 5 minutes.") }
        dispatchMain()
    }

    /// `Crate disconnect`: forgets the tokens, Crate goes back to AppleScript
    static func disconnect() {
        try? FileManager.default.removeItem(at: tokensURL)
        print("✓ Disconnected. Crate starts playlists through the Spotify app again.")
    }

    private static func respond(_ connection: NWConnection, status: String, html: String, then: (() -> Void)? = nil) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
            then?()
        })
    }

    private static func finish(_ ok: Bool, _ message: String) -> Never {
        FileHandle(fileDescriptor: ok ? 1 : 2).write(Data((message + "\n").utf8))
        exit(ok ? 0 : 1)
    }

    private static func randomString(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
