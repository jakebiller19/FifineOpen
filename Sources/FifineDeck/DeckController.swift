import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Everything one key holds. Persisted as JSON.
struct KeyConfig: Codable, Equatable {
    var colorHex: String = "#1E1E28"
    /// The far end of a background gradient. Nil is a flat colour, which is
    /// what every key written before this existed decodes as.
    var gradientHex: String? = nil
    /// `"linear"` or `"radial"`. A String rather than an enum on purpose: an
    /// unknown raw value in a hand-edited `settings.json` would throw out of
    /// the decoder and take the whole layout with it, where an unrecognised
    /// string here simply falls back to linear.
    var gradientStyle: String? = nil
    var imagePath: String? = nil
    var gifPath: String? = nil
    var label: String = ""
    var action: KeyAction = .none
    /// Set when this key ANCHORS a live widget. The keys the widget covers
    /// keep their own config here untouched, so shrinking a span hands them
    /// straight back.
    var widget: WidgetConfig? = nil

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        NSColor(hex: colorHex) ?? NSColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
    }

    /// The far end of the gradient, or nil when this key is a flat colour.
    /// An unreadable hex is treated as absent rather than as black.
    var gradientEnd: NSColor? { gradientHex.flatMap { NSColor(hex: $0) } }

    var hasGradient: Bool { gradientEnd != nil }

    var gradientIsRadial: Bool { gradientStyle == "radial" }

    /// How far a radial background spreads, as a fraction of the key.
    /// Shared by the deck's renderer and both on-screen previews so one
    /// number keeps all three looking the same.
    static let radialSpread: CGFloat = 0.62

    /// What to paint behind this key on screen — the same background the
    /// hardware is sent, so the grid is a preview rather than an
    /// approximation.
    var background: AnyShapeStyle {
        guard let end = gradientEnd else { return AnyShapeStyle(color) }
        let colors = [color, Color(nsColor: end)]
        if gradientIsRadial {
            // Elliptical rather than Radial: its radius is a FRACTION of the
            // view, so one description serves the 70 pt grid cell and the
            // 24 pt menu bar thumbnail without either being told its size.
            return AnyShapeStyle(EllipticalGradient(
                colors: colors, center: .center,
                startRadiusFraction: 0, endRadiusFraction: Self.radialSpread))
        }
        return AnyShapeStyle(LinearGradient(colors: colors,
                                            startPoint: .top, endPoint: .bottom))
    }

    var image: NSImage? {
        guard let imagePath else { return nil }
        return NSImage(contentsOfFile: imagePath)
    }
}

/// Persisted app state beyond the individual keys.
struct DeckSettings: Codable {
    var keys: [KeyConfig] = Array(repeating: KeyConfig(), count: DeckLayout.keyCount)
    var pattern: DeckPattern = .none
    var primaryHex: String = "#00E0FF"
    var secondaryHex: String = "#12002E"
    var wallpaperPath: String? = nil
    var brightness: Double = 100
    var smoothAnimation: Bool? = nil        // optional: absent in older files
}

/// Owns the deck connection, the key grid, and the animation clock.
///
/// Shared, because the window and the menu bar item are two views onto one
/// deck - a second instance would fight for the USB handle.
@MainActor
final class DeckController: ObservableObject {
    /// The app's instance, and the only one that watches the bus for the
    /// deck being plugged in.
    static let shared = DeckController(watchesForHotplug: true)

    @Published var keys: [KeyConfig] = Array(repeating: KeyConfig(), count: DeckLayout.keyCount)
    @Published var selected: Int = 0
    @Published var connected: Bool = false
    @Published var firmware: String = ""
    @Published var status: String = "Not connected"
    @Published var lastPressed: Int? = nil

    @Published var pattern: DeckPattern = .none { didSet { patternChanged() } }
    @Published var primary: Color = Color(nsColor: NSColor(hex: "#00E0FF")!) { didSet { renderPattern() } }
    @Published var secondary: Color = Color(nsColor: NSColor(hex: "#12002E")!) { didSet { renderPattern() } }
    @Published var wallpaperPath: String? = nil
    /// Persisted like everything else in `DeckSettings` — it was the one
    /// field with nowhere calling `save()`, so a brightness change survived
    /// only if some unrelated edit happened to write the file afterwards.
    /// `save()` coalesces, which is what makes it safe to call from a slider.
    @Published var brightness: Double = 100 {
        didSet {
            device.setBrightness(Int(brightness))
            save()
        }
    }

    /// Trades key presses for smoother GIFs. Off by default, and the UI says
    /// what it costs.
    @Published var smoothAnimation: Bool = false {
        didSet { animationRateChanged(); save() }
    }

    /// Live measured refresh rate, so the UI can be honest about throughput.
    @Published var framesPerSecond: Double = 0

    private let device = D6Device()

    // MARK: Live widgets

