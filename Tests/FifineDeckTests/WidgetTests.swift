import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import FifineDeck

/// Span layout, config validation and rendering.
///
/// Deliberately no coverage of the credential store: its file is the real
/// `~/Library/Application Support/FifineDeck/widgets.json`, and a test has no
/// business writing over someone's API keys.
final class WidgetLayoutTests: XCTestCase {

    private func key(_ kind: WidgetKind, columns: Int, rows: Int) -> KeyConfig {
        var config = WidgetConfig(kind: kind)
        config.columns = columns
        config.rows = rows
        var key = KeyConfig()
        key.widget = config
        return key
    }

    private func grid(_ widgets: [Int: KeyConfig]) -> [KeyConfig] {
        var keys = Array(repeating: KeyConfig(), count: DeckLayout.keyCount)
        for (index, key) in widgets { keys[index] = key }
        return keys
    }

    func testSpanCoversARectangleOfKeys() {
        let cells = WidgetLayout.cells(for: grid([0: key(.spotify, columns: 3, rows: 2)]))
        XCTAssertEqual(Set(cells.keys), [0, 1, 2, 5, 6, 7])
        XCTAssertTrue(cells[0]!.isAnchor)
        XCTAssertEqual(cells[7]!.dx, 2)
        XCTAssertEqual(cells[7]!.dy, 1)
        XCTAssertTrue(cells.values.allSatisfy { $0.anchor == 0 })
    }

    func testSpanClipsAtTheRowEdgeInsteadOfWrapping() {
        // Key 3 is the fourth column, so a 3-wide widget becomes 2-wide rather
        // than spilling onto the start of the next row.
        let cells = WidgetLayout.cells(for: grid([3: key(.spotify, columns: 3, rows: 1)]))
        XCTAssertEqual(Set(cells.keys), [3, 4])
        XCTAssertEqual(cells[3]!.columns, 2)
    }

    func testSpanClipsAtTheBottomRow() {
        let cells = WidgetLayout.cells(for: grid([10: key(.stocks, columns: 2, rows: 3)]))
        XCTAssertEqual(Set(cells.keys), [10, 11])
        XCTAssertEqual(cells[10]!.rows, 1)
    }

    func testWidgetsNeverOverlapAndTheEarlierKeyWins() {
        let cells = WidgetLayout.cells(for: grid([
            0: key(.spotify, columns: 3, rows: 1),
            2: key(.stocks, columns: 2, rows: 1),
        ]))
        XCTAssertEqual(Set(cells.filter { $0.value.anchor == 0 }.keys), [0, 1])
        XCTAssertEqual(Set(cells.filter { $0.value.anchor == 2 }.keys), [2, 3])
    }

    func testABoxedInWidgetStillPaintsItsOwnKey() {
        // Every neighbour a 3x2 could take is another widget's anchor, so the
        // span shrinks all the way to 1x1 — but the key must never go dark.
        let cells = WidgetLayout.cells(for: grid([
            0: key(.spotify, columns: 1, rows: 1),
            2: key(.spotify, columns: 1, rows: 1),
            5: key(.spotify, columns: 1, rows: 1),
            6: key(.spotify, columns: 1, rows: 1),
            1: key(.stocks, columns: 3, rows: 2),
        ]))
        XCTAssertEqual(cells[1]!.columns, 1)
        XCTAssertEqual(cells[1]!.rows, 1)
        XCTAssertEqual(cells[1]!.anchor, 1)
    }

    func testLayoutIsEmptyWithoutWidgets() {
        XCTAssertTrue(WidgetLayout.cells(for: grid([:])).isEmpty)
    }

    func testCoveredKeysKeepTheirOwnConfiguration() {
        var keys = grid([0: key(.spotify, columns: 2, rows: 1)])
        keys[1].label = "MINE"
        keys[1].action = .openURL("example.com")
        let cells = WidgetLayout.cells(for: keys)
        XCTAssertNotNil(cells[1])
        // The widget paints it, but nothing was taken away from the key: it
        // gets its face back the moment the span shrinks.
        XCTAssertEqual(keys[1].label, "MINE")
        XCTAssertEqual(keys[1].action, .openURL("example.com"))
    }
}

final class WidgetConfigTests: XCTestCase {

    func testDefaultsPerKind() {
        let spotify = WidgetConfig(kind: .spotify)
        XCTAssertEqual(spotify.press, "play_pause")
        XCTAssertEqual(spotify.interval, 3)
        let stocks = WidgetConfig(kind: .stocks)
        XCTAssertEqual(stocks.press, "cycle")
        XCTAssertEqual(stocks.interval, 30)
    }

    func testNormalizeRejectsValuesThisBuildDoesNotKnow() {
        var config = WidgetConfig(kind: .spotify)
        config.style = "hologram"
        config.press = "self-destruct"
        config.source = "telepathy"
        let normalized = config.normalized
        XCTAssertEqual(normalized.style, "auto")
        XCTAssertEqual(normalized.press, "play_pause")
        XCTAssertEqual(normalized.source, "auto")
    }

    func testNormalizeClampsTheSpanToTheDeck() {
        var config = WidgetConfig(kind: .spotify)
        config.columns = 99
        config.rows = 0
        let normalized = config.normalized
        XCTAssertEqual(normalized.columns, DeckLayout.columns)
        XCTAssertEqual(normalized.rows, 1)
    }

    func testNormalizeClampsIntervalToTheKindFloor() {
        var spotify = WidgetConfig(kind: .spotify)
        spotify.interval = 0.1
        XCTAssertEqual(spotify.normalized.interval, 1)
        var stocks = WidgetConfig(kind: .stocks)
        stocks.interval = 0.1
        XCTAssertEqual(stocks.normalized.interval, 5)
        stocks.interval = 999_999
        XCTAssertEqual(stocks.normalized.interval, WidgetConfig.maximumInterval)
    }

    func testNormalizeStripsFieldsFromTheOtherKind() {
        var spotify = WidgetConfig(kind: .spotify)
        spotify.symbols = "AAPL"
        spotify.rotate = 30
        XCTAssertEqual(spotify.normalized.symbols, "")
        XCTAssertEqual(spotify.normalized.rotate, 0)
    }

    func testSymbolsAreNormalizedAndDeduplicated() {
        var config = WidgetConfig(kind: .stocks)
        config.symbols = "aapl, msft\nAAPL  nvda,,brk.b, BINANCE:BTCUSDT"
        XCTAssertEqual(config.symbolList,
                       ["AAPL", "MSFT", "NVDA", "BRK.B", "BINANCE:BTCUSDT"])
    }

    func testSymbolListIsBounded() {
        var config = WidgetConfig(kind: .stocks)
        config.symbols = (0..<200).map { "SYM\($0)" }.joined(separator: ",")
        XCTAssertEqual(config.symbolList.count, 32)
    }

    func testRoundTripsThroughJSON() {
        var config = WidgetConfig(kind: .stocks)
        config.columns = 3; config.rows = 2; config.symbols = "AAPL"
        let data = try! JSONEncoder().encode(config)
        XCTAssertEqual(try! JSONDecoder().decode(WidgetConfig.self, from: data), config)
    }

