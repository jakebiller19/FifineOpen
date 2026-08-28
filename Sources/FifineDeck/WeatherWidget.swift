import AppKit
import Foundation

/// Weather from Open-Meteo.
///
/// Chosen over every other weather API for one reason: it needs no key and no
/// account, so this widget works the moment you type a city. Place names are
/// resolved through the same project's geocoding endpoint and then cached, so
/// a widget costs one lookup ever and one small forecast call per refresh.
struct WeatherReading {
    var place: String = ""
    var temperature: Double? = nil
    var high: Double? = nil
    var low: Double? = nil
    var wind: Double? = nil
    var code: Int = 0
    var isDay: Bool = true
    var units: String = "metric"
    var ok: Bool = false
    var error: String = ""

    var unitSuffix: String { units == "imperial" ? "°F" : "°C" }

    var signature: String {
        let t = temperature.map { String(format: "%.0f", $0) } ?? "—"
        let h = high.map { String(format: "%.0f", $0) } ?? "—"
        let l = low.map { String(format: "%.0f", $0) } ?? "—"
        return "\(ok)|\(error)|\(place)|\(t)|\(h)|\(l)|\(code)|\(isDay)|\(units)"
    }

    /// WMO weather code -> a plain description and an SF Symbol.
    /// https://open-meteo.com/en/docs — the codes are a fixed standard.
    var summary: (text: String, symbol: String) {
        switch code {
        case 0:          return ("Clear", isDay ? "sun.max.fill" : "moon.stars.fill")
        case 1, 2:       return ("Partly cloudy", isDay ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3:          return ("Overcast", "cloud.fill")
        case 45, 48:     return ("Fog", "cloud.fog.fill")
        case 51, 53, 55: return ("Drizzle", "cloud.drizzle.fill")
        case 56, 57:     return ("Freezing drizzle", "cloud.sleet.fill")
        case 61, 63, 65: return ("Rain", "cloud.rain.fill")
        case 66, 67:     return ("Freezing rain", "cloud.sleet.fill")
        case 71, 73, 75: return ("Snow", "cloud.snow.fill")
        case 77:         return ("Snow grains", "cloud.snow.fill")
        case 80, 81, 82: return ("Showers", "cloud.heavyrain.fill")
        case 85, 86:     return ("Snow showers", "cloud.snow.fill")
        case 95:         return ("Thunderstorm", "cloud.bolt.rain.fill")
        case 96, 99:     return ("Thunder, hail", "cloud.bolt.rain.fill")
        default:         return ("—", "cloud.fill")
        }
    }
}

actor WeatherProvider: WidgetProviding {
    /// Resolved coordinates by place name. A city does not move, so this is
    /// looked up once per name for the life of the process.
    private var located: [String: (lat: Double, lon: Double, name: String)] = [:]
    private var failed: Set<String> = []

    private static let timeout: TimeInterval = 8

    nonisolated func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        let reading = WeatherReading(place: config.place, units: config.units)
        return WidgetSnapshot(signature: "weather:placeholder|" + reading.signature,
                              payload: reading)
    }

    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        let name = config.place.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return wrap(WeatherReading(units: config.units, error: "no place"))
        }
        do {
            let place = try await locate(name)
            var reading = try await forecast(place, units: config.units)
            reading.place = place.name
            reading.units = config.units
            reading.ok = true
            return wrap(reading)
        } catch {
            return wrap(WeatherReading(place: name, units: config.units,
                                       error: Self.describe(error)))
        }
    }

    private func wrap(_ reading: WeatherReading) -> WidgetSnapshot {
        WidgetSnapshot(signature: "weather:" + reading.signature, payload: reading)
    }

    // MARK: - Network

    private func locate(_ name: String) async throws -> (lat: Double, lon: Double, name: String) {
        if let hit = located[name] { return hit }
        if failed.contains(name) { throw WidgetError.message("unknown place") }

        // "48.85,2.35" — skip geocoding entirely for explicit coordinates.
        let parts = name.split(separator: ",")
        if parts.count == 2, let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
           let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)),
           abs(lat) <= 90, abs(lon) <= 180 {
            let hit = (lat, lon, name)
            located[name] = hit
            return hit
        }

        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [.init(name: "name", value: name),
                                 .init(name: "count", value: "1"),
                                 .init(name: "format", value: "json")]
        let json = try await Self.get(components)
        guard let results = json["results"] as? [[String: Any]], let first = results.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double
        else {
            // Remember the miss: a typo'd city would otherwise be looked up on
            // every single refresh, forever.
            failed.insert(name)
            throw WidgetError.message("unknown place")
        }
        let hit = (lat, lon, (first["name"] as? String) ?? name)
        located[name] = hit
        return hit
    }

    private func forecast(_ place: (lat: Double, lon: Double, name: String),
                          units: String) async throws -> WeatherReading {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(place.lat)),
            .init(name: "longitude", value: String(place.lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day,wind_speed_10m"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timezone", value: "auto"),
        ]
        if units == "imperial" {
            components.queryItems? += [.init(name: "temperature_unit", value: "fahrenheit"),
                                       .init(name: "wind_speed_unit", value: "mph")]
        }
        let json = try await Self.get(components)
        guard let current = json["current"] as? [String: Any] else {
            throw WidgetError.message("bad response")
        }
        let daily = json["daily"] as? [String: Any]
        func firstDaily(_ key: String) -> Double? {
            (daily?[key] as? [Any])?.first as? Double
        }
        return WeatherReading(
            temperature: current["temperature_2m"] as? Double,
            high: firstDaily("temperature_2m_max"),
            low: firstDaily("temperature_2m_min"),
            wind: current["wind_speed_10m"] as? Double,
            code: (current["weather_code"] as? Int) ?? 0,
            isDay: ((current["is_day"] as? Int) ?? 1) == 1,
            units: units)
    }

    private static func get(_ components: URLComponents) async throws -> [String: Any] {
        guard let url = components.url else { throw WidgetError.message("bad request") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WidgetError.message("HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WidgetError.message("bad response")
        }
        return json
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
        let reading = snapshot.data(WeatherReading.self) ?? WeatherReading()
        guard reading.ok else {
            WidgetPaint.message("Weather",
                                reading.error.isEmpty ? "loading…" : reading.error,
                                frame: frame, ctx: ctx,
                                tint: WidgetPaint.mix(background, .white, 0.85))
            return
        }
        // Warm when it's warm, cold when it's cold: the face carries the
        // reading before you have read a single digit.
        let tint = Self.tint(for: reading)
        WidgetPaint.fill(frame, WidgetPaint.mix(background, tint, 0.22), ctx: ctx)

        let pad = max(4, cell * 0.09)
        let detail = config.style == "detail"
            || (config.style == "auto" && columns * rows >= 2)

        guard detail else {
            // One key: symbol above, temperature below, place at the foot.
            let unit = min(frame.width, frame.height)
            let side = frame.width * 0.42
            WidgetPaint.glyph(reading.summary.symbol,
                              in: CGRect(x: frame.midX - side / 2, y: frame.minY + pad * 0.6,
                                         width: side, height: side),
                              color: .white, ctx: ctx)
            WidgetPaint.line((reading.temperature.map { String(format: "%.0f", $0) } ?? "—") + "°",
                             in: CGRect(x: frame.minX + pad, y: frame.minY + side * 0.95,
                                        width: frame.width - 2 * pad, height: unit * 0.4),
                             ctx: ctx, size: unit * 0.32, color: .white, align: .center)
            WidgetPaint.line(reading.place.uppercased(),
                             in: CGRect(x: frame.minX + pad, y: frame.maxY - unit * 0.19,
                                        width: frame.width - 2 * pad, height: unit * 0.17),
                             ctx: ctx, size: unit * 0.12,
                             color: WidgetPaint.mix(background, .white, 0.6), align: .center)
            return
        }

        // Wide: three columns — symbol, temperature, everything else — so a
        // 3x1 fills all three keys instead of crowding into the first two.
        let unit = frame.height
        let glyphSide = min(frame.height * 0.78, frame.width * 0.3)
        let glyphRect = CGRect(x: frame.minX + pad, y: frame.midY - glyphSide / 2,
                               width: glyphSide, height: glyphSide)
        WidgetPaint.glyph(reading.summary.symbol, in: glyphRect, color: .white, ctx: ctx)

        let rest = frame.maxX - pad - (glyphRect.maxX + pad)
        // The detail column only earns its place when there is room for it.
        let detailWidth = rest > cell * 1.4 ? rest * 0.44 : 0
        let tempX = glyphRect.maxX + pad
        let tempWidth = rest - detailWidth
        let temperature = (reading.temperature.map { String(format: "%.0f", $0) } ?? "—")
            + reading.unitSuffix
        WidgetPaint.line(temperature,
                         in: CGRect(x: tempX, y: frame.midY - unit * 0.26,
                                    width: tempWidth, height: unit * 0.4),
                         ctx: ctx, size: unit * 0.34, color: .white, shadow: true)
        WidgetPaint.line(reading.summary.text,
                         in: CGRect(x: tempX, y: frame.midY + unit * 0.12,
                                    width: tempWidth, height: unit * 0.2),
                         ctx: ctx, size: unit * 0.15,
                         color: WidgetPaint.mix(background, .white, 0.75))

        guard detailWidth > 0 else { return }
        let hi = reading.high.map { String(format: "%.0f", $0) } ?? "—"
        let lo = reading.low.map { String(format: "%.0f", $0) } ?? "—"
        let wind = reading.wind.map { String(format: "%.0f %@", $0,
                                             reading.units == "imperial" ? "mph" : "km/h") } ?? ""
        let detailX = frame.maxX - pad - detailWidth
        var y = frame.midY - unit * 0.28
        for (text, size, tint) in [(reading.place.uppercased(), 0.14, 0.55),
                                   ("H \(hi)°", 0.16, 0.85),
                                   ("L \(lo)°", 0.16, 0.7),
                                   (wind, 0.13, 0.5)] where !text.isEmpty {
            guard y + unit * 0.2 <= frame.maxY - pad else { break }
            y += WidgetPaint.line(text, in: CGRect(x: detailX, y: y, width: detailWidth,
                                                   height: unit * 0.2),
                                  ctx: ctx, size: unit * size,
                                  color: WidgetPaint.mix(background, .white, CGFloat(tint)),
                                  align: .right)
        }
    }

    /// Blue below freezing through to red in the heat, on the Celsius scale
    /// whatever the display units.
    nonisolated static func tint(for reading: WeatherReading) -> NSColor {
        guard let value = reading.temperature else { return WidgetPaint.muted }
        let celsius = reading.units == "imperial" ? (value - 32) * 5 / 9 : value
        let stops: [(Double, NSColor)] = [
            (-10, NSColor(srgbRed: 0.30, green: 0.55, blue: 0.95, alpha: 1)),
            (5,   NSColor(srgbRed: 0.35, green: 0.75, blue: 0.90, alpha: 1)),
            (15,  NSColor(srgbRed: 0.35, green: 0.80, blue: 0.55, alpha: 1)),
            (24,  NSColor(srgbRed: 0.95, green: 0.75, blue: 0.30, alpha: 1)),
            (34,  NSColor(srgbRed: 0.95, green: 0.35, blue: 0.25, alpha: 1)),
        ]
        if celsius <= stops[0].0 { return stops[0].1 }
        for i in 1..<stops.count where celsius <= stops[i].0 {
            let (lowT, lowC) = stops[i - 1], (highT, highC) = stops[i]
            let t = (celsius - lowT) / (highT - lowT)
            return WidgetPaint.mix(lowC, highC, CGFloat(t))
        }
        return stops[stops.count - 1].1
    }
}
