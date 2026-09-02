#!/bin/bash
#
# Storybird 앱 아이콘 마스터 PNG를 GPT Image로 생성한다.
# 기존 Resources/AppIcon.svg는 덮어쓰지 않으며 결과를 별도 파일로 저장한다.
set -euo pipefail

cd "$(dirname "$0")/.."

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
IMAGE_GEN="${IMAGE_GEN:-$CODEX_HOME/skills/.system/imagegen/scripts/image_gen.py}"
PROMPT_FILE="Resources/StorybirdIcon.prompt.txt"
OUTPUT="${STORYBIRD_ICON_OUTPUT:-Resources/AppIcon-generated.png}"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "오류: OPENAI_API_KEY가 현재 환경에 없습니다." >&2
    exit 1
fi

if [[ ! -f "$IMAGE_GEN" ]]; then
    echo "오류: imagegen CLI를 찾을 수 없습니다: $IMAGE_GEN" >&2
    exit 1
fi

case "${1:-}" in
    "")
        force=false
        ;;
    --force)
        force=true
        ;;
    *)
        echo "Usage: $0 [--force]" >&2
        exit 2
        ;;
esac

mkdir -p "$(dirname "$OUTPUT")"

generate_icon() {
    uv run --with openai python "$IMAGE_GEN" generate \
        --model gpt-image-2 \
        --prompt-file "$PROMPT_FILE" \
        --use-case logo-brand \
        --size 1024x1024 \
        --quality high \
        --output-format png \
        --no-augment \
        --out "$OUTPUT" \
        "$@"
}

if [[ "$force" == true ]]; then
    generate_icon --force
else
    generate_icon
fi

echo "완료: $OUTPUT"
