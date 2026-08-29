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

/// Saving: what reaches the disk, and when.
///
/// Writes are coalesced now, so "did the edit persist" and "did it persist
/// *yet*" are different questions and both are worth asking.
@MainActor
final class PersistenceTests: XCTestCase {

    /// Never the real settings file — see `scratchDeck` above for the
    /// regression that rule exists for.
    private func scratch() throws -> (DeckController, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        return (DeckController(storeURL: url), url)
    }

    private func stored(_ url: URL) throws -> DeckSettings {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DeckSettings.self, from: data)
    }

    func testBrightnessIsPersisted() throws {
        // It was the one field in DeckSettings with nothing calling save(),
        // so it survived only when an unrelated edit wrote the file after it.
        let (deck, url) = try scratch()
        deck.brightness = 42
        deck.saveNow()
        XCTAssertEqual(try stored(url).brightness, 42)
    }

    func testBrightnessSurvivesAReload() throws {
        let (deck, url) = try scratch()
        deck.brightness = 17
        deck.saveNow()
        XCTAssertEqual(DeckController(storeURL: url).brightness, 17)
    }

    func testAnEditIsNotWrittenImmediately() throws {
        // The point of the coalescing: a drag sends a change per pixel, and
        // none of them may reach the disk on the spot.
        let (deck, url) = try scratch()
        deck.brightness = 55
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testACoalescedEditReachesTheDisk() throws {
        let (deck, url) = try scratch()
        deck.brightness = 66
        let landed = expectation(description: "settings written")
        // Comfortably past the debounce, so a slow machine does not fail it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { landed.fulfill() }
        wait(for: [landed], timeout: 3)
        XCTAssertEqual(try stored(url).brightness, 66)
    }

    func testTheLastEditOfABurstIsTheOneStored() throws {
        // A drag ends where the mouse stopped, not somewhere in the middle.
        let (deck, url) = try scratch()
        for level in stride(from: 0, through: 100, by: 10) {
            deck.brightness = Double(level)
        }
        deck.saveNow()
        XCTAssertEqual(try stored(url).brightness, 100)
    }

    func testSaveNowSupersedesAPendingWrite() throws {
        // Quitting flushes through saveNow(); the debounced write that was
        // already scheduled must not then land on top with older state.
        let (deck, url) = try scratch()
        deck.brightness = 10        // schedules a coalesced write
        deck.brightness = 90
        deck.saveNow()
        let settled = expectation(description: "any pending write has had its chance")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(try stored(url).brightness, 90)
    }
}

/// Opening at login.
///
/// Deliberately no test that turns it on: registering a login item is a real
/// change to the machine running the tests, and unregistering it afterwards
/// would not undo having asked the user's System Settings about it.
final class LoginItemTests: XCTestCase {

    func testABareBinaryCannotRegister() {
        // The test bundle is not an .app, which is exactly the case that
        // must fail with an explanation rather than an obscure OSStatus.
        XCTAssertFalse(LoginItem.isSupported)
        let problem = LoginItem.set(true)
        XCTAssertNotNil(problem, "an unsupported host must say so")
    }

    func testAskingAnUnsupportedHostChangesNothing() {
        LoginItem.set(true)
        XCTAssertFalse(LoginItem.isEnabled)
    }
}

/// The committed `.env.template`.
///
/// It is documentation that can go stale silently — a renamed key or a typo
/// in it costs someone an afternoon — so it is checked against the code that
/// actually reads the file.
final class EnvTemplateTests: XCTestCase {

    private var templateURL: URL {
        // From this file, not the working directory: `swift test` runs from
        // wherever it was invoked.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // FifineDeckTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent(".env.template")
    }

    private func template() throws -> String {
        try String(contentsOf: templateURL, encoding: .utf8)
    }

    func testEveryKeyTheAppReadsIsDocumented() throws {
        let text = try template()
        for key in WidgetCredentials.Key.allCases {
            for name in key.environmentNames {
                XCTAssertTrue(text.contains(name),
                              "\(name) is read by the app but absent from .env.template")
            }
        }
        XCTAssertTrue(text.contains("FIFINE_DECK_ENV"))
    }

    func testEverySettingItDeclaresIsOneTheAppReads() throws {
        let declared = Set(WidgetCredentials.parseDotenv(try template()).keys)
        let known = Set(WidgetCredentials.Key.allCases.flatMap(\.environmentNames))
        XCTAssertTrue(declared.isSubset(of: known),
                      "unrecognised names in .env.template: \(declared.subtracting(known))")
        XCTAssertFalse(declared.isEmpty, "the template declares nothing at all")
    }

