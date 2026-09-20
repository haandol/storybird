#!/usr/bin/env python3
"""Local MLX voice-cloning and built-in-speaker worker for Storybird."""

import argparse
import json
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf
from mlx_audio.tts.models.qwen3_tts import speech_tokenizer
from mlx_audio.tts.utils import load_model

MODEL_ID = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
CUSTOM_VOICE_MODEL_ID = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
MODEL_IDS = (MODEL_ID, CUSTOM_VOICE_MODEL_ID)
CUSTOM_VOICE_SPEAKERS = (
    "vivian", "serena", "uncle_fu", "dylan", "eric",
    "ryan", "aiden", "ono_anna", "sohee",
)


def decoder_window_mask(query_length, *, offset, window):
    """Keep causal keys inside the decoder checkpoint's attention window."""
    return [
        [offset + query - window < key <= offset + query
         for key in range(offset + query_length)]
        for query in range(query_length)
    ]


class WindowedDecoder(speech_tokenizer.DecoderTransformer):
    """Restore local attention omitted by MLX Audio 0.5.3's codec decoder."""

    def __call__(self, inputs_embeds, mask=None, cache=None):
        offset = cache[0].offset if cache is not None else 0
        allowed = mx.array(decoder_window_mask(
            inputs_embeds.shape[1],
            offset=offset,
            window=self.config.sliding_window,
        ))
        local = mx.where(allowed, 0.0, -mx.inf).astype(inputs_embeds.dtype)
        if mask is not None:
            local = mx.where(mask, local, -mx.inf) if mask.dtype == mx.bool_ else local + mask
        return super().__call__(inputs_embeds, mask=local, cache=cache)


def load(model_id):
    """Load the explicitly selected, allowlisted local MLX model."""
    started = time.perf_counter()
    # Install before load_model compiles the vocoder and captures its call graph.
    speech_tokenizer.DecoderTransformer = WindowedDecoder
    model = load_model(model_id)
    return model, time.perf_counter() - started


def main():
    """Prepare the model cache or generate one complete local narration WAV."""
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--model", choices=MODEL_IDS, default=MODEL_ID)
    generate = sub.add_parser("generate")
    generate.add_argument("--model", choices=MODEL_IDS, default=MODEL_ID)
    generate.add_argument("--text", required=True)
    generate.add_argument("--ref-audio")
    generate.add_argument("--ref-text")
    generate.add_argument("--speaker")
    # None distinguishes omission from an explicitly supplied empty instruction,
    # which still must be rejected when mixed with clone inputs.
    generate.add_argument("--instruct")
    generate.add_argument("--language", default="korean")
    generate.add_argument("--output", required=True)
    args = parser.parse_args()

    if args.command == "generate":
        if args.model == CUSTOM_VOICE_MODEL_ID:
            if args.ref_audio is not None or args.ref_text is not None:
                parser.error("CustomVoice does not accept clone reference inputs")
            if args.speaker is None or args.speaker.lower() not in CUSTOM_VOICE_SPEAKERS:
                parser.error("CustomVoice requires a supported --speaker")
        else:
            if args.speaker is not None or args.instruct is not None:
                parser.error("Base cloning does not accept --speaker or --instruct")
            if not args.ref_audio or not args.ref_text or not args.ref_text.strip():
                parser.error("Base cloning requires --ref-audio and --ref-text")

    model, load_seconds = load(args.model)
    if args.command == "prepare":
        print(json.dumps({
            "ok": True,
            "model": args.model,
            "load_seconds": load_seconds,
            "active_memory": mx.get_active_memory(),
        }))
        return

    started = time.perf_counter()
    if args.model == CUSTOM_VOICE_MODEL_ID:
        # mlx-audio v0.5.3 exposes language (not lang_code) on this method.
        results = list(model.generate_custom_voice(
            text=args.text,
            speaker=args.speaker,
            language=args.language,
            instruct=args.instruct if args.instruct is not None else "",
        ))
    else:
        results = list(model.generate(
            text=args.text,
            ref_audio=args.ref_audio,
            ref_text=args.ref_text,
            lang_code=args.language,
            verbose=False,
        ))
    if not results:
        raise RuntimeError("No audio generated")
    audio = np.concatenate([
        np.asarray(item.audio, dtype=np.float32).reshape(-1)
        for item in results
    ])
    sample_rate = int(getattr(results[0], "sample_rate", 24000))
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    sf.write(output, audio, sample_rate)
    print(json.dumps({
        "ok": True,
        "model": args.model,
        "output": str(output),
        "sample_rate": sample_rate,
        "duration": len(audio) / sample_rate,
        "generation_seconds": time.perf_counter() - started,
        "peak_memory": mx.get_peak_memory(),
    }))


if __name__ == "__main__":
    main()
