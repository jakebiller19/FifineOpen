import Foundation
import ServiceManagement

/// "Open at login", through `SMAppService`.
///
/// A deck that only lights up while an app someone remembered to start is
/// running is the wrong default for something that lives in the menu bar —
/// this is the one setting that decides whether the keys work after a reboot.
///
/// Deliberately NOT stored in `settings.json`. That file is the deck layout,
/// the thing you copy to another Mac, and whether *this* Mac starts the app at
/// login is not part of it. The system is the only source of truth here, so it
/// is asked every time rather than mirrored.
enum LoginItem {
    /// A bare SwiftPM binary has no bundle to register, and `register()` on
    /// one fails with an error that reads like a permissions problem. Worth
    /// telling apart, because running the binary directly is the documented
    /// way to watch the app's logs.
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turns it on or off. Returns a message to show the user, or nil when it
    /// worked — including the "approve it in System Settings" case, which is
    /// not a failure but does need saying.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard isSupported else {
            return "Only the built app can open at login — this is running as a bare binary."
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            DeckLog.write("fifine: login item \(enabled ? "register" : "unregister") failed: \(error)")
            return error.localizedDescription
        }
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            return "Allow “fifine Deck” in System Settings → General → Login Items."
        }
        return nil
    }
}
