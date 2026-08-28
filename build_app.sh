#!/usr/bin/env bash
# Build FifineDeck.app.
#
# SwiftPM produces a bare executable, and a bare executable has no bundle -
# so SwiftUI never gets a window and the process exits immediately. Wrapping
# the binary in a minimal .app with an Info.plist is what makes it a real,
# launchable Mac app.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="FifineDeck.app"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/FifineDeck"
[ -x "$BIN" ] || { echo "build produced no binary at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/FifineDeck"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: unsigned bundles get killed on Apple Silicon.
codesign --force --sign - "$APP" >/dev/null 2>&1 || \
    echo "note: ad-hoc codesign failed; the app may still run" >&2

echo "Built $APP"
echo "Run it with:  open $APP     (or ./$APP/Contents/MacOS/FifineDeck to see logs)"
