import AppKit
import Foundation

/// Stock ticker: live quotes from Finnhub, one symbol per key.
///
/// A widget spanning N keys shows N symbols; list more than that and the extra
/// ones become pages the widget rotates through (or that a press steps to).
/// One quote cache is shared by every widget on the deck, so two keys watching
/// AAPL cost one request, not two.
///
/// Needs a free Finnhub API key (finnhub.io) in the environment as
/// `FINNHUB_KEY` or stored via the key editor.

// MARK: - Data

struct StockQuote {
    var symbol: String
    var price: Double? = nil
    var change: Double? = nil
    var percent: Double? = nil
    var high: Double? = nil
    var low: Double? = nil
    var open: Double? = nil
    var previousClose: Double? = nil
    var ok: Bool = false
    var error: String = ""
    var history: [Double] = []

    var signature: String {
        let p = price.map { String(format: "%.2f", $0) } ?? "—"
        let c = percent.map { String(format: "%.2f", $0) } ?? "—"
        return "\(symbol):\(ok):\(error):\(p):\(c):\(history.count)"
    }
}

/// The symbols one widget is showing right now, plus where it is in the list.
struct StockPage {
    var quotes: [StockQuote] = []
    var page: Int = 0
    var pages: Int = 1
    var ok: Bool = true
    var error: String = ""

    var signature: String {
        "\(ok)|\(error)|\(page)/\(pages)|" + quotes.map(\.signature).joined(separator: ",")
    }
}

// MARK: - Provider

actor StocksProvider {
    private var quotes: [String: StockQuote] = [:]
    private var history: [String: [Double]] = [:]
    private var lastFetch: [String: Date] = [:]
    /// Per-widget page position: (page, when it last turned).
    private var pages: [WidgetConfig: (page: Int, since: Date)] = [:]

    private static let base = "https://finnhub.io/api/v1"
    private static let timeout: TimeInterval = 6
    private static let historyLimit = 64
    /// Finnhub's free tier allows 60 calls a minute. A symbol is never
    /// re-requested faster than this however many widgets watch it.
    private static let minimumGap: TimeInterval = 5
    private static let trackedLimit = 64

    static var configured: Bool { WidgetCredentials.has(.finnhub) }

    func quotes(_ config: WidgetConfig, cells: Int) async -> StockPage {
        let symbols = config.symbolList
        guard !symbols.isEmpty else {
            return StockPage(quotes: [], ok: false, error: "no symbols")
        }
        guard Self.configured else {
            return StockPage(quotes: [], ok: false, error: "no API key")
        }
        let cells = max(1, cells)
        let pageCount = max(1, Int(ceil(Double(symbols.count) / Double(cells))))
        let page = advance(config, pages: pageCount)
        let visible = Array(symbols.dropFirst(page * cells).prefix(cells))

        var errors: [String] = []
        for symbol in visible {
            let gap = max(Self.minimumGap, config.interval * 0.9)
            if let last = lastFetch[symbol], quotes[symbol] != nil,
               Date().timeIntervalSince(last) < gap { continue }
            do {
                let json = try await Self.get("/quote", ["symbol": symbol])
                store(symbol, json)
            } catch {
                let text = Self.describe(error)
                errors.append(text)
                lastFetch[symbol] = Date()
                // Keep the last good price on screen and mark it stale rather
                // than blanking a whole page because one request timed out.
                if var existing = quotes[symbol] {
                    existing.ok = false
                    existing.error = text
                    quotes[symbol] = existing
                } else {
                    quotes[symbol] = StockQuote(symbol: symbol, ok: false, error: text)
                }
            }
        }

        var out = visible.map { symbol -> StockQuote in
            var quote = quotes[symbol] ?? StockQuote(symbol: symbol)
            quote.history = history[symbol] ?? []
            return quote
        }
        if out.isEmpty { out = [] }
        evict()
        let ok = out.contains(where: \.ok) || errors.isEmpty
        return StockPage(quotes: out, page: page, pages: pageCount, ok: ok,
                         error: ok ? "" : (errors.first ?? ""))
    }

    func placeholderPage(_ config: WidgetConfig, cells: Int) -> StockPage {
        let symbols = config.symbolList
        let cells = max(1, cells)
        let pageCount = max(1, Int(ceil(Double(max(symbols.count, 1)) / Double(cells))))
        return StockPage(quotes: symbols.prefix(cells).map { StockQuote(symbol: $0) },
                         pages: pageCount)
    }

    private func store(_ symbol: String, _ json: [String: Any]) {
        lastFetch[symbol] = Date()
        let price = Self.number(json["c"])
        guard let price, price != 0 else {
            // Finnhub answers an unknown symbol with 200 and all-zero fields,
            // so a typo must become a visible error, not a $0.00 card.
            quotes[symbol] = StockQuote(symbol: symbol, ok: false, error: "no data")
            return
        }
        let previous = Self.number(json["pc"])
        var series = history[symbol] ?? []
        if series.isEmpty, let previous {
            // Seed with the previous close so the first poll already draws a
            // line instead of an empty box.
            series.append(previous)
        }
        series.append(price)
        if series.count > Self.historyLimit { series.removeFirst(series.count - Self.historyLimit) }
        history[symbol] = series
        quotes[symbol] = StockQuote(
            symbol: symbol, price: price,
            change: Self.number(json["d"]), percent: Self.number(json["dp"]),
            high: Self.number(json["h"]), low: Self.number(json["l"]),
            open: Self.number(json["o"]), previousClose: previous, ok: true)
    }

    /// Editing the symbol field types through a dozen dead tickers ("A", "AA",
    /// "AAP", …); without this they accumulate for the life of the process.
    private func evict() {
        guard quotes.count > Self.trackedLimit else { return }
        let keep = Set(quotes.keys
            .sorted { (lastFetch[$0] ?? .distantPast) > (lastFetch[$1] ?? .distantPast) }
            .prefix(Self.trackedLimit / 2))
        for symbol in quotes.keys where !keep.contains(symbol) {
            quotes.removeValue(forKey: symbol)
            history.removeValue(forKey: symbol)
            lastFetch.removeValue(forKey: symbol)
        }
    }

    private func advance(_ config: WidgetConfig, pages count: Int) -> Int {
        let now = Date()
        var state = pages[config] ?? (page: 0, since: now)
        if count <= 1 {
            state.page = 0
        } else if config.rotate > 0, now.timeIntervalSince(state.since) >= config.rotate {
            state.page = (state.page + 1) % count
            state.since = now
        } else {
            state.page %= count
        }
        pages[config] = state
        return state.page
    }

    func press(_ config: WidgetConfig, pageCount: Int) {
        guard config.press == "cycle", pageCount > 1 else { return }
        let state = pages[config] ?? (page: 0, since: Date())
        pages[config] = (page: (state.page + 1) % pageCount, since: Date())
    }

    // MARK: HTTP

    private static func get(_ path: String, _ params: [String: String]) async throws -> [String: Any] {
        let key = WidgetCredentials.value(.finnhub)
        guard !key.isEmpty else { throw WidgetError.message("no API key") }
        var components = URLComponents(string: base + path)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "token", value: key)]
        guard let url = components.url else { throw WidgetError.message("bad symbol") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WidgetError.message(http.statusCode == 429 ? "rate limited"
                                                             : "HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WidgetError.message("bad response")
        }
        return json
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func describe(_ error: Error) -> String {
        if let widget = error as? WidgetError { return widget.text }
        if (error as NSError).domain == NSURLErrorDomain { return "offline" }
        return String(error.localizedDescription.prefix(40))
    }
}

