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

    def find(self, stop_at: float, recent: float, keeper: str = "a") -> m.Cuts:
        return m.find_cut_turns([(m.Stop(BASE + stop_at, keeper), 0)], self.turns(), recent)

    def test_the_cut_turn_is_the_turn_of_the_last_request_before_the_stop(self) -> None:
        cuts = self.find(310, 120)
        self.assertEqual((len(cuts.first), cuts.repeats, cuts.no_recent, cuts.duplicates), (1, [], 0, 0))
        turn = cuts.first[0]
        self.assertEqual((turn.keeper, turn.turn, turn.shutdown), ("a", 2, 0))
        self.assertEqual(turn.elapsed_s, 110.0)
        self.assertEqual(turn.stopped_at, BASE + 310)
        self.assertEqual((turn.requests, turn.input_tokens, turn.uncached_tokens, turn.output_tokens), (2, 700, 70, 15))
        self.assertEqual(turn.runtime_id, "new")

    def test_a_later_request_of_the_same_turn_is_the_resume_and_not_a_member(self) -> None:
        turn = self.find(310, 120).first[0]
        self.assertEqual(turn.resume_gap_s, 90.0)
        self.assertEqual(turn.requests, 2)

    def test_the_recent_window_includes_its_edge(self) -> None:
        self.assertEqual(len(self.find(310, 10).first), 1)
        missed = self.find(310, 9.5)
        self.assertEqual((missed.first, missed.no_recent), ([], 1))

    def test_a_request_that_ends_just_after_the_stop_still_counts(self) -> None:
        cuts = self.find(298, 120)
        self.assertEqual(cuts.first[0].turn, 2)
        self.assertEqual(cuts.first[0].requests, 2)
        early = self.find(294, 120)
        self.assertEqual(early.first[0].turn, 2)
        before_second = index([("a", request(100, 160, 1)), ("a", request(165, 170, 2))])
        far = m.find_cut_turns([(m.Stop(BASE + 164, "a"), 0)], before_second, 120)
        self.assertEqual(far.first[0].turn, 1)

    def test_a_request_that_starts_within_the_slack_is_not_a_resume(self) -> None:
        turns = index([("a", request(200, 230, 2)), ("a", request(312, 330, 2)), ("a", request(316, 340, 2))])
        cuts = m.find_cut_turns([(m.Stop(BASE + 310, "a"), 0)], turns, 120)
        self.assertEqual(cuts.first[0].requests, 2)
        self.assertEqual(cuts.first[0].resume_gap_s, 6.0)
        none = index([("a", request(200, 230, 2)), ("a", request(315, 330, 2))])
        cuts_none = m.find_cut_turns([(m.Stop(BASE + 310, "a"), 0)], none, 120)
        self.assertEqual(cuts_none.first[0].requests, 2)
        self.assertIsNone(cuts_none.first[0].resume_gap_s)

    def test_several_stop_lines_for_one_turn_count_once(self) -> None:
        stops = [(m.Stop(BASE + 310, "a"), 0), (m.Stop(BASE + 311, "a"), 0)]
        cuts = m.find_cut_turns(stops, self.turns(), 120)
        self.assertEqual((len(cuts.first), cuts.repeats, cuts.no_recent, cuts.duplicates), (1, [], 0, 1))
        self.assertEqual(cuts.first[0].elapsed_s, 110.0)

    def test_a_keeper_without_requests_has_no_recent_request(self) -> None:
        cuts = self.find(310, 1800, keeper="nobody")
        self.assertEqual((cuts.first, cuts.no_recent), ([], 1))

    def test_a_stop_before_the_first_request_has_no_recent_request(self) -> None:
        cuts = self.find(10, 1800)
        self.assertEqual((cuts.first, cuts.no_recent), ([], 1))

    def test_the_turn_ids_of_different_keepers_do_not_mix(self) -> None:
        turns = index([("a", request(0, 10, 5)), ("b", request(20, 30, 5, input_tokens=999))])
        cuts = m.find_cut_turns([(m.Stop(BASE + 12, "a"), 0)], turns, 60)
        self.assertEqual((cuts.first[0].requests, cuts.first[0].input_tokens), (1, 100))

    def test_elapsed_never_goes_below_zero(self) -> None:
        turns = index([("a", request(100, 102, 1))])
        cuts = m.find_cut_turns([(m.Stop(BASE + 98, "a"), 0)], turns, 60)
        self.assertEqual(cuts.first[0].elapsed_s, 0.0)


