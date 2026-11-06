"""Tests for measure_repeated_calls.py on a small synthetic Keeper store."""

from __future__ import annotations

import json
import os
import pathlib
import tempfile
import unittest
from datetime import UTC, date, datetime
from typing import cast

import measure_repeated_calls as m

JsonObject = dict[str, object]

DAY1 = 1_793_491_200.0  # 2026-11-01T00:00:00Z
DAY2 = DAY1 + 86_400.0
PROFILE_AGENT = "agent_core-glm-coding.glm-5.3-flash"

# One finished call: tool, input, result, error.
CallSpec = tuple[str, object, object, bool]


def call(tool: str, tool_input: object = "in", result: object = "out", error: bool = False) -> CallSpec:
    return (tool, tool_input, result, error)


def trace_rows(start: float, rounds: int, calls: list[CallSpec], agent: str | None, spacing: float) -> list[JsonObject]:
    rows: list[JsonObject] = [{"record_type": "run_started", "ts": start, "agent_name": agent}]
    for index in range(rounds):
        rows.append({"record_type": "hook_invoked", "ts": start + index, "hook_name": "before_turn_params"})
        rows.append({"record_type": "hook_invoked", "ts": start + index, "hook_name": "after_turn"})
    for index, (tool, tool_input, result, error) in enumerate(calls):
        begun = start + index * spacing
        use_id = f"call-{index}"
        rows.append({"record_type": "tool_execution_started", "ts": begun, "tool_use_id": use_id, "tool_name": tool, "tool_input": tool_input})
        rows.append(
            {
                "record_type": "tool_execution_finished",
                "ts": begun + spacing / 2,
                "tool_use_id": use_id,
                "tool_name": tool,
                "tool_result": result,
                "tool_error": error,
            }
        )
    return rows


def write_run(
    base: pathlib.Path,
    keeper: str,
    file: str,
    start: float,
    calls: list[CallSpec],
    rounds: int = 1,
    agent: str | None = PROFILE_AGENT,
    error: str | None = None,
    spacing: float = 2.0,
) -> None:
    folder = base / ".masc" / "keepers" / keeper / "raw-traces"
    folder.mkdir(parents=True, exist_ok=True)
    rows = trace_rows(start, rounds, calls, agent, spacing)
    end = start + max(len(calls), 1) * spacing
    rows.append({"record_type": "run_finished", "ts": end, "error": error})
    folder.joinpath(file).write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")


def obj(value: object) -> JsonObject:
    return cast("JsonObject", value)


def rows_of(value: object) -> list[JsonObject]:
    return cast("list[JsonObject]", value)


def measured_runs(*runs: list[CallSpec], window: tuple[date | None, date | None] = (None, None)) -> JsonObject:
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        for index, calls in enumerate(runs):
            write_run(base, "alpha", f"turn-{index}.jsonl", DAY1 + index * 1000, calls)
        return m.measure(base, window[0], window[1])


A = call("masc_board_list", {"limit": 2}, "same")
B = call("masc_board_list", {"limit": 3}, "same")
C = call("masc_board_list", {"limit": 2}, "changed")
D = call("Execute", {"argv": ["ls"]}, "same")


