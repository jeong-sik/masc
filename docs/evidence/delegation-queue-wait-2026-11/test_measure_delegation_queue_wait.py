from __future__ import annotations

import contextlib
import datetime
import io
import json
import os
import pathlib
import sqlite3
import tempfile
import time
import unittest
from collections.abc import Generator, Mapping, Sequence
from typing import cast
from unittest import mock

import measure_delegation_queue_wait as m

UTC = datetime.timezone.utc
DAY = datetime.date(2026, 11, 2)


@contextlib.contextmanager
def local_timezone(name: str) -> Generator[None]:
    """Run the body with the process time zone set to `name`, so a local-date mistake shows."""
    previous = os.environ.get("TZ")
    os.environ["TZ"] = name
    time.tzset()
    try:
        yield
    finally:
        if previous is None:
            del os.environ["TZ"]
        else:
            os.environ["TZ"] = previous
        time.tzset()


def at(hour: int = 0, minute: int = 0, second: int = 0, day: int = 2) -> float:
    return datetime.datetime(2026, 11, day, hour, minute, second, tzinfo=UTC).timestamp()


def source(sender: str | None) -> str:
    return json.dumps({"surface": {"kind": "agent"}, "sender_keeper": sender})


def delegation(
    created: float,
    started: float | None,
    completed: float | None = None,
    target: str = "target-a",
    state: str = "succeeded",
    operation_id: str = "op",
) -> m.Delegation:
    return m.Delegation(operation_id, target, "sender", state, created, started, completed)


def write_store(base: pathlib.Path, keeper: str, rows: Sequence[tuple[object, ...]]) -> None:
    folder = base / ".masc" / "keepers" / keeper
    folder.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(folder / "chat-operations.sqlite3")
    try:
        connection.execute(
            "CREATE TABLE operations (operation_id TEXT, source_json TEXT, state TEXT, "
            "created_at REAL, started_at REAL, completed_at REAL, sequence INTEGER)"
        )
        connection.executemany(
            "INSERT INTO operations(operation_id, source_json, state, created_at, started_at, completed_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            rows,
        )
        connection.commit()
    finally:
        connection.close()


def write_ledger(base: pathlib.Path, rows: Sequence[Mapping[str, object]], name: str = "02.jsonl") -> None:
    folder = base / ".masc" / "tool_calls" / "2026-11"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / name).write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def call_row(keeper: str, turn: int, ts: float, duration_ms: float = 0.0, kind: str = "tool_call") -> dict[str, object]:
    return {"record_kind": kind, "keeper": keeper, "keeper_turn_id": turn, "ts": ts, "duration_ms": duration_ms}


def submit_row(
    operation_id: object, queued_count: object, ts: float, keeper: str = "sender", output: object = None
) -> dict[str, object]:
    result: object = {"operation_id": operation_id, "state": "queued", "queued_count": queued_count, "existing": False}
    row = call_row(keeper, 1, ts)
    row["tool"] = m.DELEGATE_TOOL
    row["output"] = json.dumps(result) if output is None else output
    return row


class DelegationTests(unittest.TestCase):
    def test_queue_wait_and_run_come_from_the_three_times(self) -> None:
        found = delegation(100.0, 160.0, 400.0)
        self.assertEqual(found.queue_wait, 60.0)
        self.assertEqual(found.run, 240.0)

    def test_a_delegation_that_never_started_has_neither(self) -> None:
        found = delegation(100.0, None, 120.0, state="cancelled")
        self.assertIsNone(found.queue_wait)
        self.assertIsNone(found.run)

    def test_a_running_delegation_has_a_wait_and_no_run(self) -> None:
        found = delegation(100.0, 130.0, None, state="running")
        self.assertEqual(found.queue_wait, 30.0)
        self.assertIsNone(found.run)


class ParseTests(unittest.TestCase):
    def test_numbers_become_floats_and_nothing_else_does(self) -> None:
        self.assertEqual(m.as_float(5), 5.0)
        self.assertEqual(m.as_float(2.5), 2.5)
        self.assertIsNone(m.as_float(True))
        self.assertIsNone(m.as_float("5"))
        self.assertIsNone(m.as_float(None))

    def test_a_string_is_a_name_only_when_it_is_not_empty(self) -> None:
        self.assertEqual(m.as_str("a"), "a")
        self.assertIsNone(m.as_str(""))
        self.assertIsNone(m.as_str(3))

    def test_a_turn_id_is_an_integer_or_a_string_and_never_a_bool_or_a_container(self) -> None:
        self.assertEqual(m.as_turn_id(7), 7)
        self.assertEqual(m.as_turn_id("t-7"), "t-7")
        self.assertIsNone(m.as_turn_id(True))
        self.assertIsNone(m.as_turn_id([7]))
        self.assertIsNone(m.as_turn_id(7.5))


