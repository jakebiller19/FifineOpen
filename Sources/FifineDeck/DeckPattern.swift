import AppKit

/// Effects that treat all 15 keys as one surface.
///
/// Two flavours, for throughput reasons (a full-deck repaint costs ~500 ms,
/// but only changed keys are actually sent):
///
/// - *continuous* patterns paint a 500x300 canvas that gets sliced into keys,
///   so gradients and artwork flow across the whole deck;
/// - *per-key* patterns compute one colour per key, which is far cheaper and
///   usually changes only a few keys per frame - that is what makes the
///   animated ones look smooth.
enum DeckPattern: String, CaseIterable, Identifiable, Codable {
    case none        = "Per-key"
    case linear      = "Linear gradient"
    case radial      = "Radial gradient"
    case rainbow     = "Rainbow"
    case wallpaper   = "Image across deck"
    case scanner     = "Scanner"
    case wave        = "Wave"
    case pulse       = "Pulse"
    case comet       = "Comet"

    var id: String { rawValue }

    /// Whether this pattern needs a running clock.
    var isAnimated: Bool {
        switch self {
        case .none, .linear, .radial, .rainbow, .wallpaper: return false
        case .scanner, .wave, .pulse, .comet:               return true
        }
    }

    /// Animated patterns are per-key, so only a few tiles change per frame.
    var isPerKey: Bool {
        switch self {
        case .scanner, .wave, .pulse, .comet: return true
        default:                              return false
        }
    }

    var usesColors: Bool {
        switch self {
        case .wallpaper, .rainbow, .none: return false
        default:                          return true
        }
    }

    // MARK: - Per-key rendering

    /// One colour per grid index, for the animated patterns.
    func colors(time: Double, primary: NSColor, secondary: NSColor) -> [Int: NSColor] {
        var out: [Int: NSColor] = [:]
        let columns = Double(DeckLayout.columns)

        for index in 0..<DeckLayout.keyCount {
            let column = Double(index % DeckLayout.columns)
            let row = Double(index / DeckLayout.columns)
            var t: Double

            switch self {
            case .scanner:
                // A bright column sweeping left-right and back.
                let head = (sin(time * 2.0) * 0.5 + 0.5) * (columns - 1)
                t = max(0, 1 - abs(column - head) / 1.6)

            case .wave:
                // Diagonal travelling wave.
                t = sin(time * 3.0 - column * 0.9 - row * 0.6) * 0.5 + 0.5

            case .pulse:
                // Whole deck breathing together.
                t = sin(time * 2.2) * 0.5 + 0.5

            case .comet:
                // A head that runs the keys in order with a fading tail.
                let total = Double(DeckLayout.keyCount)
                let head = (time * 6.0).truncatingRemainder(dividingBy: total)
                var distance = Double(index) - head
                if distance > 0 { distance -= total }          // wrap the tail
                t = max(0, 1 + distance / 5.0)                  // 5-key tail

            default:
                t = 0
            }

            out[index] = Self.blend(secondary, primary, t)
        }
        return out
    }

    // MARK: - Canvas rendering

    /// A full-deck image for the continuous patterns.
    func canvas(primary: NSColor, secondary: NSColor, image: NSImage?) -> CGImage? {
        let size = DeckCanvas.size
        guard let ctx = DeckCanvas.makeContext(size: size) else { return nil }
        let rect = CGRect(origin: .zero, size: size)

        switch self {
        case .linear:
            guard let gradient = Self.gradient([secondary, primary]) else { return nil }
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        case .radial:
            guard let gradient = Self.gradient([primary, secondary]) else { return nil }
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.drawRadialGradient(
                gradient,
                startCenter: centre, startRadius: 0,
                endCenter: centre, endRadius: size.width / 2,
                options: [.drawsAfterEndLocation])

        case .rainbow:
            let stops = (0...6).map {
                NSColor(hue: CGFloat($0) / 6.0, saturation: 0.9, brightness: 1.0, alpha: 1)
            }
            guard let gradient = Self.gradient(stops) else { return nil }
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        case .wallpaper:
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(rect)
            guard let image,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { break }
            // Scale to cover, centre-cropped.
            let scale = max(size.width / CGFloat(cg.width), size.height / CGFloat(cg.height))
            let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
            ctx.draw(cg, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2,
                                    width: w, height: h))

        default:
            return nil
        }

        return ctx.makeImage()
    }

    // MARK: - Helpers

    private static func gradient(_ colors: [NSColor]) -> CGGradient? {
        let cgColors = colors.map { ($0.usingColorSpace(.deviceRGB) ?? .black).cgColor }
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: cgColors as CFArray, locations: nil)
    }

    static func blend(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
        let x = CGFloat(max(0, min(1, t)))
        let ca = a.usingColorSpace(.deviceRGB) ?? .black
        let cb = b.usingColorSpace(.deviceRGB) ?? .white
        return NSColor(srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * x,
                       green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * x,
                       blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * x,
                       alpha: 1)
    }
}
