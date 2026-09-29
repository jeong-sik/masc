"""The opt-in measurement must not mutate its source or inflate evidence."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("candle_eval", ROOT / "scripts/candle-appraiser-eval.py")
EVAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVAL)


class EvalFeature(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "live-runtime.toml"
        self.source.write_text('''
[runtime]
default = "sample.model"
[providers.sample]
protocol = "openai-compatible-http"
endpoint = "https://example.invalid/v1"
[providers.sample.credentials]
type = "env"
key = "MASC_CANDLE_EVAL_TEST_TOKEN"
[providers.unselected]
protocol = "openai-compatible-http"
endpoint = "https://not-selected.invalid/v1"
[models.model]
api-name = "fixture"
max-context = 4096
[sample.model]
''')
        self.args = argparse.Namespace(
            source_runtime=self.source, runtime="sample.model", workspace=self.root / "isolated",
            source_commit="a" * 40, trials=20, max_output_tokens=4096,
            exact_body_timeout_s=1200.0, cases=ROOT / "test/fixtures/candle_appraiser_eval_cases.json",
            prompt_dir=ROOT / "config/prompts")

    def prepare(self):
        with patch.dict(os.environ, {"MASC_CANDLE_EVAL_TEST_TOKEN": "private-value-never-persisted"}):
            return EVAL.prepare(self.args)

    def test_preparation_is_private_single_slot_and_leaves_source_untouched(self):
        before = self.source.read_bytes()
        plan = self.prepare()
        self.assertEqual(before, self.source.read_bytes())
        text = (self.args.workspace / ".masc/config/runtime.toml").read_text()
        parsed = EVAL.tomllib.loads(text)
        self.assertEqual(["sample"], list(parsed["providers"]))
        lane = parsed["runtime"]["exact_output_lanes"]["candle_appraiser"]
        self.assertEqual(["sample.model"], lane["slots"])
        self.assertEqual([], lane["cli_slots"])
        self.assertEqual(240, plan["planned_calls"])
        for path in self.args.workspace.rglob("*"):
            if path.is_file():
                self.assertNotIn("private-value-never-persisted", path.read_text())
        self.assertFalse((self.args.workspace / "evidence").exists())
        with self.assertRaises(FileExistsError):
            self.prepare()

    def test_missing_credential_does_not_create_a_workspace(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, "unavailable"):
            EVAL.prepare(self.args)
        self.assertFalse(self.args.workspace.exists())

    def write_results(self, rows):
        evidence = self.args.workspace / "evidence"
        evidence.mkdir(exist_ok=True)
        (evidence / "results.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))

    def test_failures_and_missing_trials_remain_visible_without_calibration_claim(self):
        self.prepare()
        self.write_results([{"case_id": "grade-base", "trial": 1, "stage": "grade",
                             "status": "invalid_response", "answer": "rejected",
                             "receipt": {"run_id": "observed-run"}}])
        result = EVAL.report(self.args.workspace)
        self.assertFalse(result["complete"])
        base = result["cases"]["grade-base"]
        self.assertEqual({"invalid_response": 1}, base["statuses"])
        self.assertEqual(19, base["missing"])
        self.assertEqual([], base["modes"])
        self.assertEqual("not_performed", result["calibration"]["status"])
        self.assertTrue(all(row.get("unique_mode_increased") is None for row in result["comparisons"]))

    def test_duplicate_trials_cannot_inflate_the_mode_count(self):
        self.prepare()
        row = {"case_id": "grade-base", "trial": 1, "stage": "grade", "status": "ok",
               "answer": {"grade": "small"}, "receipt": {"run_id": "observed-run"}}
        self.write_results([row, row])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            EVAL.report(self.args.workspace)

    def test_one_receipt_cannot_be_counted_as_two_trials(self):
        self.prepare()
        row = {"case_id": "grade-base", "trial": 1, "stage": "grade", "status": "ok",
               "answer": {"grade": "small"}, "receipt": {"run_id": "observed-run"}}
        self.write_results([row, {**row, "trial": 2}])
        with self.assertRaisesRegex(ValueError, "duplicate exact run"):
            EVAL.report(self.args.workspace)


if __name__ == "__main__":
    unittest.main()
