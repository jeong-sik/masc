#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "validate_goal_loop_recovery_slo.py"
FIXTURE_PATH = (
    REPO_ROOT / "test" / "fixtures" / "goal_loop" / "recovery-slo.external-claim.json"
)

spec = importlib.util.spec_from_file_location(
    "validate_goal_loop_recovery_slo", SCRIPT_PATH
)
assert spec is not None
validate_goal_loop_recovery_slo = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = validate_goal_loop_recovery_slo
spec.loader.exec_module(validate_goal_loop_recovery_slo)


class ValidateGoalLoopRecoverySloTest(unittest.TestCase):
    def load_fixture(self) -> dict[str, object]:
        return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))

    def test_recovery_slo_fixture_passes(self) -> None:
        report = validate_goal_loop_recovery_slo.validate_recovery_slo_proof(
            self.load_fixture()
        )

        self.assertEqual(report.status, "PASS")
        self.assertEqual(
            report.requirements_checked,
            ["startup-alive-but-stuck", "startup-credential-starvation"],
        )
        self.assertEqual(report.missing_requirements, [])
        self.assertEqual(report.errors, [])

    def test_missing_post_recovery_turn_fails(self) -> None:
        payload = self.load_fixture()
        proofs = payload["proofs"]
        assert isinstance(proofs, list)
        first = proofs[0]
        assert isinstance(first, dict)
        first.pop("post_recovery_turn")

        report = validate_goal_loop_recovery_slo.validate_recovery_slo_proof(payload)

        self.assertEqual(report.status, "FAIL")
        self.assertIn(
            "startup-credential-starvation: post_recovery_turn object is required",
            report.errors,
        )

    def test_alive_but_stuck_must_cross_threshold(self) -> None:
        payload = self.load_fixture()
        proofs = payload["proofs"]
        assert isinstance(proofs, list)
        alive = copy.deepcopy(proofs[1])
        assert isinstance(alive, dict)
        trigger = alive["trigger"]
        assert isinstance(trigger, dict)
        trigger["elapsed_sec"] = trigger["threshold_sec"]
        payload["proofs"] = [alive]

        report = validate_goal_loop_recovery_slo.validate_recovery_slo_proof(
            payload,
            required_requirements=["startup-alive-but-stuck"],
        )

        self.assertEqual(report.status, "FAIL")
        self.assertIn(
            "startup-alive-but-stuck: trigger.elapsed_sec must exceed threshold_sec",
            report.errors,
        )

    def test_cli_require_pass_returns_nonzero_for_missing_required_proof(self) -> None:
        payload = self.load_fixture()
        proofs = payload["proofs"]
        assert isinstance(proofs, list)
        payload["proofs"] = proofs[:1]
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "proof.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(path),
                    "--require-pass",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["missing_requirements"], ["startup-alive-but-stuck"])


if __name__ == "__main__":
    unittest.main()