class QuantileTests(unittest.TestCase):
    def test_a_half_rank_rounds_up(self) -> None:
        self.assertEqual(m.rank_quantile([1.0, 2.0, 3.0, 4.0], 0.5), 3.0)

    def test_the_middle_of_an_odd_count_and_a_single_value(self) -> None:
        self.assertEqual(m.rank_quantile([1.0, 2.0, 3.0], 0.5), 2.0)
        self.assertEqual(m.rank_quantile([7.0], 0.99), 7.0)

    def test_spread_of_nothing_is_empty(self) -> None:
        block = m.spread([])
        self.assertEqual(block["n"], 0)
        self.assertIsNone(block["p50"])
        self.assertEqual(block["hours"], 0.0)

    def test_spread_picks_the_ranked_samples(self) -> None:
        block = m.spread([float(value) for value in reversed(range(101))])
        self.assertEqual((block["p50"], block["p90"], block["p99"], block["max"]), (50.0, 90.0, 99.0, 100.0))

    def test_spread_sorts_and_sums_the_hours(self) -> None:
        block = m.spread([3600.0, 0.0, 7200.0])
        self.assertEqual(block["n"], 3)
        self.assertEqual(block["p50"], 3600.0)
        self.assertEqual(block["max"], 7200.0)
        self.assertEqual(block["hours"], 3.0)


class WaitBlockTests(unittest.TestCase):
    def block(self) -> dict[str, object]:
        return m.wait_block(
            [
                delegation(0.0, 0.0, 100.0, operation_id="a"),
                delegation(0.0, 30.0, 130.0, operation_id="b"),
                delegation(0.0, 700.0, 800.0, operation_id="c"),
                delegation(0.0, None, 5.0, state="cancelled", operation_id="d"),
            ]
        )

    def test_counts_states_and_the_ones_that_never_started(self) -> None:
        block = self.block()
        self.assertEqual(block["delegations"], 4)
        self.assertEqual(block["never_started"], 1)
        self.assertEqual(block["states"], {"cancelled": 1, "succeeded": 3})

    def test_the_queue_share_divides_waiting_by_waiting_plus_running(self) -> None:
        self.assertAlmostEqual(cast(float, self.block()["queue_share_of_wall"]), 730.0 / (730.0 + 300.0))

    def test_long_waits_use_the_threshold_and_report_their_share_of_the_wait_hours(self) -> None:
        long_waits = cast(dict[str, object], self.block()["long_waits"])
        self.assertEqual(long_waits["threshold_s"], m.LONG_WAIT_S)
        self.assertEqual(long_waits["n"], 1)
        self.assertAlmostEqual(cast(float, long_waits["hours"]), 700.0 / 3600.0)
        self.assertAlmostEqual(cast(float, long_waits["share_of_wait_hours"]), 700.0 / 730.0)

    def test_a_wait_exactly_at_the_long_threshold_is_long(self) -> None:
        block = m.wait_block([delegation(0.0, m.LONG_WAIT_S, m.LONG_WAIT_S + 1)])
        self.assertEqual(cast(dict[str, object], block["long_waits"])["n"], 1)

    def test_a_running_delegation_has_a_wait_but_stays_out_of_the_share(self) -> None:
        block = m.wait_block(
            [delegation(0.0, 100.0, 200.0, operation_id="done"), delegation(0.0, 900.0, None, state="running", operation_id="running")]
        )
        self.assertAlmostEqual(cast(float, block["queue_share_of_wall"]), 100.0 / 200.0)
        self.assertEqual(cast(dict[str, object], block["queue_wait_s"])["n"], 2)
        self.assertEqual(cast(dict[str, object], block["run_s"])["n"], 1)

    def test_the_states_are_listed_in_name_order(self) -> None:
        block = m.wait_block([delegation(0.0, 1.0, 2.0, state=state) for state in ("succeeded", "failed", "cancelled")])
        self.assertEqual(list(cast(dict[str, int], block["states"])), ["cancelled", "failed", "succeeded"])

    def test_nothing_started_has_no_ratio(self) -> None:
        block = m.wait_block([delegation(0.0, None, 1.0, state="cancelled")])
        self.assertIsNone(block["queue_share_of_wall"])
        self.assertEqual(cast(dict[str, object], block["long_waits"])["share_of_wait_hours"], None)

    def test_total_is_created_to_completed_for_started_and_finished_ones(self) -> None:
        total = cast(dict[str, object], self.block()["total_s"])
        self.assertEqual(total["n"], 3)
        self.assertEqual(total["max"], 800.0)


