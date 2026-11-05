"""Tests for measure_restart_cancelled_turns.py. Run: python3 -B -m unittest discover -s <this folder>."""

from __future__ import annotations

import contextlib
import datetime
import io
import json
import pathlib
import tempfile
import unittest
from collections.abc import Sequence
from typing import cast

import measure_restart_cancelled_turns as m

BASE = datetime.datetime(2026, 11, 5, 2, 0, 0, tzinfo=datetime.timezone.utc).timestamp()
DAY = "2026-11-05"


def iso(offset: float) -> str:
    moment = datetime.datetime.fromtimestamp(BASE + offset, datetime.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def request(
    start: float,
    end: float,
    turn: int,
    input_tokens: int = 100,
    uncached: int = 10,
    output: int = 5,
    runtime: str = "rt",
) -> m.Request:
    return m.Request(BASE + start, BASE + end, turn, input_tokens, uncached, output, runtime)


def cut_turn(
    keeper: str = "k",
    turn: int = 1,
    shutdown: int = 0,
    stopped_at: float = 100.0,
    elapsed: float = 60.0,
    gap: float | None = None,
    runtime: str = "rt",
) -> m.CutTurn:
    return m.CutTurn(keeper, turn, shutdown, stopped_at, elapsed, gap, 1, 10, 1, 1, runtime)


def cost_row(agent: str, turn: int, end: float, latency_ms: int, **extra: object) -> dict[str, object]:
    row: dict[str, object] = {
        "usage_scope": "per_request",
        "agent": agent,
        "keeper_turn_id": turn,
        "timestamp": iso(end),
        "request_latency_ms": latency_ms,
        "input_tokens": 1000,
        "non_cached_input_tokens": 100,
        "output_tokens": 10,
        "runtime_id": "rt",
    }
    row.update(extra)
    return row


def stop_row(keeper: str, offset: float) -> dict[str, object]:
    return {
        "ts": iso(offset),
        "keeper_name": keeper,
        "message": f"keeper_chat_error incident_id=x detail={m.STOP_MARKER}",
    }


def shutdown_row(offset: float) -> dict[str, object]:
    return {
        "ts": iso(offset),
        "keeper_name": "system",
        "message": f"[MASC] {m.SHUTDOWN_MARKER}, shutting down gracefully (timeout=10s, hard_exit=124)...",
    }


def tool_row(keeper: str, turn: int, offset: float, tool: str, fingerprint: str | None) -> dict[str, object]:
    row: dict[str, object] = {"keeper": keeper, "keeper_turn_id": turn, "ts": BASE + offset, "tool": tool}
    if fingerprint is not None:
        row[m.FINGERPRINT_FIELD] = fingerprint
    return row


def write_lines(path: pathlib.Path, rows: Sequence[object | str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write((row if isinstance(row, str) else json.dumps(row)) + "\n")


def index(items: Sequence[tuple[str, m.Request]]) -> m.Turns:
    return m.index_requests(items)


class ParseTests(unittest.TestCase):
    def test_parse_utc(self) -> None:
        self.assertEqual(m.parse_utc("2026-11-05T02:00:00Z"), BASE)
        self.assertIsNone(m.parse_utc("2026-11-05T02:00:00"))
        self.assertIsNone(m.parse_utc("not a time"))
        self.assertIsNone(m.parse_utc(1.5))

    def test_numbers_reject_booleans_and_text(self) -> None:
        self.assertIsNone(m.as_int(True))
        self.assertIsNone(m.as_int("3"))
        self.assertEqual(m.as_int(3), 3)
        self.assertIsNone(m.as_float(False))
        self.assertEqual(m.as_float(2), 2.0)
        self.assertIsNone(m.as_str(""))

    def test_read_logs_keeps_shutdown_and_stop_lines_only(self) -> None:
        skipped = m.Skipped()
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "log.jsonl"
            write_lines(
                path,
                [
                    stop_row("k2", 30),
                    shutdown_row(500),
                    shutdown_row(10),
                    {"ts": iso(11), "keeper_name": "k1", "message": f"no tag {m.STOP_MARKER}"},
                    {"ts": iso(12), "keeper_name": "k1", "message": "unrelated"},
                    {"ts": iso(13), "message": f"{m.STOP_TAG} {m.STOP_MARKER}"},
                    {"ts": "bad", "keeper_name": "k1", "message": f"{m.STOP_TAG} {m.STOP_MARKER}"},
                    "{broken " + m.STOP_MARKER,
                    json.dumps([m.STOP_MARKER]),
                    stop_row("k1", 20),
                ],
            )
            shutdowns, stops = m.read_logs([path], skipped)
        self.assertEqual(shutdowns, [BASE + 10, BASE + 500])
        self.assertEqual(stops, [m.Stop(BASE + 20, "k1"), m.Stop(BASE + 30, "k2")])
        self.assertEqual(skipped.bad_lines, 2)

    def test_parse_request_reads_one_cost_row(self) -> None:
        skipped = m.Skipped()
        parsed = m.parse_request(cost_row("a", 4, 100, 40_000), skipped)
        assert parsed is not None
        agent, item = parsed
        self.assertEqual((agent, item.turn, item.runtime_id), ("a", 4, "rt"))
        self.assertEqual((item.start, item.end), (BASE + 60, BASE + 100))
        self.assertEqual((item.input_tokens, item.uncached_tokens, item.output_tokens), (1000, 100, 10))
        self.assertEqual(skipped.cost_rows_without_turn, 0)

    def test_parse_request_skips_other_scopes_and_counts_unusable_rows(self) -> None:
        skipped = m.Skipped()
        self.assertIsNone(m.parse_request({**cost_row("a", 1, 10, 0), "usage_scope": "aggregate"}, skipped))
        self.assertEqual(skipped.cost_rows_without_turn, 0)
        for broken in (
            {**cost_row("a", 1, 10, 0), "agent": None},
            {**cost_row("a", 1, 10, 0), "keeper_turn_id": None},
            {**cost_row("a", 1, 10, 0), "keeper_turn_id": True},
            {**cost_row("a", 1, 10, 0), "timestamp": "never"},
        ):
            self.assertIsNone(m.parse_request(broken, skipped))
        self.assertEqual(skipped.cost_rows_without_turn, 4)

    def test_parse_request_clamps_latency_and_defaults_missing_values(self) -> None:
        skipped = m.Skipped()
        parsed = m.parse_request(
            {"usage_scope": "per_request", "agent": "a", "keeper_turn_id": 1, "timestamp": iso(50),
             "request_latency_ms": -500},
            skipped,
        )
        assert parsed is not None
        item = parsed[1]
        self.assertEqual((item.start, item.end), (BASE + 50, BASE + 50))
        self.assertEqual((item.input_tokens, item.uncached_tokens, item.output_tokens), (0, 0, 0))
        self.assertEqual(item.runtime_id, "unknown")


class AttributionTests(unittest.TestCase):
    def test_a_stop_belongs_to_the_latest_shutdown_within_the_window(self) -> None:
        shutdowns = [BASE, BASE + 1000]
        stops = [
            m.Stop(BASE - 1, "k"),
            m.Stop(BASE, "k"),
            m.Stop(BASE + 10, "k"),
            m.Stop(BASE + 60, "k"),
            m.Stop(BASE + 61, "k"),
            m.Stop(BASE + 1001, "k"),
        ]
        attributed, unattributed = m.attribute(stops, shutdowns)
        self.assertEqual([(stop.at - BASE, index) for stop, index in attributed], [(0, 0), (10, 0), (60, 0), (1001, 1)])
        self.assertEqual(unattributed, 2)

    def test_no_shutdown_leaves_every_stop_unattributed(self) -> None:
        attributed, unattributed = m.attribute([m.Stop(BASE, "k")], [])
        self.assertEqual((attributed, unattributed), ([], 1))


class CutTurnTests(unittest.TestCase):
    def turns(self) -> m.Turns:
        return index(
            [
                ("a", request(100, 160, 1)),
                ("a", request(200, 230, 2, input_tokens=300, uncached=30, output=7, runtime="old")),
                ("a", request(240, 300, 2, input_tokens=400, uncached=40, output=8, runtime="new")),
                ("a", request(400, 420, 2)),
                ("a", request(500, 520, 2)),
            ]
        )

    def find(self, stop_at: float, recent: float, keeper: str = "a") -> tuple[list[m.CutTurn], int, int]:
        return m.find_cut_turns([(m.Stop(BASE + stop_at, keeper), 0)], self.turns(), recent)

    def test_the_cut_turn_is_the_turn_of_the_last_request_before_the_stop(self) -> None:
        cut, no_recent, duplicates = self.find(310, 120)
        self.assertEqual((len(cut), no_recent, duplicates), (1, 0, 0))
        turn = cut[0]
        self.assertEqual((turn.keeper, turn.turn, turn.shutdown), ("a", 2, 0))
        self.assertEqual(turn.elapsed_s, 110.0)
        self.assertEqual(turn.stopped_at, BASE + 310)
        self.assertEqual((turn.requests, turn.input_tokens, turn.uncached_tokens, turn.output_tokens), (2, 700, 70, 15))
        self.assertEqual(turn.runtime_id, "new")

    def test_a_later_request_of_the_same_turn_is_the_resume_and_not_a_member(self) -> None:
        turn = self.find(310, 120)[0][0]
        self.assertEqual(turn.resume_gap_s, 90.0)
        self.assertEqual(turn.requests, 2)

    def test_the_recent_window_includes_its_edge(self) -> None:
        self.assertEqual(len(self.find(310, 10)[0]), 1)
        cut, no_recent, _ = self.find(310, 9.5)
        self.assertEqual((cut, no_recent), ([], 1))

    def test_a_request_that_ends_just_after_the_stop_still_counts(self) -> None:
        cut, _, _ = self.find(298, 120)
        self.assertEqual(cut[0].turn, 2)
        self.assertEqual(cut[0].requests, 2)
        early, _, _ = self.find(294, 120)
        self.assertEqual(early[0].turn, 2)
        before_second = index([("a", request(100, 160, 1)), ("a", request(165, 170, 2))])
        cut_far, _, _ = m.find_cut_turns([(m.Stop(BASE + 164, "a"), 0)], before_second, 120)
        self.assertEqual(cut_far[0].turn, 1)

    def test_a_request_that_starts_within_the_slack_is_not_a_resume(self) -> None:
        turns = index([("a", request(200, 230, 2)), ("a", request(312, 330, 2)), ("a", request(316, 340, 2))])
        cut, _, _ = m.find_cut_turns([(m.Stop(BASE + 310, "a"), 0)], turns, 120)
        self.assertEqual(cut[0].requests, 2)
        self.assertEqual(cut[0].resume_gap_s, 6.0)
        none = index([("a", request(200, 230, 2)), ("a", request(315, 330, 2))])
        cut_none, _, _ = m.find_cut_turns([(m.Stop(BASE + 310, "a"), 0)], none, 120)
        self.assertEqual(cut_none[0].requests, 2)
        self.assertIsNone(cut_none[0].resume_gap_s)

    def test_several_stop_lines_for_one_turn_count_once(self) -> None:
        stops = [(m.Stop(BASE + 310, "a"), 0), (m.Stop(BASE + 311, "a"), 0)]
        cut, no_recent, duplicates = m.find_cut_turns(stops, self.turns(), 120)
        self.assertEqual((len(cut), no_recent, duplicates), (1, 0, 1))
        self.assertEqual(cut[0].elapsed_s, 110.0)

    def test_a_keeper_without_requests_has_no_recent_request(self) -> None:
        cut, no_recent, _ = self.find(310, 1800, keeper="nobody")
        self.assertEqual((cut, no_recent), ([], 1))

    def test_a_stop_before_the_first_request_has_no_recent_request(self) -> None:
        cut, no_recent, _ = self.find(10, 1800)
        self.assertEqual((cut, no_recent), ([], 1))

    def test_the_turn_ids_of_different_keepers_do_not_mix(self) -> None:
        turns = index([("a", request(0, 10, 5)), ("b", request(20, 30, 5, input_tokens=999))])
        cut, _, _ = m.find_cut_turns([(m.Stop(BASE + 12, "a"), 0)], turns, 60)
        self.assertEqual((cut[0].requests, cut[0].input_tokens), (1, 100))

    def test_elapsed_never_goes_below_zero(self) -> None:
        turns = index([("a", request(100, 102, 1))])
        cut, _, _ = m.find_cut_turns([(m.Stop(BASE + 98, "a"), 0)], turns, 60)
        self.assertEqual(cut[0].elapsed_s, 0.0)


class NumbersTests(unittest.TestCase):
    def test_quantile_is_nearest_rank(self) -> None:
        values = [1.0, 2.0, 3.0, 4.0]
        self.assertEqual(m.quantile(values, 0.5), 2.0)
        self.assertEqual(m.quantile(values, 0.9), 4.0)
        self.assertEqual(m.quantile(values, 0.0), 1.0)

    def test_spread_scales_and_handles_empty(self) -> None:
        self.assertEqual(m.spread([], 60.0), {"p50": 0.0, "p90": 0.0, "max": 0.0})
        self.assertEqual(m.spread([120.0, 60.0, 600.0], 60.0), {"p50": 2.0, "p90": 10.0, "max": 10.0})

    def test_spread_picks_nearest_rank_values_and_rounds_to_three_places(self) -> None:
        tens = [float(value) for value in range(10, 101, 10)]
        self.assertEqual(m.spread(tens, 10.0), {"p50": 5.0, "p90": 9.0, "max": 10.0})
        self.assertEqual(m.spread([100.0], 3.0), {"p50": 33.333, "p90": 33.333, "max": 33.333})

    def test_hours_rounds_to_three_places(self) -> None:
        self.assertEqual(m.hours(5400), 1.5)
        self.assertEqual(m.hours(1), 0.0)
        self.assertEqual(m.hours(18), 0.005)


class FinishShareTests(unittest.TestCase):
    SPANS = {
        ("x", 1): (0.0, 50.0),
        ("x", 2): (0.0, 120.0),
        ("x", 3): (0.0, 150.0),
        ("x", 4): (0.0, 500.0),
        ("x", 5): (0.0, 1000.0),
        ("k", 9): (0.0, 5000.0),
    }

    def shares(self, cut: Sequence[m.CutTurn], waits: Sequence[float]) -> list[dict[str, object]]:
        return m.finish_shares(cut, self.SPANS, waits)

    def test_share_among_turns_longer_than_the_elapsed_time(self) -> None:
        rows = self.shares([cut_turn(keeper="k", turn=9, elapsed=100.0)], [10.0, 60.0, 900.0])
        self.assertEqual([row["mean_finish_share"] for row in rows], [0.0, 0.5, 1.0])
        self.assertEqual([row["wait_s"] for row in rows], [10.0, 60.0, 900.0])

    def test_a_turn_as_long_as_the_elapsed_time_is_not_longer(self) -> None:
        spans = {("x", 1): (0.0, 100.0), ("x", 2): (0.0, 150.0), ("x", 3): (0.0, 300.0), ("k", 9): (0.0, 500.0)}
        rows = m.finish_shares([cut_turn(keeper="k", turn=9, elapsed=100.0)], spans, [60.0])
        self.assertEqual(rows[0]["mean_finish_share"], 0.5)

    def test_the_cut_turn_is_not_its_own_reference(self) -> None:
        rows = self.shares([cut_turn(keeper="k", turn=9, elapsed=2000.0)], [60.0])
        self.assertIsNone(rows[0]["mean_finish_share"])
        self.assertEqual(rows[0]["cut_turns_without_reference"], 1)

    def test_the_mean_runs_over_the_cut_turns_that_have_a_reference(self) -> None:
        cut = [
            cut_turn(keeper="k", turn=9, elapsed=100.0),
            cut_turn(keeper="y", turn=1, elapsed=140.0),
            cut_turn(keeper="y", turn=2, elapsed=9000.0),
        ]
        row = self.shares(cut, [60.0])[0]
        self.assertEqual(row["cut_turns_without_reference"], 1)
        self.assertEqual(row["mean_finish_share"], round((2 / 4 + 1 / 3) / 2, 4))


class RepeatedCallsTests(unittest.TestCase):
    def calls(self) -> dict[m.TurnKey, list[m.ToolCall]]:
        return {
            ("k", 1): [
                m.ToolCall(BASE + 10, "Execute", "f1"),
                m.ToolCall(BASE + 20, "Read", "f2"),
                m.ToolCall(BASE + 100, "Execute", "f7"),
                m.ToolCall(BASE + 103, "Execute", "f1"),
                m.ToolCall(BASE + 105, "Execute", "f7"),
                m.ToolCall(BASE + 105.5, "Execute", "f7"),
                m.ToolCall(BASE + 106, "Execute", "f1"),
                m.ToolCall(BASE + 107, "Execute", "f9"),
                m.ToolCall(BASE + 108, "Read", "f1"),
            ],
            ("k", 2): [m.ToolCall(BASE + 10, "Execute", "f1"), m.ToolCall(BASE + 200, "Execute", "f1")],
        }

    def test_a_call_after_the_resume_with_the_same_tool_and_input_is_a_repeat(self) -> None:
        cut = [cut_turn(turn=1, stopped_at=BASE + 100, gap=50.0)]
        result = m.repeated_calls(cut, self.calls())
        self.assertEqual(result["calls_before_stop"], 3)
        self.assertEqual(result["calls_after_stop"], 4)
        self.assertEqual(result["calls_after_stop_repeating_before_stop"], 2)
        self.assertEqual(result["repeated_share"], 0.5)
        self.assertEqual(result["repeated_by_tool"], [{"tool": "Execute", "calls": 2}])

    def test_the_repeated_share_keeps_four_decimals(self) -> None:
        calls = {
            ("k", 1): [
                m.ToolCall(BASE, "Execute", "f1"),
                m.ToolCall(BASE + 50, "Execute", "f1"),
                m.ToolCall(BASE + 51, "Execute", "f2"),
                m.ToolCall(BASE + 52, "Execute", "f3"),
            ]
        }
        result = m.repeated_calls([cut_turn(turn=1, stopped_at=BASE + 10, gap=1.0)], calls)
        self.assertEqual(result["repeated_share"], 0.3333)

    def test_a_turn_that_was_not_resumed_adds_nothing(self) -> None:
        cut = [cut_turn(turn=2, stopped_at=BASE + 100, gap=None)]
        result = m.repeated_calls(cut, self.calls())
        self.assertEqual((result["calls_before_stop"], result["calls_after_stop"]), (0, 0))
        self.assertIsNone(result["repeated_share"])

    def test_a_turn_without_ledger_rows_adds_nothing(self) -> None:
        result = m.repeated_calls([cut_turn(turn=7, gap=1.0)], {})
        self.assertEqual(result["calls_after_stop"], 0)
        self.assertEqual(result["repeated_by_tool"], [])

    def test_repeated_tools_are_ordered_by_count_then_name(self) -> None:
        calls = {
            ("k", 1): [
                m.ToolCall(BASE, "B", "f"),
                m.ToolCall(BASE, "A", "f"),
                m.ToolCall(BASE, "C", "f"),
                m.ToolCall(BASE + 50, "B", "f"),
                m.ToolCall(BASE + 50, "A", "f"),
                m.ToolCall(BASE + 50, "C", "f"),
                m.ToolCall(BASE + 51, "C", "f"),
            ]
        }
        result = m.repeated_calls([cut_turn(turn=1, stopped_at=BASE + 10, gap=1.0)], calls)
        self.assertEqual(
            result["repeated_by_tool"],
            [{"tool": "C", "calls": 2}, {"tool": "A", "calls": 1}, {"tool": "B", "calls": 1}],
        )


class RepeatedToolListTests(unittest.TestCase):
    def test_at_most_five_tools_are_listed(self) -> None:
        names = ["t1", "t2", "t3", "t4", "t5", "t6", "t7"]
        calls = {("k", 1): [m.ToolCall(BASE, name, "f") for name in names] + [m.ToolCall(BASE + 50, name, "f") for name in names]}
        result = m.repeated_calls([cut_turn(turn=1, stopped_at=BASE + 10, gap=1.0)], calls)
        self.assertEqual([row["tool"] for row in cast_rows(result["repeated_by_tool"])], names[:5])
        self.assertEqual(result["calls_after_stop_repeating_before_stop"], 7)


def cast_rows(value: object) -> list[dict[str, object]]:
    assert isinstance(value, list)
    return cast(list[dict[str, object]], value)


class BreakdownTests(unittest.TestCase):
    def test_largest_elapsed_first_then_name_and_top_limits_the_rows(self) -> None:
        cut = [
            cut_turn(keeper="b", turn=1, elapsed=3600.0),
            cut_turn(keeper="a", turn=2, elapsed=3600.0),
            cut_turn(keeper="a", turn=3, elapsed=1800.0),
            cut_turn(keeper="c", turn=4, elapsed=60.0),
        ]
        rows = m.breakdown(cut, "keeper", 2)
        self.assertEqual(rows, [
            {"keeper": "a", "cut_turns": 2, "elapsed_hours": 1.5},
            {"keeper": "b", "cut_turns": 1, "elapsed_hours": 1.0},
        ])
        runtimes = m.breakdown([cut_turn(runtime="x", elapsed=7200.0), cut_turn(runtime="y", elapsed=60.0)], "runtime_id", None)
        self.assertEqual([row["runtime_id"] for row in runtimes], ["x", "y"])


class WindowBlockTests(unittest.TestCase):
    def test_counts_per_shutdown_and_their_hours(self) -> None:
        cut = [
            cut_turn(keeper="a", turn=1, shutdown=0, elapsed=7200.0),
            cut_turn(keeper="b", turn=2, shutdown=1, elapsed=1800.0),
            cut_turn(keeper="c", turn=3, shutdown=1, elapsed=1800.0),
        ]
        turns = m.Turns({}, {}, {("a", 1): (0.0, 7200.0), ("b", 2): (0.0, 1800.0), ("c", 3): (0.0, 1800.0)})
        block = m.window_block(60.0, cut, 0, 0, 2, turns, {}, [60.0], 8)
        self.assertEqual(block["cut_turns_per_shutdown"], {"p50": 1.0, "p90": 2.0, "max": 2.0})
        self.assertEqual(block["elapsed_hours_per_shutdown"], {"p50": 1.0, "p90": 2.0, "max": 2.0})
        self.assertEqual(block["shutdowns_with_cut_turn"], 2)
        self.assertEqual(block["share_of_turn_span"], 1.0)

    def test_an_empty_window_has_no_share(self) -> None:
        block = m.window_block(60.0, [], 0, 0, 0, m.Turns({}, {}, {}), {}, [60.0], 8)
        self.assertIsNone(block["share_of_turn_span"])
        self.assertEqual(block["cut_turns"], 0)
        self.assertEqual(block["by_keeper"], [])
        self.assertEqual(block["elapsed_minutes"], {"p50": 0.0, "p90": 0.0, "max": 0.0})


class InputFilesTests(unittest.TestCase):
    def test_tool_call_files_take_the_day_and_its_numbered_segments_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            folder = base / ".masc" / "tool_calls" / "2026-11"
            for name in ("05.jsonl", "05.001.jsonl", "05.010.jsonl", "15.jsonl", "05.1.jsonl", "050.jsonl", "05.jsonl.gz"):
                write_lines(folder / name, [])
            found = m.tool_call_files(base, datetime.date(2026, 11, 5))
            self.assertEqual([path.name for path in found], ["05.001.jsonl", "05.010.jsonl", "05.jsonl"])
            self.assertEqual(m.tool_call_files(base, datetime.date(2026, 12, 5)), [])

    def test_every_segment_of_a_day_is_an_input(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ("05.jsonl", "05.001.jsonl", "05.002.jsonl"):
                write_lines(base / ".masc" / "tool_calls" / "2026-11" / name, [])
            inputs = m.input_paths(base, m.days_between(DAY, DAY), m.Skipped())
        self.assertEqual([path.name for path in inputs.tool_calls], ["05.001.jsonl", "05.002.jsonl", "05.jsonl"])

    def test_missing_files_are_listed_by_kind_and_day(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            write_lines(base / ".masc" / "logs" / f"system_log_{DAY}.jsonl", [])
            skipped = m.Skipped()
            inputs = m.input_paths(base, m.days_between(DAY, "2026-11-06"), skipped)
        self.assertEqual(len(inputs.logs), 1)
        self.assertEqual(
            sorted(skipped.missing_days),
            ["costs:2026-11-05", "costs:2026-11-06", "logs:2026-11-06", "tool_calls:2026-11-05", "tool_calls:2026-11-06"],
        )

    def test_read_tool_calls_keeps_only_wanted_turns_with_all_fields(self) -> None:
        skipped = m.Skipped()
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "05.jsonl"
            write_lines(
                path,
                [
                    tool_row("k", 1, 5, "Execute", "f1"),
                    tool_row("k", 2, 5, "Execute", "f1"),
                    tool_row("other", 1, 5, "Execute", "f1"),
                    tool_row("k", 1, 6, "Read", None),
                    {"keeper": "k", "keeper_turn_id": True, "ts": BASE, "tool": "Read", m.FINGERPRINT_FIELD: "f"},
                    {"keeper": "k", "keeper_turn_id": 1, "ts": "x", "tool": "Read", m.FINGERPRINT_FIELD: "f"},
                    {"keeper": "k", "keeper_turn_id": 1, "ts": BASE, "tool": "Read", m.FINGERPRINT_FIELD: None},
                    "broken " + m.FINGERPRINT_FIELD,
                ],
            )
            calls = m.read_tool_calls([path], {("k", 1)}, skipped)
        self.assertEqual(dict(calls), {("k", 1): [m.ToolCall(BASE + 5, "Execute", "f1")]})
        self.assertEqual(skipped.bad_lines, 1)


class CommandLineTests(unittest.TestCase):
    def build(self, base: pathlib.Path) -> None:
        masc = base / ".masc"
        write_lines(
            masc / "logs" / f"system_log_{DAY}.jsonl",
            [
                shutdown_row(310),
                stop_row("k1", 312),
                stop_row("k1", 313),
                stop_row("k2", 315),
                stop_row("k3", 316),
                stop_row("k1", 1000),
            ],
        )
        write_lines(
            masc / "costs" / "2026-11" / "05.jsonl",
            [
                cost_row("k1", 7, 100, 40_000),
                cost_row("k1", 7, 300, 100_000),
                cost_row("k1", 7, 430, 30_000),
                cost_row("k2", 3, 250, 50_000),
                cost_row("k4", 1, 1000, 1_000_000),
                cost_row("k1", 8, 50, 1, usage_scope="aggregate"),
            ],
        )
        write_lines(
            masc / "tool_calls" / "2026-11" / "05.jsonl",
            [
                tool_row("k1", 7, 210, "Execute", "f1"),
                tool_row("k1", 7, 250, "Read", "f2"),
                tool_row("k1", 7, 405, "Execute", "f1"),
                tool_row("k1", 7, 410, "Execute", "f3"),
                tool_row("k2", 3, 260, "Read", "f2"),
                tool_row("k9", 1, 260, "Read", "f2"),
            ],
        )

    def run_main(self, args: Sequence[str]) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = m.main(list(args))
        return code, out.getvalue()

    def test_the_report_for_a_small_ledger(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            self.build(base)
            out_path = base / "result.json"
            code, printed = self.run_main(
                ["--base-path", str(base), "--from-date", DAY, "--to-date", DAY,
                 "--recent-request-s", "600", "--wait-s", "60", "--wait-s", "900", "--json-out", str(out_path)]
            )
            written = out_path.read_text(encoding="utf-8")
            result = json.loads(written)
        self.assertTrue(written.endswith("}\n"))
        self.assertEqual((code, printed), (0, ""))
        self.assertEqual(
            {key: result[key] for key in ("shutdowns", "stop_lines", "attributed_stop_lines", "unattributed_stop_lines", "requests", "turns")},
            {"shutdowns": 1, "stop_lines": 5, "attributed_stop_lines": 4, "unattributed_stop_lines": 1, "requests": 5, "turns": 3},
        )
        self.assertEqual(result["turn_span_hours"], m.hours(370 + 50 + 1000))
        self.assertEqual(result["skipped"], {"bad_lines": 0, "cost_rows_without_turn": 0, "missing_days": []})
        (window,) = result["windows"]
        self.assertEqual(
            {key: window[key] for key in ("cut_turns", "duplicate_stop_lines", "no_recent_request", "shutdowns_with_cut_turn")},
            {"cut_turns": 2, "duplicate_stop_lines": 1, "no_recent_request": 1, "shutdowns_with_cut_turn": 1},
        )
        self.assertEqual(window["elapsed_hours"], m.hours(252 + 115))
        self.assertEqual(window["share_of_turn_span"], round((252 + 115) / 1420, 4))
        self.assertEqual(
            (window["requests"], window["input_tokens"], window["uncached_input_tokens"], window["output_tokens"]),
            (3, 3000, 300, 30),
        )
        self.assertEqual(window["elapsed_minutes"], {"p50": round(115 / 60, 3), "p90": round(252 / 60, 3), "max": round(252 / 60, 3)})
        self.assertEqual(window["resume_gap_minutes"], {"p50": round(88 / 60, 3), "p90": round(88 / 60, 3), "max": round(88 / 60, 3)})
        self.assertEqual(window["resumed_cut_turns"], 1)
        self.assertEqual(window["resumed_elapsed_hours"], m.hours(252))
        self.assertEqual(window["resume_gap_hours_total"], m.hours(88))
        self.assertEqual(window["not_resumed_cut_turns"], 1)
        self.assertEqual(window["not_resumed_elapsed_hours"], m.hours(115))
        self.assertEqual(
            window["repeated_calls"],
            {
                "calls_before_stop": 2,
                "calls_after_stop": 2,
                "calls_after_stop_repeating_before_stop": 1,
                "repeated_share": 0.5,
                "repeated_by_tool": [{"tool": "Execute", "calls": 1}],
            },
        )
        self.assertEqual([row["mean_finish_share"] for row in window["finish_share_if_shutdown_waited"]], [0.0, 1.0])
        self.assertEqual([row["keeper"] for row in window["by_keeper"]], ["k1", "k2"])
        self.assertEqual(window["by_runtime"], [{"runtime_id": "rt", "cut_turns": 2, "elapsed_hours": m.hours(367)}])
        self.assertEqual(window["cut_turns_per_shutdown"], {"p50": 2.0, "p90": 2.0, "max": 2.0})

    def test_without_json_out_the_report_goes_to_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            self.build(base)
            code, printed = self.run_main(["--base-path", str(base), "--from-date", DAY, "--to-date", DAY])
        self.assertEqual(code, 0)
        result = json.loads(printed)
        self.assertEqual([window["recent_request_s"] for window in result["windows"]], list(m.DEFAULT_RECENT_S))
        self.assertEqual(result["params"]["wait_s"], list(m.DEFAULT_DRAIN_S))

    def test_a_missing_day_is_reported_and_not_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            self.build(base)
            _, printed = self.run_main(["--base-path", str(base), "--from-date", DAY, "--to-date", "2026-11-06"])
        self.assertEqual(
            sorted(json.loads(printed)["skipped"]["missing_days"]),
            ["costs:2026-11-06", "logs:2026-11-06", "tool_calls:2026-11-06"],
        )

    def test_bad_days_and_a_reversed_range_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for args in (
                ["--from-date", "2026-13-01", "--to-date", DAY],
                ["--from-date", DAY, "--to-date", "yesterday"],
                ["--from-date", "2026-11-06", "--to-date", DAY],
            ):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                    m.main(["--base-path", tmp, *args])
                self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
