#!/usr/bin/env python3
"""Offline publisher checks: temporary Git repositories and a fake GitHub CLI."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
REAL_GIT = shutil.which("git")

FAKE_GIT = r'''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if os.environ.get("TEST_GIT_MUTATIONS_DENIED") and any(x in args for x in ("push", "fetch", "tag")):
    sys.exit("unexpected Git mutation from local gh mode")
for i, arg in enumerate(args):
    if arg == "git@github.com:haandol/storybird.git":
        args[i] = os.environ["TEST_REMOTE"]
sys.exit(subprocess.call([os.environ["TEST_GIT"], *args]))
'''

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
a = sys.argv[1:]
state = pathlib.Path(os.environ["TEST_STATE"])
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(json.dumps(a) + "\n")
def option(name): return a[a.index(name) + 1]
def save(value): state.write_text(json.dumps(value))
s = json.loads(state.read_text()) if state.exists() else None
if a[:2] == ["auth", "status"]:
    pass
elif a[0] == "api":
    if os.environ.get("TEST_API_FAILURE"):
        sys.exit("simulated API outage")
    if any(x.endswith("/releases/latest") for x in a):
        print(s["tagName"])
    else:
        print(json.dumps([{"tag_name": s["tagName"], "draft": s["isDraft"]}] if s else []))
elif a[:2] == ["release", "create"]:
    if s: sys.exit("release already exists")
    if os.environ.get("TEST_CREATE_FAILURE"): sys.exit("simulated create failure")
    s = {
        "tagName": a[2], "name": option("--title"),
        "body": pathlib.Path(option("--notes-file")).read_text(),
        "isDraft": True, "isPrerelease": False,
        "assets": [{"name": pathlib.Path(a[3]).name}],
        "url": "https://example.invalid/release",
    }
    shutil.copyfile(a[3], str(state) + ".zip")
    save(s)
elif a[:2] == ["release", "view"]:
    if not s: sys.exit("missing release")
    print(json.dumps(s))
elif a[:2] == ["release", "download"]:
    dest = pathlib.Path(option("--dir")) / option("--pattern")
    shutil.copyfile(str(state) + ".zip", dest)
elif a[:2] == ["release", "edit"]:
    if not s or not s["isDraft"]: sys.exit("not a draft")
    s["isDraft"] = False
    save(s)
else:
    sys.exit("unsupported fake gh call: " + repr(a))
'''


class ReleaseFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="storybird-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.remote = self.base / "remote.git"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith("GIT_") or key.startswith("GH_"):
                self.env.pop(key)
        self.env.update(
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
            GIT_TERMINAL_PROMPT="0", TEST_GIT=REAL_GIT,
            TEST_REMOTE=str(self.remote), TEST_STATE=str(self.base / "release.json"),
            TEST_LOG=str(self.base / "gh.log"),
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
        )
        for name, content in [("git", FAKE_GIT), ("gh", FAKE_GH),
                              ("uname", '#!/bin/sh\nprintf "%s\\n" "${TEST_KERNEL:-Linux}"\n')]:
            path = self.bin / name
            path.write_text(content)
            path.chmod(0o755)
        # macOS need not have GNU sha256sum; container uses its real implementation.
        if not shutil.which("sha256sum"):
            path = self.bin / "sha256sum"
            path.write_text("#!/bin/sh\nexec shasum -a 256 \"$@\"\n")
            path.chmod(0o755)
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("remote", "add", "origin", "git@github.com:haandol/storybird.git")
        (self.repo / "scripts").mkdir()
        shutil.copyfile(ROOT / "scripts/publish-release.sh",
                        self.repo / "scripts/publish-release.sh")
        shutil.copy2(ROOT / "scripts/push-version.sh",
                     self.repo / "scripts/push-version.sh")
        (self.repo / ".gitignore").write_text("build/\n")
        (self.repo / "Resources").mkdir()
        self.plist = (ROOT / "Resources/Info.plist").read_bytes()
        (self.repo / "Resources/Info.plist").write_bytes(self.plist)
        import plistlib
        self.version = plistlib.loads(self.plist)["CFBundleShortVersionString"]
        self.tag = "v" + self.version
        self.git("add", ".")
        self.git("commit", "-m", "test fixture")
        self.target = self.git("rev-parse", "HEAD").stdout.strip()
        (self.repo / "build").mkdir()
        self.archive = self.repo / f"build/Storybird-{self.version}.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Storybird.app/Contents/Info.plist", self.plist)
            archive.writestr("Storybird.app/Contents/MacOS/Storybird", b"synthetic")
        self.checksum = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.notes = self.repo / f"build/release-notes-{self.tag}.md"
        self.notes.write_text(f"# Storybird {self.version}\n\n테스트 릴리즈\n\nSHA-256: {self.checksum}\n")

    def git(self, *args):
        return subprocess.run([REAL_GIT, *args], cwd=self.repo, env=self.env,
                              text=True, capture_output=True, check=True)

    def run_script(self, mode="--check", *, checksum=None, success=True):
        result = subprocess.run(
            ["bash", "scripts/publish-release.sh", self.version, self.target,
             checksum or self.checksum, mode],
            cwd=self.repo, env=self.env, text=True, capture_output=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def state(self):
        return json.loads(Path(self.env["TEST_STATE"]).read_text())


class PublishReleaseTests(ReleaseFixture):
    def test_check_has_no_mutations(self):
        self.run_script()
        self.assertFalse(Path(self.env["TEST_STATE"]).exists())
        self.assertEqual(self.git("tag", "--list").stdout, "")
        self.assertEqual(self.git("--git-dir", str(self.remote), "for-each-ref").stdout, "")

    def test_draft_then_publish_and_reject_republication(self):
        self.run_script("--push")
        self.run_script("--draft")
        self.assertTrue(self.state()["isDraft"])
        remote_sha = self.git("--git-dir", str(self.remote), "rev-parse", self.tag + "^{}").stdout.strip()
        self.assertEqual(remote_sha, self.target)
        self.run_script("--publish")
        self.assertFalse(self.state()["isDraft"])
        result = self.run_script("--publish", success=False)
        self.assertIn("already published", result.stderr)

    def test_publish_creates_and_verifies_draft_first(self):
        self.run_script("--push")
        self.env["TEST_KERNEL"] = "Darwin"
        self.env["TEST_GIT_MUTATIONS_DENIED"] = "1"
        self.run_script("--publish")
        calls = [json.loads(line) for line in Path(self.env["TEST_LOG"]).read_text().splitlines()]
        download = next(i for i, call in enumerate(calls) if call[:2] == ["release", "download"])
        publish = next(i for i, call in enumerate(calls) if call[:2] == ["release", "edit"])
        self.assertLess(download, publish)
        self.assertFalse(self.state()["isDraft"])

    def test_checksum_mismatch_prevents_push(self):
        self.notes.write_text("SHA-256: " + "0" * 64 + "\n")
        self.run_script("--push", checksum="0" * 64, success=False)
        self.assertEqual(self.git("--git-dir", str(self.remote), "for-each-ref").stdout, "")

    def test_dirty_tree_prevents_push(self):
        (self.repo / "pending.txt").write_text("pending")
        self.run_script("--push", success=False)
        self.assertEqual(self.git("--git-dir", str(self.remote), "for-each-ref").stdout, "")

    def test_wrong_head_is_rejected(self):
        self.git("commit", "--allow-empty", "-m", "later tooling")
        self.assertIn("HEAD differs", self.run_script("--push", success=False).stderr)

    def test_local_publication_uses_prepared_commit_after_later_local_changes(self):
        self.run_script("--push")
        self.git("commit", "--allow-empty", "-m", "later tooling")
        (self.repo / "Resources/Info.plist").write_text("unrelated uncommitted changes")
        self.env["TEST_KERNEL"] = "Darwin"
        self.env["TEST_GIT_MUTATIONS_DENIED"] = "1"
        self.run_script("--publish")
        self.assertFalse(self.state()["isDraft"])

    def test_zip_from_different_version_is_rejected(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Storybird.app/Contents/Info.plist", b"wrong bundle")
        self.checksum = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.notes.write_text(self.checksum)
        self.assertIn("metadata differs", self.run_script("--push", success=False).stderr)

    def test_api_failure_prevents_push(self):
        self.env["TEST_API_FAILURE"] = "1"
        self.run_script("--push", success=False)
        self.assertEqual(self.git("--git-dir", str(self.remote), "for-each-ref").stdout, "")

    def test_mismatched_uploaded_asset_prevents_publication(self):
        self.run_script("--push")
        self.run_script("--draft")
        Path(self.env["TEST_STATE"] + ".zip").write_bytes(b"corrupt upload")
        self.assertIn("Uploaded ZIP", self.run_script("--publish", success=False).stderr)
        self.assertTrue(self.state()["isDraft"])

    def test_changed_notes_prevent_publication(self):
        self.run_script("--push")
        self.run_script("--draft")
        self.notes.write_text(self.notes.read_text() + "\nUnreviewed change\n")
        self.assertIn("metadata/notes mismatch", self.run_script("--publish", success=False).stderr)
        self.assertTrue(self.state()["isDraft"])

    def test_lightweight_tag_is_rejected(self):
        self.git("tag", self.tag)
        self.assertIn("annotated", self.run_script("--draft", success=False).stderr)

    def test_resume_after_push_and_failed_create(self):
        self.run_script("--push")
        self.env["TEST_CREATE_FAILURE"] = "1"
        self.run_script("--draft", success=False)
        self.assertEqual(self.git("--git-dir", str(self.remote), "rev-parse", self.tag + "^{}")
                         .stdout.strip(), self.target)
        del self.env["TEST_CREATE_FAILURE"]
        # A fresh checkout can reuse the existing remote annotated tag.
        self.git("tag", "-d", self.tag)
        self.run_script("--push")
        self.run_script("--publish")
        self.assertFalse(self.state()["isDraft"])

    def test_nonfastforward_push_leaves_tag_absent(self):
        clone = self.base / "other"
        self.git("clone", str(self.repo), str(clone))
        self.git("-C", str(clone), "-c", "user.name=Test", "-c",
                 "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "remote newer")
        self.git("-C", str(clone), "push", str(self.remote), "HEAD:refs/heads/main")
        self.run_script("--push", success=False)
        self.assertEqual(self.git("--git-dir", str(self.remote), "tag", "--list").stdout, "")
        self.assertFalse(Path(self.env["TEST_STATE"]).exists())

    def test_local_push_is_blocked(self):
        self.env["TEST_KERNEL"] = "Darwin"
        self.assertIn(".devcontainer", self.run_script("--push", success=False).stderr)
        self.assertEqual(self.git("--git-dir", str(self.remote), "for-each-ref").stdout, "")

    def test_local_publish_requires_remote_tag_without_pushing(self):
        self.env["TEST_KERNEL"] = "Darwin"
        self.env["TEST_GIT_MUTATIONS_DENIED"] = "1"
        self.assertIn("Push the release tag", self.run_script("--publish", success=False).stderr)
        self.assertEqual(self.git("--git-dir", str(self.remote), "for-each-ref").stdout, "")

    def test_remote_tag_on_wrong_commit_is_rejected(self):
        self.git("commit", "--allow-empty", "-m", "other commit")
        self.git("tag", "-a", self.tag, "-m", "wrong release")
        self.git("push", str(self.remote), "refs/tags/" + self.tag)
        self.git("checkout", "--detach", self.target)
        self.git("branch", "-f", "main", self.target)
        self.git("checkout", "main")
        self.git("tag", "-d", self.tag)
        self.assertIn("points elsewhere", self.run_script("--publish", success=False).stderr)


class PushVersionTests(ReleaseFixture):
    def prepared_tag(self):
        self.git("tag", "-a", self.tag, "-m", "prepared release", self.target)

    def push_version(self, version=None, check=False, success=True):
        command = ["./scripts/push-version.sh", version or self.version]
        if check:
            command.append("--check")
        result = subprocess.run(command, cwd=self.repo, env=self.env,
                                text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_prepared_tag_pushes_without_assets_or_gh_and_ignores_later_changes(self):
        self.prepared_tag()
        self.git("commit", "--allow-empty", "-m", "later tooling")
        (self.repo / "pending.txt").write_text("uncommitted local work")
        self.archive.unlink()
        self.notes.unlink()
        (self.bin / "gh").write_text("#!/bin/sh\nexit 91\n")
        self.git("config", "push.followTags", "true")
        self.git("tag", "-a", "unrelated", "-m", "must stay local", self.target)
        self.push_version()
        refs = self.git("--git-dir", str(self.remote), "for-each-ref",
                        "--format=%(refname)").stdout.splitlines()
        self.assertEqual(refs, ["refs/tags/" + self.tag])
        self.assertEqual(self.git("--git-dir", str(self.remote), "rev-parse",
                                  self.tag + "^{}").stdout.strip(), self.target)

    def test_v_prefix_and_same_remote_tag_are_idempotent(self):
        self.prepared_tag()
        self.push_version(self.tag)
        self.env["TEST_GIT_MUTATIONS_DENIED"] = "1"
        self.assertIn("이미", self.push_version().stdout)

    def test_read_only_check_on_macos_does_not_push(self):
        self.prepared_tag()
        self.env["TEST_KERNEL"] = "Darwin"
        self.env["TEST_GIT_MUTATIONS_DENIED"] = "1"
        self.push_version(check=True)
        self.assertEqual(self.git("--git-dir", str(self.remote), "for-each-ref").stdout, "")

    def test_missing_tag_is_not_created(self):
        self.assertIn("태그가 없습니다", self.push_version(success=False).stderr)
        self.assertEqual(self.git("tag", "--list").stdout, "")

    def test_mismatched_version_is_not_pushed(self):
        self.git("tag", "-a", "v99.99.99", "-m", "incorrect version")
        self.assertIn("요청 버전", self.push_version("99.99.99", success=False).stderr)
        self.assertEqual(self.git("--git-dir", str(self.remote), "for-each-ref").stdout, "")

    def test_conflicting_remote_tag_is_preserved(self):
        self.prepared_tag()
        self.git("push", str(self.remote), "refs/tags/" + self.tag)
        old_object = self.git("--git-dir", str(self.remote), "rev-parse", self.tag).stdout
        # Same commit but different tag metadata must also be rejected.
        self.git("tag", "-d", self.tag)
        self.git("tag", "-a", self.tag, "-m", "different tag object")
        self.assertIn("덮어쓰지 않습니다", self.push_version(success=False).stderr)
        self.assertEqual(self.git("--git-dir", str(self.remote), "rev-parse",
                                  self.tag).stdout, old_object)

    def test_macos_push_is_rejected(self):
        self.prepared_tag()
        self.env["TEST_KERNEL"] = "Darwin"
        self.assertIn(".devcontainer", self.push_version(success=False).stderr)

    def test_lightweight_tag_is_rejected(self):
        self.git("tag", self.tag)
        self.assertIn("annotated", self.push_version(success=False).stderr)

    def test_malformed_version_is_rejected(self):
        for version in ["--all", "0.1", "0.1.2;echo bad", "refs/tags/v0.1.2"]:
            with self.subTest(version=version):
                self.push_version(version, success=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