    func testTheTemplateCarriesNoValues() throws {
        // It is committed. A value in it is a leaked credential.
        for (name, value) in WidgetCredentials.parseDotenv(try template()) {
            XCTAssertTrue(value.isEmpty, "\(name) has a value in the committed template")
        }
    }

    func testAnEmptyTemplateValueShadowsNothing() {
        // Copying the template to .env and filling in one key must not make
        // the app think the others are set to "".
        let parsed = WidgetCredentials.parseDotenv("FINNHUB_KEY=\nSPOTIFY_CLIENT_ID=abc")
        XCTAssertEqual(parsed["FINNHUB_KEY"], "")
        XCTAssertEqual(parsed["SPOTIFY_CLIENT_ID"], "abc")
    }

    func testTheDocumentedRedirectURIIsTheOneTheLoginUses() throws {
        // The single most common setup failure: Spotify matches the redirect
        // literally, so the string in the docs has to be the string the
        // listener registers, character for character.
        XCTAssertTrue(try template().contains(SpotifyAuth.redirectURI()),
                      "the template documents a redirect URI the login does not use")
        XCTAssertEqual(SpotifyAuth.redirectURI(), "http://127.0.0.1:8888/callback")
    }

    func testTheScopesDocumentedAreTheScopesRequested() {
        XCTAssertTrue(SpotifyAuth.scope.contains("user-read-playback-state"))
        // Without this one a transport key draws its badge and then cannot
        // act on it.
        XCTAssertTrue(SpotifyAuth.scope.contains("user-modify-playback-state"))
    }
}

/// Generated artwork. Nothing here spends a call — the shaping and the file
/// naming are pure, which is why they are shaped that way.
final class ImageGenTests: XCTestCase {

    private func body(_ prompt: String, _ style: ImageGen.Style,
                      _ shape: ImageGen.Shape) -> [String: Any] {
        ImageGen.requestBody(prompt: prompt, style: style, shape: shape)
    }

    func testTheTypedPromptSurvives() {
        let text = body("a red panda", .icon, .key)["prompt"] as? String
        XCTAssertTrue(text?.hasPrefix("a red panda") == true,
                      "what the user typed must lead the prompt")
    }

    func testAnIconIsDirectedToReadAtKeySize() {
        // A key is 100x100. Without this direction the model returns a
        // photograph, which at that size is mud.
        let text = (body("an owl", .icon, .key)["prompt"] as? String) ?? ""
        XCTAssertTrue(text.contains("flat vector icon"))
        XCTAssertTrue(text.contains("high contrast"))
        XCTAssertTrue(text.contains("no text"))
    }

    func testALogoIsAllowedItsLettering() {
        let text = (body("ACME", .logo, .key)["prompt"] as? String) ?? ""
        XCTAssertTrue(text.contains("lettering"))
        XCTAssertFalse(text.contains("no lettering"), "a logo is the one case that wants text")
    }

    func testPromptExpansionIsOff() {
        // Measured against this endpoint: expansion cost 46 s on a cold model
        // against 0.3 s of inference, and it rewrites the prompt besides.
        for style in ImageGen.Style.allCases {
            XCTAssertEqual(body("x", style, .key)["expansion_model"] as? String, "None")
        }
    }

    func testAKeyAsksForASquare() {
        XCTAssertEqual(body("x", .icon, .key)["image_size"] as? String, "square")
        XCTAssertEqual(body("x", .icon, .key)["output_format"] as? String, "png")
    }

    func testTheDeckAsksForTheCanvasAspect() {
        // 5:3, the shape DeckCanvas slices into keys — asking for the right
        // aspect beats cropping a wrong one.
        let size = body("x", .art, .deck)["image_size"] as? [String: Int]
        XCTAssertEqual(size?["width"], 1280)
        XCTAssertEqual(size?["height"], 768)
        let ratio = Double(size?["width"] ?? 0) / Double(size?["height"] ?? 1)
        XCTAssertEqual(ratio, 500.0 / 300.0, accuracy: 0.001)
        XCTAssertEqual(body("x", .art, .deck)["output_format"] as? String, "jpeg")
    }

