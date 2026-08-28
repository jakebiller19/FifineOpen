import AppKit
import SwiftUI

/// A thumbnail of the whole deck, for the menu bar.
///
/// Deliberately a separate view from the editor's grid rather than that grid
/// shrunk: at 30pt a key has no room for a selection ring, a drop highlight or
/// a resize handle, and every one of those would be noise in a menu. It shows
/// the same three sources the real grid does — widget tiles, artwork, labels —
/// so what you see here is what is on the deck.
struct DeckMiniGrid: View {
    @ObservedObject var deck: DeckController

    var side: CGFloat = 30
    var spacing: CGFloat = 3
    var padding: CGFloat = 10
    /// Called when the grid is clicked, so the menu can open the window.
    var onTap: (() -> Void)? = nil

    /// The exact size the hosting view needs. NSMenuItem views are not laid
    /// out for you — a wrong number here clips the grid or leaves a gap.
    static func size(side: CGFloat = 30, spacing: CGFloat = 3,
                     padding: CGFloat = 10) -> CGSize {
        CGSize(width: CGFloat(DeckLayout.columns) * side
                    + CGFloat(DeckLayout.columns - 1) * spacing + padding * 2,
               height: CGFloat(DeckLayout.rows) * side
                    + CGFloat(DeckLayout.rows - 1) * spacing + padding * 2)
    }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<DeckLayout.rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<DeckLayout.columns, id: \.self) { column in
                        let index = row * DeckLayout.columns + column
                        MiniKey(config: deck.keys[index],
                                widgetImage: deck.widgetPreview(index),
                                side: side)
                    }
                }
            }
        }
        .padding(padding)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .help("Click to open the deck window")
    }
}

private struct MiniKey: View {
    let config: KeyConfig
    let widgetImage: NSImage?
    let side: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                .fill(config.color)
            if let face {
                Image(nsImage: face)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
            }
            if !config.label.isEmpty, widgetImage == nil {
                Text(config.label)
                    .font(.system(size: side * 0.24, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(1)
            }
        }
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    /// What this key is showing, in the same precedence the deck uses: a
    /// widget owns the face, then a GIF's first frame, then still artwork.
    private var face: NSImage? {
        if let widgetImage { return widgetImage }
        if let path = config.gifPath { return GifPreview.image(path) }
        return config.image
    }
}
