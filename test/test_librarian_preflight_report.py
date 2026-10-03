"""Exercise the public report CLI's paired evidence and refusal boundaries."""

from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/librarian/compare-preflight.py"


def fixture() -> dict[str, Any]:
    def run(run_id: str, enabled: bool, elapsed: float) -> dict[str, Any]:
        return {
            "run": {
                "run_id": run_id,
                "lane": "librarian_exact",
                "status": "succeeded",
                "selected_slot": None if enabled else "fixture-cli",
                "elapsed_s": elapsed,
                "payload_availability": {
                    "input": {"state": "available"},
                    "output": {"state": "available"},
                },
                "input": {
                    "payload": {
                        "actual_input": {
                            "prompt": {"rendered_sha256": "a" * 64},
                            "rendered_prompt_variables": {"source": "frozen source"},
                        },
                        "message_count": 1,
                        "current_fact_count": 1,
                    }
                },
                "output": {
                    "jev_preflight": {"status": "judged", "decision": "keep_current"}
                    if enabled
                    else {
                        "status": "skipped",
                        "reason": "librarian_preflight_disabled",
                    },
                    "generation_path": "jev_no_change" if enabled else "full_lane",
                    "full_llm_skipped": enabled,
                    "preflight_domain_rejection": None,
                },
            }
        }

    return {
        "source_head": "b" * 40,
        "config_sha256": "c" * 64,
        "environment": "synthetic report fixture",
        "evidence_kind": "fixture",
        "pairs": [
            {
                "sample_id": "one",
                "baseline": run("base-1", False, 2.0),
                "preflight": run("jev-1", True, 0.1),
            }
        ],
    }


class ReportCliTest(unittest.TestCase):
    def execute(self, manifest: dict[str, Any]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest))
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_report_does_not_promote_fixture_routes_to_quality_or_requests(
        self,
    ) -> None:
        result = self.execute(fixture())
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["declared_evidence_kind"], "fixture")
        self.assertAlmostEqual(report["paired_median_delta_s"], -1.9)
        self.assertEqual(report["recorded_generation_skips"], 1)
        for field in (
            "actual_provider_request_count",
            "semantic_quality_regressions",
            "installed_tui_agreement",
        ):
            self.assertEqual(report[field], "not_measured")
        self.assertEqual(report["goal_completion"], "not_established")

    def test_failures_are_included_in_paired_latency(self) -> None:
        manifest = fixture()
        second = copy.deepcopy(manifest["pairs"][0])
        second["sample_id"] = "two"
        second["baseline"]["run"]["run_id"] = "base-2"
        run = second["preflight"]["run"]
        run.update(run_id="jev-2", status="failed", elapsed_s=6.0)
        run["output"].update(
            jev_preflight={"status": "failed"},
            generation_path="full_lane",
            full_llm_skipped=False,
        )
        manifest["pairs"].append(second)
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertAlmostEqual(json.loads(result.stdout)["paired_median_delta_s"], 1.05)

    def test_successful_full_lane_requires_a_nonblank_selected_slot(self) -> None:
        for arm in ("baseline", "preflight"):
            for slot in (None, "", "   ", 123, False, {}, []):
                with self.subTest(arm=arm, slot=slot):
                    manifest = fixture()
                    run = manifest["pairs"][0][arm]["run"]
                    if arm == "preflight":
                        run["output"].update(
                            jev_preflight={"status": "judged", "decision": "needs_generation"},
                            generation_path="full_lane",
                            full_llm_skipped=False,
                        )
                    run["selected_slot"] = slot
                    result = self.execute(manifest)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, "")

    def test_preselection_failure_and_cancellation_keep_null_slot(self) -> None:
        for status in ("failed", "cancelled"):
            with self.subTest(status=status):
                manifest = fixture()
                run = manifest["pairs"][0]["baseline"]["run"]
                run.update(status=status, selected_slot=None)
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["pairs"][0]["baseline_status"], status)

    def test_mismatched_or_contradictory_evidence_is_refused(self) -> None:
        for mode in (
            "input",
            "slot",
            "reused_run",
            "unavailable",
            "missing_skip",
            "boolean_count",
            "awaiting",
            "missing_rejection",
        ):
            with self.subTest(mode=mode):
                manifest = fixture()
                pair = manifest["pairs"][0]
                run = pair["preflight"]["run"]
                if mode == "input":
                    run["input"]["payload"]["actual_input"][
                        "rendered_prompt_variables"
                    ]["source"] = "changed source"
                elif mode == "slot":
                    run["selected_slot"] = "invented-cli"
                elif mode == "reused_run":
                    run["run_id"] = pair["baseline"]["run"]["run_id"]
                elif mode == "unavailable":
                    run["payload_availability"]["output"]["state"] = "unavailable"
                elif mode == "boolean_count":
                    run["input"]["payload"]["current_fact_count"] = True
                elif mode == "awaiting":
                    run["output"].update(
                        jev_preflight={"status": "awaiting_answer"},
                        generation_path="full_lane",
                        full_llm_skipped=False,
                    )
                elif mode == "missing_rejection":
                    del run["output"]["preflight_domain_rejection"]
                else:
                    del run["output"]["full_llm_skipped"]
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
