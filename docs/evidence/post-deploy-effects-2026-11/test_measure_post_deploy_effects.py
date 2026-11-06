from __future__ import annotations

import datetime
import json
import pathlib
import tempfile
import unittest
from collections.abc import Mapping, Sequence
from typing import cast

import measure_post_deploy_effects as m

UTC = datetime.timezone.utc


def at(day: int, hour: int = 0, minute: int = 0, second: int = 0) -> float:
    return datetime.datetime(2026, 11, day, hour, minute, second, tzinfo=UTC).timestamp()


DEPLOY = at(5, 8, 30, 30)
START = at(2)
UNTIL = at(6)
NOV_1 = datetime.date(2026, 11, 1)


def window(excluded: Sequence[datetime.date] = (), start: float = START) -> m.Window:
    return m.Window(start, DEPLOY, UNTIL, frozenset(excluded))


def call_row(
    ts: float,
    tool: str = "Execute",
    keeper: str = "k1",
    row_input: object = None,
    output: object = "",
    result_bytes: object = 0,
    record_kind: str = "tool_call",
) -> dict[str, object]:
    return {
        "record_kind": record_kind,
        "ts": ts,
        "tool": tool,
        "keeper": keeper,
        "input": {} if row_input is None else row_input,
        "output": output,
        "result_bytes": result_bytes,
    }


def call(
    ts: float,
    tool: str = "Execute",
    keeper: str = "k1",
    result_bytes: int = 0,
    contains: bool = False,
    state: str | None = None,
    operation: str | None = None,
) -> m.Call:
    return m.Call(ts, keeper, tool, result_bytes, contains, state, operation)


def request(captured_at: float, keeper: str, surface: int, tools: Sequence[str] = ()) -> m.Request:
    return m.Request(captured_at, keeper, surface, frozenset(tools))


def write_ledger(base: pathlib.Path, day: int, rows: Sequence[Mapping[str, object]], name: str | None = None) -> None:
    folder = base / ".masc" / "tool_calls" / "2026-11"
    folder.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(row) + "\n" for row in rows)
    (folder / (name or f"{day:02d}.jsonl")).write_text(text, encoding="utf-8")


def write_requests(base: pathlib.Path, keeper: str, day: int, rows: Sequence[Mapping[str, object]]) -> None:
    folder = base / ".masc" / "keepers" / keeper / "provider-inputs" / "2026-11"
    folder.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(row) + "\n" for row in rows)
    (folder / f"{day:02d}.jsonl").write_text(text, encoding="utf-8")


def request_row(captured_at: float, keeper: str, schemas: Sequence[tuple[str, int]]) -> dict[str, object]:
    return {
        "captured_at": captured_at,
        "keeper": keeper,
        "tool_schemas": [{"name": name, "artifact": {"bytes": size}} for name, size in schemas],
    }


class SideOfTests(unittest.TestCase):
    def test_the_deploy_instant_belongs_to_the_after_side(self) -> None:
        self.assertEqual(m.side_of(window(), DEPLOY), "after")

    def test_an_instant_just_before_the_deploy_belongs_to_the_before_side(self) -> None:
        self.assertEqual(m.side_of(window(), DEPLOY - 0.001), "before")

    def test_the_start_belongs_to_the_before_side_and_earlier_is_outside(self) -> None:
        self.assertEqual(m.side_of(window(), START), "before")
        self.assertIsNone(m.side_of(window(), START - 0.001))

    def test_until_is_outside_and_just_before_it_is_after(self) -> None:
        self.assertIsNone(m.side_of(window(), UNTIL))
        self.assertEqual(m.side_of(window(), UNTIL - 0.001), "after")

    def test_an_excluded_day_leaves_out_the_before_side_only(self) -> None:
        excluded = window([datetime.date(2026, 11, 3), datetime.date(2026, 11, 5)])
        self.assertIsNone(m.side_of(excluded, at(3, 12)))
        self.assertEqual(m.side_of(excluded, at(4, 12)), "before")
        self.assertIsNone(m.side_of(excluded, at(5, 1)))
        self.assertEqual(m.side_of(excluded, at(5, 9)), "after")


