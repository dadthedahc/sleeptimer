#!/bin/bash
# Builds SleepTimer.app next to this script. Requires Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }

APP="SleepTimer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O main.swift -o "$APP/Contents/MacOS/SleepTimer"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.chadmiller.sleeptimer</string>
  <key>CFBundleName</key><string>Sleep Timer</string>
  <key>CFBundleExecutable</key><string>SleepTimer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# Ad-hoc sign with the hardened runtime (blocks code/library injection into the process).
codesign --force --options runtime --sign - "$APP"
echo "Built $APP — launch with: open $APP"
