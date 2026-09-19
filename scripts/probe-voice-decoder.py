#!/usr/bin/env python3
"""Compare cached Qwen codec tokens with a float reference, without synthesis."""

import argparse
import importlib.util
import json
from pathlib import Path

import mlx.core as mx
import numpy as np

from voice_waveform_metrics import compare_waveforms


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--codes", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--reference-sample-rate", type=int, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--original", action="store_true")
    args = parser.parse_args()
    path = Path(__file__).resolve().parents[1] / "Resources" / "voice_runtime.py"
    spec = importlib.util.spec_from_file_location("voice_worker", path)
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    if args.model not in worker.MODEL_IDS:
        parser.error("Use one of Storybird's supported local models")
    if args.original:
        model = worker.load_model(args.model)
    else:
        model, _ = worker.load(args.model)
    codes = mx.array(np.load(args.codes, allow_pickle=False))
    audio, lengths = model.speech_tokenizer.decode(mx.transpose(codes, (0, 2, 1)))
    mx.eval(audio, lengths)
    candidate = np.asarray(audio[0])[:int(lengths[0])]
    reference = np.load(args.reference, allow_pickle=False)
    metrics = compare_waveforms(reference, candidate, args.reference_sample_rate, model.sample_rate)
    metrics.update(model=args.model, original_decoder=args.original)
    args.output.write_text(json.dumps(metrics, indent=2) + "\n")
    print(json.dumps(metrics), flush=True)


if __name__ == "__main__":
    main()
