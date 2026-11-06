"""Tests for measure_argument_adoption.py on a small synthetic tool-call ledger."""

from __future__ import annotations

import argparse
import json
import pathlib
import tempfile
import unittest
from datetime import date
from typing import cast

import measure_argument_adoption as m

JsonObject = dict[str, object]

DAY1 = 1_793_491_200.0  # 2026-11-01T00:00:00Z
DAY2 = DAY1 + 86_400.0
HOUR = 3600.0
TOOL = "keeper_artifact_read"


def row(
    ts: object,
    tool: str = TOOL,
    keeper: str = "alpha",
    input_value: object = None,
    size: object = 100,
) -> JsonObject:
    fields: JsonObject = {"ts": ts, "record_kind": "tool_call", "tool": tool, "keeper": keeper, "input": input_value}
    if size is not None:
        fields["result_bytes"] = size
    return fields


def with_contains(ts: float, size: object = 10, keeper: str = "alpha") -> JsonObject:
    return row(ts, keeper=keeper, input_value={"contains": "needle"}, size=size)


def write_ledger(base: pathlib.Path, day: str, file: str, rows: list[JsonObject], extra: list[str] | None = None) -> None:
    month, number = day[:7], day[8:10]
    folder = base / ".masc" / "tool_calls" / month
    folder.mkdir(parents=True, exist_ok=True)
    stem = f"{number}.jsonl" if file == "live" else f"{number}.{file}.jsonl"
    lines = [json.dumps(item) for item in rows] + (extra or [])
    folder.joinpath(stem).write_text("\n".join(lines) + "\n", encoding="utf-8")


def obj(value: object) -> JsonObject:
    return cast("JsonObject", value)


def windows_of(result: JsonObject) -> list[JsonObject]:
    return cast("list[JsonObject]", result["windows"])


def run(rows_day1: list[JsonObject], split: float | None = DAY1 + 10 * HOUR, until: float = DAY1 + 20 * HOUR) -> JsonObject:
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        write_ledger(base, "2026-11-01", "live", rows_day1)
        return m.measure(base, TOOL, "contains", DAY1, split, until)


class CarriesTests(unittest.TestCase):
    def test_a_value_that_is_neither_null_nor_an_empty_string_is_carried(self) -> None:
        self.assertTrue(m.carries({"contains": "x"}, "contains"))
        self.assertTrue(m.carries({"contains": False}, "contains"))
        self.assertTrue(m.carries({"contains": 0}, "contains"))
        self.assertTrue(m.carries({"contains": []}, "contains"))

    def test_null_empty_missing_and_a_non_object_input_are_not_carried(self) -> None:
        self.assertFalse(m.carries({"contains": None}, "contains"))
        self.assertFalse(m.carries({"contains": ""}, "contains"))
        self.assertFalse(m.carries({"other": "x"}, "contains"))
        self.assertFalse(m.carries("contains", "contains"))
        self.assertFalse(m.carries(None, "contains"))


class DaysTests(unittest.TestCase):
    def test_a_range_holds_the_days_of_its_instants_and_not_the_day_its_end_opens(self) -> None:
        day1, day2, day3 = date(2026, 11, 1), date(2026, 11, 2), date(2026, 11, 3)
        self.assertEqual(m.days_between(DAY1, DAY2), [day1])
        self.assertEqual(m.days_between(DAY1, DAY2 + 1), [day1, day2])
        self.assertEqual(m.days_between(DAY1 + 5, DAY1 + 10), [day1])
        self.assertEqual(m.days_between(DAY1 + HOUR, DAY2 + 86_400.0), [day1, day2])
        self.assertEqual(m.days_between(DAY1, DAY2 + 86_400.0 + 1), [day1, day2, day3])

    def test_an_empty_range_holds_no_day(self) -> None:
        self.assertEqual(m.days_between(DAY1, DAY1), [])


