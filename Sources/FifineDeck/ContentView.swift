import AppKit
import SwiftUI

/// Real window-level vibrancy. SwiftUI's `.ultraThinMaterial` blurs what is
/// behind it *inside* the window; this blurs the desktop behind the window.
///
/// Only works because `AppDelegate.style(_:)` makes the window non-opaque —
/// blurring what is behind an opaque window shows you nothing.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The app's design tokens, in one place so the panels, the grid and the
/// controls cannot drift apart.
enum Theme {
    /// Cyan, matching the deck's own default pattern colour rather than the
    /// system accent — the app should look like the hardware it drives.
    static let accent = Color(red: 0.16, green: 0.80, blue: 0.95)
    static let cardRadius: CGFloat = 16
    static let cardStroke = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.06)
    static let label = Color.white.opacity(0.55)

    /// A dark wash over the vibrancy so cards have something to sit on. Glass
    /// with nothing behind it is just grey.
    static var backdrop: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.09).opacity(0.86),
                                    Color(red: 0.02, green: 0.02, blue: 0.04).opacity(0.94)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // A cool highlight in the corner keeps a large flat panel from
            // reading as a grey rectangle.
            RadialGradient(colors: [accent.opacity(0.16), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

/// A translucent card.
struct Glass<Content: View>: View {
    var title: String? = nil
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.label)
                    if let accessory {
                        Spacer(minLength: 0)
                        accessory
                    }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    // A top-down sheen: the difference between "a rectangle
                    // with a blur in it" and something that reads as glass.
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.white.opacity(0.07), .white.opacity(0.01)],
                            startPoint: .top, endPoint: .bottom))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

struct ContentView: View {
    @EnvironmentObject var deck: DeckController

    /// Key currently under a drag, for the drop highlight.
    @State private var dropTarget: Int? = nil
    /// Span at the moment a resize drag began.
    @State private var resizeStart: (cols: Int, rows: Int)? = nil
    @State private var confirmClear = false
    @State private var showHelp = false

    var body: some View {
        // The backdrop is a SIBLING that fills, not a `.background` on the
        // content. As a background it was sized to the content, and a content
        // narrower than the window left the rest of the window unpainted —
        // the black margin around the panel.
        ZStack(alignment: .topLeading) {
            Theme.backdrop
            layout
        }
        .frame(minWidth: 820, idealWidth: 900, maxWidth: .infinity,
               minHeight: 620, idealHeight: 720, maxHeight: .infinity,
               alignment: .topLeading)
        .tint(Theme.accent)
        .onAppear { deck.connect() }
    }

