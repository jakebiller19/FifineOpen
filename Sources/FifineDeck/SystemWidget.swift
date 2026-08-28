import AppKit
import Darwin
import Foundation

/// CPU, memory, network, disk and battery, read straight from the kernel.
///
/// No shelling out to `top` or `ps`: sampling every couple of seconds through
/// a subprocess would cost more CPU than it reports on.
struct SystemReading {
    var metric: String
    var title: String
    var value: String
    var detail: String = ""
    var percent: Double?            // 0...100, nil for rates
    var history: [Double] = []
    var ok: Bool = true

    var signature: String {
        "\(metric):\(value):\(detail):\(percent.map { String(format: "%.0f", $0) } ?? "—"):\(history.count)"
    }
}

struct SystemPage {
    var readings: [SystemReading] = []
    var page: Int = 0
    var pages: Int = 1
    var signature: String {
        "\(page)/\(pages)|" + readings.map(\.signature).joined(separator: ",")
    }
}

actor SystemProvider: WidgetProviding {
    static let metrics = ["cpu", "memory", "network", "disk", "battery"]

    private var history: [String: [Double]] = [:]
    private var previousCPU: (idle: Double, total: Double)?
    private var previousNetwork: (bytes: Double, at: Date)?
    private var pages: [WidgetConfig: Int] = [:]

    private static let historyLimit = 48

    nonisolated func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        let metrics = Self.list(config).prefix(max(1, cells))
        let page = SystemPage(readings: metrics.map {
            SystemReading(metric: $0, title: Self.title($0), value: "—")
        })
        return WidgetSnapshot(signature: "system:placeholder|" + page.signature, payload: page)
    }

    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        let all = Self.list(config)
        let cells = max(1, cells)
        let pageCount = max(1, Int(ceil(Double(all.count) / Double(cells))))
        let page = (pages[config] ?? 0) % pageCount
        let visible = Array(all.dropFirst(page * cells).prefix(cells))
        var readings = visible.map { read($0) }
        for i in readings.indices {
            if let percent = readings[i].percent {
                var series = history[readings[i].metric] ?? []
                series.append(percent)
                if series.count > Self.historyLimit {
                    series.removeFirst(series.count - Self.historyLimit)
                }
                history[readings[i].metric] = series
                readings[i].history = series
            }
        }
        let result = SystemPage(readings: readings, page: page, pages: pageCount)
        return WidgetSnapshot(signature: "system:" + result.signature, payload: result)
    }

    func press(_ config: WidgetConfig, cell: WidgetCell, snapshot: WidgetSnapshot) async -> Bool {
        guard config.press == "cycle" else { return false }
        let pageCount = snapshot.data(SystemPage.self)?.pages ?? 1
        guard pageCount > 1 else { return false }
        pages[config] = ((pages[config] ?? 0) + 1) % pageCount
        return true
    }

    nonisolated static func list(_ config: WidgetConfig) -> [String] {
        let wanted = config.symbols
            .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { metrics.contains($0) }
        return wanted.isEmpty ? ["cpu"] : Array(NSOrderedSet(array: wanted)) as? [String] ?? ["cpu"]
    }

    nonisolated static func title(_ metric: String) -> String {
        switch metric {
        case "memory":  return "MEMORY"
        case "network": return "NETWORK"
        case "disk":    return "DISK"
        case "battery": return "BATTERY"
        default:        return "CPU"
        }
    }

    // MARK: - Sampling

    private func read(_ metric: String) -> SystemReading {
        switch metric {
        case "memory":  return memory()
        case "network": return network()
        case "disk":    return disk()
        case "battery": return battery()
        default:        return cpu()
        }
    }

    /// Whole-machine CPU load, as a delta between samples.
    ///
    /// `host_statistics` returns cumulative ticks since boot, so a single
    /// sample says nothing — the first call can only prime the difference.
    private func cpu() -> SystemReading {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size /
                                           MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return SystemReading(metric: "cpu", title: "CPU", value: "n/a", ok: false)
        }
        let idle = Double(info.cpu_ticks.2)
        let total = Double(info.cpu_ticks.0) + Double(info.cpu_ticks.1)
            + idle + Double(info.cpu_ticks.3)
        defer { previousCPU = (idle, total) }
        guard let previous = previousCPU, total > previous.total else {
            return SystemReading(metric: "cpu", title: "CPU", value: "—", percent: nil)
        }
        let busy = 1 - (idle - previous.idle) / (total - previous.total)
        let percent = min(max(busy * 100, 0), 100)
        return SystemReading(metric: "cpu", title: "CPU",
                             value: String(format: "%.0f%%", percent),
                             detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                             percent: percent)
    }

    /// Memory pressure the way Activity Monitor means it: what is actually
    /// spoken for, not "free", which on macOS is always near zero and alarms
    /// people for no reason.
    private func memory() -> SystemReading {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size /
                                           MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS, total > 0 else {
            return SystemReading(metric: "memory", title: "MEMORY", value: "n/a", ok: false)
        }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count)
                    + Double(stats.compressor_page_count)) * page
        let percent = min(max(used / total * 100, 0), 100)
        return SystemReading(metric: "memory", title: "MEMORY",
                             value: String(format: "%.0f%%", percent),
                             detail: "\(Self.bytes(used)) / \(Self.bytes(total))",
                             percent: percent)
    }

    /// Throughput across every real interface, as a rate between samples.
    private func network() -> SystemReading {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return SystemReading(metric: "network", title: "NETWORK", value: "n/a", ok: false)
        }
        defer { freeifaddrs(pointer) }
        var total: Double = 0
        for addr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard addr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: addr.pointee.ifa_name)
            // Loopback and the virtual interfaces double-count traffic that
            // already crossed a real one.
            guard !name.hasPrefix("lo"), !name.hasPrefix("utun"), !name.hasPrefix("awdl"),
                  !name.hasPrefix("llw"), !name.hasPrefix("bridge") else { continue }
            guard let data = addr.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else {
                continue
            }
            total += Double(data.pointee.ifi_ibytes) + Double(data.pointee.ifi_obytes)
        }
        let now = Date()
        defer { previousNetwork = (total, now) }
        guard let previous = previousNetwork else {
            return SystemReading(metric: "network", title: "NETWORK", value: "—")
        }
        let elapsed = max(now.timeIntervalSince(previous.at), 0.001)
        let rate = max(total - previous.bytes, 0) / elapsed
        return SystemReading(metric: "network", title: "NETWORK",
                             value: Self.bytes(rate) + "/s", detail: "up + down",
                             percent: nil)
    }

    private func disk() -> SystemReading {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacity,
              let total = values.volumeTotalCapacity, total > 0
        else {
            return SystemReading(metric: "disk", title: "DISK", value: "n/a", ok: false)
        }
        let used = Double(total - Int(free))
        let percent = used / Double(total) * 100
        return SystemReading(metric: "disk", title: "DISK",
                             value: String(format: "%.0f%%", percent),
                             detail: "\(Self.bytes(Double(free))) free",
                             percent: percent)
    }

    private func battery() -> SystemReading {
        guard let level = Self.batteryLevel() else {
            return SystemReading(metric: "battery", title: "BATTERY",
                                 value: "n/a", detail: "no battery", ok: false)
        }
        return SystemReading(metric: "battery", title: "BATTERY",
                             value: String(format: "%.0f%%", level.percent),
                             detail: level.charging ? "charging" : "on battery",
                             percent: level.percent)
    }

    /// Reads the battery through `pmset`, which every Mac has and which needs
    /// no entitlement, unlike the IOKit power-source APIs.
    nonisolated static func batteryLevel() -> (percent: Double, charging: Bool)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let percentRange = text.range(of: #"\d+(?=%)"#, options: .regularExpression),
              let percent = Double(text[percentRange])
        else { return nil }
        return (percent, text.contains("AC Power") || text.contains("charging"))
    }

    nonisolated static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = value, index = 0
        while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
        return String(format: value >= 100 || index == 0 ? "%.0f %@" : "%.1f %@",
                      value, units[index])
    }

    // MARK: - Painting

    @MainActor
    func draw(_ snapshot: WidgetSnapshot, config: WidgetConfig,
                          columns: Int, rows: Int, background: NSColor, ctx: CGContext) {
        let cell = CGFloat(DeckLayout.keyPixels)
        let page = snapshot.data(SystemPage.self) ?? SystemPage()
        guard !page.readings.isEmpty else {
            WidgetPaint.message("System", "no metrics",
                                frame: CGRect(x: 0, y: 0, width: CGFloat(columns) * cell,
                                              height: CGFloat(rows) * cell),
                                ctx: ctx, tint: WidgetPaint.mix(background, .white, 0.85))
            return
        }
        let style = config.style == "auto"
            ? (columns * rows > 1 ? "number" : "gauge") : config.style
        for (index, reading) in page.readings.enumerated() {
            let rect = CGRect(x: CGFloat(index % columns) * cell,
                              y: CGFloat(index / columns) * cell,
                              width: cell, height: cell)
            drawOne(reading, style: style, rect: rect, cell: cell,
                    background: background, ctx: ctx)
        }
    }

    @MainActor
    private func drawOne(_ reading: SystemReading, style: String, rect: CGRect,
                                     cell: CGFloat, background: NSColor, ctx: CGContext) {
        // Green until it matters, red when it does — 85% is where a machine
        // starts to feel it.
        let hot = (reading.percent ?? 0) >= 85
        let accent = hot ? WidgetPaint.red
            : NSColor(srgbRed: 0.16, green: 0.80, blue: 0.95, alpha: 1)
        let pad = max(3, cell * 0.07)
        WidgetPaint.roundedRect(rect.insetBy(dx: 1, dy: 1), radius: cell * 0.10,
                                WidgetPaint.mix(background, accent, 0.10), ctx: ctx)

        if style == "graph", !reading.history.isEmpty {
            WidgetPaint.sparkline(reading.history,
                                  in: CGRect(x: rect.minX + pad, y: rect.midY,
                                             width: rect.width - 2 * pad,
                                             height: rect.height / 2 - pad),
                                  ctx: ctx, color: accent,
                                  fill: WidgetPaint.mix(background, accent, 0.30))
        } else if style == "gauge", let percent = reading.percent {
            drawGauge(percent, rect: rect, cell: cell, accent: accent,
                      background: background, ctx: ctx)
        }

        var y = rect.minY + pad
        y += WidgetPaint.line(reading.title,
                              in: CGRect(x: rect.minX + pad, y: y,
                                         width: rect.width - 2 * pad, height: cell * 0.2),
                              ctx: ctx, size: cell * 0.14,
                              color: WidgetPaint.mix(background, .white, 0.65))
        let valueY = style == "gauge" ? rect.midY - cell * 0.14 : y
        WidgetPaint.line(reading.value,
                         in: CGRect(x: rect.minX + pad, y: valueY,
                                    width: rect.width - 2 * pad, height: cell * 0.32),
                         ctx: ctx, size: cell * 0.26, color: .white,
                         align: style == "gauge" ? .center : .left, shadow: true)
        if !reading.detail.isEmpty, style != "gauge" {
            WidgetPaint.line(reading.detail,
                             in: CGRect(x: rect.minX + pad, y: rect.maxY - cell * 0.22,
                                        width: rect.width - 2 * pad, height: cell * 0.18),
                             ctx: ctx, size: cell * 0.12,
                             color: WidgetPaint.mix(background, .white, 0.55))
        }
    }

    @MainActor
    private func drawGauge(_ percent: Double, rect: CGRect, cell: CGFloat,
                                       accent: NSColor, background: NSColor, ctx: CGContext) {
        let inset = cell * 0.16
        let box = rect.insetBy(dx: inset, dy: inset)
        let radius = min(box.width, box.height) / 2
        let centre = CGPoint(x: box.midX, y: box.midY)
        let width = max(3, cell * 0.09)
        // A 270° arc opening at the bottom, leaving room for the label.
        let start = 135.0 * .pi / 180, span = 270.0 * .pi / 180
        ctx.setLineCap(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(WidgetPaint.mix(background, .white, 0.18).cgColor)
        ctx.addArc(center: centre, radius: radius, startAngle: start,
                   endAngle: start + span, clockwise: false)
        ctx.strokePath()
        let fraction = min(max(percent / 100, 0), 1)
        guard fraction > 0 else { return }
        ctx.setStrokeColor((accent.usingColorSpace(.deviceRGB) ?? .white).cgColor)
        ctx.addArc(center: centre, radius: radius, startAngle: start,
                   endAngle: start + span * fraction, clockwise: false)
        ctx.strokePath()
    }
}