    func testTheSafetyCheckerIsAlwaysAskedFor() {
        XCTAssertEqual(body("x", .icon, .key)["enable_safety_checker"] as? Bool, true)
        XCTAssertEqual(body("x", .icon, .key)["num_images"] as? Int, 1)
    }

    func testTheEndpointIsTheSynchronousOne() {
        // Not queue.fal.run: this model finishes in under a second, so
        // polling would cost more round trips than the work.
        XCTAssertEqual(ImageGen.endpoint.absoluteString,
                       "https://fal.run/ideogram/v4/instant")
    }

    // MARK: File naming

    func testAFilenameIsReadable() {
        let name = ImageGen.filename(prompt: "A Red Panda!", format: "png",
                                     date: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(name, "a-red-panda-1700000000.png")
    }

    func testAPromptCannotSteerThePath() {
        // The prompt is user text that becomes a filename. Every separator
        // has to be gone before it reaches the filesystem.
        let name = ImageGen.filename(prompt: "../../etc/passwd", format: "png")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(".."))
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    func testAnUnusableePromptStillNamesAFile() {
        let name = ImageGen.filename(prompt: "🎧🎧🎧", format: "jpeg")
        XCTAssertTrue(name.hasPrefix("image-"))
        XCTAssertTrue(name.hasSuffix(".jpg"), "jpeg is written with the extension people expect")
    }

    func testALongPromptIsTrimmed() {
        let name = ImageGen.filename(prompt: String(repeating: "wide ", count: 60), format: "png")
        XCTAssertLessThan(name.count, 64)
    }

    func testTwoImagesFromOnePromptDoNotCollide() {
        let first = ImageGen.filename(prompt: "owl", format: "png",
                                      date: Date(timeIntervalSince1970: 100))
        let second = ImageGen.filename(prompt: "owl", format: "png",
                                       date: Date(timeIntervalSince1970: 200))
        XCTAssertNotEqual(first, second)
    }

    func testImagesAreKeptWhereSettingsCanPointAtThem() {
        // settings.json stores the path, so a temp directory would blank the
        // key on the next reboot.
        let path = ImageGen.directory.path
        XCTAssertTrue(path.contains("Application Support/FifineDeck"))
        XCTAssertFalse(path.hasPrefix(NSTemporaryDirectory()))
    }

    // MARK: Failures

    func testEachFailureNamesItsFix() {
        XCTAssertTrue(ImageGen.describe(status: 401, body: Data()).contains("FAL_KEY"))
        XCTAssertTrue(ImageGen.describe(status: 402, body: Data()).contains("credit"))
        XCTAssertTrue(ImageGen.describe(status: 429, body: Data()).contains("rate limited"))
    }

    func testTheServersOwnComplaintIsShown() {
        let body = Data(#"{"detail":"prompt is required"}"#.utf8)
        XCTAssertTrue(ImageGen.describe(status: 422, body: body).contains("prompt is required"))
    }

    func testAValidationListIsUnwrapped() {
        // 422 answers with a list of field errors rather than a string.
        let body = Data(#"{"detail":[{"msg":"image_size is invalid"}]}"#.utf8)
        XCTAssertTrue(ImageGen.describe(status: 422, body: body).contains("image_size is invalid"))
    }

    func testAnUnreadableBodyStillSaysSomething() {
        XCTAssertTrue(ImageGen.describe(status: 500, body: Data("<html>".utf8)).contains("500"))
    }

    func testNoKeyIsReportedBeforeAnyRequestIsMade() async throws {
        // Only meaningful where the machine running the tests has no key —
        // and `try?` here would swallow the skip and fire a real, paid
        // request at fal.ai instead.
        try XCTSkipIf(WidgetCredentials.has(.fal), "this machine has a FAL_KEY")
        do {
            _ = try await ImageGen.generate(prompt: "x", style: .icon, shape: .key)
            XCTFail("generating without a key must throw")
        } catch {
            XCTAssertTrue(ImageGen.message(for: error).contains("FAL_KEY"))
        }
    }

    /// The real thing, end to end — off by default because it costs money.
    ///
    ///     FIFINE_LIVE_TESTS=1 swift test --filter testAgainstTheRealAPI
    func testAgainstTheRealAPI() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FIFINE_LIVE_TESTS"] == "1",
                          "live test: set FIFINE_LIVE_TESTS=1 to spend a call")
        try XCTSkipUnless(WidgetCredentials.has(.fal), "no FAL_KEY available")

        let url = try await ImageGen.generate(prompt: "a single white coffee cup",
                                              style: .icon, shape: .key)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let image = try XCTUnwrap(NSImage(contentsOf: url), "the saved file must be an image")
        XCTAssertGreaterThanOrEqual(image.size.width, 256)
        XCTAssertEqual(image.size.width, image.size.height, "a key image is square")
    }
}

/// Re-framing a generated icon.
///
/// Synthetic images throughout: the point is that the geometry is
/// deterministic, which is the whole reason framing is not left to the prompt.
final class FramingTests: XCTestCase {

