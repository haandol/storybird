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


class Array:
    def __init__(self, values, dtype=None):
        self.values = values
        self.dtype = dtype or type(values[0][0])

    def astype(self, dtype):
        return Array(self.values, dtype)

    def __add__(self, other):
        return Array([
            [a + b for a, b in zip(left, right)]
            for left, right in zip(self.values, other.values)
        ], self.dtype)


def where(condition, yes, no):
    values = condition.values
    return Array([
        [(yes.values[i][j] if isinstance(yes, Array) else yes) if value
         else (no.values[i][j] if isinstance(no, Array) else no)
         for j, value in enumerate(row)]
        for i, row in enumerate(values)
    ])


class Decoder:
    def __init__(self, config):
        self.config = config
        self.make_cache = Mock(return_value=["decoder cache"])
        self.forward = Mock(return_value="decoded audio")

    def __call__(self, *args, **kwargs):
        return self.forward(*args, **kwargs)


class VoiceRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.decoder_config = types.SimpleNamespace(sliding_window=72)
        self.tokenizer = types.SimpleNamespace(DecoderTransformer=Decoder)
        self.model = types.SimpleNamespace(generate=Mock(return_value=[
            types.SimpleNamespace(audio=Samples(), sample_rate=24000)
        ]), speech_tokenizer=types.SimpleNamespace(
            decoder=object(),
        ))
        self.loader = Mock(return_value=self.model)
        self.write = Mock()
        modules = {
            "mlx": types.ModuleType("mlx"),
            "mlx.core": types.SimpleNamespace(
                get_active_memory=lambda: 0, get_peak_memory=lambda: 0,
                array=Array, where=where, inf=float("inf"), bool_=bool,
            ),
            "numpy": types.SimpleNamespace(
                float32=float, asarray=lambda *_args, **_kwargs: Samples(),
                concatenate=lambda _: Samples(),
            ),
            "soundfile": types.SimpleNamespace(write=self.write),
            "mlx_audio": types.ModuleType("mlx_audio"),
            "mlx_audio.tts": types.ModuleType("mlx_audio.tts"),
            "mlx_audio.tts.utils": types.SimpleNamespace(load_model=self.loader),
            "mlx_audio.tts.models": types.ModuleType("mlx_audio.tts.models"),
            "mlx_audio.tts.models.qwen3_tts": types.SimpleNamespace(
                speech_tokenizer=self.tokenizer,
            ),
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

    def test_decoder_mask_excludes_future_keys(self):
        self.assertEqual(
            self.worker.decoder_window_mask(3, offset=0, window=72),
            [[True, False, False], [True, True, False], [True, True, True]],
        )

    def test_decoder_mask_keeps_exactly_the_configured_window(self):
        mask = self.worker.decoder_window_mask(73, offset=0, window=72)
        self.assertTrue(mask[71][0])
        self.assertFalse(mask[72][0])
        self.assertEqual(mask[72][1:], [True] * 72)

    def test_decoder_mask_applies_to_one_cached_query(self):
        mask = self.worker.decoder_window_mask(1, offset=100, window=72)
        self.assertEqual(mask, [[False] * 29 + [True] * 72])

    def test_decoder_mask_uses_absolute_positions_for_cached_queries(self):
        self.assertEqual(
            self.worker.decoder_window_mask(2, offset=3, window=3),
            [
                [False, True, True, True, False],
                [False, False, True, True, True],
            ],
        )

    def test_load_restores_window_before_the_library_compiles_the_decoder(self):
        def load(_):
            self.assertIs(self.tokenizer.DecoderTransformer, self.worker.WindowedDecoder)
            return self.model
        self.loader.side_effect = load
        self.worker.load(self.worker.MODEL_ID)

    def test_windowed_decoder_preserves_the_original_cache_factory(self):
        decoder = self.worker.WindowedDecoder(self.decoder_config)
        self.assertEqual(decoder.make_cache(), ["decoder cache"])
        decoder.make_cache.assert_called_once_with()

    def test_decoder_forward_applies_window_and_retains_boolean_mask(self):
        self.decoder_config.sliding_window = 3
        wrapper = self.worker.WindowedDecoder(self.decoder_config)
        inputs = types.SimpleNamespace(shape=(1, 2, 4), dtype=float)
        cache = [types.SimpleNamespace(offset=3)]
        existing = Array([
            [True, True, False, True, True],
            [True, True, True, False, True],
        ])
        self.assertEqual(wrapper(inputs, mask=existing, cache=cache), "decoded audio")
        args, kwargs = wrapper.forward.call_args
        self.assertIs(args[0], inputs)
        self.assertIs(kwargs["cache"], cache)
        neg = -float("inf")
        self.assertEqual(kwargs["mask"].values, [
            [neg, 0.0, neg, 0.0, neg],
            [neg, neg, 0.0, neg, 0.0],
        ])

    def test_decoder_forward_preserves_additive_attention_bias(self):
        wrapper = self.worker.WindowedDecoder(self.decoder_config)
        inputs = types.SimpleNamespace(shape=(1, 2, 4), dtype=float)
        wrapper(inputs, mask=Array([[0.0, -2.0], [-4.0, 0.0]]))
        self.assertEqual(
            wrapper.forward.call_args.kwargs["mask"].values,
            [[0.0, -float("inf")], [-4.0, 0.0]],
        )

    def test_loading_again_does_not_stack_decoder_subclasses(self):
        self.worker.load(self.worker.MODEL_ID)
        decoder = self.tokenizer.DecoderTransformer
        self.worker.load(self.worker.MODEL_ID)
        self.assertIs(self.tokenizer.DecoderTransformer, decoder)


if __name__ == "__main__":
    unittest.main()