class SideHoursTests(unittest.TestCase):
    def test_the_before_side_counts_whole_days_and_the_part_of_the_deploy_day(self) -> None:
        hours = m.side_hours(window())
        self.assertAlmostEqual(hours["before"], 24 * 3 + (8.5 + 30 / 3600), places=9)
        self.assertAlmostEqual(hours["after"], 24 - (8.5 + 30 / 3600), places=9)

    def test_an_excluded_day_does_not_count(self) -> None:
        hours = m.side_hours(window([datetime.date(2026, 11, 3)]))
        self.assertAlmostEqual(hours["before"], 24 * 2 + (8.5 + 30 / 3600), places=9)

    def test_a_window_that_starts_inside_a_day_counts_from_the_start(self) -> None:
        hours = m.side_hours(window(start=at(4, 12)))
        self.assertAlmostEqual(hours["before"], 12 + 8.5 + 30 / 3600, places=9)

    def test_an_excluded_first_day_loses_its_hours(self) -> None:
        hours = m.side_hours(window([datetime.date(2026, 11, 2)]))
        self.assertAlmostEqual(hours["before"], 24 * 2 + (8.5 + 30 / 3600), places=9)

    def test_days_of_stops_at_the_day_before_a_midnight_until(self) -> None:
        self.assertEqual(m.days_of(window())[-1], datetime.date(2026, 11, 5))
        self.assertEqual(m.days_of(window())[0], datetime.date(2026, 11, 2))
        later = m.Window(START, DEPLOY, at(6, 0, 0, 1), frozenset())
        self.assertEqual(m.days_of(later)[-1], datetime.date(2026, 11, 6))


class ParseCallTests(unittest.TestCase):
    def parse(self, row: Mapping[str, object]) -> m.Call | None:
        return m.parse_call(row, m.Skipped())

    def test_a_row_of_another_kind_is_ignored_without_counting(self) -> None:
        skipped = m.Skipped()
        self.assertIsNone(m.parse_call(call_row(DEPLOY, record_kind="turn"), skipped))
        self.assertEqual(skipped.unusable_rows, 0)

    def test_a_tool_call_missing_a_field_is_counted_as_unusable(self) -> None:
        skipped = m.Skipped()
        row = call_row(DEPLOY)
        del row["keeper"]
        self.assertIsNone(m.parse_call(row, skipped))
        row = call_row(DEPLOY)
        row["tool"] = ""
        self.assertIsNone(m.parse_call(row, skipped))
        row = call_row(DEPLOY)
        row["ts"] = "not a number"
        self.assertIsNone(m.parse_call(row, skipped))
        self.assertEqual(skipped.unusable_rows, 3)

    def test_contains_needs_an_object_input_with_the_key(self) -> None:
        with_key = self.parse(call_row(DEPLOY, row_input={"contains": "x"}))
        without_key = self.parse(call_row(DEPLOY, row_input={"limit": 5}))
        not_object = self.parse(call_row(DEPLOY, row_input="contains"))
        assert with_key is not None and without_key is not None and not_object is not None
        self.assertTrue(with_key.contains)
        self.assertFalse(without_key.contains)
        self.assertFalse(not_object.contains)

    def test_result_bytes_must_be_an_integer(self) -> None:
        sizes = [
            (call_row(DEPLOY, result_bytes=12), 12),
            (call_row(DEPLOY, result_bytes="12"), 0),
            (call_row(DEPLOY, result_bytes=True), 0),
            (call_row(DEPLOY, result_bytes=1.5), 0),
        ]
        for row, expected in sizes:
            parsed = self.parse(row)
            assert parsed is not None
            self.assertEqual(parsed.result_bytes, expected)

    def test_only_a_delegate_status_call_gets_a_state(self) -> None:
        status = self.parse(call_row(DEPLOY, tool=m.DELEGATE_STATUS_TOOL, output='{"state":"Running"}'))
        other = self.parse(call_row(DEPLOY, tool="Execute", output='{"state":"Running"}'))
        assert status is not None and other is not None
        self.assertEqual(status.state, "Running")
        self.assertIsNone(other.state)

    def test_the_timestamp_is_kept_as_a_float(self) -> None:
        parsed = self.parse(call_row(DEPLOY + 0.25))
        assert parsed is not None
        self.assertEqual(parsed.ts, DEPLOY + 0.25)

    def test_a_bool_timestamp_is_not_a_time(self) -> None:
        row = call_row(DEPLOY)
        row["ts"] = True
        self.assertIsNone(self.parse(row))