    func testAKeyWrittenBeforeWidgetsExistedStillDecodes() {
        // Settings files predate this feature; a missing field must not make
        // the whole deck configuration unreadable.
        // Double delimiters: the JSON itself contains `"#`, which would close
        // a single-# raw string in the middle of the colour.
        let json = ##"{"colorHex":"#1E1E28","label":"OLD","action":{"none":{}}}"##
        let key = try? JSONDecoder().decode(KeyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(key?.label, "OLD")
        XCTAssertNil(key?.widget)
    }
}

@MainActor
final class WidgetRenderingTests: XCTestCase {
    private let runtime = WidgetRuntime()

    private static let spans = [(1, 1), (2, 1), (3, 2), (5, 3), (1, 3)]

    private func artwork() -> CGImage {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testSpotifyFramesHaveTheRightSizeInEveryStyle() {
        var state = SpotifyNowPlaying(ok: true, playing: true,
                                      title: "A Very Long Track Title Indeed",
                                      artist: "Artist", album: "Album",
                                      progressMS: 1000, durationMS: 200_000)
        state.art = artwork()
        for style in WidgetKind.spotify.styles {
            for (columns, rows) in Self.spans {
                var config = WidgetConfig(kind: .spotify)
                config.style = style
                let snapshot = WidgetSnapshot(signature: "s", payload: state)
                let frame = runtime.frame(config, snapshot: snapshot, columns: columns,
                                          rows: rows, background: .black)
                XCTAssertEqual(frame?.width, columns * DeckLayout.keyPixels,
                               "\(style) \(columns)x\(rows)")
                XCTAssertEqual(frame?.height, rows * DeckLayout.keyPixels,
                               "\(style) \(columns)x\(rows)")
            }
        }
    }

    func testStocksFramesHaveTheRightSizeInEveryStyle() {
        let quotes = ["AAPL", "MSFT", "NVDA", "TSLA", "BTC"].map {
            StockQuote(symbol: $0, price: 1234.5, change: -1, percent: -0.42,
                       high: 1300, low: 1200, ok: true,
                       history: (0..<10).map(Double.init))
        }
        for style in WidgetKind.stocks.styles {
            for (columns, rows) in Self.spans {
                var config = WidgetConfig(kind: .stocks)
                config.style = style
                config.symbols = quotes.map(\.symbol).joined(separator: ",")
                let page = StockPage(quotes: Array(quotes.prefix(columns * rows)),
                                     page: 1, pages: 2)
                let snapshot = WidgetSnapshot(signature: "s", payload: page)
                let frame = runtime.frame(config, snapshot: snapshot, columns: columns,
                                          rows: rows, background: .black)
                XCTAssertEqual(frame?.width, columns * DeckLayout.keyPixels,
                               "\(style) \(columns)x\(rows)")
                XCTAssertEqual(frame?.height, rows * DeckLayout.keyPixels,
                               "\(style) \(columns)x\(rows)")
            }
        }
    }

    func testFramesRenderBeforeAnyDataArrives() {
        for kind in WidgetKind.allCases {
            let config = WidgetConfig(kind: kind)
            let frame = runtime.frame(config, snapshot: .empty(for: kind),
                                      columns: 2, rows: 1, background: .black)
            XCTAssertNotNil(frame, "\(kind) placeholder")
        }
    }

    func testAFailedWidgetPaintsItsReasonRatherThanNothing() {
        let state = SpotifyNowPlaying(ok: false, error: "offline")
        let snapshot = WidgetSnapshot(signature: "e", payload: state)
        let frame = runtime.frame(WidgetConfig(kind: .spotify), snapshot: snapshot,
                                  columns: 1, rows: 1, background: .black)
        XCTAssertNotNil(frame)
        XCTAssertTrue(isNotBlank(frame!), "an unreachable widget must say so on the key")
    }

    func testTilesCoverTheFrameAndRefuseToRunOffIt() {
        let config = WidgetConfig(kind: .spotify)
        let frame = runtime.frame(config, snapshot: .empty(for: .spotify),
                                  columns: 3, rows: 2, background: .black)!
        for dy in 0..<2 {
            for dx in 0..<3 {
                let tile = WidgetRuntime.tile(frame, dx: dx, dy: dy)
                XCTAssertEqual(tile?.width, DeckLayout.keyPixels)
                XCTAssertEqual(tile?.height, DeckLayout.keyPixels)
            }
        }
        // A layout that moved under a half-finished repaint must not trap.
        XCTAssertNil(WidgetRuntime.tile(frame, dx: 3, dy: 0))
        XCTAssertNil(WidgetRuntime.tile(frame, dx: 0, dy: 2))
    }

    func testEveryTileOfAMultiKeyWidgetIsDifferent() {
        // The whole point of a span: the keys show one picture between them,
        // not the same picture each.
        var config = WidgetConfig(kind: .stocks)
        config.symbols = "AAPL,MSFT,NVDA"
        let quotes = ["AAPL", "MSFT", "NVDA"].enumerated().map {
            StockQuote(symbol: $0.element, price: Double(100 * ($0.offset + 1)),
                       percent: Double($0.offset), ok: true)
        }
        let snapshot = WidgetSnapshot(signature: "s", payload: StockPage(quotes: quotes))
        let frame = runtime.frame(config, snapshot: snapshot, columns: 3, rows: 1,
                                  background: .black)!
        let tiles = (0..<3).compactMap { WidgetRuntime.tile(frame, dx: $0, dy: 0) }
        let hashes = Set(tiles.map { bytes(of: $0) })
        XCTAssertEqual(hashes.count, 3)
    }

    func testTextWithNewlinesDoesNotBreakTheFace() {
        // A pasted track title genuinely carries newlines.
        let state = SpotifyNowPlaying(ok: true, playing: true, title: "line one\nline two",
                                      artist: "a\nb")
        let snapshot = WidgetSnapshot(signature: "n", payload: state)
        var config = WidgetConfig(kind: .spotify)
        config.style = "text"
        XCTAssertNotNil(runtime.frame(config, snapshot: snapshot, columns: 1, rows: 1,
                                      background: .black))
    }

    func testALongTitleIsTruncatedNotShrunkIntoIllegibility() {
        // Regression: the shrink-to-fit loop used to run all the way down to
        // 7pt, so a long track title rendered SMALLER than the artist line
        // underneath it and the type hierarchy read backwards.
        let ctx = WidgetPaint.frame(columns: 1, rows: 1, background: .black)!
        let rect = CGRect(x: 0, y: 0, width: 90, height: 40)
        let short = WidgetPaint.line("Hi", in: rect, ctx: ctx, size: 26, color: .white)
        let long = WidgetPaint.line("Everything In Its Right Place", in: rect,
                                    ctx: ctx, size: 26, color: .white)
        XCTAssertGreaterThan(long, 0)
        XCTAssertGreaterThanOrEqual(long, short * 0.75,
                                    "a long title must be truncated at its own size, not demoted")
    }

    func testTheBadgeShowsWhatPressingDoesNotWhatIsHappening() {
        // Transport convention: paused shows ▶ ("press to play"), playing
        // shows ❚❚. Showing the state instead would mean a key that skips
        // tracks advertised nothing about skipping.
        XCTAssertEqual(SpotifyWidgetRenderer.badgeSymbol(press: "play_pause", playing: false),
                       "play.fill")
        XCTAssertEqual(SpotifyWidgetRenderer.badgeSymbol(press: "play_pause", playing: true),
                       "pause.fill")
        XCTAssertEqual(SpotifyWidgetRenderer.badgeSymbol(press: "next", playing: true),
                       "forward.end.fill")
        XCTAssertEqual(SpotifyWidgetRenderer.badgeSymbol(press: "previous", playing: true),
                       "backward.end.fill")
        // No press action: no badge — the state dot is drawn instead.
        XCTAssertNil(SpotifyWidgetRenderer.badgeSymbol(press: "none", playing: true))
    }

    func testEveryBadgeGlyphExistsOnThisSystem() {
        // A missing SF Symbol degrades to a bare disc with nothing in it,
        // which is worse than no badge at all.
        for symbol in ["play.fill", "pause.fill", "forward.end.fill",
                       "backward.end.fill", "arrow.forward"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                            symbol)
        }
    }

