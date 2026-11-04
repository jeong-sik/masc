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
from datetime import date, datetime, timezone

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

    def test_calls_per_turn_counts_calls_of_each_turn(self) -> None:
        calls = [call(0, 1), call(2, 3), call(4, 5), call(0, 1, turn="k/t#2")]
        summary = lane.summarize_calls(calls, {"k": 10.0})
        per_turn = summary["calls_per_turn"]
        assert isinstance(per_turn, dict)
        self.assertEqual((per_turn["n"], per_turn["max"], per_turn["mean"]), (2, 3, 2.0))

    def test_gaps_are_summed_per_pair_of_consecutive_tools(self) -> None:
        calls = [
            call(0, 1, tool="Execute"),
            call(11, 12, tool="Write"),  # Execute -> Write, gap 10
            call(13, 14, tool="Write"),  # Write -> Write, gap 1
            call(24, 25, tool="Execute"),  # Write -> Execute, gap 10
            call(30, 31, tool="Write"),  # Execute -> Write, gap 5
        ]
        transitions = lane.summarize_calls(calls, {"k": 100.0})["tool_transitions"]
        assert isinstance(transitions, dict)
        same, cross = transitions["same_tool"], transitions["cross_tool"]
        self.assertEqual((same["pairs"], same["gap_s"]), (1, 1.0))
        self.assertEqual(same["top_by_gap"], [{"from": "Write", "to": "Write", "pairs": 1, "gap_s": 1.0, "mean_gap_s": 1.0}])
        self.assertEqual((cross["pairs"], cross["gap_s"]), (3, 25.0))
        self.assertEqual(
            cross["top_by_gap"][0], {"from": "Execute", "to": "Write", "pairs": 2, "gap_s": 15.0, "mean_gap_s": 7.5}
        )
        self.assertEqual((cross["top_by_gap"][1]["from"], cross["top_by_gap"][1]["to"]), ("Write", "Execute"))

    def test_only_the_largest_pairs_are_listed(self) -> None:
        extra = 2
        count = lane.TOP_TOOL_TRANSITIONS + extra
        calls = [call(0, 1, tool="T0")]
        for index in range(1, count + 1):
            # The pair (T{index-1}, T{index}) gets a gap of `index` seconds.
            start = calls[-1].end + index
            calls.append(call(start, start + 1, tool=f"T{index}"))
        cross = lane.summarize_calls(calls, {"k": 1000.0})["tool_transitions"]["cross_tool"]
        self.assertEqual(cross["pairs"], count)
        gaps = [item["gap_s"] for item in cross["top_by_gap"]]
        self.assertEqual(gaps, [float(count - offset) for offset in range(lane.TOP_TOOL_TRANSITIONS)])

    def test_overlapping_calls_add_no_gap_to_a_pair(self) -> None:
        calls = [call(0, 10, tool="Read"), call(5, 6, tool="Read")]
        same = lane.summarize_calls(calls, {"k": 100.0})["tool_transitions"]["same_tool"]
        self.assertEqual((same["pairs"], same["gap_s"]), (1, 0.0))

    def test_calls_are_counted_by_batch_size_and_execution_mode(self) -> None:
        calls = [
            lane.Call("k", "k/t#1", "Read", 0.0, 1.0, False, False, 1, "concurrent"),
            lane.Call("k", "k/t#1", "Execute", 2.0, 12.0, False, False, 1, "serial"),
            lane.Call("k", "k/t#1", "Execute", 13.0, 15.0, False, False, 2, "serial"),
        ]
        summary = lane.summarize_calls(calls, {"k": 20.0})
        self.assertEqual(summary["calls_by_batch_size"], {"1": 2, "2": 1})
        self.assertEqual(
            summary["execution_modes"],
            {"concurrent": {"calls": 1, "time_s": 1.0}, "serial": {"calls": 2, "time_s": 12.0}},
        )

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


