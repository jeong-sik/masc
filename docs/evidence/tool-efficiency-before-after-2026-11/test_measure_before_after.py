"""Checks the counting of measure_before_after.py on small synthetic ledgers.

Run: python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
"""

from __future__ import annotations

import datetime
import json
import pathlib
import sys
import tempfile
import unittest
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_before_after as before_after  # noqa: E402

UTC = datetime.timezone.utc
BOOT = datetime.datetime(2026, 11, 7, 18, 24, tzinfo=UTC).timestamp()
SETTLE = 300.0
END = BOOT + 3600 + SETTLE
KEEPERS = ("poller",)
WINDOWS = before_after.windows_of(BOOT, END, SETTLE, None)


def row(
    stamp: float,
    tool: str,
    keeper: str = "a",
    duration_ms: float = 10.0,
    result_bytes: int = 1,
    disposition: str | None = None,
    call_input: object = None,
    output: object = "",
    sandbox_profile: str | None = None,
) -> bytes:
    fields: dict[str, object] = {
        "ts": stamp,
        "record_kind": "tool_call",
        "tool": tool,
        "keeper": keeper,
        "duration_ms": duration_ms,
        "result_bytes": result_bytes,
        "input": call_input if call_input is not None else {},
        "output": output,
    }
    if disposition is not None:
        fields["disposition"] = disposition
    if sandbox_profile is not None:
        fields["runtime_contract"] = {"sandbox_profile": sandbox_profile}
    return json.dumps(fields).encode("utf-8")


def compared(lines: list[bytes]) -> dict[str, dict[str, object]]:
    skipped = before_after.Skipped()
    calls = [
        call
        for raw in lines
        if (call := before_after.parse_call(raw, WINDOWS.before_since, WINDOWS.after_until, skipped)) is not None
    ]
    return cast("dict[str, dict[str, object]]", before_after.compare(calls, WINDOWS, KEEPERS))


class WindowTest(unittest.TestCase):
    def test_the_settle_gap_belongs_to_neither_window(self) -> None:
        result = compared(
            [
                row(BOOT - 60, "Read"),
                row(BOOT + 60, "Read"),
                row(BOOT + SETTLE, "Read"),
                row(BOOT + SETTLE + 60, "Read"),
            ]
        )
        self.assertEqual(result["before"]["calls"], 1)
        self.assertEqual(result["after"]["calls"], 2)

    def test_the_before_window_is_as_long_as_the_after_window_by_default(self) -> None:
        self.assertEqual(WINDOWS.before_until - WINDOWS.before_since, WINDOWS.after_until - WINDOWS.after_since)
        far = compared([row(WINDOWS.before_since - 1, "Read")])
        self.assertEqual(far["before"]["calls"], 0)

    def test_an_end_inside_the_settle_gap_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            before_after.windows_of(BOOT, BOOT + 10, SETTLE, None)

    def test_a_bad_line_and_a_line_without_a_number_for_ts_are_skipped_and_counted(self) -> None:
        skipped = before_after.Skipped()
        self.assertIsNone(before_after.parse_call(b"not json", 0, 1e12, skipped))
        self.assertIsNone(before_after.parse_call(b'{"record_kind":"tool_call","tool":"Read","ts":"7"}', 0, 1e12, skipped))
        self.assertIsNone(before_after.parse_call(b'{"record_kind":"tool_call","ts":7}', 0, 1e12, skipped))
        self.assertIsNone(before_after.parse_call(b'{"record_kind":"lifecycle_event","tool":"Read","ts":7}', 0, 1e12, skipped))
        self.assertEqual(skipped.bad_lines, 3)


class TurnTest(unittest.TestCase):
    def turn_of(self, tool: str = "Execute", **fields: object) -> str | None:
        line = {"ts": 7, "record_kind": "tool_call", "tool": tool, **fields}
        call = before_after.parse_call(json.dumps(line).encode("utf-8"), 0, 1e12, before_after.Skipped())
        return None if call is None else call.turn

    def test_the_turn_is_the_trace_and_the_keeper_turn_number(self) -> None:
        self.assertEqual(self.turn_of(trace_id="tr-1", keeper_turn_id=7), "tr-1:7")

    def test_the_same_number_in_another_trace_is_another_turn(self) -> None:
        self.assertNotEqual(self.turn_of(trace_id="tr-1", keeper_turn_id=7), self.turn_of(trace_id="tr-2", keeper_turn_id=7))

    def test_a_row_without_a_whole_turn_number_has_no_turn(self) -> None:
        for number in (None, True, "7", 7.5):
            self.assertEqual(self.turn_of(trace_id="tr-1", keeper_turn_id=number), "", number)
        self.assertEqual(self.turn_of(trace_id="tr-1"), "")

    def test_only_execute_rows_keep_a_turn(self) -> None:
        self.assertEqual(self.turn_of(tool="Read", trace_id="tr-1", keeper_turn_id=7), "")


