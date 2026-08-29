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
        guard config.style == "controls" else { return config.press }
        return Self.transportAction(dx: cell.dx, columns: cell.columns)
    }

    /// The button at a given column of a transport bar. One function, used by
    /// both the press and the glyph, so the two cannot disagree.
    static func transportAction(dx: Int, columns: Int) -> String {
        let buttons = ["previous", "play_pause", "next"]
        guard columns > 0 else { return "play_pause" }
        let slot = (Double(dx) + 0.5) / Double(columns) * Double(buttons.count)
        return buttons[min(max(Int(slot), 0), buttons.count - 1)]
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

enum VLCWidgetRenderer {
    /// Which layout a span gets when the style is "auto": a single key can
    /// only be a button, a wide short block is a transport bar, anything
    /// bigger has room for text and a progress bar.
    static func resolvedStyle(_ style: String, columns: Int, rows: Int) -> String {
        guard style == "auto" else { return style }
        // A single key is a control - one glyph is all that reads at 100px.
        if columns == 1 && rows == 1 { return "button" }
        // A wide single row is a transport bar: each key its own button.
        if rows == 1 && columns >= 3 { return "controls" }
        // Wide and tall enough for a square of art beside a panel of text.
        if columns >= 3 && rows >= 2 { return "split" }
        return "progress"
    }

    /// Cover art behind the whole face, dimmed enough for text to sit on it.
    @MainActor
    private static func drawArtBackground(_ state: VLCState, frame: CGRect, ctx: CGContext) {
        guard let art = state.art else { return }
        WidgetPaint.drawCover(art, in: frame, ctx: ctx)
        // Without a scrim, a title lands on whatever the cover happens to be
        // and half of them are white.
        WidgetPaint.scrim(frame, ctx: ctx)
    }

    @MainActor
    static func draw(_ state: VLCState, config: WidgetConfig, columns: Int, rows: Int,
                     background: NSColor, ctx: CGContext) {
        let cell = CGFloat(DeckLayout.keyPixels)
        let frame = CGRect(x: 0, y: 0, width: cell * CGFloat(columns), height: cell * CGFloat(rows))
        let brand = WidgetPaint.mix(NSColor(srgbRed: 0.95, green: 0.51, blue: 0.11, alpha: 1),
                                    .white, state.playing ? 0.12 : 0.35)    // VLC cone orange

        // A problem replaces the face entirely. A widget that cannot reach
        // VLC but still draws a progress bar is lying about the state of
        // something in another room.
        guard state.ok else {
            WidgetPaint.message("VLC", state.error.isEmpty ? "connecting…" : state.error,
                                frame: frame, ctx: ctx, tint: brand)
            return
        }

        // The record's own colour once there is art to take it from, so the
        // face is tinted by what is playing rather than by a brand orange.
        let accent = state.art == nil ? brand : state.accent

        switch resolvedStyle(config.style, columns: columns, rows: rows) {
        case "art":      drawArt(state, config: config, frame: frame, cell: cell,
                                 accent: accent, ctx: ctx)
        case "split":    drawSplit(state, frame: frame, cell: cell, columns: columns,
                                   rows: rows, accent: accent, background: background, ctx: ctx)
        case "button":   drawButton(state, config: config, frame: frame, cell: cell,
                                    accent: accent, ctx: ctx)
        case "controls": drawControls(state, frame: frame, cell: cell, columns: columns,
                                      accent: accent, ctx: ctx)
        case "text":     drawText(state, frame: frame, cell: cell, accent: accent,
                                  background: background, ctx: ctx, progress: false)
        default:         drawText(state, frame: frame, cell: cell, accent: accent,
                                  background: background, ctx: ctx, progress: true)
        }
    }

    /// The cover, with the title over it and the transport badge in the
    /// corner. What a 1x1 or 2x2 block should be.
    @MainActor
    private static func drawArt(_ state: VLCState, config: WidgetConfig, frame: CGRect,
                                cell: CGFloat, accent: NSColor, ctx: CGContext) {
        guard state.art != nil else {
            drawText(state, frame: frame, cell: cell, accent: accent,
                     background: .black, ctx: ctx, progress: false)
            return
        }
        drawArtBackground(state, frame: frame, ctx: ctx)
        let unit = min(frame.width, frame.height)
        if frame.height > cell * 1.4, state.hasTrack {
            let size = unit * 0.13
            WidgetPaint.line(state.displayTitle,
                             in: CGRect(x: frame.minX + unit * 0.06, y: frame.minY + unit * 0.12,
                                        width: frame.width - unit * 0.12, height: size),
                             ctx: ctx, size: size, color: .white, align: .left)
            if !state.artist.isEmpty {
                WidgetPaint.line(state.artist,
                                 in: CGRect(x: frame.minX + unit * 0.06, y: frame.minY + unit * 0.04,
                                            width: frame.width - unit * 0.12, height: size * 0.8),
                                 ctx: ctx, size: size * 0.78, color: WidgetPaint.muted, align: .left)
            }
        }
        let action = config.press == "none" ? "" : config.press
        if !action.isEmpty {
            WidgetPaint.actionBadge(VLCProvider.glyphName(for: action, playing: state.playing),
                                    frame: frame, cell: cell, tint: accent, ctx: ctx)
        } else {
            WidgetPaint.stateDot(playing: state.playing, frame: frame, cell: cell,
                                 accent: accent, ctx: ctx)
        }
    }

    /// A square of cover art filling as many WHOLE keys as it can, beside a
    /// panel with the text and the progress.
    ///
    /// Deliberately the same shape, the same tinted panel and the SAME
    /// progress block as the Spotify widget's split face — a deck showing
    /// both should not look like it was assembled from two apps. The bar
    /// itself is `WidgetPaint.progressBlock`, which both call, so they cannot
    /// drift apart.
    @MainActor
    private static func drawSplit(_ state: VLCState, frame: CGRect, cell: CGFloat,
                                  columns: Int, rows: Int, accent: NSColor,
                                  background: NSColor, ctx: CGContext) {
        // Art fills the height it was given, always leaving a column for the
        // panel. Sizing off a fraction of the width leaves a wide widget with
        // a small cover floating between two dead bands.
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
            WidgetPaint.glyph("music.note", in: artRect.insetBy(dx: artSide * 0.32,
                                                                dy: artSide * 0.32),
                              color: accent, ctx: ctx)
        }

        guard panel.width > cell * 0.6 else { return }
        let pad = max(6, cell * 0.12)
        let inner = panel.insetBy(dx: pad, dy: pad)
        let foreground = NSColor.white
        let dim = WidgetPaint.mix(tint, foreground, 0.62)
        // Type scales with the PANEL, not the key: that is the whole point of
        // giving a widget more room.
        let unit = min(panel.height, panel.width * 0.7)
        let barHeight = max(4, unit * 0.055)
        let labelSize = max(9, unit * 0.10)
        let barY = inner.maxY - barHeight - labelSize * 1.35

        var y = inner.minY
        // The state dot sits in the panel's top-right, so the title gets a
        // narrower line than everything under it.
        let badgeAllowance = cell * 0.36
        y += WidgetPaint.line(state.displayTitle,
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
        WidgetPaint.stateDot(playing: state.playing, frame: panel, cell: cell,
                             accent: accent, ctx: ctx)
        guard barY > inner.minY, state.length > 0 else { return }
        WidgetPaint.progressBlock(x: inner.minX, y: barY, width: inner.width, height: barHeight,
                                  fraction: state.position,
                                  elapsed: VLCState.clock(state.time),
                                  total: VLCState.clock(state.length),
                                  accent: accent,
                                  track: WidgetPaint.mix(tint, foreground, 0.22),
                                  labelSize: labelSize, labelGap: max(2, unit * 0.04),
                                  bottom: frame.maxY, ctx: ctx)
    }

    /// One key, one control. The glyph comes from the same function the press
    /// uses, so what it shows is what it does.
    @MainActor
    private static func drawButton(_ state: VLCState, config: WidgetConfig, frame: CGRect,
                                   cell: CGFloat, accent: NSColor, ctx: CGContext) {
        let action = config.press == "none" ? "play_pause" : config.press
        let name = VLCProvider.glyphName(for: action, playing: state.playing)
        let side = min(frame.width, frame.height) * 0.42
        WidgetPaint.glyph(name, in: CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2,
                                           width: side, height: side),
                          color: accent, ctx: ctx)
        WidgetPaint.stateDot(playing: state.playing, frame: frame, cell: cell,
                             accent: accent, ctx: ctx)
    }

    /// A transport bar: each key its own button, repeated rather than
    /// stretched when two keys share one.
    @MainActor
    private static func drawControls(_ state: VLCState, frame: CGRect, cell: CGFloat,
                                     columns: Int, accent: NSColor, ctx: CGContext) {
        for dx in 0..<columns {
            let action = VLCProvider.transportAction(dx: dx, columns: columns)
            let name = VLCProvider.glyphName(for: action, playing: state.playing)
            let box = CGRect(x: CGFloat(dx) * cell, y: frame.minY, width: cell, height: frame.height)
            let side = min(box.width, box.height) * 0.40
            WidgetPaint.glyph(name, in: CGRect(x: box.midX - side / 2, y: box.midY - side / 2,
                                               width: side, height: side),
                              color: accent, ctx: ctx)
        }
    }

    /// What is playing, in as much detail as the span allows.
    @MainActor
    private static func drawText(_ state: VLCState, frame: CGRect, cell: CGFloat,
                                 accent: NSColor, background: NSColor,
                                 ctx: CGContext, progress: Bool) {
        guard state.hasTrack else {
            WidgetPaint.message("VLC", state.stopped ? "stopped" : "nothing playing",
                                frame: frame, ctx: ctx, tint: accent)
            return
        }
        let pad = max(6, cell * 0.10)
        let unit = min(frame.width / 2, frame.height)
        let inner = frame.insetBy(dx: pad, dy: pad)

        // The widget frame's origin is at the visual TOP-left: `minY` is the
        // top of the key you are looking at. Laying out from `maxY` put the
        // title under the album, which is the wrong way up.
        let titleSize = unit * 0.20
        let subSize = unit * 0.14
        let gap = max(1, unit * 0.02)

        // The progress block is anchored to the bottom and the text flows
        // from the top, so a 2-row and a 3-row widget put the bar in the same
        // place instead of leaving it floating.
        var bottom = inner.maxY
        if progress, state.length > 0 {
            // The same block the split face and the Spotify widget draw, so
            // one bar does not look like a different app's from the next.
            let barHeight = max(4, unit * 0.055)
            let labelSize = max(9, unit * 0.10)
            bottom = inner.maxY - barHeight - labelSize * 1.35
            WidgetPaint.progressBlock(x: inner.minX, y: bottom, width: inner.width,
                                      height: barHeight, fraction: state.position,
                                      elapsed: VLCState.clock(state.time),
                                      total: VLCState.clock(state.length),
                                      accent: accent,
                                      track: WidgetPaint.mix(background, .white, 0.22),
                                      labelSize: labelSize, labelGap: max(2, unit * 0.04),
                                      bottom: frame.maxY, ctx: ctx)
        }

        var y = inner.minY
        WidgetPaint.line(state.displayTitle,
                         in: CGRect(x: inner.minX, y: y, width: inner.width, height: titleSize),
                         ctx: ctx, size: titleSize * 0.86, color: .white, align: .left)
        y += titleSize + gap
        if !state.artist.isEmpty, y + subSize <= bottom {
            WidgetPaint.line(state.artist,
                             in: CGRect(x: inner.minX, y: y, width: inner.width, height: subSize),
                             ctx: ctx, size: subSize * 0.86, color: WidgetPaint.muted, align: .left)
            y += subSize + gap
        }
        if !state.album.isEmpty, y + subSize <= bottom {
            WidgetPaint.line(state.album,
                             in: CGRect(x: inner.minX, y: y, width: inner.width, height: subSize),
                             ctx: ctx, size: subSize * 0.78, color: WidgetPaint.muted, align: .left)
        }
        WidgetPaint.stateDot(playing: state.playing, frame: frame, cell: cell,
                             accent: accent, ctx: ctx)
    }
}