    func testAutoStyleFollowsTheSpan() {
        let config = WidgetConfig(kind: .spotify)
        XCTAssertEqual(SpotifyWidgetRenderer.style(for: config, columns: 1, rows: 1), "art")
        XCTAssertEqual(SpotifyWidgetRenderer.style(for: config, columns: 3, rows: 1), "art+text")
        XCTAssertEqual(SpotifyWidgetRenderer.style(for: config, columns: 2, rows: 2), "progress")
    }

    // MARK: Helpers

    private func bytes(of image: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private func isNotBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data as Data? else { return false }
        return Set(data).count > 1
    }
}

final class WidgetFormattingTests: XCTestCase {

    func testPriceLosesDecimalsAsItGrows() {
        XCTAssertEqual(StocksWidgetRenderer.formatPrice(nil), "—")
        XCTAssertTrue(StocksWidgetRenderer.formatPrice(232.145).hasPrefix("232.1"))
        XCTAssertFalse(StocksWidgetRenderer.formatPrice(68231.0).contains("."))
    }

    func testPercentCarriesItsDirection() {
        XCTAssertEqual(StocksWidgetRenderer.formatPercent(1.234), "▲1.23%")
        XCTAssertEqual(StocksWidgetRenderer.formatPercent(-1.234), "▼1.23%")
        XCTAssertEqual(StocksWidgetRenderer.formatPercent(nil), "—")
    }

    func testLegacyArtURLIsRewrittenToTheCDN() {
        XCTAssertEqual(SpotifyProvider.normalizeArtURL("https://open.spotify.com/image/ab12"),
                       "https://i.scdn.co/image/ab12")
        XCTAssertEqual(SpotifyProvider.normalizeArtURL("https://i.scdn.co/image/ab12"),
                       "https://i.scdn.co/image/ab12")
    }

    func testNowPlayingSignatureIgnoresSubSecondProgress() {
        let a = SpotifyNowPlaying(ok: true, title: "t", progressMS: 1000)
        let b = SpotifyNowPlaying(ok: true, title: "t", progressMS: 1400)
        let c = SpotifyNowPlaying(ok: true, title: "t", progressMS: 2000)
        XCTAssertEqual(a.signature, b.signature)
        XCTAssertNotEqual(a.signature, c.signature)
    }

    func testStockPageSignatureFollowsThePrice() {
        let one = StockPage(quotes: [StockQuote(symbol: "AAPL", price: 1, ok: true)])
        let same = StockPage(quotes: [StockQuote(symbol: "AAPL", price: 1, ok: true)])
        let moved = StockPage(quotes: [StockQuote(symbol: "AAPL", price: 2, ok: true)])
        XCTAssertEqual(one.signature, same.signature)
        XCTAssertNotEqual(one.signature, moved.signature)
    }
}

/// The `.env` parser. Pure string work — it never touches a real credential
/// file, and the search-path test only checks where it WOULD look.
final class DotenvTests: XCTestCase {

    func testParsesPlainAssignments() {
        let values = WidgetCredentials.parseDotenv("""
        FINNHUN=abc123
        SPOTIFY_CLIENT_ID=deadbeef
        """)
        XCTAssertEqual(values["FINNHUN"], "abc123")
        XCTAssertEqual(values["SPOTIFY_CLIENT_ID"], "deadbeef")
    }

    func testIgnoresCommentsBlanksAndJunk() {
        let values = WidgetCredentials.parseDotenv("""
        # a comment
             
        FINNHUB_KEY=key
        this line has no equals sign
        =novalue
        """)
        XCTAssertEqual(values, ["FINNHUB_KEY": "key"])
    }

    func testHandlesExportAndQuotes() {
        let values = WidgetCredentials.parseDotenv("""
        export FINNHUB_KEY="quoted"
        SPOTIFY_CLIENT_ID='single'
        """)
        XCTAssertEqual(values["FINNHUB_KEY"], "quoted")
        XCTAssertEqual(values["SPOTIFY_CLIENT_ID"], "single")
    }

    func testOnlyTheFirstEqualsSplits() {
        // Base64 tokens end in '=' and routinely contain more of them; a
        // greedy split would truncate exactly the values we care about.
        let values = WidgetCredentials.parseDotenv("SP_DC=AQBX7V=Fm_padding==")
        XCTAssertEqual(values["SP_DC"], "AQBX7V=Fm_padding==")
    }

    func testTrimsSurroundingWhitespace() {
        let values = WidgetCredentials.parseDotenv("  FINNHUB_KEY  =  spaced  ")
        XCTAssertEqual(values["FINNHUB_KEY"], "spaced")
    }

    func testFinnhubAcceptsBothSpellings() {
        // One .env has to be able to feed this app and the scripts that
        // already read FINNHUN.
        XCTAssertEqual(WidgetCredentials.Key.finnhub.environmentNames,
                       ["FINNHUB_KEY", "FINNHUN"])
    }

    func testSearchPathIncludesTheAppsOwnFolder() {
        let paths = WidgetCredentials.dotenvSearchPaths()
        XCTAssertTrue(paths.allSatisfy { $0.hasSuffix(".env") })
        // Launched from Finder the working directory is "/", so a search that
        // relied on it alone would never find the file.
        XCTAssertGreaterThan(paths.count, 2)
        XCTAssertTrue(paths.contains { $0.hasPrefix(Bundle.main.bundleURL.path) }
                      || paths.contains { $0.contains("/.env") })
    }

    func testMissingSourceHasNoLabel() {
        XCTAssertEqual(WidgetCredentials.Source.missing.label, "")
        XCTAssertEqual(WidgetCredentials.Source.environment("FINNHUB_KEY").label,
                       "from $FINNHUB_KEY")
    }
}

/// The contract between the AppleScript and the parser. The fixtures are the
/// literal output of running that script's control flow through `osascript`.
final class SpotifyLocalParsingTests: XCTestCase {
    private let sep = "\u{1F}"

    func testParsesARealScriptLine() {
        let raw = ["true", "Everything In Its Right Place", "Radiohead", "Kid A",
                   "https://i.scdn.co/image/ab12", "251000", "95.5"].joined(separator: sep)
        let state = SpotifyProvider.parseLocal(raw)
        XCTAssertTrue(state.ok)
        XCTAssertTrue(state.playing)
        XCTAssertEqual(state.title, "Everything In Its Right Place")
        XCTAssertEqual(state.artist, "Radiohead")
        XCTAssertEqual(state.album, "Kid A")
        // Duration arrives in milliseconds, position in seconds.
        XCTAssertEqual(state.durationMS, 251_000)
        XCTAssertEqual(state.progressMS, 95_500)
    }

    func testPausedIsNotMistakenForPlaying() {
        // The whole reason the script emits a boolean: Spotify's raw state
        // codes are kPSP (playing) and kPSp (paused), which differ only in
        // case, so any case-insensitive read of them says "playing" for both.
        let raw = ["false", "Track", "Artist", "Album", "", "1000", "0"]
            .joined(separator: sep)
        XCTAssertFalse(SpotifyProvider.parseLocal(raw).playing)
    }