class SizedTest(unittest.TestCase):
    def test_the_median_the_maximum_and_the_calls_at_or_over_the_cap(self) -> None:
        sizes = [100, 102_400, 200_000]
        result = compared([row(BOOT + 400 + i, "Grep", result_bytes=size) for i, size in enumerate(sizes)])
        sized = cast("dict[str, dict[str, object]]", result["after"]["sized"])["Grep"]
        self.assertEqual(sized["calls"], 3)
        self.assertEqual(sized["p50"], 102_400)
        self.assertEqual(sized["max"], 200_000)
        self.assertEqual(sized["at_or_over_cap"], 2)
        self.assertEqual(sized["bytes_at_or_over_cap"], 302_400)

    def test_a_tool_without_calls_has_no_median(self) -> None:
        sized = cast("dict[str, dict[str, object]]", compared([])["after"]["sized"])["BrowserTabs"]
        self.assertEqual((sized["calls"], sized["p50"], sized["max"]), (0, None, None))


class ExecuteTest(unittest.TestCase):
    def test_held_time_and_the_calls_held_a_minute_or_more(self) -> None:
        result = compared(
            [
                row(BOOT + 400, "Execute", duration_ms=1_800_000),
                row(BOOT + 401, "Execute", duration_ms=1_800_000),
                row(BOOT + 402, "Execute", duration_ms=59_999),
            ]
        )
        execute = cast("dict[str, object]", result["after"]["execute"])
        self.assertEqual(execute["calls"], 3)
        self.assertEqual(execute["held_60s_or_more_calls"], 2)
        self.assertEqual(execute["held_60s_or_more_hours"], 1.0)

    def test_a_sleep_poll_is_held_a_minute_by_a_named_keeper_with_sleep_and_a_number(self) -> None:
        result = compared(
            [
                row(BOOT + 400, "Execute", "poller", 90_000, call_input={"command": "sleep 60; gh run view"}),
                row(BOOT + 401, "Execute", "poller", 30_000, call_input={"command": "sleep 60"}),
                row(BOOT + 402, "Execute", "other", 90_000, call_input={"command": "sleep 60"}),
                row(BOOT + 403, "Execute", "poller", 90_000, call_input={"command": "sleepy 60"}),
                row(BOOT + 404, "Execute", "poller", 90_000, call_input=json.dumps({"command": "sleep 5"})),
            ]
        )
        polls = cast("dict[str, object]", result["after"]["sleep_polls"])
        self.assertEqual(polls["calls"], 2)
        self.assertEqual(polls["hours"], 0.05)
        self.assertEqual(polls["keeper_execute_calls"], 4)

    def test_background_calls_are_counted_by_keeper_for_a_dict_and_a_text_input(self) -> None:
        result = compared(
            [
                row(BOOT + 400, "Execute", "a", call_input={"command": "dune build", "run_in_background": True}),
                row(BOOT + 401, "Execute", "b", call_input=json.dumps({"command": "x", "run_in_background": True})),
                row(BOOT + 402, "Execute", "a", call_input={"command": "x", "run_in_background": False}),
            ]
        )
        execute = cast("dict[str, object]", result["after"]["execute"])
        self.assertEqual(execute["background_calls"], 2)
        self.assertEqual(execute["background_by_keeper"], {"a": 1, "b": 1})

    def test_a_started_background_run_counts_when_it_names_both_handle_tools(self) -> None:
        named = json.dumps({"request_id": "r1", "delivery": "read with keeper_composition_status, stop with keeper_composition_cancel"})
        bare = json.dumps({"request_id": "r2", "delivery": "arrives in a later turn"})
        flag = {"command": "dune build", "run_in_background": True}
        result = compared(
            [
                row(BOOT + 400, "Execute", call_input=flag, output=named),
                row(BOOT + 401, "Execute", call_input=flag, output=bare),
                row(BOOT + 402, "Execute", call_input=flag, output=named, disposition="failed"),
            ]
        )
        started = cast("dict[str, object]", result["after"]["background_starts"])
        self.assertEqual(started["calls"], 2)
        self.assertEqual(started["naming_both_handle_tools"], 1)


