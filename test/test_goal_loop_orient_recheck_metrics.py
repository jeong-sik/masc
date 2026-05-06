#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "goal_loop_orient_recheck_metrics.py"

spec = importlib.util.spec_from_file_location(
    "goal_loop_orient_recheck_metrics", SCRIPT_PATH
)
assert spec is not None
goal_loop_orient_recheck_metrics = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = goal_loop_orient_recheck_metrics
spec.loader.exec_module(goal_loop_orient_recheck_metrics)


def orient_report() -> dict[str, object]:
    return {
        "source_files": [
            "/Users/dancer/me/.masc/events/2026-05/06.jsonl",
            "/Users/dancer/me/.masc/transition-audit/2026-05/06.jsonl",
        ],
        "total_lines": 21,
        "matched_lines": 0,
        "summary": {
            "critical_present": 0,
            "evidence_present": 0,
            "findings_total": 19,
            "not_evaluated": 9,
        },
        "findings": [
            {
                "finding_id": "NF-1",
                "status": "EVIDENCE_ABSENT",
            },
            {
                "finding_id": "NEW-1",
                "status": "EVIDENCE_ABSENT",
            },
        ],
    }


class GoalLoopOrientRecheckMetricsTest(unittest.TestCase):
    def test_build_metrics_report_counts_zero_present_findings(self) -> None:
        report = goal_loop_orient_recheck_metrics.build_metrics_report(
            orient_report(),
            checked_at="2026-05-07T01:30:00+09:00",
            redactions=[
                ("/Users/dancer/me/.masc", "<MASC_BASE_PATH>/.masc"),
            ],
            new_finding_prefixes=["NEW"],
        )

        self.assertEqual(
            report["metrics"],
            {
                "orient_recheck_new_finding": 0.0,
                "orient_recheck_still_present": 0.0,
            },
        )
        evidence = report["metric_evidence"]["orient_recheck_still_present"]
        self.assertEqual(evidence["evidence_present"], 0)
        self.assertEqual(evidence["matched_lines"], 0)
        self.assertEqual(evidence["present_finding_ids"], [])
        self.assertEqual(
            evidence["checked_files"],
            [
                "<MASC_BASE_PATH>/.masc/events/2026-05/06.jsonl",
                "<MASC_BASE_PATH>/.masc/transition-audit/2026-05/06.jsonl",
            ],
        )

    def test_build_metrics_report_counts_present_new_finding_prefixes(self) -> None:
        orient_json = orient_report()
        findings = orient_json["findings"]
        assert isinstance(findings, list)
        findings.extend(
            [
                {
                    "finding_id": "NF-2",
                    "status": "EVIDENCE_PRESENT",
                },
                {
                    "finding_id": "NEW-2",
                    "status": "EVIDENCE_PRESENT",
                },
            ]
        )

        report = goal_loop_orient_recheck_metrics.build_metrics_report(
            orient_json,
            checked_at=None,
            redactions=[],
            new_finding_prefixes=["NEW"],
        )

        self.assertEqual(report["metrics"]["orient_recheck_still_present"], 2.0)
        self.assertEqual(report["metrics"]["orient_recheck_new_finding"], 1.0)
        evidence = report["metric_evidence"]["orient_recheck_new_finding"]
        self.assertEqual(evidence["present_new_finding_ids"], ["NEW-2"])

    def test_cli_outputs_metric_snapshot_json(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            report_path = Path(raw_dir) / "orient.json"
            report_path.write_text(json.dumps(orient_report()), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(report_path),
                    "--checked-at",
                    "2026-05-07T01:30:00+09:00",
                    "--redact-prefix",
                    "/Users/dancer/me/.masc=<MASC_BASE_PATH>/.masc",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["snapshot_kind"], "goal_loop_orient_recheck_metrics")
        self.assertEqual(payload["metrics"]["orient_recheck_still_present"], 0.0)


if __name__ == "__main__":
    unittest.main()
