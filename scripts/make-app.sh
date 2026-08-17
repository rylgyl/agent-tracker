#!/bin/bash
# Builds AgentTracker.app into ./dist and (optionally) installs it
# into /Applications. Run from the repository root:
#   ./scripts/make-app.sh [--install]
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Agent Tracker"
BUNDLE_ID="com.agent-tracker.usage"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "Building release binary..."
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/AgentTracker" "$APP/Contents/MacOS/$APP_NAME"

echo "Rendering app icon..."
swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Icon rendering leaves Finder metadata behind, which codesign rejects.
xattr -cr "$APP"

# Ad-hoc signature so Keychain access sticks across launches.
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/$APP_NAME.app"
fi
