#!/usr/bin/env python3
import unittest

from voice_waveform_metrics import compare_waveforms


class VoiceWaveformMetricsTests(unittest.TestCase):
    def test_matching_waveforms_report_complete_sample_counts(self):
        result = compare_waveforms([0, 0.2, -0.4], [0, 0.2, -0.4], 24000, 24000)
        self.assertEqual(result["reference_samples"], 3)
        self.assertEqual(result["candidate_samples"], 3)
        self.assertEqual(result["relative_l2_error"], 0)

    def test_identical_prefix_with_missing_tail_fails(self):
        with self.assertRaisesRegex(ValueError, "lengths"):
            compare_waveforms([0, 0.2, -0.4], [0, 0.2], 24000, 24000)

    def test_different_sample_rate_fails(self):
        with self.assertRaisesRegex(ValueError, "rates"):
            compare_waveforms([0, 1], [0, 1], 24000, 48000)

    def test_invalid_waveforms_fail_instead_of_reporting_parity(self):
        for reference, candidate in [
            ([], []), ([0, 1], [0, float("nan")]), ([0, float("inf")], [0, 1]),
            ([0, 0], [0, 0]), ([[0, 1]], [[0, 1]]),
        ]:
            with self.subTest(reference=reference, candidate=candidate):
                with self.assertRaises(ValueError):
                    compare_waveforms(reference, candidate, 24000, 24000)


if __name__ == "__main__":
    unittest.main()