// MARK: - Rendering

enum StocksWidgetRenderer {
    static func style(for config: WidgetConfig) -> String {
        config.style == "auto" ? "card" : config.style
    }

    static func draw(_ page: StockPage, config: WidgetConfig, columns: Int, rows: Int,
                     background: NSColor, ctx: CGContext) {
        let cell = CGFloat(DeckLayout.keyPixels)
        let frame = CGRect(x: 0, y: 0, width: CGFloat(columns) * cell,
                           height: CGFloat(rows) * cell)
        guard !page.quotes.isEmpty else {
            WidgetPaint.message("Stocks", page.error.isEmpty ? "no symbols" : page.error,
                                frame: frame, ctx: ctx,
                                tint: WidgetPaint.mix(background, .white, 0.85))
            return
        }
        if style(for: config) == "graph" {
            drawGraph(page.quotes[0], frame: frame, cell: cell, background: background, ctx: ctx)
            return
        }
        let compact = style(for: config) == "compact"
        for (i, quote) in page.quotes.enumerated() {
            let origin = CGPoint(x: CGFloat(i % columns) * cell, y: CGFloat(i / columns) * cell)
            drawCard(quote, at: origin, cell: cell, background: background,
                     compact: compact, ctx: ctx)
        }
        if page.pages > 1 {
            drawPips(page, frame: frame, cell: cell,
                     color: WidgetPaint.mix(background, .white, 0.55), ctx: ctx)
            if config.press == "cycle" {
                // Only worth advertising when there is somewhere to cycle TO.
                // A stroked arrow, not a ".fill" one: filled SF Symbols that
                // are circle-shaped render as a solid white disc inside the
                // badge's own disc, which is no glyph at all.
                WidgetPaint.actionBadge("arrow.forward", frame: frame,
                                        cell: cell, tint: WidgetPaint.mix(background, .white, 0.7),
                                        ctx: ctx)
            }
        }
    }

