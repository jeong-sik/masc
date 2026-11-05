"""Checks the arithmetic of measure_execute_waits.py on small synthetic ledgers.

Run: python3 -B -m unittest discover -s docs/evidence/execute-waits-2026-11
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from collections.abc import Callable
from datetime import date
from typing import cast
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_execute_waits as waits  # noqa: E402

CLOCK_OF = waits.load_lane_time().clock_of

NOON = 1793534400.0  # 2026-11-01T12:00:00Z
SINCE = 1793491200.0  # 2026-11-01T00:00:00Z
MIDNIGHT = 1793577600.0  # 2026-11-02T00:00:00Z
DAY_SECONDS = 86400.0
DAY = date(2026, 11, 1)
RUN_A = "41258710053"
RUN_B = "41279552260"
SCRIPT = pathlib.Path(__file__).resolve().parent / "measure_execute_waits.py"
PROGRAM_TIMEOUT_SECONDS = 60


def rows_of(value: object) -> list[dict[str, object]]:
    assert isinstance(value, list)
    return cast(list[dict[str, object]], value)


def object_of(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    return cast(dict[str, object], value)


def setUpModule() -> None:
    # A local zone other than UTC makes a day or a window edge built without tzinfo differ from the UTC one.
    patch = mock.patch.dict(os.environ, {"TZ": "Asia/Seoul"})
    patch.start()
    time.tzset()
    unittest.addModuleCleanup(time.tzset)
    unittest.addModuleCleanup(patch.stop)


def execute_row(
    keeper: object,
    seconds: object,
    command: str | None = None,
    *,
    argv: list[object] | None = None,
    ts: object = NOON,
    record_kind: str = "tool_call",
    tool: str = "Execute",
) -> dict[str, object]:
    tool_input: dict[str, object] = {"argv": argv} if argv is not None else {"command": command}
    duration = seconds * 1000 if isinstance(seconds, (int, float)) and not isinstance(seconds, bool) else seconds
    return {"ts": ts, "record_kind": record_kind, "keeper": keeper, "tool": tool, "input": tool_input, "duration_ms": duration}


def schedule_row(
    keeper: object,
    *,
    target: object = None,
    message: object = None,
    due: object = None,
    ts: object = NOON,
    outcome: dict[str, object] | None = None,
    **extra: object,
) -> dict[str, object]:
    arguments: dict[str, object] = {}
    if target is not None:
        arguments["keeper_name"] = target
    if message is not None:
        arguments["message"] = message
    if due is not None:
        arguments["due_in_sec"] = due
    row: dict[str, object] = {"ts": ts, "record_kind": "tool_call", "keeper": keeper, "tool": "masc_schedule_create", "input": arguments}
    row.update(outcome if outcome is not None else {"disposition": "completed"})
    row.update(extra)
    return row


def write_day(base: pathlib.Path, name: str, lines: list[object], month: str = "2026-11") -> None:
    folder = base / ".masc" / "tool_calls" / month
    folder.mkdir(parents=True, exist_ok=True)
    chunks: list[bytes] = []
    for line in lines:
        if isinstance(line, bytes):
            chunks.append(line)
        elif isinstance(line, str):
            chunks.append(line.encode("utf-8"))
        else:
            chunks.append(json.dumps(line).encode("utf-8"))
    (folder / name).write_bytes(b"\n".join(chunks) + b"\n")


def write_turns(base: pathlib.Path, keeper: str, name: str, first: float, last: float) -> pathlib.Path:
    """A turn file whose first line is stamped `first` and last line `last`, as read by the lane-time script."""
    folder = base / ".masc" / "keeper_turn_events" / keeper
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    path.write_text(json.dumps({"ts": first}) + "\n" + json.dumps({"ts": last}) + "\n", encoding="utf-8")
    os.utime(path, (last, last))
    return path


def call(
    keeper: str,
    seconds: float,
    *,
    sleeping: bool = False,
    run_ids: tuple[str, ...] = (),
    has_command: bool = True,
    repos: tuple[str, ...] = (),
    kind: waits.Kind | None = None,
    day: date = DAY,
    end: float = NOON,
) -> waits.ExecuteCall:
    chosen = kind if kind is not None else (waits.Kind.RUN if run_ids else waits.Kind.REST)
    return waits.ExecuteCall(keeper, seconds, has_command, sleeping, run_ids, repos, chosen, day, end)


class NumberOfTest(unittest.TestCase):
    def test_finite_numbers_are_numbers(self) -> None:
        self.assertEqual(waits.number_of(3), 3.0)
        self.assertEqual(waits.number_of(2.5), 2.5)
        self.assertEqual(waits.number_of(0), 0.0)
        self.assertEqual(waits.number_of(-1), -1.0)

    def test_other_values_are_not_numbers(self) -> None:
        for value in (True, False, "3", None, [3], {"a": 3}):
            with self.subTest(value=value):
                self.assertIsNone(waits.number_of(value))

    def test_infinity_nan_and_integers_too_large_for_a_float_are_not_numbers(self) -> None:
        for value in (float("inf"), float("-inf"), float("nan"), 10**400, -(10**400)):
            with self.subTest(value=value):
                self.assertIsNone(waits.number_of(value))


class ParseRowTest(unittest.TestCase):
    def test_a_json_object_is_a_row(self) -> None:
        self.assertEqual(waits.parse_row(b'{"a": 1}'), {"a": 1})

    def test_other_json_and_bad_text_are_not_rows(self) -> None:
        for line in (b"[1, 2]", b"3", b"null", b"{not json", b'{"a": NaN}', b'{"a": Infinity}', b'{"a": -Infinity}', b'{"a":\xff}'):
            with self.subTest(line=line):
                self.assertIsNone(waits.parse_row(line))

    def test_a_lone_surrogate_in_the_bytes_is_not_utf8(self) -> None:
        self.assertIsNone(waits.parse_row(b'{"keeper": "\xed\xa0\x80"}'))

    def test_a_number_json_can_read_but_not_a_float_is_still_a_row(self) -> None:
        row = waits.parse_row(b'{"duration_ms": 1e999}')
        assert row is not None
        self.assertIsNone(waits.number_of(row["duration_ms"]))


class KeeperOfTest(unittest.TestCase):
    def test_a_text_keeper_is_used_and_anything_else_is_a_question_mark(self) -> None:
        self.assertEqual(waits.keeper_of({"keeper": "a"}), "a")
        rows: list[dict[str, object]] = [{}, {"keeper": 5}, {"keeper": None}, {"keeper": ["a"]}]
        for row in rows:
            with self.subTest(row=row):
                self.assertEqual(waits.keeper_of(row), "?")


class ParseUntilTest(unittest.TestCase):
    def test_every_spelling_of_the_same_instant_gives_the_same_time(self) -> None:
        expected = 1793854800.0  # 2026-11-05T05:00:00Z
        for text in ("2026-11-05T05:00:00Z", "2026-11-05T05:00:00+00:00", "2026-11-05T14:00:00+09:00", "2026-11-05T05:00:00"):
            with self.subTest(text=text):
                self.assertEqual(waits.parse_until(text), expected)


class CommandOfTest(unittest.TestCase):
    def test_a_command_string_is_used_as_it_is(self) -> None:
        self.assertEqual(waits.command_of({"command": "sleep 3"}), "sleep 3")

    def test_argv_strings_are_joined_by_spaces(self) -> None:
        self.assertEqual(waits.command_of({"argv": ["gh", "run", "view", RUN_A]}), f"gh run view {RUN_A}")

    def test_argv_items_that_are_not_strings_are_written_by_str(self) -> None:
        self.assertEqual(waits.command_of({"argv": ["rg", "-A", 30, None, True]}), "rg -A 30 None True")

    def test_an_empty_argv_is_an_empty_command(self) -> None:
        self.assertEqual(waits.command_of({"argv": []}), "")

    def test_a_shell_script_stays_inside_the_joined_text(self) -> None:
        self.assertEqual(waits.command_of({"argv": ["bash", "-lc", "sleep 7; ls"]}), "bash -lc sleep 7; ls")

    def test_the_command_string_wins_over_argv(self) -> None:
        self.assertEqual(waits.command_of({"argv": ["ls"], "command": "sleep 3"}), "sleep 3")

    def test_argv_is_used_when_the_command_is_not_a_string(self) -> None:
        self.assertEqual(waits.command_of({"argv": ["ls"], "command": ["sleep", "3"]}), "ls")

    def test_other_shapes_have_no_command(self) -> None:
        self.assertIsNone(waits.command_of(None))
        self.assertIsNone(waits.command_of("sleep 3"))
        self.assertIsNone(waits.command_of({}))
        self.assertIsNone(waits.command_of({"argv": "ls"}))
        self.assertIsNone(waits.command_of({"command": 3}))
        self.assertIsNone(waits.command_of({"command": ["sh", "-c", "sleep 3"]}))


class ReposOfTest(unittest.TestCase):
    def test_the_forms_that_name_a_repository(self) -> None:
        for text in (
            "gh api repos/octo/hub/actions/runs/1 --jq .status",
            "gh run view 1 -R octo/hub",
            "gh run view 1 --repo octo/hub",
            "gh run view 1 --repo=octo/hub",
            "curl https://github.com/octo/hub/actions/runs/1",
        ):
            with self.subTest(text=text):
                self.assertEqual(waits.repos_of(text), ("octo/hub",))

    def test_names_are_lower_case_without_git_suffix(self) -> None:
        self.assertEqual(waits.repos_of("git clone https://github.com/Octo/Hub.git"), ("octo/hub",))

    def test_names_are_unique_in_order_of_first_appearance(self) -> None:
        text = "gh run view 1 -R a/x; gh run view 2 -R b/y; gh run view 3 -R A/X"
        self.assertEqual(waits.repos_of(text), ("a/x", "b/y"))

    def test_text_without_a_marker_names_no_repository(self) -> None:
        for text in ("ls src/foo", "cd work/wkbl && gh run view 1", "prepos/octo/hub", "gh run view 1 -Rocto/hub", "curl https://githubXcom/octo/hub", ""):
            with self.subTest(text=text):
                self.assertEqual(waits.repos_of(text), ())

    def test_names_hold_letters_digits_underscores_hyphens_and_dots(self) -> None:
        self.assertEqual(waits.repos_of("gh run view 1 -R a_b-1/c.d-2_e"), ("a_b-1/c.d-2_e",))

    def test_a_name_stops_at_the_next_slash(self) -> None:
        self.assertEqual(waits.repos_of("repos/octo/hub/actions/runs/1"), ("octo/hub",))


class SleepingTest(unittest.TestCase):
    def sleeping(self, command: str) -> bool:
        call = waits.execute_call_of(execute_row("a", 1, command), NOON)
        assert call is not None
        return call.sleeping

    def test_sleep_followed_by_a_number(self) -> None:
        for command in ("sleep 5", "cd /tmp && sleep 30", "sleep 240; gh run view x", "sleep 1.5", "echo; sleep\t7", "sleep  5", "sleep 0", "sleep 0.5"):
            with self.subTest(command=command):
                self.assertTrue(self.sleeping(command))

    def test_other_text_is_not_sleeping(self) -> None:
        for command in ("sleep", "sleep infinity", "asleep 5", "sleep5", "ls -la", ""):
            with self.subTest(command=command):
                self.assertFalse(self.sleeping(command))


class RunIdsOfTest(unittest.TestCase):
    def test_the_forms_that_name_a_run(self) -> None:
        for text in (
            f"gh api repos/o/r/actions/runs/{RUN_A} --jq .status",
            f"gh run view {RUN_A} -R o/r",
            f"gh run watch {RUN_A}",
            f"gh run rerun {RUN_A}",
            f"gh run cancel {RUN_A}",
            f"merge-compile run {RUN_A}(head b3130cf)",
            f"runs {RUN_A}",
            f"gh run  watch  {RUN_A}",
            f"gh run\tview\t{RUN_A}",
        ):
            with self.subTest(text=text):
                self.assertEqual(waits.run_ids_of(text), (RUN_A,))

    def test_ten_and_eleven_digit_ids_are_both_runs(self) -> None:
        self.assertEqual(waits.run_ids_of("gh run view 9876543210"), ("9876543210",))
        self.assertEqual(waits.run_ids_of(f"gh run view {RUN_A}"), (RUN_A,))

    def test_ids_that_are_too_short_or_too_long_are_not_runs(self) -> None:
        self.assertEqual(waits.run_ids_of("run 412587100"), ())
        self.assertEqual(waits.run_ids_of("run 412587100534"), ())
        self.assertEqual(waits.run_ids_of("actions/runs/412587100534"), ())

    def test_a_word_that_only_contains_run_is_not_a_run(self) -> None:
        self.assertEqual(waits.run_ids_of(f"running {RUN_A}"), ())
        self.assertEqual(waits.run_ids_of(f"brun {RUN_A}"), ())

    def test_other_gh_run_verbs_do_not_name_a_wait(self) -> None:
        for verb in ("download", "list", "delete"):
            with self.subTest(verb=verb):
                self.assertEqual(waits.run_ids_of(f"gh run {verb} {RUN_A}"), ())

    def test_a_bare_timestamp_is_not_a_run(self) -> None:
        self.assertEqual(waits.run_ids_of("date -d @1793853513"), ())

    def test_ids_are_unique_in_order_of_first_appearance(self) -> None:
        text = f"actions/runs/{RUN_A} then run {RUN_B} then run {RUN_A}"
        self.assertEqual(waits.run_ids_of(text), (RUN_A, RUN_B))


class KindOfTest(unittest.TestCase):
    def kind(self, command: str | None) -> waits.Kind:
        found = waits.execute_call_of(execute_row("a", 1, command), NOON)
        assert found is not None
        return found.kind

    def test_the_kind_names_are_fixed(self) -> None:
        self.assertEqual([kind.value for kind in waits.Kind], ["names_a_run", "gh_without_run", "build_or_test", "rest"])
        self.assertEqual(waits.KINDS, tuple(waits.Kind))
        self.assertEqual(waits.GITHUB_KINDS, (waits.Kind.RUN, waits.Kind.GH))

    def test_a_kind_is_written_to_json_as_its_name(self) -> None:
        self.assertEqual(json.dumps({"kind": waits.Kind.RUN}), '{"kind": "names_a_run"}')

    def test_a_run_id_wins_over_gh_and_build_tools(self) -> None:
        self.assertEqual(self.kind(f"gh run view {RUN_A} -R o/r"), "names_a_run")
        self.assertEqual(self.kind(f"dune build && gh run watch {RUN_A}"), "names_a_run")
        self.assertEqual(self.kind(f"curl https://api.github.com/repos/o/r/actions/runs/{RUN_A}"), "names_a_run")

    def test_gh_wins_over_build_tools(self) -> None:
        for command in ("gh pr checks 793 -R o/r", "sleep 60; gh api repos/o/r/pulls", "dune build && gh pr view 7", "cd w; gh"):
            with self.subTest(command=command):
                self.assertEqual(self.kind(command), "gh_without_run")

    def test_build_and_test_tools(self) -> None:
        commands = (
            "dune build test/foo.exe",
            "cd w && opam switch create 5.5",
            "make all",
            "npm test",
            "pnpm install",
            "yarn build",
            "cargo build",
            "pytest -q",
            "vitest run",
            "tsc -p .",
            "python3 -m unittest discover",
            "python -m unittest",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.kind(command), "build_or_test")

    def test_everything_else_is_the_rest(self) -> None:
        for command in ("git grep -n foo", "ls -la", "sleep 30; curl -s https://example.org", ""):
            with self.subTest(command=command):
                self.assertEqual(self.kind(command), "rest")

    def test_a_name_that_only_contains_a_tool_word_is_the_rest(self) -> None:
        commands = (
            "ghost",
            "high",
            "highlight",
            "cmake .",
            "makefile",
            "mymake",
            "dunes",
            "tsconfig.json",
            "python3 -m pip install x",
            "python3 -m unittestx",
            "ipython3 -m unittest",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.kind(command), "rest")

    def test_a_call_without_a_command_is_the_rest(self) -> None:
        found = waits.execute_call_of(execute_row("a", 1, None), NOON)
        assert found is not None
        self.assertEqual((found.has_command, found.kind), (False, "rest"))


class ArithmeticTest(unittest.TestCase):
    def test_hours_are_seconds_over_3600_rounded_to_two_places(self) -> None:
        self.assertEqual(waits.hours(0), 0.0)
        self.assertEqual(waits.hours(3600), 1.0)
        self.assertEqual(waits.hours(5400), 1.5)
        self.assertEqual(waits.hours(36), 0.01)
        self.assertEqual(waits.hours(1), 0.0)
        self.assertEqual(waits.hours(360000), 100.0)

    def test_percent_is_rounded_to_one_place_and_empty_without_a_whole(self) -> None:
        self.assertEqual(waits.percent(1, 1), 100.0)
        self.assertEqual(waits.percent(0.5, 0.5), 100.0)
        self.assertEqual(waits.percent(1, 3), 33.3)
        self.assertEqual(waits.percent(0, 5), 0.0)
        self.assertIsNone(waits.percent(1, 0))


class BucketTest(unittest.TestCase):
    def test_labels(self) -> None:
        self.assertEqual(waits.bucket_labels(), ["<1s", "1-3s", "3-10s", "10-60s", "60-300s", ">=300s"])

    def test_an_edge_belongs_to_the_bucket_above_it(self) -> None:
        cases = [(0.0, 0), (0.999, 0), (1.0, 1), (2.999, 1), (3.0, 2), (9.999, 2), (10.0, 3), (59.999, 3), (60.0, 4), (299.999, 4), (300.0, 5), (1e6, 5)]
        for seconds, index in cases:
            with self.subTest(seconds=seconds):
                self.assertEqual(waits.bucket_index(seconds), index)


def kind_row(kind: str, calls: int, hours: float, share: float, sleeping_calls: int, sleeping_hours: float, sleeping_share: float) -> dict[str, object]:
    return {
        "kind": kind,
        "calls": calls,
        "hours": hours,
        "hours_percent_of_long": share,
        "sleeping_calls": sleeping_calls,
        "sleeping_hours": sleeping_hours,
        "sleeping_hours_percent_of_sleeping": sleeping_share,
    }


class SummarizeExecuteTest(unittest.TestCase):
    def test_buckets_and_long_calls(self) -> None:
        calls = [
            call("a", 0.5, has_command=False),
            call("a", 59, run_ids=(RUN_B,)),
            call("b", 60, sleeping=True, run_ids=(RUN_A,)),
            call("b", 120, sleeping=True, kind=waits.Kind.GH),
            call("c", 600, has_command=False),
            call("c", 1200, sleeping=False, run_ids=(RUN_B,)),
            call("d", 100, sleeping=True, kind=waits.Kind.BUILD),
            call("e", 240, sleeping=True),
        ]
        summary = waits.summarize_execute(calls)
        self.assertEqual(summary["calls"], 8)
        self.assertEqual(summary["calls_without_command"], 2)
        self.assertEqual(summary["hours"], 0.66)
        days = rows_of(summary["by_day"])
        self.assertEqual([(row["day"], row["calls"]) for row in days], [("2026-11-01", 8)])
        buckets = rows_of(summary["duration_buckets"])
        self.assertEqual([bucket["label"] for bucket in buckets], waits.bucket_labels())
        self.assertEqual([bucket["calls"] for bucket in buckets], [1, 0, 0, 1, 4, 2])
        self.assertEqual([bucket["hours"] for bucket in buckets], [0.0, 0.0, 0.0, 0.02, 0.14, 0.5])
        self.assertEqual([bucket["hours_percent"] for bucket in buckets], [0.0, 0.0, 0.0, 2.5, 21.9, 75.6])
        self.assertEqual(
            summary["long_calls"],
            {
                "threshold_seconds": 60,
                "calls": 6,
                "calls_percent": 75.0,
                "calls_without_command": 1,
                "hours": 0.64,
                "hours_percent_of_execute": 97.5,
                "github_calls": 3,
                "github_hours": 0.38,
                "github_hours_percent_of_long": 59.5,
                "sleeping_calls": 4,
                "sleeping_hours": 0.14,
                "sleeping_hours_percent_of_long": 22.4,
                "sleeping_github_hours": 0.05,
                "sleeping_github_percent_of_sleeping": 34.6,
                "by_kind": [
                    kind_row("names_a_run", 2, 0.35, 54.3, 1, 0.02, 11.5),
                    kind_row("gh_without_run", 1, 0.03, 5.2, 1, 0.03, 23.1),
                    kind_row("build_or_test", 1, 0.03, 4.3, 1, 0.03, 19.2),
                    kind_row("rest", 2, 0.23, 36.2, 1, 0.07, 46.2),
                ],
            },
        )

    def test_calls_are_grouped_by_utc_day_in_date_order(self) -> None:
        second = date(2026, 11, 2)
        calls = [
            call("a", 30, day=second),
            call("a", 3600, sleeping=True),
            call("b", 120, day=second),
            call("b", 1800, sleeping=True, day=second),
            call("d", 60, day=second),
            call("c", 10),
        ]
        self.assertEqual(
            waits.summarize_days(calls),
            [
                {"day": "2026-11-01", "calls": 2, "hours": 1.0, "long_calls": 1, "long_hours": 1.0, "sleeping_long_hours": 1.0},
                {"day": "2026-11-02", "calls": 4, "hours": 0.56, "long_calls": 3, "long_hours": 0.55, "sleeping_long_hours": 0.5},
            ],
        )
        self.assertEqual(waits.summarize_days([]), [])

    def test_a_sleeping_call_under_the_threshold_is_not_long(self) -> None:
        summary = waits.summarize_execute([call("a", 59.9, sleeping=True, run_ids=(RUN_A,))])
        long_calls = object_of(summary["long_calls"])
        self.assertEqual((long_calls["calls"], long_calls["sleeping_calls"]), (0, 0))
        self.assertEqual([row["calls"] for row in rows_of(long_calls["by_kind"])], [0, 0, 0, 0])

    def test_every_kind_has_a_row_in_by_kind(self) -> None:
        summary = waits.summarize_execute([call("a", 100, kind=kind) for kind in waits.Kind])
        long_calls = object_of(summary["long_calls"])
        self.assertEqual(long_calls["calls"], len(waits.Kind))
        by_kind = rows_of(long_calls["by_kind"])
        self.assertEqual([(row["kind"], row["calls"]) for row in by_kind], [(kind.value, 1) for kind in waits.Kind])
        self.assertEqual((long_calls["github_calls"], long_calls["github_hours"], long_calls["github_hours_percent_of_long"]), (2, 0.06, 50.0))

    def test_the_github_share_counts_sleeping_and_sleepless_calls_of_both_github_kinds(self) -> None:
        calls = [
            call("a", 3600, sleeping=True, run_ids=(RUN_A,)),
            call("a", 1800, run_ids=(RUN_A,)),
            call("a", 1800, kind=waits.Kind.GH),
            call("a", 3600, kind=waits.Kind.BUILD),
            call("a", 1800),
            call("a", 59, run_ids=(RUN_A,)),
        ]
        long_calls = object_of(waits.summarize_execute(calls)["long_calls"])
        self.assertEqual((long_calls["calls"], long_calls["hours"]), (5, 3.5))
        self.assertEqual((long_calls["github_calls"], long_calls["github_hours"], long_calls["github_hours_percent_of_long"]), (3, 2.0, 57.1))
        self.assertEqual((long_calls["sleeping_github_hours"], long_calls["sleeping_github_percent_of_sleeping"]), (1.0, 100.0))

    def test_no_calls_gives_no_percentages(self) -> None:
        summary = waits.summarize_execute([])
        self.assertEqual((summary["calls"], summary["calls_without_command"], summary["hours"]), (0, 0, 0.0))
        long_calls = object_of(summary["long_calls"])
        self.assertEqual(long_calls["calls_without_command"], 0)
        kinds = rows_of(long_calls["by_kind"])
        self.assertEqual([row["kind"] for row in kinds], ["names_a_run", "gh_without_run", "build_or_test", "rest"])
        self.assertTrue(all(row["calls"] == 0 and row["hours_percent_of_long"] is None for row in kinds))
        self.assertTrue(all(row["sleeping_hours_percent_of_sleeping"] is None for row in kinds))
        self.assertIsNone(long_calls["sleeping_github_percent_of_sleeping"])
        self.assertEqual((long_calls["github_calls"], long_calls["github_hours"]), (0, 0.0))
        self.assertIsNone(long_calls["github_hours_percent_of_long"])
        self.assertIsNone(long_calls["calls_percent"])
        self.assertIsNone(long_calls["hours_percent_of_execute"])
        self.assertIsNone(long_calls["sleeping_hours_percent_of_long"])
        buckets = rows_of(summary["duration_buckets"])
        self.assertTrue(all(bucket["hours_percent"] is None for bucket in buckets))


class RunWaitTest(unittest.TestCase):
    CALLS = [
        call("a", 60, sleeping=True, run_ids=(RUN_A,)),
        call("a", 120, sleeping=True, run_ids=(RUN_A,)),
        call("a", 100, sleeping=True, run_ids=(RUN_A, RUN_B)),
        call("b", 300, sleeping=True, run_ids=(RUN_A,)),
        call("b", 300, sleeping=True, run_ids=(RUN_A,)),
        call("a", 500, sleeping=False, run_ids=(RUN_A,)),
        call("a", 45, sleeping=True),
    ]

    def test_a_poll_call_sleeps_and_names_a_run(self) -> None:
        self.assertEqual([found.seconds for found in waits.poll_calls(self.CALLS)], [60, 120, 100, 300, 300])

    def test_a_wait_is_one_keeper_and_one_run(self) -> None:
        self.assertEqual(
            waits.run_waits(self.CALLS),
            {("a", RUN_A): [60, 120, 100], ("a", RUN_B): [100], ("b", RUN_A): [300, 300]},
        )

    def test_single_poll_waits_are_counted_apart_from_longer_ones(self) -> None:
        calls = [
            call("a", 60, sleeping=True, run_ids=(RUN_A,)),
            call("b", 60, sleeping=True, run_ids=(RUN_A,)),
            call("a", 60, sleeping=True, run_ids=(RUN_B,)),
            call("a", 60, sleeping=True, run_ids=(RUN_B,)),
        ]
        summary = waits.summarize_run_waits(calls)
        self.assertEqual((summary["waits"], summary["single_poll_waits"]), (3, 2))

    def test_summary(self) -> None:
        summary = waits.summarize_run_waits(self.CALLS)
        self.assertEqual(summary["waits"], 3)
        self.assertEqual(summary["single_poll_waits"], 1)
        self.assertEqual(summary["polls_per_wait"], {"median": 2.0, "p90": 3.0, "max": 3.0})
        self.assertEqual(summary["blocked_minutes_per_wait"], {"median": 4.7, "p90": 10.0, "max": 10.0})
        self.assertEqual(
            summary["top_keepers"],
            [{"keeper": "b", "blocked_hours": 0.17, "waits": 1}, {"keeper": "a", "blocked_hours": 0.08, "waits": 2}],
        )

    def test_the_totals_count_a_call_that_names_two_runs_once(self) -> None:
        summary = waits.summarize_run_waits(self.CALLS)
        self.assertEqual(summary["polls"], 5)
        self.assertEqual(summary["polls_naming_several_runs"], 1)
        self.assertEqual(summary["blocked_hours"], 0.24)
        self.assertEqual(summary["blocked_hours_percent_of_execute"], 61.8)

    def test_summed_over_waits_the_call_counts_in_each_wait(self) -> None:
        summary = waits.summarize_run_waits(self.CALLS)
        self.assertEqual(summary["polls_summed_over_waits"], 6)
        self.assertEqual(summary["blocked_hours_summed_over_waits"], 0.27)

    def test_no_waits(self) -> None:
        summary = waits.summarize_run_waits([call("a", 500, run_ids=(RUN_A,))])
        self.assertEqual((summary["waits"], summary["polls"], summary["blocked_hours"]), (0, 0, 0.0))
        self.assertEqual((summary["polls_naming_several_runs"], summary["polls_summed_over_waits"], summary["blocked_hours_summed_over_waits"]), (0, 0, 0.0))
        self.assertEqual(summary["polls_per_wait"], {"median": None, "p90": None, "max": None})
        self.assertEqual(summary["blocked_hours_percent_of_execute"], 0.0)
        self.assertIsNone(waits.summarize_run_waits([])["blocked_hours_percent_of_execute"])
        self.assertEqual(summary["top_keepers"], [])

    def test_the_cap_is_eight_and_ties_break_by_name(self) -> None:
        self.assertEqual(waits.TOP_KEEPERS, 8)
        names = [f"k{index:02d}" for index in reversed(range(waits.TOP_KEEPERS + 3))]
        many = [call(name, 60, sleeping=True, run_ids=(RUN_A,)) for name in names]
        top = rows_of(waits.summarize_run_waits(many)["top_keepers"])
        self.assertEqual([entry["keeper"] for entry in top], [f"k{index:02d}" for index in range(waits.TOP_KEEPERS)])


class RunWaitRepoTest(unittest.TestCase):
    CALLS = [
        call("a", 3600, sleeping=True, run_ids=(RUN_A,), repos=("o/x",)),
        call("a", 1800, sleeping=True, run_ids=(RUN_A,)),
        call("a", 900, sleeping=True, run_ids=(RUN_B,), repos=("o/x", "o/y")),
        call("b", 3600, sleeping=True, run_ids=(RUN_A,)),
        call("b", 3600, sleeping=True, run_ids=(RUN_A,)),
        call("b", 600, sleeping=False, run_ids=(RUN_B,), repos=("o/z",)),
    ]

    def test_a_wait_names_the_repositories_of_any_of_its_polls(self) -> None:
        self.assertEqual(
            waits.run_wait_repos(self.CALLS),
            {("a", RUN_A): {"o/x"}, ("a", RUN_B): {"o/x", "o/y"}, ("b", RUN_A): set()},
        )

    def test_summary(self) -> None:
        self.assertEqual(
            waits.summarize_repos(self.CALLS),
            {
                "waits_without_a_repo": 1,
                "blocked_hours_without_a_repo": 2.0,
                "by_repo": [
                    {"repo": "o/x", "waits": 2, "blocked_hours": 1.75},
                    {"repo": "o/y", "waits": 1, "blocked_hours": 0.25},
                ],
            },
        )

    def test_a_call_counts_once_in_a_repository_however_many_of_its_waits_name_it(self) -> None:
        calls = [
            call("a", 3600, sleeping=True, run_ids=(RUN_A, RUN_B), repos=("o/x",)),
            call("a", 1800, sleeping=True, run_ids=(RUN_B,), repos=("o/y",)),
        ]
        self.assertEqual(
            waits.summarize_repos(calls),
            {
                "waits_without_a_repo": 0,
                "blocked_hours_without_a_repo": 0.0,
                "by_repo": [
                    {"repo": "o/x", "waits": 2, "blocked_hours": 1.5},
                    {"repo": "o/y", "waits": 1, "blocked_hours": 1.5},
                ],
            },
        )

    def test_a_call_without_a_repo_inherits_the_repo_of_its_wait_through_either_run(self) -> None:
        calls = [
            call("a", 3600, sleeping=True, run_ids=(RUN_A,), repos=("o/x",)),
            call("a", 1800, sleeping=True, run_ids=(RUN_B, RUN_A)),
            call("a", 900, sleeping=True, run_ids=(RUN_B,)),
        ]
        summary = waits.summarize_repos(calls)
        self.assertEqual(summary["waits_without_a_repo"], 1)
        self.assertEqual(summary["blocked_hours_without_a_repo"], 0.25)
        self.assertEqual(summary["by_repo"], [{"repo": "o/x", "waits": 1, "blocked_hours": 1.5}])

    def test_the_run_wait_summary_holds_it(self) -> None:
        self.assertEqual(waits.summarize_run_waits(self.CALLS)["repos"], waits.summarize_repos(self.CALLS))

    def test_no_waits(self) -> None:
        self.assertEqual(
            waits.summarize_repos([call("a", 500, run_ids=(RUN_A,), repos=("o/x",))]),
            {"waits_without_a_repo": 0, "blocked_hours_without_a_repo": 0.0, "by_repo": []},
        )

    def test_repositories_are_capped_and_ties_break_by_name(self) -> None:
        self.assertEqual(waits.TOP_REPOS, 8)
        names = [f"o/r{index:02d}" for index in reversed(range(waits.TOP_REPOS + 3))]
        many = [call("a", 60, sleeping=True, run_ids=(f"{index:010d}",), repos=(name,)) for index, name in enumerate(names)]
        top = rows_of(waits.summarize_repos(many)["by_repo"])
        self.assertEqual([entry["repo"] for entry in top], [f"o/r{index:02d}" for index in range(waits.TOP_REPOS)])


class NearestRankTest(unittest.TestCase):
    def test_ranks(self) -> None:
        values = [4.0, 1.0, 3.0, 2.0]
        self.assertEqual(waits.nearest_rank(values, 0.5), 2.0)
        self.assertEqual(waits.nearest_rank(values, 0.9), 4.0)
        self.assertEqual(waits.nearest_rank(values, 0.1), 1.0)
        self.assertEqual(waits.nearest_rank([7.0], 0.9), 7.0)
        self.assertIsNone(waits.nearest_rank([], 0.5))

    def test_the_fractions_are_ten_fifty_and_ninety_percent(self) -> None:
        self.assertEqual((waits.P10, waits.MEDIAN, waits.P90), (0.1, 0.5, 0.9))
        ten = [float(number) for number in range(1, 11)]
        self.assertEqual([waits.nearest_rank(ten, fraction) for fraction in (waits.P10, waits.MEDIAN, waits.P90)], [1.0, 5.0, 9.0])
        thirty = [float(number) for number in range(1, 31)]
        self.assertEqual([waits.nearest_rank(thirty, fraction) for fraction in (waits.P10, waits.MEDIAN, waits.P90)], [3.0, 15.0, 27.0])

    def test_a_fractional_rank_rounds_up(self) -> None:
        sixteen = [float(number) for number in range(1, 17)]
        seventeen = [float(number) for number in range(1, 18)]
        self.assertEqual(waits.nearest_rank(sixteen, waits.P90), 15.0)
        self.assertEqual(waits.nearest_rank(sixteen, waits.P10), 2.0)
        self.assertEqual(waits.nearest_rank(seventeen, waits.MEDIAN), 9.0)


class WakeSummaryTest(unittest.TestCase):
    def test_summary(self) -> None:
        wakes = [
            waits.ScheduleWake("a", 900.0, (RUN_A,)),
            waits.ScheduleWake("a", 1500.0, (RUN_B,)),
            waits.ScheduleWake("a", 3600.0, ()),
            waits.ScheduleWake("b", None, (RUN_A,)),
            waits.ScheduleWake("a", 1800.0, (RUN_A,)),
        ]
        summary = waits.summarize_wakes(wakes, 9)
        self.assertEqual(summary["creates"], 9)
        self.assertEqual(summary["self_wakes"], 5)
        self.assertEqual(summary["self_wakes_naming_a_run"], 4)
        self.assertEqual(summary["distinct_keeper_run_pairs"], 3)
        self.assertEqual(summary["due_in_sec_of_those"], {"p10": 900.0, "median": 1500.0, "p90": 1800.0})
        self.assertEqual(summary["top_keepers"], [{"keeper": "a", "wakes": 3}, {"keeper": "b", "wakes": 1}])

    def test_one_wake_naming_two_runs_makes_two_pairs(self) -> None:
        summary = waits.summarize_wakes([waits.ScheduleWake("a", 60.0, (RUN_A, RUN_B))], 1)
        self.assertEqual((summary["self_wakes_naming_a_run"], summary["distinct_keeper_run_pairs"]), (1, 2))

    def test_top_keepers_are_capped_and_ties_break_by_name(self) -> None:
        self.assertEqual(waits.TOP_KEEPERS, 8)
        names = [f"k{index:02d}" for index in reversed(range(waits.TOP_KEEPERS + 3))]
        wakes = [waits.ScheduleWake(name, 60.0, (RUN_A,)) for name in names]
        top = rows_of(waits.summarize_wakes(wakes, len(wakes))["top_keepers"])
        self.assertEqual([entry["keeper"] for entry in top], [f"k{index:02d}" for index in range(waits.TOP_KEEPERS)])

    def test_no_wakes(self) -> None:
        summary = waits.summarize_wakes([], 4)
        self.assertEqual((summary["creates"], summary["self_wakes"], summary["self_wakes_naming_a_run"]), (4, 0, 0))
        self.assertEqual(summary["due_in_sec_of_those"], {"p10": None, "median": None, "p90": None})
        self.assertEqual(summary["top_keepers"], [])


class KeepersInBothTest(unittest.TestCase):
    def test_only_keepers_with_both_patterns(self) -> None:
        calls = [call("a", 600, sleeping=True, run_ids=(RUN_A,)), call("b", 60, sleeping=True, run_ids=(RUN_A,)), call("c", 60, sleeping=True)]
        wakes = [
            waits.ScheduleWake("a", 1.0, (RUN_B,)),
            waits.ScheduleWake("a", 1.0, (RUN_A,)),
            waits.ScheduleWake("c", 1.0, (RUN_A,)),
            waits.ScheduleWake("b", 1.0, ()),
        ]
        self.assertEqual(waits.keepers_in_both(calls, wakes), [{"keeper": "a", "blocked_hours": 0.17, "self_wakes_naming_a_run": 2}])

    def test_most_blocked_first_and_equal_hours_by_name(self) -> None:
        tied = [f"k{index}" for index in reversed(range(8))]
        calls = [call("slow", 3600, sleeping=True, run_ids=(RUN_A,))] + [call(name, 7200, sleeping=True, run_ids=(RUN_A,)) for name in tied]
        wakes = [waits.ScheduleWake(name, 1.0, (RUN_B,)) for name in ["slow", *tied]]
        self.assertEqual(
            [entry["keeper"] for entry in waits.keepers_in_both(calls, wakes)],
            [f"k{index}" for index in range(8)] + ["slow"],
        )


class ReadLedgerTest(unittest.TestCase):
    def read(self, base: pathlib.Path, *, since: float = SINCE, until: float = MIDNIGHT) -> waits.Ledger:
        return waits.read_ledger(base, DAY, DAY, since, until)

    def test_live_file_and_rotated_segment_are_both_read(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 10, "ls")])
            write_day(base, "01.001.jsonl", [execute_row("b", 20, "ls")])
            ledger = self.read(base)
            self.assertEqual(sorted(call.keeper for call in ledger.executes), ["a", "b"])

    def test_only_the_asked_days_are_read(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 10, "ls")])
            write_day(base, "02.jsonl", [execute_row("next_day_file", 10, "ls")])
            write_day(base, "31.jsonl", [execute_row("previous_day_file", 10, "ls")], month="2026-10")
            ledger = self.read(base)
            self.assertEqual([call.keeper for call in ledger.executes], ["a"])
            self.assertEqual(ledger.files_read, 1)
            self.assertEqual(ledger.days_without_file, [])

    def test_days_without_a_file_are_listed_and_files_are_counted(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 5, "ls")])
            write_day(base, "01.001.jsonl", [execute_row("a", 5, "ls")])
            write_day(base, "03.jsonl", [execute_row("a", 5, "ls", ts=SINCE + 2 * DAY_SECONDS + 60)])
            ledger = waits.read_ledger(base, DAY, date(2026, 11, 4), SINCE, SINCE + 4 * DAY_SECONDS)
            self.assertEqual(ledger.files_read, 3)
            self.assertEqual(ledger.days_without_file, [date(2026, 11, 2), date(2026, 11, 4)])

    def test_no_file_at_all_reads_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            ledger = self.read(pathlib.Path(raw))
            self.assertEqual((ledger.files_read, ledger.days_without_file, ledger.executes), (0, [DAY], []))

    def test_every_day_of_the_range_is_read(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            for day_number, keeper in ((1, "first"), (2, "second"), (3, "third")):
                write_day(base, f"{day_number:02d}.jsonl", [execute_row(keeper, 5, "ls", ts=SINCE + (day_number - 1) * DAY_SECONDS + 60)])
            ledger = waits.read_ledger(base, DAY, date(2026, 11, 3), SINCE, SINCE + 3 * DAY_SECONDS)
            self.assertEqual([call.keeper for call in ledger.executes], ["first", "second", "third"])
            self.assertEqual([call.day for call in ledger.executes], [DAY, date(2026, 11, 2), date(2026, 11, 3)])

    def test_the_day_of_a_call_is_its_utc_date(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("late", 5, "ls", ts=MIDNIGHT - 1), execute_row("next", 5, "ls", ts=MIDNIGHT)])
            ledger = waits.read_ledger(base, DAY, DAY, SINCE, MIDNIGHT + 1)
            self.assertEqual([(call.keeper, call.day) for call in ledger.executes], [("late", DAY), ("next", date(2026, 11, 2))])

    def test_window_start_is_included_and_end_is_not(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(
                base,
                "01.jsonl",
                [
                    execute_row("at_since", 1, "ls", ts=SINCE),
                    execute_row("before", 1, "ls", ts=SINCE - 1),
                    execute_row("last_second", 1, "ls", ts=NOON + 1),
                    execute_row("at_until", 1, "ls", ts=NOON + 2),
                ],
            )
            ledger = self.read(base, until=NOON + 2)
            self.assertEqual(sorted(call.keeper for call in ledger.executes), ["at_since", "last_second"])
            self.assertEqual(ledger.rows_in_window, 2)

    def test_rows_that_are_not_execute_calls_are_left_out(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(
                base,
                "01.jsonl",
                [
                    execute_row("ok", 5, "ls"),
                    execute_row("other_kind", 5, "ls", record_kind="tool_call_start"),
                    execute_row("other_tool", 5, "ls", tool="Read"),
                    execute_row("no_duration", None, "ls"),
                    execute_row("negative", -1, "ls"),
                    execute_row("one_millisecond_below_zero", -0.001, "ls"),
                    execute_row("bool_duration", True, "ls"),
                    execute_row("text_duration", "5", "ls"),
                    execute_row("no_stamp", 5, "ls", ts=None),
                    execute_row("text_stamp", 5, "ls", ts="1793534400"),
                ],
            )
            ledger = self.read(base)
            self.assertEqual([call.keeper for call in ledger.executes], ["ok"])
            self.assertEqual(ledger.rows_in_window, 8)
            self.assertEqual(ledger.skipped_lines, 0)
            self.assertEqual(ledger.rows_without_timestamp, 2)
            self.assertEqual(ledger.executes_without_duration, 5)

    def test_numbers_that_are_not_finite_are_counted_and_do_not_crash(self) -> None:
        huge = "9" * 400
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(
                base,
                "01.jsonl",
                [
                    execute_row("ok", 5, "ls"),
                    f'{{"ts": {NOON}, "record_kind": "tool_call", "tool": "Execute", "keeper": "inf", "input": {{"command": "ls"}}, "duration_ms": 1e999}}',
                    f'{{"ts": {NOON}, "record_kind": "tool_call", "tool": "Execute", "keeper": "huge", "input": {{"command": "ls"}}, "duration_ms": {huge}}}',
                    '{"ts": 1e999, "record_kind": "tool_call", "tool": "Execute", "keeper": "late", "input": {"command": "ls"}, "duration_ms": 5}',
                    f'{{"ts": {huge}, "record_kind": "tool_call", "tool": "Execute", "keeper": "far", "input": {{"command": "ls"}}, "duration_ms": 5}}',
                ],
            )
            ledger = self.read(base)
            self.assertEqual([call.keeper for call in ledger.executes], ["ok"])
            self.assertEqual((ledger.executes_without_duration, ledger.rows_without_timestamp, ledger.skipped_lines), (2, 2, 0))

    def test_a_zero_second_call_and_an_empty_command_are_kept(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 0, "")])
            self.assertEqual(self.read(base).executes, [waits.ExecuteCall("a", 0.0, True, False, (), (), waits.Kind.REST, DAY, NOON)])

    def test_a_line_the_json_parser_gives_up_on_for_its_depth_is_skipped_and_counted(self) -> None:
        # How deep a line must nest before the parser raises RecursionError depends on the Python build.
        real_loads = json.loads

        def loads(text: str, *, parse_constant: Callable[[str], object]) -> object:
            if "nested too deep" in text:
                raise RecursionError("maximum recursion depth exceeded while decoding a JSON array")
            return real_loads(text, parse_constant=parse_constant)

        with tempfile.TemporaryDirectory() as raw, mock.patch.object(json, "loads", loads):
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("ok", 5, "ls"), '{"note": "nested too deep"}'])
            ledger = self.read(base)
            self.assertEqual([call.keeper for call in ledger.executes], ["ok"])
            self.assertEqual((ledger.rows_in_window, ledger.skipped_lines), (1, 1))

    def test_unreadable_lines_are_counted_and_blank_lines_are_not(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(
                base,
                "01.jsonl",
                [
                    execute_row("ok", 5, "ls"),
                    "{not json",
                    "[1, 2]",
                    b'{"tool":"Execute","duration_ms":\xff}',
                    b'{"tool":"Execute","keeper":"\xed\xa0\x80"}',
                    '{"tool":"Execute","duration_ms":NaN}',
                    '{"tool":"Execute","duration_ms":Infinity}',
                    "",
                    "   ",
                ],
            )
            ledger = self.read(base)
            self.assertEqual([call.keeper for call in ledger.executes], ["ok"])
            self.assertEqual((ledger.rows_in_window, ledger.skipped_lines), (1, 6))

    def test_an_execute_call_keeps_its_command_facts(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(
                base,
                "01.jsonl",
                [
                    execute_row("a", 61.5, argv=["bash", "-lc", f"sleep 240; gh api repos/o/r/actions/runs/{RUN_A}"]),
                    execute_row("b", 3, argv=["gh", "run", "view", RUN_B, "-R", "O/R"]),
                    execute_row("c", 2, None, argv=None),
                    execute_row("d", 5, "sleep 5"),
                    execute_row("e", 1, argv=["rg", "-A", 30]),
                    execute_row("f", 1, argv=[]),
                ],
            )
            calls = self.read(base).executes
            self.assertEqual(calls[0], waits.ExecuteCall("a", 61.5, True, True, (RUN_A,), ("o/r",), waits.Kind.RUN, DAY, NOON))
            self.assertEqual(calls[1], waits.ExecuteCall("b", 3.0, True, False, (RUN_B,), ("o/r",), waits.Kind.RUN, DAY, NOON))
            self.assertEqual(calls[2], waits.ExecuteCall("c", 2.0, False, False, (), (), waits.Kind.REST, DAY, NOON))
            self.assertEqual(calls[3], waits.ExecuteCall("d", 5.0, True, True, (), (), waits.Kind.REST, DAY, NOON))
            self.assertEqual(calls[4], waits.ExecuteCall("e", 1.0, True, False, (), (), waits.Kind.REST, DAY, NOON))
            self.assertEqual(calls[5], waits.ExecuteCall("f", 1.0, True, False, (), (), waits.Kind.REST, DAY, NOON))

    def test_schedule_creates(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(
                base,
                "01.jsonl",
                [
                    schedule_row("a", target="a", message=f"check run {RUN_A}", due=900),
                    schedule_row("a", target="b", message=f"check run {RUN_A}", due=900),
                    schedule_row("a", target="a", message="look again", due=60),
                    schedule_row("a", target="a", message=f"check run {RUN_B}", due=61, outcome={"disposition": "failed"}, failure_class="workflow_rejection"),
                    schedule_row("a", target="a", message=5, due="soon"),
                    schedule_row("a", message=f"check run {RUN_A}", due=900),
                    schedule_row("a", target="a", message=[f"check run {RUN_A}"], due=30),
                    {"ts": NOON, "record_kind": "tool_call", "keeper": "a", "tool": "masc_schedule_create", "input": "oops", "disposition": "completed"},
                    schedule_row("a", target="a", message="late", due=60, ts=MIDNIGHT),
                ],
            )
            ledger = self.read(base)
            self.assertEqual(ledger.schedule_creates, 7)
            self.assertEqual(
                ledger.wakes,
                [
                    waits.ScheduleWake("a", 900.0, (RUN_A,)),
                    waits.ScheduleWake("a", 60.0, ()),
                    waits.ScheduleWake("a", None, ()),
                    waits.ScheduleWake("a", 30.0, ()),
                ],
            )

    def test_the_recorded_outcome_decides_which_schedule_rows_count(self) -> None:
        cases: list[tuple[str, dict[str, object], bool]] = [
            ("completed", {"disposition": "completed"}, True),
            ("wire ok only", {"wire_outcome": "ok"}, True),
            ("completed beats a wire error", {"disposition": "completed", "wire_outcome": "error"}, True),
            ("failed", {"disposition": "failed"}, False),
            ("wire error only", {"wire_outcome": "error"}, False),
            ("failed beats a wire ok", {"disposition": "failed", "wire_outcome": "ok"}, False),
            ("nothing recorded", {}, False),
            ("deferred", {"disposition": "deferred"}, False),
            ("unknown disposition", {"disposition": "weird"}, False),
            ("disposition not a string", {"disposition": 5}, False),
            ("wire unknown", {"wire_outcome": "unknown"}, False),
        ]
        for name, outcome, counted in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw:
                base = pathlib.Path(raw)
                write_day(base, "01.jsonl", [schedule_row("a", target="a", message=f"run {RUN_A}", due=60, outcome=outcome)])
                ledger = self.read(base)
                self.assertEqual((ledger.schedule_creates, len(ledger.wakes)), (1, 1) if counted else (0, 0))

    def test_a_failure_class_does_not_overrule_a_completed_disposition(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [schedule_row("a", target="a", message="x", due=60, failure_class="odd")])
            self.assertEqual(self.read(base).schedule_creates, 1)


class SummarizeTurnTimeTest(unittest.TestCase):
    TURNS = {"a": CLOCK_OF([(NOON, NOON + 3600)]), "b": CLOCK_OF([(NOON, NOON + 1800)])}

    def test_each_group_splits_into_the_hours_inside_and_outside_the_turn_intervals(self) -> None:
        calls = [
            call("a", 600, sleeping=True, run_ids=(RUN_A,), end=NOON + 1000),  # long github, a poll, inside
            call("a", 600, kind=waits.Kind.GH, end=NOON + 5000),  # long github, outside
            call("a", 600, kind=waits.Kind.BUILD, end=NOON + 3900),  # long build, half inside
            call("b", 30, end=NOON + 100),  # short, inside
            call("c", 100, end=NOON + 1000),  # long, a Keeper without turn files
            call("a", 59, sleeping=True, run_ids=(RUN_B,), end=NOON + 2000),  # a poll that is not long, inside
        ]
        summary = waits.summarize_turn_time(calls, self.TURNS)
        self.assertEqual((summary["keepers_with_turn_traces"], summary["hours"]), (2, 1.5))
        self.assertEqual(
            object_of(summary["execute"]),
            {"calls": 6, "hours": 0.55, "inside_hours": 0.27, "outside_hours": 0.28, "inside_percent_of_turn_time": 18.3},
        )
        self.assertEqual(
            object_of(summary["long_calls"]),
            {"calls": 4, "hours": 0.53, "inside_hours": 0.25, "outside_hours": 0.28, "inside_percent_of_turn_time": 16.7},
        )
        self.assertEqual(
            object_of(summary["github_calls"]),
            {"calls": 2, "hours": 0.33, "inside_hours": 0.17, "outside_hours": 0.17, "inside_percent_of_turn_time": 11.1},
        )
        self.assertEqual(
            object_of(summary["build_or_test_calls"]),
            {"calls": 1, "hours": 0.17, "inside_hours": 0.08, "outside_hours": 0.08, "inside_percent_of_turn_time": 5.6},
        )
        self.assertEqual(
            object_of(summary["poll_calls"]),
            {"calls": 2, "hours": 0.18, "inside_hours": 0.18, "outside_hours": 0.0, "inside_percent_of_turn_time": 12.2},
        )
        self.assertEqual(object_of(summary["execute_of_keepers_without_turn_traces"]), {"keepers": 1, "calls": 1, "hours": 0.03})

    def test_a_call_counts_only_in_the_intervals_of_its_own_keeper(self) -> None:
        # Keeper b is in a turn from NOON to NOON + 1800 only, so a call of b at NOON + 3000 is outside.
        summary = waits.summarize_turn_time([call("b", 100, end=NOON + 3000)], self.TURNS)
        self.assertEqual(object_of(summary["execute"])["inside_hours"], 0.0)

    def test_the_two_github_kinds_make_the_github_group_and_only_calls_of_sixty_seconds_or_more_are_long(self) -> None:
        calls = [
            call("a", 100, kind=waits.Kind.RUN, end=NOON + 1000),
            call("a", 100, kind=waits.Kind.GH, end=NOON + 1000),
            call("a", 100, kind=waits.Kind.BUILD, end=NOON + 1000),
            call("a", 100, kind=waits.Kind.REST, end=NOON + 1000),
            call("a", 60, kind=waits.Kind.GH, end=NOON + 1000),  # exactly the limit: long
            call("a", 59, kind=waits.Kind.GH, end=NOON + 1000),  # under the limit: in no group but execute
            call("a", 59, kind=waits.Kind.BUILD, end=NOON + 1000),
        ]
        summary = waits.summarize_turn_time(calls, self.TURNS)
        self.assertEqual(object_of(summary["github_calls"])["calls"], 3)
        self.assertEqual(object_of(summary["build_or_test_calls"])["calls"], 1)
        self.assertEqual(object_of(summary["long_calls"])["calls"], 5)
        self.assertEqual(object_of(summary["execute"])["calls"], 7)

    def test_the_calls_of_keepers_without_a_turn_file_are_counted_by_call_and_by_keeper(self) -> None:
        calls = [
            call("c", 30, end=NOON + 100),
            call("c", 36, end=NOON + 200),
            call("d", 42, end=NOON + 300),
            call("a", 3600, end=NOON + 1000),  # a Keeper with a turn file
        ]
        summary = waits.summarize_turn_time(calls, self.TURNS)
        self.assertEqual(object_of(summary["execute_of_keepers_without_turn_traces"]), {"keepers": 2, "calls": 3, "hours": 0.03})

    def test_a_poll_call_is_sleeping_and_names_a_run_whatever_its_length(self) -> None:
        calls = [
            call("a", 5, sleeping=True, run_ids=(RUN_A,), end=NOON + 1000),
            call("a", 500, sleeping=False, run_ids=(RUN_A,), end=NOON + 1000),
            call("a", 500, sleeping=True, end=NOON + 1000),
        ]
        self.assertEqual(object_of(waits.summarize_turn_time(calls, self.TURNS)["poll_calls"])["calls"], 1)

    def test_without_turn_files_every_call_is_outside_and_no_share_is_given(self) -> None:
        summary = waits.summarize_turn_time([call("a", 3600, end=NOON + 1000), call("b", 3600, end=NOON + 1000)], {})
        self.assertEqual((summary["keepers_with_turn_traces"], summary["hours"]), (0, 0.0))
        self.assertEqual(
            object_of(summary["execute"]),
            {"calls": 2, "hours": 2.0, "inside_hours": 0.0, "outside_hours": 2.0, "inside_percent_of_turn_time": None},
        )
        self.assertEqual(object_of(summary["execute_of_keepers_without_turn_traces"]), {"keepers": 2, "calls": 2, "hours": 2.0})

    def test_no_calls_hold_no_time_and_a_zero_share(self) -> None:
        summary = waits.summarize_turn_time([], self.TURNS)
        empty = {"calls": 0, "hours": 0.0, "inside_hours": 0.0, "outside_hours": 0.0, "inside_percent_of_turn_time": 0.0}
        for group in ("execute", "long_calls", "github_calls", "build_or_test_calls", "poll_calls"):
            self.assertEqual(object_of(summary[group]), empty, group)
        self.assertEqual(object_of(summary["execute_of_keepers_without_turn_traces"]), {"keepers": 0, "calls": 0, "hours": 0.0})

    def test_the_turn_time_is_the_sum_of_the_keepers_merged_intervals(self) -> None:
        turns = {"a": CLOCK_OF([(0, 100), (50, 150)]), "b": CLOCK_OF([(0, 100)])}
        # Keeper a holds 150 s, b 100 s: 250 s, not 350 s.
        summary = waits.summarize_turn_time([call("a", 25, end=100.0)], turns)
        self.assertEqual(object_of(summary["execute"])["inside_percent_of_turn_time"], 10.0)


class MainTest(unittest.TestCase):
    def run_main(self, base: pathlib.Path, *arguments: str) -> tuple[dict[str, object], str]:
        argv = ["measure_execute_waits.py", "--base-path", str(base), *arguments]
        out = io.StringIO()
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(out):
            self.assertEqual(waits.main(), 0)
        return json.loads(out.getvalue()), out.getvalue()

    def test_the_summary_is_printed_and_written(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(
                base,
                "01.jsonl",
                [
                    execute_row("a", 108, argv=["bash", "-c", f"sleep 108; gh run view {RUN_A}"]),
                    schedule_row("a", target="a", message=f"run {RUN_A}", due=300),
                    schedule_row("a", target="a", message="later", due=60),
                    schedule_row("a", target="other", message="hello", due=60),
                    execute_row("early", 90, "ls", ts=SINCE - 1),
                    execute_row("late", 90, "ls", ts=MIDNIGHT),
                    "{not json",
                    "[1, 2]",
                    execute_row("no_stamp", 5, "ls", ts=None),
                    execute_row("no_duration", None, "ls"),
                ],
            )
            # A rotated segment of the same day: its rows count too, and the three loss counters differ from each other.
            write_day(base, "01.001.jsonl", [execute_row("b", 5, "ls"), '{"ts": NaN}', execute_row("no_stamp_either", 5, "ls", ts="noon")])
            target = base / "out.json"
            summary, printed = self.run_main(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--json-out", str(target))
            self.assertEqual(target.read_text(encoding="utf-8"), printed.rstrip("\n") + "\n")
            self.assertEqual(summary["window"], {"from": "2026-11-01", "to": "2026-11-01", "until": "2026-11-02T00:00:00+00:00"})
            self.assertEqual(summary["rows_in_window"], 6)
            self.assertEqual((summary["files_read"], summary["days_without_file"]), (2, []))
            self.assertEqual((summary["skipped_lines"], summary["rows_without_timestamp"], summary["executes_without_duration"]), (3, 2, 1))
            execute = object_of(summary["execute"])
            self.assertEqual(execute["calls"], 2)
            run_waits = object_of(summary["run_waits"])
            self.assertEqual((run_waits["waits"], run_waits["polls"]), (1, 1))
            wakes = object_of(summary["schedule_wakes"])
            self.assertEqual((wakes["creates"], wakes["self_wakes"], wakes["self_wakes_naming_a_run"]), (3, 2, 1))
            self.assertEqual(summary["keepers_in_both"], [{"keeper": "a", "blocked_hours": 0.03, "self_wakes_naming_a_run": 1}])
            turn_time = object_of(summary["turn_time"])
            self.assertEqual((turn_time["keepers_with_turn_traces"], turn_time["hours"]), (0, 0.0))

    def test_the_output_is_sorted_indented_ascii_json(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 108, f"sleep 108; gh run view {RUN_A}")])
            summary, printed = self.run_main(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01")
            self.assertEqual(printed.rstrip("\n"), json.dumps(summary, indent=2, sort_keys=True))

    def test_a_keeper_name_with_a_lone_surrogate_is_written_escaped(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("\ud800", 108, f"sleep 108; gh run view {RUN_A}")])
            summary, printed = self.run_main(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--json-out", str(base / "out.json"))
            self.assertTrue(printed.isascii())
            self.assertEqual(object_of(summary["run_waits"])["top_keepers"], [{"blocked_hours": 0.03, "keeper": "\ud800", "waits": 1}])

    def fails_with_output(self, *arguments: str) -> tuple[str, str]:
        out, err = io.StringIO(), io.StringIO()
        patched = mock.patch.object(sys, "argv", ["measure_execute_waits.py", *arguments])
        with patched, contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as raised:
            waits.main()
        self.assertEqual(raised.exception.code, 2)
        return out.getvalue(), err.getvalue()

    def fails(self, base: pathlib.Path, *arguments: str) -> str:
        return self.fails_with_output("--base-path", str(base), *arguments)[1]

    def test_a_last_day_before_the_first_day_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 5, "ls")])
            message = self.fails(base, "--from-date", "2026-11-02", "--to-date", "2026-11-01")
            self.assertRegex(message, r"error: --to-date is before --from-date\n$")

    def test_a_last_day_that_has_no_following_day_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            message = self.fails(pathlib.Path(raw), "--from-date", "9999-12-30", "--to-date", "9999-12-31")
            self.assertRegex(message, r"error: --to-date must be before 9999-12-31\n$")

    def test_an_until_outside_the_days_read_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 5, "ls")])
            for until in ("2026-11-02T00:00:01Z", "2026-11-03T23:00:00Z", "2026-11-01T00:00:00Z", "2026-10-31T23:00:00Z"):
                with self.subTest(until=until):
                    message = self.fails(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--until", until)
                    self.assertRegex(message, r"error: --until must be after --from-date midnight and not after the end of --to-date\n$")

    def test_a_missing_date_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            for given, missing in ((("--to-date", "2026-11-01"), "--from-date"), (("--from-date", "2026-11-01"), "--to-date")):
                with self.subTest(missing=missing):
                    self.assertIn(f"the following arguments are required: {missing}", self.fails(pathlib.Path(raw), *given))

    def test_a_base_path_is_required(self) -> None:
        with mock.patch.dict(os.environ):
            os.environ.pop("MASC_BASE_PATH", None)
            out, err = self.fails_with_output("--from-date", "2026-11-01", "--to-date", "2026-11-01")
        self.assertEqual(out, "")
        self.assertRegex(err, r"error: --base-path or MASC_BASE_PATH is required\n$")

    def test_a_json_out_that_cannot_be_written_is_refused_before_anything_is_printed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 5, "ls")])
            for target in (base / "missing" / "out.json", base):
                with self.subTest(target=target.name):
                    arguments = ("--base-path", str(base), "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--json-out", str(target))
                    out, err = self.fails_with_output(*arguments)
                    self.assertEqual(out, "")
                    self.assertIn("error: cannot write --json-out", err)

    def test_an_until_at_the_end_of_the_last_day_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 5, "ls")])
            summary, _ = self.run_main(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--until", "2026-11-02T00:00:00Z")
            self.assertEqual(object_of(summary["execute"])["calls"], 1)

    def test_a_base_path_without_any_ledger_file_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            message = self.fails(pathlib.Path(raw), "--from-date", "2026-11-01", "--to-date", "2026-11-01")
            self.assertIn("no ledger file for 2026-11-01..2026-11-01", message)

    def test_a_missing_day_is_listed_in_the_summary(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 5, "ls")])
            summary, _ = self.run_main(base, "--from-date", "2026-11-01", "--to-date", "2026-11-02")
            self.assertEqual((summary["files_read"], summary["days_without_file"]), (1, ["2026-11-02"]))

    def test_until_cuts_the_window(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("early", 5, "ls", ts=NOON), execute_row("late", 5, "ls", ts=NOON + 60)])
            summary, _ = self.run_main(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--until", "2026-11-01T12:00:30Z")
            execute = object_of(summary["execute"])
            self.assertEqual(execute["calls"], 1)
            window = object_of(summary["window"])
            self.assertEqual(window["until"], "2026-11-01T12:00:30+00:00")

    def test_the_turn_time_is_read_with_the_lane_time_script(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(
                base,
                "01.jsonl",
                [
                    execute_row("a", 600, "ls", ts=NOON),  # inside the turns of a
                    execute_row("a", 600, "ls", ts=NOON + 3600),  # after the last turn of a
                    execute_row("b", 300, "ls", ts=NOON + 100),  # b has no turn file
                ],
            )
            write_turns(base, "a", "first.jsonl", NOON - 1000, NOON - 300)
            write_turns(base, "a", "second.jsonl", NOON - 500, NOON + 100)
            summary, _ = self.run_main(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01")
            turn_time = object_of(summary["turn_time"])
            # The two files of a overlap: 1100 s of turn time, counted once.
            self.assertEqual((turn_time["keepers_with_turn_traces"], turn_time["hours"]), (1, 0.31))
            self.assertEqual(
                object_of(turn_time["execute"]),
                {"calls": 3, "hours": 0.42, "inside_hours": 0.17, "outside_hours": 0.25, "inside_percent_of_turn_time": 54.5},
            )
            self.assertEqual(object_of(turn_time["execute_of_keepers_without_turn_traces"]), {"keepers": 1, "calls": 1, "hours": 0.08})

    def test_the_turn_time_equals_the_busy_time_of_the_lane_time_script(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 5, "ls")])
            write_turns(base, "a", "one.jsonl", NOON, NOON + 100)
            write_turns(base, "a", "two.jsonl", NOON + 50, NOON + 300)
            write_turns(base, "a", "three.jsonl", NOON + 1000, NOON + 1100)
            write_turns(base, "b", "one.jsonl", NOON, NOON + 40)
            summary, _ = self.run_main(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01")
            lane = sys.modules[waits.LANE_TIME_MODULE]
            runs = cast(dict[str, list[tuple[float, float]]], lane.read_runs(base, SINCE, MIDNIGHT))
            union = cast(Callable[[list[tuple[float, float]]], float], lane.union_seconds)
            lane_seconds = sum(union(intervals) for intervals in runs.values())
            self.assertEqual(lane_seconds, 300 + 100 + 40)
            self.assertEqual(object_of(summary["turn_time"])["hours"], waits.hours(lane_seconds))

    def test_until_cuts_the_turn_intervals_too(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 100, "ls", ts=NOON + 100)])
            write_turns(base, "a", "one.jsonl", NOON, NOON + 1000)
            summary, _ = self.run_main(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--until", "2026-11-01T12:08:20Z")
            self.assertEqual(object_of(summary["turn_time"])["hours"], waits.hours(500))

    def test_a_turn_file_last_written_before_the_window_is_not_counted(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 5, "ls")])
            write_turns(base, "a", "old.jsonl", SINCE - 1000, SINCE - 10)
            summary, _ = self.run_main(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01")
            self.assertEqual(object_of(summary["turn_time"])["keepers_with_turn_traces"], 0)

    def test_loading_the_turn_reader_puts_the_bytecode_flag_back(self) -> None:
        for before in (False, True):
            with self.subTest(before=before), mock.patch.object(sys, "dont_write_bytecode", before):
                waits.load_lane_time()
                self.assertEqual(sys.dont_write_bytecode, before)

    def test_a_lane_time_script_that_cannot_be_loaded_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 5, "ls")])
            sources: dict[str, str | None] = {"missing.py": None, "no_reader.py": "x = 1\n", "syntax.py": "def (\n", "not_python.txt": "x = 1\n"}
            for name, source in sources.items():
                with self.subTest(name=name):
                    path = base / name
                    if source is not None:
                        path.write_text(source, encoding="utf-8")
                    with mock.patch.object(waits, "LANE_TIME_SCRIPT", path):
                        message = self.fails(base, "--from-date", "2026-11-01", "--to-date", "2026-11-01")
                    self.assertIn(f"error: cannot load the turn reader from {path}", message)
                    if name == "not_python.txt":
                        # No import spec is built for this suffix: the refusal is the ImportError, not a lookup on a missing spec.
                        self.assertIn(f"{path} is not a Python file", message)
                    self.assertNotIn(waits.LANE_TIME_MODULE, sys.modules)


class ProgramTest(unittest.TestCase):
    def test_the_script_run_as_a_program_prints_the_summary_and_writes_no_bytecode_of_the_turn_reader(self) -> None:
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory() as cache:
            base = pathlib.Path(raw)
            write_day(base, "01.jsonl", [execute_row("a", 108, f"sleep 108; gh run view {RUN_A}")])
            write_turns(base, "a", "one.jsonl", NOON - 200, NOON + 100)
            # No -B, so the process may write bytecode. pycache_prefix sends what it writes to `cache`, not next to the scripts.
            command = [sys.executable, "-I", "-X", f"pycache_prefix={cache}", str(SCRIPT), "--base-path", str(base), "--from-date", "2026-11-01", "--to-date", "2026-11-01"]
            done = subprocess.run(command, capture_output=True, text=True, check=False, timeout=PROGRAM_TIMEOUT_SECONDS)
            self.assertEqual((done.returncode, done.stderr), (0, ""))
            summary = object_of(json.loads(done.stdout))
            self.assertEqual(object_of(summary["execute"])["calls"], 1)
            turn_time = object_of(summary["turn_time"])
            self.assertEqual((turn_time["keepers_with_turn_traces"], object_of(turn_time["execute"])["inside_hours"]), (1, 0.03))
            written = {path.name.split(".")[0] for path in pathlib.Path(cache).rglob("*.pyc")}
            self.assertIn("masc_base_path", written)  # bytecode could be written
            self.assertNotIn(waits.LANE_TIME_MODULE, written)


if __name__ == "__main__":
    unittest.main()