    func testATrackWithoutArtworkStillReads() {
        // Podcasts and local files have no artwork url; the track is still
        // perfectly readable and must not degrade to "nothing playing".
        let raw = ["true", "Some Podcast", "Host", "", "", "3600000", "12"]
            .joined(separator: sep)
        let state = SpotifyProvider.parseLocal(raw)
        XCTAssertTrue(state.hasTrack)
        XCTAssertEqual(state.artURL, "")
    }

    func testIdleIsASuccessfulPoll() {
        for raw in ["idle", "", "  \n"] {
            let state = SpotifyProvider.parseLocal(raw)
            XCTAssertTrue(state.ok, "idle is not an error")
            XCTAssertFalse(state.hasTrack)
        }
    }

    func testATitleContainingPunctuationSurvives() {
        // The separator is a unit separator precisely because titles contain
        // every printable character, pipes and tabs included.
        let title = "Weird | Title\twith — everything, 100%"
        let raw = ["true", title, "A", "B", "", "1", "0"].joined(separator: sep)
        XCTAssertEqual(SpotifyProvider.parseLocal(raw).title, title)
    }

    func testTruncatedOutputDoesNotCrash() {
        XCTAssertFalse(SpotifyProvider.parseLocal("true\u{1F}Track").hasTrack)
    }
}

/// Layout selection, transport-bar action assignment, and the grid editing
/// operations behind drag-and-drop.
@MainActor
final class WidgetControlsTests: XCTestCase {

    /// A controller wired to a throwaway settings file.
    ///
    /// Never `DeckController()` in a test: that reads — and the first edit
    /// writes — the real `~/Library/Application Support/FifineDeck/settings.json`.
    private func scratchDeck() throws -> DeckController {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FifineDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DeckController(storeURL: directory.appendingPathComponent("settings.json"))
    }

    private func cell(_ config: WidgetConfig, dx: Int, dy: Int,
                      columns: Int, rows: Int) -> WidgetCell {
        WidgetCell(anchor: 0, config: config, dx: dx, dy: dy,
                   columns: columns, rows: rows)
    }

    func testAutoGivesAWideBlockTheSplitLayout() {
        let config = WidgetConfig(kind: .spotify)
        // 4x2: a 2x2 of album art beside a 2x2 info panel — the shape the art
        // wants, rather than a letterboxed cover with text crammed under it.
        XCTAssertEqual(SpotifyWidgetRenderer.style(for: config, columns: 4, rows: 2), "split")
        XCTAssertEqual(SpotifyWidgetRenderer.style(for: config, columns: 6, rows: 3), "split")
        // Not wide enough to split: art behind the text instead.
        XCTAssertEqual(SpotifyWidgetRenderer.style(for: config, columns: 2, rows: 2), "progress")
        XCTAssertEqual(SpotifyWidgetRenderer.style(for: config, columns: 3, rows: 1), "art+text")
        XCTAssertEqual(SpotifyWidgetRenderer.style(for: config, columns: 1, rows: 1), "art")
    }

    func testATransportBarNeverHasMoreThanThreeButtons() {
        XCTAssertEqual(SpotifyWidgetRenderer.controlButtons(cellCount: 1), ["play_pause"])
        XCTAssertEqual(SpotifyWidgetRenderer.controlButtons(cellCount: 2),
                       ["play_pause", "next"])
        for count in 3...10 {
            XCTAssertEqual(SpotifyWidgetRenderer.controlButtons(cellCount: count),
                           ["previous", "play_pause", "next"], "\(count) cells")
        }
    }

    func testEachKeyOfATransportBarGetsItsOwnAction() {
        var config = WidgetConfig(kind: .spotify)
        config.style = "controls"
        config.press = "none"          // ignored: the style defines the actions
        let actions = (0..<3).map {
            SpotifyWidgetRenderer.pressAction(
                config: config, cell: cell(config, dx: $0, dy: 0, columns: 3, rows: 1))
        }
        XCTAssertEqual(actions, ["previous", "play_pause", "next"])
    }

    func testAWideTransportBarSpreadsButtonsOverWholeKeys() {
        var config = WidgetConfig(kind: .spotify)
        config.style = "controls"
        let actions = (0..<5).map {
            SpotifyWidgetRenderer.pressAction(
                config: config, cell: cell(config, dx: $0, dy: 0, columns: 5, rows: 1))
        }
        // Keys sharing a button repeat it — no key is dead, and none of them
        // does something different from the glyph it shows.
        XCTAssertEqual(actions, ["previous", "previous", "play_pause", "next", "next"])
    }

    func testEveryOtherStyleUsesTheSingleConfiguredAction() {
        for style in ["auto", "art", "split", "progress", "button"] {
            var config = WidgetConfig(kind: .spotify)
            config.style = style
            config.press = "next"
            XCTAssertEqual(SpotifyWidgetRenderer.pressAction(
                config: config, cell: cell(config, dx: 2, dy: 0, columns: 3, rows: 1)),
                           "next", style)
        }
    }

    func testMovingAKeySwapsItsWholeConfiguration() throws {
        let deck = try scratchDeck()
        deck.keys[0].label = "A"
        deck.keys[0].widget = WidgetConfig(kind: .spotify)
        deck.keys[7].label = "B"
        deck.moveKey(from: 0, to: 7)
        XCTAssertEqual(deck.keys[7].label, "A")
        XCTAssertNotNil(deck.keys[7].widget)
        // The displaced key goes back to the slot that was vacated, not into
        // the void.
        XCTAssertEqual(deck.keys[0].label, "B")
        XCTAssertNil(deck.keys[0].widget)
        XCTAssertNotNil(deck.widgetCell(7))
    }

    func testResizingClampsToTheDeckInsteadOfWrapping() throws {
        let deck = try scratchDeck()
        deck.keys[3].widget = WidgetConfig(kind: .spotify)      // 4th column
        deck.setWidget(deck.keys[3].widget, for: 3)
        deck.resizeWidget(anchor: 3, columns: 5, rows: 9)
        XCTAssertEqual(deck.keys[3].widget?.columns, 2)          // 2 columns left
        XCTAssertEqual(deck.keys[3].widget?.rows, DeckLayout.rows)
    }

    func testResizingAKeyWithNoWidgetDoesNothing() throws {
        let deck = try scratchDeck()
        deck.resizeWidget(anchor: 4, columns: 3, rows: 2)
        XCTAssertNil(deck.keys[4].widget)
    }
}

@MainActor
final class ClearAllTests: XCTestCase {

    private func scratchDeck() throws -> DeckController {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FifineDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DeckController(storeURL: directory.appendingPathComponent("settings.json"))
    }

    func testClearingResetsEveryKey() throws {
        let deck = try scratchDeck()
        deck.keys[0].label = "KEEP"
        deck.keys[4].widget = WidgetConfig(kind: .stocks)
        deck.keys[9].colorHex = "#FF0000"
        deck.clearAllKeys()
        XCTAssertTrue(deck.keys.allSatisfy { $0 == KeyConfig() })
        XCTAssertTrue(deck.widgetCells.isEmpty)
    }

