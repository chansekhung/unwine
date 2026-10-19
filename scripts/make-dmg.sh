#!/bin/bash
# Packs dist/Decant.app into dist/Decant.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Decant.app"
DMG="dist/Decant.dmg"
[ -d "$APP" ] || { echo "Run scripts/build.sh first"; exit 1; }

STAGE="$(mktemp -d)/Decant"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/First time on a new Mac.txt" "$STAGE/"

rm -f "$DMG"
hdiutil create -volname "Decant" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null && echo "✓ Built $DMG ($(du -h "$DMG" | cut -f1))"
