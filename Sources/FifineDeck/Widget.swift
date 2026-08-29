import AppKit
import Foundation

/// Live widgets: key faces that show something from outside the deck — what
/// Spotify is playing, what a stock is doing — instead of a static icon.
///
/// A widget is configured on ONE key (its anchor) and may span a rectangle of
/// keys from there. The keys it covers keep their own configuration in
/// `settings.json` and get it straight back when the widget shrinks, so
/// resizing a widget is never destructive.
///
/// The deck already knows how to treat several keys as one picture — that is
/// what `DeckPattern.wallpaper` does — so a widget paints one frame the size
/// of its span and `DeckCanvas` cuts it into per-key tiles.

// MARK: - Kinds

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case spotify
    case stocks
    case clock
    case weather
    case system
    case sports
    case timer
    case calendar
    case vlc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotify:  return "Spotify now playing"
        case .stocks:   return "Stock ticker"
        case .clock:    return "Clock"
        case .weather:  return "Weather"
        case .system:   return "System monitor"
        case .sports:   return "Sports scores"
        case .timer:    return "Timer"
        case .calendar: return "Next calendar event"
        case .vlc:      return "VLC on the network"
        }
    }

    /// Layout choices offered for this kind. "auto" picks by span.
    var styles: [String] {
        switch self {
        case .spotify:  return ["auto", "art", "art+text", "split", "progress",
                                "text", "button", "controls"]
        case .stocks:   return ["auto", "card", "compact", "graph"]
        case .clock:    return ["auto", "digital", "analog", "date"]
        case .weather:  return ["auto", "current", "detail"]
        case .system:   return ["auto", "number", "gauge", "graph"]
        case .sports:   return ["auto", "score", "compact"]
        case .timer:    return ["auto", "ring", "digits"]
        case .calendar: return ["auto", "next", "agenda"]
        case .vlc:      return ["auto", "progress", "text", "button", "controls"]
        }
    }

    /// Styles that ignore `press` because they define their own per-key
    /// actions. A "controls" widget IS the transport bar.
    var stylesWithOwnActions: [String] {
        switch self {
        case .spotify, .vlc: return ["controls"]
        default:             return []
        }
    }

    var presses: [String] {
        switch self {
        case .spotify:  return ["play_pause", "next", "previous", "none"]
        case .stocks:   return ["cycle", "none"]
        case .clock:    return ["none"]
        case .weather:  return ["refresh", "none"]
        case .system:   return ["cycle", "none"]
        case .sports:   return ["cycle", "none"]
        case .timer:    return ["start_pause", "reset", "none"]
        case .calendar: return ["open", "none"]
        case .vlc:      return ["play_pause", "next", "previous", "stop", "none"]
        }
    }

    var defaultPress: String { presses[0] }

    var defaultInterval: Double {
        switch self {
        case .spotify:  return 3
        case .stocks:   return 30
        case .clock:    return 1
        case .weather:  return 900        // the sky does not move that fast
        case .system:   return 2
        case .sports:   return 60
        case .timer:    return 1
        case .calendar: return 60
        case .vlc:      return 2
        }
    }

    /// The floor exists to protect whatever is on the other end, not the deck.
    /// A 0.1 s poll would hammer the Spotify Web API; Finnhub's free tier
    /// allows 60 calls a minute; Open-Meteo and ESPN are free and unmetered
    /// but should not be hit every second either.
    var minimumInterval: Double {
        switch self {
        case .spotify:  return 1
        case .stocks:   return 5
        case .clock:    return 1
        case .weather:  return 300
        case .system:   return 1
        case .sports:   return 20
        case .timer:    return 1
        case .calendar: return 15
        // A machine on your own LAN, answering a tiny JSON document.
        case .vlc:      return 1
        }
    }

    /// Kinds driven by a user-supplied list that the widget pages through.
    var usesSymbols: Bool {
        switch self {
        case .stocks, .system, .sports: return true
        default: return false
        }
    }

    /// Kinds with a single free-text target: a city, a league.
    var usesPlace: Bool {
        switch self {
        // VLC reuses `place` for the address of the machine running it: it is
        // the same thing the field already is - one free-text target - and a
        // field per kind would be a field per kind.
        case .weather, .sports, .vlc: return true
        default: return false
        }
    }

    /// Kinds whose data is local: no network, so nothing to rate limit and
    /// nothing to explain when it is offline.
    var isLocal: Bool {
        switch self {
        case .clock, .system, .timer, .calendar: return true
        case .spotify, .stocks, .weather, .sports, .vlc: return false
        }
    }
}

// MARK: - Configuration

/// What one widget is set to. Stored on its anchor key in `settings.json`.
struct WidgetConfig: Codable, Equatable, Hashable {
    var kind: WidgetKind = .spotify
    var style: String = "auto"
    var columns: Int = 1
    var rows: Int = 1
    var interval: Double = 3
    var press: String = "play_pause"

    /// Spotify only: "auto", "local" (the Spotify app over AppleScript) or
    /// "web" (the Web API, which follows playback on any device).
    var source: String = "auto"

