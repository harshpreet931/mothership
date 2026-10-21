#!/usr/bin/env bash
# Builds Mothership and assembles build/Mothership.app (ad-hoc signed).
#
#   scripts/bundle.sh            # debug build
#   scripts/bundle.sh --release  # swift build -c release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=debug
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        --debug) CONFIG=debug ;;
        -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

cd "$ROOT"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product MothershipApp
swift build -c "$CONFIG" --product mship
swift build -c "$CONFIG" --product mshipd
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Mothership.app"
CONTENTS="$APP/Contents"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN/MothershipApp" "$CONTENTS/MacOS/Mothership"
cp "$BIN/mship" "$CONTENTS/MacOS/mship"
cp "$BIN/mshipd" "$CONTENTS/MacOS/mshipd"

# SwiftPM resource bundles. Their generated `Bundle.module` accessor looks next to
# `Bundle.main.bundleURL` (the .app root, where codesign allows nothing but Contents/), then
# falls back to an absolute .build path. They go in Contents/Resources; TerminalEngine's
# ResourceBundleBootstrap points GhosttyTerminal's accessor there at launch. Any other
# bundle would only resolve on this machine, so flag it.
shopt -s nullglob
for bundle in "$BIN"/*.bundle; do
    name="$(basename "$bundle")"
    # Test targets' resources never ship.
    [[ "$name" == *Tests.bundle ]] && continue
    cp -R "$bundle" "$CONTENTS/Resources/"
    accessor="$(grep -rl --include=resource_bundle_accessor.swift "$name" "$BIN" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$accessor" ]] && grep -q 'Bundle.main.bundleURL' "$accessor"; then
        if [[ "$name" == "GhosttyKit_GhosttyTerminal.bundle" ]]; then
            echo "    $name -> Contents/Resources (resolved by ResourceBundleBootstrap)"
        else
            echo "warning: $name is looked up at the .app root by $accessor;" >&2
            echo "         add it to ResourceBundleBootstrap or it only resolves on this machine." >&2
        fi
    else
        echo "    $name -> Contents/Resources"
    fi
done
shopt -u nullglob

# App icon, regenerated when the drawing script changes.
ICON_CACHE="$ROOT/.build/mothership-icon"
ICNS="$ICON_CACHE/AppIcon.icns"
if [[ ! -f "$ICNS" || "$ROOT/scripts/make-icon.swift" -nt "$ICNS" ]]; then
    echo "==> drawing app icon"
    rm -rf "$ICON_CACHE"
    mkdir -p "$ICON_CACHE"
    swift "$ROOT/scripts/make-icon.swift" "$ICON_CACHE/AppIcon.iconset"
    iconutil -c icns "$ICON_CACHE/AppIcon.iconset" -o "$ICNS"
fi
cp "$ICNS" "$CONTENTS/Resources/AppIcon.icns"

VERSION="$(awk '/enum ShipInfo/ { inside = 1 } inside && /static let version/ { gsub(/.*= "|".*/, ""); print; exit }' "$ROOT/Sources/ShipModel/Environment.swift")"
VERSION="${VERSION:-0.0.0}"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Mothership</string>
    <key>CFBundleIdentifier</key>
    <string>com.mothership.app</string>
    <key>CFBundleName</key>
    <string>Mothership</string>
    <key>CFBundleDisplayName</key>
    <string>Mothership</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>NSLocationUsageDescription</key>
    <string>Mothership uses your approximate location only to place the sun in its sky. Nothing is saved or sent anywhere.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Mothership uses your approximate location only to place the sun in its sky. Nothing is saved or sent anywhere.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> signing (ad-hoc)"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> $APP ($CONFIG, v$VERSION build $BUILD)"