class OverheadTest(unittest.TestCase):
    def test_overhead_is_the_held_time_minus_the_command_time_of_calls_that_report_it(self) -> None:
        result = compared(
            [
                row(BOOT + 400, "Execute", duration_ms=3_600_000, output=json.dumps({"ok": True, "execution_time_ms": 1_800_000})),
                row(BOOT + 401, "Execute", duration_ms=1_000, output=json.dumps({"ok": True, "execution_time_ms": "900"})),
                row(BOOT + 402, "Execute", duration_ms=9_999_999, output=json.dumps({"ok": True})),
                row(BOOT + 403, "Execute", duration_ms=9_999_999, disposition="failed", output=json.dumps({"execution_time_ms": 1})),
                row(BOOT + 404, "Execute", duration_ms=1_000, output="not json"),
            ]
        )
        overhead = cast("dict[str, object]", result["after"]["execute_overhead"])
        self.assertEqual(overhead["calls"], 2)
        self.assertEqual(overhead["overhead_5s_or_more_calls"], 1)
        self.assertEqual(overhead["overhead_5s_or_more_hours"], 0.5)
        self.assertEqual(overhead["overhead_share"], 0.5)

    def test_no_reporting_call_leaves_the_share_empty(self) -> None:
        overhead = cast("dict[str, object]", compared([])["after"]["execute_overhead"])
        self.assertEqual((overhead["calls"], overhead["overhead_share"]), (0, None))

    def test_overhead_is_split_by_sandbox_profile_and_slow_means_half_a_second_or_more(self) -> None:
        def ran(
            stamp: float, profile: str | None, held_ms: float, overhead_ms: float, disposition: str | None = None
        ) -> bytes:
            output = json.dumps({"execution_time_ms": held_ms - overhead_ms})
            return row(
                stamp, "Execute", duration_ms=held_ms, output=output, sandbox_profile=profile, disposition=disposition
            )

        result = compared(
            [
                ran(BOOT + 400, "remote_ssh", 3_600_000, 1_800_000),
                ran(BOOT + 401, "remote_ssh", 10_000, 600),
                ran(BOOT + 402, "remote_ssh", 10_000, 10),
                ran(BOOT + 403, "microvm", 10_000, 100),
                ran(BOOT + 404, None, 10_000, 4_000),
                ran(BOOT + 405, "remote_ssh", 10_000, 9_000, disposition="failed"),
            ]
        )
        split = cast("dict[str, dict[str, object]]", result["after"]["execute_overhead_by_sandbox"])
        self.assertEqual(sorted(split), ["microvm", "remote_ssh", "unknown"])
        remote = split["remote_ssh"]
        self.assertEqual(remote["calls"], 3)
        self.assertEqual(remote["overhead_hours"], 0.5)
        self.assertEqual(remote["overhead_p50_s"], 0.6)
        self.assertEqual((remote["slow_calls"], remote["slow_hours"], remote["slow_mean_s"]), (2, 0.5, 900.3))
        self.assertEqual((split["microvm"]["calls"], split["microvm"]["slow_calls"], split["microvm"]["slow_mean_s"]), (1, 0, None))
        self.assertEqual(split["unknown"]["slow_calls"], 1)


class DiskLowTest(unittest.TestCase):
    def test_only_failed_calls_that_hold_the_code_count_and_execute_is_split_by_intent(self) -> None:
        code = json.dumps({"error": "remote_ssh_disk_low: endpoint x available_kib=1 minimum_kib=2"})
        result = compared(
            [
                row(BOOT + 400, "Execute", disposition="failed", call_input={"command": "gh pr view"}, output=code),
                row(BOOT + 401, "Execute", disposition="failed", call_input={"command": "rm x", "intent": "request_effect"}, output=code),
                row(BOOT + 402, "Execute", disposition="failed", call_input="not json", output=code),
                row(BOOT + 403, "Grep", disposition="failed", output=code),
                row(BOOT + 404, "masc_ask", disposition="completed", output="quoted remote_ssh_disk_low in a reply"),
                row(BOOT + 405, "Execute", disposition="failed", output="another failure"),
            ]
        )
        disk = cast("dict[str, object]", result["after"]["disk_low"])
        self.assertEqual(disk["calls"], 4)
        self.assertEqual(disk["by_tool"], {"Execute": 3, "Grep": 1})
        self.assertEqual(disk["execute_by_intent"], {"auto": 1, "request_effect": 1, "unknown": 1})


class FailedTest(unittest.TestCase):
    def test_failed_calls_are_ranked_by_tool(self) -> None:
        result = compared(
            [
                row(BOOT + 400, "Grep", disposition="failed"),
                row(BOOT + 401, "Grep", disposition="failed"),
                row(BOOT + 402, "Edit", disposition="failed"),
                row(BOOT + 403, "Edit", disposition="completed"),
            ]
        )
        after = result["after"]
        self.assertEqual((after["calls"], after["failed"]), (4, 3))
        self.assertEqual(after["failed_by_tool"], [{"tool": "Grep", "failed": 2}, {"tool": "Edit", "failed": 1}])


class LedgerFilesTest(unittest.TestCase):
    def test_rotated_files_of_each_touched_day_are_read_in_name_order(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            month = base / ".masc" / "tool_calls" / "2026-11"
            month.mkdir(parents=True)
            for name in ("07.jsonl", "07.001.jsonl", "08.jsonl", "09.jsonl", "07.json", "7.jsonl", "07.1.jsonl"):
                (month / name).write_text("", encoding="utf-8")
            since = datetime.datetime(2026, 11, 7, 1, tzinfo=UTC)
            until = datetime.datetime(2026, 11, 8, 1, tzinfo=UTC)
            names = [path.name for path in before_after.ledger_files(base, since, until)]
        self.assertEqual(names, ["07.001.jsonl", "07.jsonl", "08.jsonl"])


if __name__ == "__main__":
    unittest.main()
