#!/bin/bash
#
# Storybird를 빌드하고 macOS 응용 프로그램 폴더에 원자적으로 설치한다.
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Storybird"
SOURCE_APP="build/${APP_NAME}.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DESTINATION_APP="${INSTALL_DIR}/${APP_NAME}.app"
STAGING_APP="${INSTALL_DIR}/.${APP_NAME}.installing"

./build.sh "$CONFIG"

if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "오류: 설치 폴더가 없습니다: ${INSTALL_DIR}" >&2
    exit 1
fi

if [[ -w "$INSTALL_DIR" ]]; then
    run_privileged() { "$@"; }
else
    run_privileged() { sudo "$@"; }
fi

echo "==> ${DESTINATION_APP} 설치"
run_privileged rm -rf "$STAGING_APP"
run_privileged ditto "$SOURCE_APP" "$STAGING_APP"
run_privileged rm -rf "$DESTINATION_APP"
run_privileged mv "$STAGING_APP" "$DESTINATION_APP"

codesign --verify --deep --strict --verbose=2 "$DESTINATION_APP"

echo
echo "설치 완료: ${DESTINATION_APP}"
echo "실행: open \"${DESTINATION_APP}\""
