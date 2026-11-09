"""Tests for measure_runs_and_arrivals.py on a small synthetic Keeper store."""

from __future__ import annotations

import json
import os
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
from datetime import UTC, date, datetime
from typing import cast

import measure_runs_and_arrivals as m

JsonObject = dict[str, object]

DAY1 = 1_793_491_200.0  # 2026-11-01T00:00:00Z
DAY2 = DAY1 + 86_400.0
PROFILE_AGENT = "agent_core-glm-coding.glm-5.3-flash"


def trace_rows(
    start: float, rounds: int, tools: list[str], agent: str | None, spacing: float, hooks: list[str]
) -> list[JsonObject]:
    rows: list[JsonObject] = [{"record_type": "run_started", "ts": start, "agent_name": agent}]
    rows.extend({"record_type": "hook_invoked", "ts": start, "hook_name": hook} for hook in hooks)
    for index in range(rounds):
        rows.append({"record_type": "hook_invoked", "ts": start + index * spacing, "hook_name": "before_turn_params"})
        rows.append({"record_type": "hook_invoked", "ts": start + index * spacing, "hook_name": "after_turn"})
    for name in tools:
        rows.append({"record_type": "tool_execution_started", "ts": start + 1, "tool_name": name})
    return rows


def write_run(
    base: pathlib.Path,
    keeper: str,
    file: str,
    start: float,
    end: float,
    rounds: int,
    tools: list[str],
    agent: str | None = PROFILE_AGENT,
    error: str | None = None,
    spacing: float = 1.0,
    hooks: list[str] | None = None,
    extra: list[JsonObject] | None = None,
) -> None:
    folder = base / ".masc" / "keepers" / keeper / "raw-traces"
    folder.mkdir(parents=True, exist_ok=True)
    rows = trace_rows(start, rounds, tools, agent, spacing, hooks or [])
    rows.extend(extra or [])
    rows.append({"record_type": "run_finished", "ts": end, "error": error})
    folder.joinpath(file).write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")


def projection_row(
    ts: float, tool: str, listed: list[tuple[int, float]], later: int = 0, text_bytes: int = 200
) -> JsonObject:
    """The record the host writes when it appends a block of arrived rows to a tool result."""
    detail = {
        "tool": tool,
        "later": later,
        "text_bytes": text_bytes,
        "rows": [{"arrival": arrival, "arrived_at": arrived_at} for arrival, arrived_at in listed],
    }
    return {
        "record_type": "hook_invoked",
        "ts": ts,
        "hook_name": "arrived_stimuli_projection",
        "hook_decision": "appended",
        "hook_detail": json.dumps(detail),
    }


def ack_row(event_id: str, arrived: float, acked: float, urgency: str, kind: str) -> JsonObject:
    return {
        "event_id": event_id,
        "reaction": {
            "kind": "event_queue_ack",
            "transition_receipt": {
                "applied_at_unix": acked,
                "transition": {"source": {"arrived_at_unix": arrived, "urgency": urgency, "payload": {"kind": kind}}},
            },
        },
    }


def write_acks(base: pathlib.Path, keeper: str, rows: list[str]) -> None:
    folder = base / ".masc" / "keepers" / keeper / "reaction-ledger" / "v7" / "2026-11"
    folder.mkdir(parents=True, exist_ok=True)
    folder.joinpath("01.jsonl").write_text("\n".join(rows) + "\n", encoding="utf-8")


