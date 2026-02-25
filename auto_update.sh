#!/bin/bash
# auto_update.sh — clean, build, sign, deploy, and relaunch LumiAgent.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNABLE_DIR="$SCRIPT_DIR/runable"
APP_BUNDLE="$RUNABLE_DIR/LumiAgent.app"
BINARY_DST="$APP_BUNDLE/Contents/MacOS/LumiAgent"
BINARY_SRC="$SCRIPT_DIR/.build/debug/LumiAgent"
ENTITLEMENTS="$SCRIPT_DIR/LumiAgent.entitlements"
APP_INSTALL_PATH="/Applications/LumiAgent.app"

echo "🔄 LumiAgent Auto-Update"
echo "========================"

# 1) Stop running app
if pgrep -x "LumiAgent" > /dev/null 2>&1; then
    echo "⏹  Stopping running LumiAgent..."
    pkill -x "LumiAgent" || true
    sleep 0.6
fi

# 2) Delete everything in runable/
echo "🧹 Clearing runable/..."
mkdir -p "$RUNABLE_DIR"
find "$RUNABLE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

# 3) Delete /Applications/LumiAgent.app
echo "🗑  Removing /Applications/LumiAgent.app..."
rm -rf "$APP_INSTALL_PATH"

# 4) Rebuild
echo "🔨 Building..."
swift build -c debug --package-path "$SCRIPT_DIR"
echo "✅ Build complete"

# 5) Rebuild app bundle in runable/
echo "📦 Rebuilding app bundle in runable/..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
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
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>

    <key>NSHealthShareUsageDescription</key>
    <string>Lumi reads your Apple Health data to display metrics and provide AI-powered wellness insights.</string>
    <key>NSHealthUpdateUsageDescription</key>
    <string>Lumi does not write any data to Apple Health.</string>

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

cp "$BINARY_SRC" "$BINARY_DST"
cp "$SCRIPT_DIR/icons/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp "$SCRIPT_DIR/icons/appicon.png" "$APP_BUNDLE/Contents/Resources/AppIcon.png" 2>/dev/null || true

# 6) Sign
echo "🔐 Signing..."
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_BUNDLE" 2>/dev/null || true

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
           | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)

if [ -n "$IDENTITY" ]; then
    echo "   Using certificate: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" \
             --entitlements "$ENTITLEMENTS" \
             "$APP_BUNDLE"
else
    echo "   No Developer cert found — ad-hoc signing (no HealthKit)"
    ADHOC_ENT="$SCRIPT_DIR/.build/adhoc.entitlements"
    cat > "$ADHOC_ENT" << 'ENTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
ENTPLIST
    codesign --force --deep --sign - \
             --entitlements "$ADHOC_ENT" \
             "$APP_BUNDLE"
fi

# 7) Duplicate to /Applications
echo "📁 Copying to /Applications..."
if ditto "$APP_BUNDLE" "$APP_INSTALL_PATH"; then
    echo "✅ Copied to $APP_INSTALL_PATH"
else
    echo "⚠️  Direct copy failed. Retrying with sudo..."
    sudo ditto "$APP_BUNDLE" "$APP_INSTALL_PATH"
    echo "✅ Copied to $APP_INSTALL_PATH (via sudo)"
fi

# 8) Launch from /Applications
echo "🚀 Launching..."
open -n "$APP_INSTALL_PATH" 2>/dev/null || nohup "$APP_INSTALL_PATH/Contents/MacOS/LumiAgent" </dev/null &>/dev/null &

echo "✅ Done"
