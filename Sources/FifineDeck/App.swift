import AppKit
import SwiftUI

@main
struct FifineDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var deck = DeckController.shared

    var body: some Scene {
        WindowGroup("fifine Deck") {
            ContentView()
                .environmentObject(deck)
        }
    }
}

/// Running from a SwiftPM executable there is no app bundle, so the process
/// starts as a background agent with no menu bar and no focusable window.
/// Promoting it to a regular app fixes both.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A heartbeat at launch, so it is possible to tell "the app logged
        // nothing because nothing happened" from "the app's logging is not
        // reaching the console at all".
        DeckLog.write(String(format: "fifine: launched — %@", Bundle.main.bundlePath))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        menuBar.install()

        // The design is dark end to end — the deck's faces, the cards, the
        // grid. Following the system into light mode gave the app a white
        // titlebar bolted onto dark content.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // The window exists only after the first run loop pass.
        DispatchQueue.main.async { [weak self] in
            if let window = NSApp.windows.first {
                Self.style(window)
                self?.menuBar.attach(window: window)
            }
        }
    }

    /// Makes the window an actual glass panel.
    ///
    /// `NSVisualEffectView` with `.behindWindow` blending blurs what is behind
    /// the WINDOW — which does nothing at all while the window itself is
    /// opaque, and that is why the app looked flat despite having a vibrancy
    /// view in it since day one.
    private static func style(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        // NOT movableByWindowBackground: the grid's keys are dragged to
        // rearrange them and a widget is resized by dragging its corner, and
        // window-background dragging competes with both. The transparent
        // titlebar strip still moves the window.
        window.isMovableByWindowBackground = false
    }

    /// Closing the window leaves the app running in the menu bar, still
    /// driving the deck. Quit from the menu bar item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.setActivationPolicy(.regular)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Leave the deck in a clean state rather than mid-frame.
    func applicationWillTerminate(_ notification: Notification) {
        DeckController.shared.disconnect()
    }
}
