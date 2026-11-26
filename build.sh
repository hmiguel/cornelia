#!/bin/bash
# Builds Cornelia.app.
#
#   ./build.sh                    Dev build, links Homebrew's libmpv, installs to ~/Applications.
#   ./build.sh --release 1.2.0    Self-contained build with libmpv and its dependencies bundled
#                                 inside the app, packaged as dist/Cornelia-1.2.0-<arch>.dmg and .zip.
set -euo pipefail
cd "$(dirname "$0")"

MODE=dev
VERSION=0.0.0-dev
if [ "${1:-}" = "--release" ]; then
  MODE=release
  VERSION="${2:?usage: ./build.sh --release VERSION}"
  VERSION="${VERSION#v}"
fi

need() { brew list "$1" >/dev/null 2>&1 || { echo "Installing $1…"; brew install "$1"; }; }
need mpv
[ "$MODE" = release ] && need dylibbundler

export HOMEBREW_PREFIX="$(brew --prefix)"
swift build -c release

APP=build/Cornelia.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Cornelia "$APP/Contents/MacOS/Cornelia"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
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
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © $(date +%Y) Hugo Conceicao</string>
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

if [ "$MODE" = dev ]; then
  codesign --force --sign - "$APP" >/dev/null
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Cornelia.app"
  cp -R "$APP" "$HOME/Applications/Cornelia.app"
  echo "Installed: $HOME/Applications/Cornelia.app"
  exit 0
fi

# ---- Release: make the app self-contained ----
BIN="$APP/Contents/MacOS/Cornelia"
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"

# Copy libmpv and its whole dependency tree into the bundle and rewrite load paths.
dylibbundler --overwrite-dir --bundle-deps --create-dir \
  --fix-file "$BIN" \
  --dest-dir "$FW" \
  --install-path @executable_path/../Frameworks/ \
  --search-path "$HOMEBREW_PREFIX/lib" </dev/null 2>&1 | grep -v "invalidate the code signature" || true

# Drop the Homebrew rpath so nothing can resolve outside the bundle.
install_name_tool -delete_rpath "$HOMEBREW_PREFIX/lib" "$BIN" 2>/dev/null || true

# Fail if anything still points at Homebrew.
LEAKS=$( { otool -L "$BIN"; for f in "$FW"/*.dylib; do otool -L "$f"; done; } | grep -E "$HOMEBREW_PREFIX|/usr/local/(opt|Cellar|lib)" || true)
if [ -n "$LEAKS" ]; then
  echo "error: bundle still references Homebrew paths:" >&2
  echo "$LEAKS" >&2
  exit 1
fi

# Rewritten binaries need fresh (ad-hoc) signatures on Apple Silicon.
for f in "$FW"/*.dylib; do codesign --force --sign - "$f" >/dev/null 2>&1; done
codesign --force --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

ARCH=$(uname -m)
mkdir -p dist
ZIP="dist/Cornelia-${VERSION}-${ARCH}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
echo "Release: $ZIP ($(du -h "$ZIP" | cut -f1), $(ls "$FW" | wc -l | tr -d ' ') bundled libraries)"

# Disk image: open it, drag Cornelia onto the Applications shortcut.
DMG="dist/Cornelia-${VERSION}-${ARCH}.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns" && SetFile -a C "$STAGE" 2>/dev/null || true
rm -f "$DMG"
hdiutil create -quiet -volname "Cornelia ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format ULMO -ov "$DMG"
codesign --force --sign - "$DMG" >/dev/null
echo "Release: $DMG ($(du -h "$DMG" | cut -f1))"