    // MARK: Faces

    private static func drawCard(_ quote: StockQuote, at origin: CGPoint, cell: CGFloat,
                                 background: NSColor, compact: Bool, ctx: CGContext) {
        let pad = max(2, cell * 0.05)
        let trend = trendColor(quote)
        let face = WidgetPaint.mix(background, trend, quote.ok ? 0.10 : 0.03)
        WidgetPaint.roundedRect(CGRect(x: origin.x + 1, y: origin.y + 1,
                                       width: cell - 2, height: cell - 2),
                                radius: cell * 0.10, face, ctx: ctx)
        let innerWidth = cell - 2 * pad - 2
        let percentHeight = cell * 0.16 * 1.3

        // The percentage line owns the bottom of the card and the sparkline
        // stops above it: drawn on top of each other the number sits in the
        // middle of the fill and is unreadable at arm's length.
        if !quote.history.isEmpty, quote.ok, !compact {
            let top = origin.y + cell * 0.50
            let bottom = origin.y + cell - pad - percentHeight
            if bottom - top > cell * 0.12 {
                WidgetPaint.sparkline(quote.history,
                                      in: CGRect(x: origin.x + pad, y: top,
                                                 width: cell - 2 * pad, height: bottom - top),
                                      ctx: ctx, color: WidgetPaint.mix(face, trend, 0.85),
                                      fill: WidgetPaint.mix(face, trend, 0.28))
            }
        }

        var y = origin.y + pad
        y += WidgetPaint.line(quote.symbol,
                              in: CGRect(x: origin.x + pad + 1, y: y,
                                         width: innerWidth, height: cell * 0.34),
                              ctx: ctx, size: cell * (compact ? 0.26 : 0.20), color: .white)

        guard quote.ok || quote.price != nil else {
            WidgetPaint.line(quote.error.isEmpty ? "n/a" : quote.error,
                             in: CGRect(x: origin.x + pad + 1, y: y,
                                        width: innerWidth, height: cell * 0.2),
                             ctx: ctx, size: cell * 0.13, color: WidgetPaint.muted)
            return
        }

        if compact {
            WidgetPaint.line(formatPercent(quote.percent),
                             in: CGRect(x: origin.x + pad + 1, y: origin.y + cell * 0.44,
                                        width: innerWidth, height: cell * 0.34),
                             ctx: ctx, size: cell * 0.26, color: trend)
            WidgetPaint.line(formatPrice(quote.price),
                             in: CGRect(x: origin.x + pad + 1, y: origin.y + cell * 0.76,
                                        width: innerWidth, height: cell * 0.22),
                             ctx: ctx, size: cell * 0.15,
                             color: WidgetPaint.mix(face, .white, 0.65))
            return
        }

        WidgetPaint.line(formatPrice(quote.price),
                         in: CGRect(x: origin.x + pad + 1, y: y,
                                    width: innerWidth, height: cell * 0.32),
                         ctx: ctx, size: cell * 0.24, color: .white, shadow: true)
        WidgetPaint.line(formatPercent(quote.percent),
                         in: CGRect(x: origin.x + pad + 1,
                                    y: origin.y + cell - pad - percentHeight,
                                    width: innerWidth, height: percentHeight),
                         ctx: ctx, size: cell * 0.16, color: trend, shadow: true)
        if !quote.ok {
            // Stale: the last price is still shown, but say so.
            let r = max(2, cell * 0.035)
            ctx.setFillColor(WidgetPaint.muted.cgColor)
            ctx.fillEllipse(in: CGRect(x: origin.x + cell - pad - 2 * r, y: origin.y + pad,
                                       width: 2 * r, height: 2 * r))
        }
    }