def build_store(base: pathlib.Path) -> None:
    write_run(base, "alpha", "turn-a1.jsonl", DAY1 + 1000, DAY1 + 1100, 2, ["x", "y"])
    write_run(
        base,
        "alpha",
        "turn-a2.jsonl",
        DAY1 + 2000,
        DAY1 + 5600,
        150,
        ["masc_board_list"] * 150,
        error="Rate limited: Usage limit reached for 5 hour",
        spacing=24.0,
    )
    write_run(base, "alpha", "turn-a3.jsonl", DAY2 + 100, DAY2 + 200, 12, ["x"] * 6 + ["y"] * 6)
    write_run(base, "beta", "turn-b1.jsonl", DAY1 + 3000, DAY1 + 3100, 0, [], agent=None)
    rows = [
        json.dumps(ack_row("e1", DAY1 + 2500, DAY1 + 6000, "immediate", "board_signal")),
        json.dumps(ack_row("e1", DAY1 + 2500, DAY1 + 6000, "immediate", "board_signal")),
        json.dumps(ack_row("e2", DAY1 + 1050, DAY1 + 1200, "normal", "schedule_due")),
        json.dumps(ack_row("e3", DAY1 + 500, DAY1 + 600, "normal", "board_attention")),
        json.dumps(ack_row("e4", DAY1 + 5000, DAY1 + 5300, "normal", "board_attention")),
        json.dumps(ack_row("e5", DAY1 + 7000, DAY1 + 7100, "normal", "board_attention")),
        # Three days before the first trace: no run can have been going on.
        json.dumps(ack_row("e0", DAY1 - 3 * 86_400 + 10, DAY1 - 3 * 86_400 + 20, "normal", "board_attention")),
        json.dumps({"event_id": "x", "reaction": {"kind": "turn_started"}}),
        "this line is not JSON",
    ]
    write_acks(base, "alpha", rows)


def measured(window: tuple[date | None, date | None] = (None, None)) -> JsonObject:
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        build_store(base)
        return m.measure(base, window[0], window[1], 150, 0.85)


def obj(value: object) -> JsonObject:
    return cast("JsonObject", value)


class RunTests(unittest.TestCase):
    def test_rounds_count_model_requests_and_runs_without_rounds_are_set_apart(self) -> None:
        runs = obj(measured()["runs"])
        self.assertEqual(runs["runs"], 4)
        self.assertEqual(runs["runs_without_rounds"], 1)
        self.assertEqual(
            runs["wall_seconds_of_runs_without_rounds"], {"p50": 100.0, "p90": 100.0, "max": 100.0, "hours": 0.0}
        )
        self.assertEqual(runs["rounds"], 164)
        self.assertEqual(obj(runs["rounds_per_run_of_runs_with_rounds"])["max"], 150.0)

    def test_long_runs_are_counted_from_the_threshold_up(self) -> None:
        ge_100 = obj(obj(measured()["runs"])["ge_100"])
        self.assertEqual(ge_100["runs"], 1)
        self.assertEqual(ge_100["rounds"], 150)
        self.assertEqual(ge_100["wall_hours"], 1.0)
        self.assertEqual(ge_100["share_of_all_rounds"], round(150 / 164, 4))
        self.assertEqual(obj(obj(measured()["runs"])["ge_400"])["runs"], 0)

    def test_the_profile_is_the_part_after_the_first_dot(self) -> None:
        profiles = {row["profile"]: row for row in cast("list[JsonObject]", measured()["by_profile"])}
        self.assertEqual(obj(profiles["glm-5.3-flash"])["runs"], 3)
        self.assertEqual(obj(profiles["glm-5.3-flash"])["runs_ge_100"], 1)
        self.assertIn("unrecorded", profiles)

    def test_a_spin_run_needs_both_the_rounds_and_one_tool_to_dominate(self) -> None:
        spins = cast("list[JsonObject]", measured()["spin_runs"])
        self.assertEqual([row["rounds"] for row in spins], [150])
        self.assertEqual(spins[0]["top_tool"], "masc_board_list")
        self.assertTrue(str(spins[0]["ended_by"]).startswith("Rate limited"))
        self.assertEqual(spins[0]["rows_arrived_inside"], 2)

    def test_a_spin_run_counts_only_the_rows_that_arrived_inside_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            spin = ["masc_board_list"] * 150
            write_run(base, "alpha", "turn-a1.jsonl", DAY1 + 1000, DAY1 + 4600, 150, spin, spacing=24.0)
            write_run(base, "beta", "turn-b1.jsonl", DAY1 + 1000, DAY1 + 5200, 150, spin, spacing=24.0)
            write_run(base, "alpha", "turn-a2.jsonl", DAY1 + 6000, DAY1 + 6100, 2, ["x"])
            write_acks(
                base,
                "alpha",
                [
                    json.dumps(ack_row("in-1", DAY1 + 1500, DAY1 + 5000, "normal", "board_signal")),
                    json.dumps(ack_row("in-2", DAY1 + 4000, DAY1 + 5000, "normal", "board_attention")),
                    # Between the two runs of alpha, inside the run of beta: not a row of either spin run.
                    json.dumps(ack_row("between", DAY1 + 5000, DAY1 + 5100, "normal", "board_signal")),
                ],
            )
            spins = {
                str(row["keeper"]): row
                for row in cast("list[JsonObject]", m.measure(base, None, None, 150, 0.85)["spin_runs"])
            }
        self.assertEqual(sorted(spins), ["alpha", "beta"])
        self.assertEqual(obj(spins["alpha"])["rows_arrived_inside"], 2)
        self.assertEqual(obj(spins["beta"])["rows_arrived_inside"], 0)

    def test_the_day_table_splits_rounds_at_the_run_size(self) -> None:
        days = {row["day"]: row for row in cast("list[JsonObject]", measured()["by_day"])}
        self.assertEqual(obj(days["2026-11-01"])["rounds"], 152)
        self.assertEqual(obj(days["2026-11-01"])["rounds_in_ge_100"], 150)
        self.assertEqual(obj(days["2026-11-02"])["rounds"], 12)
        self.assertEqual(obj(days["2026-11-02"])["rounds_in_ge_100"], 0)

    def test_a_window_keeps_the_runs_that_start_inside_it(self) -> None:
        day2 = date(2026, 11, 2)
        runs = obj(measured((day2, day2))["runs"])
        self.assertEqual(runs["runs"], 1)
        self.assertEqual(runs["rounds"], 12)