    /// A `subject`-coloured rectangle on a `background`-coloured square.
    private func png(side: Int, background: NSColor, subject: NSColor?,
                     rect: NSRect?) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        background.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        if let subject, let rect { subject.setFill(); rect.fill() }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Where the non-background pixels are, in fractions of the square.
    private func subjectBounds(_ data: Data) throws -> (x0: Double, x1: Double,
                                                        y0: Double, y1: Double) {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let ground = try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let far = abs(c.redComponent - ground.redComponent) > 0.15
                    || abs(c.greenComponent - ground.greenComponent) > 0.15
                    || abs(c.blueComponent - ground.blueComponent) > 0.15
                guard far else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX, "the framed image has no subject in it")
        return (Double(minX) / Double(w), Double(maxX) / Double(w),
                Double(minY) / Double(h), Double(maxY) / Double(h))
    }

    func testASubjectInACornerIsCentred() throws {
        // The failure this exists for: the model puts the subject against an
        // edge, and on a 100 px key that reads as a mistake.
        let source = try png(side: 256, background: .black, subject: .white,
                             rect: NSRect(x: 6, y: 6, width: 70, height: 70))
        let framed = try XCTUnwrap(ImageGen.framed(source), "a cornered subject must be re-framed")
        let box = try subjectBounds(framed)
        XCTAssertEqual((box.x0 + box.x1) / 2, 0.5, accuracy: 0.03, "not horizontally centred")
        XCTAssertEqual((box.y0 + box.y1) / 2, 0.5, accuracy: 0.03, "not vertically centred")
    }

    func testTheSubjectGetsAMarginOnEverySide() throws {
        let source = try png(side: 256, background: .black, subject: .white,
                             rect: NSRect(x: 0, y: 0, width: 200, height: 200))
        let framed = try XCTUnwrap(ImageGen.framed(source))
        let box = try subjectBounds(framed)
        let margin = ImageGen.framingMargin - 0.02      // tolerance for resampling
        XCTAssertGreaterThan(box.x0, margin)
        XCTAssertGreaterThan(box.y0, margin)
        XCTAssertLessThan(box.x1, 1 - margin)
        XCTAssertLessThan(box.y1, 1 - margin)
    }

    func testAWideSubjectKeepsItsShape() throws {
        // Centring must not stretch anything: a 3:1 banner stays 3:1.
        let source = try png(side: 256, background: .black, subject: .white,
                             rect: NSRect(x: 10, y: 100, width: 180, height: 60))
        let framed = try XCTUnwrap(ImageGen.framed(source))
        let box = try subjectBounds(framed)
        let ratio = (box.x1 - box.x0) / (box.y1 - box.y0)
        XCTAssertEqual(ratio, 3.0, accuracy: 0.35)
    }

    func testAnImageWithNoMarginIsLeftAlone() throws {
        // Edge to edge in both directions: there is no background to measure
        // against, so shrinking it would be a guess. Better to do nothing.
        let source = try png(side: 256, background: .black, subject: .white,
                             rect: NSRect(x: 0, y: 0, width: 256, height: 256))
        XCTAssertNil(ImageGen.framed(source))
    }

    func testAnEmptyImageIsLeftAlone() throws {
        let source = try png(side: 256, background: .black, subject: nil, rect: nil)
        XCTAssertNil(ImageGen.framed(source))
    }