class OperationTests(unittest.TestCase):
    def test_a_status_call_carries_the_operation_id_of_its_input(self) -> None:
        row = call_row(DEPLOY, tool=m.DELEGATE_STATUS_TOOL, row_input={"operation_id": "kmsg-1", "target": {}})
        parsed = m.parse_call(row, m.Skipped())
        assert parsed is not None
        self.assertEqual(parsed.operation, "kmsg-1")

    def test_other_tools_and_unreadable_ids_carry_none(self) -> None:
        other = m.parse_call(call_row(DEPLOY, tool="Execute", row_input={"operation_id": "kmsg-1"}), m.Skipped())
        missing = m.parse_call(call_row(DEPLOY, tool=m.DELEGATE_STATUS_TOOL, row_input={}), m.Skipped())
        number = m.parse_call(call_row(DEPLOY, tool=m.DELEGATE_STATUS_TOOL, row_input={"operation_id": 7}), m.Skipped())
        text = m.parse_call(call_row(DEPLOY, tool=m.DELEGATE_STATUS_TOOL, row_input="kmsg-1"), m.Skipped())
        assert other is not None and missing is not None and number is not None and text is not None
        self.assertIsNone(other.operation)
        self.assertIsNone(missing.operation)
        self.assertIsNone(number.operation)
        self.assertIsNone(text.operation)


class RepeatPollTests(unittest.TestCase):
    def poll(self, ts: float, operation: str | None, state: str = "Running", keeper: str = "a") -> m.Call:
        return call(ts, m.DELEGATE_STATUS_TOOL, keeper=keeper, state=state, operation=operation)

    def test_a_second_poll_with_the_same_state_is_a_repeat(self) -> None:
        block = m.repeat_polls([self.poll(1, "op"), self.poll(2, "op"), self.poll(3, "op")])
        self.assertEqual(block["polls"], 3)
        self.assertEqual(block["operations"], 1)
        self.assertEqual(block["repeat_polls"], 2)
        self.assertEqual(block["repeat_share"], 2 / 3)

    def test_a_changed_state_is_not_a_repeat_but_a_return_to_a_read_state_is(self) -> None:
        block = m.repeat_polls(
            [self.poll(1, "op", "Queued"), self.poll(2, "op", "Running"), self.poll(3, "op", "Running"), self.poll(4, "op", "Queued")]
        )
        self.assertEqual(block["repeat_polls"], 2)

    def test_polls_are_ordered_by_time_and_not_by_input_order(self) -> None:
        block = m.repeat_polls([self.poll(9, "op", "Succeeded"), self.poll(1, "op", "Running"), self.poll(5, "op", "Running")])
        self.assertEqual(block["repeat_polls"], 1)

    def test_keepers_and_operations_are_counted_apart(self) -> None:
        block = m.repeat_polls([self.poll(1, "op"), self.poll(2, "op", keeper="b"), self.poll(3, "other")])
        self.assertEqual(block["polls"], 3)
        self.assertEqual(block["operations"], 3)
        self.assertEqual(block["repeat_polls"], 0)

    def test_a_poll_without_an_operation_is_left_out(self) -> None:
        block = m.repeat_polls([self.poll(1, None), self.poll(2, None)])
        self.assertEqual(block["polls"], 0)
        self.assertEqual(block["operations"], 0)
        self.assertIsNone(block["repeat_share"])

    def test_a_missing_state_counts_as_no_state(self) -> None:
        block = m.repeat_polls([call(1, m.DELEGATE_STATUS_TOOL, operation="op"), call(2, m.DELEGATE_STATUS_TOOL, operation="op")])
        self.assertEqual(block["repeat_polls"], 1)


