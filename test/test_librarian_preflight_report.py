"""Exercise the public report CLI's paired evidence and refusal boundaries."""

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/librarian/compare-preflight.py"


def observation(
    status: str = "judged", decision: str = "keep_current"
) -> dict[str, Any]:
    if status == "awaiting_answer":
        return {"status": status, "elapsed_s": None}
    if status == "failed":
        return {
            "status": status,
            "elapsed_s": 0.05,
            "failure": {
                "kind": "every_destination_refused",
                "attempts": [
                    {
                        "destination_uri": "https://fixture.invalid/jev",
                        "model": "fixture-model",
                        "refusal": {
                            "kind": "transport",
                            "detail": "fixture connection failure",
                        },
                    }
                ],
            },
        }
    result: dict[str, Any] = {
        "status": status,
        "elapsed_s": 0.05,
        "destination": {
            "destination_uri": "https://fixture.invalid/jev",
            "model": "fixture-model",
        },
        "model": "fixture-answering-model",
        "request_body_sha256": "d" * 64,
        "passed_over": [],
    }
    if status == "invalid_answer":
        result["reason"] = "fixture missing choice answer"
    else:
        result.update(
            decision=decision,
            confidence=0.8,
            probabilities={
                label: 0.8 if label == decision else 0.1
                for label in ("keep_current", "needs_generation", "uncertain")
            },
        )
    return result