    func testTheBackgroundColourIsKept() throws {
        // Re-framing paints new margin, and it has to be the colour the
        // picture already had or the key gets a visible frame around it.
        let ground = NSColor(red: 0.05, green: 0.07, blue: 0.20, alpha: 1)
        let source = try png(side: 256, background: ground, subject: .white,
                             rect: NSRect(x: 4, y: 4, width: 60, height: 60))
        let framed = try XCTUnwrap(ImageGen.framed(source))

        // Compared against the SOURCE read back the same way, not against the
        // NSColor it was built from: both files decode through the same
        // colour-space conversion, and comparing across that measures the
        // conversion rather than the framing.
        func corner(_ data: Data) throws -> NSColor {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
            return try XCTUnwrap(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
        }
        let before = try corner(source), after = try corner(framed)
        XCTAssertEqual(after.redComponent, before.redComponent, accuracy: 0.02)
        XCTAssertEqual(after.greenComponent, before.greenComponent, accuracy: 0.02)
        XCTAssertEqual(after.blueComponent, before.blueComponent, accuracy: 0.02)
    }

    func testRubbishInIsNotACrash() throws {
        XCTAssertNil(ImageGen.framed(Data("not an image".utf8)))
        XCTAssertNil(ImageGen.framed(Data()))
    }

    func testArtIsNotReframed() {
        // Filling the frame is the point of a deck background.
        XCTAssertFalse(ImageGen.Style.art.framesSubject)
        XCTAssertTrue(ImageGen.Style.icon.framesSubject)
        XCTAssertTrue(ImageGen.Style.logo.framesSubject)
    }
}

/// Per-key gradient backgrounds.
final class KeyGradientTests: XCTestCase {

    func testAKeyIsAFlatColourUntilToldOtherwise() {
        let key = KeyConfig()
        XCTAssertFalse(key.hasGradient)
        XCTAssertNil(key.gradientEnd)
    }

    func testSettingsWrittenBeforeGradientsExistedStillLoad() throws {
        // The whole reason the two fields are optional: a non-optional would
        // throw out of the decoder and lose every key in the file.
        let json = ##"{"colorHex":"#112233","label":"hi","action":{"none":{}}}"##
        let key = try XCTUnwrap(try? JSONDecoder().decode(KeyConfig.self, from: Data(json.utf8)))
        XCTAssertEqual(key.colorHex, "#112233")
        XCTAssertFalse(key.hasGradient)
    }

    func testAGradientSurvivesARoundTrip() throws {
        var key = KeyConfig()
        key.gradientHex = "#FF00AA"
        key.gradientStyle = "radial"
        let data = try JSONEncoder().encode(key)
        let back = try JSONDecoder().decode(KeyConfig.self, from: data)
        XCTAssertEqual(back.gradientHex, "#FF00AA")
        XCTAssertTrue(back.gradientIsRadial)
    }

    func testAnUnreadableSecondColourIsTreatedAsAbsent() {
        // Not as black: a hand-edited file with a typo in it should give a
        // flat key, not a key that fades into nothing.
        var key = KeyConfig()
        key.gradientHex = "not a colour"
        XCTAssertNil(key.gradientEnd)
        XCTAssertFalse(key.hasGradient)
    }

    func testAnUnknownStyleFallsBackToLinear() {
        var key = KeyConfig()
        key.gradientHex = "#FFFFFF"
        key.gradientStyle = "spiral"
        XCTAssertFalse(key.gradientIsRadial)
    }

    func testAGradientChangesWhatTheDeckIsSent() throws {
        // The assertion that the gradient is actually drawn, rather than
        // stored and forgotten.
        var flat = KeyConfig()
        flat.colorHex = "#203040"
        var faded = flat
        faded.gradientHex = "#A0C0FF"

        let flatJPEG = try XCTUnwrap(KeyImage.jpeg(for: flat))
        let fadedJPEG = try XCTUnwrap(KeyImage.jpeg(for: faded))
        XCTAssertNotEqual(flatJPEG, fadedJPEG)

        var radial = faded
        radial.gradientStyle = "radial"
        XCTAssertNotEqual(try XCTUnwrap(KeyImage.jpeg(for: radial)), fadedJPEG,
                          "linear and radial must not render the same")
    }

