"""Checks the counting of replay_preflight_ttl.py on small synthetic calls.

Run: python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
"""

from __future__ import annotations

import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_before_after as before_after  # noqa: E402
import replay_preflight_ttl as preflight  # noqa: E402

READ_TTL = 300.0
WRITE_TTL = 60.0


def call(
    end: float,
    tool: str = "Read",
    keeper: str = "a",
    duration_s: float = 0.0,
    intent: str | None = None,
    sandbox: str = "remote_ssh",
    command_s: float | None = None,
    failed: bool = False,
) -> before_after.Call:
    text = json.dumps({"intent": intent} if intent is not None else {}) if tool == "Execute" else ""
    output = json.dumps({"execution_time_ms": command_s * 1000}) if command_s is not None else ""
    return before_after.Call(
        ts=end,
        tool=tool,
        keeper=keeper,
        duration_ms=duration_s * 1000,
        result_bytes=0,
        failed=failed,
        input_text=text,
        output_text=output,
        sandbox=sandbox,
    )


def passes(calls: list[before_after.Call], since: float = 0.0, read_ttl: float = READ_TTL) -> dict[str, int]:
    return preflight.replay(calls, since, read_ttl, WRITE_TTL)


class ReaderTest(unittest.TestCase):
    def test_a_reader_reuses_a_pass_until_the_read_ttl_ends(self) -> None:
        result = passes([call(0), call(100), call(299), call(301)])
        self.assertEqual((result["read"], result["write"], result["total"]), (2, 0, 2))

    def test_a_call_starts_before_it_ends(self) -> None:
        result = passes([call(0), call(310, duration_s=20)])
        self.assertEqual(result["total"], 1)

    def test_the_other_remote_tools_read(self) -> None:
        result = passes([call(0, "Read"), call(400, "Grep"), call(800, "Glob"), call(1200, "Execute", intent="auto")])
        self.assertEqual((result["read"], result["write"]), (4, 0))

    def test_an_execute_without_an_intent_reads(self) -> None:
        self.assertEqual(passes([call(0, "Execute"), call(400, "Execute")])["read"], 2)


class WriterTest(unittest.TestCase):
    def test_a_writer_runs_a_pass_after_the_write_ttl_even_when_the_read_ttl_is_long(self) -> None:
        result = passes([call(0, "Edit"), call(30, "Edit"), call(61, "Write")], read_ttl=3600)
        self.assertEqual((result["read"], result["write"]), (0, 2))

    def test_an_execute_that_requests_an_effect_writes(self) -> None:
        result = passes([call(0, "Execute", intent="request_effect"), call(61, "Execute", intent="request_effect")])
        self.assertEqual((result["read"], result["write"]), (0, 2))

    def test_a_pass_run_by_a_writer_serves_a_reader(self) -> None:
        result = passes([call(0, "Edit"), call(200, "Read")])
        self.assertEqual((result["read"], result["write"]), (0, 1))


class ScopeTest(unittest.TestCase):
    def test_other_sandboxes_and_other_tools_do_not_use_the_cache(self) -> None:
        result = passes(
            [
                call(0, "Read", sandbox="microvm"),
                call(0, "Execute", sandbox=before_after.UNKNOWN_SANDBOX),
                call(0, "masc_ask"),
                call(0, "Delegate"),
            ]
        )
        self.assertEqual(result["total"], 0)

    def test_each_keeper_has_its_own_pass(self) -> None:
        self.assertEqual(passes([call(0, keeper="a"), call(1, keeper="b"), call(2, keeper="a")])["total"], 2)

    def test_the_warmup_fills_the_cache_without_being_counted(self) -> None:
        self.assertEqual(passes([call(900), call(1100)], since=1000)["total"], 0)
        self.assertEqual(passes([call(900), call(1300)], since=1000)["total"], 1)

    def test_calls_are_replayed_in_start_order_whatever_the_input_order(self) -> None:
        self.assertEqual(passes([call(301), call(0), call(100)])["total"], 2)


class OverheadByGapTest(unittest.TestCase):
    def test_overhead_is_grouped_by_the_gap_since_the_keepers_previous_call_that_used_the_cache(self) -> None:
        calls = [
            call(0, "Read"),
            call(5, "Execute", duration_s=1.0, command_s=0.99),
            call(100, "Execute", duration_s=4.0, command_s=1.0),
            call(700, "Execute", duration_s=2.0, command_s=1.9),
        ]
        by_gap = preflight.overhead_by_gap(calls, since=0.0)
        self.assertEqual(sorted(by_gap), ["0-10s", "60-120s", "600s+"])
        quick = by_gap["0-10s"]
        self.assertEqual((quick["calls"], quick["overhead_p50_s"], quick["slow_calls"]), (1, 0.01, 0))
        slow = by_gap["60-120s"]
        self.assertEqual((slow["calls"], slow["overhead_p50_s"], slow["slow_calls"]), (1, 3.0, 1))

    def test_only_successful_executes_with_a_command_time_that_ended_in_the_window_count(self) -> None:
        calls = [
            call(0, "Read"),
            call(5, "Execute", duration_s=1.0),
            call(6, "Execute", duration_s=1.0, command_s=0.5, failed=True),
            call(7, "Read", duration_s=1.0, command_s=0.5),
            call(8, "Execute", duration_s=1.0, command_s=0.5, sandbox="microvm"),
        ]
        self.assertEqual(preflight.overhead_by_gap(calls, since=0.0), {})
        late = [call(0, "Read"), call(5, "Execute", duration_s=1.0, command_s=0.5)]
        self.assertEqual(preflight.overhead_by_gap(late, since=10.0), {})

    def test_a_keepers_first_call_has_no_gap(self) -> None:
        self.assertEqual(preflight.overhead_by_gap([call(5, "Execute", duration_s=1.0, command_s=0.5)], since=0.0), {})


if __name__ == "__main__":
    unittest.main()
