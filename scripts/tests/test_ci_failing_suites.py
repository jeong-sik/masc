#!/usr/bin/env python3
"""The nightly digest names every failing test command in a full dune log."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ci_failing_suites import FailingCommand, failing_commands, render  # noqa: E402

PASSING = """\
(cd _build/default/test && ./test_passes.exe)
Testing `passes'.
  [OK]          group          0   a case.
Test Successful in 0.001s. 1 test run.
"""

ALCOTEST_FAILURE_WITH_LOCATION = """\
File "packages/agent_core/test/dune", line 75, characters 2-21:
75 |   test_agent_pipeline
       ^^^^^^^^^^^^^^^^^^^
(cd _build/.sandbox/f7715d8975d8c7470164b47207fa251e/default/packages/agent_core/test && ./test_agent_pipeline.exe)
Testing `agent_pipeline'.
  [OK]          basic                        0   simple text.
  [FAIL]        streaming                    0   run_stream.
  [FAIL]        streaming                    1   run_stream pre-dispatch.
┌──────────────────────────────────────────────────────────────────────────────┐
│ [FAIL]        streaming                    0   run_stream.                   │
└──────────────────────────────────────────────────────────────────────────────┘
2 failures! in 0.010s. 9 tests run.
"""

ALCOTEST_FAILURE_WITHOUT_LOCATION = """\
(cd _build/.sandbox/9dc213ac39a487c37f429f1cbf27f756/default/test && ./test_posix_spawn_process_mgr.exe)
Testing `posix_spawn_process_mgr'.
  [FAIL]        with the system-thread host started          7   a switch tha...
1 failure! in 0.2s. 8 tests run.
"""

CRASH_WITH_LOCATION = """\
File "test/dune", line 4120, characters 7-30:
4120 |  (name test_tui_browser_lane)
               ^^^^^^^^^^^^^^^^^^^^^
(cd _build/.sandbox/0a1b2c3d4e5f60718293a4b5c6d7e8f9/default/test && ./test_tui_browser_lane.exe)
Fatal error: exception Unix.Unix_error(Unix.EINTR, "waitpid", "")
"""

COMPILE_ERROR = """\
File "lib/foo.ml", line 3, characters 4-9:
3 |     nope
        ^^^^
Error: Unbound value nope
(cd _build/default/test && ./test_passes.exe)
Testing `passes'.
  [OK]          group          0   a case.
"""


def found(log: str) -> tuple[FailingCommand, ...]:
    return failing_commands(log.splitlines(keepends=True))


class FailingCommands(unittest.TestCase):
    def test_a_passing_command_is_not_named(self) -> None:
        self.assertEqual(found(PASSING), ())

    def test_counts_listed_cases_once_and_strips_the_sandbox_prefix(self) -> None:
        self.assertEqual(
            found(ALCOTEST_FAILURE_WITH_LOCATION),
            (FailingCommand("packages/agent_core/test", "./test_agent_pipeline.exe", 2, True),),
        )

    def test_a_failure_dune_did_not_locate_is_still_named(self) -> None:
        self.assertEqual(
            found(ALCOTEST_FAILURE_WITHOUT_LOCATION),
            (FailingCommand("test", "./test_posix_spawn_process_mgr.exe", 1, False),),
        )

    def test_a_crash_with_no_failed_case_line_is_named(self) -> None:
        self.assertEqual(
            found(CRASH_WITH_LOCATION),
            (FailingCommand("test", "./test_tui_browser_lane.exe", 0, True),),
        )

    def test_a_location_that_is_not_a_dune_file_blames_no_command(self) -> None:
        self.assertEqual(found(COMPILE_ERROR), ())

    def test_failures_keep_log_order_between_passing_commands(self) -> None:
        log = (
            PASSING
            + ALCOTEST_FAILURE_WITHOUT_LOCATION
            + PASSING
            + CRASH_WITH_LOCATION
            + ALCOTEST_FAILURE_WITH_LOCATION
        )
        self.assertEqual(
            [c.command for c in found(log)],
            [
                "./test_posix_spawn_process_mgr.exe",
                "./test_tui_browser_lane.exe",
                "./test_agent_pipeline.exe",
            ],
        )

    def test_render_puts_the_case_count_before_the_command(self) -> None:
        self.assertEqual(
            render(found(ALCOTEST_FAILURE_WITH_LOCATION + CRASH_WITH_LOCATION)),
            "  2  packages/agent_core/test/./test_agent_pipeline.exe\n"
            "  0  test/./test_tui_browser_lane.exe\n",
        )

    def test_an_empty_log_names_nothing(self) -> None:
        self.assertEqual(render(found("")), "")


if __name__ == "__main__":
    unittest.main()
