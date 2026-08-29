import AppKit
import Foundation

/// Spotify "now playing": album art, track and artist, and a progress bar,
/// painted across one key or a block of them.
///
/// Two sources, because the two have different reach:
///   local — the Spotify app on this Mac, over AppleScript. No credentials,
///           nothing to set up, and it is what the deck should use by default.
///   web   — the Spotify Web API. Needs a one-off login, but follows playback
///           on ANY device, so the deck keeps showing the track while it plays
///           on a phone.
/// "auto" prefers the Web API when a login exists and falls back to the local
/// app, then to an honest "nothing playing" face.

// MARK: - Data

struct SpotifyNowPlaying {
    var ok = false
    var playing = false
    var title = ""
    var artist = ""
    var album = ""
    var artURL = ""
    var progressMS = 0
    var durationMS = 0
    var source = ""
    var error = ""
    var art: CGImage? = nil
    var accent: NSColor = WidgetPaint.green

    var hasTrack: Bool { !title.isEmpty || !artist.isEmpty }

    /// Progress is bucketed to whole seconds: a 1 s widget must not rewrite
    /// the key for every millisecond of drift.
    var signature: String {
        "\(ok)|\(playing)|\(title)|\(artist)|\(album)|\(artURL)|\(durationMS)|\(progressMS / 1000)|\(error)"
    }
}

// MARK: - Provider