    /// Stocks, system and sports: the list this widget cycles through.
    var symbols: String = ""
    var rotate: Double = 0            // seconds between pages, 0 = off

    /// Clock: an IANA zone ("Europe/Paris"), or "" for this Mac's.
    var timezone: String = ""
    /// Weather: the place to look up. Sports: the league.
    var place: String = ""
    /// Weather units, and any other yes/no-ish secondary choice.
    var units: String = "metric"
    /// Timer length in minutes.
    var minutes: Double = 25

    static let maximumInterval: Double = 3600

    init(kind: WidgetKind) {
        self.kind = kind
        self.interval = kind.defaultInterval
        self.press = kind.defaultPress
        switch kind {
        case .stocks:  symbols = "AAPL, MSFT, NVDA"
        case .system:  symbols = "cpu, memory"
        case .weather: place = "London"
        case .sports:  place = "nfl"
        case .vlc:     place = "192.168.1.10:8080"
        default:       break
        }
    }

    /// Decoded field by field with defaults.
    ///
    /// Swift's synthesised decoder does NOT fall back to a property's default
    /// when a key is missing — it throws. Every widget added after this point
    /// brings new fields, and without this a settings file written by an
    /// earlier build would fail to decode and take the whole deck layout with
    /// it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(WidgetKind.self, forKey: .kind) ?? .spotify
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "auto"
        columns = try c.decodeIfPresent(Int.self, forKey: .columns) ?? 1
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 1
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? kind.defaultInterval
        press = try c.decodeIfPresent(String.self, forKey: .press) ?? kind.defaultPress
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "auto"
        symbols = try c.decodeIfPresent(String.self, forKey: .symbols) ?? ""
        rotate = try c.decodeIfPresent(Double.self, forKey: .rotate) ?? 0
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? ""
        place = try c.decodeIfPresent(String.self, forKey: .place) ?? ""
        units = try c.decodeIfPresent(String.self, forKey: .units) ?? "metric"
        minutes = try c.decodeIfPresent(Double.self, forKey: .minutes) ?? 25
    }

    /// Every field forced into range. Applied on load and on every edit, so
    /// nothing downstream has to defend against a hand-edited settings file.
    var normalized: WidgetConfig {
        var out = self
        if !kind.styles.contains(out.style) { out.style = "auto" }
        if !kind.presses.contains(out.press) { out.press = kind.defaultPress }
        out.columns = min(max(out.columns, 1), DeckLayout.columns)
        out.rows = min(max(out.rows, 1), DeckLayout.rows)
        out.interval = min(max(out.interval, kind.minimumInterval), Self.maximumInterval)
        out.rotate = out.rotate <= 0 ? 0 : min(max(out.rotate, 2), Self.maximumInterval)
        out.minutes = min(max(out.minutes, 1), 600)
        if kind == .spotify {
            if !["auto", "local", "web"].contains(out.source) { out.source = "auto" }
        } else {
            out.source = "auto"
        }
        // Fields belonging to another kind are cleared rather than carried:
        // they would otherwise split the data-stream cache key (see `key()`)
        // between two widgets that are configured identically.
        // Rotation is page-turning, and only the list-driven kinds have pages.
        if !kind.usesSymbols { out.symbols = ""; out.rotate = 0 }
        if kind != .clock { out.timezone = "" }
        if !kind.usesPlace { out.place = "" }
        if kind != .weather { out.units = "metric" }
        if kind != .timer { out.minutes = 25 }
        return out
    }

    /// The symbol list, normalised. Accepts commas, spaces and newlines;
    /// uppercases; keeps the typed order; drops duplicates.
    var symbolList: [String] {
        var seen = Set<String>()
        var out: [String] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:-^_"))
        for raw in symbols.components(separatedBy: CharacterSet(charactersIn: ", \n\t")) {
            let symbol = raw.uppercased().unicodeScalars.filter(allowed.contains)
                .reduce(into: "") { $0.unicodeScalars.append($1) }
            guard !symbol.isEmpty, !seen.contains(symbol) else { continue }
            seen.insert(symbol)
            out.append(symbol)
            if out.count >= 32 { break }        // a deck has 15 keys
        }
        return out
    }

    /// Human label for the span picker, e.g. "3 x 2".
    static func spanTitle(columns: Int, rows: Int) -> String { "\(columns) × \(rows)" }
}

// MARK: - Layout

/// One key painted by a widget. `dx`/`dy` is its position inside the frame;
/// `columns`/`rows` is the widget's EFFECTIVE span after clipping.
struct WidgetCell: Equatable {
    let anchor: Int
    let config: WidgetConfig
    let dx: Int
    let dy: Int
    let columns: Int
    let rows: Int

    var isAnchor: Bool { dx == 0 && dy == 0 }
    var cellCount: Int { columns * rows }
}

