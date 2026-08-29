import AppKit
import SwiftUI

/// The "?" in the header: what to try when something is not working.
///
/// Written from the failures that have actually happened with this deck, in
/// the order they are worth trying — the first item is the one that has
/// bitten most, and it is a hardware fault no amount of clicking in here can
/// fix.
struct HelpPopover: View {
    @EnvironmentObject var deck: DeckController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                section("Keys do nothing when pressed", [
                    "**Unplug the deck and plug it back in.** This is the only cure. The app sees the replug and reconnects itself, so there is nothing to press.",
                    "The cause is the deck itself: when it is written to hard — which is what an animated GIF does — it stops reporting key presses entirely, and does not start again when the writing stops. Measured on this hardware: 87 presses registered while idle, zero during sustained image writes.",
                    "The app now paces its writes to avoid this. If you turned on **Smoother animation** in the Deck panel, turn it back off.",
                    "If a single key does nothing, check whether a widget covers it: a widget owns the presses of every key it paints.",
                ])

                section("The keys are blank or frozen", [
                    "Press **Push all** to redraw every key, or **Connect** to re-open the deck.",
                    "If writes have stalled the status turns red and says so. Same cure: replug — and the app comes back on its own once you do.",
                ])

                section("A key looks wrong", [
                    "**Reset key** puts one key back to defaults — colour, artwork, label, action and widget.",
                    "**Clear all keys** resets all fifteen, and can be undone.",
                ])

                section("Widgets", [
                    "Spotify says `no Spotify app` — install the Spotify desktop app, or set Source to your Spotify account.",
                    "Spotify says `allow access` — System Settings ▸ Privacy & Security ▸ Automation, and allow fifine Deck to control Spotify.",
                    "Stocks says `no API key` — paste a free Finnhub key into the widget editor.",
                    "Weather says `unknown place` — try a bigger nearby city, or coordinates like `48.85, 2.35`.",
                    "Calendar says `allow calendar` — System Settings ▸ Privacy & Security ▸ Calendars.",
                ])

                section("Run command", [
                    "Commands run in your login shell, so the PATH matches Terminal.",
                    "Use **Test** in the key editor to run it once and see the output before binding it.",
                    "A command needing `sudo` will not work: there is nowhere to type a password.",
                ])

                Divider().opacity(0.3)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Still stuck")
                        .font(.system(size: 11, weight: .semibold))
                    Text("The app keeps a log of presses it received and anything that failed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Reveal log in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([DeckLog.url])
                        }
                        .controlSize(.small)
                        Button("Reconnect") { deck.connect() }.controlSize(.small)
                        Button("Push all") { deck.pushAll() }.controlSize(.small)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 340, height: 460)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lifepreserver.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Troubleshooting").font(.system(size: 13, weight: .semibold))
                Text(deck.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func section(_ title: String, _ points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            ForEach(points, id: \.self) { point in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(Theme.accent)
                    Text(.init(point))          // markdown, for the bold bits
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
