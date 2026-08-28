import AppKit
import Foundation

/// Owns the widget providers, caches what they last returned, and paints
/// frames.
///
/// Main-actor for the cache and the drawing (AppKit text layout belongs here,
/// and the deck controller is main-actor anyway); the providers are actors, so
/// the network and the AppleScript hop happen off it. A widget refresh
/// therefore never blocks a keypress or the animation clock.
@MainActor
final class WidgetRuntime {
    private struct Stream: Hashable {
        let config: WidgetConfig
        let cells: Int
    }

    private var cache: [Stream: WidgetSnapshot] = [:]

    /// Distinct streams kept. A deck holds at most 15 widgets; anything past
    /// this is churn from the editor rather than configuration.
    private static let cacheLimit = 32
    private var order: [Stream] = []

    private func provider(_ kind: WidgetKind) -> any WidgetProviding {
        WidgetRegistry.provider(for: kind)
    }

    // MARK: - Data

    /// The last data for this widget, or an empty placeholder. Never blocks.
    func snapshot(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        cache[Stream(config: config, cells: cells)]
            ?? provider(config.kind).placeholder(config, cells: cells)
    }

    func hasData(_ config: WidgetConfig, cells: Int) -> Bool {
        cache[Stream(config: config, cells: cells)] != nil
    }

    /// Fetches and caches. Suspends on the network; call from a Task.
    @discardableResult
    func refresh(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        let snapshot = await provider(config.kind).fetch(config, cells: cells)
        let stream = Stream(config: config, cells: cells)
        if cache.updateValue(snapshot, forKey: stream) == nil { order.append(stream) }
        while order.count > Self.cacheLimit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return snapshot
    }

    func forgetAll() {
        cache.removeAll()
        order.removeAll()
    }

    // MARK: - Press

    /// Runs the action for the KEY that was pressed. Returns true if the
    /// widget's own state changed (a ticker page turned, a timer started) so
    /// the caller can repaint at once.
    ///
    /// The cell matters: a transport-bar widget gives each of its keys a
    /// different action, so "which widget" is not enough to know what to do.
    func press(_ config: WidgetConfig, cell: WidgetCell) async -> Bool {
        let provider = provider(config.kind)
        guard provider.action(for: config, cell: cell) != "none" else { return false }
        let snapshot = snapshot(config, cells: cell.cellCount)
        return await provider.press(config, cell: cell, snapshot: snapshot)
    }

    // MARK: - Painting

    /// One frame for the whole widget: `columns x rows` keys wide, upright.
    func frame(_ config: WidgetConfig, snapshot: WidgetSnapshot,
               columns: Int, rows: Int, background: NSColor) -> CGImage? {
        guard let ctx = WidgetPaint.frame(columns: columns, rows: rows,
                                          background: background) else { return nil }
        provider(config.kind).draw(snapshot, config: config, columns: columns,
                                   rows: rows, background: background, ctx: ctx)
        return ctx.makeImage()
    }

    /// One key-sized crop of a widget frame.
    ///
    /// A crop that falls outside the frame (a layout that moved under a
    /// half-finished repaint) comes back nil rather than trapping on the
    /// render path.
    nonisolated static func tile(_ frame: CGImage, dx: Int, dy: Int) -> CGImage? {
        let side = DeckLayout.keyPixels
        let rect = CGRect(x: dx * side, y: dy * side, width: side, height: side)
        guard rect.maxX <= CGFloat(frame.width), rect.maxY <= CGFloat(frame.height)
        else { return nil }
        return frame.cropping(to: rect)
    }
}
