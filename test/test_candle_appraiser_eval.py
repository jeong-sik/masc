"""The opt-in measurement must not mutate its source or inflate evidence."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("candle_eval", ROOT / "scripts/candle-appraiser-eval.py")
EVAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVAL)
BINARY = None
if "--binary" in sys.argv:
    index = sys.argv.index("--binary")
    BINARY = Path(sys.argv[index + 1]).resolve()
    del sys.argv[index:index + 2]


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
display-name = "Fixture HTTP"
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
tools-support = true
streaming = true
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

    def test_credential_headers_are_refused_before_creating_workspace(self):
        original = self.source.read_text()
        for header in ("Authorization", "X-API-KEY", "api-key", "x-auth-token"):
            with self.subTest(header=header):
                self.source.write_text(original + f'\n[providers.sample.headers]\n"{header}" = "private-header"\n')
                with self.assertRaisesRegex(ValueError, "credential headers"):
                    self.prepare()
                self.assertFalse(self.args.workspace.exists())

    @unittest.skipIf(BINARY is None, "native executable is supplied by targeted CI")
    def test_prepared_fixture_passes_the_actual_opt_in_executable_without_calls(self):
        self.prepare()
        result = subprocess.run([str(BINARY), "--base-path", str(self.args.workspace)],
                                text=True, capture_output=True, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        observed = json.loads(result.stdout)
        self.assertEqual("validated_without_model_calls", observed["mode"])
        self.assertEqual(12, observed["cases"])
        self.assertFalse((self.args.workspace / "evidence").exists())

    def write_results(self, rows):
        evidence = self.args.workspace / "evidence"
        evidence.mkdir(exist_ok=True)
        (evidence / "results.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
        plan = json.loads((self.args.workspace / "plan.json").read_text())
        (evidence / "metadata.json").write_text(json.dumps({"plan": plan, "build": {
            "commit_source": "embedded", "commit": plan["source_commit"],
            "binary_commit": plan["source_commit"]}}))

    def row(self, *, trial=1, status="ok", answer=None, run_id="observed-run"):
        case = json.loads((self.args.workspace / "cases.json").read_text())[0]
        answer = ("rejected" if status != "ok" else {"grade": "small"}) if answer is None else answer
        receipt = {"run_id": run_id, "lane": "candle_appraiser", "selected_slot": "sample.model",
                   "status": "succeeded" if status == "ok" else "failed",
                   "input": {"kind": "exact", "payload": {"goal_id": case["id"],
                       "request_id": f"eval-{case['id']}-{trial}",
                       "verification_run_id": "synthetic-eval-verification", "stage": case["stage"],
                       "actual_input": case["input"]}},
                   "output": {"result": answer if status == "ok" else {"error": answer},
                              "attempts": [{"kind": "dispatch", "slot": "sample.model"}]}}
        if status != "ok":
            receipt.update(code={"invalid_response": "candle_appraisal_rejected",
                                 "transport_unavailable": "candle_appraisal_unavailable"}[status], detail=answer)
        return {"case_id": case["id"], "trial": trial, "stage": case["stage"],
                "status": status, "answer": answer, "receipt": receipt}

    def test_failures_and_missing_trials_remain_visible_without_calibration_claim(self):
        self.prepare()
        self.write_results([self.row(status="invalid_response")])
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
        row = self.row()
        self.write_results([row, row])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            EVAL.report(self.args.workspace)

    def test_one_receipt_cannot_be_counted_as_two_trials(self):
        self.prepare()
        row = self.row()
        self.write_results([row, {**row, "trial": 2}])
        with self.assertRaisesRegex(ValueError, "duplicate exact run"):
            EVAL.report(self.args.workspace)

    def test_report_rejects_another_runs_metadata(self):
        self.prepare()
        self.write_results([self.row()])
        path = self.args.workspace / "evidence/metadata.json"
        data = json.loads(path.read_text())
        data["plan"]["runtime_id"] = "another.provider"
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "metadata"):
            EVAL.report(self.args.workspace)

    def test_report_rejects_mispaired_receipts_and_changed_answers(self):
        self.prepare()
        for status in ("ok", "invalid_response", "transport_unavailable"):
            original = self.row(status=status)
            for change in ("input", "answer", "status", "code", "dispatch"):
                if status == "ok" and change == "code":
                    continue
                with self.subTest(status=status, change=change):
                    row = copy.deepcopy(original)
                    if change == "input":
                        row["receipt"]["input"]["payload"]["request_id"] = "another-trial"
                    elif change == "answer":
                        row["answer"] = "altered"
                    elif change == "status":
                        row["receipt"]["status"] = "cancelled"
                    elif change == "dispatch":
                        row["receipt"]["output"]["attempts"][0]["slot"] = "another.provider"
                    else:
                        row["receipt"]["code"] = "another-failure"
                    self.write_results([row])
                    with self.assertRaises(ValueError):
                        EVAL.report(self.args.workspace)

    def test_optimized_audit_still_rejects_misbound_metadata(self):
        self.prepare()
        self.write_results([self.row()])
        path = self.args.workspace / "evidence/metadata.json"
        data = json.loads(path.read_text())
        data["plan"]["runtime_id"] = "another.provider"
        path.write_text(json.dumps(data))
        audit = ROOT / "docs/evidence/2026-09-30-candle-appraiser/audit-evaluation.py"
        result = subprocess.run([sys.executable, "-O", str(audit), str(self.args.workspace),
                                 str(self.args.workspace / "evidence")], capture_output=True, text=True)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("audit check failed", result.stderr)
        self.assertNotIn('"actual_inputs_match_frozen_corpus": true', result.stdout)

    @unittest.skipIf(BINARY is None, "native executable is supplied by targeted CI")
    def test_native_validation_rejects_ambient_replacement_catalog(self):
        self.prepare()
        result = subprocess.run([str(BINARY), "--base-path", str(self.args.workspace)],
                                env={**os.environ, "AGENT_CORE_MODEL_CATALOG": "/unrelated/catalog.json"},
                                capture_output=True, text=True)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("AGENT_CORE_MODEL_CATALOG is not allowed", result.stderr)
        self.assertFalse((self.args.workspace / "evidence").exists())

if __name__ == "__main__":
    unittest.main()
