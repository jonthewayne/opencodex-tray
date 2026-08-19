#!/bin/zsh
# build.sh — compile OpenCodex Tray and assemble the .app bundle.
#   ./build.sh          build into ./OpenCodex Tray.app
#   ./build.sh install  build, then install to /Applications and launch
set -e
cd "$(dirname "$0")"
APP="OpenCodex Tray.app"

# regenerate the icon only if missing (committed AppIcon.icns is normally used as-is)
if [ ! -f AppIcon.icns ]; then
  swiftc gen-icon.swift -o gen-icon
  ./gen-icon icon_1024.png
  rm -rf AppIcon.iconset && mkdir AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s icon_1024.png --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) icon_1024.png --out "AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns AppIcon.iconset
  rm -rf AppIcon.iconset icon_1024.png gen-icon
fi

swiftc OpenCodexTray.swift -framework ServiceManagement -o OpenCodexTray

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp OpenCodexTray "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/Info.plist"
cp ocx-tray-ctl "$APP/Contents/Resources/"
cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "built: $APP"

if [ "$1" = "install" ]; then
  pkill -f "Contents/MacOS/OpenCodexTray" 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" "/Applications/$APP"
  mdimport "/Applications/$APP" 2>/dev/null || true
  open "/Applications/$APP"
  echo "installed: /Applications/$APP"
fi
