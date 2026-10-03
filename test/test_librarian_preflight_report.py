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
                    "kind": "exact",
                    "payload": {
                        "actual_input": {
                            "turn_ref": "fixture-trace#1",
                            "goal_context": {"status": "no_task"},
                            "historical_task_contexts": [],
                            "keeper_instructions": "",
                            "prompt": {"key": "librarian", "source": "file", "file_path": "prompts/librarian.md",
                                       "effective_template": "{{conversation_history}}", "rendered_bytes": 13,
                                       "rendered_sha256": "a" * 64},
                            "rendered_prompt_variables": {
                                "keeper_id": "fixture-keeper", "facts_budget": "max=100; current ordinary=1",
                                "keeper_instructions": "", "historical_task_contexts": "[]", "continuity": "null",
                                "working_context": '{"sources":[],"previous":null,"unavailable":[]}',
                                "working_contexts_rule": "fixture rule", "goal_context": '{"status":"no_task"}',
                                "current_memory": "frozen memory", "conversation_history": "frozen source",
                                "turn_tool_observations": "", "counterpart_observations": "", "source": "frozen source",
                            },
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
                        "reason": "librarian_preflight_disabled", "elapsed_s": None,
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
        return self.execute_raw(json.dumps(manifest))

    def execute_raw(self, raw: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(raw)
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_unresolved_prompts_are_refused(self) -> None:
        for source, template in (("missing", "resolved"), ("file", ""), ("override", " \n ")):
            with self.subTest(source=source, template=template):
                manifest = fixture()
                for arm in ("baseline", "preflight"):
                    prompt = manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"]["prompt"]
                    prompt.update(source=source, effective_template=template)
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")

    def test_historical_task_variants_reject_foreign_fields(self) -> None:
        for context in ({"kind": "no_task"}, {"kind": "admission_not_recorded"},
                        {"kind": "task_source_unavailable", "detail": "unreadable"},
                        {"kind": "task", "task_id": "task-1", "goals": {"kind": "observed", "goals": []}}):
            for corrupt in (False, True):
                with self.subTest(context=context, corrupt=corrupt):
                    manifest = fixture()
                    frozen = copy.deepcopy(context)
                    if corrupt:
                        frozen["detail" if context["kind"] == "task" else "task_id"] = "stale"
                    for arm in ("baseline", "preflight"):
                        actual = manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"]
                        actual["historical_task_contexts"] = [{
                            "source": {"kind": "official_turn"},
                            "attribution": {"kind": "observed", "turn_ref": "fixture-trace#1", "task_context": frozen},
                            "first_message": 0, "after_message": 1,
                            "first_tool_observation": 0, "after_tool_observation": 0,
                        }]
                    result = self.execute(manifest)
                    self.assertEqual(result.returncode, int(corrupt), result.stderr)
                    if corrupt:
                        self.assertEqual(result.stdout, "")

    def test_rendered_goal_context_matches_typed_input(self) -> None:
        for rendered in (' { "status" : "no_task" } ',
                         '{"status":"available","task_id":"task-stale","goals":[]}',
                         '{"status":"no_task","status":"no_task"}'):
            manifest = fixture()
            for arm in ("baseline", "preflight"):
                actual = manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"]
                actual["rendered_prompt_variables"]["goal_context"] = rendered
            result = self.execute(manifest)
            self.assertEqual(result.returncode, 0 if rendered.startswith(' ') else 1, result.stderr)
            if result.returncode:
                self.assertEqual(result.stdout, "")

    def test_http_refusal_matches_attempt_destination(self) -> None:
        for destination in ("https://fixture.invalid/jev", "https://other.invalid/jev"):
            manifest = fixture()
            observed = manifest["pairs"][0]["preflight"]["run"]["output"]["jev_preflight"]
            observed["passed_over"] = [{
                "destination_uri": "https://fixture.invalid/jev", "model": "fixture-model",
                "refusal": {"kind": "http_response", "status": 503, "detail": "unavailable",
                            "destination_uri": destination, "body": "unavailable"},
            }]
            result = self.execute(manifest)
            self.assertEqual(result.returncode, int(destination.startswith("https://other")), result.stderr)
            if result.returncode:
                self.assertEqual(result.stdout, "")

    def test_actor_must_match_each_frozen_keeper(self) -> None:
        for arms in (("baseline",), ("preflight",), ("baseline", "preflight")):
            with self.subTest(arms=arms):
                manifest = fixture()
                for arm in arms:
                    manifest["pairs"][0][arm]["run"]["actor"] = "other-keeper"
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("actor must match the frozen keeper_id", result.stderr)

    def test_disabled_baseline_requires_explicit_null_domain_rejection(self) -> None:
        for value in ("missing", "No-change output failed domain validation", False, {}):
            with self.subTest(value=value):
                manifest = fixture()
                output = manifest["pairs"][0]["baseline"]["run"]["output"]
                if value == "missing":
                    del output["preflight_domain_rejection"]
                else:
                    output["preflight_domain_rejection"] = value
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("baseline must explicitly record null domain rejection", result.stderr)

    def test_evaluated_pair_requires_empty_frozen_context(self) -> None:
        for key, value in (
            ("continuity", '{"previous_working_state":null}'),
            ("continuity", "{}"),
            ("continuity", "not json"),
            ("working_context", "{}"),
            ("working_context", '{"sources":[],"previous":null,"unavailable":["fixture unavailable"]}'),
            ("working_context", '{"sources":[{"reference":"s1","content":{"text":"fixture"}}],"previous":null,"unavailable":[]}'),
            ("working_context", '{"sources":[],"previous":[],"unavailable":[]}'),
            ("working_context", '{"sources":[],"previous":null,"unavailable":[],"sources":[]}'),
            ("working_context", "not json"),
        ):
            with self.subTest(key=key, value=value):
                manifest = fixture()
                for arm in ("baseline", "preflight"):
                    variables = manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"]["rendered_prompt_variables"]
                    variables[key] = value
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("preflight measurement refused:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_empty_context_uses_parsed_json_not_spelling(self) -> None:
        manifest = fixture()
        for arm in ("baseline", "preflight"):
            variables = manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"]["rendered_prompt_variables"]
            variables["continuity"] = " \n null \n "
            variables["working_context"] = '{ "unavailable": [], "previous": null, "sources": [] }'
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["recorded_generation_skips"], 1)

    def test_complete_input_is_required_even_when_both_arms_match(self) -> None:
        valid = fixture()["pairs"][0]["baseline"]["run"]["input"]["payload"]
        removals = [
            (key,) for key in valid
        ] + [("actual_input", key) for key in valid["actual_input"]] + [
            ("actual_input", "prompt", key) for key in valid["actual_input"]["prompt"]
        ] + [("actual_input", "rendered_prompt_variables", key)
             for key in valid["actual_input"]["rendered_prompt_variables"] if key != "source"]
        for path in removals:
            with self.subTest(path=path):
                manifest = fixture()
                for arm in ("baseline", "preflight"):
                    value = manifest["pairs"][0][arm]["run"]["input"]["payload"]
                    for key in path[:-1]:
                        value = value[key]
                    del value[path[-1]]
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("Traceback", result.stderr)

    def test_typed_goal_and_historical_input_alternatives(self) -> None:
        goal = {"goal_id": "goal-fixture", "phase": "executing", "criterion": {
            "revision": "rev-1", "title": "Keep constraints", "metric": None, "target_value": None,
        }}
        context = {"status": "available", "task_id": "task-1", "goals": [goal]}
        history = [{"source": {"kind": "atoms", "trace_id": "fixture-trace", "start_atom": 0, "end_atom": 1},
                    "attribution": {"kind": "observed", "turn_ref": "fixture-trace#1",
                                    "task_context": {"kind": "task", "task_id": "task-1",
                                                     "goals": {"kind": "observed", "goals": [goal]}}},
                    "first_message": 0, "after_message": 1,
                    "first_tool_observation": 0, "after_tool_observation": 0}]
        manifest = fixture()
        for arm in ("baseline", "preflight"):
            manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"].update(
                goal_context=copy.deepcopy(context), historical_task_contexts=copy.deepcopy(history))
            manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"]["rendered_prompt_variables"]["goal_context"] = json.dumps(context)
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        for arm in ("baseline", "preflight"):
            del manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"]["historical_task_contexts"][0]["attribution"]["task_context"]["goals"]["goals"][0]["criterion"]["revision"]
        self.assertEqual(self.execute(manifest).returncode, 1)

    def test_baseline_requires_disabled_answerless_observation(self) -> None:
        for key, value in [("elapsed_s", 0), ("elapsed_s", "missing"),
                           ("failure", {}), *[(key, None) for key in observation() if key not in ("status", "elapsed_s")]]:
            with self.subTest(key=key, value=value):
                manifest = fixture()
                baseline = manifest["pairs"][0]["baseline"]["run"]["output"]["jev_preflight"]
                if value == "missing":
                    del baseline[key]
                else:
                    baseline[key] = value
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")

    def test_failed_arm_details_are_required_and_retained(self) -> None:
        for arm in ("baseline", "preflight"):
            manifest = fixture()
            run = manifest["pairs"][0][arm]["run"]
            run.update(status="failed", code="output_invalid", detail="fixture schema failure")
            result = self.execute(manifest)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["pairs"][0][arm + "_failure"],
                             {"code": "output_invalid", "detail": "fixture schema failure"})
            for key in ("code", "detail"):
                for value in (None, "", " "):
                    invalid = copy.deepcopy(manifest)
                    invalid["pairs"][0][arm]["run"][key] = value
                    self.assertEqual(self.execute(invalid).returncode, 1)
                invalid = copy.deepcopy(manifest)
                del invalid["pairs"][0][arm]["run"][key]
                self.assertEqual(self.execute(invalid).returncode, 1)

    def test_nonfailed_arms_reject_failure_fields(self) -> None:
        for arm in ("baseline", "preflight"):
            for status in ("succeeded", "cancelled"):
                manifest = fixture()
                run = manifest["pairs"][0][arm]["run"]
                run["status"] = status
                valid = self.execute(manifest)
                self.assertEqual(valid.returncode, 0, valid.stderr)
                self.assertIsNone(json.loads(valid.stdout)["pairs"][0][arm + "_failure"])
                for field in ("code", "detail"):
                    for value in (None, "stale failure"):
                        with self.subTest(arm=arm, status=status, field=field, value=value):
                            invalid = copy.deepcopy(manifest)
                            invalid["pairs"][0][arm]["run"][field] = value
                            result = self.execute(invalid)
                            self.assertEqual(result.returncode, 1)
                            self.assertEqual(result.stdout, "")
                            self.assertIn("nonfailed run must not record code or detail", result.stderr)

    def test_goal_context_variants_require_exact_fields(self) -> None:
        for context in (
            {"status": "no_task"},
            {"status": "available", "task_id": "task-1", "goals": []},
            {"status": "unavailable", "task_id": "task-1", "detail": "fixture unavailable"},
        ):
            manifest = fixture()
            for arm in ("baseline", "preflight"):
                actual = manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"]
                actual["goal_context"] = copy.deepcopy(context)
                actual["rendered_prompt_variables"]["goal_context"] = json.dumps(context)
            valid = self.execute(manifest)
            self.assertEqual(valid.returncode, 0, valid.stderr)
            for field, value in (("task_id", "task-1"), ("goals", []), ("detail", "stale error")):
                if field in context:
                    continue
                with self.subTest(context=context, field=field):
                    invalid = copy.deepcopy(manifest)
                    for arm in ("baseline", "preflight"):
                        actual = invalid["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"]
                        actual["goal_context"][field] = value
                    result = self.execute(invalid)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("goal context fields do not match status", result.stderr)

    def test_duplicate_keys_are_refused_before_normalization(self) -> None:
        raw = json.dumps(fixture())
        for old, replacement in [('"status": "succeeded"', '"status":"failed", "status":"succeeded"'),
                                 ('"message_count": 1', '"message_count":2, "message_count":1')]:
            result = self.execute_raw(raw.replace(old, replacement, 1))
            self.assertEqual(result.returncode, 1)
            self.assertIn("duplicate JSON object key", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_huge_integer_numeric_fields_refuse_without_traceback(self) -> None:
        for place in ("run", "observation", "probability"):
            with self.subTest(place=place):
                manifest = fixture()
                run = manifest["pairs"][0]["preflight"]["run"]
                if place == "run":
                    run["elapsed_s"] = 10**999
                elif place == "observation":
                    run["output"]["jev_preflight"]["elapsed_s"] = 10**999
                else:
                    run["output"]["jev_preflight"]["probabilities"]["keep_current"] = 10**999
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertIn("preflight measurement refused:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_nonfinite_aggregate_refuses_without_traceback(self) -> None:
        manifest = fixture()
        manifest["pairs"][0]["preflight"]["run"]["elapsed_s"] = 1e308
        second = copy.deepcopy(manifest["pairs"][0])
        second["sample_id"] = "two"
        second["baseline"]["run"]["run_id"] = "base-2"
        second["preflight"]["run"]["run_id"] = "jev-2"
        manifest["pairs"].append(second)
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 1)
        self.assertIn("preflight measurement refused:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_preflight_variants_reject_foreign_fields(self) -> None:
        for status, fields in (("invalid_answer", ("decision", "confidence", "probabilities", "failure")),
                               ("judged", ("reason", "failure")), ("failed", ("reason",)),
                               ("awaiting_answer", ("reason", "failure"))):
            for field in fields:
                with self.subTest(status=status, field=field):
                    manifest = fixture()
                    run = manifest["pairs"][0]["preflight"]["run"]
                    awaiting = status == "awaiting_answer"
                    run.update(status="cancelled" if awaiting else "succeeded",
                               selected_slot=None if awaiting else "fixture-cli")
                    run["output"].update(
                        jev_preflight=observation(status, "needs_generation"),
                        generation_path="not_entered" if awaiting else "full_lane",
                        full_llm_skipped=False)
                    valid = self.execute(manifest)
                    self.assertEqual(valid.returncode, 0, valid.stderr)
                    run["output"]["jev_preflight"][field] = None
                    invalid = self.execute(manifest)
                    self.assertEqual(invalid.returncode, 1)
                    self.assertIn("must not report " + field, invalid.stderr)
                    self.assertEqual(invalid.stdout, "")

    def test_wall_clock_durations_are_preserved_without_an_invented_bound(self) -> None:
        manifest = fixture()
        run = manifest["pairs"][0]["preflight"]["run"]
        run["output"]["jev_preflight"]["elapsed_s"] = 10.0
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        pair = json.loads(result.stdout)["pairs"][0]
        self.assertEqual(pair["preflight_observation"]["elapsed_s"], 10.0)
        self.assertEqual(pair["preflight_elapsed_s"], 0.1)

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
        run.update(run_id="jev-2", status="failed", elapsed_s=6.0,
                   code="provider_failed", detail="fixture generation failed")
        run["output"].update(
            jev_preflight=observation("failed"),
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
                if status == "failed":
                    run.update(code="fixture_interrupted", detail="fixture failed before selection")
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    json.loads(result.stdout)["pairs"][0]["baseline_status"], status
                )

    def test_answerless_observations_reject_received_answer_fields(self) -> None:
        for status in ("failed", "awaiting_answer"):
            for field in ("destination", "model", "request_body_sha256", "decision",
                          "probabilities", "confidence", "passed_over"):
                with self.subTest(status=status, field=field):
                    manifest = fixture()
                    run = manifest["pairs"][0]["preflight"]["run"]
                    run.update(status="failed", selected_slot=None, code="cancelled_evaluation", detail="fixture interruption")
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


if __name__ == "__main__":
    unittest.main()
