import AppKit
import Foundation

/// VLC running on another machine, over its built-in HTTP interface.
///
/// VLC ships a small web server that answers `/requests/status.json` with what
/// is playing and takes transport commands on the same URL. That is the whole
/// integration — no agent to install on the other machine, no protocol to
/// reverse. It is off by default, so the widget's first job is explaining how
/// to turn it on.
///
/// In VLC: Preferences → Show settings **All** → Interface → Main interfaces →
/// tick **Web**, then Main interfaces → Lua → set a password. Restart VLC. It
/// then listens on port 8080 on every interface, and the machine's firewall
/// has to allow it.
///
/// The password is a credential, so it lives in `widgets.json` or a `.env` as
/// `VLC_PASSWORD` — never in `settings.json`, which is the layout you copy
/// between machines.
struct VLCState {
    var ok = false
    var reachable = false
    var playing = false
    var stopped = true
    var title = ""
    var artist = ""
    var album = ""
    var filename = ""
    var position = 0.0            // 0...1
    var time = 0                  // seconds
    var length = 0                // seconds
    var volume = 0                // VLC's 0...512, where 256 is 100%
    var host = ""
    var error = ""

    /// Cover art, from VLC's own `/art` endpoint.
    var art: CGImage? = nil
    /// Pulled out of the art, so the face is tinted by the record rather than
    /// by a fixed brand colour.
    var accent: NSColor = NSColor(srgbRed: 0.95, green: 0.51, blue: 0.11, alpha: 1)

    /// What identifies the CURRENT item. `/art` has no per-track URL — it
    /// always serves whatever is playing now — so this is what the art cache
    /// is keyed on, and what tells us the art must be re-fetched.
    var trackIdentity: String { "\(title)|\(artist)|\(album)|\(filename)" }

