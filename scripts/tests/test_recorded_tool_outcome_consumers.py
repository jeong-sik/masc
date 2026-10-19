"""Exercise current tool-call evidence through its operator consumers."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS / "lib"))
import keeper_store_layout  # noqa: E402


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


def call(**fields):
    return {"record_kind": "tool_call", "keeper": "fixture", "tool": "masc_web_search",
            "duration_ms": 12, "input": {}, "output": '{}', **fields}


class OutcomeConsumers(unittest.TestCase):
    def run_script(self, script, rows):
        with tempfile.TemporaryDirectory(prefix="masc-outcome-") as directory:
            root = Path(directory)
            file = root / ".masc/tool_calls" / datetime.now().strftime("%Y-%m/%d.jsonl")
            file.parent.mkdir(parents=True)
            file.write_text("".join(json.dumps(row) + "\n" for row in rows))
            args = ["bash", str(SCRIPTS / script)]
            if script == "analyze-tool-call-quality.sh":
                args.extend([str(root), "1"])
            return subprocess.run(args, env={**os.environ, "MASC_BASE_PATH": str(root)},
                                  text=True, capture_output=True, check=True).stdout

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


if __name__ == "__main__":
    unittest.main()
