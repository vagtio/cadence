#!/usr/bin/env bash
# Assembles Cadence.app from the SwiftPM release build.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Cadence
BIN=".build/$CONFIG/Cadence"
APP=".build/Cadence.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cadence"

# App icon
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM resource bundles (the 音源 glue script lives in one)
for bundle in .build/"$CONFIG"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
  cp -R "$bundle" "$APP/Contents/MacOS/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cadence</string>
  <key>CFBundleDisplayName</key><string>Cadence</string>
  <key>CFBundleExecutable</key><string>Cadence</string>
  <key>CFBundleIdentifier</key><string>dev.cadence.player</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <!-- 音源脚本与酷狗接口大量使用 http://，与 Electron 版一致不做 ATS 限制 -->
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier dev.cadence.player "$APP" >/dev/null 2>&1 || true
echo "built $APP"