class DelegateStateTests(unittest.TestCase):
    def test_the_first_state_in_the_text_is_taken(self) -> None:
        self.assertEqual(m.delegate_state('{"operation_id":"a","state":"Queued","x":{"state":"Running"}}'), "Queued")

    def test_an_output_cut_before_the_state_has_no_state(self) -> None:
        self.assertEqual(m.delegate_state('{"operation_id":"a","source":{"channel":"ag'), m.NO_STATE)

    def test_an_error_text_has_no_state(self) -> None:
        self.assertEqual(m.delegate_state('{"error":"unknown_operation"}'), m.NO_STATE)

    def test_an_object_output_is_read_through_its_json(self) -> None:
        self.assertEqual(m.delegate_state({"state": "Succeeded"}), "Succeeded")

    def test_state_text_inside_an_escaped_string_is_not_a_state(self) -> None:
        text = json.dumps({"input": 'he said "state":"Running" once'})
        self.assertEqual(m.delegate_state(text), m.NO_STATE)


class ParseRequestTests(unittest.TestCase):
    def test_the_surface_sums_the_schema_bytes_and_names_the_tools(self) -> None:
        parsed = m.parse_request(request_row(DEPLOY, "k1", [("A", 100), ("B", 20)]))
        assert parsed is not None
        self.assertEqual(parsed.surface, 120)
        self.assertEqual(parsed.tools, frozenset({"A", "B"}))
        self.assertEqual(parsed.captured_at, DEPLOY)
        self.assertEqual(parsed.keeper, "k1")

    def test_a_schema_without_an_artifact_adds_no_bytes_and_keeps_its_name(self) -> None:
        row = request_row(DEPLOY, "k1", [("A", 100)])
        schemas = cast(list[object], row["tool_schemas"])
        schemas.append({"name": "C"})
        schemas.append("not an object")
        schemas.append({"name": "D", "artifact": {"bytes": "9"}})
        parsed = m.parse_request(row)
        assert parsed is not None
        self.assertEqual(parsed.surface, 100)
        self.assertEqual(parsed.tools, frozenset({"A", "C", "D"}))

    def test_a_row_without_the_fields_is_not_a_request(self) -> None:
        self.assertIsNone(m.parse_request({"keeper": "k1", "tool_schemas": []}))
        self.assertIsNone(m.parse_request({"captured_at": DEPLOY, "tool_schemas": []}))
        self.assertIsNone(m.parse_request({"captured_at": DEPLOY, "keeper": "k1"}))

    def test_a_request_with_no_schemas_has_a_zero_surface(self) -> None:
        parsed = m.parse_request({"captured_at": DEPLOY, "keeper": "k1", "tool_schemas": []})
        assert parsed is not None
        self.assertEqual(parsed.surface, 0)


class RankQuantileTests(unittest.TestCase):
    def test_a_half_rank_rounds_up(self) -> None:
        self.assertEqual(m.rank_quantile([1, 2, 3, 4], 0.5), 3)
        self.assertEqual(m.rank_quantile([1, 2, 3, 4, 5, 6], 0.5), 4)

    def test_an_odd_count_takes_the_middle_and_one_value_is_itself(self) -> None:
        self.assertEqual(m.rank_quantile([1, 2, 3], 0.5), 2)
        self.assertEqual(m.rank_quantile([7], 0.5), 7)

    def test_a_rank_below_half_rounds_down(self) -> None:
        self.assertEqual(m.rank_quantile([1, 2, 3, 4, 5], 0.1), 1)


class PerCallTests(unittest.TestCase):
    def test_no_calls_have_no_ratios(self) -> None:
        block = m.per_call([])
        self.assertEqual(block["calls"], 0)
        self.assertIsNone(block["bytes_per_call"])
        self.assertIsNone(block["contains_share"])

    def test_the_ratios_divide_by_the_call_count(self) -> None:
        block = m.per_call([call(DEPLOY, result_bytes=10, contains=True), call(DEPLOY, result_bytes=30)])
        self.assertEqual(block["calls"], 2)
        self.assertEqual(block["result_bytes"], 40)
        self.assertEqual(block["bytes_per_call"], 20.0)
        self.assertEqual(block["contains_calls"], 1)
        self.assertEqual(block["contains_share"], 0.5)

    def test_contains_and_plain_calls_have_their_own_means(self) -> None:
        calls = [
            call(DEPLOY, result_bytes=10, contains=True),
            call(DEPLOY, result_bytes=30, contains=True),
            call(DEPLOY, result_bytes=100),
            call(DEPLOY, result_bytes=300),
            call(DEPLOY, result_bytes=500),
        ]
        block = m.per_call(calls)
        self.assertEqual(block["contains_bytes_per_call"], 20.0)
        self.assertEqual(block["plain_bytes_per_call"], 300.0)

    def test_a_side_with_only_one_kind_has_no_mean_for_the_other(self) -> None:
        only_plain = m.per_call([call(DEPLOY, result_bytes=8)])
        self.assertIsNone(only_plain["contains_bytes_per_call"])
        self.assertEqual(only_plain["plain_bytes_per_call"], 8.0)
        only_contains = m.per_call([call(DEPLOY, result_bytes=8, contains=True)])
        self.assertEqual(only_contains["contains_bytes_per_call"], 8.0)
        self.assertIsNone(only_contains["plain_bytes_per_call"])