enum WidgetLayout {
    /// Maps every key index a widget paints to its cell.
    ///
    /// Anchors are resolved in key order, so an earlier key wins a contested
    /// cell. A widget never wraps onto the next row and never overlaps
    /// another widget: its span shrinks — widest dimension first — until the
    /// rectangle is free. A widget that cannot claim a single neighbour still
    /// paints its own key at 1x1, because configuring a span must never make
    /// a key go dark.
    static func cells(for keys: [KeyConfig]) -> [Int: WidgetCell] {
        let anchors: [(index: Int, config: WidgetConfig)] = keys.enumerated().compactMap {
            guard let widget = $0.element.widget else { return nil }
            return ($0.offset, widget.normalized)
        }
        guard !anchors.isEmpty else { return [:] }

        let anchorSet = Set(anchors.map(\.index))
        var claimed: [Int: WidgetCell] = [:]

        for (anchor, config) in anchors {
            let row = anchor / DeckLayout.columns
            let column = anchor % DeckLayout.columns
            var columns = min(config.columns, DeckLayout.columns - column)
            var rows = min(config.rows, DeckLayout.rows - row)

            func fits(_ w: Int, _ h: Int) -> Bool {
                for dy in 0..<h {
                    for dx in 0..<w {
                        let index = (row + dy) * DeckLayout.columns + (column + dx)
                        if index == anchor { continue }
                        if claimed[index] != nil || anchorSet.contains(index) { return false }
                    }
                }
                return true
            }

            while (columns > 1 || rows > 1) && !fits(columns, rows) {
                if columns >= rows { columns -= 1 } else { rows -= 1 }
            }

            for dy in 0..<rows {
                for dx in 0..<columns {
                    let index = (row + dy) * DeckLayout.columns + (column + dx)
                    claimed[index] = WidgetCell(anchor: anchor, config: config,
                                                dx: dx, dy: dy,
                                                columns: columns, rows: rows)
                }
            }
        }
        return claimed
    }
}

// MARK: - Data

/// What a provider hands back: an opaque payload plus the one thing the
/// controller needs to reason about — whether the picture would change.
///
/// Opaque rather than a field per kind: with eight widgets, a struct with
/// eight optionals in it means every provider can see (and get wrong) every
/// other provider's data.
struct WidgetSnapshot {
    /// Changes whenever the painted frame would change. The controller
    /// repaints on a new signature and does nothing on a repeat, which is
    /// what keeps an idle widget off the USB bus entirely.
    var signature: String
    var payload: Any?

    init(signature: String, payload: Any? = nil) {
        self.signature = signature
        self.payload = payload
    }

    /// Typed access for a provider that knows what it put in.
    func data<T>(_ type: T.Type = T.self) -> T? { payload as? T }

    static func empty(for kind: WidgetKind) -> WidgetSnapshot {
        WidgetRegistry.provider(for: kind).placeholder(WidgetConfig(kind: kind), cells: 1)
    }
}

/// CGImage is immutable and thread-safe, but not formally Sendable; album art
/// crosses from the fetch task to the render on the main actor.
extension WidgetSnapshot: @unchecked Sendable {}

// MARK: - Providers

/// Everything a widget kind has to supply. One conformance per file, so
/// adding a widget touches nothing that already works.
protocol WidgetProviding {
    /// What to show before the first fetch lands.
    func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot

    /// Fetch fresh data. May suspend on the network; never called on the main
    /// actor's critical path.
    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot

    /// Act on a press of one particular key of the widget. Returns true when
    /// the widget's OWN state changed, so the caller can refetch at once.
    func press(_ config: WidgetConfig, cell: WidgetCell, snapshot: WidgetSnapshot) async -> Bool

    /// Paint the whole widget into a frame `columns x rows` keys in size.
    @MainActor
    func draw(_ snapshot: WidgetSnapshot, config: WidgetConfig,
              columns: Int, rows: Int, background: NSColor, ctx: CGContext)

    /// The action a given key runs. Only the transport bar answers per-key.
    func action(for config: WidgetConfig, cell: WidgetCell) -> String
}

extension WidgetProviding {
    func press(_ config: WidgetConfig, cell: WidgetCell, snapshot: WidgetSnapshot) async -> Bool {
        false
    }
    func action(for config: WidgetConfig, cell: WidgetCell) -> String { config.press }
}

/// Maps a kind to its provider. The single place that has to change when a
/// widget is added.
enum WidgetRegistry {
    private static let providers: [WidgetKind: any WidgetProviding] = [
        .spotify: SpotifyProvider(),
        .stocks: StocksProvider(),
        .clock: ClockProvider(),
        .weather: WeatherProvider(),
        .system: SystemProvider(),
        .sports: SportsProvider(),
        .timer: TimerProvider(),
        .calendar: CalendarProvider(),
        .vlc: VLCProvider(),
    ]

    static func provider(for kind: WidgetKind) -> any WidgetProviding {
        // Force-unwrapped deliberately: a kind with no provider is a
        // programming error that must fail loudly in the first second of
        // running, not paint a blank key forever.
        providers[kind]!
    }
}
