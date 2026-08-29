import Foundation

/// API keys and tokens for the network-backed widgets.
///
/// Three sources, first hit wins:
///
///   1. the process environment — handy for a one-off run, persists nothing,
///   2. `widgets.json` next to the deck settings — what the key editor writes,
///   3. a `.env` file found near the app — the shared-file workflow, so one
///      file can feed the deck and whatever scripts already read it.
///
/// `widgets.json` deliberately beats `.env`: the editor writes that file, and
/// a `.env` overriding it would make pressing Save look like it did nothing.
///
/// None of this lives in `settings.json`. That file is the deck layout — the
/// thing you would copy to another machine or hand to someone — and it must
/// never carry a token with it.
enum WidgetCredentials {
    enum Key: String, CaseIterable {
        case finnhub = "finnhub_key"
        case spotifyClientID = "spotify_client_id"
        case spotifyRefreshToken = "spotify_refresh_token"
        case fal = "fal_key"

        /// Names accepted in the environment and in a `.env`, in order.
        /// `FINNHUN` is the spelling in an existing `.env` of this user's, kept
        /// as an alias so one file can feed both this app and those scripts.
        var environmentNames: [String] {
            switch self {
            case .finnhub:             return ["FINNHUB_KEY", "FINNHUN"]
            case .spotifyClientID:     return ["SPOTIFY_CLIENT_ID"]
            case .spotifyRefreshToken: return ["SPOTIFY_REFRESH_TOKEN"]
            case .fal:                 return ["FAL_KEY"]
            }
        }

        var title: String {
            switch self {
            case .finnhub:             return "Finnhub API key"
            case .spotifyClientID:     return "Spotify client id"
            case .spotifyRefreshToken: return "Spotify refresh token"
            case .fal:                 return "fal.ai API key"
            }
        }
    }

    /// Where a value actually came from — shown in the editor, so a field that
    /// looks pre-filled is never a mystery.
    enum Source: Equatable {
        case environment(String)
        case saved
        case dotenv(String)          // file path
        case missing

        var label: String {
            switch self {
            case .environment(let name): return "from $\(name)"
            case .saved:                 return "saved"
            case .dotenv(let path):      return "from \((path as NSString).abbreviatingWithTildeInPath)"
            case .missing:               return ""
            }
        }
    }

    static var url: URL { directory.appendingPathComponent("widgets.json") }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("FifineDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static let lock = NSLock()
    private static var cache: [String: String]?
    private static var dotenvCache: (path: String, stamp: Date, values: [String: String])?

    // MARK: - Lookup

    static func value(_ key: Key) -> String {
        switch source(key) {
        case .environment(let name):
            return ProcessInfo.processInfo.environment[name]?
                .trimmingCharacters(in: .whitespaces) ?? ""
        case .saved:
            return stored()[key.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        case .dotenv:
            let values = dotenv()?.values ?? [:]
            for name in key.environmentNames where !(values[name] ?? "").isEmpty {
                return values[name]!.trimmingCharacters(in: .whitespaces)
            }
            return ""
        case .missing:
            return ""
        }
    }

    static func source(_ key: Key) -> Source {
        for name in key.environmentNames {
            if let value = ProcessInfo.processInfo.environment[name],
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return .environment(name)
            }
        }
        if let value = stored()[key.rawValue],
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return .saved
        }
        if let env = dotenv() {
            for name in key.environmentNames {
                if let value = env.values[name],
                   !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return .dotenv(env.path)
                }
            }
        }
        return .missing
    }

    static func has(_ key: Key) -> Bool { !value(key).isEmpty }

    // MARK: - widgets.json

    private static func stored() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let values: [String: String]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode([String: String].self, from: data) {
            values = parsed
        } else {
            values = [:]              // absent, or hand-edited into nonsense
        }
        cache = values
        return values
    }

    static func set(_ key: Key, _ value: String) { set([key: value]) }

    static func set(_ pairs: [Key: String]) {
        var values = stored()
        for (key, value) in pairs {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { values.removeValue(forKey: key.rawValue) }
            else { values[key.rawValue] = trimmed }
        }
        write(values)
    }

    private static func write(_ values: [String: String]) {
        lock.lock()
        cache = values
        lock.unlock()
        guard let data = try? JSONEncoder().encode(values) else { return }
        // Atomic, then tighten the mode: a crash mid-write must not leave a
        // truncated file that reads back as "no credentials" and silently logs
        // every widget out.
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    // MARK: - .env

    /// Where a `.env` is looked for, in order. Resolved from the app's own
    /// location rather than the working directory: launched from Finder the
    /// working directory is `/`, so anything relative would never be found.
    ///
    /// Walking up from the bundle covers both shapes the app takes — inside
    /// `FifineDeck.app` (its container is the project folder) and as the bare
    /// `.build/release` binary (the project folder is three levels up).
    static func dotenvSearchPaths() -> [String] {
        var paths: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["FIFINE_DECK_ENV"],
           !explicit.isEmpty {
            paths.append((explicit as NSString).expandingTildeInPath)
        }
        var directory = Bundle.main.bundleURL
        for _ in 0..<4 {
            paths.append(directory.appendingPathComponent(".env").path)
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        paths.append(FileManager.default.currentDirectoryPath + "/.env")
        paths.append(Self.directory.appendingPathComponent(".env").path)
        return paths
    }

    /// The first readable `.env` on the search path, cached until it changes.
    private static func dotenv() -> (path: String, values: [String: String])? {
        let manager = FileManager.default
        guard let path = dotenvSearchPaths().first(where: { manager.isReadableFile(atPath: $0) })
        else { return nil }
        let stamp = (try? manager.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
        lock.lock()
        if let cached = dotenvCache, cached.path == path, cached.stamp == stamp {
            lock.unlock()
            return (path, cached.values)
        }
        lock.unlock()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let values = parseDotenv(text)
        lock.lock()
        dotenvCache = (path, stamp, values)
        lock.unlock()
        return (path, values)
    }

    /// Parses `KEY=value` lines. Tolerates `export`, comments, blank lines,
    /// surrounding quotes, and a value containing `=` (only the FIRST one
    /// splits — a base64 token ending in `=` must survive intact).
    static func parseDotenv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let split = line.firstIndex(of: "=") else { continue }
            let name = line[line.startIndex..<split].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            for quote in ["\"", "'"] where value.count >= 2
                && value.hasPrefix(quote) && value.hasSuffix(quote) {
                value = String(value.dropFirst().dropLast())
            }
            guard !name.isEmpty else { continue }
            out[name] = value
        }
        return out
    }

    /// Forces the next lookup to re-read both files. Used after the editor
    /// saves, and when the user has just dropped a `.env` next to the app.
    static func reload() {
        lock.lock()
        cache = nil
        dotenvCache = nil
        lock.unlock()
    }
}