class RepeatCutTests(unittest.TestCase):
    def turns(self) -> m.Turns:
        return index(
            [
                ("a", request(200, 230, 2, input_tokens=300, uncached=30, output=7)),
                ("a", request(240, 300, 2, input_tokens=400, uncached=40, output=8)),
                ("a", request(400, 420, 2, input_tokens=500, uncached=50, output=9, runtime="again")),
                ("a", request(500, 520, 2, input_tokens=600, uncached=60, output=10, runtime="again")),
            ]
        )

    def cut(self, *stops: tuple[float, int]) -> m.Cuts:
        return m.find_cut_turns([(m.Stop(BASE + at, "a"), shutdown) for at, shutdown in stops], self.turns(), 120)

    def test_a_later_shutdown_that_cuts_a_resumed_turn_again_is_a_repeat_cut(self) -> None:
        cuts = self.cut((310, 0), (530, 1))
        self.assertEqual((len(cuts.first), len(cuts.repeats), cuts.no_recent, cuts.duplicates), (1, 1, 0, 0))
        first, again = cuts.first[0], cuts.repeats[0]
        self.assertEqual((first.shutdown, first.elapsed_s, first.requests, first.resume_gap_s), (0, 110.0, 2, 90.0))
        self.assertEqual(
            (again.keeper, again.turn, again.shutdown, again.stopped_at, again.elapsed_s, again.requests),
            ("a", 2, 1, BASE + 530, 130.0, 2),
        )
        self.assertEqual((again.input_tokens, again.uncached_tokens, again.output_tokens), (1100, 110, 19))
        self.assertEqual(again.runtime_id, "again")
        self.assertIsNone(again.resume_gap_s)

    def test_a_repeat_cut_that_is_followed_by_a_request_has_a_gap(self) -> None:
        cuts = self.cut((310, 0), (430, 1))
        self.assertEqual(cuts.repeats[0].requests, 1)
        self.assertEqual(cuts.repeats[0].elapsed_s, 30.0)
        self.assertEqual(cuts.repeats[0].resume_gap_s, 70.0)

    def test_stop_lines_of_the_same_shutdown_stay_duplicates_after_a_repeat_cut(self) -> None:
        cuts = self.cut((310, 0), (311, 0), (530, 1), (531, 1))
        self.assertEqual((len(cuts.first), len(cuts.repeats), cuts.duplicates), (1, 1, 2))

    def test_one_shutdown_cuts_a_turn_once_even_if_a_request_starts_between_its_stop_lines(self) -> None:
        turns = index([("a", request(200, 230, 2)), ("a", request(320, 345, 2))])
        cuts = m.find_cut_turns([(m.Stop(BASE + 310, "a"), 0), (m.Stop(BASE + 350, "a"), 0)], turns, 120)
        self.assertEqual((len(cuts.first), cuts.repeats, cuts.duplicates), (1, [], 1))

    def test_a_later_shutdown_without_a_new_request_is_a_duplicate(self) -> None:
        cuts = self.cut((310, 0), (320, 1))
        self.assertEqual((len(cuts.first), cuts.repeats, cuts.duplicates), (1, [], 1))

    def test_a_third_cut_counts_only_the_requests_after_the_second(self) -> None:
        cuts = self.cut((310, 0), (430, 1), (530, 2))
        self.assertEqual([repeat.shutdown for repeat in cuts.repeats], [1, 2])
        self.assertEqual([repeat.requests for repeat in cuts.repeats], [1, 1])
        self.assertEqual([repeat.elapsed_s for repeat in cuts.repeats], [30.0, 30.0])

    def test_the_boundary_between_two_cuts_is_the_previous_stop_plus_the_slack(self) -> None:
        turns = index(
            [
                ("a", request(200, 230, 2)),
                ("a", request(315, 318, 2)),
                ("a", request(316, 340, 2)),
            ]
        )
        cuts = m.find_cut_turns([(m.Stop(BASE + 310, "a"), 0), (m.Stop(BASE + 350, "a"), 1)], turns, 120)
        self.assertEqual((cuts.first[0].requests, cuts.first[0].resume_gap_s), (2, 6.0))
        self.assertEqual((cuts.repeats[0].requests, cuts.repeats[0].elapsed_s), (1, 34.0))


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

    def test_share_rounds_to_four_places_and_needs_a_span(self) -> None:
        self.assertEqual(m.share(1.0, 4.0), 0.25)
        self.assertEqual(m.share(1.0, 3.0), 0.3333)
        self.assertEqual(m.share(0.0, 4.0), 0.0)
        self.assertIsNone(m.share(1.0, 0.0))

    def test_cut_totals_sum_the_cuts_and_count_distinct_turns(self) -> None:
        cuts = [
            m.CutTurn("a", 1, 0, 0.0, 3600.0, None, 2, 100, 10, 5, "x"),
            m.CutTurn("a", 1, 1, 0.0, 1800.0, None, 3, 200, 20, 6, "x"),
            m.CutTurn("b", 1, 0, 0.0, 1800.0, None, 4, 400, 40, 7, "y"),
        ]
        self.assertEqual(
            m.cut_totals(cuts),
            {
                "cuts": 3,
                "turns": 2,
                "elapsed_hours": 2.0,
                "requests": 9,
                "input_tokens": 700,
                "uncached_input_tokens": 70,
                "output_tokens": 18,
            },
        )

    def test_cuts_per_turn_counts_turns_by_how_often_they_were_cut(self) -> None:
        cuts = [
            cut_turn(keeper="a", turn=1, shutdown=0),
            cut_turn(keeper="a", turn=1, shutdown=1),
            cut_turn(keeper="a", turn=2, shutdown=0),
            cut_turn(keeper="b", turn=1, shutdown=0),
            cut_turn(keeper="b", turn=1, shutdown=1),
            cut_turn(keeper="b", turn=1, shutdown=2),
        ]
        self.assertEqual(m.cuts_per_turn(cuts), {"1": 1, "2": 1, "3": 1})
        self.assertEqual(list(m.cuts_per_turn(cuts)), ["1", "2", "3"])
        self.assertEqual(m.cuts_per_turn([]), {})

    def test_loss_bounds_use_the_gap_or_the_elapsed_time_for_the_lower_bound(self) -> None:
        cuts = [cut_turn(elapsed=3600.0, gap=1800.0), cut_turn(turn=2, elapsed=7200.0, gap=None)]
        self.assertEqual(
            m.loss_bounds(cuts, 36000.0),
            {"lower_hours": 2.5, "lower_share": 0.25, "upper_hours": 3.5, "upper_share": 0.35},
        )
        self.assertEqual(m.loss_bounds([], 0.0), {"lower_hours": 0.0, "lower_share": None, "upper_hours": 0.0, "upper_share": None})


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


