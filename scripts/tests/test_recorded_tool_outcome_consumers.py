"""Exercise current tool-call evidence through its operator consumers."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS / "lib"))
import keeper_store_layout  # noqa: E402
from recorded_tool_outcome import recorded_call_outcome  # noqa: E402


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ROUNDTRIPS = load("outcome_roundtrips", "measure-tool-roundtrips.py")
with patch.object(keeper_store_layout, "load_store_layout", return_value={
    "metrics": "fixture", "execution-receipts": "fixture", "trajectories": "fixture",
}):
    READINESS = load("outcome_readiness", "audit-keeper-fleet-readiness.py")


ACCEPTANCE = load(
    "outcome_acceptance", "harness/workload/keeper_multi_collaboration_acceptance.py")


def call(**fields):
    return {"record_kind": "tool_call", "keeper": "fixture", "tool": "masc_web_search",
            "duration_ms": 12, "input": {}, "output": '{}', **fields}


class OutcomeConsumers(unittest.TestCase):
    def run_script(self, script, rows, *, extra_args=(), extra_env=None, utc_path=False):
        with tempfile.TemporaryDirectory(prefix="masc-outcome-") as directory:
            root = Path(directory)
            # The SLO extractor names its dated files by the UTC day.
            day = datetime.now(timezone.utc) if utc_path else datetime.now()
            file = root / ".masc/tool_calls" / day.strftime("%Y-%m/%d.jsonl")
            file.parent.mkdir(parents=True)
            file.write_text("".join(json.dumps(row) + "\n" for row in rows))
            args = ["bash", str(SCRIPTS / script)]
            if script == "analyze-tool-call-quality.sh":
                args.extend([str(root), "1"])
            args.extend(a.replace("{root}", str(root)) for a in extra_args)
            return subprocess.run(args, env={**os.environ, "MASC_BASE_PATH": str(root),
                                             **(extra_env or {})},
                                  text=True, capture_output=True, check=True).stdout

    def run_harness_functions(self, rows, keeper="fixture"):
        """Run the harness's two log readers on a fixture log.

        The script runs its own main on source, so the two functions are cut
        out by name and evaluated alone.
        """
        script = (SCRIPTS / "harness_tool_call_quality.sh").read_text()
        functions = "".join(
            re.search(rf"^{name}\(\) \{{.*?^\}}\n", script, re.S | re.M).group(0)
            for name in ("read_tool_log_entries", "tool_calls_for_evidence"))
        with tempfile.TemporaryDirectory(prefix="masc-harness-outcome-") as directory:
            root = Path(directory)
            file = root / ".masc/tool_calls/2026-10/19.jsonl"
            file.parent.mkdir(parents=True)
            file.write_text("".join(json.dumps(row) + "\n" for row in rows))
            program = functions + f'tool_calls_for_evidence "$(read_tool_log_entries {keeper})"\n'
            output = subprocess.run(
                ["bash", "-c", program],
                env={**os.environ, "TARGET_DIR": str(root), "ROOT_DIR": str(SCRIPTS.parent)},
                text=True, capture_output=True, check=True).stdout
            return json.loads(output)

    def test_quality_counts_calls_and_all_five_outcomes(self):
        output = self.run_script("analyze-tool-call-quality.sh", [
            call(disposition="completed", wire_outcome="error", success=False),
            call(disposition="failed", wire_outcome="ok", success=True),
            call(disposition="deferred", wire_outcome="ok"),
            call(wire_outcome="unknown"), call(success=True),
            call(disposition=None, wire_outcome="ok"),
            call(disposition="invented", wire_outcome="ok"),
            call(record_kind="composition_run", disposition="failed"),
            call(record_kind="lifecycle_event", disposition="completed"),
        ])
        for label, count in [("Total calls", 7), ("Success", 1), ("Failure", 1),
                             ("Deferred", 1), ("Unsettled", 2), ("Malformed", 2)]:
            self.assertRegex(output, rf"{label}:\s+{count}\b")
        self.assertRegex(output, r"fixture\s+7\s+1/1/1/2/2\b")

    def test_non_call_rows_leave_no_calls_to_analyze(self):
        output = self.run_script("analyze-tool-call-quality.sh", [
            call(record_kind="composition_run", disposition="completed")])
        self.assertIn("No tool call records", output)

    def test_sweep_buckets_only_authoritative_failures(self):
        rows = [call(disposition="failed", wire_outcome="ok", output='{"error":"failed disposition"}'),
                call(wire_outcome="error", output='{"error":"wire failure"}'),
                call(disposition="deferred", wire_outcome="error", output='{"error":"deferred"}'),
                call(disposition=None, wire_outcome="error", output='{"error":"malformed"}'),
                call(record_kind="composition_run", disposition="failed", output='{"error":"composition"}')]
        output = self.run_script("sweep-tool-error-signatures.sh", rows)
        self.assertEqual({row["sig"] for row in map(json.loads, output.splitlines())},
                         {"failed disposition", "wire failure"})

    def test_roundtrip_probe_uses_disposition_before_wire(self):
        for fields, expected in [({"disposition": "failed", "wire_outcome": "ok"}, 1),
                                 ({"disposition": "deferred", "wire_outcome": "error"}, 0),
                                 ({"disposition": None, "wire_outcome": "error"}, 0)]:
            with self.subTest(fields=fields):
                first = call(**fields)
                second = call(input={"query": "changed shape"})
                self.assertEqual(ROUNDTRIPS.probe_pairs({("turn",): [first, second]}), (1, expected))

    def test_readiness_requires_recorded_success_for_web_and_pr(self):
        for fields, success in [({"disposition": "completed", "wire_outcome": "error"}, True),
                                ({"disposition": "failed", "wire_outcome": "ok"}, False),
                                ({"disposition": "deferred", "wire_outcome": "ok"}, False),
                                ({"disposition": None, "wire_outcome": "ok"}, False),
                                ({"success": True}, False)]:
            with self.subTest(fields=fields):
                row = call(**fields, output='{"ok":true,"url":"https://github.com/example/repo/pull/1"}')
                self.assertEqual(bool(READINESS.web_search_evidence_from_tool_call(row, "fixture")), success)
                with tempfile.TemporaryDirectory(prefix="masc-readiness-outcome-") as directory:
                    root = Path(directory)
                    path = root / ".masc/tool_calls/2026-10/19.jsonl"
                    path.parent.mkdir(parents=True)
                    path.write_text(json.dumps(row) + "\n")
                    self.assertEqual(bool(READINESS.scan_pr_creation_evidence(root, "fixture").refs), success)
        row = call(record_kind="composition_run", disposition="completed")
        self.assertFalse(READINESS.web_search_evidence_from_tool_call(row, "fixture"))
        # A distinct decision producer keeps its own boolean success contract.
        refs, _ = READINESS.pr_evidence_from_row({"ok": True, "url": "https://github.com/example/repo/pull/1"})
        self.assertTrue(refs)

    # -- readers that were still on the removed top-level `success` field --

    def test_execute_census_buckets_failures_by_recorded_outcome(self):
        now = time.time()
        rows = [call(tool="Execute", ts=now, disposition="failed", wire_outcome="ok",
                     output="old_string not found"),
                call(tool="tool_execute", ts=now, wire_outcome="error", output="timed out"),
                call(tool="Execute", ts=now, disposition="completed", wire_outcome="error"),
                call(tool="Execute", ts=now, disposition="deferred", wire_outcome="error"),
                call(tool="Execute", ts=now, wire_outcome="unknown"),
                call(tool="Execute", ts=now, disposition="invented", wire_outcome="ok"),
                # A leftover boolean grants and removes nothing.
                call(tool="Execute", ts=now, success=False),
                call(tool="Execute", ts=now, record_kind="composition_run", disposition="failed")]
        output = self.run_script(
            "analyze-keeper-execute-failures.sh", rows,
            extra_args=["{root}", "24"],
            extra_env={"MASC_EXECUTE_COUNTERS_URL": "http://127.0.0.1:9/"})
        for label, count in [("total", 7), ("failed", 2), ("ok", 1),
                             ("deferred", 1), ("unsettled", 2), ("malformed", 1)]:
            self.assertRegex(output, rf"(?m)^{label}\t{count}$")
        self.assertRegex(output, r"(?m)^failure_pct\t28\.57$")
        # The failure sections list only the two recorded failures, by category.
        categories = output.split("[failure categories]")[1].split("[top failed commands]")[0]
        self.assertRegex(categories, r"(?m)^\s+1 edit_old_string_not_found$")
        self.assertRegex(categories, r"(?m)^\s+1 timeout$")
        self.assertEqual(len([line for line in categories.splitlines() if line.strip()]), 2)
        # The surface table keeps the two Execute names apart.
        self.assertRegex(output, r"(?m)^Execute\t1\t1\t4\t16\.67$")
        self.assertRegex(output, r"(?m)^tool_execute\t1\t0\t0\t100\.00$")

    def test_slo_snapshot_counts_recorded_success_and_failure(self):
        now = time.time()
        rows = [call(tool="Execute", ts=now, disposition="completed"),
                call(tool="Execute", ts=now, wire_outcome="error"),
                call(tool="masc_board_post", ts=now, wire_outcome="ok"),
                call(tool="masc_board_post", ts=now, disposition="deferred"),
                call(tool="masc_board_post", ts=now, success=True),
                call(tool="masc_board_post", ts=now, wire_outcome="unknown"),
                call(tool="masc_board_post", ts=now, disposition="invented"),
                # Rows that are not calls: neither the numerator nor the
                # denominator of either percentage.
                call(tool="Execute", ts=now, record_kind="composition_run", disposition="failed"),
                call(tool="Execute", ts=now, record_kind="lifecycle_event", disposition="failed"),
                call(tool="masc_board_post", ts=now, record_kind="composition_run",
                     disposition="completed")]
        output = self.run_script(
            "board-slo-extractor.sh", rows, extra_args=["--offline", "--json"], utc_path=True)
        metrics = json.loads(output)["metrics"]
        # 2 of 7 tool_call rows succeeded (the two settled successes) ...
        self.assertEqual(metrics["tool_call_success_pct"], 28.57)
        # ... and 1 of the 2 Execute tool_call rows failed.
        self.assertEqual(metrics["execute_failure_pct"], 50.0)

    def test_acceptance_harness_reads_the_recorded_outcome_of_a_log_row(self):
        for fields, verdict in [({"disposition": "completed", "wire_outcome": "error"}, True),
                                ({"disposition": "failed", "wire_outcome": "ok"}, False),
                                ({"wire_outcome": "ok"}, True),
                                ({"wire_outcome": "error"}, False),
                                ({"disposition": "deferred"}, None),
                                ({"wire_outcome": "unknown"}, None),
                                ({"disposition": "invented"}, None),
                                ({"success": True}, None),
                                ({"success": False}, None),
                                ({"record_kind": "composition_run", "disposition": "completed"}, None),
                                ({"record_kind": "lifecycle_event", "disposition": "failed"}, None)]:
            with self.subTest(fields=fields):
                row = call(**fields)
                self.assertIs(ACCEPTANCE.row_success_verdict(row), verdict)
                self.assertIs(ACCEPTANCE.row_succeeded(row), verdict is True)

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_the_chat_edit_verifier_copy_of_the_rule_matches_the_python_rule(self):
        # The .mjs verifier cannot import the python or TypeScript rule, so it
        # carries a copy. This keeps the copy from drifting.
        rows = [{}, {"disposition": "completed", "wire_outcome": "error"},
                {"disposition": "failed"}, {"disposition": "deferred"},
                {"disposition": None, "wire_outcome": "ok"}, {"disposition": "x"},
                {"wire_outcome": "ok"}, {"wire_outcome": "error"}, {"wire_outcome": "unknown"},
                {"wire_outcome": "nope"}, {"success": True},
                {"disposition": "constructor"}, {"wire_outcome": "toString"}, [], None, 5]
        source = (SCRIPTS / "verify-installed-chat-edit.mjs").read_text()
        function = re.search(r"^function recordedOutcome\(row\) \{.*?^\}\n", source, re.S | re.M).group(0)
        program = function + f"console.log(JSON.stringify({json.dumps(rows)}.map(recordedOutcome)))\n"
        output = subprocess.run(["node", "--input-type=module", "-e", program],
                                text=True, capture_output=True, check=True).stdout
        self.assertEqual(json.loads(output), [recorded_call_outcome(row).value for row in rows])

    def test_quality_harness_marks_only_a_settled_success_as_success(self):
        rows = [call(keeper="fixture", tool="tool_execute", disposition="completed", wire_outcome="error"),
                call(keeper="fixture", tool="tool_execute", disposition="failed", wire_outcome="ok"),
                call(keeper="fixture", tool="tool_execute", disposition="deferred"),
                call(keeper="fixture", tool="tool_execute", wire_outcome="unknown"),
                call(keeper="fixture", tool="tool_execute", success=True),
                call(keeper="fixture", tool="tool_execute", record_kind="composition_run",
                     disposition="completed"),
                call(keeper="fixture", tool="tool_execute", record_kind="lifecycle_event",
                     disposition="completed"),
                call(keeper="other", tool="tool_execute", disposition="completed")]
        calls = self.run_harness_functions(rows)
        self.assertEqual([c["success"] for c in calls], [True, False, False, False, False])


if __name__ == "__main__":
    unittest.main()
