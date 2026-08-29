# fifine Deck (macOS)

A small native Swift/SwiftUI app for the **fifine D6** macro keypad
(USB `3142:0007`, 15 keys in 3 rows of 5).

The hardware: [FIFINE AmpliGame Stream Controller
(D6)](https://www.amazon.com/dp/B0D9JFT7JS) — the 15-key deck this drives.
It ships with the vendor's own Windows-first software; this is a native macOS
replacement for it, speaking the protocol recovered from that app.

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
The app connects on launch, and again by itself whenever the deck is plugged
in; **Connect** forces a re-scan.

### The icon

The app icon is **drawn in code**, not exported from a design tool:

```sh
swift Tools/make_icon.swift     # rewrites Resources/AppIcon.icns
```

It renders the deck itself — the real 5x3 key layout, lit by the same kind of
diagonal colour sweep the Rainbow and Wave patterns paint — from a single
description scaled to every slice `iconutil` wants, so the 16pt and 1024pt
versions cannot drift apart. The body is a superellipse rather than a rounded
rectangle, which is the shape macOS's own icons use; circular corners read as
pinched beside them.

`Resources/AppIcon.icns` is committed, so a build never depends on
re-rendering it; `build_app.sh` copies it into the bundle. Regenerate only
when the drawing changes.

## Using it

- **Click a key** in the grid to select it.
- **Background** — colour picker; the key updates on the deck immediately.
- **Gradient** — a switch, then a second colour and *Linear* or *Radial*.
  Flipping it on picks a second colour that already looks deliberate: away
  from the base towards black, or towards white when the base is dark enough
  that there is nowhere else to go. The on-screen grid and the menu bar
  thumbnail draw the same gradient the hardware gets, so the preview is a
  preview rather than an approximation.
- **Label** — text drawn over the key, with a shadow so it stays readable.
- **Image** — scaled to cover the key, cropped square.
- **GIF** — an animated GIF on a single key (see *Animation* below).
- **On press** — the action harness.
- **Brightness** — slider, applies to the whole deck.
- **Push all** — re-sends every key, ignoring the diff cache.

Settings persist to `~/Library/Application Support/FifineDeck/settings.json`.
Writes are **coalesced**: an edit lands about half a second after you stop
making it, so dragging the colour picker or the brightness slider does not put
a file write inside the drag loop. Quitting and closing the window both flush
first, so nothing is lost on the way out.

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

**Open at Login** is in the menu and in the *Deck* card. It is worth turning on:
the keys are blank until this app is running, so without it a reboot leaves you
with a dark deck. It goes through `SMAppService`, and the switch shows what the
system actually thinks — macOS can leave a registration waiting for approval in
System Settings, and the app says so rather than claiming it worked. The setting
is **not** in `settings.json`: that file is the deck layout, the thing you copy
to another Mac, and whether *this* Mac starts the app is not part of it.

## Plugging and unplugging

The app watches the bus, so it **connects itself** when the deck is plugged in
and notices when it is pulled out — no need to press **Connect**.

This matters most for the failure this deck actually has. A stalled deck can
only be recovered by unplugging it, and the app used to sit there telling you
so until you found the button; now the removal and the arrival are both seen
and it comes back on its own.

The watcher is observational: it never writes to the deck and never holds the
handle the rest of the app uses. Unplugging is also told apart from stalling —
tearing the connection down politely would write to a device that has just
gone, and three failed writes are exactly what the health check reads as the
stall, so an unplugged deck used to be reported as a broken one.

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

There is also an optional **account** source, for following playback on a
phone or a speaker rather than this Mac. It needs a one-off login and is the
only part of the Spotify widget that involves credentials at all; if you play
music on this Mac you will never touch it. `.env.template` says what it wants.

### VLC on the network

What another machine's VLC is playing, and the transport to drive it — a
Windows box, a media PC, a Mac in another room.

| Setting | What it does |
|---|---|
| Address | `192.168.1.10`, `media-pc:8080`, or a pasted `http://…` URL |
| Password | VLC's web-interface password — stored as a credential, never in `settings.json` |
| Layout | `Automatic`, or force one of: progress · text · one button · transport bar |
| On press | play/pause, next, previous, stop, or nothing |

`Automatic` gives a single key the play/pause button, a wide 1-row span the
transport bar (each key its own control), a wide-and-tall span the cover
beside an info panel, and anything else the title, artist and a progress bar.

The faces are deliberately the Spotify widget's: the same square-of-whole-keys
cover, the same tinted panel, and — literally the same function —
`WidgetPaint.progressBlock` for the bar and its timestamps. A deck showing
both players should not look like it was assembled from two apps, and sharing
the drawing is the only way to keep that true. A test fails if either face
starts drawing its own bar.

**Turn VLC's web interface on first** — it is off by default. On the machine
running VLC: Preferences → *Show settings **All*** → Interface → Main
interfaces → tick **Web**, then Main interfaces → **Lua** → set a password.
Restart VLC, and allow port 8080 through that machine's firewall. Put the
password in `VLC_PASSWORD` (or the widget editor); the address goes in the
widget, since only the password is a secret.

No agent to install on the other machine and no protocol to reverse: VLC's own
HTTP server answers `/requests/status.json` and takes `?command=pl_pause` on
the same URL. Its auth is HTTP Basic with an **empty user name** — sending one
is the usual reason a correct password still gets a 401.

VLC often reports no metadata at all: a file played off a disk gives a
filename and nothing else, so the filename (minus its extension) is the
fallback title. Radio streams are the other way round — the station is in
`title` and the song in `now_playing` — so those are swapped back.

What the key says when it cannot connect: `offline` (nothing answered — the
machine is asleep, VLC is closed, the interface was never enabled, or a
firewall ate it), `wrong password`, `no password`, `set the address`.

### Now playing (Spotify or VLC)

One key that is neither the Spotify key nor the VLC key, but **the music
key**: it asks both and shows whichever is actually playing, and a press acts
on whichever it is showing.

Composed rather than reimplemented — it calls the two existing providers and
hands the drawing and the press straight back to whichever won, so the faces,
the album art and the transport are the same code the single-source widgets
use. Set the VLC address the same way; Spotify needs nothing.

Which one it shows:

1. **Playing wins.** That is the question being asked, so a paused VLC never
   outranks a playing Spotify.
2. **Both playing → whichever started most recently.** Starting something is
   how you say which one you meant.
3. **Neither playing → whatever was already there keeps the key.** Otherwise
   pausing VLC would silently turn it into a Spotify key showing last night's
   album.
4. Then whichever has a track at all; then `nothing playing`.

The two are polled **concurrently**, so a sleeping media PC costs a timeout
rather than delaying Spotify behind it. Only the styles *both* renderers
understand are offered, and a test fails if that stops being true.

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

1. **the environment** — `FINNHUB_KEY` (or `FINNHUN`), `FAL_KEY`. Persists
   nothing:

   ```sh
   FINNHUB_KEY=… ./FifineDeck.app/Contents/MacOS/FifineDeck
   ```

2. **`~/Library/Application Support/FifineDeck/widgets.json`**, mode `0600` —
   what the key editor writes when you press Save.

3. **a `.env` file**, for sharing one file with whatever scripts already read
   it. Put it next to `FifineDeck.app` (that is, in this folder) — start from
   the committed template, which documents every key:

   ```sh
   cp -n .env.template .env     # -n: never clobber a .env you already have
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
`.gitignore` excludes `.env` for the same reason; `.env.template` is committed
because it holds no values.

### The keys, and which ones you actually need

| Key | Needed for | Where it comes from |
|---|---|---|
| **none** | **Spotify, the normal way** — reads the **Spotify desktop app for macOS** running on this Mac | nothing to set up |
| `FINNHUB_KEY` | the **Stocks** widget | [finnhub.io](https://finnhub.io), free tier |
| `FINNHUN` | the same thing | an alias for an older `.env`; set one, not both |
| `FAL_KEY` | **generated artwork** | [fal.ai](https://fal.ai) → Dashboard → Keys |
| `VLC_PASSWORD` | the **VLC on the network** widget | the password you set in VLC's web interface |
| `FIFINE_DECK_ENV` | pointing at a `.env` elsewhere | your shell, *not* the `.env` |

**Spotify needs no key** — that first row is the whole story. The widget talks to the
**Spotify desktop app for macOS** — it shells out to `osascript` and asks the
running app what is playing (`SpotifyProvider.localNowPlaying`). One Automation
prompt, no account, no API key, nothing to configure. `source: "auto"` finds
the app on its own.

(There is an optional account login for following a phone or a speaker instead.
It reads `SPOTIFY_CLIENT_ID` and `SPOTIFY_REFRESH_TOKEN`, both documented in
`.env.template`, and nothing else in the app depends on them.)

Everything else runs with no credentials at all: weather (Open-Meteo), sports
(ESPN), clock, timer, calendar and system monitor.

`FIFINE_DECK_ENV` is read from the environment, so putting it inside a `.env`
does nothing: the file has to be found before it can be read.

## Generated artwork

Type what you want on a key and it is drawn and on the hardware in about a
second — through [fal.ai](https://fal.ai)'s Ideogram v4 *instant* model. Set
`FAL_KEY` and a **Generate** field appears under *Artwork* in the key editor,
and under *Image across deck* in the Deck card. Without a key the field is
disabled and says so; nothing else changes.

Three directions, because a key is 100×100 and a metre away:

| | For |
|---|---|
| **Icon** | one bold symbol, flat background, no lettering — what survives key size |
| **Logo** | lettering, drawn large enough to read |
| **Art** | a free picture; best across the whole deck or on a widget-sized block |

What you type leads the prompt and the direction is appended, so "a red panda"
becomes a flat high-contrast icon rather than a photograph. Ideogram's own
**prompt expansion is off**: it rewrites what you typed, and measured against
this endpoint it cost 46 s against 0.3 s of actual inference — the instant
model stopped being instant.

**Icon and Logo results are re-framed after they arrive**, and this is not
left to the prompt. The model composes to fill its frame, so a subject comes
back touching an edge or pushed to one side however explicitly you ask for a
margin — and on a 100 px key that is the difference between a symbol and a
smudge. So the app finds the background colour from the border, takes the
bounding box of everything that is not it, and redraws that centred with an
even margin on the picture's own background. Deterministic: centred whatever
came back. An image with no margin anywhere is left alone (there is nothing to
measure against, and shrinking it would be a guess), and **Art** is exempt
because filling the frame is the point of it.

The request goes to fal's synchronous endpoint rather than its queue. A
generation is under a second, so submit-then-poll would spend longer in round
trips than in inference. A key asks for a 512² square; the deck asks for
1280×768, which is exactly the 5:3 of the canvas `DeckCanvas` slices, so the
picture is generated in the right shape rather than cropped into it.

Images are written to
`~/Library/Application Support/FifineDeck/Generated/`, named after the prompt
and stamped, and referenced from `settings.json` by path — **not** a temp
directory, which would blank the key on the next reboot. Asking twice keeps
both answers. Deleting one blanks the key that used it.

Every press is a **paid call** on your fal balance. The button takes one at a
time rather than queueing, and failures name the fix (`fal.ai rejected the key
— check FAL_KEY`, `out of credit`, `rate limited`).

The tests cover the prompt shaping, the request body, the file naming and every
error path without spending a call. There is one live test, off by default:

```sh
FIFINE_LIVE_TESTS=1 swift test --filter testAgainstTheRealAPI
```

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

If your keys have gone dead: unplug and replug. The app reconnects itself.

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
  ImageGen.swift        prompt -> key artwork, via fal.ai Ideogram v4
  LoginItem.swift       open at login, via SMAppService
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
  VLCWidget.swift       another machine's VLC, over its HTTP interface
  NowPlayingWidget.swift  one key for whichever of the two is playing
  StocksWidget.swift    Finnhub quotes + ticker faces
Tests/FifineDeckTests/  span layout, config validation, rendering
Tools/make_icon.swift   draws the app icon -> Resources/AppIcon.icns
Resources/AppIcon.icns  the generated icon, committed
build_app.sh            builds FifineDeck.app
dist.sh                 packages a shareable zip, and proves it carries no keys
Info.plist              bundle metadata
.env.template           every credential key, documented; copy to .env
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
software change recovers it. The app does now handle the *rest* of it: it sees
the unplug and the replug and reconnects itself, so the fix is the replug alone.

## Giving it to someone else

```sh
./dist.sh          # dist/FifineDeck-0.1.0.zip, and nothing else
```

**Do not zip this folder.** The `.env` lives next to `FifineDeck.app` by
design, so the obvious way to share the app is also the way to hand over your
Finnhub, fal and Spotify credentials. `dist.sh` stages only the bundle, and
then proves the staged copy carries none of your `.env` values before it makes
the archive — it refuses, naming the variable and never printing it, if one
turns up.

**It will not open on another Mac as it stands.** The signature is ad-hoc, so
Gatekeeper reports the app as damaged. A build for other people needs a
Developer ID certificate, the hardened runtime, and notarising; `dist.sh`
prints the three commands.

### What is and is not in the repository

| | Where it lives | Committed |
|---|---|---|
| `.env` | next to the app | no — `.gitignore`, and `.env.*` with it |
| `.env.template` | the repo | yes — it carries no values |
| `widgets.json` | Application Support, mode `0600` | no |
| `settings.json` | Application Support | no |
| generated artwork | Application Support | no |

Two tests enforce this rather than leaving it to habit: one fails if any file
`git commit -a` would publish contains a credential assignment or a PEM block,
and one fails if `.env`, `widgets.json` or `settings.json` ever stops being
ignored. Both have been checked against a planted secret, because a guard that
has never fired is not known to work.

### Two things worth knowing before you share a layout

- **`settings.json` stores Run-command strings in plain text.** It is the file
  you copy to another machine, so a key whose command carries a token carries
  it along. Put the token in the environment and reference it, or keep that
  key off a layout you share.
- **A failing command is logged in full**, to
  `~/Library/Application Support/FifineDeck/debug.log`, command text included.
  That is deliberate — a command that fails silently is indistinguishable from
  a key that did nothing — but it means a secret on a command line ends up in
  the log.

### What leaves your machine

Nothing until you add a widget that needs it, and nothing about you:

| Host | Sent when |
|---|---|
| `fal.run`, `v3b.fal.media` | you press **Make** — your prompt, your fal key |
| `finnhub.io` | a Stocks widget refreshes — the symbols |
| `api.spotify.com`, `accounts.spotify.com` | only the *account* source |
| `i.scdn.co` | album art for the Spotify widget |
| `api.open-meteo.com` | a Weather widget — the place or coordinates |
| `site.api.espn.com` | a Sports widget — the league |
| your own LAN | a VLC widget — only the address you typed, never off your network |
| `127.0.0.1:8888` | the one-off Spotify login, on the loopback only |

There is no analytics, no crash reporting and no update check. The Spotify
*local* source, the clock, the timer, the calendar and the system monitor
never touch the network at all.

## Known gaps

- No profiles, pages, or folders. One page, 15 keys.
- Widgets are polled, not pushed: a track change shows up on the next refresh,
  not the instant it happens.
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