class UnresumedWithCallsTests(unittest.TestCase):
    def test_counts_not_resumed_turns_with_a_call_after_the_stop_slack(self) -> None:
        stop = BASE + 100
        cut = [
            cut_turn(keeper="a", turn=1, stopped_at=stop, gap=None),
            cut_turn(keeper="a", turn=2, stopped_at=stop, gap=None),
            cut_turn(keeper="a", turn=3, stopped_at=stop, gap=60.0),
            cut_turn(keeper="a", turn=4, stopped_at=stop, gap=None),
            cut_turn(keeper="b", turn=1, stopped_at=stop, gap=None),
        ]
        calls = {
            ("a", 1): [m.ToolCall(stop + 6, "X", "f")],
            ("a", 2): [m.ToolCall(stop + 5, "X", "f"), m.ToolCall(stop - 50, "X", "g")],
            ("a", 3): [m.ToolCall(stop + 60, "X", "f")],
            ("b", 1): [m.ToolCall(stop + 500, "X", "f"), m.ToolCall(stop + 900, "Y", "f")],
        }
        self.assertEqual(m.unresumed_with_calls(cut, calls), 2)
        self.assertEqual(m.unresumed_with_calls([], calls), 0)


class CarriedContextTests(unittest.TestCase):
    STOP = BASE + 100.0

    def cut(self, turn: int, gap: float | None = 60.0, keeper: str = "a") -> m.CutTurn:
        return cut_turn(keeper=keeper, turn=turn, stopped_at=self.STOP, gap=gap)

    def turn_requests(self, turn: int, first: int, last: int, after: int | None) -> list[tuple[str, m.Request]]:
        rows = [("a", request(0, 10, turn, input_tokens=first)), ("a", request(20, 30, turn, input_tokens=last))]
        if after is not None:
            rows.append(("a", request(200, 210, turn, input_tokens=after)))
        return rows

    def test_the_share_is_the_growth_the_first_request_after_the_stop_still_carries(self) -> None:
        rows = [
            *self.turn_requests(1, 1000, 11000, 8000),
            *self.turn_requests(2, 1000, 11000, 11000),
            ("a", request(300, 310, 2, input_tokens=21000)),
            *self.turn_requests(3, 1000, 11000, 2000),
            *self.turn_requests(5, 1000, 6000, 8000),
            *self.turn_requests(9, 1000, 11000, 9000),
            *self.turn_requests(10, 1000, 11000, 3000),
            *self.turn_requests(12, 1000, 11000, 8800),
        ]
        result = m.carried_context([self.cut(turn) for turn in (1, 2, 3, 5, 9, 10, 12)], index(rows))
        self.assertEqual(
            result,
            {
                "min_growth_tokens": 5000,
                "turns": 7,
                "retained_share": {"p10": 0.1, "p50": 0.78, "p90": 1.4},
                "at_least_80_percent": 3,
                "below_20_percent": 1,
            },
        )

    def test_turns_without_enough_history_growth_or_a_later_request_are_left_out(self) -> None:
        rows = [
            *self.turn_requests(4, 1000, 5999, 6000),
            *self.turn_requests(6, 1000, 11000, None),
            ("a", request(0, 10, 7, input_tokens=1000)),
            ("a", request(200, 210, 7, input_tokens=11000)),
            *self.turn_requests(8, 1000, 11000, 11000),
            *self.turn_requests(11, 11000, 1000, 5000),
            ("a", request(200, 210, 13, input_tokens=11000)),
        ]
        cuts = [self.cut(4), self.cut(6), self.cut(7), self.cut(8, gap=None), self.cut(11), self.cut(13)]
        result = m.carried_context(cuts, index(rows))
        self.assertEqual((result["turns"], result["retained_share"]), (0, None))
        self.assertEqual((result["at_least_80_percent"], result["below_20_percent"]), (0, 0))

    def test_a_request_that_starts_within_the_slack_is_still_before_the_stop(self) -> None:
        rows = [
            ("a", request(0, 10, 1, input_tokens=1000)),
            ("a", request(105, 110, 1, input_tokens=11000)),
            ("a", request(106, 120, 1, input_tokens=11000)),
        ]
        result = m.carried_context([self.cut(1)], index(rows))
        self.assertEqual((result["turns"], result["retained_share"]), (1, {"p10": 1.0, "p50": 1.0, "p90": 1.0}))
        self.assertEqual(m.carried_context([self.cut(1)], index(rows[:2]))["turns"], 0)

    def test_requests_are_ordered_by_start_and_the_other_keepers_are_ignored(self) -> None:
        rows = [
            ("a", request(10, 20, 1, input_tokens=7000)),
            ("a", request(0, 40, 1, input_tokens=1000)),
            ("a", request(200, 210, 1, input_tokens=11000)),
            ("b", request(-5, 15, 1, input_tokens=99999)),
        ]
        result = m.carried_context([self.cut(1)], index(rows))
        self.assertEqual((result["turns"], result["retained_share"]), (1, {"p10": 1.667, "p50": 1.667, "p90": 1.667}))

    def test_the_window_counts_first_cuts_only(self) -> None:
        rows = self.turn_requests(1, 1000, 11000, 11000)
        first = [self.cut(1)]
        again = [cut_turn(keeper="a", turn=1, shutdown=1, stopped_at=BASE + 25.0, gap=60.0)]
        turns = index(rows)
        block = m.window_block(60.0, m.Cuts(first, again, 0, 0), 2, turns, {}, [60.0], 8)
        self.assertEqual(cast_dict(block["carried_context"])["turns"], 1)


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
        block = m.window_block(60.0, m.Cuts(cut, [], 0, 0), 2, turns, {}, [60.0], 8)
        self.assertEqual(block["cut_turns_per_shutdown"], {"p50": 1.0, "p90": 2.0, "max": 2.0})
        self.assertEqual(block["elapsed_hours_per_shutdown"], {"p50": 1.0, "p90": 2.0, "max": 2.0})
        self.assertEqual(block["shutdowns_with_cut_turn"], 2)
        self.assertEqual(block["share_of_turn_span"], 1.0)

    def test_an_empty_window_has_no_share(self) -> None:
        block = m.window_block(60.0, m.Cuts([], [], 0, 0), 0, m.Turns({}, {}, {}), {}, [60.0], 8)
        self.assertIsNone(block["share_of_turn_span"])
        self.assertEqual(block["cut_turns"], 0)
        self.assertEqual(block["by_keeper"], [])
        self.assertEqual(block["elapsed_minutes"], {"p50": 0.0, "p90": 0.0, "max": 0.0})
        self.assertEqual(cast_dict(block["repeat_cuts"])["cuts"], 0)
        self.assertIsNone(cast_dict(block["all_cuts"])["share_of_turn_span"])

    def test_the_cut_turn_figures_leave_out_repeat_cuts_and_all_cuts_add_them(self) -> None:
        first = [
            cut_turn(keeper="a", turn=1, shutdown=0, elapsed=3600.0, gap=600.0),
            cut_turn(keeper="b", turn=2, shutdown=0, elapsed=1200.0, gap=None),
        ]
        again = [cut_turn(keeper="a", turn=1, shutdown=2, elapsed=1800.0, gap=None)]
        turns = m.Turns({}, {}, {("a", 1): (0.0, 30000.0), ("b", 2): (0.0, 6000.0)})
        block = m.window_block(60.0, m.Cuts(first, again, 5, 7), 3, turns, {}, [60.0], 8)
        self.assertEqual((block["cut_turns"], block["elapsed_hours"], block["share_of_turn_span"]), (2, 1.333, 0.1333))
        self.assertEqual((block["duplicate_stop_lines"], block["no_recent_request"]), (7, 5))
        self.assertEqual(block["shutdowns_with_cut_turn"], 1)
        self.assertEqual(cast_dict(block["repeat_cuts"])["cuts"], 1)
        self.assertEqual(cast_dict(block["repeat_cuts"])["elapsed_hours"], 0.5)
        everything = cast_dict(block["all_cuts"])
        self.assertEqual((everything["cuts"], everything["turns"], everything["shutdowns"]), (3, 2, 2))
        self.assertEqual((everything["elapsed_hours"], everything["share_of_turn_span"]), (1.833, 0.1833))
        self.assertEqual(everything["cuts_per_turn"], {"1": 1, "2": 1})
        self.assertEqual(
            everything["loss"],
            {"lower_hours": 1.0, "lower_share": 0.1, "upper_hours": 2.0, "upper_share": 0.2},
        )