actor SpotifyProvider {
    private var artCache: [String: CGImage] = [:]
    private var artOrder: [String] = []
    private var artFailed: Set<String> = []
    private var accessToken: String = ""
    private var tokenExpires: Date = .distantPast

    private static let artCacheLimit = 6
    private static let timeout: TimeInterval = 6
    private static let maximumArtBytes = 4 * 1024 * 1024

    static var webConfigured: Bool {
        WidgetCredentials.has(.spotifyClientID) && WidgetCredentials.has(.spotifyRefreshToken)
    }

    func fetch(_ config: WidgetConfig) async -> SpotifyNowPlaying {
        var state = await poll(config)
        if !state.artURL.isEmpty {
            state.art = await artwork(state.artURL)
        }
        if let art = state.art {
            state.accent = WidgetPaint.accent(from: art)
        }
        return state
    }

    private func poll(_ config: WidgetConfig) async -> SpotifyNowPlaying {
        let wantsWeb = config.source == "web"
            || (config.source == "auto" && Self.webConfigured)
        if wantsWeb {
            do {
                return try await webNowPlaying()
            } catch {
                if config.source == "web" {
                    return SpotifyNowPlaying(ok: false, source: "web",
                                             error: Self.describe(error))
                }
                // auto: the login is stale or the network is down — the local
                // app may still know what it is playing.
            }
        }
        // Neither path is available: with no desktop app to ask and no account
        // connected, "no Spotify app" would send the user hunting for an
        // installer they may not want. Name the fix that works either way.
        if config.source == "auto", !Self.localAppInstalled, !Self.webConfigured {
            return SpotifyNowPlaying(ok: false, source: "auto",
                                     error: "connect account")
        }
        return Self.localNowPlaying()
    }

    // MARK: Local (the Spotify app over AppleScript)

    /// Separator: a track title can contain any punctuation, but not an ASCII
    /// unit separator.
    ///
    /// Two deliberate choices in here:
    ///
    /// - The play state comes back as "true"/"false" from `player state is
    ///   playing`, not as `player state as string`. The string form yields the
    ///   raw four-character codes (`kPSP` playing, `kPSp` paused) on some
    ///   builds, and those differ only in case — so a case-insensitive
    ///   comparison would read every paused track as playing, and a
    ///   case-sensitive one would break on the builds that spell it out.
    /// - The artwork is fetched in its own `try`. Podcasts and local files
    ///   have no `artwork url`, and one shared `try` would turn a perfectly
    ///   readable track into "nothing playing".
    private static let script = """
    if application "Spotify" is running then
        set sep to (ASCII character 31)
        tell application "Spotify"
            try
                set t to current track
                set aw to ""
                try
                    set aw to (artwork url of t)
                end try
                set isPlaying to "false"
                try
                    if player state is playing then set isPlaying to "true"
                end try
                return isPlaying & sep & (name of t) & sep & (artist of t) & sep & ¬
                    (album of t) & sep & aw & sep & ((duration of t) as string) & sep & ¬
                    ((player position) as string)
            on error
                return "idle"
            end try
        end tell
    else
        return "idle"
    end if
    """

    /// Whether the Spotify desktop app exists on this Mac at all.
    ///
    /// Checked BEFORE running the script, because a `tell application
    /// "Spotify"` block is compiled against that app's scripting dictionary:
    /// with no app installed, `current track` is not a known term and
    /// osascript fails with a *syntax* error (-2741) that looks nothing like
    /// "the app is missing".
    nonisolated static var localAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    nonisolated static func localNowPlaying() -> SpotifyNowPlaying {
        guard localAppInstalled else {
            return SpotifyNowPlaying(ok: false, source: "local",
                                     error: "no Spotify app")
        }
        let result = runOsascript(script)
        guard let raw = result.output else {
            // Tell the two failures apart: one the user fixes in System
            // Settings, the other they cannot fix there at all.
            let denied = result.stderr.contains("-1743")
                || result.stderr.contains("Not authorized")
            if !result.stderr.isEmpty {
                DeckLog.write(String(format: "fifine: Spotify AppleScript failed: %@", result.stderr))
            }
            return SpotifyNowPlaying(ok: false, source: "local",
                                     error: denied ? "allow access" : "script failed")
        }
        return parseLocal(raw)
    }

    /// Turns one line of the script's output into a reading. Separate from the
    /// subprocess so the contract between the two can actually be tested.
    nonisolated static func parseLocal(_ raw: String) -> SpotifyNowPlaying {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "idle" || trimmed.isEmpty {
            // Spotify is closed or between tracks. That is a successful poll,
            // not a failure.
            return SpotifyNowPlaying(ok: true, playing: false, source: "local")
        }
        let parts = trimmed.components(separatedBy: "\u{1F}")
        guard parts.count >= 7 else {
            return SpotifyNowPlaying(ok: true, playing: false, source: "local")
        }
        // Spotify reports duration in milliseconds and position in seconds.
        let duration = Int(Double(parts[5]) ?? 0)
        let position = Int((Double(parts[6]) ?? 0) * 1000)
        return SpotifyNowPlaying(
            ok: true,
            playing: parts[0] == "true",
            title: parts[1], artist: parts[2], album: parts[3],
            artURL: normalizeArtURL(parts[4]),
            progressMS: position, durationMS: duration, source: "local")
    }

    nonisolated static func command(_ press: String) {
        guard localAppInstalled else {
            DeckLog.write(String(format: "fifine: transport command %@ dropped — no Spotify app", press))
            return
        }
        let verb: String
        switch press {
        case "play_pause": verb = "playpause"
        case "next":       verb = "next track"
        case "previous":   verb = "previous track"
        default:
            DeckLog.write(String(format: "fifine: transport command %@ has no verb", press))
            return
        }
        // The result is checked, not discarded: a command that Spotify refuses
        // looked exactly like one that worked, which is how "next does
        // nothing" became unfalsifiable from the outside.
        let result = runOsascript("""
        if application "Spotify" is running then
            tell application "Spotify" to \(verb)
        end if
        """)
        if result.output == nil {
            DeckLog.write(String(format: "fifine: transport command %@ FAILED: %@", press, result.stderr))
        }
    }

    /// osascript in a subprocess rather than NSAppleScript: NSAppleScript is
    /// not thread-safe and this runs off the main actor on every poll.
    private nonisolated static func runOsascript(_ source: String)
    -> (output: String?, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (nil, "\(error)") }
        // Drain before waiting: a script whose output outgrows the pipe buffer
        // would block forever in waitUntilExit with nobody reading.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // stderr is kept rather than discarded: without it every osascript
        // failure looked identical from the outside, and a missing Spotify app
        // was indistinguishable from a denied Automation permission.
        let stderr = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else { return (nil, stderr) }
        return (String(data: data, encoding: .utf8), stderr)
    }

    /// Older Spotify builds advertise an open.spotify.com/image URL, which is
    /// not a real image endpoint — the CDN one is.
    nonisolated static func normalizeArtURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("open.spotify.com/image/"),
              let id = trimmed.split(separator: "/").last
        else { return trimmed }
        return "https://i.scdn.co/image/\(id)"
    }

    // MARK: Web API

    private func token() async throws -> String {
        if !accessToken.isEmpty, Date() < tokenExpires { return accessToken }
        let clientID = WidgetCredentials.value(.spotifyClientID)
        let refresh = WidgetCredentials.value(.spotifyRefreshToken)
        guard !clientID.isEmpty, !refresh.isEmpty else {
            // Short on purpose: this string gets painted on a 100 px key.
            throw WidgetError.message("not logged in")
        }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SpotifyAuth.form([
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String
        else { throw WidgetError.message("bad token response") }
        accessToken = token
        tokenExpires = Date().addingTimeInterval(max(60, (json["expires_in"] as? Double ?? 3600) - 60))
        // Spotify rotates the refresh token on some flows; persist it or the
        // next refresh after the rotation fails and the widget logs itself out.
        if let rotated = json["refresh_token"] as? String, rotated != refresh {
            WidgetCredentials.set(.spotifyRefreshToken, rotated)
        }
        return token
    }

    private func call(_ method: String, _ path: String,
                      retryOn401: Bool = true) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        request.httpMethod = method
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer " + (try await token()), forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401, retryOn401 {
            // Token rejected mid-flight (revoked, or a scope change). Drop it
            // and try once with a fresh one.
            accessToken = ""; tokenExpires = .distantPast
            return try await call(method, path, retryOn401: false)
        }
        try Self.check(response)
        return data
    }

    private func webNowPlaying() async throws -> SpotifyNowPlaying {
        let data = try await call("GET", "/me/player")
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = json["item"] as? [String: Any]
        else {
            // 204: nothing is playing anywhere. A successful poll.
            return SpotifyNowPlaying(ok: true, playing: false, source: "web")
        }
        let album = item["album"] as? [String: Any] ?? [:]
        let images = (album["images"] as? [[String: Any]] ?? [])
            .sorted { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
        // A key is 100 px, so the smallest image at or above 200 px is plenty
        // and downloads in a fraction of the time of the 640 px one.
        var artURL = images.last?["url"] as? String ?? ""
        for image in images where (image["width"] as? Int ?? 0) >= 200 {
            artURL = image["url"] as? String ?? artURL
            break
        }
        let artists = (item["artists"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        return SpotifyNowPlaying(
            ok: true,
            playing: json["is_playing"] as? Bool ?? false,
            title: item["name"] as? String ?? "",
            artist: artists.joined(separator: ", "),
            album: album["name"] as? String ?? "",
            artURL: artURL,
            progressMS: json["progress_ms"] as? Int ?? 0,
            durationMS: item["duration_ms"] as? Int ?? 0,
            source: "web")
    }

    private func webCommand(_ press: String) async throws {
        switch press {
        case "next":     _ = try await call("POST", "/me/player/next")
        case "previous": _ = try await call("POST", "/me/player/previous")
        case "play_pause":
            let data = try await call("GET", "/me/player")
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let playing = (json?["is_playing"] as? Bool) ?? false
            _ = try await call("PUT", playing ? "/me/player/pause" : "/me/player/play")
        default: break
        }
    }

    // MARK: Press

    /// `action` rather than `config.press`: a "controls" widget has a
    /// different action per key, so the caller resolves it from the key that
    /// was actually pressed.
    func press(_ config: WidgetConfig, action: String, source: String) async {
        guard action != "none" else { return }
        if source == "web" || config.source == "web" {
            do {
                try await webCommand(action)
                return
            } catch {
                if config.source == "web" { return }
            }
        }
        Self.command(action)
    }

    // MARK: Artwork

    private func artwork(_ url: String) async -> CGImage? {
        if let cached = artCache[url] { return cached }
        if artFailed.contains(url) { return nil }
        guard let image = await Self.download(url) else {
            // A dead art URL retried every poll is a network round trip per
            // second for as long as the track plays.
            artFailed.insert(url)
            if artFailed.count > 64 { artFailed.removeAll() }
            return nil
        }
        artCache[url] = image
        artOrder.append(url)
        while artOrder.count > Self.artCacheLimit {
            artCache.removeValue(forKey: artOrder.removeFirst())
        }
        return image
    }

    private static func download(_ string: String) async -> CGImage? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" {
            return NSImage(contentsOfFile: url.path)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (try? check(response)) != nil,
              data.count <= maximumArtBytes
        else { return nil }
        return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Errors

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw WidgetError.message(http.statusCode == 429 ? "rate limited"
                                                             : "HTTP \(http.statusCode)")
        }
    }

    private static func describe(_ error: Error) -> String {
        if let widget = error as? WidgetError { return widget.text }
        if (error as NSError).domain == NSURLErrorDomain { return "offline" }
        return String(error.localizedDescription.prefix(40))
    }
}