class ArrivalTests(unittest.TestCase):
    def test_rows_inside_a_run_wait_at_least_until_the_run_ends(self) -> None:
        arrivals = obj(measured()["arrivals_during_runs"])
        self.assertEqual(arrivals["arrived_during_a_run"], 3)
        big = obj(obj(arrivals["by_run_size"])["100+ rounds"])
        self.assertEqual(big["rows"], 2)
        self.assertEqual(big["immediate"], 1)
        self.assertEqual(big["blocked_hours"], round((3100 + 600) / 3600, 1))
        small = obj(obj(arrivals["by_run_size"])["0-9 rounds"])
        self.assertEqual(small["rows"], 1)
        self.assertEqual(small["blocked_minutes_p50"], round(50 / 60, 1))

    def test_all_sums_the_rows_of_every_run_size_and_is_empty_when_no_row_arrived_inside_a_run(self) -> None:
        everything = obj(obj(measured()["arrivals_during_runs"])["all"])
        self.assertEqual(everything["rows"], 3)
        self.assertEqual(everything["immediate"], 1)
        self.assertEqual(everything["blocked_hours"], round((3100 + 600 + 50) / 3600, 1))
        self.assertEqual(everything["blocked_hours_max"], round(3100 / 3600, 2))
        day2 = date(2026, 11, 2)
        self.assertEqual(obj(measured((day2, day2))["arrivals_during_runs"])["all"], {"rows": 0})

    def test_a_row_before_the_first_trace_of_its_keeper_is_not_counted(self) -> None:
        arrivals = obj(measured()["arrivals_during_runs"])
        self.assertEqual(arrivals["acked_rows_in_coverage"], 4)

    def test_an_acknowledgement_before_the_run_ended_is_counted_apart(self) -> None:
        self.assertEqual(obj(measured()["arrivals_during_runs"])["acked_before_run_end"], 1)

    def test_a_row_listed_twice_is_one_row_and_a_bad_line_is_reported(self) -> None:
        result = measured()
        arrivals = obj(result["arrivals_during_runs"])
        kinds = obj(arrivals["by_kind"])
        self.assertEqual(obj(kinds["board_signal"])["rows"], 1)
        self.assertEqual(result["unreadable_lines"], 1)

    def test_rows_of_a_day_outside_the_window_are_left_out(self) -> None:
        day2 = date(2026, 11, 2)
        arrivals = obj(measured((day2, day2))["arrivals_during_runs"])
        self.assertEqual(arrivals["arrived_during_a_run"], 0)

    def test_the_day_table_counts_every_row_and_those_that_arrived_inside_a_run(self) -> None:
        by_day = cast("list[JsonObject]", obj(measured()["arrivals_during_runs"])["by_day"])
        self.assertEqual([row["day"] for row in by_day], ["2026-11-01"])
        self.assertEqual(by_day[0]["acked_rows"], 5)
        self.assertEqual(by_day[0]["arrived_during_a_run"], 3)
        self.assertEqual(by_day[0]["blocked_hours"], round((3100 + 600 + 50) / 3600, 1))


