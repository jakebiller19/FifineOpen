import AppKit
import Combine
import SwiftUI

/// The menu bar item: shows the deck is running, and keeps it reachable once
/// the window is closed.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private weak var window: NSWindow?

    private var deck: DeckController { .shared }

    // MARK: - Setup

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = icon(for: .disconnected)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "fifine Deck"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // Repaint the icon whenever the connection state changes.
        deck.$connected
            .combineLatest(deck.$stalled)
            .receive(on: RunLoop.main)
            .sink { [weak self] connected, stalled in
                guard let self else { return }
                let state: State = stalled ? .stalled : (connected ? .connected : .disconnected)
                self.statusItem?.button?.image = self.icon(for: state)
                self.statusItem?.button?.image?.isTemplate = (state != .stalled)
            }
            .store(in: &cancellables)
    }

    /// Takes over the main window so closing it hides the app instead of
    /// quitting it. The deck keeps being driven in the background.
    func attach(window: NSWindow) {
        self.window = window
        window.delegate = self
    }

    // MARK: - Icon

    private enum State { case connected, disconnected, stalled }

    private func icon(for state: State) -> NSImage? {
        let name: String
        switch state {
        case .connected:    name = "square.grid.3x3.fill"
        case .disconnected: name = "square.grid.3x3"
        case .stalled:      name = "exclamationmark.triangle.fill"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: "fifine Deck")
    }

    // MARK: - Menu

    /// Rebuilt on every open so the status line is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(gridItem(in: menu))
        menu.addItem(.separator())

        let status = NSMenuItem(title: deck.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if deck.connected && !deck.stalled {
            let pattern = NSMenuItem(title: "Pattern: \(deck.pattern.rawValue)",
                                     action: nil, keyEquivalent: "")
            pattern.isEnabled = false
            menu.addItem(pattern)
        }

        menu.addItem(.separator())
        menu.addItem(withTitleAndAction("Show Deck Window", #selector(showWindow)))
        menu.addItem(withTitleAndAction("Reconnect", #selector(reconnect)))
        menu.addItem(withTitleAndAction("Push All Keys", #selector(pushAll)))
        menu.addItem(.separator())

        // Here as well as in the window: the app is usable with the window
        // closed, and this is the setting that decides whether it is running
        // at all after a reboot.
        let login = withTitleAndAction("Open at Login", #selector(toggleOpenAtLogin))
        login.state = deck.openAtLogin ? .on : .off
        login.isEnabled = deck.canOpenAtLogin
        menu.addItem(login)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit fifine Deck",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// A live thumbnail of the deck at the top of the menu.
    ///
    /// Hosted rather than drawn: the SwiftUI view observes the controller, so
    /// it keeps updating while the menu is open — a Spotify widget ticks over
    /// in the menu exactly as it does on the deck.
    private func gridItem(in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        let size = DeckMiniGrid.size()
        let grid = DeckMiniGrid(deck: deck) { [weak self, weak menu] in
            // Close the menu first: opening a window from inside menu tracking
            // leaves the menu up and the window behind it.
            menu?.cancelTracking()
            self?.showWindow()
        }
        let host = NSHostingView(rootView: grid)
        host.frame = CGRect(origin: .zero, size: size)
        item.view = host
        return item
    }

    private func withTitleAndAction(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func reconnect() { deck.connect() }

    @objc private func pushAll() { deck.pushAll() }

    @objc private func toggleOpenAtLogin() { deck.setOpenAtLogin(!deck.openAtLogin) }

    // MARK: - Window

    /// Hide rather than close, so the window can come back intact and the deck
    /// keeps running. Returning false stops AppKit destroying it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The window is where editing happens, so closing it is the natural
        // point to flush the coalesced settings write.
        deck.saveNow()
        sender.orderOut(nil)
        // Drop out of the Dock so it behaves like a menu bar app while hidden.
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}