class CheckedTimesTests(unittest.TestCase):
    def test_a_row_whose_times_run_backward_is_dropped_and_counted(self) -> None:
        skipped = m.Skipped()
        kept = m.checked_times(
            [
                delegation(10.0, 5.0, 20.0, operation_id="started-before-created"),
                delegation(10.0, 30.0, 20.0, operation_id="completed-before-started"),
                delegation(10.0, 12.0, 20.0, operation_id="fine"),
                delegation(10.0, None, 12.0, state="cancelled", operation_id="never-started"),
            ],
            skipped,
        )
        self.assertEqual([found.operation_id for found in kept], ["fine", "never-started"])
        self.assertEqual(skipped.negative_times, 2)

    def test_equal_times_are_kept(self) -> None:
        skipped = m.Skipped()
        self.assertEqual(len(m.checked_times([delegation(10.0, 10.0, 10.0)], skipped)), 1)
        self.assertEqual(skipped.negative_times, 0)


class ByTargetTests(unittest.TestCase):
    def test_targets_are_ranked_by_wait_hours_and_cut_at_top(self) -> None:
        found = [
            delegation(0.0, 3600.0, target="slow"),
            delegation(0.0, 10.0, target="quick"),
            delegation(0.0, 20.0, target="quick"),
            delegation(0.0, 1800.0, target="middle"),
        ]
        rows = m.by_target(found, 2)
        self.assertEqual([row["target"] for row in rows], ["slow", "middle"])
        self.assertEqual(rows[0]["n"], 1)

    def test_equal_wait_hours_are_ordered_by_name(self) -> None:
        found = [delegation(0.0, 10.0, target="b"), delegation(0.0, 10.0, target="a")]
        self.assertEqual([row["target"] for row in m.by_target(found, 5)], ["a", "b"])

    def test_a_target_with_only_unstarted_delegations_is_absent(self) -> None:
        self.assertEqual(m.by_target([delegation(0.0, None, 1.0, target="idle", state="cancelled")], 5), [])


class InTurnTests(unittest.TestCase):
    spans: m.Spans = {"k": [(10.0, 20.0), (30.0, 40.0)]}

    def test_inside_a_span_the_boundaries_included(self) -> None:
        self.assertTrue(m.in_turn(self.spans, "k", 10.0))
        self.assertTrue(m.in_turn(self.spans, "k", 15.0))
        self.assertTrue(m.in_turn(self.spans, "k", 20.0))
        self.assertTrue(m.in_turn(self.spans, "k", 30.0))

    def test_between_spans_before_all_and_after_all_is_outside(self) -> None:
        self.assertFalse(m.in_turn(self.spans, "k", 25.0))
        self.assertFalse(m.in_turn(self.spans, "k", 9.9))
        self.assertFalse(m.in_turn(self.spans, "k", 40.1))

    def test_another_keeper_or_no_spans_is_outside(self) -> None:
        self.assertFalse(m.in_turn(self.spans, "other", 15.0))
        self.assertFalse(m.in_turn({}, "k", 15.0))

    def test_a_long_span_that_started_before_a_later_short_one_still_counts(self) -> None:
        spans: m.Spans = {"k": [(0.0, 1000.0), (10.0, 12.0), (20.0, 22.0)]}
        self.assertTrue(m.in_turn(spans, "k", 500.0))

    def test_a_long_span_is_found_behind_hundreds_of_short_ones(self) -> None:
        short = [(float(start), start + 0.5) for start in range(1, 501)]
        spans: m.Spans = {"k": [(0.0, 10_000.0), *short]}
        self.assertTrue(m.in_turn(spans, "k", 9_000.0))
        self.assertFalse(m.in_turn({"k": short}, "k", 9_000.0))


