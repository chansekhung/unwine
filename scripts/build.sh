#!/bin/bash
# Builds Unwine.app (release, arm64) into dist/ and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.2}"
BUILD="${BUILD:-3}"
APP="dist/Unwine.app"

# The macOS 27 SDK turns SwiftUI's @State into a compiler plugin that the Command Line
# Tools do not ship, so build against the macOS 26 SDK when it is there. The app runs on 27 too.
for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; do
  [ -d "$sdk" ] && { export SDKROOT="$sdk"; break; }
done
echo "▸ Compiling (SDK: ${SDKROOT:-default})"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Unwine"

echo "▸ Making icon"
if [ ! -f Resources/AppIcon.icns ] || [ Resources/AppIcon.png -nt Resources/AppIcon.icns ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Unwine"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Unwine</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>app.unwine.Unwine</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Unwine</string>
  <key>CFBundleDisplayName</key><string>Unwine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>Free software (GPL-3.0). Wine is LGPL. Steam is Valve's.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Unwine looks for Apple's Game Porting Toolkit file you downloaded, to add GPTK.</string>
  <key>UnwineUpdateRepo</key><string>${UNWINE_UPDATE_REPO:-chansekhung/unwine}</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP" && echo "✓ Built $APP ($(du -sh "$APP" | cut -f1))"
