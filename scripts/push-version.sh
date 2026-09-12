#!/usr/bin/env bash
# Push one prepared release tag from .devcontainer; no build or gh required.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./scripts/push-version.sh VERSION [--check]

Examples:
  ./scripts/push-version.sh 0.1.2
  ./scripts/push-version.sh v0.1.2 --check

Push only the existing annotated version tag to origin.
--check verifies the tag and remote without pushing (also available on macOS).
No branch, working-tree changes, ZIP, or GitHub Release is uploaded.
EOF
}
fail() { printf '오류: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
version="${1#v}"
mode="${2:---push}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "버전은 0.1.2 또는 v0.1.2 형식으로 입력하세요."
[[ "$mode" == "--push" || "$mode" == "--check" ]] || fail "지원하지 않는 옵션: $mode"
if [[ "$mode" == "--push" && "$(uname -s)" != Linux ]]; then
    fail "push는 .devcontainer 안에서 실행하세요. 로컬 확인은 --check를 사용하세요."
fi
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
tag="v${version}"
ref="refs/tags/${tag}"
git show-ref --verify --quiet "$ref" ||
    fail "${tag} 태그가 없습니다. 먼저 macOS에서 해당 버전의 릴리즈 커밋과 태그를 준비하세요."
[[ "$(git cat-file -t "$ref")" == tag ]] || fail "${tag}는 주석이 있는 annotated tag여야 합니다."
target="$(git rev-parse --verify "${ref}^{commit}")"
tag_object="$(git rev-parse "$ref")"
plist="$(git show "${target}:Resources/Info.plist")"
bundle_version="$(printf '%s\n' "$plist" | awk '/<key>CFBundleShortVersionString<\/key>/ {
    getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit
}')"
[[ "$bundle_version" == "$version" ]] ||
    fail "태그의 앱 버전(${bundle_version})과 요청 버전(${version})이 다릅니다."
push_url="$(git remote get-url --push --all origin)"
case "$push_url" in
    git@github.com:haandol/storybird|git@github.com:haandol/storybird.git|\
    https://github.com/haandol/storybird|https://github.com/haandol/storybird.git|\
    ssh://git@github.com/haandol/storybird.git) ;;
    *) fail "origin의 push 대상은 haandol/storybird 하나여야 합니다." ;;
esac

remote_present=false
check_remote() {
    local refs remote_object remote_commit
    refs="$(git ls-remote "$push_url" "$ref" "${ref}^{}")"
    remote_present=false
    if [[ -n "$refs" ]]; then
        remote_object="$(printf '%s\n' "$refs" | awk '$2 !~ /\^\{\}$/ {print $1}')"
        remote_commit="$(printf '%s\n' "$refs" | awk '$2 ~ /\^\{\}$/ {print $1}')"
        [[ "$remote_object" == "$tag_object" && "$remote_commit" == "$target" ]] ||
            fail "원격 ${tag}가 로컬 태그와 다릅니다. 기존 태그를 덮어쓰지 않습니다."
        remote_present=true
    fi
}
check_remote
printf '태그: %s\n커밋: %s\n' "$tag" "$target"
if [[ "$remote_present" == true ]]; then
    printf '%s는 이미 같은 내용으로 push되어 있습니다.\n' "$tag"
elif [[ "$mode" == "--check" ]]; then
    printf '검증 완료. .devcontainer에서 ./scripts/push-version.sh %s 를 실행하세요.\n' "$version"
else
    # Explicit refspec and disabled followTags prevent unrelated refs from being pushed.
    git -c push.followTags=false push "$push_url" "${ref}:${ref}"
    check_remote
    [[ "$remote_present" == true ]] || fail "push 후 원격 태그를 확인하지 못했습니다."
    printf '%s push 완료.\n' "$tag"
fi
if [[ "$mode" == "--push" ]]; then
    printf '에이전트에 "%s push 완료"를 알리면 로컬 macOS gh로 공개와 Latest 지정을 이어갑니다.\n' "$tag"
fi