enum WidgetError: Error {
    case message(String)
    var text: String { if case .message(let s) = self { return s }; return "error" }
}

// MARK: - Rendering

enum SpotifyWidgetRenderer {
    /// Which layout a span gets when the style is "auto".
    ///
    /// A wide block gets `split` — a square of album art beside a full info
    /// panel — because that is the shape the art wants: on a 4x2 the art fills
    /// a 2x2 block and the text gets the other 2x2, rather than being squeezed
    /// under a letterboxed cover.
    static func style(for config: WidgetConfig, columns: Int, rows: Int) -> String {
        guard config.style == "auto" else { return config.style }
        if columns * rows == 1 { return "art" }
        if rows == 1 { return "art+text" }
        if columns >= rows * 2 { return "split" }
        return "progress"
    }

    // MARK: - Transport controls

    /// The buttons a "controls" widget shows, left to right.
    ///
    /// Always at most three, however wide the span: a transport bar with six
    /// buttons in it is not a transport bar. On a span wider than three keys
    /// the buttons simply get bigger, each spanning several keys.
    static func controlButtons(cellCount: Int) -> [String] {
        switch max(1, cellCount) {
        case 1:  return ["play_pause"]
        case 2:  return ["play_pause", "next"]
        default: return ["previous", "play_pause", "next"]
        }
    }