class WorkloadTests(unittest.TestCase):
    def test_rates_use_the_side_hours_and_count_distinct_keepers(self) -> None:
        block = m.workload(
            [call(DEPLOY, keeper="a", result_bytes=100), call(DEPLOY, keeper="a", result_bytes=50), call(DEPLOY, keeper="b")],
            hours=5.0,
        )
        self.assertEqual(block["calls"], 3)
        self.assertEqual(block["result_bytes"], 150)
        self.assertEqual(block["keepers"], 2)
        self.assertEqual(block["calls_per_hour"], 0.6)
        self.assertEqual(block["result_bytes_per_hour"], 30.0)

    def test_a_side_with_no_hours_has_no_rate(self) -> None:
        block = m.workload([call(DEPLOY)], hours=0.0)
        self.assertIsNone(block["calls_per_hour"])
        self.assertIsNone(block["result_bytes_per_hour"])


class ByStateTests(unittest.TestCase):
    def test_each_state_gets_its_own_size_summary(self) -> None:
        calls = [
            call(DEPLOY, result_bytes=100, state="Running"),
            call(DEPLOY, result_bytes=300, state="Running"),
            call(DEPLOY, result_bytes=200, state="Running"),
            call(DEPLOY, result_bytes=900, state="Succeeded"),
            call(DEPLOY, result_bytes=50, state=None),
        ]
        block = m.by_state(calls)
        self.assertEqual(sorted(block), ["Running", "Succeeded", m.NO_STATE])
        running = block["Running"]
        self.assertEqual(running["calls"], 3)
        self.assertEqual(running["result_bytes"], 600)
        self.assertEqual(running["mean"], 200.0)
        self.assertEqual(running["p50"], 200)
        self.assertEqual(running["min"], 100)
        self.assertEqual(running["max"], 300)
        self.assertEqual(block["Succeeded"]["calls"], 1)
        self.assertEqual(block[m.NO_STATE]["result_bytes"], 50)

    def test_no_calls_give_no_states(self) -> None:
        self.assertEqual(m.by_state([]), {})


class SurfaceTests(unittest.TestCase):
    def test_the_block_reports_median_mean_and_rides(self) -> None:
        requests = [
            request(DEPLOY, "a", 100, ["X"]),
            request(DEPLOY, "a", 200, ["X", "Y"]),
            request(DEPLOY, "b", 600, []),
        ]
        block = m.surface_block(requests, ["X", "Y", "Z"])
        self.assertEqual(block["requests"], 3)
        self.assertEqual(block["surface_median"], 200)
        self.assertEqual(block["surface_mean"], 300.0)
        self.assertEqual(block["rides"], {"X": 2, "Y": 1, "Z": 0})

    def test_an_even_count_takes_the_mean_of_the_two_middle_surfaces(self) -> None:
        block = m.surface_block([request(DEPLOY, "a", 100), request(DEPLOY, "a", 200)], [])
        self.assertEqual(block["surface_median"], 150.0)

    def test_no_requests_give_no_summary(self) -> None:
        block = m.surface_block([], ["X"])
        self.assertEqual(block["requests"], 0)
        self.assertIsNone(block["surface_median"])
        self.assertIsNone(block["surface_mean"])
        self.assertEqual(block["rides"], {"X": 0})


