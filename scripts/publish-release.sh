#!/usr/bin/env bash
# Prepare on macOS, push in .devcontainer, then publish with local macOS gh.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash scripts/publish-release.sh VERSION COMMIT_SHA ZIP_SHA256 [--check|--push|--draft|--publish]

For a simple tag-only push: ./scripts/push-version.sh VERSION

  --check    Validate local inputs and GitHub state without mutations (default).
  --push     Push the current branch and annotated tag (Linux .devcontainer only).
  --draft    Create/verify a draft using gh; the tag must already be pushed.
  --publish  Perform the draft steps, then publish and mark Latest using gh.

Use --publish for a requested publication; it does not stop at the draft step.
Use --draft only when a draft is the requested result.
Disclose unperformed native checks in the notes without claiming they passed.

Required files, prepared and verified on macOS:
  build/Storybird-VERSION.zip
  build/release-notes-vVERSION.md (must include the ZIP SHA-256)

COMMIT_SHA must be the full commit used for the macOS release build.
Only the legacy --push mode requires this commit at a clean, attached HEAD.
The other modes read the specified commit even after later tooling commits.
Existing published releases and mismatched drafts/tags are never overwritten.
--check/--publish verify an identical published release and return without changes;
repeating an older release does not replace the current Latest.
Re-running with the same inputs resumes a matching draft after an interruption.
This script does not build, sign, commit, or perform native smoke tests.
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
[[ $# -ge 3 && $# -le 4 ]] || { usage >&2; exit 2; }
version="$1"
target="$2"
expected_checksum="$3"
mode="${4:---check}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must be X.Y.Z."
[[ "$target" =~ ^[0-9a-f]{40}$ ]] || fail "COMMIT_SHA must be a full Git SHA."
[[ "$expected_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "ZIP_SHA256 must be a lowercase SHA-256."
case "$mode" in --check|--push|--draft|--publish) ;; *) fail "Unknown mode: $mode" ;; esac

for tool in git gh jq unzip cmp; do
    command -v "$tool" >/dev/null || fail "Missing tool: $tool."
done
checksum() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}
if [[ "$mode" == "--push" && "$(uname -s)" != Linux ]]; then
    fail "Run git push from the Linux .devcontainer."
fi
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
git cat-file -e "${target}^{commit}" || fail "COMMIT_SHA is not a local commit."
branch="$(git symbolic-ref --quiet --short HEAD || true)"
if [[ "$mode" == "--push" ]]; then
    [[ -z "$(git status --porcelain)" ]] || fail "Commit or separate pending changes first."
    [[ "$(git rev-parse HEAD)" == "$target" ]] || fail "HEAD differs from COMMIT_SHA."
    [[ -n "$branch" ]] || fail "Detached HEAD is unsupported for --push."
fi
repo="haandol/storybird"
push_url="$(git remote get-url --push --all origin)"
case "$push_url" in
    "git@github.com:${repo}.git"|"git@github.com:${repo}"|\
    "https://github.com/${repo}.git"|"https://github.com/${repo}"|\
    "ssh://git@github.com/${repo}.git") ;;
    *) fail "origin must have exactly one push URL for github.com/${repo}." ;;
esac
tag="v${version}"
title="Storybird ${version}"
archive="build/Storybird-${version}.zip"
asset="${archive##*/}"
notes="build/release-notes-${tag}.md"
[[ -s "$archive" && -s "$notes" ]] || fail "Missing ZIP or release notes; prepare on macOS first."
actual_checksum="$(checksum "$archive")"
[[ "$actual_checksum" == "$expected_checksum" ]] || fail "ZIP SHA-256 mismatch."
grep -Fq "$expected_checksum" "$notes" || fail "Release notes must contain the verified ZIP SHA-256."
unzip -t "$archive" >/dev/null

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
git show "${target}:Resources/Info.plist" > "$scratch/source.plist"
unzip -p "$archive" Storybird.app/Contents/Info.plist > "$scratch/bundle.plist"
cmp -s "$scratch/source.plist" "$scratch/bundle.plist" ||
    fail "ZIP bundle metadata differs from the release commit."
bundle_version="$(awk '/<key>CFBundleShortVersionString<\/key>/ {
    getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit
}' "$scratch/source.plist")"
[[ "$bundle_version" == "$version" ]] || fail "VERSION differs from the committed Info.plist."

if git show-ref --verify --quiet "refs/tags/${tag}"; then
    [[ "$(git cat-file -t "refs/tags/${tag}")" == tag ]] || fail "Local tag must be annotated."
    [[ "$(git rev-parse "refs/tags/${tag}^{commit}")" == "$target" ]] ||
        fail "Local tag points to another commit."
