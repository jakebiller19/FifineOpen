import AppKit
import Foundation

/// What a key does when pressed.
///
/// Deliberately minimal for now - this is the harness, not the feature set.
/// To add a new action: add a case, give it a `title`, and handle it in
/// `perform()`. `DeckController.handleKeyPress` already routes presses here.
enum KeyAction: Codable, Equatable {
    case none
    case openURL(String)
    case runCommand(String)

    var title: String {
        switch self {
        case .none:                 return "Nothing"
        case .openURL(let url):     return url.isEmpty ? "Open URL…" : "Open \(url)"
        case .runCommand(let cmd):  return cmd.isEmpty ? "Run command…" : "Run: \(cmd)"
        }
    }

    /// Runs the action. Called on the main queue after a key press.
    func perform() {
        switch self {
        case .none:
            break

        case .openURL(let string):
            guard !string.isEmpty else { break }
            let normalised = string.contains("://") ? string : "https://\(string)"
            guard let url = URL(string: normalised) else {
                DeckLog.write(String(format: "fifine: key URL %@ could not be parsed", normalised))
                break
            }
            // The result is checked rather than discarded: a URL macOS has no
            // handler for fails silently, which is indistinguishable from the
            // press never arriving.
            if !NSWorkspace.shared.open(url) {
                DeckLog.write(String(format: "fifine: nothing opened %@", normalised))
            }

        case .runCommand(let command):
            // Detached, through the user's login shell, and the outcome is
            // logged — see CommandRunner for why the shell matters.
            CommandRunner.run(command)
        }
    }
}