    /// Which button sits under a given column of the span. Uses the column's
    /// CENTRE, so a button spanning two keys claims both of them.
    static func buttonIndex(dx: Int, columns: Int, buttons: Int) -> Int {
        guard columns > 0, buttons > 0 else { return 0 }
        let position = (Double(dx) + 0.5) / Double(columns) * Double(buttons)
        return min(buttons - 1, max(0, Int(position)))
    }

    /// What pressing one particular key of this widget does. Every style but
    /// `controls` answers with the widget's single configured action.
    static func pressAction(config: WidgetConfig, cell: WidgetCell) -> String {
        guard style(for: config, columns: cell.columns, rows: cell.rows) == "controls"
        else { return config.press }
        let buttons = controlButtons(cellCount: cell.cellCount)
        return buttons[buttonIndex(dx: cell.dx, columns: cell.columns,
                                   buttons: buttons.count)]
    }

    static func draw(_ state: SpotifyNowPlaying, config: WidgetConfig,
                     columns: Int, rows: Int, background: NSColor,
                     ctx: CGContext) {
        let cell = CGFloat(DeckLayout.keyPixels)
        let frame = CGRect(x: 0, y: 0, width: CGFloat(columns) * cell,
                           height: CGFloat(rows) * cell)
        let foreground = NSColor.white

        guard state.ok else {
            // No error text means nothing has been fetched yet — a fresh
            // widget, or one whose configuration just changed. Saying
            // "unavailable" there would accuse the service of being down.
            WidgetPaint.message("Spotify", state.error.isEmpty ? "connecting…" : state.error,
                                frame: frame, ctx: ctx, tint: WidgetPaint.green)
            return
        }
        guard state.hasTrack else {
            WidgetPaint.message("Spotify", "nothing playing", frame: frame, ctx: ctx,
                                tint: WidgetPaint.green)
            return
        }

        let accent = state.art != nil ? state.accent : WidgetPaint.green
        let resolved = style(for: config, columns: columns, rows: rows)
        switch resolved {
        case "text":
            drawText(state, frame: frame, cell: cell, accent: accent,
                     background: background, foreground: foreground, ctx: ctx)
        case "art":
            drawArt(state, frame: frame, cell: cell, accent: accent,
                    background: background, foreground: foreground,
                    withCaption: columns * rows > 1, ctx: ctx)
        case "art+text":
            drawArtText(state, frame: frame, cell: cell, accent: accent,
                        background: background, foreground: foreground, ctx: ctx)
        case "split":
            drawSplit(state, frame: frame, cell: cell, accent: accent,
                      background: background, foreground: foreground, ctx: ctx)
        case "button":
            drawButton(state, config: config, frame: frame, cell: cell,
                       accent: accent, background: background, ctx: ctx)
        case "controls":
            drawControls(state, frame: frame, cell: cell, columns: columns,
                         rows: rows, accent: accent, background: background, ctx: ctx)
        default:
            drawProgress(state, frame: frame, cell: cell, accent: accent,
                         background: background, ctx: ctx)
        }
        // The button styles ARE the badge; a second one would be noise.
        if resolved != "button", resolved != "controls" {
            badge(state, config: config, frame: frame, cell: cell, accent: accent, ctx: ctx)
        }
    }

    /// The corner badge: what pressing this key does, and — through its tint —
    /// whether playback is live.
    private static func badge(_ state: SpotifyNowPlaying, config: WidgetConfig,
                              frame: CGRect, cell: CGFloat, accent: NSColor,
                              ctx: CGContext) {
        // Playing accents the badge, paused greys it, so the state survives
        // even on a key whose press is "next track".
        let tint = state.playing ? accent : WidgetPaint.muted
        guard let symbol = badgeSymbol(press: config.press, playing: state.playing) else {
            // Nothing to advertise, but whether it is playing still matters.
            WidgetPaint.stateDot(playing: state.playing, frame: frame, cell: cell,
                                 accent: accent, ctx: ctx)
            return
        }
        WidgetPaint.actionBadge(symbol, frame: frame, cell: cell, tint: tint, ctx: ctx)
    }

