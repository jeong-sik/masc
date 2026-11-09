"""Checks the cold and warm split of cold_start_split.py on small synthetic calls.

Run: python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
"""

from __future__ import annotations

import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import cold_start_split as split  # noqa: E402
import measure_before_after as before_after  # noqa: E402

FIRST_BOOT = 10_000.0
SECOND_BOOT = 20_000.0
COLD_S = 300.0


def call(
    ts: float,
    overhead_ms: float = 100.0,
    sandbox: str = "remote_ssh",
    tool: str = "Execute",
    failed: bool = False,
    execution_time_ms: float | None = 1_000.0,
) -> before_after.Call:
    output = {} if execution_time_ms is None else {"execution_time_ms": execution_time_ms}
    run = 0.0 if execution_time_ms is None else execution_time_ms
    return before_after.Call(
        ts=ts,
        tool=tool,
        keeper="a",
        duration_ms=run + overhead_ms,
        result_bytes=10,
        failed=failed,
        input_text="{}",
        output_text=json.dumps(output),
        sandbox=sandbox,
        turn="",
    )


def cell(cells: dict[split.Key, split.Cell], segment: float, sandbox: str, phase: str) -> tuple[int, int]:
    found = cells[(segment, sandbox, phase)]
    return found.calls, found.slow


class SplitTest(unittest.TestCase):
    def test_a_call_inside_the_cold_seconds_is_cold_and_a_later_one_is_warm(self) -> None:
        cells = split.split([call(FIRST_BOOT + 10.0), call(FIRST_BOOT + COLD_S)], [FIRST_BOOT], COLD_S)
        self.assertEqual(cell(cells, FIRST_BOOT, "remote_ssh", split.COLD), (1, 0))
        self.assertEqual(cell(cells, FIRST_BOOT, "remote_ssh", split.WARM), (1, 0))

    def test_a_call_before_the_first_boot_is_warm_in_its_own_segment(self) -> None:
        cells = split.split([call(FIRST_BOOT - 1.0)], [FIRST_BOOT], COLD_S)
        self.assertEqual(list(cells), [(split.BEFORE_FIRST_BOOT, "remote_ssh", split.WARM)])

    def test_a_call_after_the_second_boot_belongs_to_the_second_segment(self) -> None:
        cells = split.split([call(SECOND_BOOT + 1.0), call(FIRST_BOOT + 1.0)], [SECOND_BOOT, FIRST_BOOT], COLD_S)
        self.assertEqual(cell(cells, SECOND_BOOT, "remote_ssh", split.COLD), (1, 0))
        self.assertEqual(cell(cells, FIRST_BOOT, "remote_ssh", split.COLD), (1, 0))

    def test_the_slow_threshold_is_the_ledger_readers(self) -> None:
        edge = before_after.OVERHEAD_SLOW_MS
        cells = split.split(
            [call(FIRST_BOOT + 1_000.0, overhead_ms=edge - 1.0), call(FIRST_BOOT + 1_001.0, overhead_ms=edge)],
            [FIRST_BOOT],
            COLD_S,
        )
        self.assertEqual(cell(cells, FIRST_BOOT, "remote_ssh", split.WARM), (2, 1))

    def test_sandboxes_are_counted_apart(self) -> None:
        cells = split.split([call(FIRST_BOOT + 1_000.0, sandbox="microvm"), call(FIRST_BOOT + 1_001.0)], [FIRST_BOOT], COLD_S)
        self.assertEqual(cell(cells, FIRST_BOOT, "microvm", split.WARM), (1, 0))
        self.assertEqual(cell(cells, FIRST_BOOT, "remote_ssh", split.WARM), (1, 0))

    def test_failed_calls_other_tools_and_calls_without_an_execution_time_are_skipped(self) -> None:
        cells = split.split(
            [
                call(FIRST_BOOT + 1_000.0, failed=True),
                call(FIRST_BOOT + 1_001.0, tool="Read"),
                call(FIRST_BOOT + 1_002.0, execution_time_ms=None),
            ],
            [FIRST_BOOT],
            COLD_S,
        )
        self.assertEqual(cells, {})

    def test_the_mean_overhead_is_the_sum_over_the_calls(self) -> None:
        cells = split.split([call(FIRST_BOOT + 1_000.0, overhead_ms=100.0), call(FIRST_BOOT + 1_001.0, overhead_ms=300.0)], [FIRST_BOOT], COLD_S)
        self.assertEqual(cells[(FIRST_BOOT, "remote_ssh", split.WARM)].overhead_ms, 400.0)


class LabelTest(unittest.TestCase):
    def test_the_segment_label_is_the_boot_in_utc(self) -> None:
        self.assertEqual(split.label(split.instant("2026-11-09T04:57:31")), "11-09 04:57:31")
        self.assertEqual(split.label(split.BEFORE_FIRST_BOOT), "before first")


if __name__ == "__main__":
    unittest.main()
