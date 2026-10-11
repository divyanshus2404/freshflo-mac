#!/bin/bash
# Packages build/Freshflo.app into a signed drag-to-Applications DMG: build/Freshflo-<version>.dmg
# Run ./scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Freshflo.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Freshflo-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Freshflo" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}"
[ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$DMG"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1)) sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
