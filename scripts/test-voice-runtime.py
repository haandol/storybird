#!/usr/bin/env python3
"""Verify worker model routing without loading MLX, audio or network resources."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch


class Samples:
    def reshape(self, *_):
        return self

    def __len__(self):
        return 24000


class VoiceRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.model = types.SimpleNamespace(generate=Mock(return_value=[
            types.SimpleNamespace(audio=Samples(), sample_rate=24000)
        ]))
        self.loader = Mock(return_value=self.model)
        self.write = Mock()
        modules = {
            "mlx": types.ModuleType("mlx"),
            "mlx.core": types.SimpleNamespace(get_active_memory=lambda: 0, get_peak_memory=lambda: 0),
            "numpy": types.SimpleNamespace(
                float32=float, asarray=lambda *_args, **_kwargs: Samples(),
                concatenate=lambda _: Samples(),
            ),
            "soundfile": types.SimpleNamespace(write=self.write),
            "mlx_audio": types.ModuleType("mlx_audio"),
            "mlx_audio.tts": types.ModuleType("mlx_audio.tts"),
            "mlx_audio.tts.utils": types.SimpleNamespace(load_model=self.loader),
        }
        self.modules = patch.dict(sys.modules, modules)
        self.modules.start()
        self.addCleanup(self.modules.stop)
        path = Path(__file__).resolve().parents[1] / "Resources" / "voice_runtime.py"
        spec = importlib.util.spec_from_file_location("storybird_voice_worker_test", path)
        self.worker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.worker)

    def call(self, *arguments):
        output = io.StringIO()
        with patch.object(sys, "argv", ["voice_runtime.py", *arguments]), contextlib.redirect_stdout(output):
            self.worker.main()
        return json.loads(output.getvalue())

    def test_prepare_selects_each_explicit_8bit_model(self):
        for model_id in self.worker.MODEL_IDS:
            with self.subTest(model=model_id):
                result = self.call("prepare", "--model", model_id)
                self.assertEqual(result["model"], model_id)
                self.loader.assert_called_with(model_id)

    def test_default_keeps_existing_large_model(self):
        self.call("prepare")
        self.loader.assert_called_once_with("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit")

    def test_generate_passes_selected_model_and_reference_without_changing_language(self):
        with tempfile.TemporaryDirectory() as root:
            for model_id in self.worker.MODEL_IDS:
                with self.subTest(model=model_id):
                    result = self.call(
                        "generate", "--model", model_id, "--text", "Synthetic text",
                        "--ref-audio", str(Path(root) / "reference.wav"), "--ref-text", "Reference",
                        "--language", "english", "--output", str(Path(root) / "generated.wav"),
                    )
                    self.assertEqual(result["model"], model_id)
                    self.assertEqual(result["duration"], 1)
                    self.loader.assert_called_with(model_id)
                    self.assertEqual(self.model.generate.call_args.kwargs["lang_code"], "english")
                    self.write.assert_called_with(Path(root) / "generated.wav", unittest.mock.ANY, 24000)

    def test_unapproved_model_is_rejected_before_loading(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            self.call("prepare", "--model", "unapproved/model")
        self.assertEqual(error.exception.code, 2)
        self.loader.assert_not_called()


if __name__ == "__main__":
    unittest.main()
