#!/usr/bin/env python3
"""Unit tests for Kokoro voice blending. No live model required."""

from __future__ import annotations

import math
import sys
import unittest
from pathlib import Path

import numpy as np

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import kokoro_server as ks  # noqa: E402


def style_loader(**named):
    def get_style(name: str):
        return named[name]

    return get_style


class DefaultVoiceTests(unittest.TestCase):
    def test_server_default_is_nway_blend(self):
        self.assertEqual(
            ks.DEFAULT_VOICE, "af_nova:0.6+af_nicole:0.3+af_heart:0.1"
        )
        self.assertEqual(ks.VOICE, ks.DEFAULT_VOICE)
        self.assertEqual(ks.VOICE_STYLE, ks.DEFAULT_VOICE)
        comps = ks.prepared_voice_components(ks.DEFAULT_VOICE)
        self.assertEqual(
            [c.name for c in comps], ["af_nova", "af_nicole", "af_heart"]
        )
        self.assertAlmostEqual(comps[0].weight, 0.6)
        self.assertAlmostEqual(comps[1].weight, 0.3)
        self.assertAlmostEqual(comps[2].weight, 0.1)
        self.assertEqual(ks.voice_lang(ks.DEFAULT_VOICE), "en-us")
        self.assertEqual(ks.dominant_voice_name(comps), "af_nova")


class ParseNormalizeTests(unittest.TestCase):
    def test_plain_voice(self):
        comps = ks.prepared_voice_components("bm_lewis")
        self.assertEqual([(c.name, c.weight) for c in comps], [("bm_lewis", 1.0)])

    def test_legacy_two_way(self):
        comps = ks.prepared_voice_components("bm_lewis+af_nova:0.35")
        self.assertEqual([c.name for c in comps], ["bm_lewis", "af_nova"])
        self.assertAlmostEqual(comps[0].weight, 0.65)
        self.assertAlmostEqual(comps[1].weight, 0.35)

    def test_unweighted_pair_is_equal_mix(self):
        comps = ks.prepared_voice_components("bm_lewis+af_nova")
        self.assertAlmostEqual(comps[0].weight, 0.5)
        self.assertAlmostEqual(comps[1].weight, 0.5)

    def test_nway_percentages(self):
        comps = ks.prepared_voice_components(
            "af_nova:0.6+af_nicole:0.3+af_heart:0.1"
        )
        self.assertEqual(
            [c.name for c in comps], ["af_nova", "af_nicole", "af_heart"]
        )
        self.assertAlmostEqual(comps[0].weight, 0.6)
        self.assertAlmostEqual(comps[1].weight, 0.3)
        self.assertAlmostEqual(comps[2].weight, 0.1)

    def test_nway_equal_weights(self):
        comps = ks.prepared_voice_components("af_nova+af_nicole+af_heart")
        self.assertTrue(all(math.isclose(c.weight, 1.0 / 3.0) for c in comps))

    def test_nway_ratios_normalize(self):
        comps = ks.prepared_voice_components("af_nova:3+af_nicole:1+af_heart:1")
        self.assertAlmostEqual(comps[0].weight, 0.6)
        self.assertAlmostEqual(comps[1].weight, 0.2)
        self.assertAlmostEqual(comps[2].weight, 0.2)

    def test_two_explicit_weights_are_nway_not_legacy(self):
        comps = ks.prepared_voice_components("af_nova:3+af_nicole:1")
        self.assertAlmostEqual(comps[0].weight, 0.75)
        self.assertAlmostEqual(comps[1].weight, 0.25)

    def test_reject_empty(self):
        for spec in ("", "   ", "+", "af_nova+", "+af_nova", "af_nova++af_heart"):
            with self.subTest(spec=spec):
                with self.assertRaises(ValueError):
                    ks.prepared_voice_components(spec)

    def test_reject_negative(self):
        with self.assertRaises(ValueError):
            ks.prepared_voice_components("af_nova:-0.1+af_nicole:1")

    def test_reject_non_finite(self):
        for spec in ("af_nova:nan", "af_nova:inf", "af_nova:-inf"):
            with self.subTest(spec=spec):
                with self.assertRaises(ValueError):
                    ks.prepared_voice_components(spec)

    def test_reject_zero_sum(self):
        with self.assertRaises(ValueError):
            ks.prepared_voice_components("af_nova:0+af_nicole:0")

    def test_legacy_weight_must_be_unit_interval(self):
        with self.assertRaises(ValueError):
            ks.prepared_voice_components("bm_lewis+af_nova:1.5")


