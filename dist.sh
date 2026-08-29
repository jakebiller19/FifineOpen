#!/usr/bin/env bash
# Package FifineDeck.app for someone else's Mac.
#
# The hazard this exists for: the README tells you to keep `.env` NEXT TO
# FifineDeck.app, so the obvious way to share the app — zip the folder — ships
# your Finnhub, fal and Spotify credentials with it. This stages ONLY the
# bundle, then proves the staged copy carries none of your `.env` values
# before it makes the archive.
set -euo pipefail
cd "$(dirname "$0")"

APP="FifineDeck.app"
STAGE="dist/stage"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 0)"
ZIP="dist/FifineDeck-$VERSION.zip"

./build_app.sh release

rm -rf "$STAGE" && mkdir -p "$STAGE"
# Only the bundle. Nothing else in this folder is anyone else's business.
cp -R "$APP" "$STAGE/"

fail() { echo "dist: REFUSING TO PACKAGE — $1" >&2; exit 1; }

# 1. Nothing that holds credentials may be inside the bundle.
for pattern in ".env" ".env.*" "widgets.json" "settings.json" "*.p12" "*.pem" "id_rsa*"; do
    found="$(find "$STAGE" -name "$pattern" 2>/dev/null || true)"
    [ -z "$found" ] || fail "the bundle contains $found"
done

# 2. And no VALUE from your own .env may appear anywhere in it — the check
#    that catches a secret baked in at build time rather than copied in.
#    Values are compared, never printed; only the variable name is reported.
if [ -f .env ]; then
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        name="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"; value="${value#\"}"
        [ "${#value}" -ge 8 ] || continue
        if grep -rqF -- "$value" "$STAGE" 2>/dev/null; then
            fail "a value from \$$name is embedded in the bundle"
        fi
    done < .env
    echo "dist: checked the bundle against every value in .env — none present"
fi

# 3. It has to be signed, or Gatekeeper kills it on arrival.
codesign --verify --deep --strict "$STAGE/$APP" 2>/dev/null \
    || fail "the staged app does not verify — re-run build_app.sh"

rm -f "$ZIP"
# ditto, not zip: it is the tool that preserves a bundle's symlinks and
# extended attributes, which is what keeps the signature intact.
/usr/bin/ditto -c -k --keepParent "$STAGE/$APP" "$ZIP"
rm -rf "$STAGE"

echo
echo "Wrote $ZIP"
echo
echo "Before sending it to anyone: this is an AD-HOC signature, so macOS will"
echo "refuse to open it on another Mac (\"damaged and can't be opened\"). A"
echo "build for other people needs a Developer ID certificate and notarising:"
echo "  codesign --force --options runtime --sign \"Developer ID Application: …\" $APP"
echo "  xcrun notarytool submit $ZIP --keychain-profile … --wait"
echo "  xcrun stapler staple $APP"
