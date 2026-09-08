#!/usr/bin/env python3
"""Local MLX voice-cloning worker for Storybird."""

import argparse
import json
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf
from mlx_audio.tts.utils import load_model

MODEL_ID = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"


def load():
    """Load the fixed local MLX model used by preparation and generation."""
    started = time.perf_counter()
    model = load_model(MODEL_ID)
    return model, time.perf_counter() - started


def main():
    """Prepare the model cache or generate one complete local narration WAV."""
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare")
    generate = sub.add_parser("generate")
    generate.add_argument("--text", required=True)
    generate.add_argument("--ref-audio", required=True)
    generate.add_argument("--ref-text", required=True)
    generate.add_argument("--language", default="korean")
    generate.add_argument("--output", required=True)
    args = parser.parse_args()

    model, load_seconds = load()
    if args.command == "prepare":
        print(json.dumps({
            "ok": True,
            "model": MODEL_ID,
            "load_seconds": load_seconds,
            "active_memory": mx.get_active_memory(),
        }))
        return

    started = time.perf_counter()
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
        "output": str(output),
        "sample_rate": sample_rate,
        "duration": len(audio) / sample_rate,
        "generation_seconds": time.perf_counter() - started,
        "peak_memory": mx.get_peak_memory(),
    }))


if __name__ == "__main__":
    main()