    /// The glyph for a press action, or nil when there is nothing to show.
    ///
    /// Play/pause follows the transport-button convention — ▶ means "press to
    /// play", so the badge shows the ACTION rather than the state. That it
    /// also reads as the state is exactly why every remote control does it
    /// this way.
    static func badgeSymbol(press: String, playing: Bool) -> String? {
        switch press {
        case "play_pause": return playing ? "pause.fill" : "play.fill"
        case "next":       return "forward.end.fill"
        case "previous":   return "backward.end.fill"
        default:           return nil
        }
    }

    // MARK: Layouts

    private static func drawText(_ state: SpotifyNowPlaying, frame: CGRect, cell: CGFloat,
                                 accent: NSColor, background: NSColor,
                                 foreground: NSColor, ctx: CGContext) {
        let tint = WidgetPaint.mix(background, accent, 0.22)
        WidgetPaint.fill(frame, tint, ctx: ctx)
        let pad = max(4, min(frame.width, frame.height) * 0.08)
        let width = frame.width - 2 * pad
        let base = min(frame.width, frame.height)
        var y = frame.minY + pad
        y += WidgetPaint.line(state.title, in: CGRect(x: pad, y: y, width: width, height: base * 0.3),
                              ctx: ctx, size: base * 0.20, color: foreground)
        y += WidgetPaint.line(state.artist, in: CGRect(x: pad, y: y, width: width, height: base * 0.25),
                              ctx: ctx, size: base * 0.15,
                              color: WidgetPaint.mix(tint, foreground, 0.6))
        if frame.maxY - y > base * 0.2 {
            WidgetPaint.line(state.album, in: CGRect(x: pad, y: y, width: width, height: base * 0.2),
                             ctx: ctx, size: base * 0.13,
                             color: WidgetPaint.mix(tint, foreground, 0.42))
        }
    }

    private static func drawArt(_ state: SpotifyNowPlaying, frame: CGRect, cell: CGFloat,
                                accent: NSColor, background: NSColor, foreground: NSColor,
                                withCaption: Bool, ctx: CGContext) {
        guard let art = state.art else {
            drawText(state, frame: frame, cell: cell, accent: accent,
                     background: background, foreground: foreground, ctx: ctx)
            return
        }
        WidgetPaint.drawCover(art, in: frame, ctx: ctx)
        if !state.playing {
            // A paused deck should look paused without hiding the art.
            WidgetPaint.scrim(frame, ctx: ctx, topAlpha: 0.35, bottomAlpha: 0.35)
        }
        guard withCaption else { return }
        let band = frame.height * 0.30
        let bandRect = CGRect(x: frame.minX, y: frame.maxY - band,
                              width: frame.width, height: band)
        WidgetPaint.scrim(bandRect, ctx: ctx, topAlpha: 0, bottomAlpha: 0.9)
        let pad = max(4, min(frame.width, frame.height) * 0.05)
        var y = bandRect.minY + band * 0.10
        y += WidgetPaint.line(state.title,
                              in: CGRect(x: pad, y: y, width: frame.width - 2 * pad, height: band * 0.5),
                              ctx: ctx, size: band * 0.42, color: .white, shadow: true)
        WidgetPaint.line(state.artist,
                         in: CGRect(x: pad, y: y, width: frame.width - 2 * pad, height: band * 0.4),
                         ctx: ctx, size: band * 0.30,
                         color: NSColor(white: 0.85, alpha: 1), shadow: true)
    }

