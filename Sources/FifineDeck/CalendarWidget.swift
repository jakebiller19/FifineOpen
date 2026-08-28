import AppKit
import EventKit
import Foundation

/// The next thing in your calendar.
///
/// Needs Calendar access, which macOS asks for once. Unlike the other
/// widgets, a refusal here is permanent until the user changes it in System
/// Settings, so the face says exactly that rather than looking empty.
struct CalendarReading {
    var title: String = ""
    var location: String = ""
    var start: Date?
    var end: Date?
    var allDay: Bool = false
    var calendarColor: NSColor?
    var authorized: Bool = true
    var error: String = ""
    var upcoming: [(title: String, start: Date)] = []

    var hasEvent: Bool { start != nil }

    /// Minutes until it starts; negative while it is happening.
    var minutesAway: Int {
        guard let start else { return 0 }
        return Int(start.timeIntervalSinceNow / 60)
    }

    var countdown: String {
        guard let start else { return "" }
        let seconds = start.timeIntervalSinceNow
        if seconds < 0 {
            if let end, end.timeIntervalSinceNow > 0 { return "now" }
            return "started"
        }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(max(minutes, 1)) min" }
        let hours = minutes / 60
        if hours < 24 { return "in \(hours) h \(minutes % 60) m" }
        return "in \(hours / 24) d"
    }

    var signature: String {
        let s = start.map { String(Int($0.timeIntervalSince1970)) } ?? "—"
        // The countdown changes on its own, so it is part of the picture.
        return "\(authorized)|\(error)|\(title)|\(s)|\(allDay)|\(minutesAway)|\(upcoming.count)"
    }
}

actor CalendarProvider: WidgetProviding {
    private let store = EKEventStore()
    private var askedForAccess = false

    nonisolated func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        let reading = CalendarReading()
        return WidgetSnapshot(signature: "calendar:placeholder|" + reading.signature,
                              payload: reading)
    }

    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        guard await ensureAccess() else {
            let reading = CalendarReading(authorized: false, error: "allow calendar")
            return wrap(reading)
        }
        let now = Date()
        // A week is far enough that an empty calendar reads as "nothing on"
        // rather than "broken", and short enough to stay cheap.
        let horizon = now.addingTimeInterval(7 * 24 * 3600)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600),
                                                 end: horizon, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { event in
                // Drop events that already ended, and all-day entries unless
                // they are today — a week of birthdays would bury the meeting
                // you actually need to see.
                guard let end = event.endDate else { return false }
                if end < now { return false }
                if event.isAllDay {
                    return Calendar.current.isDateInToday(event.startDate)
                }
                return true
            }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }

        guard let next = events.first else {
            return wrap(CalendarReading(error: "nothing scheduled"))
        }
        var reading = CalendarReading(
            title: next.title ?? "(no title)",
            location: next.location ?? "",
            start: next.startDate, end: next.endDate, allDay: next.isAllDay,
            calendarColor: next.calendar?.color)
        reading.upcoming = events.dropFirst().prefix(4).compactMap {
            guard let start = $0.startDate else { return nil }
            return ($0.title ?? "(no title)", start)
        }
        return wrap(reading)
    }

    func press(_ config: WidgetConfig, cell: WidgetCell, snapshot: WidgetSnapshot) async -> Bool {
        guard config.press == "open" else { return false }
        await MainActor.run {
            // Open Calendar rather than the event: an event URL needs a
            // calendar-item identifier that Calendar.app does not accept from
            // outside, and landing on today's view is what you wanted anyway.
            NSWorkspace.shared.open(URL(string: "ical://")!)
        }
        return false
    }

    private func wrap(_ reading: CalendarReading) -> WidgetSnapshot {
        WidgetSnapshot(signature: "calendar:" + reading.signature, payload: reading)
    }

    /// Asks once, then reports whatever the answer was.
    private func ensureAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            if status == .fullAccess { return true }
        }
        if status == .authorized { return true }
        guard status == .notDetermined, !askedForAccess else { return false }
        askedForAccess = true
        do {
            if #available(macOS 14.0, *) {
                return try await store.requestFullAccessToEvents()
            }
            return try await store.requestAccess(to: .event)
        } catch {
            return false
        }
    }

    // MARK: - Painting

    @MainActor
    func draw(_ snapshot: WidgetSnapshot, config: WidgetConfig,
                          columns: Int, rows: Int, background: NSColor, ctx: CGContext) {
        let cell = CGFloat(DeckLayout.keyPixels)
        let frame = CGRect(x: 0, y: 0, width: CGFloat(columns) * cell,
                           height: CGFloat(rows) * cell)
        let reading = snapshot.data(CalendarReading.self) ?? CalendarReading()
        guard reading.hasEvent else {
            WidgetPaint.message("Calendar",
                                reading.error.isEmpty ? "loading…" : reading.error,
                                frame: frame, ctx: ctx,
                                tint: WidgetPaint.mix(background, .white, 0.85))
            return
        }
        // Tinted with the event's own calendar colour, so work and personal
        // are distinguishable at a glance.
        let accent = reading.calendarColor
            ?? NSColor(srgbRed: 0.16, green: 0.80, blue: 0.95, alpha: 1)
        // Amber inside ten minutes, red once it has started: a key you notice.
        let urgency: NSColor = reading.minutesAway < 0 ? WidgetPaint.red
            : (reading.minutesAway <= 10
               ? NSColor(srgbRed: 0.95, green: 0.72, blue: 0.25, alpha: 1) : accent)
        WidgetPaint.fill(frame, WidgetPaint.mix(background, urgency, 0.18), ctx: ctx)

        let pad = max(4, cell * 0.09)
        let unit = min(frame.height, cell * 1.2)
        let width = frame.width - 2 * pad
        var y = frame.minY + pad

        let time = reading.allDay ? "ALL DAY" : Self.time(reading.start)
        y += WidgetPaint.line(time, in: CGRect(x: pad, y: y, width: width, height: unit * 0.34),
                              ctx: ctx, size: unit * 0.26, color: .white, shadow: true)
        y += WidgetPaint.line(reading.title,
                              in: CGRect(x: pad, y: y, width: width, height: unit * 0.26),
                              ctx: ctx, size: unit * 0.17,
                              color: WidgetPaint.mix(background, .white, 0.85))
        if y + unit * 0.2 <= frame.maxY {
            let detail = reading.location.isEmpty ? reading.countdown
                : "\(reading.countdown) · \(reading.location)"
            y += WidgetPaint.line(detail,
                                  in: CGRect(x: pad, y: y, width: width, height: unit * 0.2),
                                  ctx: ctx, size: unit * 0.13,
                                  color: WidgetPaint.mix(background, .white, 0.6))
        }
        // Room to spare: list what follows, which is the whole point of the
        // "agenda" style on a wide widget.
        let agenda = config.style == "agenda"
            || (config.style == "auto" && rows >= 2)
        guard agenda, !reading.upcoming.isEmpty else { return }
        for event in reading.upcoming {
            guard y + unit * 0.22 <= frame.maxY - pad else { break }
            WidgetPaint.line("\(Self.time(event.start))  \(event.title)",
                             in: CGRect(x: pad, y: y, width: width, height: unit * 0.2),
                             ctx: ctx, size: unit * 0.13,
                             color: WidgetPaint.mix(background, .white, 0.5))
            y += unit * 0.19
        }
    }

    nonisolated static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return formatter.string(from: date)
    }
}
