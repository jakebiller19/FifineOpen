import AppKit
import Foundation

/// What a now-playing face needs, whoever is playing it.
///
/// The renderer used to take a `SpotifyNowPlaying`, so VLC grew a parallel set
/// of faces — and the two immediately disagreed about what a 3x2 widget should
/// look like, because each was choosing its own layout. One value type means
/// one renderer, one set of `auto` rules, and no way for them to diverge.
struct NowPlayingFace {
    var ok = false
    var playing = false
    var title = ""
    var artist = ""
    var album = ""
    var progressMS = 0
    var durationMS = 0
    var art: CGImage? = nil
    var accent: NSColor = WidgetPaint.green

    var error = ""
    /// What the "cannot reach it" face says, and its colour. The only thing
    /// about a face that is allowed to know which player it came from.
    var brand = "Spotify"
    var brandTint: NSColor = WidgetPaint.green

    var hasTrack: Bool { !title.isEmpty || !artist.isEmpty }
}

extension SpotifyNowPlaying {
    var face: NowPlayingFace {
        NowPlayingFace(ok: ok, playing: playing, title: title, artist: artist, album: album,
                       progressMS: progressMS, durationMS: durationMS, art: art, accent: accent,
                       error: error, brand: "Spotify", brandTint: WidgetPaint.green)
    }
}

extension VLCState {
    /// VLC counts in seconds and calls the title something else when there is
    /// no metadata; the face wants milliseconds and one title.
    var face: NowPlayingFace {
        NowPlayingFace(ok: ok, playing: playing, title: displayTitle, artist: artist, album: album,
                       progressMS: time * 1000, durationMS: length * 1000, art: art, accent: accent,
                       error: error, brand: "VLC",
                       brandTint: NSColor(srgbRed: 0.95, green: 0.51, blue: 0.11, alpha: 1))
    }
}

/// Whichever of Spotify or VLC is actually playing.
///
/// Composed rather than reimplemented: it asks the two existing providers and
/// picks one, then hands the drawing and the press straight back to whichever
/// won. So the faces, the album art and the transport are the same code the
/// single-source widgets use, and a fix to either shows up here for free.
///
/// The point is that a key stops being "the Spotify key" or "the VLC key" and
/// becomes "the music key".
struct NowPlaying {
    enum Source: String, Equatable {
        case spotify, vlc, none
    }

    var source: Source = .none
    var spotify: SpotifyNowPlaying? = nil
    var vlc: VLCState? = nil

    /// The chosen source leads the signature, so switching sources always
    /// repaints even if the two happened to be showing similar text.
    var signature: String {
        switch source {
        case .spotify: return "spotify|" + (spotify?.signature ?? "")
        case .vlc:     return "vlc|" + (vlc?.signature ?? "")
        case .none:    return "none"
        }
    }
}