class KeeperDeltaTests(unittest.TestCase):
    def side(self, keeper: str, surface: int, count: int) -> list[m.Request]:
        return [request(DEPLOY, keeper, surface) for _ in range(count)]

    def test_the_delta_is_after_minus_before_per_keeper(self) -> None:
        before = self.side("a", 1000, 5) + self.side("b", 500, 5) + self.side("c", 700, 5)
        after = self.side("a", 900, 5) + self.side("b", 600, 5) + self.side("c", 500, 5)
        block = m.keeper_deltas(before, after)
        self.assertEqual(block["keepers"], 3)
        self.assertEqual(block["median_delta_bytes"], -100.0)
        self.assertEqual(block["keepers_smaller"], 2)

    def test_a_keeper_needs_enough_requests_on_both_sides(self) -> None:
        before = self.side("a", 1000, 5) + self.side("b", 1000, 4)
        after = self.side("a", 800, 5) + self.side("b", 100, 5) + self.side("c", 100, 5)
        block = m.keeper_deltas(before, after)
        self.assertEqual(block["keepers"], 1)
        self.assertEqual(block["median_delta_bytes"], -200.0)

    def test_the_threshold_is_the_constant(self) -> None:
        count = m.MIN_KEEPER_REQUESTS
        self.assertEqual(m.keeper_deltas(self.side("a", 10, count), self.side("a", 5, count))["keepers"], 1)
        self.assertEqual(m.keeper_deltas(self.side("a", 10, count - 1), self.side("a", 5, count))["keepers"], 0)
        self.assertEqual(m.keeper_deltas(self.side("a", 10, count), self.side("a", 5, count - 1))["keepers"], 0)

    def test_no_keepers_in_both_sides_give_no_median(self) -> None:
        block = m.keeper_deltas(self.side("a", 10, 5), self.side("b", 5, 5))
        self.assertEqual(block["keepers"], 0)
        self.assertIsNone(block["median_delta_bytes"])
        self.assertEqual(block["keepers_smaller"], 0)


class ByDayTests(unittest.TestCase):
    def test_the_deploy_day_has_one_row_per_side_and_other_tools_are_left_out(self) -> None:
        calls = [
            call(at(4, 12), "T", result_bytes=10),
            call(at(5, 1), "T", result_bytes=20),
            call(at(5, 9), "T", result_bytes=40, contains=True),
            call(at(5, 9), "Other", result_bytes=99),
        ]
        rows = m.by_day(calls, window(), ["T"])
        self.assertEqual(sorted(rows), ["T|2026-11-04|before", "T|2026-11-05|after", "T|2026-11-05|before"])
        self.assertEqual(rows["T|2026-11-05|before"]["bytes_per_call"], 20.0)
        self.assertEqual(rows["T|2026-11-05|after"]["contains_calls"], 1)

    def test_an_excluded_day_still_has_its_row_and_calls_outside_the_window_do_not(self) -> None:
        calls = [call(at(2, 3), "T", result_bytes=10), call(at(1, 3), "T", result_bytes=5), call(UNTIL, "T", result_bytes=7)]
        rows = m.by_day(calls, window([datetime.date(2026, 11, 2)]), ["T"])
        self.assertEqual(sorted(rows), ["T|2026-11-02|before"])


