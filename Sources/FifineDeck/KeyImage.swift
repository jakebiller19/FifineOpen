import AppKit

/// Renders what a key should look like into the JPEG the deck expects.
enum KeyImage {
    /// The panels are mounted upside-down, so everything is rotated 180°
    /// before it goes out. Confirmed on hardware.
    private static let rotate180 = true

    /// Builds a `DeckLayout.keyPixels` square JPEG from a background colour,
    /// an optional custom image, and an optional label.
    static func jpeg(color: NSColor, image: NSImage?, label: String) -> Data? {
        let side = DeckLayout.keyPixels
        // Must be 32-bit RGBA: a 24-bit rep is not a valid drawing destination,
        // and NSGraphicsContext(bitmapImageRep:) returns nil for one. JPEG
        // encoding drops the alpha channel again on the way out.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)

        if rotate180 {
            let t = NSAffineTransform()
            t.translateX(by: CGFloat(side), yBy: CGFloat(side))
            t.rotate(byDegrees: 180)
            t.concat()
        }

        (color.usingColorSpace(.deviceRGB) ?? .black).setFill()
        bounds.fill()

        // Custom art is scaled to cover the key, cropped to the square.
        if let image {
            let size = image.size
            if size.width > 0, size.height > 0 {
                let scale = max(CGFloat(side) / size.width, CGFloat(side) / size.height)
                let w = size.width * scale, h = size.height * scale
                let dest = NSRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2,
                                  width: w, height: h)
                image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        }

        if !label.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 20),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
                // A shadow keeps text legible over busy artwork.
                .shadow: {
                    let s = NSShadow()
                    s.shadowColor = NSColor.black.withAlphaComponent(0.9)
                    s.shadowBlurRadius = 3
                    s.shadowOffset = .zero
                    return s
                }(),
            ]
            let text = label as NSString
            let bounding = text.boundingRect(
                with: NSSize(width: side, height: side),
                options: [.usesLineFragmentOrigin], attributes: attrs)
            let rect = NSRect(x: 0, y: (CGFloat(side) - bounding.height) / 2,
                              width: CGFloat(side), height: bounding.height)
            text.draw(in: rect, withAttributes: attrs)
        }

        // Quality 0.9 keeps a key comfortably inside the 16-bit length field.
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