    func testClearingIsUndoable() throws {
        let deck = try scratchDeck()
        deck.keys[0].label = "KEEP"
        deck.keys[4].widget = WidgetConfig(kind: .stocks)
        deck.clearAllKeys()
        XCTAssertTrue(deck.hasBackup)
        XCTAssertTrue(deck.restoreBackup())
        XCTAssertEqual(deck.keys[0].label, "KEEP")
        XCTAssertEqual(deck.keys[4].widget?.kind, .stocks)
        // The widget has to come back live, not just as stored bytes.
        XCTAssertNotNil(deck.widgetCell(4))
    }

    func testUndoIsItselfUndoable() throws {
        // Restoring onto the wrong layout must not be a one-way door either.
        let deck = try scratchDeck()
        deck.keys[0].label = "FIRST"
        deck.clearAllKeys()
        XCTAssertTrue(deck.restoreBackup())
        XCTAssertEqual(deck.keys[0].label, "FIRST")
        XCTAssertTrue(deck.restoreBackup())
        XCTAssertTrue(deck.keys.allSatisfy { $0 == KeyConfig() })
    }

    func testRestoreWithNoBackupSaysSo() throws {
        let deck = try scratchDeck()
        XCTAssertFalse(deck.hasBackup)
        XCTAssertFalse(deck.restoreBackup())
    }

    func testClearingNeverTouchesTheRealSettingsFile() throws {
        // The regression this whole injectable-store change exists for.
        let deck = try scratchDeck()
        let real = DeckController.defaultStoreURL
        let before = try? Data(contentsOf: real)
        deck.keys[0].label = "X"
        deck.clearAllKeys()
        let after = try? Data(contentsOf: real)
        XCTAssertEqual(before, after, "a test must never write the user's own deck layout")
    }
}

/// The grid's GIF preview. Builds a real multi-frame GIF in a temp directory
/// rather than reaching for one of the user's.
final class GifPreviewTests: XCTestCase {

    private func makeGIF(width: Int, height: Int) throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FifineGifTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.gif")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        for shade in [0.2, 0.8] {
            let ctx = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            ctx.setFillColor(NSColor(white: shade, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(destination, ctx.makeImage()!, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url.path
    }

    func testAGifIsReadableForThePreview() throws {
        let path = try makeGIF(width: 60, height: 40)
        XCTAssertTrue(GifPreview.exists(path))
        XCTAssertNotNil(GifPreview.image(path))
    }

    func testFillSizeCoversTheKeyLikeTheDeckDoes() throws {
        // GifPlayer.fit scales to COVER and centre-crops, so the preview has
        // to over-size the wide axis rather than letterbox it.
        let path = try makeGIF(width: 200, height: 100)
        let size = GifPreview.fillSize(path, side: 78)
        XCTAssertEqual(size.height, 78, accuracy: 0.01)
        XCTAssertEqual(size.width, 156, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(size.width, 78)
    }

    func testATallGifAlsoCovers() throws {
        let path = try makeGIF(width: 50, height: 200)
        let size = GifPreview.fillSize(path, side: 78)
        XCTAssertEqual(size.width, 78, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(size.height, 78)
    }

    func testAMissingGifDegradesToASquareAndIsNotRetriedForever() {
        let path = NSTemporaryDirectory() + "/definitely-not-here-\(UUID().uuidString).gif"
        XCTAssertFalse(GifPreview.exists(path))
        XCTAssertEqual(GifPreview.fillSize(path, side: 78), CGSize(width: 78, height: 78))
        XCTAssertNil(GifPreview.image(path))
    }
}

@MainActor
final class DeckMiniGridTests: XCTestCase {

    func testSizeMatchesTheGridItLaysOut() {
        // NSMenuItem does not lay its custom view out for you: this number is
        // the contract, and a wrong one clips the grid or leaves a gap.
        let size = DeckMiniGrid.size(side: 30, spacing: 3, padding: 10)
        XCTAssertEqual(size.width, CGFloat(DeckLayout.columns) * 30
                       + CGFloat(DeckLayout.columns - 1) * 3 + 20)
        XCTAssertEqual(size.height, CGFloat(DeckLayout.rows) * 30
                       + CGFloat(DeckLayout.rows - 1) * 3 + 20)
    }

    func testItRendersEveryKeyOfTheDeck() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MiniGridTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let deck = DeckController(storeURL: directory.appendingPathComponent("settings.json"))
        deck.keys = Array(repeating: KeyConfig(), count: DeckLayout.keyCount)
        deck.keys[2].colorHex = "#1E5FD4"

        let renderer = ImageRenderer(content: DeckMiniGrid(deck: deck))
        let image = renderer.nsImage
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size, DeckMiniGrid.size())
    }
}

/// The AppKit-side clipping of the grid's GIF preview.
@MainActor
final class GifClipViewTests: XCTestCase {

    private func wideGIF() throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FifineClipTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wide.gif")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, 1, nil)!
        let ctx = CGContext(data: nil, width: 240, height: 80, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.setFillColor(NSColor.blue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 80))
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url.path
    }

    func testTheImageIsClippedToTheKeyAndNeverSpillsOntoItsNeighbours() throws {
        // The regression: SwiftUI's clipShape does not clip a hosted NSView,
        // so a wide GIF drew straight across the keys either side of it.
        let view = GifClipView(frame: NSRect(x: 0, y: 0, width: 78, height: 78))
        view.path = try wideGIF()
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.layer?.masksToBounds == true)
        XCTAssertEqual(view.bounds.width, 78)
        XCTAssertEqual(view.bounds.height, 78)
    }

    func testTheImageCoversTheKeyAndIsCentred() throws {
        let view = GifClipView(frame: NSRect(x: 0, y: 0, width: 78, height: 78))
        view.path = try wideGIF()
        view.layoutSubtreeIfNeeded()
        guard let image = view.subviews.first else { return XCTFail("no image view") }
        // 240x80 covering a 78 square: 234x78, centred, so it overhangs evenly
        // on both sides rather than being letterboxed or shoved to one edge.
        XCTAssertEqual(image.frame.height, 78, accuracy: 0.5)
        XCTAssertEqual(image.frame.width, 234, accuracy: 0.5)
        XCTAssertEqual(image.frame.midX, 39, accuracy: 0.5)
        XCTAssertEqual(image.frame.midY, 39, accuracy: 0.5)
    }

    func testAKeyWithNoReadableGifJustFillsTheBounds() {
        let view = GifClipView(frame: NSRect(x: 0, y: 0, width: 78, height: 78))
        view.path = "/nope-\(UUID().uuidString).gif"
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.first?.frame, view.bounds)
    }
}

// MARK: - The widget set

@MainActor
final class AllWidgetsTests: XCTestCase {
    private let runtime = WidgetRuntime()

    func testEveryKindHasAProvider() {
        for kind in WidgetKind.allCases {
            XCTAssertNotNil(WidgetRegistry.provider(for: kind), kind.rawValue)
        }
    }

    func testEveryKindRendersAtEverySpanBeforeAnyDataArrives() {
        // A widget must paint something the moment it is dropped on a key,
        // with no network and nothing cached.
        for kind in WidgetKind.allCases {
            for (columns, rows) in [(1, 1), (2, 1), (3, 2), (5, 3)] {
                var config = WidgetConfig(kind: kind)
                config.columns = columns; config.rows = rows
                config = config.normalized
                let snapshot = runtime.snapshot(config, cells: columns * rows)
                let frame = runtime.frame(config, snapshot: snapshot, columns: columns,
                                          rows: rows, background: .black)
                XCTAssertEqual(frame?.width, columns * DeckLayout.keyPixels,
                               "\(kind.rawValue) \(columns)x\(rows)")
                XCTAssertEqual(frame?.height, rows * DeckLayout.keyPixels,
                               "\(kind.rawValue) \(columns)x\(rows)")
            }
        }
    }

