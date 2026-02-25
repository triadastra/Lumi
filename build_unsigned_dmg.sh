#!/bin/bash
# Build an unsigned LumiAgent.app and package it into a DMG on the Desktop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="LumiAgent"
BUILD_CONFIG="${1:-debug}"
DIST_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_STAGE_DIR="$DIST_DIR/dmg-root"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DMG_PATH="$HOME/Desktop/${APP_NAME}-unsigned-${TIMESTAMP}.dmg"

echo "Building $APP_NAME ($BUILD_CONFIG)..."
swift build -c "$BUILD_CONFIG" --package-path "$SCRIPT_DIR"

BIN_DIR="$(swift build -c "$BUILD_CONFIG" --show-bin-path --package-path "$SCRIPT_DIR")"
BIN_PATH="$BIN_DIR/$APP_NAME"

if [ ! -x "$BIN_PATH" ]; then
  echo "error: executable not found at $BIN_PATH"
  exit 1
fi

echo "Assembling app bundle..."
rm -rf "$APP_BUNDLE" "$DMG_STAGE_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LumiAgent</string>
    <key>CFBundleIdentifier</key>
    <string>com.lumiagent.app</string>
    <key>CFBundleName</key>
    <string>LumiAgent</string>
    <key>CFBundleDisplayName</key>
    <string>Lumi Agent</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>LumiAgent needs to control apps via AppleScript to automate tasks.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>LumiAgent needs accessibility access to control the mouse, keyboard, and screen.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>LumiAgent needs to capture screenshots for visual AI analysis.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>LumiAgent may need microphone access for voice-based features.</string>
    <key>NSCameraUsageDescription</key>
    <string>LumiAgent may use camera access for vision-based features you enable.</string>
</dict>
</plist>
PLIST

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy SwiftPM-produced resource bundles (if present).
find "$BIN_DIR" -maxdepth 1 -type d -name "*.bundle" -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;

# Build a proper macOS .icns from your asset catalog images.
ASSET_ICON_DIR="$SCRIPT_DIR/Lumi/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ASSET_ICON_DIR" ]; then
  TMP_ICONSET="$DIST_DIR/AppIcon.iconset"
  rm -rf "$TMP_ICONSET"
  mkdir -p "$TMP_ICONSET"

  cp "$ASSET_ICON_DIR/mac_16.png" "$TMP_ICONSET/icon_16x16.png"
  cp "$ASSET_ICON_DIR/mac_32.png" "$TMP_ICONSET/icon_16x16@2x.png"
  cp "$ASSET_ICON_DIR/mac_32.png" "$TMP_ICONSET/icon_32x32.png"
  cp "$ASSET_ICON_DIR/mac_64.png" "$TMP_ICONSET/icon_32x32@2x.png"
  cp "$ASSET_ICON_DIR/mac_128.png" "$TMP_ICONSET/icon_128x128.png"
  cp "$ASSET_ICON_DIR/mac_256.png" "$TMP_ICONSET/icon_128x128@2x.png"
  cp "$ASSET_ICON_DIR/mac_256.png" "$TMP_ICONSET/icon_256x256.png"
  cp "$ASSET_ICON_DIR/mac_512.png" "$TMP_ICONSET/icon_256x256@2x.png"
  cp "$ASSET_ICON_DIR/mac_512.png" "$TMP_ICONSET/icon_512x512.png"
  cp "$ASSET_ICON_DIR/mac_1024.png" "$TMP_ICONSET/icon_512x512@2x.png"

  iconutil -c icns "$TMP_ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "Preparing DMG staging..."
mkdir -p "$DMG_STAGE_DIR"
cp -R "$APP_BUNDLE" "$DMG_STAGE_DIR/"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

echo "Creating DMG at $DMG_PATH..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Done."
echo "App bundle: $APP_BUNDLE"
echo "DMG: $DMG_PATH"
