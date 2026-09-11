#!/usr/bin/env python3
"""Offline regression tests with real temporary Git repositories and fake gh."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_fixtures", ROOT / "scripts/test-publish-release.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
COLLECTOR = ROOT / ".agents/skills/prepare-storybird-release/scripts/collect_release_facts.sh"

FAKE_GH = '''#!/usr/bin/env python3
import json, os, pathlib, sys
if os.environ.get("TEST_API_FAILURE"):
    sys.exit("simulated authentication or network failure")
if sys.argv[1] != "api":
    sys.exit("unexpected gh operation")
print(json.dumps([json.loads(pathlib.Path(os.environ["TEST_RELEASE_LIST"]).read_text())]))
'''


class CollectReleaseFactsTests(fixtures.ReleaseFixture):
    def setUp(self):
        super().setUp()
        self.releases_path = self.base / "releases.json"
        self.releases_path.write_text("[]")
        self.env["TEST_RELEASE_LIST"] = str(self.releases_path)
        (self.bin / "gh").write_text(FAKE_GH)
        # The collector addresses origin by name; route it to the temporary bare
        # repository just like the publisher fixture routes its explicit URL.
        path = self.bin / "git"
        path.write_text(path.read_text().replace(
            "args = sys.argv[1:]\n",
            'args = sys.argv[1:]\n'
            'if args[:1] == ["ls-remote"] and "origin" in args:\n'
            '    args[args.index("origin")] = os.environ["TEST_REMOTE"]\n',
        ))

    def releases(self, *items):
        self.releases_path.write_text(json.dumps(items))

    def release(self, tag=None, draft=False, date="2026-09-11T00:00:00Z"):
        return {"tag_name": tag or self.tag, "draft": draft,
                "prerelease": False, "published_at": None if draft else date}

    def prepare_tag(self, name=None, push=True, target=None):
        name = name or self.tag
        self.git("tag", "-a", name, target or self.target, "-m", "release")
        if push:
            self.git("push", str(self.remote), "refs/tags/" + name)

    def collect(self, online=True, target=None):
        args = ["bash", str(COLLECTOR), "--target", target or self.target, "--json"]
        if online:
            args.append("--online")
        env = dict(self.env, TEST_GIT_MUTATIONS_DENIED="1")
        result = subprocess.run(args, cwd=self.repo, env=env,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_local_tag_and_draft_do_not_imply_published_or_empty_range(self):
        self.prepare_tag(push=False)
        self.releases(self.release(draft=True))
        facts = self.collect()
        self.assertEqual(facts["release_state"], "draft")
        self.assertEqual(facts["local_tag"]["state"], "present")
        self.assertEqual(facts["remote_tag"]["state"], "absent")
        self.assertIsNone(facts["comparison"]["base"])
        self.assertGreater(facts["comparison"]["commit_count"], 0)
        self.assertIn("Resources/Info.plist", facts["comparison"]["changed_files"])

    def test_pushed_tag_without_release_is_absent(self):
        self.prepare_tag()
        facts = self.collect()
        self.assertEqual(facts["release_state"], "absent")
        self.assertEqual(facts["remote_tag"]["commit"], self.target)
        self.assertEqual(facts["conflicts"], [])

    def test_published_target_is_reported_explicitly(self):
        self.prepare_tag()
        self.releases(self.release())
        self.assertEqual(self.collect()["release_state"], "published")

    def test_offline_never_infers_publication_or_comparison_from_local_tag(self):
        self.prepare_tag(push=False)
        facts = self.collect(online=False)
        self.assertEqual(facts["release_state"], "unknown")
        self.assertEqual(facts["remote_tag"]["state"], "unknown")
        self.assertEqual(facts["comparison"]["state"], "unknown")

    def test_api_failure_is_unknown_not_absent(self):
        self.env["TEST_API_FAILURE"] = "1"
        facts = self.collect()
        self.assertEqual(facts["release_state"], "unknown")
        self.assertEqual(facts["comparison"]["state"], "unknown")
        self.assertTrue(facts["warnings"])

    def test_prior_published_base_excludes_unpublished_intermediate_tags(self):
        base = self.target
        self.prepare_tag("v0.1.0")
        self.git("commit", "--allow-empty", "-m", "unpublished work")
        intermediate = self.git("rev-parse", "HEAD").stdout.strip()
        self.prepare_tag("v0.1.1", target=intermediate)
        self.git("commit", "--allow-empty", "-m", "target change")
        self.target = self.git("rev-parse", "HEAD").stdout.strip()
        self.prepare_tag()
        self.releases(self.release("v0.1.0"), self.release("v0.1.1", draft=True),
                      self.release(draft=True))
        facts = self.collect()
        self.assertEqual(facts["comparison"]["base"], {"tag": "v0.1.0", "commit": base})
        self.assertEqual(facts["comparison"]["commit_count"], 2)

    def test_unresolved_published_base_is_not_silently_first_release(self):
        self.prepare_tag()
        self.releases(self.release("v0.1.1"), self.release(draft=True))
        facts = self.collect()
        self.assertEqual(facts["release_state"], "draft")
        self.assertEqual(facts["comparison"]["state"], "unknown")

    def test_empty_repository_release_list_has_valid_full_history_diff(self):
        facts = self.collect()
        self.assertEqual(facts["local_tag"]["state"], "absent")
        self.assertEqual(facts["release_state"], "absent")
        self.assertEqual(facts["comparison"]["state"], "known")
        self.assertGreater(facts["comparison"]["commit_count"], 0)

    def test_later_head_is_distinct_from_version_tag_commit(self):
        self.prepare_tag()
        release_commit = self.target
        self.git("commit", "--allow-empty", "-m", "later release tools")
        facts = self.collect(target="HEAD")
        self.assertNotEqual(facts["target_sha"], release_commit)
        self.assertEqual(facts["local_tag"]["commit"], release_commit)
        self.assertIn("local_tag does not point to target_sha", facts["conflicts"])
        pinned = self.collect(target=self.tag_name())
        self.assertEqual(pinned["target_sha"], release_commit)
        self.assertEqual(pinned["conflicts"], [])

    def tag_name(self):
        return "v" + self.version

    def test_remote_tag_conflict_is_reported_without_mutation(self):
        self.prepare_tag()
        original = self.git("--git-dir", str(self.remote), "rev-parse", self.tag_name()).stdout
        self.git("tag", "-d", self.tag_name())
        self.git("commit", "--allow-empty", "-m", "different release")
        self.target = self.git("rev-parse", "HEAD").stdout.strip()
        self.prepare_tag(push=False)
        facts = self.collect()
        self.assertIn("remote_tag does not point to target_sha", facts["conflicts"])
        self.assertEqual(self.git("--git-dir", str(self.remote), "rev-parse",
                                  self.tag_name()).stdout, original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
