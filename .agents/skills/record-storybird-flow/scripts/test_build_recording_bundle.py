#!/usr/bin/env python3
"""Regression tests for the Storybird agent recording package builder."""

from __future__ import annotations

import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib


SCRIPT_DIR = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIR.parents[3]
BUILDER = SCRIPT_DIR / "build_recording_bundle.py"
SOURCE_PNG = REPOSITORY_ROOT / "Resources" / "AppIcon-generated.png"
SECRET = b"session-secret"


def png_with_text_chunk(source: Path, destination: Path) -> None:
    data = source.read_bytes()
    position = data.rfind(b"IEND") - 4
    if position < 8:
        raise ValueError("source PNG has no IEND chunk")
    payload = b"cookies\x00" + SECRET
    chunk_type = b"tEXt"
    chunk = (
        struct.pack(">I", len(payload))
        + chunk_type
        + payload
        + struct.pack(">I", zlib.crc32(chunk_type + payload) & 0xFFFFFFFF)
    )
    destination.write_bytes(data[:position] + chunk + data[position:])


def run_builder(spec: Path, output: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            str(BUILDER),
            "--spec",
            str(spec),
            "--output",
            str(output),
        ],
        capture_output=True,
        text=True,
    )


class BuildRecordingBundleTests(unittest.TestCase):
    def test_builder_strips_hidden_png_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_png = root / "input.png"
            png_with_text_chunk(SOURCE_PNG, input_png)
            self.assertIn(SECRET, input_png.read_bytes())

            spec = root / "spec.json"
            spec.write_text(
                json.dumps(
                    {
                        "project_name": "Metadata test",
                        "source_name": "Fixture browser",
                        "steps": [
                            {"image": str(input_png)},
                            {
                                "image": str(input_png),
                                "click": {"x": 0.5, "y": 0.25},
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )
            output = root / "recording.storybirdrecording"

            result = run_builder(spec, output)
            self.assertEqual(result.returncode, 0, result.stderr)

            for asset in sorted((output / "assets").glob("*.png")):
                self.assertNotIn(SECRET, asset.read_bytes())
            manifest = json.loads(
                (output / "manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(manifest["version"], 1)
            self.assertEqual(len(manifest["steps"]), 2)

    def test_builder_rejects_out_of_range_click_without_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spec = root / "spec.json"
            spec.write_text(
                json.dumps(
                    {
                        "project_name": "Invalid click",
                        "source_name": "Fixture browser",
                        "steps": [
                            {"image": str(SOURCE_PNG)},
                            {
                                "image": str(SOURCE_PNG),
                                "click": {"x": 1.1, "y": 0.25},
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )
            output = root / "recording.storybirdrecording"

            result = run_builder(spec, output)

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