class CancelledTurnTest(unittest.TestCase):
    def cancelled(self, keeper: str, completed_at: float, kind: str = "Turn_cancelled") -> lane.Operation:
        return lane.Operation(keeper, "delegate", "failed", 0.0, 1.0, completed_at, kind)

    def test_only_a_cancel_inside_an_execute_of_the_same_keeper_counts(self) -> None:
        operations = [
            self.cancelled("k", 40.0),  # inside the long Execute of k, 40 s in
            self.cancelled("k", 500.0),  # no Execute at that time
            self.cancelled("other", 40.0),  # another Keeper's Execute is not k's
            self.cancelled("k", 40.0, kind="Turn_exception"),  # not a cancel
        ]
        execute_calls = {"k": [(0.0, 100.0)], "other": [(1000.0, 1100.0)]}
        summary = lane.summarize_cancelled_turns(operations, execute_calls)
        self.assertEqual(summary["turn_cancelled_operations"], 3)
        self.assertEqual(summary["cancelled_during_execute"], 1)
        self.assertEqual(summary["cancelled_during_long_execute"], 1)
        self.assertEqual((summary["execute_time_lost_s"], summary["long_execute_time_lost_s"]), (40.0, 40.0))

    def test_short_execute_is_counted_but_not_as_long(self) -> None:
        summary = lane.summarize_cancelled_turns([self.cancelled("k", 5.0)], {"k": [(0.0, 10.0)]})
        self.assertEqual((summary["cancelled_during_execute"], summary["cancelled_during_long_execute"]), (1, 0))
        self.assertEqual((summary["execute_time_lost_s"], summary["long_execute_time_lost_s"]), (5.0, 0.0))

    def test_one_cancel_counts_once_when_two_executes_overlap(self) -> None:
        summary = lane.summarize_cancelled_turns([self.cancelled("k", 30.0)], {"k": [(0.0, 100.0), (10.0, 90.0)]})
        self.assertEqual(summary["cancelled_during_execute"], 1)
        self.assertEqual(summary["execute_time_lost_s"], 30.0)

    def test_the_slack_after_the_end_matches_and_beyond_it_does_not(self) -> None:
        call = {"k": [(0.0, 10.0)]}
        inside = lane.summarize_cancelled_turns([self.cancelled("k", 10.0 + lane.CANCEL_MATCH_SLACK_SEC)], call)
        outside = lane.summarize_cancelled_turns([self.cancelled("k", 10.0 + lane.CANCEL_MATCH_SLACK_SEC + 0.1)], call)
        self.assertEqual((inside["cancelled_during_execute"], outside["cancelled_during_execute"]), (1, 0))
        self.assertEqual(inside["execute_time_lost_s"], 10.0)


class StoreReadingTest(unittest.TestCase):
    def test_ledger_rows_become_calls_with_rereads_and_polling(self) -> None:
        rows = [
            {"record_kind": "tool_call", "ts": 1000.0, "duration_ms": 2000, "keeper": "k", "tool": "keeper_artifact_read",
             "trace_id": "t", "keeper_turn_id": 1, "input_fingerprint": "i", "output_fingerprint": "o",
             "batch_size": 2, "execution_mode": "concurrent"},
            {"record_kind": "tool_call", "ts": 1010.0, "duration_ms": 1000, "keeper": "k", "tool": "keeper_artifact_read",
             "trace_id": "t", "keeper_turn_id": 1, "input_fingerprint": "i", "output_fingerprint": "o"},
            {"record_kind": "tool_call", "ts": 1100.0, "duration_ms": 90000, "keeper": "k", "tool": "Execute",
             "trace_id": "t", "keeper_turn_id": 1, "input": {"command": "for i in 1 2; do sleep 5; done"},
             "batch_size": 1, "execution_mode": "serial"},
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
        self.assertEqual([(c.batch_size, c.mode) for c in calls], [(2, "concurrent"), (0, "unknown"), (1, "serial")])

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


DAY_START = datetime(2026, 11, 1, tzinfo=timezone.utc).timestamp()


def admission_event(ts: float, waited_ms: float | None, *, model: str = "glm-5.3", admission_class: str = "standard") -> str:
    payload: dict[str, object] = {"provider_id": "glm-coding", "model": model, "admission_class": admission_class}
    if waited_ms is not None:
        payload["waited_ms"] = waited_ms
    return json.dumps({"type": "agent_core:masc:provider_admission:waited", "ts_unix": ts, "payload": payload})


class AdmissionTest(unittest.TestCase):
    def test_waits_are_read_inside_the_window_and_summed_by_class_and_hour(self) -> None:
        lines = [
            admission_event(DAY_START + 100, 10_000),
            admission_event(DAY_START + 4_000, 30_000, admission_class="priority"),
            admission_event(DAY_START + 5_000, 99_000),  # after `until`
            admission_event(DAY_START + 200, None),  # no clock could measure it
            json.dumps({"type": "agent_core:tool_called", "ts_unix": DAY_START + 300}),
            "provider_admission:waited {not json",
        ]
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            events_dir = base / ".masc" / "agent-core-events" / "2026-11"
            events_dir.mkdir(parents=True)
            (events_dir / "01.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
            waits = lane.read_admission_waits(base, since=DAY_START, until=DAY_START + 4_500)
        self.assertEqual([w.waited_s for w in waits], [10.0, 30.0])
        summary = lane.summarize_admission(waits)
        self.assertEqual(summary["events"], 2)
        self.assertEqual(summary["by_class_s"], {"priority": 30.0, "standard": 10.0})
        self.assertEqual(summary["clock_hours_with_events"], 2)

    def test_missing_events_directory_gives_no_waits(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            self.assertEqual(lane.read_admission_waits(pathlib.Path(raw), since=DAY_START, until=DAY_START + 10), [])


if __name__ == "__main__":
    unittest.main()
