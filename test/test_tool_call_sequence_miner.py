#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Sequence
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "tool-call-sequence-miner.py"
SPEC = importlib.util.spec_from_file_location("tool_call_sequence_miner", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MINER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MINER
SPEC.loader.exec_module(MINER)


def fixture_call(
    tool: str,
    ts: float,
    *,
    keeper: str = "keeper-a",
    trace_id: str | None = "trace-a",
    turn_id: int | None = 7,
    suffix: str = "",
    success: bool = True,
    disposition: str | None = None,
    turn: int = 1,
) -> dict[str, Any]:
    runtime_contract: dict[str, Any] = {"keeper_name": keeper}
    if trace_id is not None:
        runtime_contract["trace_id"] = trace_id
    if turn_id is not None:
        runtime_contract["keeper_turn_id"] = turn_id
    return {
        "ts": ts,
        "record_kind": "tool_call",
        "keeper": keeper,
        "tool": tool,
        "input": {},
        "output": "{}",
        "success": success,
        "disposition": disposition or ("completed" if success else "failed"),
        "runtime_contract": runtime_contract,
        "route_evidence": {
            "descriptor_id": f"descriptor.{tool}",
            "composable_output": {"kind": "json", "schema": {"type": "object"}},
        },
        "execution_id": f"exec-{tool}{suffix}",
        "tool_use_id": f"use-{tool}{suffix}",
        "planned_index": 0,
        "turn": turn,
        "batch_index": 0,
        "batch_size": 1,
        "execution_mode": "serial",
        "runtime_profile": "fixture-runtime",
        "result_bytes": 2,
    }


def write_rows(path: Path, rows: Sequence[dict[str, Any] | str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(row if isinstance(row, str) else json.dumps(row))
            handle.write("\n")


class ToolCallSequenceMinerTest(unittest.TestCase):
    def test_schedule_is_named_and_outcome_rollup_is_fail_closed(self) -> None:
        gaps: set[str] = set()
        schedule = MINER._execution_schedule(fixture_call("scheduled", 1.0), gaps)

        self.assertEqual(schedule.turn, 1)
        self.assertEqual(schedule.planned_index, 0)
        self.assertEqual(schedule.batch_index, 0)
        self.assertEqual(schedule.batch_size, 1)
        self.assertEqual(schedule.execution_mode, "serial")
        self.assertFalse(schedule.directed_order_unproven)
        self.assertEqual(gaps, set())
        self.assertIs(
            MINER._rollup_outcomes(
                {MINER.CallOutcome.COMPLETED, MINER.CallOutcome.DEFERRED}
            ),
            MINER.CallOutcome.DEFERRED,
        )
        self.assertIs(
            MINER._rollup_outcomes(
                {MINER.CallOutcome.COMPLETED, MINER.CallOutcome.CONFLICT}
            ),
            MINER.CallOutcome.CONFLICT,
        )

    def test_filters_groups_and_orders_by_timestamp_then_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = fixture_call("first", 30.0)
            second = fixture_call("second", 10.0)
            tie_a = fixture_call("tie-a", 20.0)
            tie_b = fixture_call("tie-b", 20.0)
            composition_node = fixture_call("hidden-node", 15.0)
            composition_node["composition_run_id"] = "run-1"
            aggregate = {
                "record_kind": "composition_run",
                "ts": 16.0,
            }
            pre_schema = {"tool": "legacy", "ts": 5.0}
            write_rows(
                root / "2026-09" / "01.jsonl",
                [pre_schema, first, second, tie_a],
            )
            write_rows(
                root / "2026-09" / "02.jsonl",
                [tie_b, composition_node, aggregate],
            )

            report = MINER.analyze(
                root,
                evidence_sequences=frozenset({("tie-a", "tie-b")}),
                evidence_limit=10,
            )

            self.assertEqual(report["summary"]["selected_tool_calls"], 4)
            self.assertEqual(report["summary"]["excluded_composition_nodes"], 1)
            self.assertEqual(report["summary"]["excluded_pre_schema_rows"], 1)
            self.assertEqual(
                report["summary"]["coverage_gap_counts"][
                    "pre_schema_missing_record_kind"
                ],
                1,
            )
            self.assertEqual(report["summary"]["ignored_non_tool_records"], 1)
            pairs = {tuple(item["tools"]): item for item in report["pairs"]}
            self.assertEqual(
                set(pairs),
                {("second", "tie-a"), ("tie-a", "tie-b"), ("tie-b", "first")},
            )
            tied = pairs[("tie-a", "tie-b")]["occurrences"][0]["calls"]
            self.assertEqual(
                [call["source"]["file"] for call in tied],
                ["2026-09/01.jsonl", "2026-09/02.jsonl"],
            )
            self.assertEqual(tied[0]["execution_id"], "exec-tie-a")
            self.assertEqual(tied[1]["tool_use_id"], "use-tie-b")
            self.assertEqual(report["summary"]["triplet_occurrences"], 2)

    def test_aggregates_exact_sequence_without_a_frequency_threshold(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rows = [fixture_call("solo-a", 1.0), fixture_call("solo-b", 2.0)]
            rows += [
                fixture_call(
                    "solo-a",
                    1.0,
                    keeper="keeper-b",
                    trace_id="trace-b",
                    turn_id=8,
                    suffix="-b",
                ),
                fixture_call(
                    "solo-b",
                    2.0,
                    keeper="keeper-b",
                    trace_id="trace-b",
                    turn_id=8,
                    suffix="-b",
                    success=False,
                ),
            ]
            write_rows(root / "calls.jsonl", rows)

            report = MINER.analyze(root)
            pairs = {tuple(item["tools"]): item for item in report["pairs"]}

            self.assertIn(("solo-a", "solo-b"), pairs)
            sequence = pairs[("solo-a", "solo-b")]
            self.assertEqual(sequence["occurrence_count"], 2)
            self.assertEqual(sequence["keeper_count"], 2)
            self.assertEqual(sequence["failed_occurrence_count"], 1)
            self.assertEqual(sequence["completed_occurrence_count"], 1)
            self.assertEqual(sequence["keepers"], ["keeper-a", "keeper-b"])
            self.assertNotIn("occurrences", sequence)
            self.assertFalse(report["evidence"]["included"])
            self.assertNotIn("coverage_gaps", report)
            self.assertNotIn("ungrouped_calls", report)

    def test_preserves_coverage_gaps_and_does_not_group_missing_turn_identity(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            truncated = fixture_call("truncated", 1.0)
            truncated["input"] = {"nested": ["value...(truncated)"]}
            truncated["output"] = "prefix...(truncated)"
            truncated["truncated_to"] = 4000
            truncated["result_bytes"] = 5000
            truncated["route_evidence"]["composable_output"] = {"kind": "opaque"}

            blob = fixture_call("blob", 2.0)
            blob["output"] = {"_blob": {"sha256": "a" * 64, "bytes": 12}}
            del blob["route_evidence"]
            del blob["execution_id"]

            ungrouped = fixture_call("ungrouped", 3.0, trace_id=None)
            write_rows(root / "calls.jsonl", [truncated, blob, ungrouped])

            report = MINER.analyze(
                root,
                evidence_sequences=frozenset({("truncated", "blob")}),
                evidence_limit=10,
            )
            gaps = report["summary"]["coverage_gap_counts"]

            self.assertEqual(gaps["truncated_input"], 1)
            self.assertEqual(gaps["truncated_output"], 1)
            self.assertEqual(gaps["opaque_output"], 1)
            self.assertEqual(gaps["blob_only_output"], 1)
            self.assertEqual(gaps["missing_descriptor"], 1)
            self.assertEqual(gaps["missing_execution_id"], 1)
            self.assertEqual(gaps["missing_runtime_identity"], 1)
            self.assertEqual(report["summary"]["ungrouped_tool_calls"], 1)
            self.assertEqual(report["summary"]["pair_occurrences"], 1)
            self.assertTrue(report["evidence"]["included"])
            pair = report["pairs"][0]
            self.assertEqual(pair["tools"], ["truncated", "blob"])
            self.assertEqual(
                pair["occurrences"][0]["calls"][0]["execution_id"],
                "exec-truncated",
            )

    def test_cli_is_deterministic_and_base_path_is_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            tool_calls = base / ".masc" / "tool_calls"
            write_rows(
                tool_calls / "calls.jsonl",
                [fixture_call("one", 1.0), fixture_call("two", 2.0)],
            )
            command = [sys.executable, str(SCRIPT), "--base-path", str(base)]
            first = subprocess.run(command, text=True, capture_output=True, check=False)
            second = subprocess.run(
                command, text=True, capture_output=True, check=False
            )

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(first.stdout, second.stdout)
            self.assertEqual(first.stderr, "")
            self.assertEqual(
                json.loads(first.stdout)["source"]["files"], ["calls.jsonl"]
            )
            compact = json.loads(first.stdout)
            self.assertNotIn("occurrences", compact["pairs"][0])
            self.assertNotIn("coverage_gaps", compact)

            expanded = subprocess.run(
                command + ["--evidence-sequence", "one,two", "--evidence-limit", "10"],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(expanded.returncode, 0, expanded.stderr)
            evidence = json.loads(expanded.stdout)
            self.assertIn("occurrences", evidence["pairs"][0])
            self.assertTrue(evidence["evidence"]["included"])

            help_result = subprocess.run(
                [sys.executable, str(SCRIPT), "--help"],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertIn("--evidence-sequence", help_result.stdout)
            self.assertIn("--evidence-limit", help_result.stdout)

    def test_streams_each_jsonl_file_instead_of_reading_it_whole(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_rows(
                root / "calls.jsonl",
                [fixture_call("one", 1.0), fixture_call("two", 2.0)],
            )

            with mock.patch.object(
                Path,
                "read_text",
                side_effect=AssertionError("whole-file read is forbidden"),
            ):
                report = MINER.analyze(root)

            self.assertEqual(report["summary"]["rows_read"], 2)
            self.assertEqual(report["summary"]["pair_occurrences"], 1)

    def test_reports_deferred_separately_from_completed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_rows(
                root / "calls.jsonl",
                [
                    fixture_call("start", 1.0),
                    fixture_call("wait", 2.0, disposition="deferred"),
                ],
            )

            report = MINER.analyze(root)
            pair = report["pairs"][0]

            self.assertEqual(pair["completed_occurrence_count"], 0)
            self.assertEqual(pair["deferred_occurrence_count"], 1)
            self.assertEqual(pair["failed_occurrence_count"], 0)
            self.assertEqual(report["summary"]["call_outcome_counts"]["deferred"], 1)

    def test_conflicting_disposition_is_counted_and_breaks_adjacency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            conflict = fixture_call(
                "conflict", 2.0, success=False, disposition="completed"
            )
            write_rows(
                root / "calls.jsonl",
                [fixture_call("before", 1.0), conflict, fixture_call("after", 3.0)],
            )

            report = MINER.analyze(root)

            self.assertEqual(report["summary"]["excluded_conflicting_calls"], 1)
            self.assertEqual(
                report["summary"]["call_outcome_counts"][
                    "disposition_success_conflict"
                ],
                1,
            )
            self.assertEqual(report["summary"]["pair_occurrences"], 0)

    def test_disposition_is_authoritative_when_success_is_absent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            completed = fixture_call("completed", 1.0)
            failed = fixture_call("failed", 2.0, success=False)
            del completed["success"]
            del failed["success"]
            write_rows(root / "calls.jsonl", [completed, failed])

            report = MINER.analyze(
                root,
                evidence_sequences=frozenset({("completed", "failed")}),
                evidence_limit=1,
            )
            pair = report["pairs"][0]

            self.assertEqual(pair["completed_occurrence_count"], 0)
            self.assertEqual(pair["failed_occurrence_count"], 1)
            calls = pair["occurrences"][0]["calls"]
            self.assertIsNone(calls[0]["success"])
            self.assertIsNone(calls[1]["success"])

    def test_multi_call_concurrent_batch_is_not_a_directed_sequence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = fixture_call("planned-first", 2.0, turn=4)
            first.update(
                execution_mode="concurrent",
                batch_size=2,
                batch_index=0,
                planned_index=0,
            )
            second = fixture_call("planned-second", 1.0, turn=4)
            second.update(
                execution_mode="concurrent",
                batch_size=2,
                batch_index=0,
                planned_index=1,
            )
            later = fixture_call("later", 3.0, turn=5)
            write_rows(root / "calls.jsonl", [first, second, later])

            report = MINER.analyze(root)

            self.assertEqual(report["summary"]["excluded_unordered_calls"], 2)
            self.assertEqual(report["summary"]["concurrent_groups"], 1)
            self.assertEqual(report["summary"]["pair_occurrences"], 0)

    def test_missing_and_partial_schedules_break_directed_adjacency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            missing = fixture_call("missing", 1.0)
            partial = fixture_call("partial", 2.0)
            for name in (
                "turn",
                "planned_index",
                "batch_index",
                "batch_size",
                "execution_mode",
            ):
                del missing[name]
                if name != "turn":
                    del partial[name]
            write_rows(
                root / "calls.jsonl",
                [missing, partial, fixture_call("serial", 3.0)],
            )

            report = MINER.analyze(root)
            gaps = report["summary"]["coverage_gap_counts"]

            self.assertEqual(gaps["missing_execution_schedule"], 1)
            self.assertEqual(gaps["partial_execution_schedule"], 1)
            self.assertEqual(report["summary"]["excluded_unordered_calls"], 2)
            self.assertEqual(report["summary"]["pair_occurrences"], 0)

    def test_deferred_false_is_a_disposition_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_rows(
                root / "calls.jsonl",
                [
                    fixture_call(
                        "deferred-conflict",
                        1.0,
                        success=False,
                        disposition="deferred",
                    )
                ],
            )

            report = MINER.analyze(root)

            self.assertEqual(report["summary"]["excluded_conflicting_calls"], 1)
            self.assertEqual(
                report["summary"]["call_outcome_counts"][
                    "disposition_success_conflict"
                ],
                1,
            )

    def test_targeted_evidence_uses_one_explicit_global_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_rows(
                root / "calls.jsonl",
                [
                    fixture_call("a", 1.0),
                    fixture_call("b", 2.0),
                    fixture_call("a", 3.0),
                    fixture_call("b", 4.0),
                ],
            )

            report = MINER.analyze(
                root,
                evidence_sequences=frozenset({("a", "b")}),
                evidence_limit=1,
            )
            pair = next(item for item in report["pairs"] if item["tools"] == ["a", "b"])

            self.assertEqual(pair["occurrence_count"], 2)
            self.assertEqual(pair["evidence_included_count"], 1)
            self.assertEqual(pair["evidence_omitted_count"], 1)
            self.assertEqual(report["evidence"]["included_occurrences"], 1)
            self.assertEqual(report["evidence"]["omitted_occurrences"], 1)

    def test_malformed_row_fails_closed_with_source_diagnostic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_rows(root / "bad.jsonl", ["{not-json"])

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--tool-calls-dir", str(root)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("bad.jsonl:1: invalid JSON", result.stderr)

    def test_wrong_typed_turn_identity_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            row = fixture_call("bad-turn", 1.0)
            row["runtime_contract"]["keeper_turn_id"] = "7"
            write_rows(root / "bad.jsonl", [row])

            with self.assertRaisesRegex(
                MINER.RowError, "runtime_contract.keeper_turn_id"
            ):
                MINER.analyze(root)

    def test_unknown_non_null_record_kind_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_rows(root / "bad.jsonl", [{"record_kind": "future_kind"}])

            with self.assertRaisesRegex(MINER.RowError, "unknown record_kind"):
                MINER.analyze(root)

    def test_null_record_kind_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_rows(root / "bad.jsonl", [{"record_kind": None}])

            with self.assertRaisesRegex(MINER.RowError, "record_kind must be a string"):
                MINER.analyze(root)

    def test_missing_record_kind_after_schema_boundary_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_rows(
                root / "bad.jsonl",
                [fixture_call("current", 1.0), {"tool": "late-legacy"}],
            )

            with self.assertRaisesRegex(MINER.RowError, "after the schema boundary"):
                MINER.analyze(root)


if __name__ == "__main__":
    unittest.main()
