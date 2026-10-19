#!/bin/zsh
# Builds "Ding Detective.app" into ./build. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "${0:A:h}"
APP="build/Ding Detective.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.4 \
  -framework AppKit -framework SwiftUI -framework CoreAudio -framework AudioToolbox \
  -framework Accelerate -framework ServiceManagement -lsqlite3 \
  -o "$APP/Contents/MacOS/DingDetective" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - --identifier com.cheapassjimmy.dingdetective \
  -r='designated => identifier "com.cheapassjimmy.dingdetective"' "$APP"
echo "Built $APP"
