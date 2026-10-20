#!/bin/bash
# Packs dist/Unwine.app into dist/Unwine.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Unwine.app"
DMG="dist/Unwine.dmg"
[ -d "$APP" ] || { echo "Run scripts/build.sh first"; exit 1; }

STAGE="$(mktemp -d)/Unwine"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# Decant 1.0.0 updates itself only from a file named Decant.app. A hidden copy under that name
# lets it reach Unwine; Unwine then renames its own folder to Unwine.app on first start.
cp -R "$APP" "$STAGE/Decant.app"
chflags hidden "$STAGE/Decant.app"
ln -s /Applications "$STAGE/Applications"
cp "Resources/First time on a new Mac.txt" "$STAGE/"

rm -f "$DMG"
hdiutil create -volname "Unwine" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null && echo "✓ Built $DMG ($(du -h "$DMG" | cut -f1))"