    /// What to put on the key. VLC often has no metadata at all — playing a
    /// file straight off disk gives a filename and nothing else — so the
    /// filename is the fallback, stripped of its extension because
    /// ".mkv" is not information.
    var displayTitle: String {
        if !title.isEmpty { return title }
        guard !filename.isEmpty else { return "" }
        let name = (filename as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    var hasTrack: Bool { !displayTitle.isEmpty }

    var signature: String {
        // Time is bucketed to the second: a widget on a 1 s interval must not
        // rewrite the key for every millisecond of drift.
        "\(ok)|\(reachable)|\(playing)|\(stopped)|\(displayTitle)|\(artist)|\(album)"
            + "|\(time)|\(length)|\(error)|\(art != nil)"
    }

    static func clock(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0:00" }
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Provider

actor VLCProvider: WidgetProviding {
    private static let timeout: TimeInterval = 4      // it is on the LAN
    static let defaultPort = 8080

    private var artCache: [String: CGImage] = [:]
    private var artOrder: [String] = []
    private static let artCacheLimit = 6
    /// A cover is a few hundred KB; anything this size is not one.
    private static let maximumArtBytes = 12 * 1024 * 1024

    nonisolated func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        let state = VLCState(host: config.place)
        return WidgetSnapshot(signature: "vlc:placeholder|" + state.signature, payload: state)
    }

    // MARK: Address

    /// Splits "192.168.1.50", "192.168.1.50:8080" or "http://host:8080/" into
    /// something a URL can be built from. Nil when there is nothing usable.
    ///
    /// Static and pure so the parsing can be tested without a VLC on the
    /// network — which is the part most likely to be typed wrong.
    static func address(_ raw: String) -> (host: String, port: Int)? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        for prefix in ["http://", "https://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[text.startIndex..<slash]) }
        guard !text.isEmpty else { return nil }

        var host = text
        var port = defaultPort
        // Split on the LAST colon so an IPv6 literal in brackets survives.
        if let colon = text.lastIndex(of: ":"), !text.hasSuffix("]") {
            let tail = String(text[text.index(after: colon)...])
            if let parsed = Int(tail), (1...65535).contains(parsed) {
                host = String(text[text.startIndex..<colon])
                port = parsed
            }
        }
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    private static func url(_ config: WidgetConfig, command: String? = nil) -> URL? {
        guard let (host, port) = address(config.place) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/requests/status.json"
        if let command { components.queryItems = [URLQueryItem(name: "command", value: command)] }
        return components.url
    }

    /// VLC's HTTP interface uses Basic auth with an EMPTY user name and the
    /// Lua password. Sending a user name is the usual reason a correct
    /// password still gets a 401.
    /// The current item's cover. VLC serves it at `/art` with the same auth.
    private static func artURL(_ config: WidgetConfig) -> URL? {
        guard let (host, port) = address(config.place) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/art"
        return components.url
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let password = WidgetCredentials.value(.vlcPassword)
        let pair = Data(":\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(pair)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Fetch

    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        var state = VLCState(host: config.place)
        guard let url = Self.url(config) else {
            state.error = "set the address"
            return snapshot(state)
        }
        guard WidgetCredentials.has(.vlcPassword) else {
            state.error = "no password"
            return snapshot(state)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: Self.request(url))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                state.reachable = true          // something answered, so VLC is up
                state.error = Self.describe(status: http.statusCode)
                return snapshot(state)
            }
            state.reachable = true
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                state.error = "bad reply"
                return snapshot(state)
            }
            Self.apply(json, to: &state)
            state.ok = true
            if state.hasTrack, let art = await artwork(config, identity: state.trackIdentity) {
                state.art = art
                state.accent = WidgetPaint.accent(from: art)
            }
        } catch {
            // Nothing answered. The machine is asleep, VLC is closed, the web
            // interface was never enabled, or a firewall ate it — all of which
            // look identical from here, so the key says the honest thing.
            state.error = "offline"
        }
        return snapshot(state)
    }

    /// What an HTTP failure from VLC actually means.
    ///
    /// The 404 is the one worth knowing. With no password configured, VLC
    /// still binds the port and still accepts connections — it just refuses
    /// to enable the interface, and answers **404 to everything**, including
    /// a request that carries credentials:
    ///
    ///     lua interface error: Password unset, insecure web interface disabled
    ///
    /// So "the port is open but nothing works" is not a broken URL, it is an
    /// unset password, and reporting a bare 404 sends you looking in exactly
    /// the wrong place. Confirmed against VLC 3 with and without one.
    static func describe(status: Int) -> String {
        switch status {
        case 401: return "wrong password"
        case 403: return "VLC refused it"
        case 404: return "set a password in VLC"
        default:  return "HTTP \(status)"
        }
    }

    /// Reads VLC's status document. Split out and static so the parsing is
    /// testable against a captured reply.
    static func apply(_ json: [String: Any], to state: inout VLCState) {
        let vlcState = (json["state"] as? String ?? "").lowercased()
        state.playing = vlcState == "playing"
        state.stopped = vlcState == "stopped" || vlcState.isEmpty
        state.time = Self.int(json["time"])
        state.length = Self.int(json["length"])
        state.volume = Self.int(json["volume"])
        // `position` is authoritative when present: with a stream of unknown
        // length, time/length would divide by zero.
        if let position = json["position"] as? Double {
            state.position = min(max(position, 0), 1)
        } else if state.length > 0 {
            state.position = min(max(Double(state.time) / Double(state.length), 0), 1)
        }

        guard let information = json["information"] as? [String: Any],
              let category = information["category"] as? [String: Any],
              let meta = category["meta"] as? [String: Any]
        else { return }
        func text(_ key: String) -> String {
            (meta[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        state.title = text("title")
        state.artist = text("artist")
        state.album = text("album")
        state.filename = text("filename")
        // Radio streams put the track in now_playing and the station in title.
        let nowPlaying = text("now_playing")
        if !nowPlaying.isEmpty {
            if state.artist.isEmpty { state.artist = state.title }
            state.title = nowPlaying
        }
    }

    private static func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    /// Cover art, cached per track.
    ///
    /// A failure is deliberately NOT remembered. VLC fetches artwork
    /// asynchronously after a track starts, so the first ask often lands
    /// before the art exists — caching that "no" would mean the cover never
    /// appears for the rest of the track. Retrying costs one small request on
    /// your own LAN.
    private func artwork(_ config: WidgetConfig, identity: String) async -> CGImage? {
        guard !identity.isEmpty else { return nil }
        if let cached = artCache[identity] { return cached }
        guard let url = Self.artURL(config),
              let (data, response) = try? await URLSession.shared.data(for: Self.request(url)),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= Self.maximumArtBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        artCache[identity] = image
        artOrder.append(identity)
        while artOrder.count > Self.artCacheLimit {
            artCache.removeValue(forKey: artOrder.removeFirst())
        }
        return image
    }

    private func snapshot(_ state: VLCState) -> WidgetSnapshot {
        WidgetSnapshot(signature: "vlc|" + state.signature, payload: state)
    }

    // MARK: Press

    /// What each key of the widget does. `controls` gives every key its own
    /// button — the same rule the Spotify transport bar follows, and for the
    /// same reason: the deck's keys are physically separate, so one glyph
    /// stretched across a gap reads as a fault.
    nonisolated func action(for config: WidgetConfig, cell: WidgetCell) -> String {
        SpotifyWidgetRenderer.pressAction(config: config, cell: cell)
    }

    /// The button at a given column of a transport bar. One function, used by
    /// both the press and the glyph, so the two cannot disagree.
    static func transportAction(dx: Int, columns: Int) -> String {
        let buttons = SpotifyWidgetRenderer.controlButtons(cellCount: columns)
        return buttons[SpotifyWidgetRenderer.buttonIndex(dx: dx, columns: columns,
                                                         buttons: buttons.count)]
    }

    func press(_ config: WidgetConfig, cell: WidgetCell, snapshot: WidgetSnapshot) async -> Bool {
        let action = action(for: config, cell: cell)
        let state: VLCState? = snapshot.data()
        guard let command = Self.command(for: action, playing: state?.playing ?? false),
              let url = Self.url(config, command: command)
        else { return false }
        _ = try? await URLSession.shared.data(for: Self.request(url))
        // Always true: the deck should show the new state now, not up to a
        // whole refresh interval later.
        return true
    }

    /// VLC's command words. `pl_pause` toggles, so play/pause is one command
    /// whichever way round it is — except from a full stop, where nothing is
    /// loaded to toggle and `pl_play` is what resumes the playlist.
    static func command(for action: String, playing: Bool) -> String? {
        switch action {
        case "play_pause": return playing ? "pl_pause" : "pl_play"
        case "next":       return "pl_next"
        case "previous":   return "pl_previous"
        case "stop":       return "pl_stop"
        default:           return nil
        }
    }

    /// The glyph for a key, from the same action the press runs.
    static func glyphName(for action: String, playing: Bool) -> String {
        switch action {
        case "play_pause": return playing ? "pause.fill" : "play.fill"
        case "next":       return "forward.end.fill"
        case "previous":   return "backward.end.fill"
        case "stop":       return "stop.fill"
        default:           return "play.fill"
        }
    }

    // MARK: Draw

    @MainActor
    func draw(_ snapshot: WidgetSnapshot, config: WidgetConfig,
                          columns: Int, rows: Int, background: NSColor, ctx: CGContext) {
        let state: VLCState = snapshot.data() ?? VLCState()
        VLCWidgetRenderer.draw(state, config: config, columns: columns, rows: rows,
                               background: background, ctx: ctx)
    }
}

// MARK: - Faces

/// VLC has no faces of its own any more.
///
/// It draws through `SpotifyWidgetRenderer`, from the shared `NowPlayingFace`.
/// Two renderers meant two sets of `auto` rules, and a 3x2 VLC widget looked
/// nothing like a 3x2 Spotify one — not because either was wrong, but because
/// nothing made them agree. This is what makes them agree.
enum VLCWidgetRenderer {
    /// Kept as the name the tests reason about; the rules are Spotify's.
    static func resolvedStyle(_ style: String, columns: Int, rows: Int) -> String {
        var config = WidgetConfig(kind: .vlc)
        config.style = style
        return SpotifyWidgetRenderer.style(for: config, columns: columns, rows: rows)
    }

    @MainActor
    static func draw(_ state: VLCState, config: WidgetConfig, columns: Int, rows: Int,
                     background: NSColor, ctx: CGContext) {
        SpotifyWidgetRenderer.draw(state.face, config: config, columns: columns,
                                   rows: rows, background: background, ctx: ctx)
    }
}
