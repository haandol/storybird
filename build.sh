#!/bin/bash
#
# Storybird.app 번들을 빌드하고 안정적인 앱 신원으로 서명한다.
#
# 화면 기록과 입력 모니터링 권한은 번들 식별자와 코드서명 요구사항에 묶인다.
# bare executable 또는 매번 CDHash가 바뀌는 ad-hoc 번들은 개발 중에도 권한을
# 반복해서 잃을 수 있으므로 가능한 경우 실제 Apple 인증서를 사용한다.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Storybird"
APP_BUNDLE="build/${APP_NAME}.app"
ICON_SOURCE="${STORYBIRD_ICON_SOURCE:-Resources/AppIcon-generated.png}"
ICON_FALLBACK="Resources/AppIcon.svg"
ICON_PNG="build/AppIcon.png"
ICONSET="build/AppIcon.iconset"
ICON_FILE="build/AppIcon.icns"

echo "==> 빌드 (${CONFIG})"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"

echo "==> 번들 구성"
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "$BINARY" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"

echo "==> 앱 아이콘 생성"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "    생성 아이콘이 없어 SVG fallback을 사용합니다: ${ICON_FALLBACK}"
    ICON_SOURCE="$ICON_FALLBACK"
fi

if [[ "$ICON_SOURCE" == *.png ]]; then
    cp "$ICON_SOURCE" "$ICON_PNG"
else
    sips -s format png "$ICON_SOURCE" --out "$ICON_PNG" >/dev/null
fi
for SIZE in 16 32 128 256 512; do
    DOUBLE_SIZE=$((SIZE * 2))
    sips -z "$SIZE" "$SIZE" "$ICON_PNG" \
        --out "${ICONSET}/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$ICON_PNG" \
        --out "${ICONSET}/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICON_FILE"
cp "$ICON_FILE" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> 코드서명"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' \
        | head -1 | tr -d '"')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "    인증서: ${SIGN_IDENTITY}"
else
    echo "    경고: 서명 인증서가 없어 ad-hoc으로 서명합니다." >&2
    echo "    macOS 권한을 재빌드마다 다시 허용해야 할 수 있습니다." >&2
    SIGN_IDENTITY="-"
fi

codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements Resources/Storybird.entitlements \
    --options runtime \
    --timestamp=none \
    "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo
echo "완료: ${APP_BUNDLE}"
echo "실행: open ${APP_BUNDLE}"
