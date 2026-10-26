#!/usr/bin/env python3
"""Exercise collection, process isolation, failure propagation and bounded waits."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().with_name("run-python-tests.py")


class PythonRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="storybird-python-runner-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write_suite(self, name, body):
        (self.root / name).write_text(body, encoding="utf-8")

    def run_suites(self, *arguments):
        return subprocess.run(
            [sys.executable, str(RUNNER), "--directory", str(self.root), *arguments],
            capture_output=True, text=True, timeout=30,
        )

    def test_hyphenated_names_are_collected_in_isolated_parallel_processes(self):
        for name in ["test-first-suite.py", "test-second-suite.py"]:
            self.write_suite(name, '''import os, time, unittest
from pathlib import Path
class Suite(unittest.TestCase):
    def test_meets_other_worker(self):
        root = Path(__file__).parent
        self.assertNotIn("STORYBIRD_TEST_WORKER_MARKER", os.environ)
        os.environ["STORYBIRD_TEST_WORKER_MARKER"] = "local only"
        (root / (Path(__file__).stem + ".ready")).touch()
        deadline = time.monotonic() + 5
        while len(list(root.glob("*.ready"))) < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(len(list(root.glob("*.ready"))), 2)
''')
        # A non-test helper must not be executed by the collector.
        self.write_suite("helper.py", "raise RuntimeError('not a test')")
        result = self.run_suites("--jobs", "2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2 suites, 0 failed", result.stdout)
        self.assertEqual(result.stdout.count("Ran 1 test"), 2)

    def test_failure_does_not_hide_other_suites_and_returns_nonzero(self):
        self.write_suite("test-a-failing.py", '''import unittest
class Suite(unittest.TestCase):
    def test_fails(self): self.fail("deliberate failure")
''')
        self.write_suite("test-b-passing.py", '''import unittest
class Suite(unittest.TestCase):
    def test_passes(self): self.assertTrue(True)
''')
        result = self.run_suites("--jobs", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deliberate failure", result.stdout)
        self.assertIn("test-b-passing.py: PASS", result.stdout)
        self.assertIn("2 suites, 1 failed", result.stdout)

    def test_empty_collection_empty_module_and_import_failure_are_errors(self):
        self.assertNotEqual(self.run_suites().returncode, 0)
        self.write_suite("test-empty.py", "# no tests\n")
        self.write_suite("test-import.py", "raise RuntimeError('broken import')")
        result = self.run_suites()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no tests collected", result.stdout)
        self.assertIn("broken import", result.stdout)
        self.assertIn("2 suites, 2 failed", result.stdout)

    def test_hanging_suite_times_out_and_reports_failure(self):
        self.write_suite("test-hang.py", '''import subprocess, sys, time, unittest
from pathlib import Path
class Suite(unittest.TestCase):
    def test_hangs(self):
        marker = Path(__file__).with_suffix(".orphan")
        child = "import time; from pathlib import Path; time.sleep(2); Path(" + repr(str(marker)) + ").touch()"
        subprocess.Popen([sys.executable, "-c", child])
        time.sleep(60)
''')
        result = self.run_suites("--timeout", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeded 1s suite timeout", result.stdout)
        # A surviving shell/Git-style descendant would write this after timeout.
        import time
        time.sleep(2)
        self.assertFalse((self.root / "test-hang.orphan").exists())


if __name__ == "__main__":
    unittest.main()