def cast_dict(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    return cast(dict[str, object], value)


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
                tool_row("k2", 3, 400, "Read", "f9"),
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
        self.assertEqual(window["not_resumed_with_calls_after_stop"], 1)
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

    def test_the_report_counts_a_turn_that_a_second_shutdown_cuts_again(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            masc = base / ".masc"
            write_lines(
                masc / "logs" / f"system_log_{DAY}.jsonl",
                [shutdown_row(105), stop_row("k1", 110), shutdown_row(305), stop_row("k1", 310)],
            )
            write_lines(
                masc / "costs" / "2026-11" / "05.jsonl",
                [cost_row("k1", 7, 100, 100_000), cost_row("k1", 7, 300, 100_000), cost_row("k1", 7, 500, 100_000)],
            )
            write_lines(masc / "tool_calls" / "2026-11" / "05.jsonl", [])
            _, printed = self.run_main(
                ["--base-path", str(base), "--from-date", DAY, "--to-date", DAY, "--recent-request-s", "600"]
            )
        (window,) = json.loads(printed)["windows"]
        self.assertEqual((window["cut_turns"], window["duplicate_stop_lines"], window["elapsed_hours"]), (1, 0, m.hours(110)))
        self.assertEqual(window["resume_gap_hours_total"], m.hours(90))
        self.assertEqual(window["repeat_cuts"]["cuts"], 1)
        self.assertEqual(window["repeat_cuts"]["elapsed_hours"], m.hours(110))
        self.assertEqual(window["repeat_cuts"]["uncached_input_tokens"], 100)
        everything = window["all_cuts"]
        self.assertEqual((everything["cuts"], everything["turns"], everything["shutdowns"]), (2, 1, 2))
        self.assertEqual((everything["elapsed_hours"], everything["share_of_turn_span"]), (m.hours(220), 0.44))
        self.assertEqual(everything["cuts_per_turn"], {"2": 1})
        self.assertEqual(
            everything["loss"],
            {"lower_hours": m.hours(180), "lower_share": 0.36, "upper_hours": m.hours(400), "upper_share": 0.8},
        )

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
