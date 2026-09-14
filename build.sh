#!/bin/bash
# Builds FanBlast.app — a menu bar front end for the fan helper daemon.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/FanBlast.app"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

# Read-only SMC access (RPM + temperature) needs no privileges.
clang -O2 -Wall -mmacosx-version-min=13.0 -Isrc -c src/smcread.c -o build/smcread.o

swiftc -O \
  -target x86_64-apple-macosx13.0 \
  -import-objc-header src/bridge.h \
  src/main.swift build/smcread.o \
  -framework Cocoa -framework IOKit \
  -o "$APP/Contents/MacOS/FanBlast"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>FanBlast</string>
    <key>CFBundleDisplayName</key>       <string>FanBlast</string>
    <key>CFBundleExecutable</key>        <string>FanBlast</string>
    <key>CFBundleIdentifier</key>        <string>com.kirtan.fanblast</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || echo "note: ad-hoc signing skipped"
echo "built $APP"
