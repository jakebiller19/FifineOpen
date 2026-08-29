import AppKit
import Foundation

/// Key artwork and deck backgrounds from a text prompt, through fal.ai's
/// Ideogram v4 "instant" model.
///
/// The point is the turnaround: inference is about a third of a second, so
/// asking for a key icon and seeing it land on the hardware is one gesture
/// rather than a trip to a browser and a file picker.
///
/// Needs `FAL_KEY` — the environment, `widgets.json`, or a `.env`, like every
/// other credential here.
enum ImageGen {
    /// fal's SYNCHRONOUS endpoint, not the queue.
    ///
    /// The queue exists for jobs worth polling for. This model finishes in
    /// under a second, so a submit-then-poll cycle would spend more time in
    /// round trips than in inference.
    static let endpoint = URL(string: "https://fal.run/ideogram/v4/instant")!

    /// A generation is a paid API call and the model is not instant on a cold
    /// start, so the request is given room rather than failing at the default.
    static let timeout: TimeInterval = 120

    // MARK: - What the picture is for

    /// Not a stylistic preference. A key is 100x100 and a metre from your
    /// eyes: a photograph cut down to that is mud, and the difference between
    /// a usable key and a smudge is entirely in these words.
    enum Style: String, CaseIterable, Identifiable {
        case icon = "Icon"
        case logo = "Logo"
        case art  = "Art"

        var id: String { rawValue }

        var help: String {
            switch self {
            case .icon: return "One bold symbol on a flat background, framed for you — what reads at key size."
            case .logo: return "Lettering, drawn large enough to survive a 100 px key. Framed for you."
            case .art:  return "A free picture. Best across the whole deck, or on a 2×2 widget-sized block."
            }
        }

        /// Whether the result is re-framed after it arrives.
        ///
        /// Asking for a margin in the prompt helps and does not guarantee:
        /// the model composes to fill the frame, so subjects come back
        /// touching the edges or pushed to one side however politely you ask.
        /// Art is exempt because filling the frame is the point of it.
        var framesSubject: Bool { self != .art }

        /// Appended to what was typed. Ideogram follows plain description, so
        /// this is the entire art direction.
        var direction: String {
            switch self {
            case .icon:
                return "flat vector icon, one centred subject, bold simple shapes, "
                     + "thick strokes, high contrast, solid dark background, "
                     + "entire subject inside the frame with generous even margin "
                     + "on all four sides, not cropped, not bleeding off the edge, "
                     + "no text, no lettering, no watermark, no border"
            case .logo:
                return "bold logo, large legible lettering, centred, flat colour, "
                     + "high contrast, solid background, "
                     + "whole logo inside the frame with even margin, not cropped, "
                     + "no watermark"
            case .art:
                return "rich detailed illustration, strong focal point, high contrast, "
                     + "no text, no watermark"
            }
        }
    }

    /// Where the picture is going, which decides its shape.
    enum Shape {
        /// One key. Square, because the deck crops a key image square.
        case key
        /// All fifteen. 5:3, the aspect of the 500x300 canvas `DeckCanvas`
        /// slices — asking for the right shape beats cropping a wrong one.
        case deck

        var imageSize: Any {
            switch self {
            case .key:  return "square"                          // 512 x 512
            case .deck: return ["width": 1280, "height": 768]    // exactly 5:3
            }
        }

        /// PNG for a key: flat colour with hard edges is what JPEG is worst
        /// at, and the file is small at 512. JPEG for the deck, where the
        /// picture is photographic and four times the area.
        var format: String { self == .key ? "png" : "jpeg" }
    }

    // MARK: - The request