fi
remote_tag_present=false
check_remote_tag() {
    local remote_tags remote_object remote_commit
    remote_tags="$(git ls-remote "$push_url" "refs/tags/${tag}" "refs/tags/${tag}^{}")"
    remote_tag_present=false
    if [[ -n "$remote_tags" ]]; then
        remote_tag_present=true
        remote_object="$(printf '%s\n' "$remote_tags" | awk '$2 !~ /\^\{\}$/ {print $1}')"
        remote_commit="$(printf '%s\n' "$remote_tags" | awk '$2 ~ /\^\{\}$/ {print $1}')"
        [[ "$remote_commit" == "$target" ]] || fail "Remote tag is unannotated or points elsewhere."
        if git show-ref --verify --quiet "refs/tags/${tag}"; then
            [[ "$(git rev-parse "refs/tags/${tag}")" == "$remote_object" ]] ||
                fail "Local and remote tag objects differ; inspect before continuing."
        fi
    fi
}
check_remote_tag
if [[ "$mode" == "--draft" || "$mode" == "--publish" ]]; then
    [[ "$remote_tag_present" == true ]] ||
        fail "Push the release tag in .devcontainer first: ./scripts/push-version.sh ${version}"
fi
gh auth status --hostname github.com >/dev/null ||
    fail "Authenticate GitHub CLI in this environment first: gh auth login --hostname github.com"
# Listing distinguishes an absent release from authentication/network failures.
gh api --hostname github.com --paginate "repos/${repo}/releases?per_page=100" |
    jq -s --arg tag "$tag" 'add // [] | map(select(.tag_name == $tag))' > "$scratch/matches.json"
count="$(jq 'length' "$scratch/matches.json")"
[[ "$count" -le 1 ]] || fail "Multiple releases use this tag."

verify_release() {
    local expected_draft="$1"
    gh release view "$tag" --repo "github.com/${repo}" \
        --json tagName,name,body,isDraft,isPrerelease,assets,url > "$scratch/release.json"
    jq -e --arg tag "$tag" --arg title "$title" --argjson draft "$expected_draft" \
        --rawfile notes "$notes" '
        .tagName == $tag and .name == $title and .isDraft == $draft
        and .isPrerelease == false
        and ((.body | gsub("\r\n"; "\n") | sub("\n+$"; ""))
             == ($notes | gsub("\r\n"; "\n") | sub("\n+$"; "")))
    ' "$scratch/release.json" >/dev/null || fail "Release metadata/notes mismatch."
    jq -e --arg asset "$asset" '.assets | length == 1 and .[0].name == $asset' \
        "$scratch/release.json" >/dev/null || fail "Release must contain exactly the expected ZIP."
    # Verify actual uploaded bytes, including when resuming an existing draft.
    local download_dir
    download_dir="$(mktemp -d "$scratch/download.XXXXXX")"
    gh release download "$tag" --repo "github.com/${repo}" --pattern "$asset" --dir "$download_dir"
    [[ "$(checksum "$download_dir/$asset")" == "$expected_checksum" ]] ||
        fail "Uploaded ZIP SHA-256 mismatch."
}
if [[ "$count" == 1 ]]; then
    if [[ "$(jq -r '.[0].draft' "$scratch/matches.json")" == true ]]; then
        verify_release true
    else
        [[ "$mode" == "--check" || "$mode" == "--publish" ]] ||
            fail "This version is already published. Use a new version."
        verify_release false
        printf 'Already published and verified. No release or Latest changes were made.\n'
        jq -r '.url' "$scratch/release.json"
        exit 0
    fi
fi

printf 'Repository: %s\nBranch: %s\nCommit: %s\nTitle: %s\nZIP: %s\nSHA-256: %s\nMode: %s\n\n' \
    "$repo" "${branch:-(detached)}" "$target" "$title" "$archive" "$expected_checksum" "$mode"
cat "$notes"
printf '\n'
if [[ "$mode" == "--check" ]]; then
    printf 'Checks passed. No local tags, pushes, or release changes were made.\n'
    exit 0
fi

if [[ "$mode" == "--push" ]]; then
    # Reuse the exact remote tag object after an interruption or fresh checkout.
    if ! git show-ref --verify --quiet "refs/tags/${tag}"; then
        if [[ "$remote_tag_present" == true ]]; then
            git fetch --no-tags "$push_url" "refs/tags/${tag}:refs/tags/${tag}"
        else
            git -c tag.gpgSign=false tag -a "$tag" "$target" -m "$title"
        fi
    fi
    check_remote_tag
    # No force pushes. Both refs succeed together or neither is updated.
    git -c push.followTags=false push --atomic "$push_url" \
        "${target}:refs/heads/${branch}" "refs/tags/${tag}:refs/tags/${tag}"
    check_remote_tag
    printf 'Push verified. Run the same script with --draft or --publish locally using gh.\n'
    exit 0
fi
if [[ "$count" == 0 ]]; then
    # The verified tag may be ahead of the default branch after a tag-only push.
    # Do not ask gh to infer new commits from default-branch release history.
    gh release create "$tag" "$archive" --repo "github.com/${repo}" --draft \
        --verify-tag --target "$target" \
        --title "$title" --notes-file "$notes"
fi
verify_release true
if [[ "$mode" == "--publish" ]]; then
    gh release edit "$tag" --repo "github.com/${repo}" --draft=false --latest --verify-tag
    verify_release false
    latest="$(gh api --hostname github.com "repos/${repo}/releases/latest" --jq .tag_name)"
    [[ "$latest" == "$tag" ]] || fail "Published, but Latest differs; inspect GitHub release state."
fi
jq -r '.url' "$scratch/release.json"
