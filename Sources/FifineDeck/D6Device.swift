import Foundation
import IOKit
import IOKit.hid

/// Talks to the deck over IOKit HID.
///
/// macOS-only by necessity: `IOHIDManager` has no iOS equivalent, and iOS
/// exposes no public API for arbitrary USB HID devices.
final class D6Device {
    static let vendorID = 0x3142
    static let productID = 0x0007

    private var device: IOHIDDevice?

    /// Where IOKit writes incoming reports.
    ///
    /// Manually allocated, and NOT a Swift Array, because IOKit keeps this
    /// pointer and writes through it for as long as the callback is
    /// registered. Handing it `withUnsafeMutableBufferPointer`'s pointer —
    /// which is only valid for the duration of that call — let the runtime
    /// move the array out from under the driver, and key presses stopped
    /// arriving at some unpredictable point after the app had been running a
    /// while.
    private let inputBufferSize = 512
    private lazy var inputBuffer: UnsafeMutablePointer<UInt8> = {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
        buffer.initialize(repeating: 0, count: inputBufferSize)
        return buffer
    }()

    private var runLoop: CFRunLoop?
    private let ioQueue = DispatchQueue(label: "fifine.d6.io")

    /// Fires on the main queue with the grid index of a pressed key.
    var onKeyDown: ((Int) -> Void)?

    /// Fires on the main queue when the deck stops (or resumes) accepting
    /// writes. `false` means it needs a physical replug.
    var onHealthChange: ((Bool) -> Void)?

    private var consecutiveFailures = 0
    private(set) var healthy = true

    private(set) var firmware: String = ""
    var isOpen: Bool { device != nil }

    deinit {
        inputBuffer.deallocate()
    }

    // MARK: - Discovery

