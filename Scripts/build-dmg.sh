#!/bin/bash
#
# Build a distributable ThermalForge.dmg (drag-to-Applications installer).
#
# No sudo required — everything is staged under ./dist. Produces:
#   dist/ThermalForge.app   — the menu-bar app bundle
#   dist/ThermalForge.dmg   — compressed disk image with an Applications symlink
#
# The daemon/CLI still install via `sudo thermalforge install` (or ./setup.sh);
# this DMG delivers the menu-bar .app for drag-install.
#
# Note: the app is NOT code-signed/notarized. On first launch Gatekeeper will
# warn — right-click > Open, or run: xattr -dr com.apple.quarantine /Applications/ThermalForge.app
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="dist/ThermalForge.app"
DMG="dist/ThermalForge-${VERSION}.dmg"

echo "==> Building release binaries"
swift build -c release --quiet

echo "==> Generating icon if missing"
if [ ! -f ThermalForge.icns ]; then
    swift Scripts/generate-icon.swift
    iconutil -c icns ThermalForge.iconset -o ThermalForge.icns
fi

echo "==> Assembling $APP"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ThermalForgeApp "$APP/Contents/MacOS/ThermalForgeApp"
cp ThermalForge.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ThermalForge</string>
    <key>CFBundleDisplayName</key><string>ThermalForge</string>
    <key>CFBundleIdentifier</key><string>com.thermalforge.app</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>ThermalForgeApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Strip any quarantine attributes from the staged bundle.
xattr -cr "$APP" 2>/dev/null || true

echo "==> Building $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "ThermalForge" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo ""
echo "Done: $DMG"
ls -lh "$DMG"
