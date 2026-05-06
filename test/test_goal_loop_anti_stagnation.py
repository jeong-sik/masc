#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "goal_loop_anti_stagnation.py"

spec = importlib.util.spec_from_file_location("goal_loop_anti_stagnation", SCRIPT_PATH)
assert spec is not None
goal_loop_anti_stagnation = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = goal_loop_anti_stagnation
spec.loader.exec_module(goal_loop_anti_stagnation)


NOW = datetime(2026, 5, 8, 0, 0, tzinfo=timezone.utc)


class GoalLoopAntiStagnationTest(unittest.TestCase):
    def test_still_present_requires_act_reference(self) -> None:
        report = goal_loop_anti_stagnation.build_report(
            {
                "findings": [
                    {
                        "finding_id": "NF-2",
                        "status": "STILL_PRESENT",
                        "first_seen_at": "2026-05-07T20:00:00Z",
                    }
                ]
            },
            now=NOW,
        )

        self.assertEqual(report.status, "critical")
        self.assertEqual(report.violations[0].rule_id, "still_present_requires_act")

    def test_act_creation_deadline_misses_after_48_hours(self) -> None:
        report = goal_loop_anti_stagnation.build_report(
            {
                "findings": [
                    {
                        "finding_id": "R-FATAL-1",
                        "status": "STILL_PRESENT",
                        "first_seen_at": "2026-05-05T00:00:00Z",
                        "act": {"ref": "planned PR#13050"},
                    }
                ]
            },
            now=NOW,
        )

        rule_ids = {violation.rule_id for violation in report.violations}
        self.assertIn("act_creation_deadline_missed", rule_ids)

    def test_verify_after_merge_deadline_misses_after_24_hours(self) -> None:
        report = goal_loop_anti_stagnation.build_report(
            {
                "findings": [
                    {
                        "finding_id": "CD-8",
                        "status": "PARTIALLY_FIXED",
                        "first_seen_at": "2026-05-05T00:00:00Z",
                        "act": {
                            "ref": "PR#13050",
                            "created_at": "2026-05-05T06:00:00Z",
                            "merged_at": "2026-05-06T00:00:00Z",
                        },
                        "verify": {"status": "PENDING"},
                    }
                ]
            },
            now=NOW,
        )

        self.assertEqual(
            report.violations[0].rule_id, "verify_after_merge_deadline_missed"
        )

    def test_failed_verify_requires_repair_or_rollback_within_4_hours(self) -> None:
        report = goal_loop_anti_stagnation.build_report(
            {
                "findings": [
                    {
                        "finding_id": "CF-1",
                        "status": "PARTIALLY_FIXED",
                        "first_seen_at": "2026-05-07T00:00:00Z",
                        "act": {
                            "ref": "PR#13051",
                            "created_at": "2026-05-07T01:00:00Z",
                        },
                        "verify": {
                            "status": "FAIL",
                            "failed_at": "2026-05-07T18:00:00Z",
                        },
                    }
                ]
            },
            now=NOW,
        )

        self.assertEqual(
            report.violations[0].rule_id,
            "verify_fail_repair_deadline_missed",
        )

    def test_week_old_still_present_requires_escalation(self) -> None:
        report = goal_loop_anti_stagnation.build_report(
            {
                "findings": [
                    {
                        "finding_id": "CE-1",
                        "status": "STILL_PRESENT",
                        "first_seen_at": "2026-04-30T00:00:00Z",
                        "act": {
                            "ref": "PR#13052",
                            "created_at": "2026-05-01T00:00:00Z",
                        },
                    }
                ]
            },
            now=NOW,
        )

        self.assertEqual(report.escalations_required, 1)
        self.assertEqual(report.violations[0].rule_id, "week_old_escalation_required")

    def test_satisfied_lifecycle_has_no_violations(self) -> None:
        report = goal_loop_anti_stagnation.build_report(
            {
                "findings": [
                    {
                        "finding_id": "NF-1",
                        "status": "VERIFIED_FIXED",
                        "first_seen_at": "2026-05-05T00:00:00Z",
                        "act": {
                            "ref": "PR#13050",
                            "created_at": "2026-05-05T02:00:00Z",
                            "merged_at": "2026-05-05T04:00:00Z",
                        },
                        "verify": {
                            "status": "PASS",
                            "checked_at": "2026-05-05T06:00:00Z",
                        },
                    }
                ]
            },
            now=NOW,
        )

        self.assertEqual(report.status, "ok")
        self.assertEqual(report.violations_total, 0)

    def test_cli_fails_on_critical_status(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "anti.json"
            path.write_text(
                json.dumps(
                    {
                        "findings": [
                            {
                                "finding_id": "NF-2",
                                "status": "STILL_PRESENT",
                                "first_seen_at": "2026-05-07T20:00:00Z",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(path),
                    "--now",
                    "2026-05-08T00:00:00Z",
                    "--fail-on",
                    "critical",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "critical")
        self.assertEqual(payload["violations_total"], 1)


if __name__ == "__main__":
    unittest.main()
