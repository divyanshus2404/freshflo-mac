#!/bin/bash
# Builds Freshflo.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Freshflo.app"
if [ "${SKIP_CHECKS:-0}" != "1" ]; then
    echo "→ Running logic checks…"
    swift run -q FreshfloChecks
fi
echo "→ Compiling (release)…"
swift build -c release --arch arm64 --product Freshflo

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Freshflo "$APP/Contents/MacOS/Freshflo"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon is rendered from the brand master (Freshflo-Website/brand/icon.svg) and checked in.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Accessibility/Microphone grants across rebuilds.
# Override with SIGN_IDENTITY="..." or SIGN_IDENTITY="-" for ad-hoc.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
echo "→ Signing with: $IDENTITY"
codesign --force --options runtime --entitlements Resources/Freshflo.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "✓ Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Freshflo 2>/dev/null || true
    # The app used to be called ExcuseMe. Quit it and move it to the Trash (recoverable);
    # Freshflo copies its settings, key, history and meetings on first launch.
    if [ -d /Applications/ExcuseMe.app ]; then
        pkill -x ExcuseMe 2>/dev/null || true
        mv /Applications/ExcuseMe.app "$HOME/.Trash/ExcuseMe-$(date +%s).app"
        echo "→ Moved the old ExcuseMe.app to the Trash"
    fi
    rm -rf /Applications/Freshflo.app
    cp -R "$APP" /Applications/
    echo "✓ Installed to /Applications/Freshflo.app"
    open /Applications/Freshflo.app
fi
