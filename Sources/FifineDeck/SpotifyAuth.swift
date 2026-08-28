import AppKit
import CryptoKit
import Foundation
import Network

/// One-off Spotify login for the widget's "web" source.
///
/// Authorization Code flow with PKCE, so no client secret is needed and the
/// only long-lived thing stored is the refresh token. The redirect is caught
/// on a loopback listener that lives exactly as long as the login does.
///
/// You need a Spotify application (developer.spotify.com/dashboard, free) with
/// `http://127.0.0.1:8888/callback` registered as a redirect URI. The default
/// "local" source needs none of this — the login only buys you playback that
/// is happening on another device.
enum SpotifyAuth {
    static let defaultPort: UInt16 = 8888
    static let scope = "user-read-playback-state user-modify-playback-state"
    /// The browser hop has a human in it: time to log in and approve.
    static let timeout: TimeInterval = 300

    static func redirectURI(port: UInt16 = defaultPort) -> String {
        "http://127.0.0.1:\(port)/callback"
    }

    static func form(_ params: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }

    /// Runs the whole flow and stores the refresh token. Throws with a
    /// human-readable message on every failure path.
    static func login(clientID: String, port: UInt16 = defaultPort) async throws {
        let clientID = clientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else { throw WidgetError.message("a client id is required") }

        let verifier = randomVerifier()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomVerifier(length: 24)

        var authorize = URLComponents(string: "https://accounts.spotify.com/authorize")!
        authorize.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI(port: port)),
            .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        guard let url = authorize.url else { throw WidgetError.message("bad client id") }

        let listener = try CallbackListener(port: port)
        defer { listener.stop() }
        NSWorkspace.shared.open(url)
        let query = try await listener.awaitRedirect(timeout: timeout)

        // A redirect we did not start. Refusing it is the entire point of the
        // state parameter: an attacker-supplied code would bind the deck to
        // someone else's account.
        guard query["state"] == state else {
            throw WidgetError.message("the redirect did not match this login")
        }
        guard let code = query["code"] else {
            throw WidgetError.message("Spotify said: \(query["error"] ?? "no code")")
        }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirectURI(port: port), "client_id": clientID,
            "code_verifier": verifier,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WidgetError.message("token exchange failed (HTTP \(http.statusCode))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refresh = json["refresh_token"] as? String
        else { throw WidgetError.message("no refresh token in the response") }

        WidgetCredentials.set([.spotifyClientID: clientID, .spotifyRefreshToken: refresh])
    }

    private static func randomVerifier(length: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    /// base64url, unpadded — what PKCE and OAuth state want.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A loopback HTTP listener that answers exactly one redirect and stops.
///
/// `@unchecked Sendable` because the connection handler runs on the listener's
/// own queue while `awaitRedirect` waits on the caller's: every piece of
/// mutable state here is behind `lock`, which is exactly the contract the
/// compiler cannot verify for us.
private final class CallbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fifine.spotify.callback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    /// A result that landed before anyone was waiting for it. The listener is
    /// started before the continuation is installed, so a redirect that
    /// arrives in that window has to be held, not dropped.
    private var pending: Result<[String: String], Error>?
    private var finished = false
    private let lock = NSLock()

    init(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw WidgetError.message("bad port")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw WidgetError.message("port \(port) is busy — close whatever is using it")
        }
    }

    func awaitRedirect(timeout: TimeInterval) async throws -> [String: String] {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let query = Self.parse(request)
                let ok = query["code"] != nil
                let body = Self.page(ok: ok, error: query["error"])
                let response = """
                HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                self?.finish(.success(query))
            }
        }
        listener.start(queue: queue)

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(WidgetError.message("timed out waiting for Spotify")))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pending {
                // The listener already answered. Hand that over rather than
                // waiting for a second redirect that will never come.
                finished = true
                self.pending = nil
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// Resumes the continuation at most once, whichever of the redirect, the
    /// timeout, or a teardown gets here first.
    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard let continuation else {
            pending = result            // nobody waiting yet; hold it
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func stop() {
        listener.cancel()
        finish(.failure(WidgetError.message("login cancelled")))
    }

    private static func parse(_ request: String) -> [String: String] {
        guard let line = request.split(separator: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1" + path)
        else { return [:] }
        var out: [String: String] = [:]
        for item in components.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }

    private static func page(ok: Bool, error: String?) -> String {
        let title = ok ? "Spotify connected" : "Spotify login failed"
        let body = ok
            ? "You can close this tab and go back to the deck."
            : "The deck did not receive an authorization code. Spotify said: \(error ?? "nothing")."
        return """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <body style="font-family:system-ui;background:#101014;color:#eee;padding:3rem">
        <h2>\(title)</h2><p>\(body)</p></body>
        """
    }
}