actor NowPlayingProvider: WidgetProviding {
    private let spotify = SpotifyProvider()
    private let vlc = VLCProvider()

    /// When each source's CURRENT track started, as far as we can tell — the
    /// first time we saw it. Used to break the tie when both are playing.
    private var startedAt: [NowPlaying.Source: Date] = [:]
    private var identity: [NowPlaying.Source: String] = [:]
    /// What was on the key last time, so a pause does not make it flip.
    private var previous: NowPlaying.Source = .none

    nonisolated func placeholder(_ config: WidgetConfig, cells: Int) -> WidgetSnapshot {
        WidgetSnapshot(signature: "nowplaying:placeholder", payload: NowPlaying())
    }

    func fetch(_ config: WidgetConfig, cells: Int) async -> WidgetSnapshot {
        // Concurrently: one unreachable machine must not delay the other
        // source by a whole timeout.
        async let spotifyState = spotify.fetch(config, cells: cells)
        async let vlcState = vlc.fetch(config, cells: cells)
        let spotifyNow: SpotifyNowPlaying? = await spotifyState.data()
        let vlcNow: VLCState? = await vlcState.data()

        note(.spotify, identity: spotifyNow.map { "\($0.title)|\($0.artist)|\($0.album)" } ?? "")
        note(.vlc, identity: vlcNow?.trackIdentity ?? "")

        let chosen = Self.choose(spotifyPlaying: spotifyNow?.playing ?? false,
                                 spotifyHasTrack: spotifyNow?.hasTrack ?? false,
                                 vlcPlaying: vlcNow?.playing ?? false,
                                 vlcHasTrack: vlcNow?.hasTrack ?? false,
                                 spotifyStarted: startedAt[.spotify],
                                 vlcStarted: startedAt[.vlc],
                                 previous: previous)
        previous = chosen
        let now = NowPlaying(source: chosen, spotify: spotifyNow, vlc: vlcNow)
        return WidgetSnapshot(signature: "nowplaying|" + now.signature, payload: now)
    }

    /// Remembers when a source's track last changed.
    private func note(_ source: NowPlaying.Source, identity newIdentity: String) {
        guard !newIdentity.isEmpty else {
            identity[source] = ""
            startedAt[source] = nil
            return
        }
        if identity[source] != newIdentity {
            identity[source] = newIdentity
            startedAt[source] = Date()
        }
    }

    /// Which source the key shows. Pure, so the rules can be tested without a
    /// Spotify or a VLC.
    ///
    /// 1. Actually playing wins — that is the whole question being asked.
    /// 2. Both playing: the one that started most recently, because starting
    ///    something is how you say which one you meant.
    /// 3. Neither playing: whatever was already on the key keeps it, so
    ///    pausing does not make the face jump to the other source. Then
    ///    whichever has a track at all.
    static func choose(spotifyPlaying: Bool, spotifyHasTrack: Bool,
                       vlcPlaying: Bool, vlcHasTrack: Bool,
                       spotifyStarted: Date?, vlcStarted: Date?,
                       previous: NowPlaying.Source) -> NowPlaying.Source {
        if spotifyPlaying && vlcPlaying {
            let s = spotifyStarted ?? .distantPast
            let v = vlcStarted ?? .distantPast
            return v > s ? .vlc : .spotify
        }
        if spotifyPlaying { return .spotify }
        if vlcPlaying { return .vlc }

        if previous == .spotify, spotifyHasTrack { return .spotify }
        if previous == .vlc, vlcHasTrack { return .vlc }
        if spotifyHasTrack { return .spotify }
        if vlcHasTrack { return .vlc }
        return .none
    }

    // MARK: Press

    /// Both transport bars map a column to the same three buttons, so this
    /// answers without needing to know which source is showing.
    nonisolated func action(for config: WidgetConfig, cell: WidgetCell) -> String {
        SpotifyWidgetRenderer.pressAction(config: config, cell: cell)
    }

    /// Routed to whatever the key is currently showing — which is what makes
    /// one key able to drive either player.
    func press(_ config: WidgetConfig, cell: WidgetCell, snapshot: WidgetSnapshot) async -> Bool {
        guard let now: NowPlaying = snapshot.data() else { return false }
        switch now.source {
        case .spotify:
            guard let state = now.spotify else { return false }
            return await spotify.press(config, cell: cell,
                                       snapshot: WidgetSnapshot(signature: "", payload: state))
        case .vlc:
            guard let state = now.vlc else { return false }
            return await vlc.press(config, cell: cell,
                                   snapshot: WidgetSnapshot(signature: "", payload: state))
        case .none:
            return false
        }
    }

    // MARK: Draw

    @MainActor
    func draw(_ snapshot: WidgetSnapshot, config: WidgetConfig,
              columns: Int, rows: Int, background: NSColor, ctx: CGContext) {
        let now: NowPlaying = snapshot.data() ?? NowPlaying()
        switch now.source {
        case .spotify:
            SpotifyWidgetRenderer.draw(now.spotify?.face ?? NowPlayingFace(), config: config,
                                       columns: columns, rows: rows,
                                       background: background, ctx: ctx)
        case .vlc:
            SpotifyWidgetRenderer.draw(now.vlc?.face ?? NowPlayingFace(), config: config,
                                       columns: columns, rows: rows,
                                       background: background, ctx: ctx)
        case .none:
            let frame = CGRect(x: 0, y: 0,
                               width: CGFloat(DeckLayout.keyPixels * columns),
                               height: CGFloat(DeckLayout.keyPixels * rows))
            WidgetPaint.message("Music", "nothing playing", frame: frame, ctx: ctx,
                                tint: WidgetPaint.muted)
        }
    }
}