    func testALinearGradientRunsTopToBottom() throws {
        var key = KeyConfig()
        key.colorHex = "#000000"
        key.gradientHex = "#FFFFFF"
        let data = try XCTUnwrap(KeyImage.jpeg(for: key))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        // The key image is rotated 180° on the way out, so the file's first
        // row is the BOTTOM of the key the user looks at — which is where
        // the light end belongs.
        let top = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: 2)?
            .usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 3)?
            .usingColorSpace(.deviceRGB))
        XCTAssertNotEqual(top.brightnessComponent, bottom.brightnessComponent, accuracy: 0.001)
        XCTAssertGreaterThan(abs(top.brightnessComponent - bottom.brightnessComponent), 0.5,
                             "a black-to-white gradient must actually span the key")
    }

    func testARadialGradientIsBrightestInTheMiddle() throws {
        var key = KeyConfig()
        key.colorHex = "#FFFFFF"
        key.gradientHex = "#000000"
        key.gradientStyle = "radial"
        let data = try XCTUnwrap(KeyImage.jpeg(for: key))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        let middle = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
            .usingColorSpace(.deviceRGB))
        let corner = try XCTUnwrap(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(middle.brightnessComponent, corner.brightnessComponent + 0.3)
    }

    @MainActor
    func testTurningOnAGradientPicksAVisibleSecondColour() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Gradient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let deck = DeckController(storeURL: directory.appendingPathComponent("settings.json"))

        // A dark key has nowhere to fade but lighter, and a light key nowhere
        // but darker. Either way the two ends must be tellable apart.
        for hex in ["#0A0A12", "#F0C000"] {
            deck.keys[0].colorHex = hex
            let end = try XCTUnwrap(NSColor(hex: deck.suggestedGradientEnd(for: 0))?
                .usingColorSpace(.deviceRGB))
            let base = try XCTUnwrap(NSColor(hex: hex)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(abs(end.brightnessComponent - base.brightnessComponent), 0.15,
                                 "\(hex) faded into something indistinguishable from itself")
        }
    }
}

/// Nothing this repository would publish may carry a credential.
///
/// The template test above covers `.env.template`. This one covers everything
/// else, because the file a secret lands in by accident is never the file you
/// were watching.
final class RepositoryHygieneTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // FifineDeckTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // repo root
    }

    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "not a git checkout")
        return String(decoding: data, as: UTF8.self)
    }

    /// Exactly the set `git commit -a` would publish: tracked, plus untracked
    /// that nothing ignores. A file `.gitignore` covers is not this test's
    /// business — that is what makes `.env` itself allowed to exist.
    private func committableFiles() throws -> [String] {
        try git(["ls-files", "-co", "--exclude-standard"])
            .split(separator: "\n").map(String.init)
    }

    func testTheWorkingCopyHasFilesToCheck() throws {
        XCTAssertGreaterThan(try committableFiles().count, 10)
    }

    func testTheEnvFileIsNotCommittable() throws {
        let files = try committableFiles()
        XCTAssertFalse(files.contains(".env"), ".env must never be committable")
        XCTAssertTrue(files.contains(".env.template"), "the template is meant to ship")
    }

    func testNoCommittableFileAssignsACredential() throws {
        // Every name the app reads, in `NAME=value` or `NAME: value` form,
        // with something substantial after it.
        let names = WidgetCredentials.Key.allCases.flatMap(\.environmentNames)
        let pattern = try NSRegularExpression(
            pattern: "(\(names.joined(separator: "|")))\\s*[=:]\\s*[\"']?([A-Za-z0-9_.:/+-]{8,})")

        for file in try committableFiles() {
            let url = root.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard let range = Range(match.range(at: 2), in: text) else { continue }
                let value = String(text[range])
                // Placeholders are the point of the template and the docs.
                let allowed = ["deadbeef", "YOUR_API_KEY", "YOUR_FAL_KEY"]
                XCTAssertTrue(allowed.contains(where: { value.hasPrefix($0) }),
                              "\(file) looks like it carries a real credential")
            }
        }
    }

    func testNoCommittableFileCarriesAPrivateKey() throws {
        // Assembled at run time rather than written out: this file is itself
        // one of the files being scanned, and a literal PEM header in it
        // would make the test fail on its own source.
        let opening = "-----" + "BEGIN "
        let markers = ["RSA PRIVATE KEY", "OPENSSH PRIVATE KEY", "PRIVATE KEY",
                       "EC PRIVATE KEY", "PGP PRIVATE KEY BLOCK", "CERTIFICATE"]
            .map { opening + $0 }

        for file in try committableFiles() {
            let url = root.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for marker in markers {
                XCTAssertFalse(text.contains(marker),
                               "\(file) contains \(marker.replacingOccurrences(of: opening, with: "a "))")
            }
        }
    }

    func testTheCredentialFilesAreAllIgnored() throws {
        // Not just .env: widgets.json holds live tokens and settings.json
        // holds every Run-command string in plain text.
        for name in [".env", ".env.local", "widgets.json", "settings.json"] {
            let status = try git(["check-ignore", "-q", name])
            XCTAssertEqual(status, "", "unexpected output for \(name)")
        }
    }
}