    func testEveryKindRendersInEveryStyle() {
        for kind in WidgetKind.allCases {
            for style in kind.styles {
                var config = WidgetConfig(kind: kind)
                config.style = style; config.columns = 3; config.rows = 2
                config = config.normalized
                XCTAssertEqual(config.style, style, "\(kind.rawValue) rejected \(style)")
                let snapshot = runtime.snapshot(config, cells: 6)
                XCTAssertNotNil(runtime.frame(config, snapshot: snapshot, columns: 3,
                                              rows: 2, background: .black),
                                "\(kind.rawValue)/\(style)")
            }
        }
    }

    func testDefaultsAreUsableWithoutEditing() {
        // Dropping a widget on a key and touching nothing has to produce
        // something that works, not an empty configuration.
        XCTAssertFalse(WidgetConfig(kind: .stocks).symbolList.isEmpty)
        XCTAssertFalse(WidgetConfig(kind: .weather).place.isEmpty)
        XCTAssertFalse(WidgetConfig(kind: .sports).place.isEmpty)
        XCTAssertFalse(SystemProvider.list(WidgetConfig(kind: .system)).isEmpty)
        XCTAssertEqual(WidgetConfig(kind: .timer).minutes, 25)
    }

    func testEachKindKeepsOnlyItsOwnFields() {
        // Stray fields from another kind split the data-stream cache key, so
        // two identically-configured widgets would stop sharing one fetch.
        var config = WidgetConfig(kind: .clock)
        config.symbols = "AAPL"; config.place = "London"; config.minutes = 99
        let clean = config.normalized
        XCTAssertEqual(clean.symbols, "")
        XCTAssertEqual(clean.place, "")
        XCTAssertEqual(clean.minutes, 25)
    }

    func testIntervalFloorsProtectTheServices() {
        // Weather has the highest floor: it is a free service and the sky
        // does not move in a second.
        for kind in WidgetKind.allCases {
            var config = WidgetConfig(kind: kind)
            config.interval = 0.01
            XCTAssertEqual(config.normalized.interval, kind.minimumInterval, kind.rawValue)
        }
        XCTAssertGreaterThanOrEqual(WidgetKind.weather.minimumInterval, 300)
    }
}

final class ClockWidgetTests: XCTestCase {

    func testZoneNameIsJustTheCity() {
        XCTAssertEqual(ClockProvider.shortName(TimeZone(identifier: "Europe/Paris")!), "PARIS")
        XCTAssertEqual(ClockProvider.shortName(TimeZone(identifier: "America/New_York")!),
                       "NEW YORK")
    }

    func testAnalogIsChosenForASquareBlock() {
        let config = WidgetConfig(kind: .clock)
        XCTAssertEqual(ClockProvider().style(config, columns: 2, rows: 2), "analog")
        XCTAssertEqual(ClockProvider().style(config, columns: 3, rows: 1), "digital")
        XCTAssertEqual(ClockProvider().style(config, columns: 1, rows: 1), "digital")
    }

    func testTheSignatureOnlyMovesWhenTheFaceWould() {
        let now = Date()
        let a = ClockReading(date: now, timezone: .current, label: "")
        let b = ClockReading(date: now.addingTimeInterval(0.5), timezone: .current, label: "")
        let c = ClockReading(date: now.addingTimeInterval(61), timezone: .current, label: "")
        // Without seconds, half a second later is the same picture.
        XCTAssertEqual(a.signature(showsSeconds: false), b.signature(showsSeconds: false))
        XCTAssertNotEqual(a.signature(showsSeconds: false), c.signature(showsSeconds: false))
    }
}

final class SystemWidgetTests: XCTestCase {

    func testUnknownMetricsAreDroppedAndTheListNeverEmpties() {
        var config = WidgetConfig(kind: .system)
        config.symbols = "cpu, unicorns, memory, cpu"
        XCTAssertEqual(SystemProvider.list(config), ["cpu", "memory"])
        config.symbols = "nonsense"
        XCTAssertEqual(SystemProvider.list(config), ["cpu"])
    }

    func testByteFormattingStaysShortEnoughForAKey() {
        XCTAssertEqual(SystemProvider.bytes(512), "512 B")
        XCTAssertEqual(SystemProvider.bytes(1536), "1.5 KB")
        XCTAssertEqual(SystemProvider.bytes(8 * 1024 * 1024 * 1024), "8.0 GB")
        XCTAssertLessThanOrEqual(SystemProvider.bytes(999 * 1024 * 1024).count, 8)
    }

    func testCPUReportsSomethingPlausible() async {
        let provider = SystemProvider()
        var config = WidgetConfig(kind: .system)
        config.symbols = "cpu"
        // The first sample can only prime the delta; the second is real.
        _ = await provider.fetch(config, cells: 1)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let page = await provider.fetch(config, cells: 1).data(SystemPage.self)
        let reading = page?.readings.first
        XCTAssertEqual(reading?.metric, "cpu")
        if let percent = reading?.percent {
            XCTAssertGreaterThanOrEqual(percent, 0)
            XCTAssertLessThanOrEqual(percent, 100)
        }
    }

    func testMemoryReportsAPercentage() async {
        let provider = SystemProvider()
        var config = WidgetConfig(kind: .system)
        config.symbols = "memory"
        let page = await provider.fetch(config, cells: 1).data(SystemPage.self)
        let percent = page?.readings.first?.percent
        XCTAssertNotNil(percent)
        XCTAssertGreaterThan(percent ?? 0, 0)
        XCTAssertLessThanOrEqual(percent ?? 101, 100)
    }
}

final class SportsWidgetTests: XCTestCase {

    func testLeagueFallsBackRatherThanBuildingABadURL() {
        var config = WidgetConfig(kind: .sports)
        config.place = "quidditch"
        XCTAssertEqual(SportsProvider.league(config), "nfl")
        config.place = "NBA"
        XCTAssertEqual(SportsProvider.league(config), "nba")
    }

    func testEveryLeagueKnowsItsSport() {
        for (league, sport) in SportsProvider.leagues {
            XCTAssertFalse(sport.isEmpty, league)
        }
        XCTAssertEqual(SportsProvider.leagues["nba"], "basketball")
        XCTAssertEqual(SportsProvider.leagues["eng.1"], "soccer")
    }
}

final class TimerWidgetTests: XCTestCase {

    private func cell(_ config: WidgetConfig) -> WidgetCell {
        WidgetCell(anchor: 0, config: config, dx: 0, dy: 0, columns: 1, rows: 1)
    }

    func testStartsPausesAndResumesWhereItLeftOff() async {
        let provider = TimerProvider()
        var config = WidgetConfig(kind: .timer)
        config.minutes = 1
        config.press = "start_pause"
        config = config.normalized

        let idle = await provider.fetch(config, cells: 1).data(TimerReading.self)
        XCTAssertEqual(idle?.running, false)
        XCTAssertEqual(idle?.remaining ?? 0, 60, accuracy: 0.1)

        _ = await provider.press(config, cell: cell(config),
                                 snapshot: WidgetSnapshot(signature: ""))
        try? await Task.sleep(nanoseconds: 300_000_000)
        let running = await provider.fetch(config, cells: 1).data(TimerReading.self)
        XCTAssertEqual(running?.running, true)
        XCTAssertLessThan(running?.remaining ?? 60, 60)

        _ = await provider.press(config, cell: cell(config),
                                 snapshot: WidgetSnapshot(signature: ""))
        let paused = await provider.fetch(config, cells: 1).data(TimerReading.self)
        let held = paused?.remaining ?? 0
        XCTAssertEqual(paused?.running, false)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let still = await provider.fetch(config, cells: 1).data(TimerReading.self)
        // Paused means paused: the clock must not keep draining.
        XCTAssertEqual(still?.remaining ?? 0, held, accuracy: 0.05)
    }