class FlagReplayTests(unittest.TestCase):
    spans: m.Spans = {"busy": [(0.0, 5000.0)]}

    def replay(self) -> dict[str, object]:
        found = [
            delegation(100.0, 800.0, target="busy", operation_id="flagged-long"),
            delegation(200.0, 230.0, target="busy", operation_id="flagged-short"),
            delegation(6000.0, 6650.0, target="busy", operation_id="unflagged-long"),
            delegation(6000.0, 6000.0, target="busy", operation_id="unflagged-instant"),
            delegation(100.0, None, 120.0, target="busy", state="cancelled", operation_id="never-started"),
        ]
        return m.flag_replay(found, self.spans, (60.0, 600.0))

    def test_flags_count_only_the_ones_that_started(self) -> None:
        block = self.replay()
        self.assertEqual(block["started"], 4)
        self.assertEqual(block["flagged"], 2)

    def test_the_confusion_table_at_each_threshold(self) -> None:
        rows = cast(list[dict[str, object]], self.replay()["thresholds"])
        at_minute = rows[0]
        self.assertEqual(
            (at_minute["true_positive"], at_minute["false_positive"], at_minute["false_negative"], at_minute["true_negative"]),
            (1, 1, 1, 1),
        )
        at_ten = rows[1]
        self.assertEqual(
            (at_ten["true_positive"], at_ten["false_positive"], at_ten["false_negative"], at_ten["true_negative"]),
            (1, 1, 1, 1),
        )
        self.assertEqual(at_ten["precision"], 0.5)
        self.assertEqual(at_ten["recall"], 0.5)

    def test_a_wait_exactly_at_the_threshold_is_positive(self) -> None:
        found = [delegation(100.0, 160.0, target="busy")]
        rows = cast(list[dict[str, object]], m.flag_replay(found, self.spans, (60.0,))["thresholds"])
        self.assertEqual(rows[0]["true_positive"], 1)
        self.assertEqual(rows[0]["false_positive"], 0)

    def test_an_unflagged_wait_exactly_at_the_threshold_is_a_miss(self) -> None:
        found = [delegation(9000.0, 9060.0, target="busy")]
        rows = cast(list[dict[str, object]], m.flag_replay(found, self.spans, (60.0,))["thresholds"])
        self.assertEqual((rows[0]["false_negative"], rows[0]["true_negative"]), (1, 0))

    def test_wait_hours_and_spreads_split_by_flag(self) -> None:
        block = self.replay()
        self.assertAlmostEqual(cast(float, block["flagged_wait_hours"]), (700.0 + 30.0) / 3600.0)
        self.assertAlmostEqual(cast(float, block["flagged_share_of_wait_hours"]), 730.0 / (730.0 + 650.0))
        self.assertEqual(cast(dict[str, object], block["flagged_wait_s"])["n"], 2)
        self.assertEqual(cast(dict[str, object], block["unflagged_wait_s"])["n"], 2)
        self.assertEqual(cast(dict[str, object], block["unflagged_wait_s"])["max"], 650.0)
        self.assertEqual(cast(dict[str, object], block["flagged_wait_s"])["max"], 700.0)

    def test_a_flag_without_any_long_wait_has_zero_precision_and_no_recall(self) -> None:
        found = [delegation(100.0, 101.0, target="busy")]
        rows = cast(list[dict[str, object]], m.flag_replay(found, self.spans, (600.0,))["thresholds"])
        self.assertEqual(rows[0]["precision"], 0.0)
        self.assertIsNone(rows[0]["recall"])

    def test_no_flag_has_no_precision(self) -> None:
        found = [delegation(9000.0, 9700.0, target="busy")]
        rows = cast(list[dict[str, object]], m.flag_replay(found, self.spans, (600.0,))["thresholds"])
        self.assertIsNone(rows[0]["precision"])
        self.assertEqual(rows[0]["recall"], 0.0)

    def test_nothing_started_has_no_share(self) -> None:
        block = m.flag_replay([], self.spans, (60.0,))
        self.assertEqual(block["started"], 0)
        self.assertIsNone(block["flagged_share_of_wait_hours"])


