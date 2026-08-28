import AppKit
import Foundation

/// Live scores from ESPN's public scoreboard endpoints.
///
/// Same reason as Open-Meteo: no key, no account. The path shape is
/// `/apis/site/v2/sports/{sport}/{league}/scoreboard`, and the league name the
/// user types is mapped to its sport here so "nba" is enough.
struct GameReading {
    var home: String = ""
    var away: String = ""
    var homeScore: String = ""
    var awayScore: String = ""
    var status: String = ""
    var detail: String = ""
    var live: Bool = false
    var final: Bool = false

    var signature: String {
        "\(away)\(awayScore)@\(home)\(homeScore)|\(status)|\(detail)|\(live)|\(final)"
    }
}

struct SportsPage {
    var games: [GameReading] = []
    var league: String = ""
    var page: Int = 0
    var pages: Int = 1
    var ok: Bool = true
    var error: String = ""

    var signature: String {
        "\(ok)|\(error)|\(league)|\(page)/\(pages)|"
            + games.map(\.signature).joined(separator: ",")
    }
}

actor SportsProvider: WidgetProviding {
    /// The leagues ESPN exposes, and the sport each belongs to.
    static let leagues: [String: String] = [
        "nfl": "football", "college-football": "football",
        "nba": "basketball", "wnba": "basketball", "mens-college-basketball": "basketball",
        "mlb": "baseball", "nhl": "hockey",
        "eng.1": "soccer", "esp.1": "soccer", "ger.1": "soccer", "ita.1": "soccer",
        "fra.1": "soccer", "usa.1": "soccer", "uefa.champions": "soccer",
    ]

    private var pages: [WidgetConfig: Int] = [:]
    private static let timeout: TimeInterval = 8

    nonisolated func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        let page = SportsPage(league: Self.league(config))
        return WidgetSnapshot(signature: "sports:placeholder|" + page.signature, payload: page)
    }

    nonisolated static func league(_ config: WidgetConfig) -> String {
        let raw = config.place.trimmingCharacters(in: .whitespaces).lowercased()
        return leagues[raw] != nil ? raw : "nfl"
    }

    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        let league = Self.league(config)
        let sport = Self.leagues[league] ?? "football"
        do {
            var games = try await scoreboard(sport: sport, league: league)
            // A team filter turns "what's on" into "how are MY team doing",
            // which is what a single key is actually for.
            let wanted = config.symbols
                .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                .filter { !$0.isEmpty }
            if !wanted.isEmpty {
                games = games.filter { wanted.contains($0.home) || wanted.contains($0.away) }
            }
            // Live games first, then upcoming, then finished: a deck key
            // should show the thing that is happening now.
            games.sort { a, b in
                if a.live != b.live { return a.live }
                if a.final != b.final { return b.final }
                return false
            }
            let cells = max(1, cells)
            let pageCount = max(1, Int(ceil(Double(max(games.count, 1)) / Double(cells))))
            let page = (pages[config] ?? 0) % pageCount
            let visible = Array(games.dropFirst(page * cells).prefix(cells))
            let result = SportsPage(games: visible, league: league.uppercased(),
                                    page: page, pages: pageCount,
                                    ok: true,
                                    error: games.isEmpty ? "no games" : "")
            return WidgetSnapshot(signature: "sports:" + result.signature, payload: result)
        } catch {
            let result = SportsPage(league: league.uppercased(), ok: false,
                                    error: Self.describe(error))
            return WidgetSnapshot(signature: "sports:" + result.signature, payload: result)
        }
    }

    func press(_ config: WidgetConfig, cell: WidgetCell, snapshot: WidgetSnapshot) async -> Bool {
        guard config.press == "cycle" else { return false }
        let pageCount = snapshot.data(SportsPage.self)?.pages ?? 1
        guard pageCount > 1 else { return false }
        pages[config] = ((pages[config] ?? 0) + 1) % pageCount
        return true
    }

    // MARK: - Network

    private func scoreboard(sport: String, league: String) async throws -> [GameReading] {
        let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/"
                      + "\(sport)/\(league)/scoreboard")!
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WidgetError.message("HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]]
        else { throw WidgetError.message("bad response") }

        return events.compactMap { event in
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let competitors = competition["competitors"] as? [[String: Any]]
            else { return nil }
            var game = GameReading()
            for side in competitors {
                let team = side["team"] as? [String: Any]
                let abbreviation = (team?["abbreviation"] as? String)
                    ?? (team?["shortDisplayName"] as? String) ?? "?"
                let score = (side["score"] as? String) ?? ""
                if (side["homeAway"] as? String) == "home" {
                    game.home = abbreviation; game.homeScore = score
                } else {
                    game.away = abbreviation; game.awayScore = score
                }
            }
            let status = competition["status"] as? [String: Any]
            let type = status?["type"] as? [String: Any]
            let state = (type?["state"] as? String) ?? ""
            game.live = state == "in"
            game.final = state == "post"
            game.status = (type?["shortDetail"] as? String)
                ?? (type?["detail"] as? String) ?? ""
            if game.live, let clock = status?["displayClock"] as? String,
               let period = status?["period"] as? Int {
                game.detail = "Q\(period) \(clock)"
            } else {
                game.detail = game.status
            }
            return game
        }
    }

    private static func describe(_ error: Error) -> String {
        if let widget = error as? WidgetError { return widget.text }
        if (error as NSError).domain == NSURLErrorDomain { return "offline" }
        return String(error.localizedDescription.prefix(40))
    }

    // MARK: - Painting

    @MainActor
    func draw(_ snapshot: WidgetSnapshot, config: WidgetConfig,
                          columns: Int, rows: Int, background: NSColor, ctx: CGContext) {
        let cell = CGFloat(DeckLayout.keyPixels)
        let frame = CGRect(x: 0, y: 0, width: CGFloat(columns) * cell,
                           height: CGFloat(rows) * cell)
        let page = snapshot.data(SportsPage.self) ?? SportsPage()
        guard !page.games.isEmpty else {
            WidgetPaint.message(page.league.isEmpty ? "Sports" : page.league,
                                page.error.isEmpty ? "loading…" : page.error,
                                frame: frame, ctx: ctx,
                                tint: WidgetPaint.mix(background, .white, 0.85))
            return
        }
        let compact = config.style == "compact"
            || (config.style == "auto" && columns < 2)
        for (index, game) in page.games.enumerated() {
            let rect = CGRect(x: CGFloat(index % columns) * cell,
                              y: CGFloat(index / columns) * cell,
                              width: cell * (compact ? 1 : min(CGFloat(columns), 2)),
                              height: cell)
            drawGame(game, rect: compact ? rect : CGRect(x: CGFloat(index % columns) * cell,
                                                         y: CGFloat(index / columns) * cell,
                                                         width: cell, height: cell),
                     cell: cell, compact: compact, background: background, ctx: ctx)
        }
    }

    @MainActor
    private func drawGame(_ game: GameReading, rect: CGRect, cell: CGFloat,
                                      compact: Bool, background: NSColor, ctx: CGContext) {
        let accent = game.live ? WidgetPaint.green
            : (game.final ? WidgetPaint.muted
               : NSColor(srgbRed: 0.16, green: 0.80, blue: 0.95, alpha: 1))
        WidgetPaint.roundedRect(rect.insetBy(dx: 1, dy: 1), radius: cell * 0.10,
                                WidgetPaint.mix(background, accent, 0.12), ctx: ctx)
        let pad = max(3, cell * 0.07)
        let width = rect.width - 2 * pad
        let scoreWidth = width * 0.38

        var y = rect.minY + pad
        for (team, score) in [(game.away, game.awayScore), (game.home, game.homeScore)] {
            WidgetPaint.line(team, in: CGRect(x: rect.minX + pad, y: y,
                                              width: width - scoreWidth, height: cell * 0.26),
                             ctx: ctx, size: cell * 0.20, color: .white)
            WidgetPaint.line(score.isEmpty ? "–" : score,
                             in: CGRect(x: rect.maxX - pad - scoreWidth, y: y,
                                        width: scoreWidth, height: cell * 0.26),
                             ctx: ctx, size: cell * 0.22, color: .white, align: .right)
            y += cell * 0.27
        }
        // A live pip: the difference between a score you should look at and
        // one that finished last night.
        if game.live {
            let r = max(2, cell * 0.03)
            ctx.setFillColor(WidgetPaint.green.cgColor)
            ctx.fillEllipse(in: CGRect(x: rect.maxX - pad - 2 * r, y: rect.maxY - cell * 0.19,
                                       width: 2 * r, height: 2 * r))
        }
        WidgetPaint.line(game.detail, in: CGRect(x: rect.minX + pad, y: rect.maxY - cell * 0.20,
                                                 width: width - (game.live ? cell * 0.1 : 0),
                                                 height: cell * 0.17),
                         ctx: ctx, size: cell * 0.12,
                         color: WidgetPaint.mix(background, .white, 0.6))
    }
}
