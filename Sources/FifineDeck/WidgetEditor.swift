import AppKit
import SwiftUI

/// The key inspector's widget section: pick a widget, size it, and give it
/// whatever credentials it needs.
///
/// Text fields commit on Return or when they lose focus, not on every
/// keystroke: each commit reconfigures the widget and can start a network
/// request, and typing "AAPL" would otherwise fetch A, AA and AAP on the way.
struct WidgetEditor: View {
    @EnvironmentObject var deck: DeckController
    let index: Int

    private enum Field: Hashable {
        case symbols, interval, rotate, finnhub, clientID, place, timezone, minutes
        case vlcPassword
    }

    @State private var symbols = ""
    @State private var interval = ""
    @State private var rotate = ""
    @State private var place = ""
    @State private var vlcPassword = ""
    @State private var timezone = ""
    @State private var minutes = ""
    @State private var finnhubKey = ""
    @State private var clientID = ""
    @State private var loginStatus = ""
    @State private var loggingIn = false
    @State private var draftIndex: Int? = nil
    @FocusState private var focus: Field?

    private var config: WidgetConfig? { deck.keys[safe: index]?.widget }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            kindPicker

            if let config {
                presets(config)
                spanPicker(config)
                stylePicker(config)
                fields(config)
                if config.kind.stylesWithOwnActions.contains(config.style) {
                    // The transport bar assigns an action per key, so a single
                    // "on press" would be a control that contradicts the face.
                    Label("Each key of the bar runs its own control — previous, play/pause, next.",
                          systemImage: "hand.tap")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    pressPicker(config)
                }
                credentials(config)
            } else if let cell = deck.widgetCell(index) {
                Text("Key \(cell.anchor + 1) paints this one. Select it to change the widget, or shrink its size to hand this key back.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("A widget replaces the key face with something live — what Spotify is playing, or a stock ticker — and can spread across several keys.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { syncDrafts(force: true) }
        .onChange(of: index) { _ in syncDrafts(force: true) }
        // Follows the stored widget however it changed — a preset, a drag
        // resize, an undo — so the fields never disagree with the deck.
        .onChange(of: deck.keys[safe: index]?.widget) { _ in syncDrafts(force: false) }
    }

    // MARK: - Sections

    private var kindPicker: some View {
        Picker("", selection: Binding(
            get: { config?.kind },
            set: { newKind in
                guard let newKind else { deck.setWidget(nil, for: index); return }
                guard newKind != config?.kind else { return }
                deck.setWidget(WidgetConfig(kind: newKind), for: index)
                reloadDrafts()
            })) {
            Text("None").tag(WidgetKind?.none)
            ForEach(WidgetKind.allCases) { Text($0.title).tag(WidgetKind?.some($0)) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    /// One-click starting points. The combinations that look good are not
    /// obvious from two size pickers and a style menu.
    @ViewBuilder
    private func presets(_ config: WidgetConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Presets").font(.system(size: 10)).foregroundStyle(.secondary)
            FlowRow(spacing: 5) {
                ForEach(presetOptions(config), id: \.0) { name, preset in
                    Button(name) { apply(preset) }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    /// Plain function, not a @ViewBuilder: the builder cannot hold a
    /// statement-style switch that assigns to a local.
    private func presetOptions(_ config: WidgetConfig) -> [(String, WidgetConfig)] {
        var options: [(String, WidgetConfig)] = []
        switch config.kind {
        case .spotify:
            options = [("Now playing", preset(.spotify, style: "auto", 4, 2)),
                       ("Big art", preset(.spotify, style: "art", 2, 2)),
                       ("Transport bar", preset(.spotify, style: "controls", 3, 1)),
                       ("Play/pause key", preset(.spotify, style: "button", 1, 1,
                                                 press: "play_pause")),
                       ("Next-track key", preset(.spotify, style: "button", 1, 1, press: "next"))]
        case .stocks:
            options = [("Ticker row", preset(.stocks, style: "card", 3, 1)),
                       ("Ticker block", preset(.stocks, style: "card", 3, 2)),
                       ("Single chart", preset(.stocks, style: "graph", 2, 2)),
                       ("One key", preset(.stocks, style: "compact", 1, 1))]
        case .clock:
            options = [("Digital", preset(.clock, style: "digital", 2, 1)),
                       ("Analog", preset(.clock, style: "analog", 2, 2)),
                       ("Date", preset(.clock, style: "date", 1, 1)),
                       ("One key", preset(.clock, style: "digital", 1, 1))]
        case .weather:
            options = [("Detail", preset(.weather, style: "detail", 3, 1)),
                       ("Block", preset(.weather, style: "detail", 2, 2)),
                       ("One key", preset(.weather, style: "current", 1, 1))]
        case .system:
            options = [("CPU + memory", preset(.system, style: "number", 2, 1)),
                       ("Four metrics", preset(.system, style: "number", 4, 1)),
                       ("CPU gauge", preset(.system, style: "gauge", 1, 1)),
                       ("Graph", preset(.system, style: "graph", 2, 1))]
        case .sports:
            options = [("Scoreboard", preset(.sports, style: "score", 3, 1)),
                       ("One game", preset(.sports, style: "score", 1, 1)),
                       ("Block", preset(.sports, style: "score", 3, 2))]
        case .vlc:
            options = [("Now playing", preset(.vlc, style: "progress", 3, 2)),
                       ("Transport bar", preset(.vlc, style: "controls", 3, 1)),
                       ("Play/pause key", preset(.vlc, style: "button", 1, 1,
                                                 press: "play_pause")),
                       ("Next key", preset(.vlc, style: "button", 1, 1, press: "next"))]
        case .timer:
            options = [("Pomodoro 25", preset(.timer, style: "ring", 2, 2, minutes: 25)),
                       ("5 minutes", preset(.timer, style: "digits", 1, 1, minutes: 5)),
                       ("Ring 10", preset(.timer, style: "ring", 2, 2, minutes: 10))]
        case .calendar:
            options = [("Next event", preset(.calendar, style: "next", 3, 1)),
                       ("Agenda", preset(.calendar, style: "agenda", 3, 2)),
                       ("One key", preset(.calendar, style: "next", 1, 1))]
        }
        return options
    }

    private func preset(_ kind: WidgetKind, style: String, _ columns: Int, _ rows: Int,
                        press: String? = nil, minutes: Double? = nil) -> WidgetConfig {
        var config = self.config ?? WidgetConfig(kind: kind)
        config.style = style
        config.columns = columns
        config.rows = rows
        if let press { config.press = press }
        if let minutes { config.minutes = minutes }
        return config.normalized
    }

    private func apply(_ preset: WidgetConfig) {
        deck.setWidget(preset, for: index)
        reloadDrafts()
    }

    private func spanPicker(_ config: WidgetConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Size").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Picker("", selection: binding(config, \.columns)) {
                    ForEach(1...DeckLayout.columns, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 58)
                Text("×").foregroundStyle(.secondary)
                Picker("", selection: binding(config, \.rows)) {
                    ForEach(1...DeckLayout.rows, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 58)
                Text("keys").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let cell = deck.widgetCell(index),
               cell.columns != config.columns || cell.rows != config.rows {
                // Say so rather than silently showing something smaller: the
                // span clips at the edge of the deck and shrinks rather than
                // overlapping a neighbouring widget.
                Label("Showing \(cell.columns) × \(cell.rows) — the rest of the span is off the deck or already taken.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }

    private func stylePicker(_ config: WidgetConfig) -> some View {
        labelled("Layout") {
            Picker("", selection: binding(config, \.style)) {
                ForEach(config.kind.styles, id: \.self) { Text(title(for: $0)).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu)
        }
    }

    private func pressPicker(_ config: WidgetConfig) -> some View {
        labelled("On press") {
            Picker("", selection: binding(config, \.press)) {
                ForEach(config.kind.presses, id: \.self) { Text(title(for: $0)).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu)
        }
    }

    /// The controls that belong to this kind. Everything else is shared.
    @ViewBuilder
    private func fields(_ config: WidgetConfig) -> some View {
        switch config.kind {
        case .spotify:  spotifyFields(config)
        case .stocks:   stocksFields(config)
        case .clock:    clockFields(config)
        case .weather:  weatherFields(config)
        case .system:   systemFields(config)
        case .sports:   sportsFields(config)
        case .timer:    timerFields(config)
        case .calendar: intervalField(config)
        case .vlc:      vlcFields(config)
        }
    }

    private func clockFields(_ config: WidgetConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("Time zone (blank = this Mac)") {
                TextField("Europe/Paris", text: $timezone)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .timezone)
                    .onSubmit { commit(\.timezone, timezone) }
                    .onChange(of: focus) { if $0 != .timezone { commit(\.timezone, timezone) } }
            }
            labelled("Hours") {
                Picker("", selection: binding(config, \.units)) {
                    Text("24-hour").tag("metric")
                    Text("12-hour").tag("imperial")
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            // The refresh interval IS the seconds hand: under 5 s the face
            // shows seconds, above it does not.
            intervalField(config)
        }
    }

    private func weatherFields(_ config: WidgetConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("Place") {
                TextField("London — or 48.85, 2.35", text: $place)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .place)
                    .onSubmit { commit(\.place, place) }
                    .onChange(of: focus) { if $0 != .place { commit(\.place, place) } }
            }
            labelled("Units") {
                Picker("", selection: binding(config, \.units)) {
                    Text("°C").tag("metric")
                    Text("°F").tag("imperial")
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            Text("Open-Meteo — free, no account needed.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            intervalField(config)
        }
    }

    /// VLC's address, and the password its web interface wants.
    ///
    /// The address is ordinary configuration and lives in `settings.json`
    /// with the rest of the layout. The password does NOT: it goes through
    /// the credential store like every other secret, because settings.json is
    /// the file you copy to another machine.
    private func vlcFields(_ config: WidgetConfig) -> some View {
        let source = WidgetCredentials.source(.vlcPassword)
        return VStack(alignment: .leading, spacing: 10) {
            labelled("Address of the machine running VLC") {
                HStack(spacing: 6) {
                    TextField("192.168.1.10:8080", text: $place)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .place)
                        .onSubmit { commit(\.place, place) }
                        .onChange(of: focus) { if $0 != .place { commit(\.place, place) } }
                    // An explicit Apply, matching the password's Save below.
                    // Typing an address and walking away left the widget on
                    // the OLD one, and the key then said "offline" - which
                    // reads as a network fault rather than an unsaved field.
                    Button("Apply") { commit(\.place, place) }
                        .controlSize(.small)
                        .disabled(place == config.place)
                }
            }
            if place != config.place {
                Label("Not applied yet — press Return or Apply",
                      systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            labelled("Web interface password") {
                HStack(spacing: 6) {
                    SecureField(source == .missing ? "the Lua password you set in VLC"
                                                   : "replace it",
                                text: $vlcPassword)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .vlcPassword)
                        .onSubmit { saveVLCPassword() }
                    Button("Save") { saveVLCPassword() }
                        .controlSize(.small).disabled(vlcPassword.isEmpty)
                }
            }
            if source == .missing {
                Label("Not set — the widget cannot connect without it",
                      systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            } else {
                Label(source.label, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(.green)
            }
            Text("In VLC: Preferences → Show settings **All** → Interface → "
                 + "Main interfaces → tick **Web**, then Lua → set a password. "
                 + "Restart VLC, and let it through that machine's firewall on port 8080.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            intervalField(config)
        }
    }

    private func systemFields(_ config: WidgetConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("Metrics") {
                TextField("cpu, memory, network, disk, battery", text: $symbols)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .symbols)
                    .onSubmit { commitSymbols() }
                    .onChange(of: focus) { if $0 != .symbols { commitSymbols() } }
            }
            Text("Any of: cpu · memory · network · disk · battery")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            intervalField(config)
        }
    }

    private func sportsFields(_ config: WidgetConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("League") {
                Picker("", selection: binding(config, \.place)) {
                    ForEach(SportsProvider.leagues.keys.sorted(), id: \.self) {
                        Text($0.uppercased()).tag($0)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }
            labelled("Only these teams (blank = all games)") {
                TextField("SF, KC", text: $symbols)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .symbols)
                    .onSubmit { commitSymbols() }
                    .onChange(of: focus) { if $0 != .symbols { commitSymbols() } }
            }
            intervalField(config)
        }
    }

    private func timerFields(_ config: WidgetConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("Length (minutes)") {
                TextField("25", text: $minutes)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .minutes)
                    .onSubmit { commitMinutes() }
                    .onChange(of: focus) { if $0 != .minutes { commitMinutes() } }
            }
            Text("Press the key to start and pause it. It chimes at zero.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func spotifyFields(_ config: WidgetConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("Source") {
                Picker("", selection: binding(config, \.source)) {
                    Text("Automatic").tag("auto")
                    Text("Spotify on this Mac").tag("local")
                    Text("Spotify account (any device)").tag("web")
                }
                .labelsHidden().pickerStyle(.menu)
            }
            if config.source != "web", !SpotifyProvider.localAppInstalled {
                // Without the desktop app there is nothing on this Mac to ask,
                // and the failure is otherwise cryptic — the AppleScript does
                // not even compile.
                Label("The Spotify app isn't installed on this Mac, so there's nothing local to read. Connect your account below, or install Spotify.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            intervalField(config)
        }
    }

    private func stocksFields(_ config: WidgetConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("Symbols") {
                TextField("AAPL, MSFT, NVDA", text: $symbols)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .symbols)
                    .onSubmit { commitSymbols() }
                    .onChange(of: focus) { if $0 != .symbols { commitSymbols() } }
            }
            let count = config.symbolList.count
            let cells = deck.widgetCell(index).map(\.cellCount) ?? 1
            if count > cells {
                Text("\(count) symbols across \(cells) key\(cells == 1 ? "" : "s") — \(Int(ceil(Double(count) / Double(cells)))) pages.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            intervalField(config)
            labelled("Rotate pages every (seconds, 0 = off)") {
                TextField("0", text: $rotate)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .rotate)
                    .onSubmit { commitRotate() }
                    .onChange(of: focus) { if $0 != .rotate { commitRotate() } }
            }
        }
    }

    private func intervalField(_ config: WidgetConfig) -> some View {
        labelled("Refresh every (seconds)") {
            TextField("\(Int(config.kind.defaultInterval))", text: $interval)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .interval)
                .onSubmit { commitInterval() }
                .onChange(of: focus) { if $0 != .interval { commitInterval() } }
        }
    }

    // MARK: - Credentials

    @ViewBuilder
    private func credentials(_ config: WidgetConfig) -> some View {
        Divider().opacity(0.3)
        if config.kind == .stocks {
            let source = WidgetCredentials.source(.finnhub)
            labelled("Finnhub API key") {
                HStack(spacing: 6) {
                    SecureField(source == .missing ? "free at finnhub.io" : "replace it",
                                text: $finnhubKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .finnhub)
                        .onSubmit { saveFinnhub() }
                    Button("Save") { saveFinnhub() }
                        .controlSize(.small).disabled(finnhubKey.isEmpty)
                }
            }
            HStack(spacing: 8) {
                if source == .missing {
                    Label("Not set", systemImage: "exclamationmark.circle")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                } else {
                    // Say WHERE it came from: a field that looks pre-filled
                    // from a .env you forgot about is otherwise a mystery.
                    Label(source.label, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(.green)
                }
                Button("Reload") { reloadCredentials() }.controlSize(.small)
                if source == .saved {
                    Button("Clear") {
                        WidgetCredentials.set(.finnhub, "")
                        reloadCredentials()
                    }
                    .controlSize(.small)
                }
            }
            if source == .missing {
                Text("Paste a key above, or drop a .env next to FifineDeck.app with FINNHUB_KEY (or FINNHUN) in it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Link("Get a free key", destination: URL(string: "https://finnhub.io/register")!)
                    .font(.system(size: 10))
            }
        } else if config.source != "local" {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spotify account").font(.system(size: 10)).foregroundStyle(.secondary)
                if WidgetCredentials.has(.spotifyRefreshToken) {
                    let source = WidgetCredentials.source(.spotifyRefreshToken)
                    HStack(spacing: 8) {
                        Label(source == .saved ? "Connected" : "Connected (\(source.label))",
                              systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(.green)
                        if source == .saved {
                            Button("Disconnect") {
                                WidgetCredentials.set([.spotifyRefreshToken: "",
                                                       .spotifyClientID: ""])
                                reloadCredentials()
                            }
                            .controlSize(.small)
                        }
                    }
                } else {
                    Text("Only needed to follow playback on other devices. Create an app at developer.spotify.com and add \(SpotifyAuth.redirectURI()) as a redirect URI.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("Spotify client id", text: $clientID)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .clientID)
                    Button(loggingIn ? "Waiting for your browser…" : "Connect Spotify…") { login() }
                        .controlSize(.small)
                        .disabled(loggingIn || clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !loginStatus.isEmpty {
                    Text(loginStatus).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Plumbing

    /// Writes one field of the widget through to the controller.
    private func binding<Value: Equatable>(_ config: WidgetConfig,
                                           _ path: WritableKeyPath<WidgetConfig, Value>)
    -> Binding<Value> {
        Binding(get: { config[keyPath: path] },
                set: { newValue in
                    guard newValue != config[keyPath: path] else { return }
                    var updated = config
                    updated[keyPath: path] = newValue
                    deck.setWidget(updated, for: index)
                })
    }

    private func reloadDrafts() { syncDrafts(force: true) }

    /// Brings the text fields back in line with the stored widget.
    ///
    /// Called whenever the config changes, not only when the selected key
    /// does. The drafts are `@State`, and SwiftUI is free to rebuild this view
    /// with fresh state at any point — when the sibling "On press" card
    /// appears or disappears, for instance. Reloading only in `onAppear` and
    /// on an index change left the fields blank while the widget still held
    /// the value, which looked exactly like the setting had been wiped.
    ///
    /// A field the user is typing in is left alone: the draft is authoritative
    /// while focused, the config is authoritative otherwise.
    private func syncDrafts(force: Bool) {
        let config = deck.keys[safe: index]?.widget
        if force || focus != .symbols  { symbols  = config?.symbols ?? "" }
        if force || focus != .place    { place    = config?.place ?? "" }
        if force || focus != .timezone { timezone = config?.timezone ?? "" }
        if force || focus != .interval { interval = config.map { trim($0.interval) } ?? "" }
        if force || focus != .rotate   { rotate   = config.map { trim($0.rotate) } ?? "" }
        if force || focus != .minutes  { minutes  = config.map { trim($0.minutes) } ?? "" }
        if force {
            finnhubKey = ""
            clientID = WidgetCredentials.value(.spotifyClientID)
            loginStatus = ""
        }
        draftIndex = index
    }

    /// Which key the drafts were loaded from.
    ///
    /// Selecting another key while a field is focused fires that field's
    /// focus-lost commit, and without this the text belonging to the key you
    /// just left was written onto the key you just arrived at.
    private var draftsAreForThisKey: Bool { draftIndex == index }

    private func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Writes one text field through, if it changed.
    private func commit(_ path: WritableKeyPath<WidgetConfig, String>, _ value: String) {
        guard draftsAreForThisKey else { return }
        guard var config, config[keyPath: path] != value else { return }
        config[keyPath: path] = value
        deck.setWidget(config, for: index)
    }

    private func commitMinutes() {
        guard draftsAreForThisKey, var config else { return }
        let value = Double(minutes.replacingOccurrences(of: ",", with: ".")) ?? config.minutes
        guard value != config.minutes else { return }
        config.minutes = value
        deck.setWidget(config, for: index)
        minutes = trim(config.normalized.minutes)
    }

    private func commitSymbols() {
        guard draftsAreForThisKey else { return }
        guard var config, config.symbols != symbols else { return }
        config.symbols = symbols
        deck.setWidget(config, for: index)
    }

    private func commitInterval() {
        guard draftsAreForThisKey, var config else { return }
        // An unparseable entry falls back to the kind's default rather than
        // to zero, which would be a poll as fast as the clock can run.
        let value = Double(interval.replacingOccurrences(of: ",", with: "."))
            ?? config.kind.defaultInterval
        guard value != config.interval else { return }
        config.interval = value
        deck.setWidget(config, for: index)
        interval = trim(config.normalized.interval)
    }

    private func commitRotate() {
        guard draftsAreForThisKey, var config else { return }
        let value = Double(rotate.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard value != config.rotate else { return }
        config.rotate = value
        deck.setWidget(config, for: index)
        rotate = trim(config.normalized.rotate)
    }

    private func saveVLCPassword() {
        let password = vlcPassword.trimmingCharacters(in: .whitespaces)
        guard !password.isEmpty else { return }
        WidgetCredentials.set(.vlcPassword, password)
        vlcPassword = ""
        focus = nil
        reloadCredentials()
    }

    private func saveFinnhub() {
        let key = finnhubKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        WidgetCredentials.set(.finnhub, key)
        finnhubKey = ""
        focus = nil
        reloadCredentials()
    }

    /// Re-reads both credential files and repaints. The .env is the point:
    /// you can drop one next to the app while it is running and pick it up
    /// without a relaunch.
    private func reloadCredentials() {
        WidgetCredentials.reload()
        loginStatus = ""
        deck.refreshWidgetsNow()
    }

    private func login() {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        loggingIn = true
        loginStatus = ""
        Task {
            do {
                try await SpotifyAuth.login(clientID: id)
                loginStatus = "Connected."
                deck.refreshWidgetsNow()
            } catch {
                loginStatus = (error as? WidgetError)?.text ?? error.localizedDescription
            }
            loggingIn = false
        }
    }

    // MARK: - Labels

    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            content()
        }
    }

    private func title(for option: String) -> String {
        switch option {
        case "auto":       return "Automatic"
        case "art":        return "Album art"
        case "art+text":   return "Art and text"
        case "split":      return "Art + info panel"
        case "text":       return "Text only"
        case "progress":   return "Art and progress"
        case "button":     return "One control button"
        case "controls":   return "Transport bar (one control per key)"
        case "card":       return "Cards"
        case "compact":    return "Compact"
        case "graph":      return "Big chart"
        case "play_pause": return "Play / pause"
        case "next":       return "Next track"
        case "previous":   return "Previous track"
        case "cycle":      return "Next page of symbols"
        case "none":       return "Nothing"
        default:           return option.capitalized
        }
    }
}

extension Array {
    /// Bounds-checked subscript. The selected key index and the key array are
    /// two pieces of state that can disagree for one layout pass.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A wrapping row of small controls. SwiftUI has no flow layout before macOS
/// 16, and five preset buttons in an HStack simply run off the inspector.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
