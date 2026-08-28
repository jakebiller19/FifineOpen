# fifine Deck (macOS)

A small native Swift/SwiftUI app for the **fifine D6** macro keypad
(USB `3142:0007`, 15 keys in 3 rows of 5).

Set a colour, a custom image, and a label per key. Key presses are wired to a
minimal action harness that is deliberately bare — that is where richer actions
get added later.

> **macOS only, by necessity.** The deck is a USB HID device and `IOHIDManager`
> is a macOS API. iOS exposes no public API for arbitrary USB HID devices, so an
> iOS build is not possible.

## Build & run

```sh
./build_app.sh          # produces FifineDeck.app
open FifineDeck.app
```

To see logs while it runs:

```sh
./FifineDeck.app/Contents/MacOS/FifineDeck
```

Requires macOS 13+ and a Swift toolchain (Xcode or the Command Line Tools).
The app connects on launch; **Connect** re-scans if the deck was plugged in late.

## Using it

- **Click a key** in the grid to select it.
- **Background** — colour picker; the key updates on the deck immediately.
- **Label** — text drawn over the key, with a shadow so it stays readable.
- **Image** — scaled to cover the key, cropped square.
- **GIF** — an animated GIF on a single key (see *Animation* below).
- **On press** — the action harness.
- **Brightness** — slider, applies to the whole deck.
- **Push all** — re-sends every key, ignoring the diff cache.

Settings persist to `~/Library/Application Support/FifineDeck/settings.json`.

## Menu bar & background running

The app installs a menu bar item, and its icon reports the state at a glance:

| Icon | Meaning |
|---|---|
| filled 3x3 grid | connected and driving the deck |
| outline 3x3 grid | no deck found |
| warning triangle | deck stalled - replug it |

The menu opens with a **live thumbnail of all fifteen keys** — the same widget
tiles, artwork and labels the editor shows, updating while the menu is open, so
a now-playing widget ticks over in the menu as it does on the deck. Click it to
open the window.

**Closing the window does not quit the app.** It hides the window, drops the
Dock icon, and keeps driving the deck from the menu bar - so patterns, GIFs and
key actions carry on. The menu offers *Show Deck Window*, *Reconnect*, *Push All
Keys*, and *Quit*; clicking the Dock icon also brings the window back.

Quit properly from the menu bar item (or Cmd-Q with the window focused); the app
disconnects cleanly on the way out rather than leaving the deck mid-frame.

## Deck patterns

The **Deck** picker treats all 15 keys as one surface rather than 15 separate
ones. Two kinds:

*Continuous* — a 500×300 canvas is painted, then sliced into keys, so the
image flows across the whole deck:

- **Linear gradient**, **Radial gradient** — between the two chosen colours
- **Rainbow** — full hue sweep left to right
- **Image across deck** — one picture spread over all 15 keys

*Animated* — a colour per key, driven by a clock:

- **Scanner** — a bright column sweeping back and forth
- **Wave** — a diagonal travelling wave
- **Pulse** — the whole deck breathing together
- **Comet** — a head running the keys in order with a fading tail

A pattern overrides the individual key settings while it is active. Selecting
**Per-key** hands control back.

## Live widgets

A key can show something live instead of a static picture — what Spotify is
playing, or a stock ticker — and a widget can spread across a **block of keys**
rather than just one. Pick a widget in the key inspector, then set its size in
columns × rows.

A widget is configured on one key and paints a rectangle from there, as one
picture cut into tiles (the same path "Image across deck" uses, so it lands on
the hardware the same way). The span **clips at the edge of the deck** instead
of wrapping onto the next row, and **shrinks rather than overlapping** another
widget, so a widget can be dropped on any key. Keys a widget covers keep their
own colour, label, artwork and action in `settings.json` and get them straight
back when the widget shrinks; while covered, pressing any of them acts on the
widget.

Widgets refresh on their own 0.5 s clock, separate from the animation clock, and
fetch off the main thread — a slow or unreachable service delays neither
keypresses nor a running pattern. When something is wrong the widget says so on
the key (`offline`, `rate limited`, `no API key`, `not logged in`) rather than
going blank.

