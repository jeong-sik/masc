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


if __name__ == "__main__":
    unittest.main()
