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


def observation(status: str = "judged", decision: str = "keep_current") -> dict[str, Any]:
    if status == "awaiting_answer":
        return {"status": status, "elapsed_s": None}
    if status == "failed":
        return {"status": status, "elapsed_s": 0.05, "failure": {
            "kind": "every_destination_refused", "attempts": [{
                "destination_uri": "https://fixture.invalid/jev", "model": "fixture-model",
                "refusal": {"kind": "transport", "detail": "fixture connection failure"},
            }],
        }}
    result: dict[str, Any] = {
        "status": status, "elapsed_s": 0.05,
        "destination": {"destination_uri": "https://fixture.invalid/jev", "model": "fixture-model"},
        "model": "fixture-answering-model", "request_body_sha256": "d" * 64,
        "passed_over": [],
    }
    if status == "invalid_answer":
        result["reason"] = "fixture missing choice answer"
    else:
        result.update(decision=decision, confidence=0.8, probabilities={
            label: 0.8 if label == decision else 0.1
            for label in ("keep_current", "needs_generation", "uncertain")
        })
    return result


def fixture() -> dict[str, Any]:
    def run(run_id: str, enabled: bool, elapsed: float) -> dict[str, Any]:
        return {
            "run": {
                "run_id": run_id,
                "lane": "librarian_exact",
                "actor": "fixture-keeper",
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
                    "jev_preflight": observation()
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
            jev_preflight=observation("failed"),
            generation_path="full_lane",
            full_llm_skipped=False,
        )
        manifest["pairs"].append(second)
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertAlmostEqual(json.loads(result.stdout)["paired_median_delta_s"], 1.05)

    def test_valid_fallback_and_not_entered_failures_are_reported(self) -> None:
        for status, path, rejection in (
            ("succeeded", "full_lane", "No-change output failed domain validation"),
            ("failed", "not_entered", None),
            ("cancelled", "not_entered", None),
        ):
            with self.subTest(status=status, path=path):
                manifest = fixture()
                run = manifest["pairs"][0]["preflight"]["run"]
                run.update(status=status, selected_slot="fixture-cli" if path == "full_lane" else None)
                run["output"].update(
                    generation_path=path,
                    full_llm_skipped=False,
                    preflight_domain_rejection=rejection,
                    jev_preflight=observation()
                    if path == "full_lane" else observation("awaiting_answer"),
                )
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["recorded_generation_skips"], 0)

    def test_successful_full_lane_requires_a_nonblank_selected_slot(self) -> None:
        for arm in ("baseline", "preflight"):
            for slot in (None, "", "   ", 123, False, {}, []):
                with self.subTest(arm=arm, slot=slot):
                    manifest = fixture()
                    run = manifest["pairs"][0][arm]["run"]
                    if arm == "preflight":
                        run["output"].update(
                            jev_preflight=observation("judged", "needs_generation"),
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
                self.assertEqual(
                    json.loads(result.stdout)["pairs"][0]["baseline_status"], status
                )

    def test_unevaluated_candidate_is_refused(self) -> None:
        for status, reason in (
            ("skipped", "librarian_preflight_disabled"),
            ("skipped", "lane_disabled"),
            ("skipped", "no_armed_destination"),
            ("skipped", "keeper_excluded"),
            ("ineligible", "working context requires generation"),
            ("question_unavailable", "invalid choice set"),
        ):
            with self.subTest(status=status, reason=reason):
                manifest = fixture()
                run = manifest["pairs"][0]["preflight"]["run"]
                run["selected_slot"] = "fixture-cli"
                run["output"].update(
                    jev_preflight={"status": status, "reason": reason},
                    generation_path="full_lane",
                    full_llm_skipped=False,
                )
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")

    def test_completed_assessment_cannot_leave_generation_not_entered(self) -> None:
        for status in ("failed", "cancelled"):
            for observed_status in ("judged", "skipped", "ineligible", "failed", "invalid_answer"):
                with self.subTest(status=status, observation=observed_status):
                    manifest = fixture()
                    run = manifest["pairs"][0]["preflight"]["run"]
                    run.update(status=status, selected_slot=None)
                    run["output"].update(
                        jev_preflight=observation(observed_status, "needs_generation"),
                        generation_path="not_entered",
                        full_llm_skipped=False,
                    )
                    result = self.execute(manifest)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, "")

    def test_answerless_observations_reject_received_answer_fields(self) -> None:
        for status in ("failed", "awaiting_answer"):
            for field in ("destination", "model", "request_body_sha256", "decision",
                          "probabilities", "confidence", "passed_over"):
                with self.subTest(status=status, field=field):
                    manifest = fixture()
                    run = manifest["pairs"][0]["preflight"]["run"]
                    run.update(status="failed", selected_slot=None)
                    evidence = observation(status)
                    evidence[field] = observation()[field]
                    run["output"].update(jev_preflight=evidence, full_llm_skipped=False,
                        generation_path="not_entered" if status == "awaiting_answer" else "full_lane")
                    result = self.execute(manifest)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("answerless preflight", result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_completed_judgment_requires_typed_provenance(self) -> None:
        for field in ("destination", "model", "request_body_sha256", "passed_over", "elapsed_s", "probabilities", "confidence"):
            with self.subTest(field=field):
                manifest = fixture()
                manifest["evidence_kind"] = "live"
                del manifest["pairs"][0]["preflight"]["run"]["output"]["jev_preflight"][field]
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
        for field, value in (("confidence", True), ("elapsed_s", -1),
                             ("model", ""), ("request_body_sha256", "missing"),
                             ("passed_over", {}), ("destination", {}),
                             ("probabilities", {"keep_current": 0.2, "needs_generation": 0.7, "uncertain": 0.1}),
                             ("probabilities", {"keep_current": 0.8, "needs_generation": 0.2, "uncertain": 0.2})):
            with self.subTest(field=field, value=value):
                manifest = fixture()
                manifest["pairs"][0]["preflight"]["run"]["output"]["jev_preflight"][field] = value
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")

    def test_fallback_success_retains_actual_preflight_outcome(self) -> None:
        for status in ("failed", "invalid_answer", "judged"):
            with self.subTest(status=status):
                manifest = fixture()
                run = manifest["pairs"][0]["preflight"]["run"]
                run["selected_slot"] = "fixture-cli"
                evidence = observation(status, "needs_generation")
                run["output"].update(jev_preflight=evidence, generation_path="full_lane", full_llm_skipped=False)
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 0, result.stderr)
                pair = json.loads(result.stdout)["pairs"][0]
                self.assertEqual(pair["preflight_status"], "succeeded")
                self.assertEqual(pair["preflight_observation"], evidence)

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
            "disabled_candidate",
            "keep_current_fallback",
            "different_actor",
            "successful_not_entered",
        ):
            with self.subTest(mode=mode):
                manifest = fixture()
                pair = manifest["pairs"][0]
                run = pair["preflight"]["run"]
                if mode == "different_actor":
                    run["actor"] = "other-keeper"
                elif mode in ("disabled_candidate", "keep_current_fallback", "successful_not_entered"):
                    run["output"].update(generation_path="full_lane", full_llm_skipped=False)
                    if mode == "keep_current_fallback":
                        run["selected_slot"] = "fixture-cli"
                    if mode == "disabled_candidate":
                        run["output"]["jev_preflight"] = {"status": "skipped", "reason": "librarian_preflight_disabled"}
                    elif mode == "successful_not_entered":
                        run["output"].update(generation_path="not_entered", jev_preflight=observation("awaiting_answer"))
                elif mode == "input":
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
                        jev_preflight=observation("awaiting_answer"),
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
                if mode == "keep_current_fallback":
                    self.assertIn("keep-current fallback domain rejection", result.stderr)
                elif mode == "successful_not_entered":
                    self.assertIn("interrupted awaiting preflight", result.stderr)


if __name__ == "__main__":
    unittest.main()
