import Foundation

/// Wire format for the fifine D6 (USB 3142:0007).
///
/// Recovered by interposing `IOHIDDeviceSetReport` on the vendor's own macOS
/// app. Every packet is exactly 512 bytes, sent as an Output report with
/// report id 0:
///
///     "CRT\0\0" + <command> + params at fixed offsets, zero padded
///
/// The deck ignores image writes until it has been handshaken (see
/// `D6Device.connect`). Skipping that makes its firmware stall the USB OUT
/// endpoint - the first write appears to succeed, every later one times out,
/// and only a physical replug clears it.
enum D6Protocol {
    static let packetSize = 512
    static let header: [UInt8] = Array("CRT\0\0".utf8)

    /// A zero-padded command frame.
    static func frame(_ command: String) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: packetSize)
        buf.replaceSubrange(0..<header.count, with: header)
        let cmd = Array(command.utf8)
        buf.replaceSubrange(header.count..<(header.count + cmd.count), with: cmd)
        return buf
    }

    /// Reset / disconnect.
    static func disconnect() -> [UInt8] { frame("DIS") }

    /// Commit pending key images to the display.
    static func commit() -> [UInt8] { frame("STP") }

    /// Backlight brightness, 0...100.
    static func brightness(_ level: Int) -> [UInt8] {
        var f = frame("LIG")
        f[10] = UInt8(max(0, min(100, level)))
        return f
    }

    /// Clear one hardware key, or every key with `key: 0xFF`.
    static func clear(key: UInt8 = 0xFF) -> [UInt8] {
        var f = frame("CLE")
        f[11] = key
        return f
    }

    /// Query issued during the vendor app's opening handshake.
    static func query() -> [UInt8] {
        var f = frame("QUCMD")
        f.replaceSubrange(10..<16, with: [0x1F, 0x11, 0x00, 0x11, 0x00, 0x11])
        return f
    }

    /// Header announcing a key image: JPEG byte count then hardware key index.
    /// The JPEG itself follows as raw 512-byte chunks.
    static func imageHeader(byteCount: Int, key: UInt8) -> [UInt8] {
        var f = frame("BAT")
        f[10] = UInt8((byteCount >> 8) & 0xFF)
        f[11] = UInt8(byteCount & 0xFF)
        f[12] = key
        return f
    }

    /// Split a JPEG into zero-padded 512-byte payload frames.
    static func imageChunks(_ jpeg: Data) -> [[UInt8]] {
        var chunks: [[UInt8]] = []
        var offset = 0
        while offset < jpeg.count {
            let end = min(offset + packetSize, jpeg.count)
            var chunk = [UInt8](repeating: 0, count: packetSize)
            chunk.replaceSubrange(0..<(end - offset), with: jpeg[offset..<end])
            chunks.append(chunk)
            offset = end
        }
        return chunks
    }
}

/// Physical layout of the deck: 3 rows of 5.
enum DeckLayout {
    static let columns = 5
    static let rows = 3
    static let keyCount = columns * rows
    static let keyPixels = 100

    /// Images are addressed by hardware index, which runs bottom-up: hardware
    /// key 1 is the BOTTOM-left key, while our grid counts from the top-left.
    /// Verified on real hardware.
    static func hardwareKey(forGridIndex index: Int) -> UInt8 {
        let row = index / columns          // 0 = top row
        let column = index % columns
        let flippedRow = (rows - 1) - row  // hardware counts rows from the bottom
        return UInt8(flippedRow * columns + column + 1)
    }

    /// Grid index for a pressed key.
    ///
    /// NOT the inverse of `hardwareKey(forGridIndex:)`, deliberately. The deck
    /// reports presses in plain reading order (1 = top-left), while key
    /// *images* are addressed bottom-up. Applying the image flip here as well
    /// double-maps and swaps rows 1-5 with 11-15, so the bottom-left key fires
    /// the top-left key's action. Input is therefore identity.
    static func gridIndex(forHardwareKey key: Int) -> Int? {
        guard key >= 1, key <= keyCount else { return nil }
        return key - 1
    }
}