    /// Art in a square block on the left, text beside it — the layout for a
    /// wide, short span (2x1, 3x1, 5x1).
    private static func drawArtText(_ state: SpotifyNowPlaying, frame: CGRect, cell: CGFloat,
                                    accent: NSColor, background: NSColor,
                                    foreground: NSColor, ctx: CGContext) {
        let artWidth = frame.width > frame.height ? min(frame.height, frame.width / 2) : frame.width
        let pad = max(4, cell * 0.08)
        let textX = artWidth + pad
        let textWidth = frame.width - textX - pad
        guard textWidth >= cell * 0.4 else {
            // Too narrow to say anything useful: fall back to art with a
            // caption band, which at least names the track.
            drawArt(state, frame: frame, cell: cell, accent: accent,
                    background: background, foreground: foreground,
                    withCaption: true, ctx: ctx)
            return
        }
        let artRect = CGRect(x: frame.minX, y: frame.minY, width: artWidth, height: frame.height)
        if let art = state.art {
            WidgetPaint.drawCover(art, in: artRect, ctx: ctx)
        } else {
            WidgetPaint.fill(artRect, WidgetPaint.mix(background, accent, 0.30), ctx: ctx)
        }
        let tint = WidgetPaint.mix(background, accent, 0.16)
        WidgetPaint.fill(CGRect(x: artWidth, y: frame.minY,
                                width: frame.width - artWidth, height: frame.height), tint, ctx: ctx)

        var y = frame.minY + pad
        y += WidgetPaint.line(state.title,
                              in: CGRect(x: textX, y: y, width: textWidth, height: cell * 0.3),
                              ctx: ctx, size: cell * 0.22, color: foreground)
        y += WidgetPaint.line(state.artist,
                              in: CGRect(x: textX, y: y, width: textWidth, height: cell * 0.25),
                              ctx: ctx, size: cell * 0.16,
                              color: WidgetPaint.mix(tint, foreground, 0.6))
        if frame.maxY - y > cell * 0.34 {
            y += WidgetPaint.line(state.album,
                                  in: CGRect(x: textX, y: y, width: textWidth, height: cell * 0.2),
                                  ctx: ctx, size: cell * 0.13,
                                  color: WidgetPaint.mix(tint, foreground, 0.42))
        }
        let barHeight = max(3, cell * 0.06)
        let labels = textWidth > cell * 1.2
        let labelHeight = labels ? cell * 0.12 * 1.3 : 0
        let barY = frame.maxY - pad - barHeight - labelHeight
        if barY > y {
            progress(state, x: textX, y: barY, width: textWidth, height: barHeight,
                     cell: cell, accent: accent, track: tint, labels: labels,
                     bottom: frame.maxY, ctx: ctx)
        }
    }

    /// A square of album art beside a full info panel — the layout for a wide
    /// block (4x2, 6x3). The art gets a whole sub-square of keys at native
    /// aspect, and everything else gets the panel: title, artist, album, a
    /// progress bar and the times, all sized off the PANEL rather than off one
    /// key, so a bigger widget genuinely reads bigger.
    private static func drawSplit(_ state: SpotifyNowPlaying, frame: CGRect, cell: CGFloat,
                                  accent: NSColor, background: NSColor,
                                  foreground: NSColor, ctx: CGContext) {
        // A square of whole keys, as tall as the widget allows, always leaving
        // at least one column for the panel. Sizing it off a fraction of the
        // width instead left a 5x3 widget with a 2x2 cover floating between
        // two dead bands — the art has to fill the height it was given.
        let columns = max(1, Int((frame.width / cell).rounded()))
        let rows = max(1, Int((frame.height / cell).rounded()))
        let artKeys = max(1, min(rows, columns - 1))
        let artSide = CGFloat(artKeys) * cell
        let artRect = CGRect(x: frame.minX, y: frame.minY + (frame.height - artSide) / 2,
                             width: artSide, height: artSide)
        let panel = CGRect(x: frame.minX + artSide, y: frame.minY,
                           width: frame.width - artSide, height: frame.height)
        let tint = WidgetPaint.mix(background, accent, 0.18)
        WidgetPaint.fill(panel, tint, ctx: ctx)
        if let art = state.art {
            WidgetPaint.drawCover(art, in: artRect, ctx: ctx)
        } else {
            WidgetPaint.fill(artRect, WidgetPaint.mix(background, accent, 0.35), ctx: ctx)
        }

        guard panel.width > cell * 0.6 else { return }
        let pad = max(6, cell * 0.12)
        let inner = panel.insetBy(dx: pad, dy: pad)
        let dim = WidgetPaint.mix(tint, foreground, 0.62)
        // Type scales with the panel, not the key: this is the whole point of
        // giving a widget more room.
        let unit = min(panel.height, panel.width * 0.7)
        let barHeight = max(4, unit * 0.055)
        let labelSize = max(9, unit * 0.10)
        let barY = inner.maxY - barHeight - labelSize * 1.35

        var y = inner.minY
        // The badge sits in the panel's top-right corner, so the title gets a
        // narrower line than everything below it. Without this the two overlap
        // on a narrow panel (a 3x2 leaves the panel just one key wide).
        let badgeAllowance = cell * 0.36
        y += WidgetPaint.line(state.title,
                              in: CGRect(x: inner.minX, y: y,
                                         width: max(inner.width - badgeAllowance, inner.width * 0.5),
                                         height: unit * 0.3),
                              ctx: ctx, size: unit * 0.20, color: foreground)
        y += WidgetPaint.line(state.artist, in: CGRect(x: inner.minX, y: y,
                                                       width: inner.width, height: unit * 0.24),
                              ctx: ctx, size: unit * 0.145, color: dim)
        if barY - y > unit * 0.18 {
            WidgetPaint.line(state.album, in: CGRect(x: inner.minX, y: y,
                                                     width: inner.width, height: unit * 0.2),
                             ctx: ctx, size: unit * 0.115,
                             color: WidgetPaint.mix(tint, foreground, 0.42))
        }
        guard barY > inner.minY else { return }
        progress(state, x: inner.minX, y: barY, width: inner.width, height: barHeight,
                 cell: unit, accent: accent, track: WidgetPaint.mix(tint, foreground, 0.22),
                 labels: true, bottom: frame.maxY, ctx: ctx, labelSize: labelSize)
    }

