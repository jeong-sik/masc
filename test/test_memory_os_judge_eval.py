#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "memory_os_judge_eval.py"

spec = importlib.util.spec_from_file_location("memory_os_judge_eval", SCRIPT_PATH)
assert spec is not None
memory_os_judge_eval = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = memory_os_judge_eval
spec.loader.exec_module(memory_os_judge_eval)


class MemoryOsJudgeEvalTest(unittest.TestCase):
    def test_extract_json_array_skips_prose_brackets(self) -> None:
        text = '[analysis] judge rationale\n[{"i":1,"label":"durable"}]'
        self.assertEqual(
            memory_os_judge_eval._extract_json_array(text),
            '[{"i":1,"label":"durable"}]',
        )

    def test_extract_json_array_keeps_nested_arrays(self) -> None:
        text = '```json\n[{"i":1,"label":"durable","why":["a","b"]}]\n```'
        self.assertEqual(
            memory_os_judge_eval._extract_json_array(text),
            '[{"i":1,"label":"durable","why":["a","b"]}]',
        )

    def test_extract_json_array_skips_valid_non_answer_arrays(self) -> None:
        text = 'valid labels: ["durable","ephemeral","uncertain"]\n[{"i":1,"label":"durable"}]'
        self.assertEqual(
            memory_os_judge_eval._extract_json_array(text),
            '[{"i":1,"label":"durable"}]',
        )

    # noise_rate — ephemeral / (ephemeral + durable), uncertain excluded
    def test_noise_rate_excludes_uncertain(self) -> None:
        labels = ["ephemeral", "durable", "durable", "uncertain"]
        self.assertEqual(memory_os_judge_eval.noise_rate(labels), 1 / 3)

    def test_noise_rate_empty_is_zero(self) -> None:
        self.assertEqual(memory_os_judge_eval.noise_rate([]), 0.0)

    def test_noise_rate_all_uncertain_is_zero(self) -> None:
        self.assertEqual(memory_os_judge_eval.noise_rate(["uncertain", "uncertain"]), 0.0)

    def test_noise_rate_all_ephemeral_is_one(self) -> None:
        self.assertEqual(memory_os_judge_eval.noise_rate(["ephemeral", "ephemeral"]), 1.0)

    # _parse_index — 1-based judge index to 0-based position; malformed -> None
    def test_parse_index_one_based_to_zero_based(self) -> None:
        self.assertEqual(memory_os_judge_eval._parse_index(1, 3), 0)
        self.assertEqual(memory_os_judge_eval._parse_index(3, 3), 2)

    def test_parse_index_rejects_bool(self) -> None:
        self.assertIsNone(memory_os_judge_eval._parse_index(True, 3))

    def test_parse_index_accepts_whole_float_rejects_fractional(self) -> None:
        self.assertEqual(memory_os_judge_eval._parse_index(2.0, 3), 1)
        self.assertIsNone(memory_os_judge_eval._parse_index(2.5, 3))

    def test_parse_index_out_of_range_is_none(self) -> None:
        self.assertIsNone(memory_os_judge_eval._parse_index(0, 3))
        self.assertIsNone(memory_os_judge_eval._parse_index(4, 3))

    def test_parse_index_numeric_string(self) -> None:
        self.assertEqual(memory_os_judge_eval._parse_index("2", 3), 1)

    def test_parse_index_non_numeric_string_is_none(self) -> None:
        self.assertIsNone(memory_os_judge_eval._parse_index("x", 3))

    # deterministic_sample — stable stride sample, no RNG
    def test_deterministic_sample_is_reproducible(self) -> None:
        items = list(range(100))
        self.assertEqual(
            memory_os_judge_eval.deterministic_sample(items, 10),
            memory_os_judge_eval.deterministic_sample(items, 10),
        )

    def test_deterministic_sample_returns_all_when_n_ge_len(self) -> None:
        items = [1, 2, 3]
        self.assertEqual(memory_os_judge_eval.deterministic_sample(items, 5), items)
        self.assertEqual(memory_os_judge_eval.deterministic_sample(items, 3), items)

    def test_deterministic_sample_returns_all_when_n_nonpositive(self) -> None:
        items = [1, 2, 3]
        self.assertEqual(memory_os_judge_eval.deterministic_sample(items, 0), items)

    def test_deterministic_sample_strides(self) -> None:
        items = list(range(10))
        self.assertEqual(memory_os_judge_eval.deterministic_sample(items, 5), [0, 2, 4, 6, 8])

    # _split_runtime_id — "provider.model" split on the first dot
    def test_split_runtime_id_splits_first_dot(self) -> None:
        self.assertEqual(
            memory_os_judge_eval._split_runtime_id("ollama_cloud.minimax-m3"),
            ("ollama_cloud", "minimax-m3"),
        )

    def test_split_runtime_id_keeps_model_dots(self) -> None:
        self.assertEqual(
            memory_os_judge_eval._split_runtime_id("provider.model.v1.2"),
            ("provider", "model.v1.2"),
        )

    def test_split_runtime_id_without_dot_exits(self) -> None:
        with self.assertRaises(SystemExit):
            memory_os_judge_eval._split_runtime_id("nodot")

    # _looks_like_answer_array — list of dicts carrying an "i" index key
    def test_looks_like_answer_array_true(self) -> None:
        self.assertTrue(
            memory_os_judge_eval._looks_like_answer_array([{"i": 1, "label": "durable"}])
        )

    def test_looks_like_answer_array_false_for_label_list(self) -> None:
        self.assertFalse(
            memory_os_judge_eval._looks_like_answer_array(["durable", "ephemeral"])
        )

    def test_looks_like_answer_array_false_for_non_list(self) -> None:
        self.assertFalse(memory_os_judge_eval._looks_like_answer_array({"i": 1}))


if __name__ == "__main__":
    unittest.main()
