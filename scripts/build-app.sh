#!/bin/bash
# Builds ExcuseMe.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ExcuseMe.app"
if [ "${SKIP_CHECKS:-0}" != "1" ]; then
    echo "→ Running logic checks…"
    swift run -q ExcuseMeChecks
fi
echo "→ Compiling (release)…"
swift build -c release --arch arm64 --product ExcuseMe

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/ExcuseMe "$APP/Contents/MacOS/ExcuseMe"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
    echo "→ Rendering icon"
    rm -rf build/AppIcon.iconset
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Accessibility/Microphone grants across rebuilds.
# Override with SIGN_IDENTITY="..." or SIGN_IDENTITY="-" for ad-hoc.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
echo "→ Signing with: $IDENTITY"
codesign --force --options runtime --entitlements Resources/ExcuseMe.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "✓ Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x ExcuseMe 2>/dev/null || true
    rm -rf /Applications/ExcuseMe.app
    cp -R "$APP" /Applications/
    echo "✓ Installed to /Applications/ExcuseMe.app"
    open /Applications/ExcuseMe.app
fi
