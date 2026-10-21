#!/usr/bin/env bash
# Builds a release Mothership.app, signs it with the hardened runtime, notarizes and staples
# it when credentials are configured, and packages dist/Mothership-<version>.dmg.
#
#   scripts/release.sh                     # ad-hoc signed (runs here; Gatekeeper warns elsewhere)
#   MOTHERSHIP_SIGN_ID="Developer ID Application: Name (TEAMID)" \
#   MOTHERSHIP_NOTARY_PROFILE=mothership scripts/release.sh
#
# One-time notary setup: xcrun notarytool store-credentials mothership \
#   --apple-id <id> --team-id <TEAMID> --password <app-specific password>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/Mothership.app"
ENTITLEMENTS="$ROOT/scripts/Mothership.entitlements"
SIGN_ID="${MOTHERSHIP_SIGN_ID:--}"
NOTARY_PROFILE="${MOTHERSHIP_NOTARY_PROFILE:-}"

echo "==> building"
scripts/bundle.sh --release >/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

echo "==> signing with the hardened runtime (${SIGN_ID/-/ad-hoc})"
sign() {
    local flags=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID")
    [[ "$SIGN_ID" != "-" ]] && flags+=(--timestamp)
    codesign "${flags[@]}" "$1"
}
# Inner executables first (mship, mshipd, …), then the bundle that seals them.
for binary in "$APP"/Contents/MacOS/*; do
    [[ "$(basename "$binary")" == Mothership ]] && continue
    sign "$binary"
done
sign "$APP"
codesign --verify --strict --deep "$APP"

echo "==> packaging"
mkdir -p dist build/dmg
STAGE="$ROOT/build/dmg/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/dist/Mothership-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Mothership" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
[[ "$SIGN_ID" != "-" ]] && codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
    [[ "$SIGN_ID" == "-" ]] && { echo "notarization needs MOTHERSHIP_SIGN_ID (a Developer ID)" >&2; exit 1; }
    echo "==> notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
    echo "==> not notarized (set MOTHERSHIP_NOTARY_PROFILE to notarize)"
fi

echo "==> $DMG (v$VERSION build $BUILD)"
shasum -a 256 "$DMG"