    private let widgets = WidgetRuntime()
    /// Which key each widget paints. Rebuilt whenever the key grid changes.
    private(set) var widgetCells: [Int: WidgetCell] = [:]
    /// Grid index -> the JPEG a widget last painted for it. Applied over every
    /// payload, so neither a deck pattern nor a GIF can overpaint a widget.
    private var widgetTiles: [Int: Data] = [:]
    /// The same tiles the right way up, for the on-screen grid.
    @Published private(set) var widgetPreviews: [Int: NSImage] = [:]
    private var widgetNextDue: [Int: Date] = [:]        // anchor -> next fetch
    private var widgetFetching: Set<Int> = []           // anchors with a fetch in flight
    private var widgetPainted: [Int: String] = [:]      // anchor -> signature on the keys
    /// Separate from the 15 fps animation clock: a widget refresh makes
    /// network calls, and a stalled request must not stall the animation.
    private var widgetTimer: Timer?

    /// Loaded GIFs by grid index, and where each one is in its loop.
    private var gifs: [Int: GifAnimation] = [:]
    private var gifFrame: [Int: Int] = [:]
    private var gifNextDue: [Int: Double] = [:]

    /// Last JPEG actually sent per key - the diff that makes animation viable.
    private var lastSent: [Int: Data] = [:]

    /// Decoded overlay icons, keyed by grid index.
    private var overlayCache: [Int: NSImage] = [:]

    private var timer: Timer?
    private var startedAt = Date()
    private var frameInFlight = false
    private var lastFrameAt = Date()

    /// Where this controller reads and writes its settings.
    ///
    /// Injectable, and NOT optional-with-a-static-default by accident: a test
    /// that constructs a controller writes a real file the moment it edits a
    /// key, and the first version of these tests silently overwrote the
    /// author's own deck layout. Anything that builds a DeckController outside
    /// the app must name its own file.
    private let storeURL: URL