def fixture() -> dict[str, Any]:
    def run(run_id: str, enabled: bool, elapsed: float) -> dict[str, Any]:
        return {
            "generated_at": "2026-10-04T00:00:00Z",
            "run": {
                "run_kind": "exact_output",
                "skill_evidence": {"state": "no_keeper_skills"},
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
                            "prompt": {
                                "key": "librarian",
                                "source": "file",
                                "file_path": "prompts/librarian.md",
                                "effective_template": "{{conversation_history}}",
                                "rendered_bytes": 13,
                                "rendered_sha256": hashlib.sha256(
                                    b"frozen source"
                                ).hexdigest(),
                            },
                            "rendered_prompt_variables": {
                                "keeper_id": "fixture-keeper",
                                "facts_budget": "max=100; current ordinary=1",
                                "keeper_instructions": "[no keeper instructions]",
                                "historical_task_contexts": "[]",
                                "continuity": "null",
                                "working_context": '{"sources":[],"previous":null,"unavailable":[]}',
                                "working_contexts_rule": "fixture rule",
                                "goal_context": '{"status":"no_task"}',
                                "current_memory": "frozen memory",
                                "conversation_history": "frozen source",
                                "turn_tool_observations": "",
                                "counterpart_observations": "",
                                "source": "frozen source",
                            },
                        },
                        "message_count": 1,
                        "current_fact_count": 1,
                    },
                },
                "output": {
                    "absorb_gate": {
                        "status": "skipped",
                        "reason": "no_absorptions",
                        "applied_absorptions": [],
                    },
                    "absorption": {"applied": [], "not_applied": []},
                    "claims_not_applied": [],
                    "exact_output": {
                        "new_claims": [],
                        "dropped": [],
                        "working_contexts": [],
                        "working_state": None,
                    },
                    "before": {"present": True, "fact_count": 1},
                    "after": {
                        "commit": "unchanged",
                        "revision": 1,
                        "updated_at": 1.0,
                        "fact_count": 1,
                        "change": {"added_count": 0, "removed_count": 0, "retained": 1},
                    },
                    "jev_preflight": observation()
                    if enabled
                    else {
                        "status": "skipped",
                        "reason": "librarian_preflight_disabled",
                        "elapsed_s": None,
                    },
                    "generation_path": "jev_no_change" if enabled else "full_lane",
                    "full_llm_skipped": enabled,
                    "preflight_domain_rejection": None,
                },
            },
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

    def test_incremental_manifest_preserves_all_pairs_and_canonical_digest(
        self,
    ) -> None:
        manifest = fixture()
        pairs = []
        for index in range(5):
            pair = copy.deepcopy(manifest["pairs"][0])
            pair["sample_id"] = str(index)
            for arm in ("baseline", "preflight"):
                pair[arm]["run"]["run_id"] = arm + str(index)
            pairs.append(pair)
        manifest["pairs"] = pairs
        manifest["unused"] = {
            "integer": 2**80,
            "float": -0.0,
            "text": "한글🙂",
            "array": [None, True],
        }
        for keys in (list(manifest), list(reversed(manifest))):
            with self.subTest(keys=keys):
                reordered = {key: manifest[key] for key in keys}
                result = self.execute(reordered)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(
                    [p["sample_id"] for p in report["pairs"]],
                    [str(i) for i in range(5)],
                )
                self.assertEqual(report["recorded_generation_skips"], 5)
                expected = hashlib.sha256(
                    json.dumps(
                        manifest, sort_keys=True, separators=(",", ":"), allow_nan=False
                    ).encode()
                ).hexdigest()
                self.assertEqual(report["manifest_sha256"], expected)

    def test_incremental_json_boundary_and_syntax(self) -> None:
        # Place a number across the initial read boundary, including a partial exponent.
        for offset in range(5):
            prefix = '{"padding":"' + ("x" * (65510 + offset)) + '","number":'
            raw = prefix + "1.25e+100," + json.dumps(fixture())[1:]
            result = self.execute_raw(raw)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = hashlib.sha256(
                json.dumps(
                    json.loads(raw), sort_keys=True, separators=(",", ":")
                ).encode()
            ).hexdigest()
            self.assertEqual(json.loads(result.stdout)["manifest_sha256"], expected)
        raw = json.dumps(fixture())
        for malformed in (
            raw + "{}",
            raw[:-1],
            raw[:-1] + ",}",
            raw.replace('"pairs": [', '"pairs": null, "pairs": [', 1),
            raw.replace('"pairs": [', '"pairs": {', 1),
            raw.replace(
                '"run_id": "base-1"', '"run_id": "base-1", "run_id": "duplicate"', 1
            ),
            raw.replace('"environment":', '"unused": [0,], "environment":', 1),
        ):
            with self.subTest(malformed=malformed[:60]):
                result = self.execute_raw(malformed)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("Traceback", result.stderr)

    def test_chunked_hash_matches_canonical_json(self) -> None:
        manifest = fixture()
        # Cross chunk boundaries with escaped, Unicode and surrogate code points.
        value = '"\\\\\n\t한글🙂\ud800' * 10000
        for arm in ("baseline", "preflight"):
            actual = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                "actual_input"
            ]
            actual["rendered_prompt_variables"]["unused"] = value
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        canonical = json.dumps(
            manifest, sort_keys=True, separators=(",", ":"), allow_nan=False
        ).encode()
        self.assertEqual(
            report["manifest_sha256"], hashlib.sha256(canonical).hexdigest()
        )
        payload = manifest["pairs"][0]["baseline"]["run"]["input"]["payload"]
        expected = hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        self.assertEqual(report["pairs"][0]["input_sha256"], expected)

    def test_endpoint_envelope_and_provenance_are_required(self) -> None:
        for path in (
            ("generated_at",),
            ("run", "run_kind"),
            ("run", "skill_evidence"),
            ("run", "skill_evidence", "state"),
        ):
            for replacement in ("missing", None, "invented"):
                if path == ("generated_at",) and replacement == "invented":
                    continue
                with self.subTest(path=path, replacement=replacement):
                    manifest = fixture()
                    for arm in ("baseline", "preflight"):
                        record = manifest["pairs"][0][arm]
                        for key in path[:-1]:
                            record = record[key]
                        if replacement == "missing":
                            del record[path[-1]]
                        else:
                            record[path[-1]] = replacement
                    result = self.execute(manifest)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, "")

    def test_success_requires_completion_structures(self) -> None:
        output = fixture()["pairs"][0]["baseline"]["run"]["output"]
        fields = (
            "absorb_gate",
            "absorption",
            "claims_not_applied",
            "exact_output",
            "before",
            "after",
        )
        paths = [(key,) for key in fields]
        paths += [
            (key, member)
            for key in ("absorb_gate", "absorption", "before", "after")
            for member in output[key]
        ]
        paths += [("exact_output", key) for key in ("new_claims", "dropped")]
        paths += [("after", "change", key) for key in output["after"]["change"]]
        for path in paths:
            with self.subTest(path=path):
                manifest = fixture()
                for arm in ("baseline", "preflight"):
                    record = manifest["pairs"][0][arm]["run"]["output"]
                    for key in path[:-1]:
                        record = record[key]
                    del record[path[-1]]
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
        for status in ("failed", "cancelled"):
            manifest = fixture()
            for arm in ("baseline", "preflight"):
                run = manifest["pairs"][0][arm]["run"]
                run["status"] = status
                if status == "failed":
                    run.update(code="fixture_failed", detail="before commit")
                for key in fields:
                    del run["output"][key]
            result = self.execute(manifest)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_success_completion_variants_and_types(self) -> None:
        manifest = fixture()
        output = manifest["pairs"][0]["baseline"]["run"]["output"]
        output["after"].update(commit="rewritten", revision=2)
        output["absorb_gate"] = {
            "status": "judged",
            "applied_absorptions": [],
            "left": [],
            "conveyed": [],
            "unjudged": [],
            "unjudgeable": [],
            "requests": 0,
            "conveyed_boundary": 0.5,
            "copy_checks": [],
            "evaluations": [],
        }
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        for field, bad in (
            ("before", {"present": "yes", "fact_count": 1}),
            ("exact_output", {}),
            ("claims_not_applied", [False]),
            ("absorption", {"applied": [{}], "not_applied": []}),
            ("absorb_gate", {"status": "invented"}),
        ):
            with self.subTest(field=field):
                invalid = copy.deepcopy(manifest)
                invalid["pairs"][0]["baseline"]["run"]["output"][field] = bad
                self.assertEqual(self.execute(invalid).returncode, 1)

    def test_completion_before_matches_frozen_count(self) -> None:
        for current, present, before, accepted in (
            (1, True, 1, True),
            (0, True, 0, True),
            (0, False, 0, True),
            (1, False, 1, False),
            (1, True, 0, False),
            (1, True, 2, False),
            (0, False, 1, False),
        ):
            with self.subTest(current=current, present=present, before=before):
                manifest = fixture()
                for arm in ("baseline", "preflight"):
                    run = manifest["pairs"][0][arm]["run"]
                    run["input"]["payload"]["current_fact_count"] = current
                    run["input"]["payload"]["actual_input"][
                        "rendered_prompt_variables"
                    ]["facts_budget"] = f"max=100; current ordinary={current}"
                    run["output"]["before"] = {"present": present, "fact_count": before}
                    run["output"]["after"]["fact_count"] = current
                    run["output"]["after"]["change"]["retained"] = current
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 0 if accepted else 1, result.stderr)
                if not accepted:
                    self.assertEqual(result.stdout, "")

    def test_nested_json_recursion_is_a_normal_refusal(self) -> None:
        shallow = "[" * 20 + "0" + "]" * 20
        valid = self.execute_raw(
            '{"nested":' + shallow + "," + json.dumps(fixture())[1:]
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)
        deep = "[" * 1500 + "0" + "]" * 1500
        root = '{"nested":' + deep + "," + json.dumps(fixture())[1:]
        manifest = fixture()
        manifest["pairs"] = []
        pair = json.dumps(manifest).replace('"pairs": []', '"pairs": [' + deep + "]")
        for location, raw in (("root metadata", root), ("pair", pair)):
            with self.subTest(location=location):
                result = self.execute_raw(raw)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("preflight measurement refused:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_success_requires_persisted_revision(self) -> None:
        for revision in (0, 1):
            manifest = fixture()
            for arm in ("baseline", "preflight"):
                manifest["pairs"][0][arm]["run"]["output"]["after"]["revision"] = (
                    revision
                )
            result = self.execute(manifest)
            self.assertEqual(
                result.returncode, 0 if revision == 1 else 1, result.stderr
            )

    def test_success_rejects_fully_recorded_failed_gate(self) -> None:
        failed_gate = {
            "status": "failed",
            "reason": "fixture evaluator failed",
            "applied_absorptions": [],
            "left": [],
            "conveyed": [],
            "unjudged": [],
            "unjudgeable": [],
            "conveyed_boundary": 0.5,
            "copy_checks": [],
            "evaluations": [],
        }
        for status in ("succeeded", "failed", "cancelled"):
            manifest = fixture()
            for arm in ("baseline", "preflight"):
                run = manifest["pairs"][0][arm]["run"]
                run["status"] = status
                run["output"]["absorb_gate"] = copy.deepcopy(failed_gate)
                if status != "succeeded":
                    for key in (
                        "after",
                        "before",
                        "exact_output",
                        "absorption",
                        "claims_not_applied",
                    ):
                        del run["output"][key]
                if status == "failed":
                    run.update(
                        code="absorb_judgment_failed", detail="fixture evaluator failed"
                    )
            result = self.execute(manifest)
            self.assertEqual(
                result.returncode, 1 if status == "succeeded" else 0, result.stderr
            )
            if status == "succeeded":
                self.assertEqual(result.stdout, "")

    def test_slots_and_domain_fallback_remain_visible(self) -> None:
        manifest = fixture()
        run = manifest["pairs"][0]["preflight"]["run"]
        run["selected_slot"] = "different-provider-slot"
        run["output"].update(
            generation_path="full_lane",
            full_llm_skipped=False,
            preflight_domain_rejection="no-change domain rejected",
        )
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        pair = json.loads(result.stdout)["pairs"][0]
        self.assertEqual(pair["baseline_selected_slot"], "fixture-cli")
        self.assertEqual(pair["preflight_selected_slot"], "different-provider-slot")
        self.assertEqual(
            pair["preflight_domain_rejection"], "no-change domain rejected"
        )

    def test_unix_errors_use_closed_variants_and_exact_fields(self) -> None:
        for error, accepted in (
            ({"kind": "eacces"}, True),
            ({"kind": "eopnotsupp"}, True),
            ({"kind": "eunknownerr", "code": -123}, True),
            ({"kind": "invented_errno"}, False),
            ({"kind": "eacces", "code": 1}, False),
            ({"kind": "eunknownerr"}, False),
            ({"kind": "eunknownerr", "code": True}, False),
            ({"kind": "eunknownerr", "code": 1, "extra": 0}, False),
        ):
            for location in ("reason", "mirror"):
                with self.subTest(error=error, location=location):
                    manifest = fixture()
                    source = {
                        "file": "goals.json",
                        "reason": {"kind": "missing_after_init"},
                        "mirror": {"kind": "mirror_absent"},
                        "reset_step": {"kind": "reset_goal_store"},
                    }
                    source[location] = {
                        "kind": "unreadable"
                        if location == "reason"
                        else "mirror_unreadable",
                        "error": error,
                    }
                    history = [
                        {
                            "source": {"kind": "boundary_only"},
                            "attribution": {
                                "kind": "observed",
                                "turn_ref": "fixture-trace#1",
                                "task_context": {
                                    "kind": "task",
                                    "task_id": "task-1",
                                    "goals": {
                                        "kind": "unavailable",
                                        "error": {
                                            "kind": "goal_source_unavailable",
                                            "error": source,
                                        },
                                    },
                                },
                            },
                            "first_message": 0,
                            "after_message": 1,
                            "first_tool_observation": 0,
                            "after_tool_observation": 0,
                        }
                    ]
                    for arm in ("baseline", "preflight"):
                        actual = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                            "actual_input"
                        ]
                        actual["historical_task_contexts"] = history
                        actual["rendered_prompt_variables"][
                            "historical_task_contexts"
                        ] = json.dumps(history)
                    result = self.execute(manifest)
                    self.assertEqual(
                        result.returncode, 0 if accepted else 1, result.stderr
                    )

    def test_rendered_prompt_matches_producer_substitution(self) -> None:
        cases = (
            ("{{conversation_history}}", {}, "frozen source"),
            (
                "{{ \tconversation_history\n}}/{{conversation_history}}",
                {},
                "frozen source/frozen source",
            ),
            (
                "{{conversation_history}}",
                {"conversation_history": "{{unknown}}\\1"},
                "{{unknown}}\\1",
            ),
            ("{{extra}}", {"extra": "한글🙂"}, "한글🙂"),
            ("{{ extra }}", {" extra ": "trimmed key"}, "trimmed key"),
            ("{{extra}}", {" extra ": "first", "extra": "second"}, "first"),
            ("{{extra}}", {"extra": "", " extra ": "second"}, ""),
            ("{{}}/{{   }}/{{broken", {}, "{{}}/{{   }}/{{broken"),
            ("{{   }}", {"": "blank key"}, "blank key"),
            ("\u00a0", {}, "\u00a0"),
            ("{{\vextra\v}}", {"\vextra\v": "vertical"}, "vertical"),
        )
        for template, extra, rendered in cases:
            with self.subTest(template=template, extra=extra):
                manifest = fixture()
                for arm in ("baseline", "preflight"):
                    actual = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                        "actual_input"
                    ]
                    actual["rendered_prompt_variables"].update(extra)
                    actual["prompt"].update(
                        effective_template=template,
                        rendered_bytes=len(rendered.encode("utf-8")),
                        rendered_sha256=hashlib.sha256(
                            rendered.encode("utf-8")
                        ).hexdigest(),
                    )
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_impossible_rendered_prompt_evidence_is_refused(self) -> None:
        for update in (
            {"effective_template": "{{does_not_exist}}"},
            {"effective_template": "{{known}}/{{unknown}}"},
            {"rendered_sha256": "0" * 64},
            {"rendered_bytes": 999},
            {
                "effective_template": "{{extra}}",
                "rendered_bytes": 3,
                "rendered_sha256": hashlib.sha256("한글🙂".encode()).hexdigest(),
            },
        ):
            with self.subTest(update=update):
                manifest = fixture()
                for arm in ("baseline", "preflight"):
                    actual = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                        "actual_input"
                    ]
                    actual["rendered_prompt_variables"].update(
                        extra="한글🙂", known="present"
                    )
                    actual["prompt"].update(update)
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")

    def test_keeper_instructions_match_native_prompt_normalization(self) -> None:
        cases = (
            ("", "[no keeper instructions]", True),
            (" \t\n\r\f", "[no keeper instructions]", True),
            (" \tkeep sources\r\n\f", "keep sources", True),
            ("\u00a0keep\u00a0", "\u00a0keep\u00a0", True),
            ("\vkeep\v", "\vkeep\v", True),
            ("keep\n sources", "keep\n sources", True),
            ("preserve sources", "ignore sources", False),
            ("", "", False),
            (" \t\n\r\f", "", False),
            (" \tkeep sources\r\n\f", " \tkeep sources\r\n\f", False),
            ("\u00a0keep\u00a0", "keep", False),
            ("\vkeep\v", "keep", False),
            ("keep\n sources", "keep sources", False),
        )
        for typed, rendered, accepted in cases:
            with self.subTest(typed=typed, rendered=rendered):
                manifest = fixture()
                for arm in ("baseline", "preflight"):
                    actual = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                        "actual_input"
                    ]
                    actual["keeper_instructions"] = typed
                    actual["rendered_prompt_variables"]["keeper_instructions"] = (
                        rendered
                    )
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 0 if accepted else 1, result.stderr)
                if not accepted:
                    self.assertEqual(result.stdout, "")
                    self.assertIn("keeper instructions", result.stderr)

    def test_unresolved_prompts_are_refused(self) -> None:
        for source, template in (
            ("missing", "resolved"),
            ("file", ""),
            ("override", " \n "),
        ):
            with self.subTest(source=source, template=template):
                manifest = fixture()
                for arm in ("baseline", "preflight"):
                    prompt = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                        "actual_input"
                    ]["prompt"]
                    prompt.update(source=source, effective_template=template)
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")

    def test_historical_task_variants_reject_foreign_fields(self) -> None:
        for context in (
            {"kind": "no_task"},
            {"kind": "admission_not_recorded"},
            {"kind": "task_source_unavailable", "detail": "unreadable"},
            {
                "kind": "task",
                "task_id": "task-1",
                "goals": {"kind": "observed", "goals": []},
            },
        ):
            for corrupt in (False, True):
                with self.subTest(context=context, corrupt=corrupt):
                    manifest = fixture()
                    frozen = copy.deepcopy(context)
                    if corrupt:
                        frozen["detail" if context["kind"] == "task" else "task_id"] = (
                            "stale"
                        )
                    for arm in ("baseline", "preflight"):
                        actual = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                            "actual_input"
                        ]
                        actual["historical_task_contexts"] = [
                            {
                                "source": {"kind": "official_turn"},
                                "attribution": {
                                    "kind": "observed",
                                    "turn_ref": "fixture-trace#1",
                                    "task_context": frozen,
                                },
                                "first_message": 0,
                                "after_message": 1,
                                "first_tool_observation": 0,
                                "after_tool_observation": 0,
                            }
                        ]
                        actual["rendered_prompt_variables"][
                            "historical_task_contexts"
                        ] = json.dumps(actual["historical_task_contexts"])
                    result = self.execute(manifest)
                    self.assertEqual(result.returncode, int(corrupt), result.stderr)
                    if corrupt:
                        self.assertEqual(result.stdout, "")

    def test_rendered_goal_context_matches_typed_input(self) -> None:
        for rendered in (
            ' { "status" : "no_task" } ',
            '{"status":"available","task_id":"task-stale","goals":[]}',
            '{"status":"no_task","status":"no_task"}',
        ):
            manifest = fixture()
            for arm in ("baseline", "preflight"):
                actual = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                    "actual_input"
                ]
                actual["rendered_prompt_variables"]["goal_context"] = rendered
            result = self.execute(manifest)
            self.assertEqual(
                result.returncode, 0 if rendered.startswith(" ") else 1, result.stderr
            )
            if result.returncode:
                self.assertEqual(result.stdout, "")

    def test_rendered_history_matches_typed_input(self) -> None:
        history = [
            {
                "source": {"kind": "official_turn"},
                "attribution": {"kind": "unattributed"},
                "first_message": 0,
                "after_message": 1,
                "first_tool_observation": 0,
                "after_tool_observation": 0,
            }
        ]
        wrong_type = copy.deepcopy(history)
        wrong_type[0]["first_message"] = False
        for rendered in (
            json.dumps(history, indent=2, sort_keys=True),
            json.dumps(wrong_type),
            "[]",
            "null",
            "not-json",
        ):
            manifest = fixture()
            for arm in ("baseline", "preflight"):
                actual = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                    "actual_input"
                ]
                actual["historical_task_contexts"] = copy.deepcopy(history)
                actual["rendered_prompt_variables"]["historical_task_contexts"] = (
                    rendered
                )
            result = self.execute(manifest)
            self.assertEqual(
                result.returncode, 0 if rendered.startswith("[\n") else 1, result.stderr
            )
            if result.returncode:
                self.assertEqual(result.stdout, "")

    def test_http_refusal_matches_attempt_destination(self) -> None:
        for destination in ("https://fixture.invalid/jev", "https://other.invalid/jev"):
            manifest = fixture()
            observed = manifest["pairs"][0]["preflight"]["run"]["output"][
                "jev_preflight"
            ]
            observed["passed_over"] = [
                {
                    "destination_uri": "https://fixture.invalid/jev",
                    "model": "fixture-model",
                    "refusal": {
                        "kind": "http_response",
                        "status": 503,
                        "detail": "unavailable",
                        "destination_uri": destination,
                        "body": "unavailable",
                    },
                }
            ]
            result = self.execute(manifest)
            self.assertEqual(
                result.returncode,
                int(destination.startswith("https://other")),
                result.stderr,
            )
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
        for value in (
            "missing",
            "No-change output failed domain validation",
            False,
            {},
        ):
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
                self.assertIn(
                    "baseline must explicitly record null domain rejection",
                    result.stderr,
                )

    def test_evaluated_pair_requires_empty_frozen_context(self) -> None:
        for key, value in (
            ("continuity", '{"previous_working_state":null}'),
            ("continuity", "{}"),
            ("continuity", "not json"),
            ("working_context", "{}"),
            (
                "working_context",
                '{"sources":[],"previous":null,"unavailable":["fixture unavailable"]}',
            ),
            (
                "working_context",
                '{"sources":[{"reference":"s1","content":{"text":"fixture"}}],"previous":null,"unavailable":[]}',
            ),
            ("working_context", '{"sources":[],"previous":[],"unavailable":[]}'),
            (
                "working_context",
                '{"sources":[],"previous":null,"unavailable":[],"sources":[]}',
            ),
            ("working_context", "not json"),
        ):
            with self.subTest(key=key, value=value):
                manifest = fixture()
                for arm in ("baseline", "preflight"):
                    variables = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                        "actual_input"
                    ]["rendered_prompt_variables"]
                    variables[key] = value
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("preflight measurement refused:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_empty_context_uses_parsed_json_not_spelling(self) -> None:
        manifest = fixture()
        for arm in ("baseline", "preflight"):
            variables = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                "actual_input"
            ]["rendered_prompt_variables"]
            variables["continuity"] = " \n null \n "
            variables["working_context"] = (
                '{ "unavailable": [], "previous": null, "sources": [] }'
            )
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["recorded_generation_skips"], 1)

    def test_complete_input_is_required_even_when_both_arms_match(self) -> None:
        valid = fixture()["pairs"][0]["baseline"]["run"]["input"]["payload"]
        removals = (
            [(key,) for key in valid]
            + [("actual_input", key) for key in valid["actual_input"]]
            + [
                ("actual_input", "prompt", key)
                for key in valid["actual_input"]["prompt"]
            ]
            + [
                ("actual_input", "rendered_prompt_variables", key)
                for key in valid["actual_input"]["rendered_prompt_variables"]
                if key != "source"
            ]
        )
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
        goal = {
            "goal_id": "goal-fixture",
            "phase": "executing",
            "criterion": {
                "revision": "rev-1",
                "title": "Keep constraints",
                "metric": None,
                "target_value": None,
            },
        }
        context = {"status": "available", "task_id": "task-1", "goals": [goal]}
        history = [
            {
                "source": {
                    "kind": "atoms",
                    "trace_id": "fixture-trace",
                    "start_atom": 0,
                    "end_atom": 1,
                },
                "attribution": {
                    "kind": "observed",
                    "turn_ref": "fixture-trace#1",
                    "task_context": {
                        "kind": "task",
                        "task_id": "task-1",
                        "goals": {"kind": "observed", "goals": [goal]},
                    },
                },
                "first_message": 0,
                "after_message": 1,
                "first_tool_observation": 0,
                "after_tool_observation": 0,
            }
        ]
        manifest = fixture()
        for arm in ("baseline", "preflight"):
            manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"].update(
                goal_context=copy.deepcopy(context),
                historical_task_contexts=copy.deepcopy(history),
            )
            manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"][
                "rendered_prompt_variables"
            ]["goal_context"] = json.dumps(context)
            manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"][
                "rendered_prompt_variables"
            ]["historical_task_contexts"] = json.dumps(history)
        result = self.execute(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        for arm in ("baseline", "preflight"):
            del manifest["pairs"][0][arm]["run"]["input"]["payload"]["actual_input"][
                "historical_task_contexts"
            ][0]["attribution"]["task_context"]["goals"]["goals"][0]["criterion"][
                "revision"
            ]
        self.assertEqual(self.execute(manifest).returncode, 1)

    def test_baseline_requires_disabled_answerless_observation(self) -> None:
        for key, value in [
            ("elapsed_s", 0),
            ("elapsed_s", "missing"),
            ("failure", {}),
            *[
                (key, None)
                for key in observation()
                if key not in ("status", "elapsed_s")
            ],
        ]:
            with self.subTest(key=key, value=value):
                manifest = fixture()
                baseline = manifest["pairs"][0]["baseline"]["run"]["output"][
                    "jev_preflight"
                ]
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
            run.update(
                status="failed", code="output_invalid", detail="fixture schema failure"
            )
            result = self.execute(manifest)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(result.stdout)["pairs"][0][arm + "_failure"],
                {"code": "output_invalid", "detail": "fixture schema failure"},
            )
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
                self.assertIsNone(
                    json.loads(valid.stdout)["pairs"][0][arm + "_failure"]
                )
                for field in ("code", "detail"):
                    for value in (None, "stale failure"):
                        with self.subTest(
                            arm=arm, status=status, field=field, value=value
                        ):
                            invalid = copy.deepcopy(manifest)
                            invalid["pairs"][0][arm]["run"][field] = value
                            result = self.execute(invalid)
                            self.assertEqual(result.returncode, 1)
                            self.assertEqual(result.stdout, "")
                            self.assertIn(
                                "nonfailed run must not record code or detail",
                                result.stderr,
                            )

    def test_goal_context_variants_require_exact_fields(self) -> None:
        for context in (
            {"status": "no_task"},
            {"status": "available", "task_id": "task-1", "goals": []},
            {
                "status": "unavailable",
                "task_id": "task-1",
                "detail": "fixture unavailable",
            },
        ):
            manifest = fixture()
            for arm in ("baseline", "preflight"):
                actual = manifest["pairs"][0][arm]["run"]["input"]["payload"][
                    "actual_input"
                ]
                actual["goal_context"] = copy.deepcopy(context)
                actual["rendered_prompt_variables"]["goal_context"] = json.dumps(
                    context
                )
            valid = self.execute(manifest)
            self.assertEqual(valid.returncode, 0, valid.stderr)
            for field, value in (
                ("task_id", "task-1"),
                ("goals", []),
                ("detail", "stale error"),
            ):
                if field in context:
                    continue
                with self.subTest(context=context, field=field):
                    invalid = copy.deepcopy(manifest)
                    for arm in ("baseline", "preflight"):
                        actual = invalid["pairs"][0][arm]["run"]["input"]["payload"][
                            "actual_input"
                        ]
                        actual["goal_context"][field] = value
                    result = self.execute(invalid)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, "")
                    self.assertIn(
                        "goal context fields do not match status", result.stderr
                    )

    def test_duplicate_keys_are_refused_before_normalization(self) -> None:
        raw = json.dumps(fixture())
        for old, replacement in [
            ('"status": "succeeded"', '"status":"failed", "status":"succeeded"'),
            ('"message_count": 1', '"message_count":2, "message_count":1'),
        ]:
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
                    run["output"]["jev_preflight"]["probabilities"]["keep_current"] = (
                        10**999
                    )
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
        for status, fields in (
            ("invalid_answer", ("decision", "confidence", "probabilities", "failure")),
            ("judged", ("reason", "failure")),
            ("failed", ("reason",)),
            ("awaiting_answer", ("reason", "failure")),
        ):
            for field in fields:
                with self.subTest(status=status, field=field):
                    manifest = fixture()
                    run = manifest["pairs"][0]["preflight"]["run"]
                    awaiting = status == "awaiting_answer"
                    run.update(
                        status="cancelled" if awaiting else "succeeded",
                        selected_slot=None if awaiting else "fixture-cli",
                    )
                    run["output"].update(
                        jev_preflight=observation(status, "needs_generation"),
                        generation_path="not_entered" if awaiting else "full_lane",
                        full_llm_skipped=False,
                    )
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
        run.update(
            run_id="jev-2",
            status="failed",
            elapsed_s=6.0,
            code="provider_failed",
            detail="fixture generation failed",
        )
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
                run.update(
                    status=status,
                    selected_slot="fixture-cli" if path == "full_lane" else None,
                )
                if status == "failed":
                    run.update(
                        code="fixture_interrupted",
                        detail="fixture failed before selection",
                    )
                run["output"].update(
                    generation_path=path,
                    full_llm_skipped=False,
                    preflight_domain_rejection=rejection,
                    jev_preflight=observation()
                    if path == "full_lane"
                    else observation("awaiting_answer"),
                )
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    json.loads(result.stdout)["recorded_generation_skips"], 0
                )

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
                    run.update(
                        code="fixture_interrupted",
                        detail="fixture failed before selection",
                    )
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
                    jev_preflight={
                        "status": status,
                        "reason": reason,
                        "elapsed_s": None,
                    },
                    generation_path="full_lane",
                    full_llm_skipped=False,
                )
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn(
                    "preflight arm must enter preflight evaluation", result.stderr
                )

    def test_completed_assessment_cannot_leave_generation_not_entered(self) -> None:
        for status in ("failed", "cancelled"):
            for observed_status in (
                "judged",
                "skipped",
                "ineligible",
                "failed",
                "invalid_answer",
            ):
                with self.subTest(status=status, observation=observed_status):
                    manifest = fixture()
                    run = manifest["pairs"][0]["preflight"]["run"]
                    run.update(status=status, selected_slot=None)
                    if status == "failed":
                        run.update(
                            code="fixture_interrupted",
                            detail="fixture failed before selection",
                        )
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
            for field in (
                "destination",
                "model",
                "request_body_sha256",
                "decision",
                "probabilities",
                "confidence",
                "passed_over",
            ):
                with self.subTest(status=status, field=field):
                    manifest = fixture()
                    run = manifest["pairs"][0]["preflight"]["run"]
                    run.update(
                        status="failed",
                        selected_slot=None,
                        code="cancelled_evaluation",
                        detail="fixture interruption",
                    )
                    evidence = observation(status)
                    evidence[field] = observation()[field]
                    run["output"].update(
                        jev_preflight=evidence,
                        full_llm_skipped=False,
                        generation_path="not_entered"
                        if status == "awaiting_answer"
                        else "full_lane",
                    )
                    result = self.execute(manifest)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("answerless preflight", result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_completed_judgment_requires_typed_provenance(self) -> None:
        for field in (
            "destination",
            "model",
            "request_body_sha256",
            "passed_over",
            "elapsed_s",
            "probabilities",
            "confidence",
        ):
            with self.subTest(field=field):
                manifest = fixture()
                manifest["evidence_kind"] = "live"
                del manifest["pairs"][0]["preflight"]["run"]["output"]["jev_preflight"][
                    field
                ]
                result = self.execute(manifest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
        for field, value in (
            ("confidence", True),
            ("elapsed_s", -1),
            ("model", ""),
            ("request_body_sha256", "missing"),
            ("passed_over", {}),
            ("destination", {}),
            (
                "probabilities",
                {"keep_current": 0.2, "needs_generation": 0.7, "uncertain": 0.1},
            ),
            (
                "probabilities",
                {"keep_current": 0.8, "needs_generation": 0.2, "uncertain": 0.2},
            ),
        ):
            with self.subTest(field=field, value=value):
                manifest = fixture()
                manifest["pairs"][0]["preflight"]["run"]["output"]["jev_preflight"][
                    field
                ] = value
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
                run["output"].update(
                    jev_preflight=evidence,
                    generation_path="full_lane",
                    full_llm_skipped=False,
                )
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
                    run["input"]["payload"]["actual_input"][
                        "rendered_prompt_variables"
                    ]["keeper_id"] = "other-keeper"
                elif mode in (
                    "disabled_candidate",
                    "keep_current_fallback",
                    "successful_not_entered",
                ):
                    run["output"].update(
                        generation_path="full_lane", full_llm_skipped=False
                    )
                    if mode == "keep_current_fallback":
                        run["selected_slot"] = "fixture-cli"
                    if mode == "disabled_candidate":
                        run["selected_slot"] = "fixture-cli"
                        run["output"]["jev_preflight"] = {
                            "status": "skipped",
                            "reason": "librarian_preflight_disabled",
                            "elapsed_s": None,
                        }
                    elif mode == "successful_not_entered":
                        run["output"].update(
                            generation_path="not_entered",
                            jev_preflight=observation("awaiting_answer"),
                        )
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
                if mode == "different_actor":
                    self.assertIn(
                        "paired runs must use the same Keeper actor", result.stderr
                    )
                elif mode == "keep_current_fallback":
                    self.assertIn(
                        "keep-current fallback domain rejection", result.stderr
                    )
                elif mode == "disabled_candidate":
                    self.assertIn(
                        "preflight arm must enter preflight evaluation", result.stderr
                    )
                elif mode == "successful_not_entered":
                    self.assertIn("interrupted awaiting preflight", result.stderr)


if __name__ == "__main__":
    unittest.main()