    private static func drawGraph(_ quote: StockQuote, frame: CGRect, cell: CGFloat,
                                  background: NSColor, ctx: CGContext) {
        let pad = max(4, cell * 0.08)
        let trend = trendColor(quote)
        WidgetPaint.fill(frame, WidgetPaint.mix(background, trend, 0.10), ctx: ctx)
        if !quote.history.isEmpty {
            WidgetPaint.sparkline(quote.history,
                                  in: CGRect(x: pad, y: frame.height * 0.42,
                                             width: frame.width - 2 * pad,
                                             height: frame.height * 0.58 - pad),
                                  ctx: ctx, color: WidgetPaint.mix(background, trend, 0.9),
                                  fill: WidgetPaint.mix(background, trend, 0.30), width: 3)
        }
        var y = frame.minY + pad
        y += WidgetPaint.line(quote.symbol,
                              in: CGRect(x: pad, y: y, width: frame.width - 2 * pad, height: cell * 0.32),
                              ctx: ctx, size: cell * 0.24, color: .white)
        guard quote.ok || quote.price != nil else {
            WidgetPaint.line(quote.error.isEmpty ? "n/a" : quote.error,
                             in: CGRect(x: pad, y: y, width: frame.width - 2 * pad, height: cell * 0.26),
                             ctx: ctx, size: cell * 0.18, color: WidgetPaint.muted)
            return
        }
        WidgetPaint.line(formatPrice(quote.price),
                         in: CGRect(x: pad, y: y, width: frame.width - 2 * pad, height: cell * 0.38),
                         ctx: ctx, size: cell * 0.30, color: .white, shadow: true)
        WidgetPaint.line(formatPercent(quote.percent),
                         in: CGRect(x: pad, y: frame.minY + pad,
                                    width: frame.width - 2 * pad, height: cell * 0.28),
                         ctx: ctx, size: cell * 0.20, color: trend, align: .right)
        if let low = quote.low, let high = quote.high {
            WidgetPaint.line("L \(formatPrice(low))   H \(formatPrice(high))",
                             in: CGRect(x: pad, y: y + cell * 0.32,
                                        width: frame.width - 2 * pad, height: cell * 0.2),
                             ctx: ctx, size: cell * 0.13,
                             color: WidgetPaint.mix(background, .white, 0.55))
        }
    }

    /// One pip per page along the bottom edge, so a rotating widget shows
    /// where it is in the list.
    private static func drawPips(_ page: StockPage, frame: CGRect, cell: CGFloat,
                                 color: NSColor, ctx: CGContext) {
        let r = max(1, cell * 0.022)
        let gap = r * 4
        var x = frame.midX - CGFloat(page.pages - 1) * gap / 2
        let y = frame.maxY - r - max(2, cell * 0.03)
        for i in 0..<page.pages {
            let fill = i == page.page ? color : WidgetPaint.mix(color, .black, 0.6)
            ctx.setFillColor((fill.usingColorSpace(.deviceRGB) ?? .gray).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            x += gap
        }
    }

    // MARK: Formatting

    private static func trendColor(_ quote: StockQuote) -> NSColor {
        guard let percent = quote.percent, percent != 0 else { return WidgetPaint.muted }
        return percent > 0 ? WidgetPaint.green : WidgetPaint.red
    }

    /// Fewer decimals as the number grows: a key is 100 px wide, and
    /// "68,231" fits where "68,231.4523" does not.
    static func formatPrice(_ price: Double?) -> String {
        guard let price else { return "—" }
        if price >= 10000 { return decimal(price, places: 0) }
        if price >= 1000 { return decimal(price, places: 1) }
        if price >= 1 { return decimal(price, places: 2) }
        return String(format: "%.4f", price)
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    static func formatPercent(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return String(format: "%@%.2f%%", percent >= 0 ? "▲" : "▼", abs(percent))
    }
}


// MARK: - WidgetProviding

extension StocksProvider: WidgetProviding {
    nonisolated func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        // Synchronous and off the actor: a placeholder is derived from the
        // config alone, so it needs none of the cached quotes.
        let symbols = config.symbolList
        let cells = max(1, cells)
        let pages = max(1, Int(ceil(Double(max(symbols.count, 1)) / Double(cells))))
        let page = StockPage(quotes: symbols.prefix(cells).map { StockQuote(symbol: $0) },
                             pages: pages)
        return WidgetSnapshot(signature: "stocks:placeholder|" + page.signature, payload: page)
    }

    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        let page = await quotes(config, cells: cells)
        return WidgetSnapshot(signature: "stocks:" + page.signature, payload: page)
    }

    func press(_ config: WidgetConfig, cell: WidgetCell, snapshot: WidgetSnapshot) async -> Bool {
        guard config.press != "none" else { return false }
        press(config, pageCount: snapshot.data(StockPage.self)?.pages ?? 1)
        return true
    }

    @MainActor
    func draw(_ snapshot: WidgetSnapshot, config: WidgetConfig,
                          columns: Int, rows: Int, background: NSColor, ctx: CGContext) {
        StocksWidgetRenderer.draw(snapshot.data(StockPage.self) ?? StockPage(),
                                  config: config, columns: columns, rows: rows,
                                  background: background, ctx: ctx)
    }
}