    static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FifineDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }

    /// True when the deck is open but has stopped accepting writes.
    @Published var stalled: Bool = false

    /// True while a plug-in has been seen and the connect attempt it schedules
    /// has not run yet.
    private var reconnectPending = false

    /// Off by default so a test never opens a HID manager: only the shared
    /// instance the app runs on watches the bus.
    init(storeURL: URL? = nil, watchesForHotplug: Bool = false) {
        self.storeURL = storeURL ?? Self.defaultStoreURL
        load()
        device.onKeyDown = { [weak self] index in
            Task { @MainActor in self?.handleKeyPress(index) }
        }
        device.onHealthChange = { [weak self] healthy in
            Task { @MainActor in self?.healthChanged(healthy) }
        }
        device.onDeviceAttached = { [weak self] in
            Task { @MainActor in self?.deviceAttached() }
        }
        device.onDeviceRemoved = { [weak self] in
            Task { @MainActor in self?.deviceRemoved() }
        }
        if watchesForHotplug { device.startWatching() }
    }

    // MARK: - Hotplug

    /// A deck appeared. Both callbacks can arrive twice for one deck, so this
    /// has to be idempotent.
    private func deviceAttached() {
        guard !connected, !reconnectPending else { return }
        reconnectPending = true
        status = "Deck detected — connecting…"
        // Not immediately: the deck has only just enumerated, and the
        // handshake is the one sequence that must not be sent to a device
        // that is not ready for it. One delayed attempt also absorbs the
        // duplicate callback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconnectPending = false
                guard !self.connected else { return }
                self.connect()
            }
        }
    }

    /// The deck was unplugged. The device handle is already gone by the time
    /// this runs — `D6Device` drops it without writing — so this only has to
    /// bring the app's own state down with it.
    private func deviceRemoved() {
        guard connected || stalled else { return }
        stopClock()
        stopWidgetClock()
        connected = false
        stalled = false
        lastSent.removeAll()
        status = "Deck unplugged. It connects itself when you plug it back in."
    }

    private func healthChanged(_ healthy: Bool) {
        stalled = !healthy
        if healthy {
            status = "Connected — firmware \(firmware)"
        } else {
            // The deck stays enumerable and readable while its OUT endpoint is
            // stalled, so "connected" would be actively misleading here.
            stopClock()
            status = "Deck stopped responding — unplug it and plug it back in"
        }
    }

    // MARK: - Connection

    func connect() {
        // Always tear down first: reconnecting over a live handle leaves the
        // old reader thread running against a dead device.
        device.disconnect()
        lastSent.removeAll()
        stalled = false
        if device.connect() {
            connected = true
            firmware = device.firmware
            status = "Connected — firmware \(firmware)"
            device.setBrightness(Int(brightness))
            lastSent.removeAll()
            // Fetch every widget at once rather than waiting out an interval
            // that started before the deck was even plugged in.
            widgetNextDue.removeAll()
            widgetPainted.removeAll()
            patternChanged()
            widgetsChanged()
        } else {
            connected = false
            status = "No deck found. Plug in the fifine D6 — it connects itself."
        }
    }

    func disconnect() {
        stopClock()
        stopWidgetClock()
        device.disconnect()
        connected = false
        status = "Disconnected"
    }

    // MARK: - Rendering

    /// Re-sends everything from scratch (ignores the diff cache).
    func pushAll() {
        lastSent.removeAll()
        patternChanged()
    }

    private func patternChanged() {
        guard connected else { return }
        if pattern.isAnimated || !gifs.isEmpty {
            startClock()
        } else {
            stopClock()
        }
        renderPattern()
        save()
    }

    /// Paints the current still frame: a pattern canvas, or the per-key config.
    private func renderPattern() {
        guard connected, !pattern.isAnimated else { return }

        if pattern == .none {
            var payload: [Int: Data] = [:]
            for (index, cfg) in keys.enumerated() {
                if gifs[index] != nil { continue }        // the clock drives GIF keys
                if let jpeg = KeyImage.jpeg(for: cfg) {
                    payload[index] = jpeg
                }
            }
            applyWidgets(to: &payload)
            sendDiff(payload)
            return
        }

        let wallpaper = wallpaperPath.flatMap { NSImage(contentsOfFile: $0) }
        guard let canvas = pattern.canvas(primary: NSColor(primary),
                                          secondary: NSColor(secondary),
                                          image: wallpaper)
        else { return }
        var payload = DeckCanvas.keyJPEGs(from: canvas, overlays: overlays(), labels: labels())
        applyWidgets(to: &payload)
        sendDiff(payload)
    }

    /// Per-key labels, drawn over whatever the pattern paints. Labels survive
    /// a pattern precisely so a gradient deck can still be readable.
    private func labels() -> [Int: String] {
        var out: [Int: String] = [:]
        for (index, key) in keys.enumerated() where !key.label.isEmpty {
            out[index] = key.label
        }
        return out
    }

    /// Per-key icons composited over the pattern. Transparent PNGs let the
    /// gradient show through around the artwork.
    ///
    /// Cached because an animated pattern renders these up to 15x a second,
    /// and decoding a PNG per key per frame would dominate the frame budget.
    private func overlays() -> [Int: NSImage] {
        var out: [Int: NSImage] = [:]
        for (index, key) in keys.enumerated() {
            guard let path = key.imagePath else { continue }
            if let cached = overlayCache[index] {
                out[index] = cached
            } else if let image = NSImage(contentsOfFile: path) {
                overlayCache[index] = image
                out[index] = image
            }
        }
        return out
    }

    private func invalidateOverlay(_ index: Int) {
        overlayCache[index] = nil
    }

    /// Sends only the keys whose bytes changed since last time.
    private func sendDiff(_ payload: [Int: Data], completion: (() -> Void)? = nil) {
        var changed: [Int: Data] = [:]
        for (index, data) in payload where lastSent[index] != data {
            changed[index] = data
            lastSent[index] = data
        }
        guard !changed.isEmpty else { completion?(); return }
        device.setAllKeyImages(changed, completion: completion)
    }

    // MARK: - Clearing

    /// Where the pre-clear snapshot lives, beside the settings it came from.
    private var backupURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("settings-backup.json")
    }

    var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    /// Wipes every key back to default — colour, artwork, label, action and
    /// widget alike.
    ///
    /// Snapshots the current layout first. Fifteen keys of artwork and macros
    /// is an afternoon's work, and one button that destroys it without a way
    /// back is not a button worth shipping.
    func clearAllKeys() {
        writeBackup()
        keys = Array(repeating: KeyConfig(), count: DeckLayout.keyCount)
        gifs.removeAll(); gifFrame.removeAll(); gifNextDue.removeAll()
        overlayCache.removeAll()
        widgetTiles.removeAll(); widgetPreviews.removeAll()
        widgetPainted.removeAll(); widgetNextDue.removeAll()
        lastSent.removeAll()
        selected = 0
        save()
        widgetsChanged()
        status = "Cleared every key — Undo restores them"
    }

    /// Puts back whatever `clearAllKeys` (or the last restore) replaced.
    @discardableResult
    func restoreBackup() -> Bool {
        guard let data = try? Data(contentsOf: backupURL),
              let settings = try? JSONDecoder().decode(DeckSettings.self, from: data),
              settings.keys.count == DeckLayout.keyCount
        else { return false }
        // Swap rather than consume: undo has to be undoable too, or a restore
        // onto the wrong layout is its own one-way door.
        writeBackup()
        keys = settings.keys
        gifs.removeAll(); gifFrame.removeAll(); gifNextDue.removeAll()
        overlayCache.removeAll()
        for (index, key) in keys.enumerated() {
            if let path = key.gifPath, let animation = GifPlayer.load(path: path) {
                gifs[index] = animation
                gifFrame[index] = -1
                gifNextDue[index] = 0
            }
            if let widget = key.widget { keys[index].widget = widget.normalized }
        }
        pattern = settings.pattern
        if let c = NSColor(hex: settings.primaryHex) { primary = Color(nsColor: c) }
        if let c = NSColor(hex: settings.secondaryHex) { secondary = Color(nsColor: c) }
        wallpaperPath = settings.wallpaperPath
        lastSent.removeAll()
        save()
        widgetsChanged()
        status = "Restored the previous layout"
        return true
    }

    private func writeBackup() {
        let settings = DeckSettings(
            keys: keys, pattern: pattern,
            primaryHex: NSColor(primary).hexString,
            secondaryHex: NSColor(secondary).hexString,
            wallpaperPath: wallpaperPath, brightness: brightness)
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: backupURL, options: .atomic)
    }

    func clearDeck() {
        stopClock()
        pattern = .none
        lastSent.removeAll()
        device.clearAll()
    }

    // MARK: - Animation clock

    /// Frames per second the animation clock aims for.
    ///
    /// Four, not the fifteen the USB can carry, because the deck stops
    /// reporting key presses when its write endpoint is saturated — and does
    /// not recover without a replug (see `D6Device.pacingPerKey`). Smoothness
    /// is worth nothing if it costs you the buttons.
    static let safeAnimationFPS: Double = 4
    static let smoothAnimationFPS: Double = 12

    private func startClock() {
        guard timer == nil else { return }
        startedAt = Date()
        let fps = smoothAnimation ? Self.smoothAnimationFPS : Self.safeAnimationFPS
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Restarts the clock at the current rate, after the setting changes.
    private func animationRateChanged() {
        guard timer != nil else { return }
        stopClock()
        startClock()
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
        framesPerSecond = 0
    }

    private func tick() {
        guard connected, !frameInFlight else { return }        // drop, never queue
        let now = Date()
        let time = now.timeIntervalSince(startedAt)

        var payload: [Int: Data] = [:]

        if pattern.isAnimated {
            let colors = pattern.colors(time: time,
                                        primary: NSColor(primary),
                                        secondary: NSColor(secondary))
            payload = DeckCanvas.keyJPEGs(colors: colors, overlays: overlays(), labels: labels())
        }

        // GIF keys advance on their own per-frame delays.
        for (index, gif) in gifs {
            let due = gifNextDue[index] ?? 0
            guard time >= due else { continue }
            let frame = ((gifFrame[index] ?? -1) + 1) % gif.count
            gifFrame[index] = frame
            gifNextDue[index] = time + max(GifPlayer.minDelay, gif.delays[frame])
            payload[index] = gif.frames[frame]
        }

        // Last word, always: a widget owns the keys it covers, so neither an
        // animated pattern nor a GIF underneath it gets to paint them.
        applyWidgets(to: &payload)

        guard !payload.isEmpty else { return }

        frameInFlight = true
        sendDiff(payload) { [weak self] in
            guard let self else { return }
            self.frameInFlight = false
            let dt = Date().timeIntervalSince(self.lastFrameAt)
            if dt > 0 { self.framesPerSecond = 1.0 / dt }
            self.lastFrameAt = Date()
        }
    }

    // MARK: - Editing

    func setColor(_ color: Color, for index: Int) {
        guard keys.indices.contains(index) else { return }
        keys[index].colorHex = NSColor(color).hexString
        save()
        // A widget is coloured by its ANCHOR key, so recolouring the anchor
        // repaints the whole span; recolouring a covered key changes nothing
        // until the widget stops covering it.
        if let cell = widgetCells[index], cell.isAnchor {
            renderWidget(anchor: index)
        } else {
            pushKey(index)
        }
    }

    func setLabel(_ label: String, for index: Int) {
        guard keys.indices.contains(index) else { return }
        keys[index].label = label
        save()
        if pattern == .none {
            pushKey(index)
        } else {
            // Labels sit on top of patterns, so a static pattern has to be
            // repainted. Animated ones pick the new text up on the next tick.
            renderPattern()
        }
    }

    /// Turns a gradient on with a second colour, or off with nil.
    func setGradient(_ hex: String?, for index: Int) {
        guard keys.indices.contains(index) else { return }
        keys[index].gradientHex = hex
        keyBackgroundChanged(index)
    }

    func setGradientStyle(_ style: String, for index: Int) {
        guard keys.indices.contains(index) else { return }
        keys[index].gradientStyle = style
        keyBackgroundChanged(index)
    }

    /// A second colour that looks deliberate the moment the switch is
    /// flipped: away from the base colour, towards black unless the base is
    /// already dark, in which case there is nowhere to go but lighter.
    func suggestedGradientEnd(for index: Int) -> String {
        guard keys.indices.contains(index) else { return "#000000" }
        let base = keys[index].nsColor.usingColorSpace(.deviceRGB) ?? .black
        let towards: NSColor = base.brightnessComponent < 0.25 ? .white : .black
        let amount: CGFloat = base.brightnessComponent < 0.25 ? 0.38 : 0.68
        let blended = base.blended(withFraction: amount, of: towards) ?? base
        return blended.hexString
    }

    private func keyBackgroundChanged(_ index: Int) {
        save()
        // A widget takes its tint from its anchor key, so recolouring one
        // repaints the whole span - the same rule `setColor` follows.
        if let cell = widgetCells[index], cell.isAnchor {
            renderPattern()
        } else if pattern == .none {
            pushKey(index)
        } else {
            renderPattern()
        }
    }

    func setAction(_ action: KeyAction, for index: Int) {
        guard keys.indices.contains(index) else { return }
        keys[index].action = action
        save()
    }

    private func pushKey(_ index: Int) {
        guard connected, pattern == .none, gifs[index] == nil,
              widgetCells[index] == nil, keys.indices.contains(index) else { return }
        let cfg = keys[index]
        guard let jpeg = KeyImage.jpeg(for: cfg)
        else { return }
        sendDiff([index: jpeg])
    }

    func chooseImage(for index: Int) {
        guard let url = pickFile(types: [.png, .jpeg, .gif, .bmp, .tiff, .heic],
                                 message: "Choose an image for this key") else { return }
        setImage(url.path, for: index)
    }

    /// Where a key's artwork actually gets set — the file picker and the
    /// generator both land here, so a generated image is a key image in
    /// exactly the same sense as one you chose.
    func setImage(_ path: String, for index: Int) {
        guard keys.indices.contains(index) else { return }
        keys[index].imagePath = path
        keys[index].gifPath = nil
        gifs[index] = nil
        invalidateOverlay(index)
        save()
        if pattern == .none { pushKey(index) } else { renderPattern() }
    }

    /// Loads an animated GIF onto one key. Frames stream at up to 15 fps -
    /// the deck has no hardware GIF support.
    func chooseGIF(for index: Int) {
        guard let url = pickFile(types: [.gif], message: "Choose an animated GIF for this key")
        else { return }
        guard let animation = GifPlayer.load(path: url.path) else {
            status = "Could not read that GIF"
            return
        }
        gifs[index] = animation
        gifFrame[index] = -1
        gifNextDue[index] = 0
        keys[index].gifPath = url.path
        keys[index].imagePath = nil
        save()
        if connected { startClock() }
    }

    func clearImage(for index: Int) {
        guard keys.indices.contains(index) else { return }
        keys[index].imagePath = nil
        keys[index].gifPath = nil
        gifs[index] = nil
        gifFrame[index] = nil
        gifNextDue[index] = nil
        invalidateOverlay(index)
        if gifs.isEmpty && !pattern.isAnimated { stopClock() }
        save()
        if pattern == .none { pushKey(index) } else { renderPattern() }
    }

    func chooseWallpaper() {
        guard let url = pickFile(types: [.png, .jpeg, .bmp, .tiff, .heic],
                                 message: "Choose an image to spread across all 15 keys")
        else { return }
        setWallpaper(url.path)
    }

    func setWallpaper(_ path: String) {
        wallpaperPath = path
        // Selecting the picture is the whole intent; making the user then
        // find the pattern in a picker to see it would be a second step with
        // only one sensible answer.
        pattern = .wallpaper
        save(); pushAll()
    }

    func resetKey(_ index: Int) {
        guard keys.indices.contains(index) else { return }
        let hadWidget = keys[index].widget != nil
        keys[index] = KeyConfig()
        gifs[index] = nil
        invalidateOverlay(index)
        save()
        if hadWidget {
            widgetsChanged()          // hands every key it covered back
        } else if pattern == .none {
            pushKey(index)
        } else {
            renderPattern()
        }
    }

    func hasGIF(_ index: Int) -> Bool { gifs[index] != nil }

    private func pickFile(types: [UTType], message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Live widgets

    /// True if a widget paints this key (its own, or a neighbour's span).
    func isWidgetKey(_ index: Int) -> Bool { widgetCells[index] != nil }

    /// The upright tile for the on-screen grid, or nil if no widget covers
    /// this key. Painted from cached data, so the editor previews a widget
    /// with no deck plugged in.
    func widgetPreview(_ index: Int) -> NSImage? { widgetPreviews[index] }

    /// The widget covering this key, whichever key anchors it — what the
    /// editor shows when you select a covered key.
    func widgetCell(_ index: Int) -> WidgetCell? { widgetCells[index] }

    /// Swaps two keys' entire configuration — colour, artwork, label, action
    /// and any widget. What the grid's drag and drop does.
    ///
    /// A swap rather than an overwrite: dropping a key onto an occupied one
    /// has to put the displaced key somewhere, and anywhere other than the
    /// slot you just vacated is a surprise.
    func moveKey(from: Int, to: Int) {
        guard from != to, keys.indices.contains(from), keys.indices.contains(to)
        else { return }
        keys.swapAt(from, to)
        // The per-index caches are all keyed by grid position, so they have to
        // travel with the configuration or the new occupant inherits the old
        // one's animation and artwork.
        // Through locals: two subscripts of the same dictionary in one swap()
        // are overlapping exclusive accesses, which Swift rejects.
        let movedGif = gifs[from], movedFrame = gifFrame[from]
        let movedDue = gifNextDue[from], movedOverlay = overlayCache[from]
        gifs[from] = gifs[to];             gifs[to] = movedGif
        gifFrame[from] = gifFrame[to];     gifFrame[to] = movedFrame
        gifNextDue[from] = gifNextDue[to]; gifNextDue[to] = movedDue
        overlayCache[from] = overlayCache[to]; overlayCache[to] = movedOverlay
        selected = to
        save()
        widgetsChanged()
    }

    /// Resizes a widget by dragging: the span runs from its anchor to the key
    /// under the pointer. Clamped to the deck, so a drag off the edge simply
    /// stops growing.
    func resizeWidget(anchor: Int, columns: Int, rows: Int) {
        guard keys.indices.contains(anchor), var widget = keys[anchor].widget else { return }
        let anchorColumn = anchor % DeckLayout.columns
        let anchorRow = anchor / DeckLayout.columns
        let newColumns = min(max(columns, 1), DeckLayout.columns - anchorColumn)
        let newRows = min(max(rows, 1), DeckLayout.rows - anchorRow)
        guard newColumns != widget.columns || newRows != widget.rows else { return }
        widget.columns = newColumns
        widget.rows = newRows
        keys[anchor].widget = widget.normalized
        save()
        widgetsChanged()
    }

    func setWidget(_ widget: WidgetConfig?, for index: Int) {
        guard keys.indices.contains(index) else { return }
        keys[index].widget = widget?.normalized
        save()
        widgetsChanged()
    }

    /// Recomputes which key each widget paints, drops the state of widgets
    /// that no longer exist, and repaints everything.
    ///
    /// Deliberately heavy-handed: this runs on a config edit, never in the
    /// frame path, and the keys a widget just STOPPED covering have to go back
    /// to their own faces — which the diff cache would otherwise suppress,
    /// because as far as it knows those keys already show what they should.
    private func widgetsChanged() {
        widgetCells = WidgetLayout.cells(for: keys)
        let anchors = Set(widgetCells.values.map(\.anchor))
        widgetTiles = widgetTiles.filter { widgetCells[$0.key] != nil }
        widgetPreviews = widgetPreviews.filter { widgetCells[$0.key] != nil }
        widgetPainted = widgetPainted.filter { anchors.contains($0.key) }
        // Every widget refetches after an edit. Without this, changing the
        // symbols on a 30 s ticker left the old page on the keys for up to
        // half a minute; the providers' own rate limiting is what stops an
        // edit storm from turning into a request storm.
        widgetNextDue.removeAll()
        lastSent.removeAll()
        syncWidgetClock()
        renderWidgets()
        renderPattern()
        if widgetCells.isEmpty { widgets.forgetAll() }
    }

    /// Overlays the widget tiles onto a payload. Called last on every path
    /// that paints keys, so nothing can end up half a widget.
    private func applyWidgets(to payload: inout [Int: Data]) {
        for (index, jpeg) in widgetTiles { payload[index] = jpeg }
    }

    private func renderWidgets() {
        for (index, cell) in widgetCells where cell.isAnchor {
            renderWidget(anchor: index)
        }
    }

    /// Paints one widget as a single frame and cuts it into per-key tiles.
    ///
    /// One render for the whole span, not one per key: a 5x3 widget is 15
    /// keys, and rendering it fifteen times would cost fifteen times as much
    /// for exactly the same picture.
    private func renderWidget(anchor: Int) {
        guard let cell = widgetCells[anchor], cell.isAnchor,
              keys.indices.contains(anchor) else { return }
        let background = keys[anchor].nsColor
        let snapshot = widgets.snapshot(cell.config, cells: cell.cellCount)
        let signature = "\(snapshot.signature)|\(cell.columns)x\(cell.rows)|\(background.hexString)"
        // Same picture as last time: no repaint, no USB write. This is what
        // keeps an idle widget off the bus entirely.
        if widgetPainted[anchor] == signature, widgetTiles[anchor] != nil { return }

        guard let frame = widgets.frame(cell.config, snapshot: snapshot,
                                        columns: cell.columns, rows: cell.rows,
                                        background: background) else { return }
        var payload: [Int: Data] = [:]
        for (index, covered) in widgetCells where covered.anchor == anchor {
            guard let tile = WidgetRuntime.tile(frame, dx: covered.dx, dy: covered.dy)
            else { continue }
            widgetPreviews[index] = NSImage(cgImage: tile,
                                            size: NSSize(width: DeckLayout.keyPixels,
                                                         height: DeckLayout.keyPixels))
            if let jpeg = DeckCanvas.jpeg(from: tile) {
                widgetTiles[index] = jpeg
                payload[index] = jpeg
            }
        }
        widgetPainted[anchor] = signature
        if connected { sendDiff(payload) }
    }

    // MARK: Widget clock

    private func syncWidgetClock() {
        let wanted = connected && !widgetCells.isEmpty
        if wanted, widgetTimer == nil {
            // 0.5 s scheduler granularity, like the Linux app's: with no
            // widgets on the deck a tick is a single dictionary scan, and no
            // widget is ever polled faster than its own interval.
            widgetTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.widgetTick() }
            }
        } else if !wanted {
            stopWidgetClock()
        }
    }

    private func stopWidgetClock() {
        widgetTimer?.invalidate()
        widgetTimer = nil
    }

    /// Drops every cached fetch and repaints. Used when credentials change:
    /// the widgets were painting "no API key" and must not sit there for a
    /// whole interval once one exists.
    func refreshWidgetsNow() {
        widgets.forgetAll()
        widgetNextDue.removeAll()
        widgetPainted.removeAll()
        renderWidgets()
    }

    private func widgetTick() {
        guard connected else { return }
        let now = Date()
        for (anchor, cell) in widgetCells where cell.isAnchor {
            // Never two fetches for one widget: a slow request must not have a
            // queue of its successors piling up behind it.
            guard !widgetFetching.contains(anchor) else { continue }
            guard now >= (widgetNextDue[anchor] ?? .distantPast) else { continue }
            widgetFetching.insert(anchor)
            let config = cell.config
            let cells = cell.cellCount
            Task { [weak self] in
                guard let self else { return }
                await self.widgets.refresh(config, cells: cells)
                self.widgetFetching.remove(anchor)
                self.widgetNextDue[anchor] = Date().addingTimeInterval(config.interval)
                // The layout may have moved while we were on the network; the
                // guard inside renderWidget is what makes that safe.
                self.renderWidget(anchor: anchor)
            }
        }
    }

    // MARK: - Key presses (the harness)

    /// What a press on one key will do.
    ///
    /// Split out of `handleKeyPress` so it can be asserted on directly: the
    /// question "does a GIF key still run its action?" should be answerable
    /// without a deck plugged in.
    enum PressTarget: Equatable {
        case widget(anchor: Int)
        case action(KeyAction)
        case nothing
    }

    /// Artwork of any kind — still image or animated GIF — has no bearing on
    /// this. Only a widget takes a key's press away from it.
    func pressTarget(_ index: Int) -> PressTarget {
        if let cell = widgetCells[index] { return .widget(anchor: cell.anchor) }
        guard keys.indices.contains(index) else { return .nothing }
        let action = keys[index].action
        return action == .none ? .nothing : .action(action)
    }

    private func handleKeyPress(_ index: Int) {
        lastPressed = index
        // A key a widget paints answers to the WIDGET, not to whatever its own
        // config says: the face being pressed belongs to the widget, so
        // pressing any key of a 3x2 Spotify block toggles playback. The key's
        // own action comes back the moment the widget stops covering it.
        if let cell = widgetCells[index] {
            // Not gated on config.press: a transport-bar widget ignores that
            // field entirely and gives each of its keys its own action.
            let config = cell.config, anchor = cell.anchor
            Task { [weak self] in
                guard let self else { return }
                let turned = await self.widgets.press(config, cell: cell)
                // Refresh promptly rather than at the end of the interval: the
                // pause pip and the ticker page have to follow the press.
                // Spotify needs a moment to reflect a transport command.
                self.widgetNextDue[anchor] = Date().addingTimeInterval(turned ? 0 : 0.35)
            }
            return
        }
        // Artwork is irrelevant here: a GIF key is still a button.
        guard case .action(let action) = pressTarget(index) else { return }
        action.perform()
    }

    // MARK: - Generated artwork

    /// One at a time. Not a technical limit — it is a paid call per press,
    /// and a button that keeps accepting clicks while it works bills for
    /// pictures nobody waited to see.
    @Published private(set) var generating: Bool = false
    @Published var generatorProblem: String? = nil

    var canGenerate: Bool { WidgetCredentials.has(.fal) }

    func generateImage(prompt: String, style: ImageGen.Style, for index: Int) {
        generate(prompt: prompt, style: style, shape: .key) { [weak self] url in
            self?.setImage(url.path, for: index)
        }
    }

    func generateWallpaper(prompt: String, style: ImageGen.Style) {
        generate(prompt: prompt, style: style, shape: .deck) { [weak self] url in
            self?.setWallpaper(url.path)
        }
    }

    private func generate(prompt: String, style: ImageGen.Style, shape: ImageGen.Shape,
                          apply: @escaping (URL) -> Void) {
        guard !generating else { return }
        generating = true
        generatorProblem = nil
        // Inherits this actor, so `apply` runs on the main thread and only
        // the network wait happens off it.
        Task {
            do {
                let url = try await ImageGen.generate(prompt: prompt, style: style, shape: shape)
                DeckLog.write("fifine: generated \(url.lastPathComponent)")
                apply(url)
            } catch {
                let text = ImageGen.message(for: error)
                DeckLog.write("fifine: image generation failed — \(text)")
                generatorProblem = text
            }
            generating = false
        }
    }

    // MARK: - Open at login

    /// Mirrors `SMAppService`, which is the source of truth — see `LoginItem`
    /// for why this is not in `settings.json`.
    @Published private(set) var openAtLogin: Bool = LoginItem.isEnabled
    @Published private(set) var loginItemProblem: String? = nil
    var canOpenAtLogin: Bool { LoginItem.isSupported }

    func setOpenAtLogin(_ enabled: Bool) {
        loginItemProblem = LoginItem.set(enabled)
        // Read back rather than assume it took: registration can be left
        // pending the user's approval in System Settings, and a switch that
        // says "on" while the system says "waiting" is a lie the user only
        // discovers after the next reboot.
        openAtLogin = LoginItem.isEnabled
    }

    // MARK: - Persistence

    /// How long an edit waits before it reaches the disk. Long enough that a
    /// drag writes once at the end of it, short enough that it is over before
    /// a hand gets back to the keyboard.
    private static let saveDelay: TimeInterval = 0.4

    /// Bumped by every request; a scheduled write that finds it changed has
    /// been superseded and does nothing.
    private var saveGeneration = 0

    private static let saveQueue = DispatchQueue(label: "fifine.settings")

    /// Coalesced, and the write itself happens off the main thread.
    ///
    /// Every editing path lands here, and some of them fire per tick of a
    /// drag — the colour picker sends a change for every pixel the mouse
    /// moves, and so does the brightness slider — so encoding the whole
    /// layout and doing a temp-file-and-rename synchronously put the disk
    /// inside the drag loop.
    ///
    /// The delay leaves a moment where an edit is not yet on disk, which is
    /// what `saveNow()` is for; quitting and closing the window both go
    /// through it.
    func save() {
        saveGeneration += 1
        let generation = saveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay) { [weak self] in
            Task { @MainActor in
                guard let self, self.saveGeneration == generation else { return }
                self.writeSettings(synchronously: false)
            }
        }
    }

    /// Writes immediately, and supersedes any pending coalesced write.
    func saveNow() {
        saveGeneration += 1
        writeSettings(synchronously: true)
    }

    private func writeSettings(synchronously: Bool) {
        let settings = DeckSettings(
            keys: keys, pattern: pattern,
            primaryHex: NSColor(primary).hexString,
            secondaryHex: NSColor(secondary).hexString,
            wallpaperPath: wallpaperPath, brightness: brightness,
            smoothAnimation: smoothAnimation)
        guard let data = try? JSONEncoder().encode(settings) else { return }
        let url = storeURL
        // Synchronously on the way out: handing the write to another queue as
        // the process exits is handing it to a queue that will not run again.
        if synchronously {
            try? data.write(to: url, options: .atomic)
        } else {
            Self.saveQueue.async { try? data.write(to: url, options: .atomic) }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let settings = try? JSONDecoder().decode(DeckSettings.self, from: data),
              settings.keys.count == DeckLayout.keyCount
        else { return }
        keys = settings.keys
        pattern = settings.pattern
        if let c = NSColor(hex: settings.primaryHex)   { primary = Color(nsColor: c) }
        if let c = NSColor(hex: settings.secondaryHex) { secondary = Color(nsColor: c) }
        wallpaperPath = settings.wallpaperPath
        brightness = settings.brightness
        smoothAnimation = settings.smoothAnimation ?? false
        // Re-load any GIFs the keys reference.
        for (index, key) in keys.enumerated() {
            if let path = key.gifPath, let animation = GifPlayer.load(path: path) {
                gifs[index] = animation
                gifFrame[index] = -1
                gifNextDue[index] = 0
            }
        }
        // Normalise once, here: a hand-edited settings.json is the only way a
        // widget can carry an out-of-range span or an unknown style, and
        // nothing downstream should have to defend against it.
        for index in keys.indices {
            if let widget = keys[index].widget { keys[index].widget = widget.normalized }
        }
        widgetCells = WidgetLayout.cells(for: keys)
    }
}

// MARK: - Colour helpers

extension NSColor {
    /// Parses "#RRGGBB".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                  green: CGFloat((value >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(value & 0xFF) / 255.0,
                  alpha: 1.0)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