class ReplayTests(unittest.TestCase):
    def test_a_row_waits_for_the_next_round_instead_of_the_run_end(self) -> None:
        replay = obj(obj(measured()["arrivals_during_runs"])["visible_at_next_round"])
        # e1 arrives 500 s into a run whose rounds are 24 s apart: the next round is at 504 s, 4 s later.
        # e4 arrives at 3000 s, which is a round: 0 s. e2 arrives at 50 s into a run with 1 s spacing: 0 s (its
        # rounds are at 0 and 1, so no round follows it).
        self.assertEqual(replay["rows"], 2)
        self.assertEqual(replay["rows_after_the_last_round"], 1)
        self.assertEqual(replay["rows_in_runs_without_rounds"], 0)
        self.assertEqual(replay["seconds_to_next_round_max"], 4.0)
        self.assertEqual(replay["seconds_to_next_round_p50"], 4.0)
        self.assertEqual(replay["hours_earlier_than_the_run_end"], round(((5600 - 2504) + (5600 - 5000)) / 3600, 1))


class ToolResultReplayTests(unittest.TestCase):
    def test_a_row_in_a_run_without_rounds_waits_for_the_next_tool_result(self) -> None:
        start = DAY1 + 1000
        finished: list[JsonObject] = [
            {"record_type": "tool_execution_finished", "ts": start + offset} for offset in (300, 100, 200)
        ]
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a1.jsonl", start, start + 400, 0, [], agent=None, extra=finished)
            write_run(base, "alpha", "turn-a2.jsonl", start + 1000, start + 1100, 3, ["x"], spacing=10.0)
            arrivals = [
                ("a", 90),  # next tool result at 100: 10 s, 300 s earlier than the run end
                ("b", 95),  # 5 s, 300 s earlier
                ("c", 200),  # a result at the very second of the arrival counts: 0 s, 200 s earlier
                ("d", 250),  # 50 s, 100 s earlier
                ("e", 350),  # no tool result is left in the run
                ("f", 1050),  # inside a run that has rounds: not a row of this replay
            ]
            write_acks(
                base,
                "alpha",
                [json.dumps(ack_row(name, start + at, start + 2000, "normal", "board_signal")) for name, at in arrivals],
            )
            replay = obj(
                obj(m.measure(base, None, None, 150, 0.85)["arrivals_during_runs"])["visible_at_next_tool_result"]
            )
        self.assertEqual(replay["rows_in_runs_without_rounds"], 5)
        self.assertEqual(replay["blocked_hours"], round((310 + 305 + 200 + 150 + 50) / 3600, 2))
        self.assertEqual(replay["rows_after_the_last_tool_result"], 1)
        self.assertEqual(replay["rows"], 4)
        self.assertEqual(replay["seconds_to_next_tool_result"], {"p50": 10.0, "p90": 50.0, "max": 50.0})
        self.assertEqual(replay["hours_earlier_than_the_run_end"], round((300 + 300 + 200 + 100) / 3600, 2))

    def test_a_tool_result_stamped_after_the_run_end_is_not_a_result_of_the_run(self) -> None:
        start = DAY1 + 1000
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            late: list[JsonObject] = [{"record_type": "tool_execution_finished", "ts": start + 200}]
            write_run(base, "alpha", "turn-a1.jsonl", start, start + 150, 0, [], agent=None, extra=late)
            write_acks(base, "alpha", [json.dumps(ack_row("a", start + 120, start + 500, "normal", "board_signal"))])
            replay = obj(
                obj(m.measure(base, None, None, 150, 0.85)["arrivals_during_runs"])["visible_at_next_tool_result"]
            )
        self.assertEqual(
            replay,
            {"rows": 0, "rows_in_runs_without_rounds": 1, "blocked_hours": 0.01, "rows_after_the_last_tool_result": 1},
        )

    def test_a_window_without_such_rows_says_so(self) -> None:
        replay = obj(obj(measured()["arrivals_during_runs"])["visible_at_next_tool_result"])
        self.assertEqual(replay["rows"], 0)
        self.assertEqual(replay["rows_in_runs_without_rounds"], 0)
        self.assertEqual(replay["blocked_hours"], 0.0)