class StoreTests(unittest.TestCase):
    def test_only_delegations_in_the_window_are_read_and_the_database_names_the_target(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_store(
                base,
                "target-a",
                [
                    ("d1", source("sender-x"), "succeeded", at(1), at(1, 0, 30), at(1, 5)),
                    ("dash", source(None), "succeeded", at(1), at(1), at(2)),
                    ("early", source("sender-x"), "succeeded", at(0, day=1), at(0, day=1), at(1, day=1)),
                    ("late", source("sender-x"), "succeeded", at(0, day=3), at(0, day=3), at(1, day=3)),
                    ("cancelled", source("sender-y"), "cancelled", at(2), None, at(2, 1)),
                    ("first-instant", source("sender-y"), "succeeded", at(0), at(0, 0, 1), at(0, 1)),
                ],
            )
            skipped = m.Skipped()
            found = m.read_delegations(base, m.utc_day_start(DAY), m.utc_day_start(DAY) + m.SECONDS_PER_DAY, skipped)
            self.assertEqual(sorted(each.operation_id for each in found), ["cancelled", "d1", "first-instant"])
            self.assertEqual({each.target for each in found}, {"target-a"})
            self.assertEqual(skipped.unreadable_sources, 0)
            by_id = {each.operation_id: each for each in found}
            self.assertEqual(by_id["d1"].sender, "sender-x")
            self.assertEqual(by_id["d1"].queue_wait, 30.0)
            self.assertIsNone(by_id["cancelled"].started_at)

    def test_a_source_that_is_not_an_object_or_a_row_with_a_null_field_is_counted(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_store(
                base,
                "target-a",
                [
                    ("broken", "{not json", "succeeded", at(1), at(1), at(2)),
                    ("array", "[1]", "succeeded", at(1), at(1), at(2)),
                    ("null-state", source("sender-x"), None, at(1), at(1), at(2)),
                    ("null-source", None, "succeeded", at(1), at(1), at(2)),
                    ("ok", source("sender-x"), "succeeded", at(1), at(1), at(2)),
                ],
            )
            skipped = m.Skipped()
            found = m.read_delegations(base, m.utc_day_start(DAY), m.utc_day_start(DAY) + m.SECONDS_PER_DAY, skipped)
            self.assertEqual([each.operation_id for each in found], ["ok"])
            self.assertEqual(skipped.unreadable_sources, 4)

    def test_a_database_without_the_table_is_reported_and_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            folder = base / ".masc" / "keepers" / "no-table"
            folder.mkdir(parents=True)
            sqlite3.connect(folder / "chat-operations.sqlite3").close()
            write_store(base, "target-a", [("ok", source("s"), "succeeded", at(1), at(1), at(2))])
            skipped = m.Skipped()
            found = m.read_delegations(base, m.utc_day_start(DAY), m.utc_day_start(DAY) + m.SECONDS_PER_DAY, skipped)
            self.assertEqual(skipped.unreadable_stores, ["no-table"])
            self.assertEqual(len(found), 1)

    def test_no_keepers_folder_reads_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            self.assertEqual(m.read_delegations(pathlib.Path(raw), 0.0, 1e12, m.Skipped()), [])


def read_spans(
    base: pathlib.Path, days: Sequence[datetime.date], keepers: frozenset[str], skipped: m.Skipped
) -> m.Spans:
    return m.read_ledger(base, days, keepers, skipped).spans


class SpansTests(unittest.TestCase):
    def test_a_turn_runs_from_its_first_call_to_the_end_of_its_last(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(
                base,
                [
                    call_row("a", 1, 100.0, 2000.0),
                    call_row("a", 1, 110.0, 500.0),
                    call_row("a", 2, 300.0, 0.0),
                    call_row("b", 1, 100.0, 0.0),
                    call_row("a", 3, 400.0, 0.0, kind="note"),
                ],
            )
            skipped = m.Skipped()
            spans = read_spans(base, [DAY], frozenset({"a"}), skipped)
            self.assertEqual(spans, {"a": [(100.0, 110.5), (300.0, 300.0)]})

    def test_a_negative_duration_does_not_end_a_span_before_its_start(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(base, [call_row("a", 1, 100.0, -5000.0)])
            self.assertEqual(read_spans(base, [DAY], frozenset({"a"}), m.Skipped()), {"a": [(100.0, 100.0)]})

    def test_a_row_of_a_target_without_a_usable_turn_or_time_is_counted(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            no_turn = call_row("a", 1, 100.0)
            del no_turn["keeper_turn_id"]
            no_time = call_row("a", 2, 100.0)
            del no_time["ts"]
            list_turn = call_row("a", 3, 100.0)
            list_turn["keeper_turn_id"] = [1]
            bool_turn = call_row("a", 4, 100.0)
            bool_turn["keeper_turn_id"] = True
            write_ledger(base, [no_turn, no_time, list_turn, bool_turn, call_row("b", 1, 100.0)])
            skipped = m.Skipped()
            self.assertEqual(read_spans(base, [DAY], frozenset({"a"}), skipped), {})
            self.assertEqual(skipped.unusable_rows, 4)

    def test_a_turn_id_written_as_text_is_a_turn(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            row = call_row("a", 1, 100.0)
            row["keeper_turn_id"] = "t-1"
            write_ledger(base, [row])
            self.assertEqual(read_spans(base, [DAY], frozenset({"a"}), m.Skipped()), {"a": [(100.0, 100.0)]})

    def test_a_day_without_a_ledger_file_is_listed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(base, [call_row("a", 1, 100.0)], name="02.jsonl")
            skipped = m.Skipped()
            read_spans(base, [DAY, datetime.date(2026, 11, 3), datetime.date(2026, 12, 1)], frozenset({"a"}), skipped)
            self.assertEqual(skipped.missing_days, ["2026-11-03", "2026-12-01"])

    def test_only_the_day_file_and_its_three_digit_segments_are_read(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(base, [call_row("a", 1, 100.0)], name="02.jsonl")
            write_ledger(base, [call_row("a", 2, 200.0)], name="02.007.jsonl")
            for ignored in ("02.5.jsonl", "02.0001.jsonl", "02.jsonl.bak", "102.jsonl", "03.jsonl"):
                write_ledger(base, [call_row("a", 9, 900.0)], name=ignored)
            spans = read_spans(base, [DAY], frozenset({"a"}), m.Skipped())
            self.assertEqual(spans, {"a": [(100.0, 100.0), (200.0, 200.0)]})

    def test_segments_and_bad_lines(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(base, [call_row("a", 1, 100.0)], name="02.jsonl")
            write_ledger(base, [call_row("a", 2, 200.0)], name="02.001.jsonl")
            path = base / ".masc" / "tool_calls" / "2026-11" / "02.jsonl"
            path.write_text(path.read_text(encoding="utf-8") + "not json\n[1]\n", encoding="utf-8")
            skipped = m.Skipped()
            spans = read_spans(base, [DAY], frozenset({"a"}), skipped)
            self.assertEqual(spans, {"a": [(100.0, 100.0), (200.0, 200.0)]})
            self.assertEqual(skipped.bad_lines, 2)


class SubmitCountReadTests(unittest.TestCase):
    def read(self, rows: Sequence[Mapping[str, object]], skipped: m.Skipped | None = None) -> dict[str, int]:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(base, rows)
            return m.read_ledger(base, [DAY], frozenset(), skipped or m.Skipped()).submit_counts

    def test_the_count_comes_from_the_output_of_a_delegate_call(self) -> None:
        self.assertEqual(self.read([submit_row("op-1", 1, 100.0), submit_row("op-2", 4, 101.0)]), {"op-1": 1, "op-2": 4})

    def test_other_tools_and_other_record_kinds_are_not_submits(self) -> None:
        other = submit_row("op-3", 2, 100.0)
        other["tool"] = "masc_keeper_delegate_status"
        note = submit_row("op-4", 2, 100.0)
        note["record_kind"] = "note"
        self.assertEqual(self.read([other, note]), {})

    def test_the_earliest_submit_of_one_operation_counts(self) -> None:
        rows = [submit_row("op-1", 5, 200.0), submit_row("op-1", 1, 100.0), submit_row("op-1", 9, 300.0)]
        self.assertEqual(self.read(rows), {"op-1": 1})

    def test_a_submit_without_an_operation_id_or_an_integer_count_is_counted(self) -> None:
        no_id = submit_row("", 1, 100.0)
        text_count = submit_row("op-1", "2", 101.0)
        bool_count = submit_row("op-2", True, 102.0)
        error_text = submit_row("op-3", 1, 103.0, output="error: target is unknown")
        list_output = submit_row("op-4", 1, 104.0, output="[1]")
        no_output = submit_row("op-5", 1, 105.0)
        del no_output["output"]
        no_time = submit_row("op-6", 1, 106.0)
        del no_time["ts"]
        float_count = submit_row("op-7", 1.5, 107.0)
        skipped = m.Skipped()
        rows = [no_id, text_count, bool_count, error_text, list_output, no_output, no_time, float_count]
        self.assertEqual(self.read(rows, skipped), {})
        self.assertEqual(skipped.unusable_submits, 8)

    def test_a_submit_of_a_non_target_keeper_still_counts_while_its_spans_do_not(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(base, [submit_row("op-1", 2, 100.0, keeper="sender")])
            ledger = m.read_ledger(base, [DAY], frozenset({"target"}), m.Skipped())
            self.assertEqual(ledger.submit_counts, {"op-1": 2})
            self.assertEqual(ledger.spans, {})


class SubmitBlockTests(unittest.TestCase):
    def block(self) -> dict[str, object]:
        found = [
            delegation(0.0, 0.0, 10.0, operation_id="quick-one"),
            delegation(0.0, 700.0, 800.0, operation_id="long-one"),
            delegation(0.0, 900.0, 950.0, operation_id="long-two"),
            delegation(0.0, 30.0, 60.0, operation_id="short-two"),
            delegation(0.0, 5000.0, 5100.0, operation_id="long-many"),
            delegation(0.0, 40.0, 60.0, operation_id="no-submit-row"),
            delegation(0.0, None, 5.0, state="cancelled", operation_id="never-started"),
        ]
        counts = {"quick-one": 1, "long-one": 1, "long-two": 2, "short-two": 2, "long-many": 7, "never-started": 1}
        return m.submit_block(found, counts)

    def test_started_and_joined_delegations_are_counted_apart(self) -> None:
        block = self.block()
        self.assertEqual(block["started"], 6)
        self.assertEqual(block["joined"], 5)

    def test_waits_are_grouped_by_the_count_with_a_cap(self) -> None:
        by_count = cast(dict[str, dict[str, object]], self.block()["by_queued_count"])
        self.assertEqual(list(by_count), ["1", "2", "3+"])
        self.assertEqual(by_count["1"]["n"], 2)
        self.assertEqual(by_count["1"]["long_waits"], 1)
        self.assertEqual(by_count["2"]["n"], 2)
        self.assertEqual(by_count["2"]["long_waits"], 1)
        self.assertEqual(by_count["3+"]["n"], 1)
        self.assertEqual(by_count["3+"]["max"], 5000.0)

    def test_long_waits_report_how_many_the_submit_showed_as_one_queued(self) -> None:
        long_waits = cast(dict[str, object], self.block()["long_waits"])
        self.assertEqual(long_waits["n"], 3)
        self.assertEqual(long_waits["queued_count_one"], 1)
        self.assertAlmostEqual(cast(float, long_waits["hours"]), (700.0 + 900.0 + 5000.0) / 3600.0)
        self.assertAlmostEqual(cast(float, long_waits["hours_queued_count_one"]), 700.0 / 3600.0)

    def test_a_wait_exactly_at_the_long_threshold_is_long_in_both_counts(self) -> None:
        block = m.submit_block([delegation(0.0, m.LONG_WAIT_S, operation_id="edge")], {"edge": 1})
        long_waits = cast(dict[str, object], block["long_waits"])
        self.assertEqual((long_waits["n"], long_waits["queued_count_one"]), (1, 1))
        by_count = cast(dict[str, dict[str, object]], block["by_queued_count"])
        self.assertEqual(by_count["1"]["long_waits"], 1)

    def test_a_count_of_two_is_not_a_count_of_one(self) -> None:
        block = m.submit_block([delegation(0.0, 900.0, operation_id="two")], {"two": 2})
        self.assertEqual(cast(dict[str, object], block["long_waits"])["queued_count_one"], 0)

    def test_the_cap_label_starts_at_the_cap(self) -> None:
        self.assertEqual([m.queued_count_label(count) for count in (0, 1, 2, 3, 4)], ["0", "1", "2", "3+", "3+"])

    def test_nothing_joined_gives_empty_groups(self) -> None:
        block = m.submit_block([delegation(0.0, 5.0)], {})
        self.assertEqual(block["joined"], 0)
        self.assertEqual(block["by_queued_count"], {})
        self.assertEqual(cast(dict[str, object], block["long_waits"])["n"], 0)


class MeasureTests(unittest.TestCase):
    def build(self, base: pathlib.Path) -> None:
        write_store(
            base,
            "busy",
            [
                ("flagged", source("s1"), "succeeded", at(1, 0, 10), at(1, 20, 0), at(1, 30, 0)),
                ("unflagged", source("s1"), "succeeded", at(5), at(5, 0, 1), at(5, 1)),
                ("dashboard", source(None), "succeeded", at(1), at(1), at(2)),
                ("next-day", source("s1"), "failed", at(2, day=3), at(2, 10, day=3), at(3, day=3)),
            ],
        )
        write_ledger(
            base,
            [
                call_row("busy", 1, at(1), 1_000_000.0),
                submit_row("flagged", 1, at(1, 0, 10)),
                submit_row("unflagged", 2, at(5)),
            ],
        )

    def result(self) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            self.build(base)
            return m.measure(base, DAY, datetime.date(2026, 11, 3), top=3)

    def test_the_whole_window_and_each_day(self) -> None:
        result = self.result()
        self.assertEqual(cast(dict[str, object], result["all"])["delegations"], 3)
        by_day = cast(dict[str, dict[str, object]], result["by_day"])
        self.assertEqual(list(by_day), ["2026-11-02", "2026-11-03"])
        self.assertEqual(by_day["2026-11-02"]["delegations"], 2)
        self.assertEqual(by_day["2026-11-03"]["states"], {"failed": 1})

    def test_the_flag_replay_uses_the_turn_spans_of_the_target(self) -> None:
        replay = cast(dict[str, object], self.result()["flag_replay"])
        self.assertEqual(replay["started"], 3)
        self.assertEqual(replay["flagged"], 1)

    def test_the_params_and_skips_are_reported(self) -> None:
        result = self.result()
        params = cast(dict[str, object], result["params"])
        self.assertEqual(params["from_date"], "2026-11-02")
        self.assertEqual(params["to_date"], "2026-11-03")
        self.assertEqual(params["long_wait_s"], m.LONG_WAIT_S)
        skipped = cast(dict[str, object], result["skipped"])
        self.assertEqual(skipped["unreadable_sources"], 0)
        self.assertEqual(skipped["negative_times"], 0)
        self.assertEqual(skipped["unusable_rows"], 0)
        self.assertEqual(skipped["missing_days"], ["2026-11-03"])

    def test_the_submit_counts_are_joined_by_operation_id(self) -> None:
        block = cast(dict[str, object], self.result()["submit_queued_count"])
        self.assertEqual(block["started"], 3)
        self.assertEqual(block["joined"], 2)
        long_waits = cast(dict[str, object], block["long_waits"])
        self.assertEqual(long_waits["n"], 1)
        self.assertEqual(long_waits["queued_count_one"], 1)

    def test_a_day_is_the_utc_day_of_creation_in_any_local_time_zone(self) -> None:
        with tempfile.TemporaryDirectory() as raw, local_timezone("Asia/Seoul"):
            base = pathlib.Path(raw)
            write_store(base, "t", [("late", source("s"), "succeeded", at(20), at(20, 0, 5), at(20, 1))])
            result = m.measure(base, DAY, DAY, top=3)
            self.assertEqual(list(cast(dict[str, object], result["by_day"])), ["2026-11-02"])

    def test_a_row_whose_times_run_backward_is_left_out_of_every_block_and_counted(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_store(
                base,
                "t",
                [
                    ("backward", source("s"), "succeeded", at(3), at(2), at(4)),
                    ("fine", source("s"), "succeeded", at(1), at(1, 0, 5), at(1, 1)),
                ],
            )
            result = m.measure(base, DAY, DAY, top=3)
            self.assertEqual(cast(dict[str, object], result["all"])["delegations"], 1)
            self.assertEqual(cast(dict[str, object], result["skipped"])["negative_times"], 1)

    def test_by_target_lists_the_busy_target(self) -> None:
        rows = cast(list[dict[str, object]], self.result()["by_target"])
        self.assertEqual([row["target"] for row in rows], ["busy"])


class MainTests(unittest.TestCase):
    def test_the_command_line_writes_the_result_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_store(base, "t", [("a", source("s"), "succeeded", at(1), at(1, 0, 5), at(1, 1))])
            out = base / "out.json"
            code = m.main(
                ["--base-path", str(base), "--from-date", "2026-11-02", "--to-date", "2026-11-02", "--json-out", str(out)]
            )
            self.assertEqual(code, 0)
            text = out.read_text(encoding="utf-8")
            self.assertTrue(text.endswith("}\n"))
            loaded = cast(dict[str, object], json.loads(text))
            self.assertEqual(cast(dict[str, object], loaded["all"])["delegations"], 1)

    def test_a_home_relative_base_path_is_expanded(self) -> None:
        with tempfile.TemporaryDirectory() as raw, mock.patch.dict(os.environ, {"HOME": raw}):
            write_store(pathlib.Path(raw) / "me", "t", [("a", source("s"), "succeeded", at(1), at(1, 0, 5), at(1, 1))])
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                code = m.main(["--base-path", "~/me", "--from-date", "2026-11-02", "--to-date", "2026-11-02"])
            self.assertEqual(code, 0)
            printed = cast(dict[str, object], json.loads(captured.getvalue()))
            self.assertEqual(cast(dict[str, object], printed["all"])["delegations"], 1)

    def test_a_first_day_after_the_last_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                m.main(["--base-path", raw, "--from-date", "2026-11-05", "--to-date", "2026-11-02"])

    def test_without_top_the_eight_slowest_targets_are_listed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            for index in range(1, 10):
                write_store(base, f"t{index}", [(f"op{index}", source("s"), "succeeded", at(1), at(1, 0, index), at(1, 1))])
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                code = m.main(["--base-path", str(base), "--from-date", "2026-11-02", "--to-date", "2026-11-02"])
            self.assertEqual(code, 0)
            printed = cast(dict[str, object], json.loads(captured.getvalue()))
            rows = cast(list[dict[str, object]], printed["by_target"])
            self.assertEqual([row["target"] for row in rows], [f"t{index}" for index in range(9, 1, -1)])

    def test_a_top_below_one_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                m.main(["--base-path", raw, "--from-date", "2026-11-02", "--to-date", "2026-11-02", "--top", "0"])

    def test_the_result_goes_to_stdout_without_a_json_out_path(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_store(base, "t", [("a", source("s"), "succeeded", at(1), at(1, 0, 5), at(1, 1))])
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                code = m.main(["--base-path", str(base), "--from-date", "2026-11-02", "--to-date", "2026-11-02"])
            self.assertEqual(code, 0)
            printed = cast(dict[str, object], json.loads(captured.getvalue()))
            self.assertEqual(cast(list[dict[str, object]], printed["by_target"])[0]["target"], "t")


if __name__ == "__main__":
    unittest.main()