    /// One big transport button filling the span — a control that is a key in
    /// its own right rather than a corner badge on a now-playing face.
    private static func drawButton(_ state: SpotifyNowPlaying, config: WidgetConfig,
                                   frame: CGRect, cell: CGFloat, accent: NSColor,
                                   background: NSColor, ctx: CGContext) {
        let action = config.press == "none" ? "play_pause" : config.press
        // The face spans the whole widget, but the glyph is centred on one
        // key — see drawControls for why a glyph must not straddle the gap
        // between two physical keys.
        let columns = max(1, Int((frame.width / cell).rounded()))
        let centreColumn = columns / 2
        let glyphKey = CGRect(x: frame.minX + CGFloat(centreColumn) * cell,
                              y: frame.minY, width: cell, height: frame.height)
        drawControlFace(action, state: state, rect: frame, cell: cell, accent: accent,
                        background: background, label: frame.width >= cell * 1.8,
                        glyphRect: glyphKey, ctx: ctx)
    }

    /// A transport bar across the span: previous / play-pause / next, each
    /// button claiming whole keys, each key pressing only its own button.
    private static func drawControls(_ state: SpotifyNowPlaying, frame: CGRect, cell: CGFloat,
                                     columns: Int, rows: Int, accent: NSColor,
                                     background: NSColor, ctx: CGContext) {
        let buttons = controlButtons(cellCount: columns * rows)
        // One face per KEY, drawn through the SAME buttonIndex the press
        // routing uses — so what a key shows is by construction what it does.
        //
        // Keys that share a button repeat its glyph rather than stretching one
        // glyph across them: the deck's keys are physically separate, and a
        // pause symbol split down the gap between two of them reads as a
        // rendering fault, not as one wide button.
        for dy in 0..<rows {
            for dx in 0..<columns {
                let action = buttons[buttonIndex(dx: dx, columns: columns,
                                                 buttons: buttons.count)]
                let rect = CGRect(x: frame.minX + CGFloat(dx) * cell,
                                  y: frame.minY + CGFloat(dy) * cell,
                                  width: cell, height: cell)
                drawControlFace(action, state: state, rect: rect, cell: cell,
                                accent: accent, background: background,
                                label: false, ctx: ctx)
            }
        }
    }

    /// One transport button: a big glyph on a tinted face. Playing tints it
    /// with the album accent, paused greys it, so a bar of buttons still says
    /// whether anything is playing.
    private static func drawControlFace(_ action: String, state: SpotifyNowPlaying,
                                        rect: CGRect, cell: CGFloat, accent: NSColor,
                                        background: NSColor, label: Bool,
                                        glyphRect: CGRect? = nil, ctx: CGContext) {
        let live = state.ok && state.playing
        let tint = live ? accent : WidgetPaint.muted
        let inset = max(2, cell * 0.04)
        let face = rect.insetBy(dx: inset, dy: inset)
        WidgetPaint.roundedRect(face, radius: cell * 0.14,
                                WidgetPaint.mix(background, tint, 0.16), ctx: ctx)
        WidgetPaint.roundedRect(face.insetBy(dx: 1, dy: 1), radius: cell * 0.13,
                                WidgetPaint.mix(background, tint, 0.10), ctx: ctx)

        let symbol = badgeSymbol(press: action, playing: state.playing) ?? "play.fill"
        let base = glyphRect ?? face
        let glyphBox = label
            ? CGRect(x: base.minX, y: base.minY, width: base.width, height: base.height * 0.62)
            : base
        WidgetPaint.glyph(symbol, in: glyphBox.insetBy(dx: glyphBox.width * 0.26,
                                                       dy: glyphBox.height * 0.26),
                          color: live ? .white : NSColor(white: 0.72, alpha: 1), ctx: ctx)
        guard label, state.hasTrack else { return }
        let pad = max(4, cell * 0.08)
        WidgetPaint.line(state.title, in: CGRect(x: face.minX + pad, y: face.maxY - cell * 0.30,
                                                 width: face.width - 2 * pad, height: cell * 0.24),
                         ctx: ctx, size: cell * 0.17, color: .white, align: .center)
        WidgetPaint.line(state.artist, in: CGRect(x: face.minX + pad, y: face.maxY - cell * 0.16,
                                                  width: face.width - 2 * pad, height: cell * 0.18),
                         ctx: ctx, size: cell * 0.13,
                         color: NSColor(white: 0.78, alpha: 1), align: .center)
    }

