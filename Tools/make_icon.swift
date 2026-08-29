#!/usr/bin/env swift
//
// Draws the app icon and writes Resources/AppIcon.icns.
//
//     swift Tools/make_icon.swift
//
// The icon is generated rather than drawn by hand so it can be re-rendered at
// any size from one description — every .icns slice comes out of the same
// code, so the 16pt and 1024pt versions cannot drift apart.
//
// The subject is the deck itself: fifteen keys in the 5x3 layout the hardware
// has, lit by a diagonal colour sweep (the "Rainbow"/"Wave" patterns the app
// paints). At 16pt the keys collapse into a grid texture, which still reads as
// the same thing the menu bar item shows.

import AppKit
import Foundation

// MARK: - Colour

struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat

    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }

    init(r: CGFloat, g: CGFloat, b: CGFloat) { (self.r, self.g, self.b) = (r, g, b) }

    func cg(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    func lightened(_ amount: CGFloat) -> RGB {
        RGB(r: r + (1 - r) * amount, g: g + (1 - g) * amount, b: b + (1 - b) * amount)
    }

    func darkened(_ amount: CGFloat) -> RGB {
        RGB(r: r * (1 - amount), g: g * (1 - amount), b: b * (1 - amount))
    }
}

/// The key ramp, sampled diagonally across the deck.
let ramp = [RGB(0xFF4D8D), RGB(0xB15CFF), RGB(0x4C7DFF), RGB(0x2ED9E8), RGB(0x4BE08A)]

func sampleRamp(_ t: CGFloat) -> RGB {
    let x = min(max(t, 0), 1) * CGFloat(ramp.count - 1)
    let i = min(Int(x), ramp.count - 2)
    let f = x - CGFloat(i)
    let a = ramp[i], b = ramp[i + 1]
    return RGB(r: a.r + (b.r - a.r) * f,
               g: a.g + (b.g - a.g) * f,
               b: a.b + (b.b - a.b) * f)
}

// MARK: - Geometry

/// An Apple-style continuous-corner rounded square.
///
/// `CGPath(roundedRect:)` gives circular corners, which next to a real macOS
/// icon look visibly pinched. A superellipse is what the platform's own icon
/// shape approximates.
func superellipse(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let theta = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(theta), s = sin(theta)
        let x = cx + a * pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = cy + b * pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: colors as CFArray,
               locations: locations)!
}

// MARK: - The drawing

/// Everything is laid out in a 1024-unit square and scaled, so one description
/// serves every slice.
func drawIcon(into ctx: CGContext, pixelSize: CGFloat) {
    let s = pixelSize / 1024
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    // Apple's icon grid: an 824-unit body inside a 1024 canvas, the margin
    // left for the shadow so icons of different shapes line up in the Dock.
    let body = CGRect(x: 100, y: 108, width: 824, height: 824)
    let shape = superellipse(in: body)

    // Drop shadow. Cast from a solid fill of the shape, then covered by the
    // real body, so the blur never shows through the translucent parts.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18),
                  blur: 40,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: a dark slab, lighter at the top the way a lit object is.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([RGB(0x3C4356).cg(), RGB(0x232838).cg(), RGB(0x11131C).cg()],
                 [0, 0.45, 1]),
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY),
        options: [])

    // A wash of colour bleeding up off the keys, so the body is not flat grey.
    ctx.saveGState()
    ctx.setBlendMode(.screen)
    ctx.drawRadialGradient(
        gradient([RGB(0x4C7DFF).cg(0.30), RGB(0x4C7DFF).cg(0)], [0, 1]),
        startCenter: CGPoint(x: body.midX, y: body.midY), startRadius: 0,
        endCenter: CGPoint(x: body.midX, y: body.midY), endRadius: 470,
        options: [])
    ctx.restoreGState()

    // Top edge highlight — the single cue that reads as "physical" at 32pt.
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    // MARK: keys

    // 5 x 3, the deck's real layout, centred in the body.
    let cols = 5, rows = 3
    let inset: CGFloat = 84
    let gap: CGFloat = 26
    let side = (body.width - inset * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)
    let gridW = side * CGFloat(cols) + gap * CGFloat(cols - 1)
    let gridH = side * CGFloat(rows) + gap * CGFloat(rows - 1)
    let originX = body.midX - gridW / 2
    let originY = body.midY - gridH / 2

    for row in 0..<rows {
        for col in 0..<cols {
            // Diagonal sweep: mostly left-to-right, tilted by the row, which
            // is what stops the deck reading as three separate stripes.
            let t = (CGFloat(col) / CGFloat(cols - 1)) * 0.78
                  + (CGFloat(rows - 1 - row) / CGFloat(rows - 1)) * 0.22
            let colour = sampleRamp(t)

            // Rows are drawn top-down; y counts up.
            let x = originX + CGFloat(col) * (side + gap)
            let y = originY + CGFloat(rows - 1 - row) * (side + gap)
            let rect = CGRect(x: x, y: y, width: side, height: side)
            let key = superellipse(in: rect, n: 4.2)

            // Glow first, from a solid fill that the key itself then covers.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 40, color: colour.cg(0.55))
            ctx.addPath(key)
            ctx.setFillColor(colour.cg())
            ctx.fillPath()
            ctx.restoreGState()

            // Face: brighter at the top, so each key has its own light.
            ctx.saveGState()
            ctx.addPath(key)
            ctx.clip()
            ctx.drawLinearGradient(
                gradient([colour.lightened(0.34).cg(), colour.cg(), colour.darkened(0.28).cg()],
                         [0, 0.42, 1]),
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: [])

            // Gloss across the top half.
            ctx.drawLinearGradient(
                gradient([CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30),
                          CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)], [0, 1]),
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.midY - side * 0.05),
                options: [])

            ctx.addPath(key)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30))
            ctx.setLineWidth(4)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    ctx.restoreGState()
}

// MARK: - Output

func render(_ pixels: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawIcon(into: ctx, pixelSize: CGFloat(pixels))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_icon", code: 1)
    }
    try data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The slices `iconutil` expects; anything missing makes it refuse the folder.
let slices: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in slices {
    try writePNG(render(pixels), to: iconset.appendingPathComponent("\(name).png"))
}

// A standalone preview, handy for a README or a quick look. 512 rather than
// 1024: it is only ever looked at, and the .icns already carries the big one.
try writePNG(render(512), to: root.appendingPathComponent("Resources/AppIcon.png"))

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

// The .iconset folder is only an intermediate; the .icns is the artefact.
try? FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