class WindowTests(unittest.TestCase):
    def test_a_call_at_the_split_belongs_to_the_window_after_it(self) -> None:
        before, after = windows_of(
            run([row(DAY1), row(DAY1 + 10 * HOUR - 1), row(DAY1 + 10 * HOUR), row(DAY1 + 20 * HOUR - 1)])
        )
        self.assertEqual(before["calls"], 2)
        self.assertEqual(after["calls"], 2)

    def test_a_call_at_the_end_or_before_the_start_is_outside_every_window(self) -> None:
        before, after = windows_of(run([row(DAY1 - 1), row(DAY1 + 20 * HOUR)]))
        self.assertEqual((before["calls"], after["calls"]), (0, 0))

    def test_another_tool_is_ignored(self) -> None:
        before, _ = windows_of(run([row(DAY1 + 1, tool="Execute"), row(DAY1 + 2)]))
        self.assertEqual(before["calls"], 1)

    def test_a_window_without_calls_reports_only_its_extent(self) -> None:
        _, after = windows_of(run([row(DAY1 + 1)]))
        self.assertEqual(after, {"label": "after", "from_utc": "2026-11-01T10:00:00Z", "until_utc": "2026-11-01T20:00:00Z", "hours": 10.0, "calls": 0})

    def test_without_a_split_there_is_one_window_called_all(self) -> None:
        windows = windows_of(run([row(DAY1 + 1), row(DAY1 + 15 * HOUR)], split=None))
        self.assertEqual([w["label"] for w in windows], ["all"])
        self.assertEqual(windows[0]["calls"], 2)
        self.assertEqual(windows[0]["hours"], 20.0)

    def test_rotated_segments_and_the_next_day_are_read(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_ledger(base, "2026-11-01", "001", [row(DAY1 + 100)])
            write_ledger(base, "2026-11-01", "live", [row(DAY1 + 200)])
            write_ledger(base, "2026-11-02", "live", [row(DAY2 + 100)])
            result = m.measure(base, TOOL, "contains", DAY1, None, DAY2 + HOUR)
        self.assertEqual(windows_of(result)[0]["calls"], 3)

    def test_a_range_ending_at_midnight_does_not_read_the_next_day(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_ledger(base, "2026-11-01", "live", [row(DAY1 + 100)])
            write_ledger(base, "2026-11-02", "live", [row(DAY2)])
            result = m.measure(base, TOOL, "contains", DAY1, None, DAY2)
        self.assertEqual(windows_of(result)[0]["calls"], 1)

    def test_a_file_of_a_day_outside_the_range_is_not_opened(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_ledger(base, "2026-11-01", "live", [row(DAY1 + 100)])
            write_ledger(base, "2026-11-02", "live", [row(DAY2)], extra=["not json"])
            result = m.measure(base, TOOL, "contains", DAY1, None, DAY2)
        self.assertEqual(result["unreadable_lines"], 0)

    def test_a_call_at_the_end_of_the_range_is_not_a_first_use(self) -> None:
        self.assertIsNone(run([with_contains(DAY1 + 20 * HOUR)])["first_use_utc"])

    def test_a_missing_day_is_an_empty_day(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = m.measure(pathlib.Path(directory), TOOL, "contains", DAY1, None, DAY2 + HOUR)
        self.assertEqual(windows_of(result)[0]["calls"], 0)


class StatTests(unittest.TestCase):
    def test_the_share_and_the_rate_use_the_calls_inside_the_window(self) -> None:
        _, after = windows_of(run([row(DAY1 + 11 * HOUR), with_contains(DAY1 + 12 * HOUR), with_contains(DAY1 + 13 * HOUR), row(DAY1 + 14 * HOUR)]))
        self.assertEqual(after["calls"], 4)
        self.assertEqual(after["calls_with_argument"], 2)
        self.assertEqual(after["share_with_argument"], 0.5)
        self.assertEqual(after["calls_per_hour"], 0.4)

    def test_result_bytes_are_totalled_and_averaged_with_and_without_the_argument(self) -> None:
        sizes = [100, 200, 300, 400, 1000]
        rows = [row(DAY1 + 11 * HOUR, size=sizes[0]), row(DAY1 + 12 * HOUR, size=sizes[1]), row(DAY1 + 13 * HOUR, size=sizes[2])]
        rows += [with_contains(DAY1 + 14 * HOUR, size=sizes[3]), with_contains(DAY1 + 15 * HOUR, size=sizes[4])]
        _, after = windows_of(run(rows))
        stats = obj(after["result_bytes"])
        self.assertEqual(stats["total"], 2000)
        self.assertEqual(stats["per_hour"], 200.0)
        self.assertEqual(stats["mean"], 400.0)
        self.assertEqual(stats["p50"], 300)
        self.assertEqual(stats["p99"], 1000)
        self.assertEqual(stats["mean_with_argument"], 700.0)
        self.assertEqual(stats["mean_without_argument"], 200.0)

    def test_a_call_without_a_usable_size_counts_as_a_call_but_not_as_bytes(self) -> None:
        rows = [row(DAY1 + 11 * HOUR, size=100), row(DAY1 + 12 * HOUR, size=None), row(DAY1 + 13 * HOUR, size="big"), row(DAY1 + 14 * HOUR, size=-5), row(DAY1 + 15 * HOUR, size=True)]
        _, after = windows_of(run(rows))
        self.assertEqual(after["calls"], 5)
        self.assertEqual(after["calls_without_size"], 4)
        self.assertEqual(obj(after["result_bytes"])["total"], 100)

    def test_a_window_whose_calls_all_lack_a_size_has_no_byte_figures(self) -> None:
        _, after = windows_of(run([row(DAY1 + 11 * HOUR, size=None)]))
        self.assertNotIn("result_bytes", after)
        self.assertEqual(after["calls"], 1)

    def test_no_call_with_the_argument_leaves_its_mean_empty(self) -> None:
        _, after = windows_of(run([row(DAY1 + 11 * HOUR, size=100)]))
        stats = obj(after["result_bytes"])
        self.assertIsNone(stats["mean_with_argument"])
        self.assertEqual(stats["mean_without_argument"], 100.0)

    def test_keepers_that_carried_the_argument_are_listed_most_calls_first_then_by_name(self) -> None:
        rows = [with_contains(DAY1 + 11 * HOUR, keeper="zed"), with_contains(DAY1 + 12 * HOUR, keeper="amy")]
        rows += [with_contains(DAY1 + (13 + i) * HOUR, keeper="bob") for i in range(3)]
        rows += [row(DAY1 + 17 * HOUR, keeper="plain")]
        _, after = windows_of(run(rows))
        using = obj(after["keepers_using_argument"])
        self.assertEqual(using["count"], 3)
        self.assertEqual(using["top"], [{"keeper": "bob", "calls": 3}, {"keeper": "amy", "calls": 1}, {"keeper": "zed", "calls": 1}])
        self.assertEqual(after["keepers"], 4)

    def test_at_most_five_keepers_are_listed(self) -> None:
        rows = [with_contains(DAY1 + 11 * HOUR + index, keeper=f"k{index}") for index in range(7)]
        _, after = windows_of(run(rows))
        using = obj(after["keepers_using_argument"])
        self.assertEqual(using["count"], 7)
        self.assertEqual(len(cast("list[object]", using["top"])), 5)

    def test_a_keeper_that_is_not_a_string_is_named_with_a_question_mark(self) -> None:
        item = with_contains(DAY1 + 11 * HOUR)
        item["keeper"] = 7
        _, after = windows_of(run([item]))
        self.assertEqual(obj(after["keepers_using_argument"])["top"], [{"keeper": "?", "calls": 1}])

    def test_the_first_use_is_the_earliest_call_that_carries_the_argument_in_the_range(self) -> None:
        result = run([row(DAY1 + 1), with_contains(DAY1 + 14 * HOUR), with_contains(DAY1 + 11 * HOUR)])
        self.assertEqual(result["first_use_utc"], "2026-11-01T11:00:00Z")

    def test_no_use_gives_no_first_use(self) -> None:
        self.assertIsNone(run([row(DAY1 + 1)])["first_use_utc"])


class UnreadableTests(unittest.TestCase):
    def test_lines_that_are_not_json_objects_are_counted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_ledger(base, "2026-11-01", "live", [row(DAY1 + 100)], extra=["not json", "[1, 2]", "7"])
            result = m.measure(base, TOOL, "contains", DAY1, None, DAY1 + HOUR)
        self.assertEqual(result["unreadable_lines"], 3)
        self.assertEqual(windows_of(result)[0]["calls"], 1)

    def test_a_row_of_the_tool_without_a_timestamp_is_counted_and_belongs_to_no_window(self) -> None:
        rows = [row(None), row("noon"), row(float("inf")), row(True), row(DAY1 + 100), row(None, tool="Execute")]
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_ledger(base, "2026-11-01", "live", rows)
            result = m.measure(base, TOOL, "contains", DAY1, None, DAY1 + HOUR)
        self.assertEqual(result["rows_without_timestamp"], 4)
        self.assertEqual(windows_of(result)[0]["calls"], 1)


class InstantTests(unittest.TestCase):
    def test_a_utc_instant_is_read_to_the_second(self) -> None:
        self.assertEqual(m.parse_instant("2026-11-01T00:00:00Z"), DAY1)
        self.assertEqual(m.parse_instant("2026-11-01T01:02:03Z"), DAY1 + 3723)

    def test_an_instant_without_the_utc_mark_or_a_date_only_is_refused(self) -> None:
        for text in ("2026-11-01T00:00:00", "2026-11-01", "2026-11-01T00:00:00+09:00", "yesterday"):
            with self.assertRaises(argparse.ArgumentTypeError):
                m.parse_instant(text)

    def test_iso_names_the_second_in_utc(self) -> None:
        self.assertEqual(m.iso(DAY1 + 3723.9), "2026-11-01T01:02:03Z")


if __name__ == "__main__":
    unittest.main()
