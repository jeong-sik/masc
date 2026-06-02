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
SCRIPT_PATH = REPO_ROOT / "scripts" / "decide_goal_loop_findings.py"
FIXTURE_DIR = REPO_ROOT / "test" / "fixtures" / "goal_loop"

spec = importlib.util.spec_from_file_location("decide_goal_loop_findings", SCRIPT_PATH)
assert spec is not None
decide_goal_loop_findings = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = decide_goal_loop_findings
spec.loader.exec_module(decide_goal_loop_findings)


class DecideGoalLoopFindingsTest(unittest.TestCase):
    def test_act_map_marks_linked_and_missing_decisions(self) -> None:
        report = decide_goal_loop_findings.decide_orient(
            {
                "findings": [
                    {"finding_id": "NF-1", "status": "EVIDENCE_PRESENT"},
                    {"finding_id": "NF-2", "status": "EVIDENCE_PRESENT"},
                    {"finding_id": "NF-4", "status": "EVIDENCE_PRESENT"},
                ]
            },
            act_map={"D-EMERGENCY-2": ["PR#13124"]},
        )

        by_id = {decision.decision_id: decision for decision in report.decisions}
        self.assertEqual(report.decisions_total, 3)
        self.assertEqual(report.act_linked_count, 1)
        self.assertEqual(report.act_missing_count, 2)
        self.assertEqual(by_id["D-EMERGENCY-2"].act_status, "ACT_LINKED")
        self.assertEqual(by_id["D-EMERGENCY-2"].act_artifacts, ["PR#13124"])
        self.assertEqual(by_id["D-EMERGENCY-1"].act_status, "ACT_MISSING")

    def test_without_act_map_keeps_decisions_unmapped_not_missing(self) -> None:
        report = decide_goal_loop_findings.decide_orient(
            {
                "findings": [
                    {"finding_id": "NF-2", "status": "EVIDENCE_PRESENT"},
                ]
            }
        )

        self.assertEqual(report.decisions_total, 1)
        self.assertEqual(report.act_linked_count, 0)
        self.assertEqual(report.act_missing_count, 0)
        self.assertEqual(report.decisions[0].act_status, "ACT_UNMAPPED")

    def test_fail_on_missing_act_trips_when_map_is_provided(self) -> None:
        report = decide_goal_loop_findings.decide_orient(
            {
                "findings": [
                    {"finding_id": "NF-2", "status": "EVIDENCE_PRESENT"},
                ]
            },
            act_map={},
        )

        self.assertTrue(decide_goal_loop_findings.should_fail(report, "missing-act"))

    def test_cli_accepts_act_map_and_reports_missing_count(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            orient_path = Path(raw_dir) / "orient.json"
            act_map_path = Path(raw_dir) / "act-map.json"
            orient_path.write_text(
                json.dumps(
                    {
                        "findings": [
                            {"finding_id": "NF-1", "status": "EVIDENCE_PRESENT"},
                            {"finding_id": "NF-2", "status": "EVIDENCE_PRESENT"},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            act_map_path.write_text(
                json.dumps({"D-EMERGENCY-2": ["PR#13124"]}),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(orient_path),
                    "--act-map",
                    str(act_map_path),
                    "--fail-on",
                    "missing-act",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn('"act_linked_count": 1', result.stdout)
        self.assertIn('"act_missing_count": 1', result.stdout)

    def test_startup_fixture_links_all_decisions_after_emergency_acts(self) -> None:
        orient = json.loads(
            (FIXTURE_DIR / "orient.startup.json").read_text(encoding="utf-8")
        )
        act_map = decide_goal_loop_findings.load_act_map_input(
            str(FIXTURE_DIR / "act-map.startup.json")
        )

        report = decide_goal_loop_findings.decide_orient(
            orient,
            act_map=act_map,
        )
        by_id = {decision.decision_id: decision for decision in report.decisions}

        self.assertEqual(report.decisions_total, 5)
        self.assertEqual(report.act_linked_count, 5)
        self.assertEqual(report.act_missing_count, 0)
        self.assertEqual(
            by_id["D-EMERGENCY-1"].act_status,
            "ACT_LINKED",
        )
        self.assertEqual(
            by_id["D-EMERGENCY-1"].act_artifacts,
            [
                "PR#13218 keeper credential auto-recovery",
                "PR#13231 keeper slot forced-reclaim regression",
                "PR#13246 keeper slot crash-path force release",
            ],
        )
        self.assertEqual(
            by_id["D-P1-1"].act_artifacts,
            [
                "PR#13123 alive-stuck recovery",
                "PR#13190 partial stale-turn recovery",
            ],
        )


if __name__ == "__main__":
    unittest.main()