### Spotify

| Setting | What it does |
|---|---|
| Layout | `Automatic`, or force one of: album art · art and text · **art + info panel** · art and progress · text only · **one control button** · **transport bar** |
| Source | Spotify on this Mac, your Spotify account, or automatic |
| On press | play/pause, next, previous, or nothing — drawn on the key as a transport badge |
| Refresh | seconds between polls (1 s minimum) |

**Art + info panel** is what `Automatic` picks for a wide block: a square of
album art filling as many whole keys as it can, beside a panel with the title,
artist, album, progress bar and times — so a 4×2 widget is a 2×2 cover next to
a 2×2 panel, and a 5×3 is a 3×3 cover next to a 2×3 panel. Type scales with the
panel rather than with one key, so a bigger widget genuinely reads bigger.

**Controls can be keys in their own right.** *One control button* turns the
whole widget into a single transport key — drop it on a key, set *On press*,
done. *Transport bar* goes further and gives **each key its own control**
(previous · play/pause · next) across the span, ignoring *On press* entirely.
Keys that share a button repeat its glyph rather than stretching one across
them: the deck's keys are physically separate, and a pause symbol split down
the gap reads as a fault. The glyph a key shows and the action it runs come
from the same function, so they cannot disagree.

The **Presets** row in the editor is the fast way in: *Now playing* (4×2),
*Big art* (2×2), *Transport bar* (3×1), *Play/pause key*, *Next-track key*.