    private var layout: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 14) {
                header
                Glass { grid }
                Glass(title: "Deck") { patternSection }
            }
            .frame(width: 470)

            ScrollView {
                VStack(spacing: 16) {
                    Glass(title: "Key \(deck.selected + 1)") { keyEditor }
                    Glass(title: "Widget") { WidgetEditor(index: deck.selected) }
                    if deck.widgetCell(deck.selected) == nil {
                        Glass(title: "On press") { ActionEditor(action: actionBinding) }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 290)
        }
        .padding(.horizontal, 20)
        // Room for the transparent titlebar the window now uses.
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Status

    private var statusColor: Color {
        if deck.stalled { return .red }
        return deck.connected ? .green : .orange
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.45)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black.opacity(0.75))
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("fifine Deck")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: statusColor, radius: 3)
                    Text(deck.status)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if deck.framesPerSecond > 0 {
                Text(String(format: "%.0f fps", deck.framesPerSecond))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.label)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.07)))
            }
            Button("Connect") { deck.connect() }.controlSize(.small)
            Button("Push all") { deck.pushAll() }.controlSize(.small)
                .disabled(!deck.connected)
            Button { showHelp.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(deck.stalled ? Color.orange : Theme.label)
            .help("Troubleshooting")
            .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                HelpPopover().environmentObject(deck)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(.white.opacity(0.04))
        }
        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    // MARK: - Grid

    /// Distance between key centres in the grid: the key itself plus the gap.
    /// A resize drag converts pointer travel into keys with it.
    static let keyPitch: CGFloat = KeyView.side + 10

    private var grid: some View {
        VStack(spacing: 10) {
            ForEach(0..<DeckLayout.rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(0..<DeckLayout.columns, id: \.self) { column in
                        let index = row * DeckLayout.columns + column
                        KeyView(index: index,
                                config: deck.keys[index],
                                hasGIF: deck.hasGIF(index),
                                widgetImage: deck.widgetPreview(index),
                                widgetCell: deck.widgetCell(index),
                                isSelected: deck.selected == index,
                                isPressed: deck.lastPressed == index,
                                isDropTarget: dropTarget == index,
                                resizeHandle: resizeHandle(for: index))
                            .onTapGesture { deck.selected = index }
                            .draggable(String(index)) {
                                // Drag preview: the key's own face, so it is
                                // obvious what is being moved.
                                KeyView(index: index, config: deck.keys[index],
                                        hasGIF: false,
                                        widgetImage: deck.widgetPreview(index),
                                        widgetCell: nil, isSelected: false,
                                        isPressed: false, isDropTarget: false,
                                        resizeHandle: nil)
                                    .opacity(0.85)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let source = items.first.flatMap(Int.init) else {
                                    return false
                                }
                                deck.moveKey(from: source, to: index)
                                return true
                            } isTargeted: { targeted in
                                dropTarget = targeted ? index : (dropTarget == index ? nil : dropTarget)
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The drag handle shown on the bottom-right key of the SELECTED widget.
    /// Dragging it resizes the span a key at a time.
    private func resizeHandle(for index: Int) -> ((CGSize, Bool) -> Void)? {
        guard let cell = deck.widgetCell(index),
              deck.selected == cell.anchor || deck.selected == index,
              cell.dx == cell.columns - 1, cell.dy == cell.rows - 1
        else { return nil }
        let anchor = cell.anchor
        return { translation, ended in
            // The span at the START of the drag, captured once: reading the
            // live config every step would compound each delta into the next.
            if resizeStart == nil {
                resizeStart = (deck.keys[safe: anchor]?.widget?.columns ?? cell.columns,
                               deck.keys[safe: anchor]?.widget?.rows ?? cell.rows)
            }
            guard let start = resizeStart else { return }
            let dx = Int((translation.width / Self.keyPitch).rounded())
            let dy = Int((translation.height / Self.keyPitch).rounded())
            deck.resizeWidget(anchor: anchor, columns: start.cols + dx, rows: start.rows + dy)
            if ended { resizeStart = nil }
        }
    }

    // MARK: - Whole-deck patterns

    private var patternSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $deck.pattern) {
                ForEach(DeckPattern.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if deck.pattern.usesColors {
                HStack(spacing: 16) {
                    ColorPicker("From", selection: $deck.secondary, supportsOpacity: false)
                    ColorPicker("To", selection: $deck.primary, supportsOpacity: false)
                }
                .font(.system(size: 11))
            }

            if deck.pattern == .wallpaper {
                HStack {
                    Button("Choose image…") { deck.chooseWallpaper() }.controlSize(.small)
                    if let path = deck.wallpaperPath {
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            if deck.pattern.isAnimated {
                Label("Animated patterns update only the keys that change, so they stay smooth.",
                      systemImage: "waveform")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $deck.smoothAnimation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smoother animation").font(.system(size: 11))
                    // Measured, not guessed: saturating the deck with image
                    // writes stops it reporting key presses, and it does not
                    // recover without a replug.
                    Text(deck.smoothAnimation
                         ? "Faster GIFs and patterns — but the deck may stop responding to presses until you replug it."
                         : "GIFs and patterns run gently so the deck keeps reporting key presses.")
                        .font(.system(size: 10))
                        .foregroundStyle(deck.smoothAnimation ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider().opacity(0.3)

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Clear all keys", systemImage: "trash")
                }
                .controlSize(.small)
                if deck.hasBackup {
                    Button {
                        deck.restoreBackup()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                }
                Spacer()
            }
            .confirmationDialog("Clear all 15 keys?", isPresented: $confirmClear) {
                Button("Clear every key", role: .destructive) { deck.clearAllKeys() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Colours, artwork, labels, actions and widgets are all reset. Undo puts them back.")
            }

            Divider().opacity(0.3)

            HStack(spacing: 10) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: $deck.brightness, in: 0...100)
                Image(systemName: "sun.max").foregroundStyle(.secondary)
                Text("\(Int(deck.brightness))%")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 34, alignment: .trailing)
            }
            .disabled(!deck.connected)
        }
    }

    // MARK: - Key editor

    private var actionBinding: Binding<KeyAction> {
        Binding(get: { deck.keys[deck.selected].action },
                set: { deck.setAction($0, for: deck.selected) })
    }

    private var keyEditor: some View {
        let index = deck.selected
        return VStack(alignment: .leading, spacing: 12) {
            if let cell = deck.widgetCell(index) {
                Label(cell.isAnchor
                      ? "A widget owns this key's face. Its background colour tints the widget; the label and artwork are not drawn."
                      : "Painted by the widget on key \(cell.anchor + 1). This key keeps its own settings and gets them back when that widget shrinks.",
                      systemImage: "square.grid.3x3.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else if deck.pattern != .none {
                Label("A deck pattern is active — it replaces per-key colours, but icons and labels composite on top. Transparent PNGs let the pattern show through.",
                      systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            ColorPicker("Background", selection: Binding(
                get: { deck.keys[index].color },
                set: { deck.setColor($0, for: index) }), supportsOpacity: false)
            .font(.system(size: 11))

            VStack(alignment: .leading, spacing: 5) {
                Text("Label").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("", text: Binding(
                    get: { deck.keys[index].label },
                    set: { deck.setLabel($0, for: index) }))
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Artwork").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button("Image…") { deck.chooseImage(for: index) }.controlSize(.small)
                    Button("GIF…") { deck.chooseGIF(for: index) }.controlSize(.small)
                    Button("Clear") { deck.clearImage(for: index) }.controlSize(.small)
                        .disabled(deck.keys[index].imagePath == nil && deck.keys[index].gifPath == nil)
                }
                if let path = deck.keys[index].gifPath {
                    Label((path as NSString).lastPathComponent, systemImage: "play.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else if let path = deck.keys[index].imagePath {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            Button("Reset key") { deck.resetKey(index) }
                .controlSize(.small)
                .foregroundStyle(.red)
        }
    }
}

/// One key in the grid.
struct KeyView: View {
    /// On-screen size of a key. Shared so the resize drag can convert pointer
    /// travel into whole keys.
    static let side: CGFloat = 78

    let index: Int
    let config: KeyConfig
    let hasGIF: Bool
    /// The slice of a widget's frame this key shows, if a widget covers it.
    /// It replaces the whole face — colour, artwork and label alike — because
    /// that is exactly what the deck will show.
    var widgetImage: NSImage? = nil
    /// Set when a widget paints this key, for the span outline.
    var widgetCell: WidgetCell? = nil
    let isSelected: Bool
    let isPressed: Bool
    var isDropTarget: Bool = false
    /// Called with the live drag translation while the span is resized, and
    /// once more with `ended` when the drag finishes.
    var resizeHandle: ((CGSize, Bool) -> Void)? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(config.color)
            if let widgetImage {
                Image(nsImage: widgetImage)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let gifPath = config.gifPath, GifPreview.exists(gifPath) {
                // The real animation, cropped the way the deck crops it. A
                // still play icon told you a GIF was bound but nothing about
                // WHICH one, which is useless when three keys have one.
                AnimatedGIF(path: gifPath, cornerRadius: 10)
                    .frame(width: Self.side, height: Self.side)
            } else if let image = config.image {
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if hasGIF, widgetImage == nil {
                // Small and out of the way now that the animation itself is
                // visible: this only has to say "this one moves on the deck".
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .padding(4)
            }
            if !config.label.isEmpty, widgetImage == nil {
                Text(config.label)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 2)
                    .padding(3)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .overlay(alignment: .bottomTrailing) { handle }
        .shadow(color: .black.opacity(0.45), radius: 5, y: 3)
        // The selected key glows in the accent rather than just gaining a
        // ring, so it stays findable across fifteen busy tiles.
        .shadow(color: isSelected ? Theme.accent.opacity(0.55) : .clear, radius: 9)
        .scaleEffect(isPressed ? 0.94 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.5), value: isPressed)
    }

    /// The corner grip that resizes a widget's span.
    @ViewBuilder
    private var handle: some View {
        if let resizeHandle {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.accentColor))
                .offset(x: 5, y: 5)
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { resizeHandle($0.translation, false) }
                        .onEnded { resizeHandle($0.translation, true) }
                )
                .help("Drag to resize the widget across more keys")
        }
    }

    private var borderColor: Color {
        if isDropTarget { return .green }
        if isPressed { return .yellow }
        if isSelected { return Theme.accent }
        // A widget's keys share one outline so the span is visible at a glance.
        if widgetCell != nil { return Theme.accent.opacity(0.40) }
        return .white.opacity(0.14)
    }

    private var borderWidth: CGFloat {
        if isDropTarget { return 3 }
        return isSelected || isPressed ? 2.5 : (widgetCell != nil ? 1.5 : 1)
    }
}

/// Minimal editor for the action harness.
struct ActionEditor: View {
    @Binding var action: KeyAction

    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    private enum Kind: String, CaseIterable, Identifiable {
        case none = "Nothing", url = "Open URL", command = "Run command"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch action {
        case .none: return .none
        case .openURL: return .url
        case .runCommand: return .command
        }
    }

    private var payload: String {
        switch action {
        case .none: return ""
        case .openURL(let s), .runCommand(let s): return s
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { kind },
                set: { newKind in
                    switch newKind {
                    case .none:    action = .none
                    case .url:     action = .openURL(payload)
                    case .command: action = .runCommand(payload)
                    }
                })) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if kind != .none {
                TextField(kind == .url ? "example.com" : "pmset displaysleepnow",
                          text: Binding(
                    get: { payload },
                    set: { text in
                        action = (kind == .url) ? .openURL(text) : .runCommand(text)
                    }), axis: kind == .command ? .vertical : .horizontal)
                .textFieldStyle(.roundedBorder)
                .lineLimit(kind == .command ? 1...4 : 1...1)
            }

            if kind == .command {
                HStack(spacing: 6) {
                    Menu("Examples") {
                        ForEach(CommandRunner.examples, id: \.group) { group in
                            Menu(group.group) {
                                ForEach(group.items, id: \.name) { item in
                                    Button(item.name) { action = .runCommand(item.command) }
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 84)

                    Button(testing ? "Running…" : "Test") { test() }
                        .controlSize(.small)
                        .disabled(payload.isEmpty || testing)
                    Spacer(minLength: 0)
                }
                if let testResult {
                    // The result of an actual run, not a guess: the whole point
                    // of Test is finding out that `brew` is not on the app's
                    // PATH before binding the key and wondering why it is dead.
                    Label(testResult.text, systemImage: testResult.ok
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(testResult.ok ? .green : .orange)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Runs in your login shell (\((CommandRunner.loginShell as NSString).lastPathComponent)), so your usual PATH applies.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        CommandRunner.test(payload) { result in
            testing = false
            let output = result.output.isEmpty
                ? (result.ok ? "ran, no output" : "failed, no output") : result.output
            testResult = (result.ok, result.ok ? output : "exit \(result.status): \(output)")
        }
    }
}

/// An animated GIF in the grid.
///
/// SwiftUI's `Image` renders only the first frame of a GIF, so the preview has
/// to drop to AppKit: `NSImageView` animates one natively.
struct AnimatedGIF: NSViewRepresentable {
    let path: String
    var cornerRadius: CGFloat = 10

    func makeNSView(context: Context) -> GifClipView {
        let view = GifClipView()
        view.cornerRadius = cornerRadius
        view.path = path
        return view
    }

    func updateNSView(_ view: GifClipView, context: Context) {
        view.cornerRadius = cornerRadius
        // The setter is a no-op when the path is unchanged: reassigning the
        // image restarts the animation from frame zero, and SwiftUI re-runs
        // this on every layout pass, which would leave the GIF frozen.
        view.path = path
    }
}

/// Holds an `NSImageView` sized to COVER its bounds, and clips it.
///
/// The clipping has to happen here, in AppKit. A SwiftUI `.clipShape` does not
/// clip a hosted NSView — the oversized image view simply spilled out over the
/// neighbouring keys, drawing one GIF across a 2x2 block of them.
final class GifClipView: NSView {
    private let imageView = NSImageView()

    var cornerRadius: CGFloat = 10 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    var path: String? {
        didSet {
            guard path != oldValue else { return }
            imageView.image = path.flatMap(GifPreview.image)
            imageView.animates = true
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = cornerRadius
        // Stretch to whatever frame `layout` gives it; that frame is what
        // encodes the aspect-correct cover.
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else {
            imageView.frame = bounds
            return
        }
        // Cover and centre — the same crop GifPlayer.fit applies before the
        // frame is sent to the deck, so the preview matches the hardware.
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        imageView.frame = CGRect(x: (bounds.width - width) / 2,
                                 y: (bounds.height - height) / 2,
                                 width: width, height: height)
    }
}

/// Cached GIF images and geometry for the grid.
///
/// Cached because SwiftUI re-evaluates a view's body freely, and decoding a
/// multi-megabyte GIF on every layout pass would make the window crawl.
enum GifPreview {
    private static var images: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(_ path: String) -> NSImage? {
        if let cached = images[path] { return cached }
        if missing.contains(path) { return nil }
        guard let image = NSImage(contentsOfFile: path) else {
            missing.insert(path)
            return nil
        }
        images[path] = image
        return image
    }

    static func exists(_ path: String) -> Bool { image(path) != nil }

    /// The size to draw the GIF at so it COVERS a `side` square, matching
    /// `GifPlayer.fit`, which scales to cover and centre-crops.
    static func fillSize(_ path: String, side: CGFloat) -> CGSize {
        guard let image = image(path), image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: side, height: side)
        }
        let scale = max(side / image.size.width, side / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }
}