class RepeatTests(unittest.TestCase):
    def test_a_call_equal_in_tool_input_and_result_to_the_one_before_is_a_repeat(self) -> None:
        calls = obj(measured_runs([A, A, A])["calls"])
        self.assertEqual(calls["calls"], 3)
        self.assertEqual(calls["repeats"], 2)
        self.assertEqual(calls["share_of_calls"], round(2 / 3, 4))

    def test_another_input_another_result_or_another_tool_is_not_a_repeat(self) -> None:
        self.assertEqual(obj(measured_runs([A, B, C, D, A])["calls"])["repeats"], 0)

    def test_the_same_input_and_result_under_another_tool_is_not_a_repeat(self) -> None:
        self.assertEqual(obj(measured_runs([call("first", "i", "r"), call("second", "i", "r")])["calls"])["repeats"], 0)

    def test_the_call_right_before_is_the_only_one_compared(self) -> None:
        # A B A: the third call equals the first, but the second sits between them.
        self.assertEqual(obj(measured_runs([A, B, A])["calls"])["repeats"], 0)

    def test_the_order_of_keys_in_an_input_does_not_matter(self) -> None:
        first = call("t", {"a": 1, "b": [1, 2]}, "r")
        second = call("t", {"b": [1, 2], "a": 1}, "r")
        self.assertEqual(obj(measured_runs([first, second])["calls"])["repeats"], 1)

    def test_an_error_repeat_is_counted_among_the_repeats(self) -> None:
        failed = call("t", "i", "refused", error=True)
        calls = obj(measured_runs([failed, failed, failed, A, A])["calls"])
        self.assertEqual(calls["repeats"], 3)
        self.assertEqual(calls["repeats_that_were_errors"], 2)

    def test_an_error_that_does_not_repeat_the_call_before_is_not_a_repeated_error(self) -> None:
        calls = obj(measured_runs([A, call("t", "i", "refused", error=True)])["calls"])
        self.assertEqual(calls["repeats"], 0)
        self.assertEqual(calls["repeats_that_were_errors"], 0)

    def test_a_streak_does_not_cross_from_one_run_into_the_next(self) -> None:
        self.assertEqual(obj(measured_runs([A], [A])["calls"])["repeats"], 0)

    def test_a_finished_call_without_a_start_record_never_repeats(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            rows = trace_rows(DAY1, 1, [A, A], PROFILE_AGENT, 2.0)
            starts = [row for row in rows if row["record_type"] == "tool_execution_started"]
            rows.remove(starts[1])
            folder = base / ".masc" / "keepers" / "alpha" / "raw-traces"
            folder.mkdir(parents=True)
            folder.joinpath("turn-a.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            self.assertEqual(obj(m.measure(base, None, None)["calls"])["repeats"], 0)

    def test_two_finished_calls_that_both_lack_a_start_record_do_not_repeat_each_other(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            rows = [row for row in trace_rows(DAY1, 1, [A, A], PROFILE_AGENT, 2.0) if row["record_type"] != "tool_execution_started"]
            folder = base / ".masc" / "keepers" / "alpha" / "raw-traces"
            folder.mkdir(parents=True)
            folder.joinpath("turn-a.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            self.assertEqual(obj(m.measure(base, None, None)["calls"])["repeats"], 0)

    def test_a_record_without_an_input_or_a_result_equals_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            rows = trace_rows(DAY1, 1, [A, A], PROFILE_AGENT, 2.0)
            for row in rows:
                row.pop("tool_result", None)
            folder = base / ".masc" / "keepers" / "alpha" / "raw-traces"
            folder.mkdir(parents=True)
            folder.joinpath("turn-a.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            self.assertEqual(obj(m.measure(base, None, None)["calls"])["repeats"], 0)

    def test_runs_without_a_finished_call_count_as_runs_only(self) -> None:
        calls = obj(measured_runs([], [A, A])["calls"])
        self.assertEqual(calls["runs"], 2)
        self.assertEqual(calls["runs_with_calls"], 1)

    def test_rounds_are_the_before_turn_params_records(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a.jsonl", DAY1, [A, A], rounds=7)
            self.assertEqual(obj(m.measure(base, None, None)["calls"])["rounds"], 7)


class AggregateTests(unittest.TestCase):
    def test_by_tool_lists_the_tools_with_a_repeat_biggest_first(self) -> None:
        by_tool = rows_of(measured_runs([A, A, A, D, D, D, D, D, B])["by_tool"])
        self.assertEqual([row["tool"] for row in by_tool], ["Execute", "masc_board_list"])
        self.assertEqual(by_tool[0]["calls"], 5)
        self.assertEqual(by_tool[0]["repeats"], 4)
        self.assertEqual(by_tool[1]["calls"], 4)
        self.assertEqual(by_tool[1]["repeats"], 2)

    def test_a_tool_without_a_repeat_is_not_listed(self) -> None:
        self.assertEqual(rows_of(measured_runs([A, B, D])["by_tool"]), [])

    def test_streaks_are_counted_with_their_length_and_bands(self) -> None:
        lengths = [2, 5, 12, 120]
        run: list[CallSpec] = []
        for index, length in enumerate(lengths):
            run.extend([call("t", "i", f"r{index}")] * length)
        streaks = obj(measured_runs(run)["streaks"])
        self.assertEqual(streaks["count"], 4)
        self.assertEqual(obj(streaks["length"])["max"], 120.0)
        self.assertEqual(obj(streaks["length"])["p50"], 12.0)
        bands = obj(streaks["by_length"])
        self.assertEqual(bands["2-9"], {"streaks": 2, "repeats": 1 + 4})
        self.assertEqual(bands["10-99"], {"streaks": 1, "repeats": 11})
        self.assertEqual(bands["100+"], {"streaks": 1, "repeats": 119})

    def test_a_streak_lasts_from_the_first_start_to_the_last_finish(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a.jsonl", DAY1, [A, A, A], spacing=3600.0)
            # The calls start at 0 h, 1 h and 2 h; the last finishes at 2.5 h.
            self.assertEqual(obj(m.measure(base, None, None)["streaks"])["wall_hours"], 2.5)

    def test_no_streak_gives_a_count_of_zero(self) -> None:
        self.assertEqual(measured_runs([A, B])["streaks"], {"count": 0})

    def test_the_runs_with_the_most_repeats_come_first_with_their_profile_and_end(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a.jsonl", DAY1, [A, A], error="Rate limited: Usage limit reached for 5 hour")
            write_run(base, "beta", "turn-b.jsonl", DAY2, [D, D, D, D], agent="agent_core-glm-coding.glm-5-3", rounds=4)
            write_run(base, "gamma", "turn-c.jsonl", DAY2, [A, B])
            top = rows_of(m.measure(base, None, None)["runs_with_the_most_repeats"])
        self.assertEqual([row["keeper"] for row in top], ["beta", "alpha"])
        self.assertEqual(top[0]["repeats"], 3)
        self.assertEqual(top[0]["profile"], "glm-5-3")
        self.assertEqual(top[0]["rounds"], 4)
        self.assertEqual(top[0]["top_repeated_tool"], "Execute")
        self.assertEqual(top[0]["day"], "2026-11-02")
        # Execute repeats three times with a 4-byte result; the first call of the streak is not a repeat.
        self.assertEqual(top[0]["repeated_result_bytes"], 3 * 4)
        self.assertEqual(top[1]["repeated_result_bytes"], 4)
        self.assertEqual(top[1]["profile"], "glm-5.3-flash")
        self.assertTrue(str(top[1]["ended_by"]).startswith("Rate limited"))

    def test_at_most_eight_runs_are_listed(self) -> None:
        runs = [[call(f"t{index}", "i", "r")] * 2 for index in range(10)]
        self.assertEqual(len(rows_of(measured_runs(*runs)["runs_with_the_most_repeats"])), 8)

    def test_by_profile_counts_calls_and_repeats_per_profile(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a.jsonl", DAY1, [A, A, B])
            write_run(base, "beta", "turn-b.jsonl", DAY1, [D, D], agent=None)
            profiles = {row["profile"]: row for row in rows_of(m.measure(base, None, None)["by_profile"])}
        self.assertEqual(obj(profiles["glm-5.3-flash"])["calls"], 3)
        self.assertEqual(obj(profiles["glm-5.3-flash"])["repeats"], 1)
        self.assertEqual(obj(profiles["unrecorded"])["repeats"], 1)


class ResultBytesTests(unittest.TestCase):
    def test_a_result_is_measured_by_the_utf8_length_of_its_logged_text(self) -> None:
        # "가나다" is 9 bytes. The object is logged as text with its characters kept: 12 bytes.
        calls = obj(measured_runs([call("t", "i", "가나다"), call("u", "i", {"k": "가"})])["calls"])
        self.assertEqual(calls["result_bytes"], 9 + 12)

    def test_the_bytes_of_repeats_are_those_of_the_repeated_results_only(self) -> None:
        small = call("masc_board_list", {"limit": 2}, "abcd")
        large = call("Execute", {"argv": ["ls"]}, "x" * 13)
        result = measured_runs([small, small, small, large, large])
        calls = obj(result["calls"])
        self.assertEqual(calls["result_bytes"], 3 * 4 + 2 * 13)
        self.assertEqual(calls["repeated_result_bytes"], 2 * 4 + 13)
        self.assertEqual(calls["share_of_result_bytes"], round(21 / 38, 4))
        by_tool = {row["tool"]: row for row in rows_of(result["by_tool"])}
        self.assertEqual(obj(by_tool["masc_board_list"])["result_bytes"], 12)
        self.assertEqual(obj(by_tool["masc_board_list"])["repeated_result_bytes"], 8)
        self.assertEqual(obj(by_tool["Execute"])["result_bytes"], 26)
        self.assertEqual(obj(by_tool["Execute"])["repeated_result_bytes"], 13)

    def test_by_profile_carries_the_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a.jsonl", DAY1, [call("t", "i", "abcd")] * 3)
            write_run(base, "beta", "turn-b.jsonl", DAY1, [call("t", "i", "xy")] * 2, agent=None)
            profiles = {row["profile"]: row for row in rows_of(m.measure(base, None, None)["by_profile"])}
        self.assertEqual(obj(profiles["glm-5.3-flash"])["result_bytes"], 12)
        self.assertEqual(obj(profiles["glm-5.3-flash"])["repeated_result_bytes"], 8)
        self.assertEqual(obj(profiles["unrecorded"])["result_bytes"], 4)
        self.assertEqual(obj(profiles["unrecorded"])["repeated_result_bytes"], 2)

    def test_a_record_without_a_result_has_no_size(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            rows = trace_rows(DAY1, 1, [call("t", "i", "abcd")] * 2, PROFILE_AGENT, 2.0)
            rows[-1].pop("tool_result")
            folder = base / ".masc" / "keepers" / "alpha" / "raw-traces"
            folder.mkdir(parents=True)
            folder.joinpath("turn-a.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            calls = obj(m.measure(base, None, None)["calls"])
        self.assertEqual(calls["result_bytes"], 4)
        self.assertEqual(calls["repeated_result_bytes"], 0)

    def test_a_lone_surrogate_in_a_result_is_measured_and_does_not_stop_the_read(self) -> None:
        # A preview cut inside an emoji leaves half of a surrogate pair: 3 bytes with the byte before it.
        calls = obj(measured_runs([call("t", "i", "a\ud83d"), call("t", "i", "a\ud83d")])["calls"])
        self.assertEqual(calls["result_bytes"], 2 * (1 + 3))
        self.assertEqual(calls["repeated_result_bytes"], 1 + 3)

    def test_the_repeated_calls_are_the_ones_the_streaks_count(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a.jsonl", DAY1, [A, A, B, B, B, C, A, A])
            runs = m.read_runs(base, m.Unreadable())
        self.assertEqual(len(m.repeated_calls(runs[0].calls)), sum(s.length - 1 for s in m.streaks_of(runs[0].calls)))
        self.assertEqual(len(m.repeated_calls(runs[0].calls)), 4)


class StoreTests(unittest.TestCase):
    def test_a_window_keeps_the_runs_that_start_inside_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a.jsonl", DAY1 + 100, [A, A])
            write_run(base, "alpha", "turn-b.jsonl", DAY2 + 100, [D, D, D])
            day2 = date(2026, 11, 2)
            calls = obj(m.measure(base, day2, day2)["calls"])
        self.assertEqual(calls["runs"], 1)
        self.assertEqual(calls["repeats"], 2)

    def test_the_window_reports_the_days_of_the_first_and_last_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a.jsonl", DAY1 + 100, [A])
            write_run(base, "alpha", "turn-b.jsonl", DAY2 + 100, [A])
            window = obj(m.measure(base, None, None)["window"])
        self.assertEqual(window, {"first_run_utc": "2026-11-01", "last_run_utc": "2026-11-02"})

    def test_an_empty_store_measures_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = m.measure(pathlib.Path(directory), None, None)
        self.assertEqual(obj(result["calls"])["calls"], 0)
        self.assertEqual(obj(result["window"]), {"first_run_utc": None, "last_run_utc": None})

    def test_a_line_that_is_not_a_json_object_is_counted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a.jsonl", DAY1, [A, A])
            trace = base / ".masc" / "keepers" / "alpha" / "raw-traces" / "turn-a.jsonl"
            trace.write_text(trace.read_text(encoding="utf-8") + "not json\n[1, 2]\n", encoding="utf-8")
            result = m.measure(base, None, None)
        self.assertEqual(result["unreadable_lines"], 2)
        self.assertEqual(obj(result["calls"])["repeats"], 1)

    def test_a_trace_that_is_gone_after_listing_is_counted_not_fatal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a.jsonl", DAY1, [A, A])
            traces = base / ".masc" / "keepers" / "alpha" / "raw-traces"
            os.symlink(base / "nowhere", traces / "turn-gone.jsonl")
            result = m.measure(base, None, None)
        self.assertEqual(result["unreadable_files"], 1)
        self.assertEqual(obj(result["calls"])["runs"], 1)

    def test_the_read_time_names_the_minute_in_utc(self) -> None:
        stamp = str(measured_runs([A])["read_at_utc"])
        self.assertEqual(datetime.strptime(stamp, "%Y-%m-%dT%H:%MZ").replace(tzinfo=UTC).tzinfo, UTC)


if __name__ == "__main__":
    unittest.main()
