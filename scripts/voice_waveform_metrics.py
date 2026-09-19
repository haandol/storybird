"""Strict metrics for like-for-like decoder probes, not a voice-quality score."""

import numpy as np


def compare_waveforms(reference, candidate, reference_rate, candidate_rate):
    reference = np.asarray(reference, dtype=np.float64)
    candidate = np.asarray(candidate, dtype=np.float64)
    if reference_rate <= 0 or reference_rate != candidate_rate:
        raise ValueError("Sample rates must be positive and equal")
    if reference.ndim != 1 or candidate.ndim != 1:
        raise ValueError("Compare mono waveforms without flattening channels")
    if reference.size == 0 or reference.shape != candidate.shape:
        raise ValueError(
            f"Waveform lengths differ or are empty: {reference.size} / {candidate.size}"
        )
    if not np.all(np.isfinite(reference)) or not np.all(np.isfinite(candidate)):
        raise ValueError("Waveforms must contain only finite samples")
    reference_norm = np.linalg.norm(reference)
    if reference_norm == 0 or np.std(reference) == 0 or np.std(candidate) == 0:
        raise ValueError("A silent or constant waveform cannot establish decoder parity")
    difference = reference - candidate
    return {
        "reference_samples": int(reference.size),
        "candidate_samples": int(candidate.size),
        "sample_rate": int(reference_rate),
        "relative_l2_error": float(np.linalg.norm(difference) / reference_norm),
        "correlation": float(np.corrcoef(reference, candidate)[0, 1]),
        "maximum_absolute_difference": float(np.max(np.abs(difference))),
    }
