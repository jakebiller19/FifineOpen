import AppKit

/// Treats the whole deck as one image and slices it into per-key JPEGs.
///
/// The deck is 5x3 keys of 100px, so the canvas is 500x300. Everything here
/// works in top-left origin coordinates to match the on-screen grid; the flip
/// to the hardware's bottom-up key order happens in `DeckLayout`.
enum DeckCanvas {
    static let size = CGSize(width: CGFloat(DeckLayout.columns * DeckLayout.keyPixels),
                             height: CGFloat(DeckLayout.rows * DeckLayout.keyPixels))

    /// A bitmap context with a top-left origin, so drawing code reads naturally.
    static func makeContext(size: CGSize) -> CGContext? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    private static func keyContext() -> CGContext? {
        let side = DeckLayout.keyPixels
        return CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    }

    /// Cuts a full-deck image into 15 key tiles, keyed by grid index.
    ///
    /// `CGImage.cropping` uses top-left origin, which is what we drew in.
    static func slice(_ canvas: CGImage) -> [Int: CGImage] {
        var tiles: [Int: CGImage] = [:]
        let side = DeckLayout.keyPixels
        for index in 0..<DeckLayout.keyCount {
            let row = index / DeckLayout.columns
            let column = index % DeckLayout.columns
            let rect = CGRect(x: column * side, y: row * side, width: side, height: side)
            if let tile = canvas.cropping(to: rect) { tiles[index] = tile }
        }
        return tiles
    }

    /// How much of the key an overlay icon fills. A little inset keeps the
    /// gradient visible around the edges so the icon reads as a badge sitting
    /// on the pattern rather than a replacement tile.
    static let overlayInset: CGFloat = 0.78

    /// Composites a transparent icon over whatever has already been drawn.
    ///
    /// Aspect-*fit*, not fill: an icon must not be cropped, and its alpha has
    /// to survive so the pattern shows through. Drawn while the tile is still
    /// upright, like the label.
    static func drawOverlay(_ image: NSImage?, in ctx: CGContext) {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let side = CGFloat(DeckLayout.keyPixels)
        let box = side * overlayInset
        let scale = min(box / CGFloat(cg.width), box / CGFloat(cg.height))
        let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
        ctx.saveGState()
        ctx.setBlendMode(.normal)          // source-over, so alpha is honoured
        ctx.draw(cg, in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        ctx.restoreGState()
    }

    /// Draws a centred label with a shadow, so it stays readable over artwork
    /// or a gradient. Called while the tile is still the right way up.
    static func drawLabel(_ label: String, in ctx: CGContext) {
        guard !label.isEmpty else { return }
        let side = CGFloat(DeckLayout.keyPixels)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 20),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
            .shadow: shadow,
        ]

        let text = label as NSString
        let bounds = text.boundingRect(with: NSSize(width: side, height: side),
                                       options: [.usesLineFragmentOrigin],
                                       attributes: attributes)
        let rect = NSRect(x: 0, y: (side - bounds.height) / 2, width: side, height: bounds.height)
        text.draw(in: rect, withAttributes: attributes)
    }

    /// Encodes one tile as the JPEG the deck expects.
    ///
    /// Two passes on purpose: the label is composited while the tile is still
    /// upright, and only then is the whole thing rotated 180° for the panel
    /// (which is mounted upside-down). Drawing the text after the rotation
    /// would leave it legible only to someone standing behind the deck.
    static func jpeg(from tile: CGImage,
                     overlay: NSImage? = nil,
                     label: String = "",
                     quality: CGFloat = 0.85) -> Data? {
        let side = CGFloat(DeckLayout.keyPixels)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)

        guard let compose = keyContext() else { return nil }
        compose.draw(tile, in: rect)
        drawOverlay(overlay, in: compose)
        drawLabel(label, in: compose)
        guard let composed = compose.makeImage() else { return nil }

        guard let out = keyContext() else { return nil }
        out.translateBy(x: side, y: side)
        out.rotate(by: .pi)
        out.draw(composed, in: rect)
        guard let rotated = out.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: rotated)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Full-deck image to per-key JPEGs, with optional icons and labels on top.
    static func keyJPEGs(from canvas: CGImage,
                         overlays: [Int: NSImage] = [:],
                         labels: [Int: String] = [:],
                         quality: CGFloat = 0.85) -> [Int: Data] {
        var out: [Int: Data] = [:]
        for (index, tile) in slice(canvas) {
            if let data = jpeg(from: tile, overlay: overlays[index],
                               label: labels[index] ?? "", quality: quality) {
                out[index] = data
            }
        }
        return out
    }

    /// Solid colour per key, with optional icons and labels. Used by the
    /// animated patterns, which are per-key rather than canvas-wide.
    static func keyJPEGs(colors: [Int: NSColor],
                         overlays: [Int: NSImage] = [:],
                         labels: [Int: String] = [:],
                         quality: CGFloat = 0.85) -> [Int: Data] {
        var out: [Int: Data] = [:]
        let side = CGFloat(DeckLayout.keyPixels)
        for (index, color) in colors {
            guard let fill = keyContext() else { continue }
            fill.setFillColor((color.usingColorSpace(.deviceRGB) ?? .black).cgColor)
            fill.fill(CGRect(x: 0, y: 0, width: side, height: side))
            guard let tile = fill.makeImage() else { continue }
            if let data = jpeg(from: tile, overlay: overlays[index],
                               label: labels[index] ?? "", quality: quality) {
                out[index] = data
            }
        }
        return out
    }
}
