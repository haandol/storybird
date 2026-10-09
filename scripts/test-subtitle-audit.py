#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / ".agents/skills/create-storybird-video/scripts/check-subtitles.py"
SPEC = importlib.util.spec_from_file_location("subtitle_audit", SCRIPT)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class SubtitleAuditTests(unittest.TestCase):
    def subtitle(self, identifier, start, text, size=24, position="bottom"):
        return dict(id=identifier, startTime=start, text=text, position=position, style=dict(fontSize=size))

    def test_saved_order_and_wrapping_preserve_complete_source(self):
        project = {"subtitles": [self.subtitle("b", 1, "끝까지 표시합니다."), self.subtitle("a", 0, "전체\n문구를")]}
        result = AUDIT.audit({"project": project}, "전체 문구를 끝까지 표시합니다.")
        self.assertTrue(result["ok"])
        self.assertEqual(result["subtitle_count"], 2)

    def test_missing_repeated_reordered_and_broken_words_fail(self):
        for text in ["전체 문구를", "전체 전체 문구를 표시합니다.", "문구를 전체 표시합니다.", "전 체 문구를 표시합니다."]:
            with self.subTest(text=text):
                result = AUDIT.audit({"subtitles": [self.subtitle("a", 0, text)]}, "전체 문구를 표시합니다.")
                self.assertFalse(result["ok"])
                self.assertEqual(result["issues"][0]["kind"], "source_text_mismatch")

    def test_cue_subtitles_share_sequence_style(self):
        project = {"subtitles": [self.subtitle("a", 0, "First")], "clicks": [
            {"id": "b", "cueSubtitle": self.subtitle("b", 1, "Second", size=18)}]}
        self.assertFalse(AUDIT.audit(project, "First Second")["ok"])
        self.assertTrue(AUDIT.audit(project, "First Second", allow_style_variation=True)["ok"])
        self.assertFalse(AUDIT.audit(project, "First", allow_style_variation=True)["ok"])

    def test_targeted_scope_requires_every_selected_id(self):
        project = {"subtitles": [self.subtitle("a", 0, "Keep"), self.subtitle("b", 1, "Target")]}
        self.assertTrue(AUDIT.audit(project, "Target", ["b"])["ok"])
        self.assertFalse(AUDIT.audit(project, "Target", ["b", "missing"])["ok"])

    def test_cli_returns_failure_for_missing_text_and_success_after_repair(self):
        with tempfile.TemporaryDirectory() as root:
            project = Path(root) / "project.json"
            source = Path(root) / "source.txt"
            source.write_text("Complete source text.", encoding="utf-8")
            for text, status in [("Complete", 1), ("Complete source text.", 0)]:
                project.write_text(json.dumps({"subtitles": [self.subtitle("a", 0, text)]}), encoding="utf-8")
                result = subprocess.run([sys.executable, str(SCRIPT), "--project", str(project), "--source", str(source)],
                                        capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, status)
                self.assertEqual(json.loads(result.stdout)["ok"], status == 0)


if __name__ == "__main__":
    unittest.main()