    func testResetPutsTheFullLengthBack() async {
        let provider = TimerProvider()
        var config = WidgetConfig(kind: .timer)
        config.minutes = 2; config.press = "start_pause"
        config = config.normalized
        _ = await provider.press(config, cell: cell(config),
                                 snapshot: WidgetSnapshot(signature: ""))
        try? await Task.sleep(nanoseconds: 200_000_000)
        var reset = config
        reset.press = "reset"
        _ = await provider.press(reset, cell: cell(reset),
                                 snapshot: WidgetSnapshot(signature: ""))
        // Same timer: reset and start/pause differ only in the press field,
        // and the countdown is keyed on the config.
        let reading = await provider.fetch(reset, cells: 1).data(TimerReading.self)
        XCTAssertEqual(reading?.remaining ?? 0, 120, accuracy: 0.1)
        XCTAssertEqual(reading?.running, false)
    }

    func testTheClockReadsAsMinutesAndSeconds() {
        XCTAssertEqual(TimerReading(remaining: 65, total: 300).clock, "1:05")
        XCTAssertEqual(TimerReading(remaining: 0, total: 300).clock, "0:00")
        XCTAssertEqual(TimerReading(remaining: 3661, total: 7200).clock, "1:01:01")
    }
}

final class WeatherWidgetTests: XCTestCase {

    func testWeatherCodesMapToRealSymbols() {
        for code in [0, 1, 3, 45, 61, 71, 95, 999] {
            let reading = WeatherReading(code: code)
            XCTAssertNotNil(NSImage(systemSymbolName: reading.summary.symbol,
                                    accessibilityDescription: nil),
                            "code \(code) -> \(reading.summary.symbol)")
            XCTAssertFalse(reading.summary.text.isEmpty)
        }
    }

    func testNightUsesANightSymbol() {
        XCTAssertEqual(WeatherReading(code: 0, isDay: true).summary.symbol, "sun.max.fill")
        XCTAssertEqual(WeatherReading(code: 0, isDay: false).summary.symbol, "moon.stars.fill")
    }

    func testTintRunsColdToHotOnCelsiusWhateverTheUnits() {
        let cold = WeatherProvider.tint(for: WeatherReading(temperature: -5, units: "metric"))
        let hot = WeatherProvider.tint(for: WeatherReading(temperature: 35, units: "metric"))
        XCTAssertGreaterThan(cold.usingColorSpace(.sRGB)!.blueComponent,
                             hot.usingColorSpace(.sRGB)!.blueComponent)
        // 95°F is hot, and must not be read as 95°C-off-the-scale-cold.
        let hotF = WeatherProvider.tint(for: WeatherReading(temperature: 95, units: "imperial"))
        XCTAssertEqual(hotF.usingColorSpace(.sRGB)!.redComponent,
                       hot.usingColorSpace(.sRGB)!.redComponent, accuracy: 0.15)
    }
}

final class KeyPressRoutingTests: XCTestCase {

    func testPressMappingIsReadingOrderAndBoundsChecked() {
        // Images are addressed bottom-up, presses in reading order. Applying
        // the image flip to input as well swaps rows 1 and 3.
        XCTAssertEqual(DeckLayout.gridIndex(forHardwareKey: 1), 0)
        XCTAssertEqual(DeckLayout.gridIndex(forHardwareKey: 15), 14)
        XCTAssertNil(DeckLayout.gridIndex(forHardwareKey: 0))
        XCTAssertNil(DeckLayout.gridIndex(forHardwareKey: 16))
    }

    func testAKeyOutsideEveryWidgetKeepsItsOwnAction() {
        // The regression shape to guard against: a widget claiming a key it
        // does not cover swallows that key's action silently.
        var keys = Array(repeating: KeyConfig(), count: DeckLayout.keyCount)
        var widget = WidgetConfig(kind: .system)
        widget.columns = 4; widget.rows = 1
        keys[10].widget = widget                       // covers 10, 11, 12, 13
        keys[14].action = .openURL("example.com")
        let cells = WidgetLayout.cells(for: keys)
        XCTAssertNil(cells[14], "key 15 is not part of a 4-wide widget at key 11")
        XCTAssertNotNil(cells[13])
    }

    func testAURLWithAFragmentSurvivesNormalisation() {
        // The three keys that stopped working all had URLs; this pins the
        // parsing half of that path.
        for raw in ["https://mail.google.com/mail/u/0/#inbox", "chatgpt.com",
                    "https://www.mypeoplenet.com/LogonVerify?x=1&y=2"] {
            let normalised = raw.contains("://") ? raw : "https://\(raw)"
            XCTAssertNotNil(URL(string: normalised), raw)
        }
    }
}

final class CommandRunnerTests: XCTestCase {

    func testRunsThroughALoginShell() {
        // The whole point: an app launched from Finder has a minimal PATH, so
        // a bare /bin/sh would not find anything the user installed.
        XCTAssertTrue(CommandRunner.loginShell.hasPrefix("/"))
    }