class FilesTests(unittest.TestCase):
    def test_segments_of_the_day_are_read_and_other_days_are_not(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(base, 5, [], name="05.jsonl")
            write_ledger(base, 5, [], name="05.001.jsonl")
            write_ledger(base, 5, [], name="05.2.jsonl")
            write_ledger(base, 5, [], name="15.jsonl")
            write_ledger(base, 5, [], name="05.001.jsonl.tmp")
            names = [path.name for path in m.tool_call_files(base, datetime.date(2026, 11, 5))]
            self.assertEqual(names, ["05.001.jsonl", "05.jsonl"])

    def test_a_missing_month_folder_has_no_files(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            self.assertEqual(m.tool_call_files(base, datetime.date(2026, 11, 5)), [])
            self.assertEqual(m.request_files(base, datetime.date(2026, 11, 5)), [])

    def test_request_files_come_from_every_keeper(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_requests(base, "a", 5, [])
            write_requests(base, "b", 5, [])
            write_requests(base, "b", 4, [])
            names = [path.parts[-4] for path in m.request_files(base, datetime.date(2026, 11, 5))]
            self.assertEqual(names, ["a", "b"])


class MeasureTests(unittest.TestCase):
    def build(self, base: pathlib.Path) -> None:
        status = m.DELEGATE_STATUS_TOOL
        write_ledger(
            base,
            1,
            [call_row(at(1, 5), tool="keeper_artifact_read", result_bytes=1000)],
        )
        write_ledger(
            base,
            4,
            [
                call_row(at(4, 5), tool=status, output='{"state":"Running","x":1}', result_bytes=2000, row_input={"operation_id": "op1"}),
                call_row(at(4, 6), tool=status, output='{"state":"Running","x":1}', result_bytes=3000, row_input={"operation_id": "op1"}),
                call_row(at(4, 7), tool="keeper_artifact_read", row_input={"contains": "a"}, result_bytes=500),
                call_row(at(4, 8), tool="keeper_artifact_read", result_bytes=1500, keeper="k2"),
            ],
        )
        write_ledger(
            base,
            5,
            [
                call_row(at(5, 9), tool=status, output='{"state":"Running"}', result_bytes=135, row_input={"operation_id": "op2"}),
                call_row(at(5, 10), tool="keeper_artifact_read", row_input={"contains": "b"}, result_bytes=100),
                call_row(at(5, 11), tool="Execute", keeper="k3", result_bytes=10),
                call_row(at(5, 7), tool="Execute", result_bytes=10),
                call_row(at(5, 7, 1), tool="Execute", record_kind="note"),
            ],
            name="05.001.jsonl",
        )
        (base / ".masc" / "tool_calls" / "2026-11" / "05.jsonl").write_text("not json\n[1]\n", encoding="utf-8")
        write_requests(
            base,
            "k1",
            4,
            [request_row(at(4, 12) + n, "k1", [("A", 100), ("BrowserSession", 50)]) for n in range(5)],
        )
        write_requests(
            base,
            "k1",
            5,
            [request_row(at(5, 7) + n, "k1", [("A", 100), ("BrowserSession", 50)]) for n in range(2)]
            + [request_row(at(5, 9) + n, "k1", [("A", 100)]) for n in range(5)],
        )

    def result(self, excluded: Sequence[datetime.date] = (NOV_1,)) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            self.build(base)
            return m.measure(base, window(excluded, start=at(1)), ("keeper_artifact_read",), ("BrowserSession",))

    def test_each_call_lands_on_the_side_of_its_instant_and_excluded_days_drop(self) -> None:
        tools = cast(dict[str, dict[str, dict[str, object]]], self.result()["tools"])
        artifact = tools["keeper_artifact_read"]
        self.assertEqual(artifact["before"]["calls"], 2)
        self.assertEqual(artifact["before"]["bytes_per_call"], 1000.0)
        self.assertEqual(artifact["before"]["contains_calls"], 1)
        self.assertEqual(artifact["after"]["calls"], 1)
        self.assertEqual(artifact["after"]["contains_share"], 1.0)

    def test_without_the_exclusion_the_first_day_joins_the_before_side(self) -> None:
        tools = cast(dict[str, dict[str, dict[str, object]]], self.result(excluded=())["tools"])
        self.assertEqual(tools["keeper_artifact_read"]["before"]["calls"], 3)

    def test_the_delegate_status_sizes_are_grouped_by_state_and_side(self) -> None:
        states = cast(dict[str, dict[str, dict[str, object]]], self.result()["delegate_status_by_state"])
        self.assertEqual(states["before"]["Running"]["calls"], 2)
        self.assertEqual(states["before"]["Running"]["mean"], 2500.0)
        self.assertEqual(states["after"]["Running"]["mean"], 135.0)

    def test_the_repeat_polls_are_counted_per_side(self) -> None:
        repeats = cast(dict[str, dict[str, object]], self.result()["delegate_status_repeats"])
        self.assertEqual(repeats["before"]["polls"], 2)
        self.assertEqual(repeats["before"]["repeat_polls"], 1)
        self.assertEqual(repeats["after"]["polls"], 1)
        self.assertEqual(repeats["after"]["repeat_polls"], 0)

    def test_the_workload_counts_every_tool_and_uses_the_side_hours(self) -> None:
        result = self.result()
        workload = cast(dict[str, dict[str, object]], result["workload"])
        self.assertEqual(workload["before"]["calls"], 5)
        self.assertEqual(workload["after"]["calls"], 3)
        self.assertEqual(workload["after"]["keepers"], 2)
        hours = cast(dict[str, float], result["hours"])
        self.assertAlmostEqual(cast(float, workload["after"]["calls_per_hour"]), 3 / hours["after"], places=9)
        self.assertAlmostEqual(cast(float, workload["before"]["calls_per_hour"]), 5 / hours["before"], places=9)

    def test_the_stored_requests_are_split_at_the_deploy_instant(self) -> None:
        surface = cast(dict[str, dict[str, object]], self.result()["schema_surface"])
        self.assertEqual(surface["before"]["requests"], 7)
        self.assertEqual(surface["after"]["requests"], 5)
        self.assertEqual(surface["before"]["rides"], {"BrowserSession": 7})
        self.assertEqual(surface["after"]["rides"], {"BrowserSession": 0})
        self.assertEqual(surface["before"]["surface_median"], 150)
        self.assertEqual(surface["after"]["surface_median"], 100)
        delta = surface["keeper_delta"]
        self.assertEqual(delta["median_delta_bytes"], -50.0)

    def test_unreadable_lines_and_missing_days_are_reported(self) -> None:
        skipped = cast(dict[str, object], self.result()["skipped"])
        self.assertEqual(skipped["bad_lines"], 2)
        self.assertEqual(skipped["unusable_rows"], 0)
        missing = cast(list[str], skipped["missing_days"])
        self.assertIn("tool_calls:2026-11-02", missing)
        self.assertIn("provider_inputs:2026-11-02", missing)
        self.assertNotIn("tool_calls:2026-11-04", missing)

    def test_by_day_keeps_the_excluded_first_day(self) -> None:
        rows = cast(dict[str, dict[str, object]], self.result()["by_day"])
        self.assertIn("keeper_artifact_read|2026-11-01|before", rows)
        self.assertEqual(rows["keeper_artifact_read|2026-11-05|after"]["calls"], 1)

    def test_the_params_name_the_window(self) -> None:
        params = cast(dict[str, object], self.result()["params"])
        self.assertEqual(params["deploy_at"], "2026-11-05T08:30:30+00:00")
        self.assertEqual(params["until"], "2026-11-06T00:00:00+00:00")
        self.assertEqual(params["excluded_days"], ["2026-11-01"])
        self.assertEqual(params["min_keeper_requests"], m.MIN_KEEPER_REQUESTS)


class MainTests(unittest.TestCase):
    def test_the_command_line_writes_the_result_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(base, 4, [call_row(at(4, 5), tool="keeper_artifact_read", result_bytes=10)])
            write_ledger(base, 5, [call_row(at(5, 9), tool="keeper_artifact_read", result_bytes=20)])
            out = base / "result.json"
            code = m.main(
                [
                    "--base-path",
                    str(base),
                    "--from-date",
                    "2026-11-04",
                    "--deploy-at",
                    "2026-11-05T08:30:30Z",
                    "--until",
                    "2026-11-06T00:00:00Z",
                    "--json-out",
                    str(out),
                ]
            )
            self.assertEqual(code, 0)
            loaded = cast(dict[str, object], json.loads(out.read_text(encoding="utf-8")))
            tools = cast(dict[str, dict[str, dict[str, object]]], loaded["tools"])
            self.assertEqual(tools["keeper_artifact_read"]["before"]["calls"], 1)
            self.assertEqual(tools["keeper_artifact_read"]["after"]["calls"], 1)
            self.assertEqual(sorted(tools), ["keeper_artifact_read", "masc_keeper_delegate_status", "masc_schedule_notes_list"])

    def test_a_deploy_instant_after_until_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(SystemExit):
                m.main(
                    [
                        "--base-path",
                        raw,
                        "--from-date",
                        "2026-11-04",
                        "--deploy-at",
                        "2026-11-07T00:00:00Z",
                        "--until",
                        "2026-11-06T00:00:00Z",
                    ]
                )

    def test_an_instant_without_an_offset_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(SystemExit):
                m.main(
                    [
                        "--base-path",
                        raw,
                        "--from-date",
                        "2026-11-04",
                        "--deploy-at",
                        "2026-11-05T08:30:30",
                        "--until",
                        "2026-11-06T00:00:00Z",
                    ]
                )


if __name__ == "__main__":
    unittest.main()
