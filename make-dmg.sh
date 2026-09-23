#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_SOURCE="${1:-build/MDMF 파일 추출기.app}"
if [ ! -d "$APP_SOURCE" ]; then
    printf '앱을 찾을 수 없습니다. 먼저 bash build.sh를 실행하세요.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$APP_SOURCE"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SOURCE/Contents/Info.plist")
DMG_OUTPUT="${2:-build/MDMF-Extractor-${VERSION}.dmg}"
mkdir -p "$(dirname "$DMG_OUTPUT")"

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mdmf-dmg.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_SOURCE" "$STAGING_DIR/MDMF 파일 추출기.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/설치 안내.txt" <<'INSTALL'
MDMF 파일 추출기 — 설치 안내

1. MDMF 파일 추출기.app을 옆의 Applications 폴더로 끌어 넣습니다.
2. 응용 프로그램 폴더에서 MDMF 파일 추출기를 실행합니다.
3. 설치가 끝나면 Finder에서 이 디스크 이미지를 추출해도 됩니다.

MDMF 파일을 앱에 끌어놓거나 '파일 선택…'으로 선택하세요.
PDF 공문과 ZIP·엑셀·HWP 등 모든 붙임파일을 원래 형식으로 저장합니다.
기본 저장 위치는 원본 파일과 같은 폴더입니다.

macOS 13 이상, Apple Silicon 및 Intel 지원.
파일을 외부 서버에 보내지 않습니다.
이 버전은 Apple Developer ID 서명 및 공증을 받지 않은 독립 제작 앱입니다.
INSTALL

hdiutil create -volname "MDMF 파일 추출기" -srcfolder "$STAGING_DIR" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG_OUTPUT"
hdiutil verify "$DMG_OUTPUT"
printf '\n완료: %s\n' "$DMG_OUTPUT"
