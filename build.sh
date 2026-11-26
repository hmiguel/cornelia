#!/bin/bash
# Builds Cornelia.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

if ! brew list mpv >/dev/null 2>&1; then
  echo "Installing mpv (libmpv)…"
  brew install mpv
fi

export HOMEBREW_PREFIX="$(brew --prefix)"
swift build -c release
APP=build/Cornelia.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Cornelia "$APP/Contents/MacOS/Cornelia"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cornelia</string>
  <key>CFBundleDisplayName</key><string>Cornelia</string>
  <key>CFBundleIdentifier</key><string>local.cornelia.player</string>
  <key>CFBundleExecutable</key><string>Cornelia</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>M3U Playlist</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>CFBundleTypeExtensions</key><array><string>m3u</string><string>m3u8</string></array>
  </dict></array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Cornelia.app"
cp -R "$APP" "$HOME/Applications/Cornelia.app"
echo "Installed: $HOME/Applications/Cornelia.app"
