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
SCRIPT_PATH = REPO_ROOT / "scripts" / "validate_goal_loop_act_map.py"
FIXTURE_DIR = REPO_ROOT / "test" / "fixtures" / "goal_loop"

spec = importlib.util.spec_from_file_location("validate_goal_loop_act_map", SCRIPT_PATH)
assert spec is not None
validate_goal_loop_act_map = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = validate_goal_loop_act_map
spec.loader.exec_module(validate_goal_loop_act_map)


class ValidateGoalLoopActMapTest(unittest.TestCase):
    def test_fixture_act_map_pr_refs_exist_in_known_pr_snapshot(self) -> None:
        report = validate_goal_loop_act_map.validate_act_map(
            validate_goal_loop_act_map.normalize_act_map(
                json.loads((FIXTURE_DIR / "act-map.startup.json").read_text())
            ),
            known_prs=validate_goal_loop_act_map.known_pr_numbers(
                json.loads((FIXTURE_DIR / "known-prs.startup.json").read_text())
            ),
            require_pr_ref=True,
        )

        self.assertEqual(report.artifact_count, 8)
        self.assertEqual(report.pr_ref_count, 8)
        self.assertEqual(report.known_pr_count, 8)
        self.assertEqual(report.missing_pr_count, 0)
        self.assertEqual(report.malformed_artifact_count, 0)

    def test_missing_pr_ref_fails_when_known_snapshot_does_not_include_it(self) -> None:
        report = validate_goal_loop_act_map.validate_act_map(
            {"D-TEST": ["PR#99999 missing"]},
            known_prs={13123},
            require_pr_ref=True,
        )

        self.assertTrue(validate_goal_loop_act_map.should_fail(report, "missing"))
        self.assertEqual(report.missing_prs[0].pr_number, 99999)

    def test_artifact_without_pr_ref_is_malformed_when_required(self) -> None:
        report = validate_goal_loop_act_map.validate_act_map(
            {"D-TEST": ["manual runbook"]},
            known_prs={13123},
            require_pr_ref=True,
        )

        self.assertTrue(validate_goal_loop_act_map.should_fail(report, "malformed"))
        self.assertEqual(report.malformed_artifacts[0].artifact, "manual runbook")

    def test_cli_reports_missing_pr_with_nonzero_exit(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            act_map_path = root / "act-map.json"
            known_path = root / "known.json"
            act_map_path.write_text(
                json.dumps({"D-TEST": ["PR#99999 missing"]}),
                encoding="utf-8",
            )
            known_path.write_text(
                json.dumps({"prs": [{"number": 13123}]}),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(act_map_path),
                    "--known-prs-json",
                    str(known_path),
                    "--require-pr-ref",
                    "--fail-on",
                    "any",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["missing_pr_count"], 1)
        self.assertEqual(payload["missing_prs"][0]["pr_number"], 99999)


if __name__ == "__main__":
    unittest.main()