class ProjectionTests(unittest.TestCase):
    def test_a_window_with_no_block_says_so(self) -> None:
        result = measured()
        self.assertEqual(result["arrived_stimuli_projection"], {"blocks": 0})
        self.assertEqual(result["unreadable_projection_records"], 0)

    def test_a_row_is_counted_at_the_first_block_that_listed_it(self) -> None:
        start = DAY1 + 1000
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(
                base,
                "alpha",
                "turn-a1.jsonl",
                start,
                start + 100,
                0,
                [],
                agent=None,
                extra=[
                    projection_row(start + 30, "Execute", [(1, start + 10), (2, start + 20)], text_bytes=300),
                    # Row 2 comes again: the first block never reached the model. Row 3 is new.
                    projection_row(start + 50, "masc_board_list", [(2, start + 20), (3, start + 40)], later=1, text_bytes=100),
                ],
            )
            result = m.measure(base, None, None, 150, 0.85)
        shown = obj(result["arrived_stimuli_projection"])
        self.assertEqual(shown["blocks"], 2)
        self.assertEqual(shown["runs_with_a_block"], 1)
        self.assertEqual(shown["rows_shown"], 3)
        self.assertEqual(shown["blocks_with_rows_left_for_later"], 1)
        self.assertEqual(shown["blocks_by_tool"], {"Execute": 1, "masc_board_list": 1})
        self.assertEqual(shown["block_bytes"], {"total": 400, "p50": 300, "p90": 300, "max": 300})
        # Waits to the first block: row 1 20 s, row 2 10 s, row 3 10 s.
        self.assertEqual(shown["seconds_to_first_block"], {"p50": 10.0, "p90": 20.0, "max": 20.0})
        # The same rows would have waited to the run end: 90 s, 80 s, 60 s.
        self.assertEqual(shown["seconds_to_run_end_of_the_same_rows"], {"p50": 80.0, "p90": 90.0, "max": 90.0})
        self.assertEqual(shown["hours_earlier_than_the_run_end"], round((70 + 70 + 50) / 3600, 2))

    def test_each_day_counts_its_blocks_and_the_rows_it_showed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            for day, name in ((DAY1, "turn-a1.jsonl"), (DAY2, "turn-a2.jsonl")):
                write_run(
                    base,
                    "alpha",
                    name,
                    day + 100,
                    day + 400,
                    0,
                    [],
                    agent=None,
                    extra=[projection_row(day + 200, "Execute", [(1, day + 150)])],
                )
            by_day = cast(
                "list[JsonObject]", obj(m.measure(base, None, None, 150, 0.85)["arrived_stimuli_projection"])["by_day"]
            )
        self.assertEqual([row["day"] for row in by_day], ["2026-11-01", "2026-11-02"])
        self.assertEqual([row["blocks"] for row in by_day], [1, 1])
        self.assertEqual([row["rows_shown"] for row in by_day], [1, 1])
        self.assertEqual([row["hours_earlier_than_the_run_end"] for row in by_day], [round(200 / 3600, 2)] * 2)

    def test_a_row_belongs_to_the_day_it_was_shown_not_the_day_it_arrived(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(
                base,
                "alpha",
                "turn-a1.jsonl",
                DAY1 + 86_000,
                DAY2 + 500,
                0,
                [],
                agent=None,
                extra=[projection_row(DAY2 + 100, "Execute", [(1, DAY1 + 86_300)])],
            )
            by_day = cast(
                "list[JsonObject]", obj(m.measure(base, None, None, 150, 0.85)["arrived_stimuli_projection"])["by_day"]
            )
        self.assertEqual([(row["day"], row["blocks"], row["rows_shown"]) for row in by_day], [("2026-11-02", 1, 1)])

    def test_a_record_the_host_does_not_write_is_reported_and_not_counted(self) -> None:
        start = DAY1 + 1000
        good = projection_row(start + 30, "Execute", [(1, start + 10)])
        broken: list[JsonObject] = [
            {**good, "hook_detail": "not json"},
            {**good, "hook_detail": json.dumps({"tool": "Execute", "later": 0, "text_bytes": 5, "rows": []})},
            {**good, "hook_detail": json.dumps({"tool": "Execute", "later": 0, "text_bytes": 5, "rows": [{"arrival": 1}]})},
            {**good, "hook_detail": json.dumps({"tool": "Execute", "later": -1, "text_bytes": 5, "rows": [{"arrival": 1, "arrived_at": start}]})},
            {key: value for key, value in good.items() if key != "hook_detail"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a1.jsonl", start, start + 100, 0, [], agent=None, extra=[good, *broken])
            result = m.measure(base, None, None, 150, 0.85)
        self.assertEqual(result["unreadable_projection_records"], 5)
        self.assertEqual(obj(result["arrived_stimuli_projection"])["blocks"], 1)


SVG = "{http://www.w3.org/2000/svg}"


def rect_fills(svg: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for rect in ET.fromstring(svg).findall(f"{SVG}rect"):
        fill = rect.get("fill", "")
        counts[fill] = counts.get(fill, 0) + 1
    return counts


def day_labels(svg: str) -> list[str]:
    return [
        text.text or ""
        for text in ET.fromstring(svg).findall(f"{SVG}text")
        if text.get("transform", "").startswith("rotate")
    ]


class ClientContextTests(unittest.TestCase):
    def test_runs_without_rounds_are_split_by_the_client_context_hook(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a1.jsonl", DAY1 + 1000, DAY1 + 1100, 0, [], hooks=["client_context_submission"])
            write_run(base, "alpha", "turn-a2.jsonl", DAY1 + 2000, DAY1 + 2100, 0, [])
            write_run(base, "alpha", "turn-a3.jsonl", DAY1 + 3000, DAY1 + 3100, 2, ["x"])
            runs = obj(m.measure(base, None, None, 150, 0.85)["runs"])
        self.assertEqual(runs["runs"], 3)
        self.assertEqual(runs["runs_without_rounds"], 2)
        self.assertEqual(runs["runs_without_rounds_with_client_context_submission"], 1)


class RowsPerRoundTests(unittest.TestCase):
    def test_a_request_that_would_list_more_rows_than_the_limit_is_counted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            # Rounds at 0, 10 and 20 s. Nine rows arrive between the second and the third round, one before the second.
            write_run(base, "alpha", "turn-a1.jsonl", DAY1 + 1000, DAY1 + 1030, 3, ["x"], spacing=10.0)
            rows = [json.dumps(ack_row("first", DAY1 + 1005, DAY1 + 1100, "normal", "board_signal"))]
            rows += [
                json.dumps(ack_row(f"burst-{index}", DAY1 + 1011 + index * 0.5, DAY1 + 1100, "normal", "board_signal"))
                for index in range(9)
            ]
            write_acks(base, "alpha", rows)
            replay = obj(obj(m.measure(base, None, None, 150, 0.85)["arrivals_during_runs"])["visible_at_next_round"])
        per_round = obj(replay["rows_per_next_round"])
        self.assertEqual(replay["rows"], 10)
        self.assertEqual(per_round["rounds"], 2)
        self.assertEqual(per_round["max"], 9)
        self.assertEqual(per_round["limit"], 8)
        self.assertEqual(per_round["rounds_over_limit"], 1)
        self.assertEqual(per_round["rows_in_rounds_over_limit"], 9)


class RunsWithoutRoundsTests(unittest.TestCase):
    def test_a_row_inside_a_run_without_round_records_is_counted_apart_from_one_after_the_last_round(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "beta", "turn-b1.jsonl", DAY1 + 3000, DAY1 + 3100, 0, [], agent=None)
            write_run(base, "alpha", "turn-a1.jsonl", DAY1 + 1000, DAY1 + 1100, 2, ["x"], spacing=10.0)
            write_acks(base, "beta", [json.dumps(ack_row("b", DAY1 + 3050, DAY1 + 3200, "normal", "board_signal"))])
            write_acks(base, "alpha", [json.dumps(ack_row("a", DAY1 + 1050, DAY1 + 1200, "normal", "board_signal"))])
            arrivals = obj(m.measure(base, None, None, 150, 0.85)["arrivals_during_runs"])
        replay = obj(arrivals["visible_at_next_round"])
        self.assertEqual(arrivals["arrived_during_a_run"], 2)
        self.assertEqual(replay["rows"], 0)
        self.assertEqual(replay["rows_in_runs_without_rounds"], 1)
        self.assertEqual(replay["rows_after_the_last_round"], 1)


class VanishedFileTests(unittest.TestCase):
    def test_a_file_that_is_gone_before_it_is_opened_is_counted_and_the_rest_is_read(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-a1.jsonl", DAY1 + 1000, DAY1 + 1100, 2, ["x"])
            write_acks(base, "alpha", [json.dumps(ack_row("e1", DAY1 + 1050, DAY1 + 1200, "normal", "board_signal"))])
            traces = base / ".masc" / "keepers" / "alpha" / "raw-traces"
            ledger = base / ".masc" / "keepers" / "alpha" / "reaction-ledger" / "v7" / "2026-11"
            os.symlink(base / "nowhere", traces / "turn-gone.jsonl")
            os.symlink(base / "nowhere", ledger / "02.jsonl")
            result = m.measure(base, None, None, 150, 0.85)
        self.assertEqual(result["unreadable_files"], 2)
        self.assertEqual(obj(result["runs"])["runs"], 1)
        self.assertEqual(obj(result["arrivals_during_runs"])["arrived_during_a_run"], 1)


class ChartTests(unittest.TestCase):
    def test_the_svg_has_a_bar_pair_per_day_and_a_wait_bar_per_day(self) -> None:
        svg = m.svg_chart(measured())
        fills = rect_fills(svg)
        # Each of the two days has rounds. The legend adds one swatch to each colour of the first panel.
        self.assertEqual(fills[m.BLUE], 2 + 1)
        self.assertEqual(fills[m.ORANGE], 2 + 1)
        self.assertEqual(fills[m.RED], 2)
        self.assertEqual(fills[m.GREY], 1)

    def test_a_day_without_round_records_keeps_its_slot_as_a_grey_tick_in_both_panels(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            write_run(base, "alpha", "turn-x1.jsonl", DAY1 + 100, DAY1 + 200, 3, ["x"])
            write_run(base, "alpha", "turn-x2.jsonl", DAY1 + 2 * 86_400 + 100, DAY1 + 2 * 86_400 + 200, 3, ["x"])
            svg = m.svg_chart(m.measure(base, None, None, 150, 0.85))
        self.assertEqual(day_labels(svg), ["11-01", "11-02", "11-03", "11-01", "11-02", "11-03"])
        fills = rect_fills(svg)
        self.assertEqual(fills[m.GREY], 1 + 2)
        self.assertEqual(fills[m.RED], 2)

    def test_the_window_label_is_utc(self) -> None:
        stamp = datetime.fromtimestamp(DAY1, UTC).strftime("%Y-%m-%d")
        self.assertEqual(stamp, "2026-11-01")


if __name__ == "__main__":
    unittest.main()