    /// Finds the first attached D6. Returns nil when none is present.
    private static func findDevice() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        // The deck publishes two usage collections on one interface; either works.
        return set.first
    }

    // MARK: - Lifecycle

    /// Opens the deck and performs the handshake it requires before it will
    /// accept anything. Returns false when no deck is attached.
    @discardableResult
    func connect() -> Bool {
        guard let dev = Self.findDevice() else { return false }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return false
        }
        device = dev
        consecutiveFailures = 0
        healthy = true
        firmware = readFirmware()
        startReading()
        handshake()
        return true
    }

    func disconnect() {
        guard let dev = device else { return }
        _ = send(D6Protocol.disconnect())
        // Deliberately NOT unregistering the input callback here. Passing a
        // null callback is the documented way to do it, but the buffer now
        // outlives the device by design and re-registering on the next
        // connect() replaces it — so the unregister buys nothing and is one
        // more thing that can go wrong on a path that has to keep working.
        if let rl = runLoop {
            IOHIDDeviceUnscheduleFromRunLoop(dev, rl, CFRunLoopMode.defaultMode.rawValue)
            CFRunLoopStop(rl)
            runLoop = nil
        }
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
    }

    /// The opening sequence the vendor app performs. Not optional: without it
    /// the deck stalls its OUT endpoint on the first image write.
    private func handshake() {
        _ = send(D6Protocol.disconnect())
        _ = send(D6Protocol.brightness(60))
        _ = send(D6Protocol.query())
        _ = send(D6Protocol.brightness(60))
        _ = send(D6Protocol.clear())
    }

    // MARK: - Output

    @discardableResult
    private func send(_ bytes: [UInt8]) -> Bool {
        guard let dev = device else { return false }
        let ok = bytes.withUnsafeBufferPointer { ptr in
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, ptr.baseAddress!, ptr.count)
                == kIOReturnSuccess
        }
        noteWriteResult(ok)
        return ok
    }

    /// Tracks whether the deck is still accepting writes.
    ///
    /// A stalled OUT endpoint is the D6's failure mode: writes start timing out
    /// (0xE00002D6) and never recover until the deck is physically replugged.
    /// The device stays enumerable and readable throughout, so "is it open?" is
    /// not a useful health check - only write outcomes are.
    private func noteWriteResult(_ ok: Bool) {
        if ok {
            if consecutiveFailures > 0 {
                consecutiveFailures = 0
                if !healthy {
                    healthy = true
                    DispatchQueue.main.async { self.onHealthChange?(true) }
                }
            }
            return
        }
        consecutiveFailures += 1
        // One timeout can be a hiccup; a run of them means the endpoint is gone.
        if consecutiveFailures >= 3, healthy {
            healthy = false
            DispatchQueue.main.async { self.onHealthChange?(false) }
        }
    }

    func setBrightness(_ level: Int) {
        ioQueue.async { _ = self.send(D6Protocol.brightness(level)) }
    }

    func clearAll() {
        ioQueue.async {
            _ = self.send(D6Protocol.clear())
            _ = self.send(D6Protocol.commit())
        }
    }

    /// Sends one key image: header, the JPEG in 512-byte chunks, then commit.
    func setKeyImage(_ jpeg: Data, gridIndex: Int) {
        let key = DeckLayout.hardwareKey(forGridIndex: gridIndex)
        ioQueue.async {
            guard jpeg.count <= 0xFFFF else { return }   // length field is 16-bit
            _ = self.send(D6Protocol.imageHeader(byteCount: jpeg.count, key: key))
            for chunk in D6Protocol.imageChunks(jpeg) { _ = self.send(chunk) }
            _ = self.send(D6Protocol.commit())
        }
    }

    /// Idle time left on the bus after each batch, per key written.
    ///
    /// NOT a politeness: writing flat out permanently kills the deck's ability
    /// to report key presses. Measured on hardware — 87 presses registered
    /// during 40 s of quiet, then **zero** during 40 s of saturated image
    /// writing, and it never recovered when the writing stopped. Only a
    /// replug brought input back.
    ///
    /// So the deck must be left idle between batches. This is the single
    /// setting that decides whether animation costs you your keys.
    static let pacingPerKey: TimeInterval = 0.05

    /// Pushes a batch of keys in one pass, committing once at the end.
    ///
    /// A full 15-key repaint costs roughly half a second, so animation depends
    /// on callers sending only the keys that actually changed. `completion`
    /// runs on the main queue and exists so callers can apply backpressure
    /// rather than queueing frames faster than USB drains them.
    func setAllKeyImages(_ jpegs: [Int: Data], completion: (() -> Void)? = nil) {
        ioQueue.async {
            for (index, jpeg) in jpegs.sorted(by: { $0.key < $1.key }) {
                guard jpeg.count <= 0xFFFF else { continue }
                let key = DeckLayout.hardwareKey(forGridIndex: index)
                _ = self.send(D6Protocol.imageHeader(byteCount: jpeg.count, key: key))
                for chunk in D6Protocol.imageChunks(jpeg) { _ = self.send(chunk) }
            }
            _ = self.send(D6Protocol.commit())
            // Hold the queue, not the caller: the next batch cannot start
            // until the deck has had this long with nothing to do.
            if !jpegs.isEmpty {
                Thread.sleep(forTimeInterval: Double(jpegs.count) * Self.pacingPerKey)
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    // MARK: - Input

    private func readFirmware() -> String {
        guard let dev = device else { return "" }
        var buffer = [UInt8](repeating: 0, count: 32)
        var length = buffer.count
        let result = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 0, &buffer, &length)
        guard result == kIOReturnSuccess, length > 0 else { return "" }
        let bytes = buffer.prefix(length).filter { $0 >= 32 && $0 < 127 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Schedules the device on a background run loop and reports key presses.
    ///
    /// The input layout IS confirmed on a D6 (firmware V2.D6.00.002). Pressing
    /// hardware key 5 produces two 512-byte reports:
    ///
    ///     41 43 4b 00 00 4f 4b 00 00 05 01 ...   "ACK".."OK", key 5, down
    ///     41 43 4b 00 00 4f 4b 00 00 05 00 ...   "ACK".."OK", key 5, up
    ///
    /// so: "ACK" prefix, hardware key at byte 9, state at byte 10.
    ///
    /// The deck sends nothing at all until it has been handshaken, and it can
    /// also stop sending after a long run — the same stall that afflicts the
    /// OUT endpoint. Neither is recoverable from software: only a replug or a
    /// reset brings input back.
    private func startReading() {
        guard let dev = device else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            dev, inputBuffer, inputBufferSize,
            { context, _, _, _, _, report, reportLength in
                guard let context else { return }
                let me = Unmanaged<D6Device>.fromOpaque(context).takeUnretainedValue()
                me.handleInput(report: report, length: reportLength)
            },
            context)
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            guard let rl = CFRunLoopGetCurrent() else { return }
            self.runLoop = rl
            IOHIDDeviceScheduleWithRunLoop(dev, rl, CFRunLoopMode.defaultMode.rawValue)
            CFRunLoopRun()
        }
    }

    private func handleInput(report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let bytes = UnsafeBufferPointer(start: report, count: max(0, Int(length)))
        // A report that matches nothing is logged rather than dropped: a deck
        // that has silently stopped talking, and one whose packets we fail to
        // parse, look identical from the outside otherwise.
        let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        guard length >= 11 else {
            DeckLog.write(String(format: "fifine: short input report (%d bytes): %@", Int(length), hex))
            return
        }
        guard bytes[0] == 0x41, bytes[1] == 0x43, bytes[2] == 0x4B else {  // "ACK"
            DeckLog.write(String(format: "fifine: unrecognised input report: %@", hex))
            return
        }
        let hardwareKey = Int(bytes[9])
        let state = bytes[10]
        // State 0 is the key-up half of every press; it is not an anomaly and
        // must not be logged as one.
        guard state == 0x01 else { return }
        guard let index = DeckLayout.gridIndex(forHardwareKey: hardwareKey) else {
            DeckLog.write(String(format: "fifine: press for unknown hardware key %d: %@", hardwareKey, hex))
            return
        }
        DeckLog.write(String(format: "fifine: key down hw=%d -> grid index %d", hardwareKey, index))
        DispatchQueue.main.async { self.onKeyDown?(index) }
    }
}