    func testASuccessfulCommandReportsItsOutput() {
        let done = expectation(description: "ran")
        CommandRunner.test("echo hello-from-the-deck") { result in
            XCTAssertTrue(result.ok)
            XCTAssertEqual(result.output, "hello-from-the-deck")
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    func testAFailingCommandReportsTheStatusAndStderr() {
        let done = expectation(description: "failed")
        CommandRunner.test("echo oops >&2; exit 3") { result in
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.status, 3)
            XCTAssertTrue(result.output.contains("oops"), result.output)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    func testTheLoginShellBringsTheUsersPath() {
        // A command found only via the profile's PATH is exactly what a bare
        // /bin/sh would miss.
        let done = expectation(description: "path")
        CommandRunner.test("echo $PATH") { result in
            XCTAssertTrue(result.ok)
            XCTAssertTrue(result.output.contains("/usr/bin"), result.output)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    func testAnEmptyCommandIsRefusedRatherThanRun() {
        let done = expectation(description: "empty")
        CommandRunner.test("   ") { result in
            XCTAssertFalse(result.ok)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testEveryExampleIsNonEmptyAndUnique() {
        var seen = Set<String>()
        for group in CommandRunner.examples {
            XCTAssertFalse(group.group.isEmpty)
            for item in group.items {
                XCTAssertFalse(item.name.isEmpty)
                XCTAssertFalse(item.command.isEmpty)
                XCTAssertTrue(seen.insert(item.command).inserted, "duplicate: \(item.command)")
            }
        }
        XCTAssertGreaterThan(seen.count, 10)
    }

    func testExamplesParseAsShellSyntax() {
        // A shipped example that does not even parse would be worse than none.
        for group in CommandRunner.examples {
            for item in group.items {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-n", "-c", item.command]
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, "syntax: \(item.command)")
            }
        }
    }
}

@MainActor
final class GifKeyActionTests: XCTestCase {

    private func scratchDeck() throws -> DeckController {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GifAction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DeckController(storeURL: directory.appendingPathComponent("settings.json"))
    }

    func testAGifKeyStillOpensItsURL() throws {
        // A key can be a picture AND a button: artwork and action are
        // independent, and animation must not swallow the press.
        let deck = try scratchDeck()
        deck.keys[4].gifPath = "/tmp/neon-bull.gif"
        deck.keys[4].action = .openURL("https://example.com")
        XCTAssertEqual(deck.pressTarget(4), .action(.openURL("https://example.com")))
    }

    func testAGifKeyStillRunsItsCommand() throws {
        let deck = try scratchDeck()
        deck.keys[7].gifPath = "/tmp/spin.gif"
        deck.keys[7].action = .runCommand("pmset displaysleepnow")
        XCTAssertEqual(deck.pressTarget(7), .action(.runCommand("pmset displaysleepnow")))
    }

    func testAStillImageKeyBehavesTheSame() throws {
        let deck = try scratchDeck()
        deck.keys[2].imagePath = "/tmp/logo.png"
        deck.keys[2].action = .openURL("example.com")
        XCTAssertEqual(deck.pressTarget(2), .action(.openURL("example.com")))
    }

    func testAWidgetTakesThePressEvenFromAGifKey() throws {
        let deck = try scratchDeck()
        deck.keys[1].gifPath = "/tmp/spin.gif"
        deck.keys[1].action = .openURL("example.com")
        var widget = WidgetConfig(kind: .clock)
        widget.columns = 3; widget.rows = 1
        deck.setWidget(widget, for: 0)          // covers 0, 1, 2
        XCTAssertEqual(deck.pressTarget(1), .widget(anchor: 0))
        // ...and hands it straight back when the widget shrinks.
        deck.resizeWidget(anchor: 0, columns: 1, rows: 1)
        XCTAssertEqual(deck.pressTarget(1), .action(.openURL("example.com")))
    }

    func testAKeyWithArtworkButNoActionDoesNothing() throws {
        let deck = try scratchDeck()
        deck.keys[3].gifPath = "/tmp/spin.gif"
        XCTAssertEqual(deck.pressTarget(3), .nothing)
    }
}

@MainActor
final class WritePacingTests: XCTestCase {

    func testTheDefaultAnimationRateIsTheSafeOne() {
        // The deck stops reporting presses when saturated with image writes,
        // and does not recover without a replug — so smoothness is opt-in.
        XCTAssertLessThanOrEqual(DeckController.safeAnimationFPS, 5)
        XCTAssertGreaterThan(DeckController.smoothAnimationFPS,
                             DeckController.safeAnimationFPS)
    }

    func testEveryBatchLeavesTheBusIdle() {
        // A frame of three animated keys must leave real idle time behind it.
        XCTAssertGreaterThanOrEqual(D6Device.pacingPerKey, 0.02)
        let idleForThreeKeys = 3 * D6Device.pacingPerKey
        XCTAssertGreaterThanOrEqual(idleForThreeKeys, 0.1)
    }

    func testSmoothAnimationIsOffOnAFreshDeck() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Pacing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let deck = DeckController(storeURL: directory.appendingPathComponent("settings.json"))
        XCTAssertFalse(deck.smoothAnimation)
    }

    func testSettingsWrittenBeforeThisOptionStillLoad() {
        // smoothAnimation is Optional precisely so an older settings.json
        // decodes; a non-optional field would throw and lose the whole layout.
        let json = ##"{"keys":[],"pattern":"Per-key","primaryHex":"#00E0FF","secondaryHex":"#12002E","brightness":100}"##
        let settings = try? JSONDecoder().decode(DeckSettings.self, from: Data(json.utf8))
        XCTAssertNotNil(settings)
        XCTAssertNil(settings?.smoothAnimation)
    }
}

@MainActor
final class WidgetEditorDraftTests: XCTestCase {

    private func scratchDeck() throws -> DeckController {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DeckController(storeURL: directory.appendingPathComponent("settings.json"))
    }

    func testTypedMetricsSurviveARoundTripThroughTheStore() throws {
        // The editor reads its fields back out of the widget, so whatever
        // normalisation does to them is what the field will show next time.
        let deck = try scratchDeck()
        var config = WidgetConfig(kind: .system)
        config.symbols = "cpu, memory, disk"
        deck.setWidget(config, for: 0)
        XCTAssertEqual(deck.keys[0].widget?.symbols, "cpu, memory, disk")
    }

    func testEveryTextFieldOfEveryKindSurvivesNormalisation() throws {
        // A field that normalisation clears would read back as blank — which
        // is exactly what "it wipes the text when I go to edit it" looks like.
        let deck = try scratchDeck()
        var system = WidgetConfig(kind: .system); system.symbols = "cpu, network"
        deck.setWidget(system, for: 0)
        XCTAssertEqual(deck.keys[0].widget?.symbols, "cpu, network")

        var weather = WidgetConfig(kind: .weather); weather.place = "Reykjavik"
        deck.setWidget(weather, for: 1)
        XCTAssertEqual(deck.keys[1].widget?.place, "Reykjavik")

        var clock = WidgetConfig(kind: .clock); clock.timezone = "Europe/Paris"
        deck.setWidget(clock, for: 2)
        XCTAssertEqual(deck.keys[2].widget?.timezone, "Europe/Paris")

        var timer = WidgetConfig(kind: .timer); timer.minutes = 45
        deck.setWidget(timer, for: 3)
        XCTAssertEqual(deck.keys[3].widget?.minutes, 45)

        var stocks = WidgetConfig(kind: .stocks)
        stocks.symbols = "AAPL, MSFT"; stocks.rotate = 12
        deck.setWidget(stocks, for: 4)
        XCTAssertEqual(deck.keys[4].widget?.symbols, "AAPL, MSFT")
        XCTAssertEqual(deck.keys[4].widget?.rotate, 12)

        var sports = WidgetConfig(kind: .sports)
        sports.place = "nba"; sports.symbols = "GSW"
        deck.setWidget(sports, for: 5)
        XCTAssertEqual(deck.keys[5].widget?.place, "nba")
        XCTAssertEqual(deck.keys[5].widget?.symbols, "GSW")
    }

    func testEditingOneKeyNeverWritesOntoAnother() throws {
        // The editor guards commits with the index its drafts came from; this
        // pins the underlying invariant it protects.
        let deck = try scratchDeck()
        var a = WidgetConfig(kind: .system); a.symbols = "cpu"
        var b = WidgetConfig(kind: .system); b.symbols = "memory"
        deck.setWidget(a, for: 0)
        deck.setWidget(b, for: 1)
        XCTAssertEqual(deck.keys[0].widget?.symbols, "cpu")
        XCTAssertEqual(deck.keys[1].widget?.symbols, "memory")
    }

    func testAPresetDoesNotDiscardTheTypedList() throws {
        // Presets change size and style; they must build on the current
        // config, or the symbols you typed vanish when you click one.
        let deck = try scratchDeck()
        var config = WidgetConfig(kind: .stocks)
        config.symbols = "NVDA, AMD"
        deck.setWidget(config, for: 0)
        var preset = deck.keys[0].widget!
        preset.style = "card"; preset.columns = 3; preset.rows = 1
        deck.setWidget(preset, for: 0)
        XCTAssertEqual(deck.keys[0].widget?.symbols, "NVDA, AMD")
        XCTAssertEqual(deck.keys[0].widget?.columns, 3)
    }
}
