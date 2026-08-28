import AppKit
import Foundation

/// A countdown timer you drive from the deck.
///
/// The first widget whose data is its own state rather than something read
/// from elsewhere: press starts and pauses it, and the "refresh" the widget
/// clock performs is just re-reading the clock.
struct TimerReading {
    var remaining: TimeInterval = 0
    var total: TimeInterval = 0
    var running: Bool = false
    var finished: Bool = false

    var fraction: Double { total > 0 ? max(0, min(1, remaining / total)) : 0 }

    var clock: String {
        let seconds = Int(remaining.rounded(.up))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600,
                          (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Whole seconds: a timer that repainted on every fractional tick would
    /// write the same picture to the deck several times a second.
    var signature: String {
        "\(Int(remaining.rounded(.up)))|\(running)|\(finished)|\(Int(total))"
    }
}

actor TimerProvider: WidgetProviding {
    /// One running timer per configured widget, keyed by its config — so two
    /// timer keys with different lengths keep separate countdowns.
    private struct State {
        var endsAt: Date?          // set while running
        var remaining: TimeInterval
        var finished = false
    }

    private var timers: [WidgetConfig: State] = [:]

    nonisolated func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        let reading = TimerReading(remaining: config.minutes * 60,
                                   total: config.minutes * 60)
        return WidgetSnapshot(signature: "timer:" + reading.signature, payload: reading)
    }

    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        WidgetSnapshot(signature: "timer:" + reading(config).signature,
                       payload: reading(config))
    }

    func press(_ config: WidgetConfig, cell: WidgetCell, snapshot: WidgetSnapshot) async -> Bool {
        let total = config.minutes * 60
        var state = timers[config] ?? State(endsAt: nil, remaining: total)
        switch config.press {
        case "reset":
            state = State(endsAt: nil, remaining: total)
        case "start_pause":
            if state.finished {
                // A finished timer restarts rather than refusing to move:
                // pressing a ringing timer means "again", not "nothing".
                state = State(endsAt: Date().addingTimeInterval(total), remaining: total)
            } else if let endsAt = state.endsAt {
                state = State(endsAt: nil, remaining: max(0, endsAt.timeIntervalSinceNow))
            } else {
                let left = state.remaining > 0 ? state.remaining : total
                state = State(endsAt: Date().addingTimeInterval(left), remaining: left)
            }
        default:
            return false
        }
        timers[config] = state
        return true
    }

    private func reading(_ config: WidgetConfig) -> TimerReading {
        let total = config.minutes * 60
        guard var state = timers[config] else {
            return TimerReading(remaining: total, total: total)
        }
        if let endsAt = state.endsAt {
            let left = endsAt.timeIntervalSinceNow
            if left <= 0 {
                state = State(endsAt: nil, remaining: 0, finished: true)
                timers[config] = state
                Self.alert()
            } else {
                state.remaining = left
            }
        }
        return TimerReading(remaining: state.remaining, total: total,
                            running: state.endsAt != nil, finished: state.finished)
    }

    /// One sound when it reaches zero. The deck has no speaker and the app may
    /// be hidden behind everything, so this is the only way a timer can tell
    /// you it is done.
    private static func alert() {
        Task { @MainActor in NSSound(named: "Glass")?.play() }
    }

    // MARK: - Painting

    @MainActor
    func draw(_ snapshot: WidgetSnapshot, config: WidgetConfig,
                          columns: Int, rows: Int, background: NSColor, ctx: CGContext) {
        let cell = CGFloat(DeckLayout.keyPixels)
        let frame = CGRect(x: 0, y: 0, width: CGFloat(columns) * cell,
                           height: CGFloat(rows) * cell)
        let reading = snapshot.data(TimerReading.self) ?? TimerReading()
        // Green running, amber paused, red at zero — readable across a room
        // before any digit is.
        let accent: NSColor = reading.finished ? WidgetPaint.red
            : (reading.running ? WidgetPaint.green
               : NSColor(srgbRed: 0.95, green: 0.72, blue: 0.25, alpha: 1))
        WidgetPaint.fill(frame, WidgetPaint.mix(background, accent, 0.14), ctx: ctx)

        let style = config.style == "auto"
            ? (min(columns, rows) >= 2 ? "ring" : "digits") : config.style
        let unit = min(frame.width, frame.height)

        if style == "ring" {
            let inset = unit * 0.14
            let box = CGRect(x: frame.midX - unit / 2 + inset, y: frame.midY - unit / 2 + inset,
                             width: unit - 2 * inset, height: unit - 2 * inset)
            let radius = min(box.width, box.height) / 2
            let centre = CGPoint(x: box.midX, y: box.midY)
            let width = max(4, unit * 0.08)
            ctx.setLineCap(.round)
            ctx.setLineWidth(width)
            ctx.setStrokeColor(WidgetPaint.mix(background, .white, 0.16).cgColor)
            ctx.addArc(center: centre, radius: radius, startAngle: 0,
                       endAngle: 2 * .pi, clockwise: false)
            ctx.strokePath()
            if reading.fraction > 0 {
                // Starts at twelve o'clock and unwinds clockwise, the way
                // every kitchen timer does.
                let start = -Double.pi / 2
                ctx.setStrokeColor((accent.usingColorSpace(.deviceRGB) ?? .green).cgColor)
                ctx.addArc(center: centre, radius: radius, startAngle: start,
                           endAngle: start + 2 * .pi * reading.fraction, clockwise: false)
                ctx.strokePath()
            }
        }

        let clockY = style == "ring" ? frame.midY - unit * 0.16 : frame.midY - unit * 0.22
        WidgetPaint.line(reading.clock,
                         in: CGRect(x: frame.minX + 4, y: clockY,
                                    width: frame.width - 8, height: unit * 0.34),
                         ctx: ctx, size: unit * (style == "ring" ? 0.26 : 0.32),
                         color: .white, align: .center, shadow: true)
        let label = reading.finished ? "DONE" : (reading.running ? "RUNNING" : "PAUSED")
        WidgetPaint.line(label,
                         in: CGRect(x: frame.minX + 4, y: clockY + unit * 0.30,
                                    width: frame.width - 8, height: unit * 0.18),
                         ctx: ctx, size: unit * 0.12,
                         color: WidgetPaint.mix(background, .white, 0.7), align: .center)
    }
}
