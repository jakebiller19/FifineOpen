import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An animated GIF, pre-rendered to the exact JPEGs the deck wants.
///
/// The deck has no hardware GIF support - the protocol only carries still
/// JPEGs - so animation means streaming frames. A single key sustains ~15 fps,
/// which is plenty. Frames are encoded once at load time so playback is just a
/// write.
struct GifAnimation {
    let frames: [Data]        // key-ready JPEGs, already rotated
    let delays: [Double]      // seconds per frame
    let sourcePath: String

    var count: Int { frames.count }

    /// Total loop length, useful for picking a sensible tick rate.
    var duration: Double { delays.reduce(0, +) }
}

enum GifPlayer {
    /// How many frames we keep. Long GIFs get sampled evenly rather than
    /// truncated, so the whole loop is still represented.
    private static let maxFrames = 90

    /// The deck cannot show frames faster than this, so anything quicker is
    /// clamped rather than silently dropped.
    static let minDelay = 1.0 / 15.0

    /// Loads a GIF (or any multi-frame image) and pre-encodes its frames.
    static func load(path: String) -> GifAnimation? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let total = CGImageSourceGetCount(source)
        guard total > 0 else { return nil }

        // Sample evenly when a GIF has more frames than we want to hold.
        let indices: [Int]
        if total <= maxFrames {
            indices = Array(0..<total)
        } else {
            indices = (0..<maxFrames).map { $0 * total / maxFrames }
        }

        var frames: [Data] = []
        var delays: [Double] = []

        for index in indices {
            guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            guard let tile = fit(cg) else { continue }
            guard let jpeg = DeckCanvas.jpeg(from: tile) else { continue }
            frames.append(jpeg)
            delays.append(max(minDelay, delay(source, index)))
        }

        guard !frames.isEmpty else { return nil }
        return GifAnimation(frames: frames, delays: delays, sourcePath: path)
    }

    /// Scales a frame to cover a key, centre-cropped to the square.
    private static func fit(_ image: CGImage) -> CGImage? {
        let side = DeckLayout.keyPixels
        guard let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let scale = max(CGFloat(side) / CGFloat(image.width),
                        CGFloat(side) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2,
                                   width: w, height: h))
        return ctx.makeImage()
    }

    /// Per-frame delay from the GIF metadata, defaulting to 10 fps.
    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }

        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return unclamped
        }
        if let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0 {
            return clamped
        }
        return 0.1
    }
}
