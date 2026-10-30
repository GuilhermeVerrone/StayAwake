#!/bin/bash
# Compila o StayAwake e monta o bundle .app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/StayAwake.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>StayAwake</string>
    <key>CFBundleDisplayName</key>       <string>StayAwake</string>
    <key>CFBundleExecutable</key>        <string>StayAwake</string>
    <key>CFBundleIdentifier</key>        <string>local.stayawake</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string></string>
</dict>
</plist>
PLIST

swiftc -O -swift-version 5 \
    -target arm64-apple-macos12.0 \
    -framework AppKit -framework IOKit \
    main.swift \
    -o "$APP/Contents/MacOS/StayAwake"

# Assinatura ad-hoc: sem ela o macOS revoga a permissão de Acessibilidade a cada build.
codesign --force --sign - --identifier local.stayawake "$APP"

echo "OK -> $(pwd)/$APP"