    /// Art as a dimmed background with the track and a progress bar over it —
    /// the layout for a block span (2x2 and larger).
    private static func drawProgress(_ state: SpotifyNowPlaying, frame: CGRect, cell: CGFloat,
                                     accent: NSColor, background: NSColor, ctx: CGContext) {
        if let art = state.art {
            WidgetPaint.drawCover(art, in: frame, ctx: ctx)
            WidgetPaint.scrim(frame, ctx: ctx, topAlpha: 0.45, bottomAlpha: 0.92)
        } else {
            WidgetPaint.fill(frame, WidgetPaint.mix(background, accent, 0.25), ctx: ctx)
        }
        let pad = max(5, cell * 0.10)
        let barHeight = max(4, cell * 0.07)
        let labelHeight = cell * 0.12 * 1.3
        let barY = frame.maxY - pad - barHeight - labelHeight
        progress(state, x: pad, y: barY, width: frame.width - 2 * pad, height: barHeight,
                 cell: cell, accent: accent,
                 track: WidgetPaint.mix(background, .white, 0.25), labels: true,
                 bottom: frame.maxY, ctx: ctx)
        var y = max(frame.minY + pad, barY - cell * 0.5)
        y += WidgetPaint.line(state.title,
                              in: CGRect(x: pad, y: y, width: frame.width - 2 * pad, height: cell * 0.34),
                              ctx: ctx, size: cell * 0.26, color: .white, shadow: true)
        WidgetPaint.line(state.artist,
                         in: CGRect(x: pad, y: y, width: frame.width - 2 * pad, height: cell * 0.26),
                         ctx: ctx, size: cell * 0.18,
                         color: NSColor(white: 0.86, alpha: 1), shadow: true)
    }

    private static func progress(_ state: SpotifyNowPlaying, x: CGFloat, y: CGFloat,
                                 width: CGFloat, height: CGFloat, cell: CGFloat,
                                 accent: NSColor, track: NSColor, labels: Bool,
                                 bottom: CGFloat, ctx: CGContext,
                                 labelSize: CGFloat? = nil) {
        let fraction = state.durationMS > 0
            ? Double(state.progressMS) / Double(state.durationMS) : 0
        guard labels else {
            WidgetPaint.progressBar(CGRect(x: x, y: y, width: width, height: height),
                                    fraction: fraction, accent: accent, track: track, ctx: ctx)
            return
        }
        // Explicit when the caller already reserved space for them: deriving
        // the size from `cell` when `cell` is a whole panel produced labels
        // bigger than the gap left for them, and the fit guard then silently
        // dropped the times entirely.
        WidgetPaint.progressBlock(x: x, y: y, width: width, height: height,
                                  fraction: fraction,
                                  elapsed: clock(state.progressMS), total: clock(state.durationMS),
                                  accent: accent, track: track,
                                  labelSize: labelSize ?? max(8, cell * 0.12),
                                  labelGap: max(2, cell * 0.04),
                                  bottom: bottom, ctx: ctx)
    }

    private static func clock(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}


// MARK: - WidgetProviding

extension SpotifyProvider: WidgetProviding {
    nonisolated func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        let state = SpotifyNowPlaying(source: config.source)
        return WidgetSnapshot(signature: "spotify:" + state.signature, payload: state)
    }

    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        let state = await fetch(config)
        return WidgetSnapshot(signature: "spotify:" + state.signature, payload: state)
    }

    func press(_ config: WidgetConfig, cell: WidgetCell, snapshot: WidgetSnapshot) async -> Bool {
        let action = SpotifyWidgetRenderer.pressAction(config: config, cell: cell)
        guard action != "none" else { return false }
        // Prefer the source the last poll actually used: with "auto" that is
        // the only way to know whether the Web API or the local app answered.
        let polled = snapshot.data(SpotifyNowPlaying.self)?.source ?? ""
        await press(config, action: action, source: polled.isEmpty ? config.source : polled)
        return false
    }

    nonisolated func action(for config: WidgetConfig, cell: WidgetCell) -> String {
        SpotifyWidgetRenderer.pressAction(config: config, cell: cell)
    }

    @MainActor
    func draw(_ snapshot: WidgetSnapshot, config: WidgetConfig,
                          columns: Int, rows: Int, background: NSColor, ctx: CGContext) {
        SpotifyWidgetRenderer.draw(snapshot.data(SpotifyNowPlaying.self) ?? SpotifyNowPlaying(),
                                   config: config, columns: columns, rows: rows,
                                   background: background, ctx: ctx)
    }
}