class LangTests(unittest.TestCase):
    def test_single_prefix_map(self):
        self.assertEqual(ks.voice_lang("bm_lewis"), "en-gb")
        self.assertEqual(ks.voice_lang("bf_emma"), "en-gb")
        self.assertEqual(ks.voice_lang("af_nova"), "en-us")
        self.assertEqual(ks.voice_lang("am_adam"), "en-us")
        self.assertEqual(ks.voice_lang("jf_alpha"), "ja")
        self.assertEqual(ks.voice_lang("ff_siwis"), "fr-fr")
        self.assertEqual(ks.voice_lang("if_sara"), "it")
        self.assertEqual(ks.voice_lang("zf_xiaobei"), "cmn")

    def test_override_wins(self):
        self.assertEqual(ks.voice_lang("bm_lewis", "en-us"), "en-us")

    def test_legacy_blend_follows_heavier_left(self):
        self.assertEqual(ks.voice_lang("bm_lewis+af_nova:0.35"), "en-gb")

    def test_legacy_blend_follows_heavier_right(self):
        self.assertEqual(ks.voice_lang("bm_lewis+af_nova:0.8"), "en-us")

    def test_nway_follows_highest_weight(self):
        self.assertEqual(
            ks.voice_lang("af_nova:0.6+bm_lewis:0.3+af_heart:0.1"),
            "en-us",
        )
        self.assertEqual(
            ks.voice_lang("af_nova:0.2+bm_lewis:0.7+af_heart:0.1"),
            "en-gb",
        )

    def test_weight_tie_uses_first_listed(self):
        self.assertEqual(ks.voice_lang("af_nova:1+bm_lewis:1"), "en-us")


class ResolveVoiceTests(unittest.TestCase):
    def setUp(self):
        self.lewis = np.array([1.0, 0.0, 0.0], dtype=np.float32)
        self.nova = np.array([0.0, 1.0, 0.0], dtype=np.float32)
        self.nicole = np.array([0.0, 0.0, 1.0], dtype=np.float32)
        self.heart = np.array([0.5, 0.5, 0.0], dtype=np.float32)
        self.get_style = style_loader(
            bm_lewis=self.lewis,
            af_nova=self.nova,
            af_nicole=self.nicole,
            af_heart=self.heart,
        )

    def test_plain_returns_name(self):
        self.assertEqual(ks.resolve_voice("bm_lewis", self.get_style), "bm_lewis")

    def test_legacy_two_way_math(self):
        blended = ks.resolve_voice("bm_lewis+af_nova:0.35", self.get_style)
        expected = (0.65 * self.lewis) + (0.35 * self.nova)
        np.testing.assert_allclose(blended, expected)
        self.assertEqual(blended.shape, self.lewis.shape)
        self.assertEqual(blended.dtype, self.lewis.dtype)

    def test_nway_math(self):
        blended = ks.resolve_voice(
            "af_nova:0.6+af_nicole:0.3+af_heart:0.1", self.get_style
        )
        expected = (0.6 * self.nova) + (0.3 * self.nicole) + (0.1 * self.heart)
        np.testing.assert_allclose(blended, expected, rtol=1e-6)

    def test_equal_nway_math(self):
        blended = ks.resolve_voice("af_nova+af_nicole+af_heart", self.get_style)
        expected = (self.nova + self.nicole + self.heart) / 3.0
        np.testing.assert_allclose(blended, expected, rtol=1e-6)

    def test_shape_mismatch(self):
        bad = style_loader(
            af_nova=np.zeros((2, 2), dtype=np.float32),
            af_nicole=np.zeros((3,), dtype=np.float32),
        )
        with self.assertRaises(ValueError) as ctx:
            ks.resolve_voice("af_nova:1+af_nicole:1", bad)
        message = str(ctx.exception)
        self.assertIn("shape", message)
        self.assertIn("af_nicole", message)

    def test_dtype_mismatch(self):
        bad = style_loader(
            af_nova=np.zeros((4,), dtype=np.float32),
            af_nicole=np.zeros((4,), dtype=np.float64),
        )
        with self.assertRaises(ValueError) as ctx:
            ks.resolve_voice("af_nova:1+af_nicole:1", bad)
        self.assertIn("dtype", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
