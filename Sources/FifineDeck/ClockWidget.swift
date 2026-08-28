import AppKit
import Foundation

/// A clock: digital, analog, or a date face. Local — nothing to fetch, so it
/// keeps working with the network down and costs nothing to refresh.
struct ClockReading {
    var date: Date
    var timezone: TimeZone
    var label: String            // the zone's short name, when it isn't ours

    /// Bucketed to the minute unless the face shows seconds, so a clock only
    /// repaints when its picture actually changes.
    func signature(showsSeconds: Bool) -> String {
        let unit: TimeInterval = showsSeconds ? 1 : 60
        return "\(timezone.identifier)|\(Int(date.timeIntervalSince1970 / unit))"
    }
}

struct ClockProvider: WidgetProviding {

    func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        snapshot(config)
    }

    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        snapshot(config)
    }

    private func snapshot(_ config: WidgetConfig) -> WidgetSnapshot {
        let zone = TimeZone(identifier: config.timezone.trimmingCharacters(in: .whitespaces))
            ?? .current
        let reading = ClockReading(date: Date(), timezone: zone,
                                   label: zone == .current ? "" : Self.shortName(zone))
        return WidgetSnapshot(
            signature: "clock:" + reading.signature(showsSeconds: config.interval < 5),
            payload: reading)
    }

    /// "Europe/Paris" -> "PARIS". The city is what identifies a world clock;
    /// the continent is noise on a 100 px key.
    static func shortName(_ zone: TimeZone) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier)
            .replacingOccurrences(of: "_", with: " ")
            .uppercased()
    }

    @MainActor
    func draw(_ snapshot: WidgetSnapshot, config: WidgetConfig,
              columns: Int, rows: Int, background: NSColor, ctx: CGContext) {
        let cell = CGFloat(DeckLayout.keyPixels)
        let frame = CGRect(x: 0, y: 0, width: CGFloat(columns) * cell,
                           height: CGFloat(rows) * cell)
        let reading = snapshot.data(ClockReading.self)
            ?? ClockReading(date: Date(), timezone: .current, label: "")
        let accent = WidgetPaint.mix(background, .white, 0.9)

        switch style(config, columns: columns, rows: rows) {
        case "analog":
            drawAnalog(reading, frame: frame, cell: cell, background: background, ctx: ctx)
        case "date":
            drawDate(reading, frame: frame, cell: cell, accent: accent,
                     background: background, ctx: ctx)
        default:
            drawDigital(reading, config: config, frame: frame, cell: cell,
                        accent: accent, background: background, ctx: ctx)
        }
    }

    func style(_ config: WidgetConfig, columns: Int, rows: Int) -> String {
        guard config.style == "auto" else { return config.style }
        // A square block is the shape a clock face wants; anything else reads
        // better as digits.
        return columns == rows && columns >= 2 ? "analog" : "digital"
    }

    // MARK: - Faces

    private func formatter(_ reading: ClockReading, _ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = reading.timezone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private func drawDigital(_ reading: ClockReading, config: WidgetConfig, frame: CGRect,
                             cell: CGFloat, accent: NSColor, background: NSColor,
                             ctx: CGContext) {
        let seconds = config.interval < 5
        let twelve = config.units == "imperial"       // 12-hour clock
        let pattern = (twelve ? "h:mm" : "HH:mm") + (seconds ? ":ss" : "")
        let time = formatter(reading, pattern).string(from: reading.date)
        let unit = min(frame.width / CGFloat(max(time.count, 4)) * 1.9, frame.height)
        let pad = max(4, cell * 0.08)

        var y = frame.midY - unit * 0.34
        if !reading.label.isEmpty || frame.height > cell * 1.4 {
            y = frame.minY + pad + unit * 0.10
        }
        WidgetPaint.line(time, in: CGRect(x: pad, y: y, width: frame.width - 2 * pad,
                                          height: unit * 0.6),
                         ctx: ctx, size: unit * 0.46, color: .white, align: .center)
        let subY = y + unit * 0.52
        let sub = reading.label.isEmpty
            ? formatter(reading, "EEE d MMM").string(from: reading.date).uppercased()
            : reading.label
        if subY + unit * 0.2 <= frame.maxY {
            WidgetPaint.line(sub, in: CGRect(x: pad, y: subY, width: frame.width - 2 * pad,
                                             height: unit * 0.22),
                             ctx: ctx, size: unit * 0.15,
                             color: WidgetPaint.mix(background, .white, 0.6), align: .center)
        }
    }

    private func drawDate(_ reading: ClockReading, frame: CGRect, cell: CGFloat,
                          accent: NSColor, background: NSColor, ctx: CGContext) {
        let pad = max(4, cell * 0.08)
        let unit = min(frame.width, frame.height)
        var y = frame.minY + pad
        y += WidgetPaint.line(formatter(reading, "EEEE").string(from: reading.date).uppercased(),
                              in: CGRect(x: pad, y: y, width: frame.width - 2 * pad,
                                         height: unit * 0.22),
                              ctx: ctx, size: unit * 0.15,
                              color: WidgetPaint.mix(background, .white, 0.65), align: .center)
        y += WidgetPaint.line(formatter(reading, "d").string(from: reading.date),
                              in: CGRect(x: pad, y: y, width: frame.width - 2 * pad,
                                         height: unit * 0.55),
                              ctx: ctx, size: unit * 0.46, color: .white, align: .center)
        WidgetPaint.line(formatter(reading, "MMMM").string(from: reading.date).uppercased(),
                         in: CGRect(x: pad, y: y, width: frame.width - 2 * pad,
                                    height: unit * 0.22),
                         ctx: ctx, size: unit * 0.15,
                         color: WidgetPaint.mix(background, .white, 0.75), align: .center)
    }

    private func drawAnalog(_ reading: ClockReading, frame: CGRect, cell: CGFloat,
                            background: NSColor, ctx: CGContext) {
        let radius = min(frame.width, frame.height) / 2 - max(4, cell * 0.08)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let face = WidgetPaint.mix(background, .white, 0.10)
        ctx.setFillColor((face.usingColorSpace(.deviceRGB) ?? .black).cgColor)
        ctx.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                   width: radius * 2, height: radius * 2))
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.25).cgColor)
        ctx.setLineWidth(max(1, radius * 0.03))
        ctx.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                     width: radius * 2, height: radius * 2))

        // Hour ticks. Twelve of them is legible even at one key.
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.45).cgColor)
        for tick in 0..<12 {
            let angle = Double(tick) / 12 * 2 * .pi
            let inner = radius * (tick % 3 == 0 ? 0.76 : 0.86)
            ctx.setLineWidth(max(1, radius * (tick % 3 == 0 ? 0.06 : 0.03)))
            ctx.move(to: point(centre, inner, angle))
            ctx.addLine(to: point(centre, radius * 0.94, angle))
            ctx.strokePath()
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = reading.timezone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: reading.date)
        let minute = Double(parts.minute ?? 0) + Double(parts.second ?? 0) / 60
        let hour = Double((parts.hour ?? 0) % 12) + minute / 60

        hand(ctx, centre, radius * 0.52, hour / 12 * 2 * .pi, radius * 0.085, .white)
        hand(ctx, centre, radius * 0.78, minute / 60 * 2 * .pi, radius * 0.055, .white)
        if radius > 26 {
            hand(ctx, centre, radius * 0.86, Double(parts.second ?? 0) / 60 * 2 * .pi,
                 max(1, radius * 0.02), WidgetPaint.red)
        }
        ctx.setFillColor(NSColor.white.cgColor)
        let pin = max(1.5, radius * 0.06)
        ctx.fillEllipse(in: CGRect(x: centre.x - pin, y: centre.y - pin,
                                   width: pin * 2, height: pin * 2))
    }

    /// Clock angles run clockwise from 12, while the drawing context's y grows
    /// downward — so 12 o'clock is -y and the sine term is not negated.
    private func point(_ centre: CGPoint, _ length: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: centre.x + length * CGFloat(sin(angle)),
                y: centre.y - length * CGFloat(cos(angle)))
    }

    private func hand(_ ctx: CGContext, _ centre: CGPoint, _ length: CGFloat,
                      _ angle: Double, _ width: CGFloat, _ color: NSColor) {
        ctx.setStrokeColor((color.usingColorSpace(.deviceRGB) ?? .white).cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.move(to: centre)
        ctx.addLine(to: point(centre, length, angle))
        ctx.strokePath()
    }
}
