import AppKit
import CoreGraphics

/// Drawing helpers for widget frames.
///
/// Everything works in frame pixels with a top-left origin (the context
/// `DeckCanvas.makeContext` hands out), because a widget frame is not square —
/// it is `columns x rows` keys — and nothing here may assume otherwise.
enum WidgetPaint {
    static let green = NSColor(srgbRed: 0.11, green: 0.72, blue: 0.33, alpha: 1)   // #1DB954
    static let red   = NSColor(srgbRed: 1.00, green: 0.37, blue: 0.43, alpha: 1)   // #ff5f6d
    static let muted = NSColor(srgbRed: 0.46, green: 0.49, blue: 0.47, alpha: 1)

    // MARK: - Colour

    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let x = a.usingColorSpace(.sRGB) ?? .black
        let y = b.usingColorSpace(.sRGB) ?? .black
        let k = min(max(t, 0), 1)
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * k,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * k,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * k,
                       alpha: 1)
    }

    /// A saturated, reasonably bright colour from the artwork — the accent the
    /// progress bar and the play pip use. Falls back to the average when the
    /// art is uniformly grey (a black-and-white cover).
    static func accent(from image: CGImage) -> NSColor {
        guard let pixels = samples(of: image, side: 24) else { return green }
        var best: (r: Int, g: Int, b: Int)? = nil
        var bestScore = -1.0
        var sum = (r: 0, g: 0, b: 0)
        for p in pixels {
            sum = (sum.r + p.r, sum.g + p.g, sum.b + p.b)
            let hi = max(p.r, max(p.g, p.b)), lo = min(p.r, min(p.g, p.b))
            // Refuse near-black and blown-out pixels: both draw an unreadable
            // bar over the art.
            guard hi >= 60, lo <= 225 else { continue }
            let score = Double(hi - lo) / 255.0 * 2.0 + Double(hi) / 255.0
            if score > bestScore { bestScore = score; best = p }
        }
        let n = max(pixels.count, 1)
        let pick = best ?? (sum.r / n, sum.g / n, sum.b / n)
        return NSColor(srgbRed: CGFloat(pick.r) / 255, green: CGFloat(pick.g) / 255,
                       blue: CGFloat(pick.b) / 255, alpha: 1)
    }

    private static func samples(of image: CGImage, side: Int) -> [(r: Int, g: Int, b: Int)]? {
        let bytesPerRow = side * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * side)
        guard let ctx = data.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(data: buffer.baseAddress, width: side, height: side,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var out: [(r: Int, g: Int, b: Int)] = []
        out.reserveCapacity(side * side)
        for i in stride(from: 0, to: data.count, by: 4) {
            out.append((Int(data[i]), Int(data[i + 1]), Int(data[i + 2])))
        }
        return out
    }

    // MARK: - Images

    /// Draws a CGImage the right way up.
    ///
    /// Everything here paints into a context whose CTM is flipped so that
    /// drawing code can use top-left origin coordinates like the on-screen
    /// grid. `CGContext.draw` does not care about that: it always places an
    /// image bottom-up, so in this context every image came out vertically
    /// mirrored. It went unnoticed for as long as it did because album art and
    /// the transport glyphs are near enough symmetric — it took a
    /// cloud-with-rain symbol, which read as a steaming cup, to make it
    /// obvious.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// Draws `image` so it fills `rect` completely, centre-cropped. Cover, not
    /// fit: a letterboxed album cover on a key looks like a bug.
    static func drawCover(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        let sw = CGFloat(image.width), sh = CGFloat(image.height)
        guard sw > 0, sh > 0, rect.width > 0, rect.height > 0 else { return }
        let scale = max(rect.width / sw, rect.height / sh)
        let w = sw * scale, h = sh * scale
        ctx.saveGState()
        ctx.clip(to: rect)
        drawImage(image, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2,
                                    width: w, height: h), ctx: ctx)
        ctx.restoreGState()
    }

    /// A vertical black gradient over `rect`. Album art needs one under any
    /// text, or the title is unreadable on a bright cover.
    static func scrim(_ rect: CGRect, ctx: CGContext,
                      topAlpha: CGFloat = 0, bottomAlpha: CGFloat = 0.85) {
        guard rect.width > 0, rect.height > 0,
              let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [NSColor(white: 0, alpha: topAlpha).cgColor,
                         NSColor(white: 0, alpha: bottomAlpha).cgColor] as CFArray,
                locations: [0, 1])
        else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        // The context is y-flipped, so "down the screen" is +y here.
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.minY),
                               end: CGPoint(x: rect.midX, y: rect.maxY),
                               options: [])
        ctx.restoreGState()
    }

    static func fill(_ rect: CGRect, _ color: NSColor, ctx: CGContext) {
        ctx.setFillColor((color.usingColorSpace(.deviceRGB) ?? .black).cgColor)
        ctx.fill(rect)
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat, _ color: NSColor,
                            ctx: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let r = min(radius, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r,
                          transform: nil)
        ctx.saveGState()
        ctx.setFillColor((color.usingColorSpace(.deviceRGB) ?? .black).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - Text

    enum Align { case left, center, right }

    /// Draws one line, shrinking the font a little and then truncating with an
    /// ellipsis until it fits `rect.width`. Returns the height used, so
    /// callers can stack lines. Multi-line input is folded to one line: a
    /// pasted track title genuinely contains newlines, and these are
    /// single-line faces.
    ///
    /// The shrink is capped at `shrinkFloor` of the requested size rather than
    /// running all the way down to `minimumSize`. Unbounded shrinking inverted
    /// the type hierarchy on every long title: "Everything In Its Right Place"
    /// collapsed to 7pt while "Radiohead" underneath it stayed at 18, so the
    /// artist read as the headline. A title that will not fit should be
    /// truncated at its own size, not demoted.
    @discardableResult
    static func line(_ text: String, in rect: CGRect, ctx: CGContext,
                     size: CGFloat, color: NSColor, align: Align = .left,
                     shadow: Bool = false, minimumSize: CGFloat = 7,
                     shrinkFloor: CGFloat = 0.8) -> CGFloat {
        let flat = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !flat.isEmpty, rect.width > 2 else { return 0 }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // flipped: true — the context has a top-left origin, and AppKit text
        // drawn into an unflipped context would come out upside-down.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        var fontSize = max(size, minimumSize)
        let floorSize = max(minimumSize, (size * shrinkFloor).rounded(.down))
        var attributes = attrs(fontSize: fontSize, color: color, align: align,
                               shadow: shadow)
        var string = flat as NSString
        while fontSize > floorSize,
              string.size(withAttributes: attributes).width > rect.width {
            fontSize -= 1
            attributes = attrs(fontSize: fontSize, color: color, align: align,
                               shadow: shadow)
        }
        if string.size(withAttributes: attributes).width > rect.width {
            string = truncate(flat, to: rect.width, attributes: attributes) as NSString
            guard string.length > 0 else { return 0 }
        }
        let height = string.size(withAttributes: attributes).height
        string.draw(in: CGRect(x: rect.minX, y: rect.minY,
                               width: rect.width, height: max(height, rect.height)),
                    withAttributes: attributes)
        return height
    }

    private static func attrs(fontSize: CGFloat, color: NSColor, align: Align,
                              shadow: Bool) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = align == .left ? .left : (align == .center ? .center : .right)
        style.lineBreakMode = .byClipping
        var out: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        if shadow {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.9)
            s.shadowBlurRadius = 3
            s.shadowOffset = .zero
            out[.shadow] = s
        }
        return out
    }

    private static func truncate(_ text: String, to width: CGFloat,
                                 attributes: [NSAttributedString.Key: Any]) -> String {
        var low = 0, high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(text.prefix(mid)) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low > 0 ? String(text.prefix(low)) + "…" : ""
    }

    // MARK: - Shapes

    static func progressBar(_ rect: CGRect, fraction: Double, accent: NSColor,
                            track: NSColor, ctx: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        roundedRect(rect, radius: rect.height / 2, track, ctx: ctx)
        let f = min(max(fraction, 0), 1)
        guard f > 0 else { return }
        let width = max(rect.height, rect.width * CGFloat(f))
        roundedRect(CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    radius: rect.height / 2, accent, ctx: ctx)
    }

    /// Line chart of `values` inside `rect`, with an optional fill underneath.
    /// A flat series still draws a centred line rather than vanishing — a
    /// stock that has not ticked yet is data, not an error.
    static func sparkline(_ values: [Double], in rect: CGRect, ctx: CGContext,
                          color: NSColor, fill: NSColor? = nil, width: CGFloat = 2) {
        guard values.count >= 2, rect.width > 1, rect.height > 1 else { return }
        let low = values.min()!, high = values.max()!
        let span = high - low
        let step = rect.width / CGFloat(values.count - 1)
        // 6% headroom so a peak is not clipped flat against the box edge.
        let inset = rect.height * 0.06
        let points: [CGPoint] = values.enumerated().map { i, v in
            let t = span <= 0 ? 0.5 : (v - low) / span
            return CGPoint(x: rect.minX + CGFloat(i) * step,
                           y: rect.maxY - inset - (rect.height - 2 * inset) * CGFloat(t))
        }
        ctx.saveGState()
        if let fill {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: points[0].x, y: rect.maxY))
            points.forEach { ctx.addLine(to: $0) }
            ctx.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            ctx.closePath()
            ctx.setFillColor((fill.usingColorSpace(.deviceRGB) ?? .black).cgColor)
            ctx.fillPath()
        }
        ctx.beginPath()
        ctx.move(to: points[0])
        points.dropFirst().forEach { ctx.addLine(to: $0) }
        ctx.setStrokeColor((color.usingColorSpace(.deviceRGB) ?? .white).cgColor)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Action badge

    private static var symbolCache: [String: CGImage] = [:]
    private static let symbolLock = NSLock()

    /// A white SF Symbol as a CGImage, cached. Rendering one is cheap but not
    /// free, and a widget repaints on every tick.
    private static func symbol(_ name: String) -> CGImage? {
        symbolLock.lock(); defer { symbolLock.unlock() }
        if let cached = symbolCache[name] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        symbolCache[name] = cg
        return cg
    }

    /// Draws an SF Symbol centred in `rect`, aspect-fit, in one colour.
    static func glyph(_ name: String, in rect: CGRect, color: NSColor, ctx: CGContext) {
        guard rect.width > 1, rect.height > 1, let image = symbol(name) else { return }
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        let box = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        // The cached symbol is already white; anything else needs a tint pass.
        //
        // Compared component-wise on purpose: -whiteComponent throws an
        // NSException on an RGB colour ("not valid for the NSColor sRGB
        // colorspace"), and an AppKit exception is not catchable in Swift — it
        // took the whole app down the first time a control face was drawn.
        let rgb = color.usingColorSpace(.sRGB)
        let isWhite = (rgb?.redComponent ?? 0) > 0.99
            && (rgb?.greenComponent ?? 0) > 0.99
            && (rgb?.blueComponent ?? 0) > 0.99
        if isWhite {
            drawImage(image, in: box, ctx: ctx)
            return
        }
        // A clip mask is placed with the same bottom-up convention as an
        // image, so it needs the same flip.
        ctx.saveGState()
        ctx.translateBy(x: box.minX, y: box.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(x: 0, y: 0, width: box.width, height: box.height)
        ctx.clip(to: local, mask: image)
        ctx.setFillColor((color.usingColorSpace(.deviceRGB) ?? .white).cgColor)
        ctx.fill(local)
        ctx.restoreGState()
    }

    /// The badge in the top-right corner that says what PRESSING this key
    /// does — a transport glyph on a dark disc.
    ///
    /// Not the same thing as a state indicator, which is what used to be here:
    /// a dot that means "playing" tells you nothing about a key whose press
    /// skips to the next track. The tint carries the state instead — accent
    /// while playing, grey while paused — so one element says both.
    static func actionBadge(_ symbolName: String, frame: CGRect, cell: CGFloat,
                            tint: NSColor, ctx: CGContext) {
        let size = max(16, cell * 0.30)
        let margin = max(3, cell * 0.05)
        let box = CGRect(x: frame.maxX - margin - size, y: frame.minY + margin,
                         width: size, height: size)
        // A disc, not a bare glyph: album art is arbitrary, and white-on-white
        // happens the moment someone plays a record with a pale cover.
        ctx.saveGState()
        ctx.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.fillEllipse(in: box)
        ctx.setStrokeColor((tint.usingColorSpace(.deviceRGB) ?? .white)
            .withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(max(1, size * 0.07))
        ctx.strokeEllipse(in: box.insetBy(dx: size * 0.035, dy: size * 0.035))
        ctx.restoreGState()

        guard let glyph = symbol(symbolName) else { return }
        let inset = size * 0.28
        let available = box.insetBy(dx: inset, dy: inset)
        let scale = min(available.width / CGFloat(glyph.width),
                        available.height / CGFloat(glyph.height))
        let w = CGFloat(glyph.width) * scale, h = CGFloat(glyph.height) * scale
        drawImage(glyph, in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2,
                                    width: w, height: h), ctx: ctx)
    }

    /// The play/pause pip in a corner — used only when a key has no press
    /// action, where there is nothing to advertise but the state still matters.
    static func stateDot(playing: Bool, frame: CGRect, cell: CGFloat,
                         accent: NSColor, ctx: CGContext) {
        let r = max(2, cell * 0.035)
        let center = CGPoint(x: frame.maxX - 2 * r - 2, y: frame.minY + 2 * r)
        if playing {
            ctx.setFillColor((accent.usingColorSpace(.deviceRGB) ?? .green).cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r,
                                       width: 2 * r, height: 2 * r))
        } else {
            let bar = max(1, r / 2)
            ctx.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
            ctx.fill(CGRect(x: center.x - r, y: center.y - r, width: bar, height: 2 * r))
            ctx.fill(CGRect(x: center.x + r - bar, y: center.y - r, width: bar, height: 2 * r))
        }
    }

    // MARK: - Frames

    /// A blank widget frame, `columns x rows` keys, with a top-left origin.
    static func frame(columns: Int, rows: Int, background: NSColor) -> CGContext? {
        let size = CGSize(width: CGFloat(columns * DeckLayout.keyPixels),
                          height: CGFloat(rows * DeckLayout.keyPixels))
        guard let ctx = DeckCanvas.makeContext(size: size) else { return nil }
        fill(CGRect(origin: .zero, size: size), background, ctx: ctx)
        return ctx
    }

    /// The "we cannot show you anything" face — a title and a reason. Never a
    /// blank key: a widget that failed has to say so on the deck.
    static func message(_ title: String, _ detail: String, frame rect: CGRect,
                        ctx: CGContext, tint: NSColor, detailColor: NSColor = muted) {
        let base = min(rect.width, rect.height)
        line(title, in: CGRect(x: rect.minX + 4, y: rect.minY + rect.height * 0.32,
                               width: rect.width - 8, height: base * 0.3),
             ctx: ctx, size: base * 0.20, color: tint, align: .center)
        line(detail, in: CGRect(x: rect.minX + 4,
                                y: rect.minY + rect.height * 0.32 + base * 0.24,
                                width: rect.width - 8, height: base * 0.2),
             ctx: ctx, size: base * 0.13, color: detailColor, align: .center)
    }
}