**Spotify on this Mac** is the default and needs no credentials: it asks the
Spotify desktop app what is playing, over Apple Events. It does need that app
to be **installed** — a `tell application "Spotify"` block is compiled against
the app's scripting dictionary, so without it the script does not even compile.
macOS also asks for permission the first time ("fifine Deck wants to control
Spotify"), and because the app is ad-hoc signed that prompt can come back after
a rebuild.

The corner badge says what **pressing** the key does, not what is happening:
▶ means "press to play", ❚❚ means "press to pause", ⏭ / ⏮ skip. Its ring is
tinted with the album's accent colour while playing and grey while paused, so
one element carries both the action and the state. Set *On press* to *Nothing*
and the badge is replaced by a plain state dot. The stock ticker gets the same
badge — an arrow — when a press cycles to the next page of symbols.

What the key says when it cannot read the local app:

| On the key | Meaning |
|---|---|
| `no Spotify app` | the desktop app is not installed |
| `allow access` | Automation permission denied — System Settings → Privacy & Security → Automation |
| `connect account` | no desktop app *and* no account connected |
| `script failed` | something else; the detail is in `NSLog` |

**Your Spotify account** follows playback on *any* device — a phone, a
speaker — and needs a one-off login. Create a free app at
[developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), add
`http://127.0.0.1:8888/callback` as a redirect URI, then paste its client id
into the widget editor and press **Connect Spotify…**. The login uses PKCE, so
no client secret is stored — only a refresh token.

### Clock

Digital, analog or a date face; `Automatic` picks the analog face for a square
block. Set a time zone (`Europe/Paris`) for a world clock and leave it blank
for this Mac. The refresh interval doubles as the seconds hand: under 5 s the
face shows seconds.

### Weather

| Setting | What it does |
|---|---|
| Place | a city (`London`) or explicit coordinates (`48.85, 2.35`) |
| Units | °C or °F |

[Open-Meteo](https://open-meteo.com) — **no API key, no account**. A place name
is geocoded once and cached, so a widget costs one lookup ever plus one small
forecast call per refresh. The face is tinted cold-blue to hot-red by the
actual temperature, so it reads before you do.

### System monitor

CPU, memory, network, disk and battery, read from the kernel rather than by
shelling out to `top` — sampling through a subprocess every two seconds would
cost more CPU than it reports on. List several (`cpu, memory, disk`) and each
gets a key; list more than the span holds and they become pages. Memory is
what Activity Monitor calls used, not "free", which on macOS is always near
zero and alarms people for no reason.

### Sports scores

Live scores from ESPN's public scoreboard — again no key. Pick a league (NFL,
NBA, MLB, NHL, and the main soccer leagues) and optionally filter to your teams
(`SF, KC`). Live games sort first, then upcoming, then finished, and a live
game gets a green pip.

### Timer

A countdown you drive from the deck: press to start and pause, again to resume,
and it chimes at zero. Green running, amber paused, red done. `ring` draws the
remaining time as an arc; `digits` is a plain clock for one key.

### Next calendar event

The next thing in your calendar, tinted with that calendar's own colour, going
amber inside ten minutes and red once it has started. macOS asks for Calendar
access the first time. The `agenda` style fills a taller widget with what
follows.

### Stocks

| Setting | What it does |
|---|---|
| Symbols | comma separated (`AAPL, MSFT, NVDA`); crypto works too (`BINANCE:BTCUSDT`) |
| Layout | Cards (symbol, price, change, sparkline), Compact, or one Big chart |
| Rotate | seconds between pages when you list more symbols than keys (0 = off) |
| On press | next page of symbols, or nothing |

One symbol per key: a 3×2 stock widget shows six tickers. List more than the
span holds and the extras become pages. Quotes come from
[Finnhub](https://finnhub.io)'s free tier, so it needs an API key — paste it
into the widget editor. One quote cache is shared by the whole deck, and no
symbol is re-requested more than once every 5 seconds however many widgets
watch it.

### Credentials

Three sources, first hit wins:

1. **the environment** — `FINNHUB_KEY` (or `FINNHUN`), `SPOTIFY_CLIENT_ID`,
   `SPOTIFY_REFRESH_TOKEN`. Persists nothing:

   ```sh
   FINNHUB_KEY=… ./FifineDeck.app/Contents/MacOS/FifineDeck
   ```

2. **`~/Library/Application Support/FifineDeck/widgets.json`**, mode `0600` —
   what the key editor writes when you press Save.

3. **a `.env` file**, for sharing one file with whatever scripts already read
   it. Put it next to `FifineDeck.app` (that is, in this folder):

   ```
   FINNHUB_KEY=…        # FINNHUN is accepted too
   SPOTIFY_CLIENT_ID=…
   ```

   Searched in order: `$FIFINE_DECK_ENV`, then `.env` walking up from the app
   bundle (four levels, which covers both `FifineDeck.app` and the bare
   `.build/release` binary), then the working directory, then the Application
   Support folder. Resolved from the app's own location, not the working
   directory — launched from Finder that is `/`. **Reload** in the widget
   editor re-reads it without a relaunch, and the editor says which source a
   key came from.

`widgets.json` deliberately beats `.env`, so pressing Save always takes effect.
None of this is in `settings.json`: that file is the deck layout — the thing
you would copy to another machine — and it must never carry a token with it.
`.gitignore` excludes `.env` for the same reason.

## Adding a widget

One file. `WidgetProviding` is four methods — placeholder, fetch, press, draw —
and `WidgetRegistry` maps a kind to its provider. Nothing else in the app knows
what a Spotify widget is; the controller only knows about signatures, spans and
tiles.

`WidgetSnapshot` carries an opaque payload rather than a field per kind,
precisely so that adding the eighth widget did not mean giving every provider
sight of the other seven's data.

## Editing the grid

- **Click** a key to select it.
- **Drag** a key onto another to swap their entire configuration — colour,
  artwork, label, action and any widget. Dropping onto an occupied key swaps
  rather than overwrites: the displaced key has to go somewhere, and anywhere
  but the slot you just vacated is a surprise.
- **Drag the round handle** on the bottom-right key of a selected widget to
  resize its span a key at a time. It clamps at the edge of the deck.
- Keys a widget paints share a faint outline, so a span is visible at a glance.
- **GIF keys animate in the grid**, cropped the way the deck crops them, with a
  small corner marker. SwiftUI's `Image` renders only a GIF's first frame, so
  the preview drops to an `NSImageView`, which animates one natively — inside a
  layer-backed container that does the clipping, because a SwiftUI `clipShape`
  does **not** clip a hosted AppKit view and an oversized GIF otherwise draws
  straight over the keys next to it.
- **Clear all keys** (in the *Deck* card) resets all fifteen. It snapshots the
  layout to `settings-backup.json` first and offers **Undo** — which is itself
  undoable, so restoring onto the wrong layout is not a one-way door either.

## Animation and throughput

Measured on real hardware — these numbers drove the design:

| | rate |
|---|---|
| Full 15-key repaint | ~1.9 fps (516 ms) |
| Single key | ~15 fps (69 ms) |

The bottleneck is **per-write latency** (~11 ms per 512-byte report), not
bandwidth: JPEG quality made no measurable difference. Two consequences:

1. **Only changed keys are sent.** `DeckController` caches the last JPEG per
   key and diffs against it. Effects like Scanner and Comet touch a handful of
   keys per frame, so they stay smooth; a full-deck colour cycle cannot.
2. **Frames are dropped, never queued.** A frame is skipped while the previous
   one is still draining, so the animation degrades in smoothness instead of
   building an unbounded backlog. The live rate is shown next to the status.

### Writing hard stops the deck reporting key presses

Measured on hardware, and the single most important thing to know about this
device:

| Phase (40 s each) | Presses registered |
|---|---|
| idle | **87** |
| saturated with image writes | **0** |
| idle again | **0** — it never came back |

Saturating the OUT endpoint kills the IN endpoint, permanently, until a
physical replug. Since animation means writing continuously, an unpaced GIF
costs you every button on the deck.

So the app **paces its writes**: every batch of key images is followed by idle
time proportional to its size (`D6Device.pacingPerKey`), and the animation
clock runs at 4 fps rather than the 15 the bus would carry. **Smoother
animation** in the Deck panel raises that, and says plainly what it risks.

If your keys have gone dead: unplug, replug, press Connect.

**GIFs are software-driven.** The protocol carries still JPEGs only — there is
no hardware GIF support. A GIF is decoded at load time, each frame pre-rendered
to a key-ready JPEG, then streamed. Per-frame delays from the GIF metadata are
honoured, clamped to the 15 fps ceiling. Long GIFs are sampled evenly down to
90 frames so the whole loop is represented rather than truncated. Best on one
or two keys; every animated key shares the same budget.

## The protocol

The D6 does **not** speak the Stream Dock 293V3 command set that most open
source tooling emits. Sending it a 293V3 image write before any handshake makes
its firmware stall the USB OUT endpoint: the first write reports success, every
later one fails with `IOHIDDeviceSetReport ... I/O Timeout (0xE00002D6)`, and
only a physical replug clears it.

The real format was recovered by interposing `IOHIDDeviceSetReport` on the
vendor's own macOS app. Every packet is exactly 512 bytes, sent as an Output
report with report id 0:

```
"CRT\0\0" + <command> + params at fixed offsets, zero padded

DIS                       reset / disconnect
CONNECT                   handshake
LIG    [10]    = level    brightness 0..100
CLE    [11]    = key      clear key; 0xFF clears all
QUCMD  [10:16] = 1f 11 00 11 00 11
BAT    [10:12] = len BE16, [12] = hardware key
                          key image header; raw JPEG follows in 512-byte chunks
STP                       commit / refresh
```

The opening handshake is `DIS → LIG → QUCMD → LIG → CLE`, and it is **not
optional** — skipping it is what wedges the endpoint.

Verified on hardware:

- key images are **100 × 100** JPEG,
- rotated **180°** (the panels are mounted upside-down),
- hardware key indices run **bottom-up**: hardware key 1 is the *bottom-left*
  key, while the on-screen grid counts from the top-left.

## Layout

```
Sources/FifineDeck/
  App.swift             @main entry + AppDelegate
  ContentView.swift     the whole UI
  DeckController.swift  key state, persistence, connection
  D6Device.swift        IOKit HID transport
  D6Protocol.swift      packet construction + key layout
  KeyImage.swift        renders a key to the JPEG the deck wants
  KeyAction.swift       the press-action harness
  DeckCanvas.swift      full-deck canvas + slicing into key tiles
  DeckPattern.swift     whole-deck patterns, static and animated
  GifPlayer.swift       GIF decoding + frame pre-rendering
  Widget.swift          widget config + the multi-key span layout
  WidgetRuntime.swift   provider cache, frame painting, tile slicing
  WidgetPaint.swift     drawing helpers for widget frames
  WidgetEditor.swift    the widget section of the key inspector
  WidgetCredentials.swift  API keys and tokens (env / widgets.json / .env)
  SpotifyWidget.swift   now-playing data (Apple Events / Web API) + faces
  SpotifyAuth.swift     one-off PKCE login on a loopback listener
  StocksWidget.swift    Finnhub quotes + ticker faces
Tests/FifineDeckTests/  span layout, config validation, rendering
build_app.sh            builds FifineDeck.app
Info.plist              bundle metadata
```

Run the tests with `swift test`. They cover the span layout, config validation
and that every widget face renders at the size it claims; nothing in them
touches the network, the deck, or the credentials file.

## Key actions

Three, and any key can carry one **regardless of its artwork** — a GIF key is
still a button:

| Action | What it does |
|---|---|
| Nothing | the key is decoration |
| Open URL | opens it in your default browser; a bare `example.com` gets `https://` |
| Run command | runs a shell command |

**Run command** runs through your **login shell** (`$SHELL -l -c`), not a bare
`/bin/sh`. An app launched from Finder inherits a minimal PATH, so anything
from Homebrew, mise or a dotfile would simply not be found and the key would
silently do nothing. A login shell sources the same profile Terminal does, so
a command that works when you type it works here.

- **Examples** in the key editor fills in ready-made commands — lock the
  screen, mute, screenshot, toggle dark mode, empty the Trash, open an app.
  Every one is a stock macOS binary.
- **Test** runs it once and shows the exit status and output, so you find out
  that something is missing from PATH *before* binding the key.
- It is detached, so a slow command never blocks the deck, and failures are
  written to the log with their exit status.
- `sudo` will not work: there is nowhere to type a password.

The only thing that takes a press away from a key is a **widget** covering it.

To add an action type: add a case to `KeyAction`, give it a `title`, handle it
in `perform()`, and add it to the picker in `ActionEditor`. `pressTarget(_:)`
on the controller answers "what will this key do" without a deck attached,
which is what the tests assert against.

## Getting unstuck

The **?** in the header opens a troubleshooting panel, and the app keeps a log
at `~/Library/Application Support/FifineDeck/debug.log` recording every press
it received and anything that failed.

The one to know: **if keys stop responding while the displays keep updating,
the deck has stopped sending input.** Unplug it and plug it back in. That is a
fault in the deck — the same stall that afflicts its write endpoint — and no
software change recovers it.

## Known gaps

- No profiles, pages, or folders. One page, 15 keys.
- Widgets are polled, not pushed: a track change shows up on the next refresh,
  not the instant it happens.
- Hotplug is not detected; press **Connect** after replugging.
- Full-deck animation is capped by the hardware at ~2 fps, so smooth effects
  have to be ones that change only a few keys per frame.
- Only one GIF plays comfortably at a time; several share the same write budget.

Key presses **are** confirmed working on hardware (`"ACK"`-prefixed input
report, hardware key at byte 9, state at byte 10 — decoded in
`D6Device.handleInput`).

## Key press mapping

Presses and images use **different** addressing, which is easy to get wrong:

- **Images** are addressed bottom-up — hardware key 1 is the *bottom-left* key
  (`DeckLayout.hardwareKey(forGridIndex:)`).
- **Presses** arrive in plain reading order — code 1 is the *top-left* key
  (`DeckLayout.gridIndex(forHardwareKey:)` is identity).

Applying the image flip to input as well double-maps it and swaps rows 1-5 with
11-15, so the bottom-left key fires the top-left key's action.
