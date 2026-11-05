"""Checks the arithmetic of measure_lane_time.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/lane-time-2026-11
"""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import sqlite3
import sys
import tempfile
import unittest
from datetime import date, datetime, timezone
from typing import cast
from unittest import mock

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


def block(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    return cast("dict[str, object]", value)


def clocks_of(*spans: tuple[float, float], keeper: str = "k") -> dict[str, lane.TurnClock]:
    return {keeper: lane.TurnClock.of(spans)}


class TurnClockTest(unittest.TestCase):
    SPANS = ((10.0, 20.0), (30.0, 40.0), (50.0, 60.0))

    def test_overlapping_and_touching_intervals_are_merged(self) -> None:
        clock = lane.TurnClock.of([(10, 20), (15, 30), (30, 40), (50, 60)])
        self.assertEqual(clock.spans, ((10, 40), (50, 60)))
        self.assertEqual(clock.starts, (10, 50))
        self.assertEqual(clock.seconds, 40)

    def test_an_interval_inside_another_is_absorbed(self) -> None:
        self.assertEqual(lane.TurnClock.of([(10, 50), (20, 30)]).spans, ((10, 50),))

    def test_intervals_are_sorted_and_may_come_in_any_order(self) -> None:
        clock = lane.TurnClock.of([(50, 60), (10, 20), (30, 40)])
        self.assertEqual(clock.spans, self.SPANS)
        self.assertEqual(clock.starts, (10, 30, 50))
        self.assertEqual(clock.seconds, 30)

    def test_no_intervals_hold_no_time(self) -> None:
        clock = lane.TurnClock.of([])
        self.assertEqual((clock.spans, clock.starts, clock.seconds, clock.overlap(0, 100)), ((), (), 0, 0))

    def test_the_overlap_of_a_call_with_the_spans(self) -> None:
        clock = lane.TurnClock.of(self.SPANS)
        cases = [
            (12, 18, 6),  # inside one span
            (0, 5, 0),  # before all spans
            (65, 70, 0),  # after all spans
            (5, 15, 5),  # starts before a span
            (15, 25, 5),  # ends after a span
            (15, 35, 10),  # reaches over the gap between two spans
            (0, 100, 30),  # holds every span
            (20, 30, 0),  # exactly the gap
            (40, 50, 0),  # exactly the next gap
            (35, 55, 10),  # the second and the third span
            (10, 10, 0),  # no length, on the edge of a span
            (12, 12, 0),  # no length, inside a span
            (10, 20, 10),  # exactly one span
        ]
        for start, end, expected in cases:
            with self.subTest(start=start, end=end):
                self.assertEqual(clock.overlap(start, end), expected)

    def test_a_call_that_ends_where_a_span_starts_has_no_overlap_with_it(self) -> None:
        clock = lane.TurnClock.of(self.SPANS)
        self.assertEqual(clock.overlap(25, 30), 0)
        self.assertEqual(clock.overlap(60, 70), 0)

    def test_the_seconds_of_a_clock_equal_the_union_of_its_intervals(self) -> None:
        intervals: list[lane.Interval] = [(0, 10), (5, 15), (20, 25), (25, 30)]
        self.assertEqual(lane.TurnClock.of(intervals).seconds, lane.union_seconds(intervals))


class InsideTurnsTest(unittest.TestCase):
    def test_a_call_counts_only_the_seconds_inside_the_turn_time(self) -> None:
        summary = lane.summarize_inside_turns([call(0, 10), call(20, 30)], clocks_of((5, 25)))
        self.assertEqual(summary["tool_time_s"], 10.0)
        self.assertEqual(summary["execute_time_s"], 10.0)

    def test_only_execute_counts_as_execute_time(self) -> None:
        summary = lane.summarize_inside_turns([call(0, 10), call(10, 30, tool="Read")], clocks_of((0, 100)))
        self.assertEqual((summary["tool_time_s"], summary["execute_time_s"]), (30.0, 10.0))

    def test_a_gap_counts_only_the_seconds_inside_the_turn_time(self) -> None:
        # The gap is 2..10 and the turn time 1..6: 4 of its 8 seconds are inside.
        summary = lane.summarize_inside_turns([call(0, 2), call(10, 12)], clocks_of((1, 6)))
        self.assertEqual(summary["between_calls_s"], 4.0)

    def test_a_gap_that_reaches_over_two_spans_counts_both_parts(self) -> None:
        summary = lane.summarize_inside_turns([call(0, 2), call(30, 31)], clocks_of((1, 5), (20, 40)))
        self.assertEqual(summary["between_calls_s"], 3.0 + 10.0)

    def test_a_keeper_without_a_clock_has_nothing_inside(self) -> None:
        summary = lane.summarize_inside_turns([call(0, 10), call(20, 30)], {})
        self.assertEqual((summary["tool_time_s"], summary["between_calls_s"], summary["other_turn_time_s"]), (0.0, 0.0, 0.0))
        self.assertEqual(set(block(summary["percent_of_turn_time"]).values()), {None})

    def test_each_keeper_is_measured_against_its_own_clock(self) -> None:
        calls = [lane.Call("a", "a/t#1", "Execute", 0, 10, False, False), lane.Call("b", "b/t#1", "Execute", 0, 10, False, False)]
        clocks = {"a": lane.TurnClock.of([(0, 4)]), "b": lane.TurnClock.of([(6, 20)])}
        self.assertEqual(lane.summarize_inside_turns(calls, clocks)["tool_time_s"], 4.0 + 4.0)

    def test_overlapping_calls_add_no_gap(self) -> None:
        summary = lane.summarize_inside_turns([call(0, 5), call(3, 8)], clocks_of((0, 10)))
        self.assertEqual(summary["between_calls_s"], 0.0)

    def test_other_turn_time_is_what_the_inside_tools_and_gaps_leave(self) -> None:
        full = lane.summarize_inside_turns([call(0, 2), call(5, 6)], clocks_of((0, 20)))
        self.assertEqual(full["other_turn_time_s"], 20.0 - 3.0 - 3.0)
        # The turn time ends at 5.5: the first call and the gap are inside, half of the second call is.
        cut = lane.summarize_inside_turns([call(0, 2), call(5, 6)], clocks_of((0, 5.5)))
        self.assertEqual(cut["other_turn_time_s"], 5.5 - 2.5 - 3.0)

    def test_a_reread_counts_the_inside_gap_and_the_inside_call(self) -> None:
        # The gap is 1..4 and the reread call 4..6; the turn time is 0.5..5: 3 s of the gap and 1 s of the call.
        summary = lane.summarize_inside_turns([call(0, 1), call(4, 6, reread=True)], clocks_of((0.5, 5)))
        self.assertEqual(summary["rereads_after_first_call_turn_time_s"], 4.0)

    def test_long_execute_and_polling_count_only_inside_seconds(self) -> None:
        calls = [call(0, 100, polling=True), call(200, 210, polling=True), call(300, 400, tool="Read")]
        summary = lane.summarize_inside_turns(calls, clocks_of((50, 350)))
        # Tools: 50 + 10 + 50. Execute: 50 + 10. Only the first call is long, and it is polling.
        self.assertEqual(summary["tool_time_s"], 110.0)
        self.assertEqual(summary["execute_time_s"], 60.0)
        self.assertEqual((summary["long_execute_time_s"], summary["polling_time_s"]), (50.0, 50.0))

    def test_a_call_is_long_by_its_whole_length_and_not_by_its_inside_part(self) -> None:
        summary = lane.summarize_inside_turns([call(0, 100)], clocks_of((90, 200)))
        self.assertEqual(summary["long_execute_time_s"], 10.0)

    def test_polling_by_keeper_counts_the_inside_seconds_against_the_keepers_own_turn_time(self) -> None:
        def poll(keeper: str, start: float, end: float) -> lane.Call:
            return lane.Call(keeper, f"{keeper}/t#1", "Execute", start, end, False, True)

        calls = [
            poll("a", 0, 100),  # 50 s inside
            poll("b", 0, 100),  # 100 s inside
            poll("b", 200, 230),  # not long, so not polling
            poll("c", 0, 100),  # Keeper c has no clock
            poll("d", 0, 100),  # outside the turn time of d
        ]
        clocks = {"a": lane.TurnClock.of([(50, 150)]), "b": lane.TurnClock.of([(0, 300)]), "d": lane.TurnClock.of([(500, 600)])}
        listed = block(lane.summarize_inside_turns(calls, clocks)["polling_by_keeper"])
        self.assertEqual(list(listed), ["b", "a"])  # largest first; c and d have no inside polling
        self.assertEqual(listed["b"], {"polling_s": 100.0, "turn_time_s": 300.0})
        self.assertEqual(listed["a"], {"polling_s": 50.0, "turn_time_s": 100.0})

    def test_the_shares_are_of_the_turn_time_and_rounded_to_one_decimal(self) -> None:
        shares = block(lane.summarize_inside_turns([call(0, 10)], clocks_of((0, 30)))["percent_of_turn_time"])
        self.assertEqual((shares["tool"], shares["execute"], shares["between_calls"], shares["other"]), (33.3, 33.3, 0.0, 66.7))
        self.assertEqual((shares["long_execute"], shares["polling"], shares["rereads_after_first_call"]), (0.0, 0.0, 0.0))

    def test_the_turn_time_is_the_sum_of_the_keepers_merged_intervals(self) -> None:
        # Keeper a holds 150 s and b 100 s: 250 s, not 350 s.
        clocks = {"a": lane.TurnClock.of([(0, 100), (50, 150)]), "b": lane.TurnClock.of([(0, 100)])}
        shares = block(lane.summarize_inside_turns([call(0, 25)], clocks)["percent_of_turn_time"])
        self.assertEqual(shares["tool"], 0.0)  # the call belongs to Keeper k, which has no clock
        calls = [lane.Call("a", "a/t#1", "Execute", 0, 25, False, False)]
        self.assertEqual(block(lane.summarize_inside_turns(calls, clocks)["percent_of_turn_time"])["tool"], 10.0)

    def test_with_every_call_inside_the_totals_equal_those_of_summarize_calls(self) -> None:
        calls = [call(0, 2), call(5, 9, reread=True), call(20, 30, tool="Read"), call(0, 1, turn="k/t#2")]
        full = lane.summarize_calls(calls, {"k": 100.0})
        inside = lane.summarize_inside_turns(calls, clocks_of((0, 100)))
        self.assertEqual(inside["tool_time_s"], full["tool_time_s"])
        self.assertEqual(inside["execute_time_s"], full["execute_time_s"])
        self.assertEqual(inside["between_calls_s"], block(full["between_calls"])["sum_s"])
        self.assertEqual(inside["other_turn_time_s"], full["other_turn_time_s"])
        self.assertEqual(inside["rereads_after_first_call_turn_time_s"], block(full["rereads_after_first_call"])["turn_time_s"])


def call_of_turn(turn: str, turn_kind: str, start: float, end: float, *, tool: str = "Execute") -> lane.Call:
    return lane.Call("k", turn, tool, start, end, False, False, 0, "unknown", turn_kind)


class UntracedTest(unittest.TestCase):
    def test_calls_of_turns_without_a_trace_file_are_counted_by_turn_kind(self) -> None:
        calls = [
            call_of_turn("k/trace-1-00000#1", "autonomous", 0, 10),  # has a trace file
            call_of_turn("k/trace-1-00000#2", "direct", 0, 20),
            call_of_turn("k/trace-1-00000#2", "direct", 30, 35, tool="Read"),
            call_of_turn("k/trace-1-00000#3", "autonomous", 0, 40),
        ]
        summary = lane.summarize_untraced(calls, frozenset({"k/trace-1-00000#1"}), {})
        self.assertEqual((summary["calls"], summary["turns"], summary["tool_time_s"], summary["execute_time_s"]), (3, 2, 65.0, 60.0))
        self.assertEqual(summary["turns_in_window"], 3)
        kinds = block(summary["by_turn_kind"])
        self.assertEqual(list(kinds), ["autonomous", "direct"])
        self.assertEqual(
            block(kinds["direct"]), {"calls": 2, "turns": 1, "tool_time_s": 25.0, "execute_time_s": 20.0, "turns_of_this_kind": 1}
        )
        # The autonomous turn that has a trace file counts in `turns_of_this_kind`, not in `turns`.
        self.assertEqual(
            block(kinds["autonomous"]), {"calls": 1, "turns": 1, "tool_time_s": 40.0, "execute_time_s": 40.0, "turns_of_this_kind": 2}
        )

    def test_when_every_turn_has_a_trace_file_nothing_is_untraced(self) -> None:
        summary = lane.summarize_untraced([call_of_turn("k/trace-1-00000#1", "autonomous", 0, 10)], frozenset({"k/trace-1-00000#1"}), {})
        self.assertEqual((summary["calls"], summary["turns"], summary["tool_time_s"], summary["by_turn_kind"]), (0, 0, 0.0, {}))
        self.assertEqual((summary["turns_in_window"], summary["tool_time_inside_turns_s"]), (1, 0.0))

    def test_the_file_of_another_keeper_does_not_trace_the_call(self) -> None:
        summary = lane.summarize_untraced([call_of_turn("k/trace-1-00000#1", "direct", 0, 10)], frozenset({"other/trace-1-00000#1"}), {})
        self.assertEqual(summary["calls"], 1)

    def test_the_seconds_of_untraced_calls_that_the_keepers_turn_time_covers_are_listed(self) -> None:
        calls = [call_of_turn("k/trace-1-00000#2", "direct", 0, 20), call_of_turn("k/trace-1-00000#3", "direct", 30, 35, tool="Read")]
        clocks = clocks_of((10, 32))
        self.assertEqual(lane.summarize_untraced(calls, frozenset(), clocks)["tool_time_inside_turns_s"], 10.0 + 2.0)
        # A call whose turn has a trace file is not counted, and a Keeper without a clock has no inside seconds.
        traced = frozenset({"k/trace-1-00000#2", "k/trace-1-00000#3"})
        self.assertEqual(lane.summarize_untraced(calls, traced, clocks)["tool_time_inside_turns_s"], 0.0)
        self.assertEqual(lane.summarize_untraced(calls, frozenset(), {})["tool_time_inside_turns_s"], 0.0)


class TraceKeysTest(unittest.TestCase):
    @staticmethod
    def write(base: pathlib.Path, keeper: str, name: str) -> None:
        directory = base / ".masc" / "keeper_turn_events" / keeper
        directory.mkdir(parents=True, exist_ok=True)
        (directory / name).write_text("{}\n", encoding="utf-8")

    def test_the_file_name_gives_the_trace_id_and_the_turn_id(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            self.write(base, "k", "trace-1792566606674-00000-2476-8d86742357ba00d5.jsonl")
            self.write(base, "k", "trace-1792566606674-00000-12-0123456789abcdef.jsonl")
            self.write(base, "other", "trace-1792566606674-00000-2476-8d86742357ba00d5.jsonl")
            self.write(base, "k", "notes.jsonl")
            self.write(base, "k", "trace-1792566606674-00000-7-nothex.jsonl")
            self.write(base, "k", "trace-1792566606674-00000-8-abc.txt")
            (base / ".masc" / "keeper_turn_events" / "stray.jsonl").write_text("{}\n", encoding="utf-8")
            keys = lane.read_trace_keys(base)
        self.assertEqual(
            keys,
            frozenset({"k/trace-1792566606674-00000#2476", "k/trace-1792566606674-00000#12", "other/trace-1792566606674-00000#2476"}),
        )

    def test_a_ledger_row_and_the_file_of_its_turn_spell_the_same_key(self) -> None:
        row = {"record_kind": "tool_call", "ts": 1000.0, "duration_ms": 1000, "keeper": "k", "tool": "Execute",
               "trace_id": "trace-100-00001", "keeper_turn_id": 5}
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            day_dir = base / ".masc" / "tool_calls" / "2026-11"
            day_dir.mkdir(parents=True)
            (day_dir / "01.jsonl").write_text(json.dumps(row) + "\n", encoding="utf-8")
            self.write(base, "k", "trace-100-00001-5-abcdef0123456789.jsonl")
            calls = lane.read_calls(base, date(2026, 11, 1), date(2026, 11, 1), until=5000.0)
            keys = lane.read_trace_keys(base)
        self.assertEqual([c.turn for c in calls], ["k/trace-100-00001#5"])
        self.assertIn(calls[0].turn, keys)

    def test_no_directory_gives_no_keys(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            self.assertEqual(lane.read_trace_keys(pathlib.Path(raw)), frozenset())


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
             "batch_size": 2, "execution_mode": "concurrent", "turn_kind": "direct"},
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
        self.assertEqual([c.turn_kind for c in calls], ["direct", "unknown", "unknown"])

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


TURN_STARTED_KIND = "turn_started"
QUEUE_CANCELLED_KIND = "event_queue_cancelled"


def stimulus_row(keeper: str, stimulus_id: str, arrived: float) -> str:
    return json.dumps(
        {
            "record_kind": "stimulus",
            "keeper_name": keeper,
            "stimulus_id": stimulus_id,
            "recorded_at_unix": arrived + 1.0,
            "stimulus": {"kind": "schedule_due", "arrived_at_unix": arrived},
        }
    )


def reaction_row(keeper: str, stimulus_id: str, kind: str, recorded: float) -> str:
    return json.dumps(
        {
            "record_kind": "reaction",
            "keeper_name": keeper,
            "stimulus_id": stimulus_id,
            "recorded_at_unix": recorded,
            "reaction": {"kind": kind},
        }
    )


def write_reaction_day(base: pathlib.Path, keeper: str, day: str, lines: list[str]) -> None:
    month, number = day[:7], day[8:]
    directory = base / ".masc" / "keepers" / keeper / "reaction-ledger" / "v7" / month
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{number}.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")


def wake(arrived: float, started: float | None, *, cancelled: bool = False, keeper: str = "k") -> lane.Wake:
    return lane.Wake(keeper, arrived, started, cancelled)


class WakeReadTest(unittest.TestCase):
    def test_a_start_recorded_the_next_day_joins_and_a_cancel_does_not_start(self) -> None:
        first = DAY_START + 100.0
        day_two = DAY_START + 86_400.0
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_reaction_day(
                base,
                "k",
                "2026-11-01",
                [
                    stimulus_row("k", "a", first),
                    stimulus_row("k", "late-start", DAY_START + 86_000.0),
                    stimulus_row("k", "cancelled", first + 5.0),
                    stimulus_row("k", "outside", DAY_START + 90_000.0),  # after `until`
                    stimulus_row("k", "before", DAY_START - 50.0),  # before `since`, recorded late into the first day's file
                    reaction_row("k", "a", TURN_STARTED_KIND, first + 30.0),
                    reaction_row("k", "a", TURN_STARTED_KIND, first + 99.0),  # a later start is ignored
                    reaction_row("k", "cancelled", QUEUE_CANCELLED_KIND, first + 6.0),
                    "{not json",
                ],
            )
            write_reaction_day(base, "k", "2026-11-02", [reaction_row("k", "late-start", TURN_STARTED_KIND, day_two + 50.0)])
            wakes = lane.read_wakes(base, date(2026, 11, 1), date(2026, 11, 1), DAY_START, DAY_START + 88_000.0)
        by_id = {(w.arrived): w for w in wakes}
        self.assertEqual(len(wakes), 3)
        self.assertEqual(by_id[first].started, first + 30.0)
        self.assertEqual(by_id[DAY_START + 86_000.0].started, day_two + 50.0)
        self.assertEqual((by_id[first + 5.0].started, by_id[first + 5.0].cancelled), (None, True))

    def test_the_same_stimulus_id_of_two_keepers_keeps_each_keepers_state(self) -> None:
        arrived = DAY_START + 10.0
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_reaction_day(
                base,
                "k",
                "2026-11-01",
                [stimulus_row("k", "same", arrived), reaction_row("k", "same", TURN_STARTED_KIND, arrived + 5.0)],
            )
            write_reaction_day(
                base,
                "j",
                "2026-11-01",
                [stimulus_row("j", "same", arrived), reaction_row("j", "same", QUEUE_CANCELLED_KIND, arrived + 7.0)],
            )
            wakes = lane.read_wakes(base, date(2026, 11, 1), date(2026, 11, 1), DAY_START, DAY_START + 1_000.0)
        state = {w.keeper: (w.started, w.cancelled) for w in wakes}
        self.assertEqual(state, {"k": (arrived + 5.0, False), "j": (None, True)})

    def test_a_start_recorded_two_days_after_the_window_is_not_read(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_reaction_day(base, "k", "2026-11-01", [stimulus_row("k", "a", DAY_START + 10.0)])
            write_reaction_day(base, "k", "2026-11-03", [reaction_row("k", "a", TURN_STARTED_KIND, DAY_START + 2 * 86_400.0 + 5.0)])
            wakes = lane.read_wakes(base, date(2026, 11, 1), date(2026, 11, 1), DAY_START, DAY_START + 1_000.0)
        self.assertEqual([w.started for w in wakes], [None])



class WakeSummaryTest(unittest.TestCase):
    def test_counts_split_started_cancelled_and_unstarted(self) -> None:
        summary = lane.summarize_wakes(
            [wake(0, 10), wake(0, None, cancelled=True), wake(0, None), wake(0, 20)], {}, {}
        )
        self.assertEqual(
            (summary["stimuli"], summary["turn_started"], summary["cancelled_in_queue"], summary["no_turn_started"]),
            (4, 2, 1, 1),
        )
        self.assertEqual(summary["latency"]["sum_s"], 30.0)  # type: ignore[index]

    def test_a_wake_cancelled_after_it_started_counts_as_started(self) -> None:
        summary = lane.summarize_wakes([wake(0, 10, cancelled=True)], {}, {})
        self.assertEqual((summary["turn_started"], summary["cancelled_in_queue"]), (1, 0))

    def test_a_wake_that_started_before_it_arrived_counts_zero_latency(self) -> None:
        summary = lane.summarize_wakes([wake(100, 90)], {}, {})
        self.assertEqual(summary["latency"]["sum_s"], 0.0)  # type: ignore[index]

    def test_wait_is_split_by_what_the_same_keeper_was_doing(self) -> None:
        long_execute = {"k": [(0.0, 400.0)], "other": [(600.0, 900.0)]}
        runs = {"k": [(0.0, 400.0), (1000.0, 1100.0)]}
        wakes = [
            wake(100, 1_500),  # arrives inside the Execute; waits 1400 s; 300 s of it inside the Execute
            wake(500, 1_500, keeper="other"),  # waits through its own Execute (300 s), not through k's
        ]
        summary = lane.summarize_wakes(wakes, long_execute, runs)
        self.assertEqual(summary["total_wait_s"], 2_400.0)
        self.assertEqual(summary["wait_overlapping_long_execute_s"], 600.0)  # 300 of k's own + 300 of other's own
        self.assertEqual(summary["wait_overlapping_a_run_of_the_same_keeper_s"], 400.0)  # 300 + 100 of k's runs
        self.assertEqual(summary["created_during_long_execute"]["n"], 1)  # type: ignore[index]

    def test_waits_of_half_an_hour_or_more_are_totalled_apart(self) -> None:
        summary = lane.summarize_wakes([wake(0, 1_799), wake(0, 1_800), wake(0, 5_000)], {}, {})
        tail = summary["waited_at_least_30_min"]
        assert isinstance(tail, dict)
        self.assertEqual((tail["n"], tail["sum_s"]), (2, 6_800.0))

    def test_a_keeper_whose_waits_were_all_short_is_not_listed(self) -> None:
        tail = lane.summarize_wakes([wake(0, 1_000, keeper="quick"), wake(0, 2_000, keeper="slow")], {}, {})["waited_at_least_30_min"]
        assert isinstance(tail, dict)
        self.assertEqual(tail["top_keepers"], [{"keeper": "slow", "n": 1, "sum_s": 2_000.0}])

    def test_the_longest_waiting_keepers_are_listed_largest_first_and_capped(self) -> None:
        wakes = [wake(0, 2_000, keeper="small"), wake(0, 9_000, keeper="big"), wake(0, 3_000, keeper="big")]
        wakes += [wake(0, 2_000 + 100 * index, keeper=f"k{index}") for index in range(lane.TOP_WAKE_KEEPERS + 1)]
        tail = lane.summarize_wakes(wakes, {}, {})["waited_at_least_30_min"]
        assert isinstance(tail, dict)
        top = tail["top_keepers"]
        self.assertEqual(len(top), lane.TOP_WAKE_KEEPERS)
        self.assertEqual(top[0], {"keeper": "big", "n": 2, "sum_s": 12_000.0})
        self.assertEqual([item["sum_s"] for item in top], sorted((item["sum_s"] for item in top), reverse=True))


def ledger_row(ts: float, seconds: int, tool: str, turn_id: int, turn_kind: str) -> dict[str, object]:
    return {"record_kind": "tool_call", "ts": ts, "duration_ms": seconds * 1000, "keeper": "k", "tool": tool,
            "trace_id": "trace-100-00001", "keeper_turn_id": turn_id, "turn_kind": turn_kind}


def run_main(rows: list[dict[str, object]], run: tuple[float, float]) -> dict[str, object]:
    """Run the script on a ledger of `rows` and one trace file (turn 1 of Keeper k) that spans `run`."""
    with tempfile.TemporaryDirectory() as raw:
        base = pathlib.Path(raw)
        day_dir = base / ".masc" / "tool_calls" / "1970-01"
        day_dir.mkdir(parents=True)
        (day_dir / "01.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
        trace_dir = base / ".masc" / "keeper_turn_events" / "k"
        trace_dir.mkdir(parents=True)
        (trace_dir / "trace-100-00001-1-abcdef0123456789.jsonl").write_text(
            json.dumps({"ts": run[0]}) + "\n" + json.dumps({"ts": run[1]}) + "\n", encoding="utf-8"
        )
        argv = ["measure_lane_time.py", "--base-path", str(base), "--from-date", "1970-01-01", "--to-date", "1970-01-01",
                "--until", "1970-01-01T01:00:00Z"]
        out = io.StringIO()
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(out):
            assert lane.main() == 0
    return block(json.loads(out.getvalue())["turn_time"])


class MainTest(unittest.TestCase):
    def test_the_summary_carries_the_inside_and_untraced_blocks(self) -> None:
        turn_time = run_main(
            [
                ledger_row(1010.0, 10, "Execute", 1, "autonomous"),  # 1000..1010, inside the run
                ledger_row(1040.0, 10, "Read", 1, "autonomous"),  # 1030..1040, after the run ended at 1030
                ledger_row(1060.0, 20, "Execute", 2, "direct"),  # 1040..1060, a turn with no trace file
            ],
            (1000.0, 1030.0),
        )
        self.assertEqual(turn_time["turn_time_s"], 30.0)
        self.assertEqual(turn_time["tool_time_s"], 40.0)
        inside = block(turn_time["inside_turns"])
        # Inside the 30 s of the run: the first call (10 s) and the 20 s gap before the second call. The rest is outside.
        self.assertEqual((inside["tool_time_s"], inside["execute_time_s"], inside["between_calls_s"], inside["other_turn_time_s"]), (10.0, 10.0, 20.0, 0.0))
        self.assertEqual(block(inside["percent_of_turn_time"])["tool"], 33.3)
        untraced = block(turn_time["calls_without_trace_file"])
        self.assertEqual((untraced["calls"], untraced["turns"], untraced["turns_in_window"]), (1, 1, 2))
        self.assertEqual(untraced["tool_time_inside_turns_s"], 0.0)  # the direct turn runs after the run has ended
        self.assertEqual(
            block(untraced["by_turn_kind"]),
            {"direct": {"calls": 1, "turns": 1, "tool_time_s": 20.0, "execute_time_s": 20.0, "turns_of_this_kind": 1}},
        )

    def test_the_untraced_block_counts_the_seconds_that_the_keepers_run_covers(self) -> None:
        turn_time = run_main(
            [
                ledger_row(1010.0, 10, "Execute", 1, "autonomous"),
                ledger_row(1040.0, 20, "Execute", 2, "direct"),  # 1020..1040, 10 s of it inside the run 1000..1030
            ],
            (1000.0, 1030.0),
        )
        untraced = block(turn_time["calls_without_trace_file"])
        self.assertEqual((untraced["calls"], untraced["tool_time_s"], untraced["tool_time_inside_turns_s"]), (1, 20.0, 10.0))


if __name__ == "__main__":
    unittest.main()
