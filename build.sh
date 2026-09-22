#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="${1:-build}"
mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/MDMF 파일 추출기.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 Extractor.swift main.swift -o "$BUILD_DIR/mdmf-arm64"
xcrun swiftc -swift-version 5 -O -target x86_64-apple-macosx13.0 Extractor.swift main.swift -o "$BUILD_DIR/mdmf-x86_64"
xcrun lipo -create "$BUILD_DIR/mdmf-arm64" "$BUILD_DIR/mdmf-x86_64" -output "$APP/Contents/MacOS/mdmf-extract"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
