#!/bin/zsh
# Builds dist/Bonkeys.app. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Bonkeys"
APP=dist/Bonkeys.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bonkeys"
for d in Sounds Packs Effects CREDITS.md; do cp -R "Resources/$d" "$APP/Contents/Resources/$d"; done
if [[ ! -f Resources/Bonkeys.icns ]]; then
  TMP=$(mktemp -d); swift scripts/icon.swift "$TMP/Bonkeys.iconset"
  iconutil -c icns "$TMP/Bonkeys.iconset" -o Resources/Bonkeys.icns
fi
cp Resources/Bonkeys.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.bonkeys</string>
<key>CFBundleName</key><string>Bonkeys</string>
<key>CFBundleExecutable</key><string>Bonkeys</string>
<key>CFBundleIconFile</key><string>Bonkeys</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Bonkeys uses the microphone only while you record your own key sound.</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>local.bonkeys</string>
<key>CFBundleURLSchemes</key><array><string>bonkeys</string></array>
</dict></array>
</dict></plist>
P
ENT=$(mktemp); cat > "$ENT" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
P
codesign --force --sign - --options runtime --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP"
echo "Built $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app id "local.bonkeys"' 2>/dev/null || true
  mkdir -p ~/Applications; rm -rf ~/Applications/Bonkeys.app; cp -R "$APP" ~/Applications/
  # Ad hoc signatures change on every build, so clear the stale grant instead of leaving one that looks on but fails.
  tccutil reset ListenEvent local.bonkeys >/dev/null 2>&1 || true
  echo "Installed ~/Applications/Bonkeys.app (allow Input Monitoring again after each rebuild)"
fi