    /// Pure, so the shaping can be tested without spending a call.
    static func requestBody(prompt: String, style: Style, shape: Shape) -> [String: Any] {
        let typed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "prompt": "\(typed), \(style.direction)",
            // Ideogram's prompt expansion rewrites what you typed, which is
            // the opposite of what a key icon wants — and measured against
            // this endpoint it cost 46 s on a cold model against 0.3 s of
            // actual inference, so "instant" stopped being instant. The
            // direction above does the same job locally and for free.
            "expansion_model": "None",
            "image_size": shape.imageSize,
            "num_images": 1,
            "enable_safety_checker": true,
            "output_format": shape.format,
        ]
    }

    /// Generates one image and returns the file it was written to.
    static func generate(prompt: String, style: Style, shape: Shape) async throws -> URL {
        let key = WidgetCredentials.value(.fal)
        guard !key.isEmpty else {
            throw WidgetError.message("no FAL_KEY — add one to .env or the widget editor")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WidgetError.message("type what you want first")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(prompt: prompt, style: style, shape: shape))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WidgetError.message(describe(status: http.statusCode, body: data))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WidgetError.message("fal.ai sent something that was not JSON")
        }
        // The checker runs server-side and reports rather than refuses, so
        // acting on the flag is this end's job.
        if let flags = json["has_nsfw_concepts"] as? [Bool], flags.first == true {
            throw WidgetError.message("that image was flagged — try a different prompt")
        }
        guard let images = json["images"] as? [[String: Any]],
              let link = images.first?["url"] as? String,
              let remote = URL(string: link)
        else { throw WidgetError.message("no image in the response") }

        var (bytes, _) = try await URLSession.shared.data(from: remote)
        // Checked before it is written: a key pointing at a file that is not
        // an image draws nothing, and "nothing" is indistinguishable from a
        // key that was never set.
        guard NSImage(data: bytes) != nil else {
            throw WidgetError.message("what came back was not a readable image")
        }
        // Framing is deterministic, and deliberately not left to the prompt.
        // Only for a key: it is the 100 px square that makes an off-centre
        // subject unreadable, and `.deck` is a picture you want edge to edge.
        if style.framesSubject, shape == .key, let framed = framed(bytes) {
            bytes = framed
        }
        return try write(bytes, prompt: prompt, format: shape.format)
    }

    // MARK: - Framing

    /// Empty space left around the subject, as a fraction of the square.
    static let framingMargin: CGFloat = 0.09

    /// How far a pixel must sit from the background colour to count as
    /// subject. Loose enough to ignore JPEG ringing, tight enough to catch a
    /// dark subject on a dark ground.
    static let framingTolerance = 30

    /// A subject already this close to edge-to-edge is left alone: with no
    /// margin anywhere there is nothing to measure the centring against, and
    /// shrinking it would be a guess.
    static let framingFullBleed = 0.98

    /// Re-frames a generated image: finds the subject, centres it, and leaves
    /// an even margin around it on the background's own colour.
    ///
    /// This exists because prompting for it does not work reliably. The model
    /// composes to fill its frame, so an icon comes back touching an edge or
    /// pushed to one side however explicitly the prompt asks otherwise — and
    /// on a 100 px key that is the difference between a symbol and a smudge.
    /// Doing it here is deterministic: the result is centred whatever came
    /// back.
    ///
    /// Returns nil, meaning "keep the original", whenever it cannot improve
    /// on what it was given.
    static func framed(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width, height = image.height
        guard width > 8, height > 8 else { return nil }

        // Allocated rather than a Swift array handed to CGContext: the
        // context keeps the pointer, and an array's buffer is only guaranteed
        // for the duration of the call that lends it out.
        let count = width * height * 4
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { pixels.deallocate() }
        pixels.initialize(repeating: 0, count: count)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let background = borderColour(pixels, width: width, height: height)
        guard let box = subjectBox(pixels, width: width, height: height,
                                   background: background)
        else { return nil }                       // nothing but background

        let full = Double(box.width) >= Double(width) * framingFullBleed
            && Double(box.height) >= Double(height) * framingFullBleed
        if full { return nil }

        // Row 0 of the buffer is the top row, which is also how `cropping`
        // reads its rectangle — so the box needs no flipping.
        guard let subject = image.cropping(to: CGRect(x: box.minX, y: box.minY,
                                                      width: box.width, height: box.height))
        else { return nil }

        let side = max(width, height)
        guard let out = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        out.interpolationQuality = .high
        out.setFillColor(red: CGFloat(background.0) / 255, green: CGFloat(background.1) / 255,
                         blue: CGFloat(background.2) / 255, alpha: 1)
        out.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let inner = CGFloat(side) * (1 - 2 * framingMargin)
        let scale = min(inner / CGFloat(box.width), inner / CGFloat(box.height))
        let drawWidth = CGFloat(box.width) * scale, drawHeight = CGFloat(box.height) * scale
        out.draw(subject, in: CGRect(x: (CGFloat(side) - drawWidth) / 2,
                                     y: (CGFloat(side) - drawHeight) / 2,
                                     width: drawWidth, height: drawHeight))

        guard let result = out.makeImage() else { return nil }
        let png = NSBitmapImageRep(cgImage: result)
        return png.representation(using: .png, properties: [:])
    }

    /// The background colour, taken as the commonest colour around the
    /// border. A mean would be dragged off by a subject that touches an edge;
    /// the mode is not.
    private static func borderColour(_ pixels: UnsafeMutablePointer<UInt8>,
                                     width: Int, height: Int) -> (Int, Int, Int) {
        var counts: [Int: Int] = [:]
        var sums: [Int: (Int, Int, Int)] = [:]
        func sample(_ x: Int, _ y: Int) {
            let i = (y * width + x) * 4
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            // Quantised to 4 bits a channel so near-identical pixels land in
            // one bucket; the exact colour comes from averaging the bucket.
            let bucket = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            counts[bucket, default: 0] += 1
            let running = sums[bucket] ?? (0, 0, 0)
            sums[bucket] = (running.0 + r, running.1 + g, running.2 + b)
        }
        for x in 0..<width { sample(x, 0); sample(x, height - 1) }
        for y in 0..<height { sample(0, y); sample(width - 1, y) }
        guard let (bucket, n) = counts.max(by: { $0.value < $1.value }),
              let total = sums[bucket], n > 0
        else { return (0, 0, 0) }
        return (total.0 / n, total.1 / n, total.2 / n)
    }

    private struct Box { var minX: Int; var minY: Int; var width: Int; var height: Int }

    private static func subjectBox(_ pixels: UnsafeMutablePointer<UInt8>,
                                   width: Int, height: Int,
                                   background: (Int, Int, Int)) -> Box? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                // A transparent pixel is background whatever colour it claims.
                if pixels[i + 3] < 128 { continue }
                let dr = abs(Int(pixels[i]) - background.0)
                let dg = abs(Int(pixels[i + 1]) - background.1)
                let db = abs(Int(pixels[i + 2]) - background.2)
                guard max(dr, max(dg, db)) > framingTolerance else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return Box(minX: minX, minY: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - Storage

    /// Beside the settings, NOT in a temp directory: `settings.json` stores
    /// the path, and artwork that evaporates on reboot would leave a key
    /// blank with nothing to explain why.
    static var directory: URL {
        let base = WidgetCredentials.directory
            .appendingPathComponent("Generated", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A readable name, so the folder can be browsed later and the file
    /// beside a key in the editor says what it is.
    ///
    /// Every character that is not a letter or a digit is dropped, which is
    /// also what keeps a prompt from steering the path: `../../…` slugs to
    /// nothing. The timestamp means asking twice keeps both answers rather
    /// than overwriting the one you preferred.
    static func filename(prompt: String, format: String, date: Date = Date()) -> String {
        var slug = ""
        var lastWasDash = true          // leading dashes are never wanted
        for character in prompt.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
            if slug.count >= 32 { break }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "image" }
        let stamp = Int(date.timeIntervalSince1970)
        return "\(slug)-\(stamp).\(format == "jpeg" ? "jpg" : format)"
    }

    private static func write(_ data: Data, prompt: String, format: String) throws -> URL {
        let url = directory.appendingPathComponent(filename(prompt: prompt, format: format))
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw WidgetError.message("could not save the image: \(error.localizedDescription)")
        }
        return url
    }

    // MARK: - Errors

    /// Turns an HTTP failure into something that names the fix.
    static func describe(status: Int, body: Data) -> String {
        let detail: String? = {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            if let text = json["detail"] as? String { return text }
            // 422 reports a list of field errors rather than a string.
            if let list = json["detail"] as? [[String: Any]] {
                return list.compactMap { $0["msg"] as? String }.first
            }
            return nil
        }()
        switch status {
        case 401, 403: return "fal.ai rejected the key — check FAL_KEY"
        case 402:      return "fal.ai says the account is out of credit"
        case 429:      return "rate limited — wait a moment"
        default:       return detail.map { "fal.ai: \($0)" } ?? "fal.ai returned HTTP \(status)"
        }
    }

    /// The text to put in front of the user for anything thrown here.
    static func message(for error: Error) -> String {
        if let widget = error as? WidgetError { return widget.text }
        if (error as? URLError)?.code == .timedOut { return "fal.ai timed out" }
        if error is URLError { return "no connection to fal.ai" }
        return error.localizedDescription
    }
}
