#!/usr/bin/env python3
"""Read-only release facts. Local tags never imply GitHub publication."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import re
import subprocess
import sys


def command(*args, optional=False):
    result = subprocess.run(args, input=b"", capture_output=True, timeout=30)
    if result.returncode:
        if optional:
            return None
        raise RuntimeError(f"{args[0]} {args[1]} failed (exit {result.returncode})")
    return result.stdout.decode("utf-8")


def git(*args, **kwargs):
    return command("git", *args, **kwargs)


def local_tag(name):
    ref = f"refs/tags/{name}"
    obj = git("rev-parse", "--verify", ref, optional=True)
    if obj is None:
        return {"state": "absent", "name": name}
    commit = git("rev-parse", "--verify", f"{ref}^{{commit}}", optional=True)
    return {
        "state": "present", "name": name, "object": obj.strip(),
        "commit": commit.strip() if commit else None,
        "annotated": git("cat-file", "-t", ref).strip() == "tag",
    }


def remote_tag(name, refs):
    if refs is None:
        return {"state": "unknown", "name": name}
    ref = f"refs/tags/{name}"
    if ref not in refs:
        return {"state": "absent", "name": name}
    return {
        "state": "present", "name": name, "object": refs[ref],
        "commit": refs.get(ref + "^{}", refs[ref]),
        "annotated": ref + "^{}" in refs,
    }


def github_repo(origin):
    match = re.fullmatch(
        r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
        r"([^/]+/[^/]+?)(?:\.git)?", origin,
    )
    return match.group(1) if match else None


def collect_comparison(target, tag_name, releases, refs):
    if releases is None or refs is None:
        return {"state": "unknown", "reason": "Published releases or remote tags were not verified."}
    # Publication time chooses the previous release on this target's ancestry,
    # not the nearest local tag or the repository-wide highest version.
    previous = sorted(
        (r for r in releases if not r["draft"] and r["tag_name"] != tag_name
         and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", r["tag_name"])),
        key=lambda r: (r.get("published_at") or "", r["tag_name"]), reverse=True,
    )
    base = None
    for release in previous:
        candidate = remote_tag(release["tag_name"], refs)
        commit = candidate.get("commit")
        if not commit or git("cat-file", "-e", f"{commit}^{{commit}}", optional=True) is None:
            return {
                "state": "unknown",
                "reason": f"Cannot resolve published base {release['tag_name']} in local history.",
            }
        if git("merge-base", "--is-ancestor", commit, target, optional=True) is not None:
            base = {"tag": release["tag_name"], "commit": commit}
            break
    if base:
        log_range = f"{base['commit']}..{target}"
        diff_base = base["commit"]
    else:
        # Empty trees are valid diff bases, but not commit-log range endpoints.
        log_range = target
        diff_base = git("hash-object", "-t", "tree", "--stdin").strip()
    return {
        "state": "known", "base": base,
        "commit_count": int(git("rev-list", "--count", log_range).strip()),
        "commits": git("log", "--reverse", "--format=%h %s%n%b", log_range).strip(),
        "changed_files": git("diff", "--name-status", diff_base, target).strip(),
        "diff_stat": git("diff", "--stat", diff_base, target).strip(),
    }


def collect(target_ref, online):
    target = git("rev-parse", "--verify", "--end-of-options",
                 f"{target_ref}^{{commit}}").strip()
    root = Path(git("rev-parse", "--show-toplevel").strip())
    raw = subprocess.run(["git", "show", f"{target}:Resources/Info.plist"],
                         check=True, capture_output=True).stdout
    plist = plistlib.loads(raw)
    version = plist["CFBundleShortVersionString"]
    name = "v" + version
    facts = {
        "target_ref": target_ref, "target_sha": target, "version": version,
        "build": str(plist["CFBundleVersion"]), "local_tag": local_tag(name),
        "release_state": "unknown", "release": None, "warnings": [], "conflicts": [],
        "working_tree": git("status", "--short").strip(),
    }
    releases = None
    refs = None
    origin = (git("remote", "get-url", "origin", optional=True) or "").strip()
    repo = github_repo(origin)
    facts["repository"] = repo
    if online:
        try:
            output = git("ls-remote", "--tags", "origin")
            refs = dict((ref, sha) for sha, ref in
                        (line.split() for line in output.splitlines()))
        except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
            facts["warnings"].append(f"Remote tags unknown: {error}")
        try:
            if not repo:
                raise RuntimeError("origin is not a supported GitHub repository URL")
            pages = json.loads(command(
                "gh", "api", "--hostname", "github.com", "--paginate", "--slurp",
                f"repos/{repo}/releases?per_page=100",
            ))
            if not isinstance(pages, list) or any(not isinstance(p, list) for p in pages):
                raise ValueError("unexpected paginated release response")
            releases = [release for page in pages for release in page]
            for release in releases:
                if (not isinstance(release, dict)
                        or not isinstance(release.get("tag_name"), str)
                        or type(release.get("draft")) is not bool):
                    raise ValueError("invalid release metadata")
            matches = [r for r in releases if r["tag_name"] == name]
            if len(matches) > 1:
                raise ValueError("multiple releases have the target tag")
            if matches:
                release = matches[0]
                facts["release_state"] = "draft" if release["draft"] else "published"
                facts["release"] = {
                    key: release.get(key)
                    for key in ("tag_name", "name", "prerelease", "published_at", "html_url")
                }
            else:
                facts["release_state"] = "absent"
        except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
            releases = None
            facts["warnings"].append(f"GitHub release state unknown: {error}")
    else:
        facts["warnings"].append("Offline: remote tags and publication were not queried.")
    facts["remote_tag"] = remote_tag(name, refs)
    for field in ("local_tag", "remote_tag"):
        tag = facts[field]
        if tag["state"] == "present" and tag.get("commit") != target:
            facts["conflicts"].append(f"{field} does not point to target_sha")
    if (facts["local_tag"]["state"] == facts["remote_tag"]["state"] == "present"
            and facts["local_tag"]["object"] != facts["remote_tag"]["object"]):
        facts["conflicts"].append("local and remote tag objects differ")
    facts["comparison"] = collect_comparison(target, name, releases, refs)
    artifacts = []
    for relative in ("build/Storybird.app", f"build/Storybird-{version}.zip",
                     f"build/release-notes-v{version}.md"):
        path = root / relative
        if path.exists():
            artifact = {"path": relative, "kind": "file" if path.is_file() else "directory"}
            if path.is_file():
                artifact["bytes"] = path.stat().st_size
                if path.suffix == ".zip":
                    digest = hashlib.sha256()
                    with path.open("rb") as stream:
                        for block in iter(lambda: stream.read(1024 * 1024), b""):
                            digest.update(block)
                    artifact["sha256"] = digest.hexdigest()
            artifacts.append(artifact)
    facts["artifacts"] = artifacts
    return facts


def markdown(facts):
    print("# Storybird release facts\n")
    for key in ("target_ref", "target_sha", "version", "build", "repository", "release_state"):
        print(f"- {key}: `{facts[key]}`")
    for key in ("local_tag", "remote_tag"):
        print(f"- {key}: `{json.dumps(facts[key], ensure_ascii=False)}`")
    print("\n## Publication\n")
    state = facts["release_state"]
    descriptions = {
        "unknown": "공개 상태 미확인. 로컬 태그만으로 공개 여부를 판단하지 않는다.",
        "absent": "해당 버전의 GitHub Release가 없다.",
        "draft": "초안이 있으며 아직 공개되지 않았다.",
        "published": "해당 버전이 이미 공개되어 있다. 같은 버전을 덮어쓰지 않는다.",
    }
    print(descriptions[state])
    for message in facts["conflicts"]:
        print(f"\nCONFLICT: {message}")
    for message in facts["warnings"]:
        print(f"\n미확인: {message}")
    print("\n## Candidate range\n")
    comparison = facts["comparison"]
    if comparison["state"] == "unknown":
        print(f"비교 기준 미확인: {comparison['reason']}")
    else:
        print(f"- Previous published base: `{comparison['base']}`")
        print(f"- Commits in range: `{comparison['commit_count']}`")
        if comparison["base"] is None:
            print("도달 가능한 이전 공개 릴리즈가 없어 전체 commit 이력을 비교한다.")
        for key in ("commits", "changed_files", "diff_stat"):
            print(f"\n### {key}\n\n```text\n{comparison[key] or '(none)'}\n```")
    print(f"\n## Working tree\n\n```text\n{facts['working_tree'] or 'Clean'}\n```")
    print("\n## Local artifacts (presence/checksum only)\n")
    print("```json\n" + json.dumps(facts["artifacts"], indent=2, ensure_ascii=False) + "\n```")
    print("파일 존재와 checksum은 빌드 출처·서명·수동 검증 완료를 뜻하지 않는다.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", default="HEAD", help="Commit or tag to inspect (default: HEAD)")
    parser.add_argument("--online", action="store_true", help="Query remote tags and GitHub releases")
    parser.add_argument("--json", action="store_true", help="Return structured facts")
    args = parser.parse_args()
    try:
        facts = collect(args.target, args.online)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"Release facts failed: {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(facts, indent=2, ensure_ascii=False))
    else:
        markdown(facts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
