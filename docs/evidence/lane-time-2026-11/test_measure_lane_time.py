"""Checks the arithmetic of measure_lane_time.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/lane-time-2026-11
"""

from __future__ import annotations

import json
import pathlib
import sqlite3
import sys
import tempfile
import unittest
from datetime import date

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_lane_time as lane  # noqa: E402


def call(start: float, end: float, *, tool: str = "Execute", turn: str = "k/t#1", reread: bool = False, polling: bool = False) -> lane.Call:
    return lane.Call("k", turn, tool, start, end, reread, polling)


def operation(created: float, started: float | None, *, origin: str = "delegate", state: str = "succeeded") -> lane.Operation:
    return lane.Operation("k", origin, state, created, started, None if started is None else started + 10.0, None)


class IntervalTest(unittest.TestCase):
    def test_union_counts_overlapping_time_once(self) -> None:
        self.assertEqual(lane.union_seconds([(0, 10), (5, 15), (20, 25)]), 20.0)

    def test_overlap_is_clipped_to_the_window(self) -> None:
        self.assertEqual(lane.overlap_seconds(8, 22, [(0, 10), (5, 15), (20, 25)]), 9.0)

    def test_overlap_of_disjoint_intervals_is_zero(self) -> None:
        self.assertEqual(lane.overlap_seconds(30, 40, [(0, 10)]), 0.0)


class CallSummaryTest(unittest.TestCase):
    def test_gap_is_start_minus_previous_end_and_overlap_counts_zero(self) -> None:
        calls = [call(0, 2), call(5, 6), call(5.5, 7)]
        summary = lane.summarize_calls(calls, {"k": 100.0})
        between = summary["between_calls"]
        assert isinstance(between, dict)
        self.assertEqual(between["n"], 2)
        self.assertEqual(between["sum_s"], 3.0)
        self.assertEqual(between["overlapping_pairs"], 1)

    def test_reread_turn_time_is_gap_plus_tool_time(self) -> None:
        summary = lane.summarize_calls([call(0, 1), call(4, 6, reread=True)], {"k": 10.0})
        self.assertEqual(summary["rereads_after_first_call"], {"calls": 1, "turn_time_s": 5.0})

    def test_other_turn_time_is_what_tools_and_gaps_leave(self) -> None:
        summary = lane.summarize_calls([call(0, 2), call(5, 6)], {"k": 20.0})
        self.assertEqual(summary["other_turn_time_s"], 20.0 - 3.0 - 3.0)

    def test_polling_is_counted_only_for_long_execute(self) -> None:
        calls = [call(0, 100, polling=True), call(200, 210, polling=True), call(300, 400, tool="Read", polling=False)]
        summary = lane.summarize_calls(calls, {"k": 500.0})
        long_execute = summary["long_execute"]
        assert isinstance(long_execute, dict)
        self.assertEqual((long_execute["calls"], long_execute["polling_calls"]), (1, 1))
        self.assertEqual(long_execute["polling_time_s"], 100.0)


class OperationSummaryTest(unittest.TestCase):
    def test_wait_overlap_and_creation_inside_a_long_execute(self) -> None:
        # The third operation is created the moment the Execute ends, so it is not blocked by it.
        operations = [operation(100, 200), operation(160, 400), operation(400, 450), operation(500, 500)]
        summary = lane.summarize_operations(operations, {"k": [(150.0, 400.0)]}, {"k": [(0.0, 120.0)]})
        self.assertEqual(summary["total_wait_s"], 100.0 + 240.0 + 50.0)
        self.assertEqual(summary["wait_overlapping_long_execute_s"], 50.0 + 240.0)
        self.assertEqual(summary["wait_overlapping_a_run_of_the_same_keeper_s"], 20.0)
        blocked = summary["created_during_long_execute"]
        assert isinstance(blocked, dict)
        self.assertEqual((blocked["n"], blocked["sum_s"]), (1, 240.0))

    def test_operation_that_never_started_has_no_wait(self) -> None:
        summary = lane.summarize_operations([operation(100, None)], {}, {})
        self.assertEqual((summary["operations"], summary["started"], summary["total_wait_s"]), (1, 0, 0.0))


class StoreReadingTest(unittest.TestCase):
    def test_ledger_rows_become_calls_with_rereads_and_polling(self) -> None:
        rows = [
            {"record_kind": "tool_call", "ts": 1000.0, "duration_ms": 2000, "keeper": "k", "tool": "keeper_artifact_read",
             "trace_id": "t", "keeper_turn_id": 1, "input_fingerprint": "i", "output_fingerprint": "o"},
            {"record_kind": "tool_call", "ts": 1010.0, "duration_ms": 1000, "keeper": "k", "tool": "keeper_artifact_read",
             "trace_id": "t", "keeper_turn_id": 1, "input_fingerprint": "i", "output_fingerprint": "o"},
            {"record_kind": "tool_call", "ts": 1100.0, "duration_ms": 90000, "keeper": "k", "tool": "Execute",
             "trace_id": "t", "keeper_turn_id": 1, "input": {"command": "for i in 1 2; do sleep 5; done"}},
            {"record_kind": "other", "ts": 1.0},
            {"record_kind": "tool_call", "ts": 9999999.0, "duration_ms": 1, "keeper": "k", "tool": "Execute"},
        ]
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            day_dir = base / ".masc" / "tool_calls" / "2026-11"
            day_dir.mkdir(parents=True)
            (day_dir / "01.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            calls = lane.read_calls(base, date(2026, 11, 1), date(2026, 11, 1), until=5000.0)
        self.assertEqual([c.reread for c in calls], [False, True, False])
        self.assertEqual([c.polling for c in calls], [False, False, True])
        self.assertEqual(calls[0].start, 998.0)

    def test_operations_are_classified_by_sender_keeper_and_read_only(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            keeper_dir = base / ".masc" / "keepers" / "k"
            keeper_dir.mkdir(parents=True)
            connection = sqlite3.connect(keeper_dir / "chat-operations.sqlite3")
            connection.execute(
                "create table operations (state text, created_at real, started_at real, completed_at real,"
                " failure_kind text, source_json text)"
            )
            connection.execute("insert into operations values ('failed', 10, 12, 30, 'Turn_cancelled', ?)",
                               (json.dumps({"sender_keeper": "other", "channel": "agent"}),))
            connection.execute("insert into operations values ('succeeded', 11, 11, 20, null, ?)",
                               (json.dumps({"sender_keeper": None, "channel": "dashboard"}),))
            connection.execute("insert into operations values ('succeeded', 999, 999, 1000, null, '{}')")
            connection.commit()
            connection.close()
            operations = lane.read_operations(base, since=0.0, until=100.0)
        self.assertEqual(sorted(op.origin for op in operations), ["channel:dashboard", "delegate"])
        self.assertEqual({op.state for op in operations}, {"failed", "succeeded"})


if __name__ == "__main__":
    unittest.main()
