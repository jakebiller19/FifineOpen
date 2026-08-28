import Foundation

/// Runs a shell command for the "Run command" key action.
///
/// Through the user's **login** shell, not a bare `/bin/sh`. An app launched
/// from Finder inherits a minimal PATH — roughly `/usr/bin:/bin:/usr/sbin:/sbin`
/// — so anything installed by Homebrew, mise, nvm or a dotfile is simply not
/// found, and the key silently does nothing. A login shell sources the same
/// profile Terminal does, so a command that works when you type it works here.
enum CommandRunner {

    struct Result {
        var status: Int32
        var output: String        // stdout and stderr, trimmed
        var ok: Bool { status == 0 }
    }

    /// How long `test` waits before giving up. Long enough for a Homebrew
    /// binary behind a cold login shell, short enough not to hang the editor.
    static let testTimeout: TimeInterval = 10

    /// The user's shell, as macOS records it. Falls back to zsh, the default
    /// on every macOS since Catalina.
    static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Fire and forget: what a key press does.
    ///
    /// Never blocks the caller — a key that runs `sleep 30` must not freeze
    /// the deck — but the outcome is still logged, because a command that
    /// fails silently is indistinguishable from a key that did nothing.
    static func run(_ command: String) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = execute(command, timeout: 30)
            if !result.ok {
                DeckLog.write("fifine: command failed (status \(result.status)): "
                              + "\(command) — \(result.output.prefix(200))")
            }
        }
    }

    /// Runs it and waits, for the editor's Test button.
    static func test(_ command: String,
                     completion: @escaping @Sendable (Result) -> Void) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            completion(Result(status: -1, output: "nothing to run"))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = execute(command, timeout: testTimeout)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func execute(_ command: String, timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        // -l: login shell, so the profile that defines PATH is sourced.
        process.arguments = ["-l", "-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        // Read before waiting: a command that outfills the pipe buffer would
        // block forever with nobody draining it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            // Left running rather than killed: a key that starts a long job is
            // a legitimate thing to want. Only the waiting stops.
            return Result(status: 0, output: String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n(still running)")
        }
        return Result(status: process.terminationStatus,
                      output: String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Ready-made commands, as a starting point. Every one of these is a
    /// stock macOS binary — nothing to install.
    static let examples: [(group: String, items: [(name: String, command: String)])] = [
        ("Screen", [
            ("Lock the screen", "pmset displaysleepnow"),
            ("Start the screen saver", "open -a ScreenSaverEngine"),
            ("Screenshot to Desktop", "screencapture -x ~/Desktop/shot-$(date +%H%M%S).png"),
            ("Screenshot a selection", "screencapture -i -c"),
        ]),
        ("Sound", [
            ("Mute", "osascript -e 'set volume with output muted'"),
            ("Unmute", "osascript -e 'set volume without output muted'"),
            ("Volume 50%", "osascript -e 'set volume output volume 50'"),
        ]),
        ("System", [
            ("Toggle dark mode",
             "osascript -e 'tell app \"System Events\" to tell appearance preferences to "
             + "set dark mode to not dark mode'"),
            ("Empty the Trash", "osascript -e 'tell app \"Finder\" to empty trash'"),
            ("Flush the DNS cache", "sudo -n dscacheutil -flushcache || true"),
            ("Show hidden files",
             "defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder"),
            ("Hide hidden files",
             "defaults write com.apple.finder AppleShowAllFiles -bool false && killall Finder"),
        ]),
        ("Apps & files", [
            ("Open an app", "open -a 'Visual Studio Code'"),
            ("Open a folder", "open ~/Downloads"),
            ("New Terminal window", "open -a Terminal ~"),
            ("Copy the date", "date | pbcopy"),
        ]),
        ("Media", [
            ("Play / pause Spotify", "osascript -e 'tell app \"Spotify\" to playpause'"),
            ("Next track", "osascript -e 'tell app \"Spotify\" to next track'"),
        ]),
    ]
}
