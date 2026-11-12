"""Tests for sleep_waits.py on rows built in memory.

Run: python3 docs/evidence/tool-efficiency-1112-2026-11/test_sleep_waits.py
"""

from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import sleep_waits as sw  # noqa: E402

type Row = dict[str, object]

RUN = "gh api repos/o/r/actions/runs/123456789 --jq .status"


def execute(keeper: str, turn: str, ts: float, seconds: float, command: str, background: bool = False) -> Row:
    inp: dict[str, object] = {"command": command}
    if background:
        inp["run_in_background"] = True
    return {"tool": "Execute", "keeper": keeper, "keeper_turn_id": turn, "ts": ts,
            "duration_ms": seconds * 1000, "input": inp}


def schedule(keeper: str, turn: str, ts: float, field: str) -> Row:
    return {"tool": "masc_schedule_create", "keeper": keeper, "keeper_turn_id": turn, "ts": ts,
            "input": {field: "https://github.com/o/r/actions/runs/1", "due_in_sec": 600}}


class CommandTest(unittest.TestCase):
    def test_command_field(self) -> None:
        self.assertEqual(sw.command_of(execute("k", "1", 0, 70, "sleep 60; ls")), "sleep 60; ls")

    def test_bash_argv_gives_the_script(self) -> None:
        row: Row = {"input": {"argv": ["bash", "-lc", "sleep 5; true"]}}
        self.assertEqual(sw.command_of(row), "sleep 5; true")

    def test_other_argv_is_joined(self) -> None:
        row: Row = {"input": {"argv": ["gh", "run", "view", "1"]}}
        self.assertEqual(sw.command_of(row), "gh run view 1")

    def test_input_kept_as_a_json_string(self) -> None:
        row: Row = {"input": '{"command":"sleep 9"}'}
        self.assertEqual(sw.command_of(row), "sleep 9")

    def test_missing_input_is_empty(self) -> None:
        self.assertEqual(sw.command_of({}), "")


class BackgroundTest(unittest.TestCase):
    def test_object_input_with_the_flag_is_background(self) -> None:
        self.assertTrue(sw.is_background(execute("k", "1", 0, 1, "x", background=True)))

    def test_flag_inside_an_escaped_string_is_background(self) -> None:
        self.assertTrue(sw.is_background({"input": '{"run_in_background": true}'}))

    def test_false_is_not_background(self) -> None:
        self.assertFalse(sw.is_background({"input": {"run_in_background": False}}))


class SleepGroupTest(unittest.TestCase):
    def test_sleep_and_gh(self) -> None:
        self.assertEqual(sw.sleep_group(f"sleep 100; {RUN}", 120), "sleep+gh")

    def test_sleep_only(self) -> None:
        self.assertEqual(sw.sleep_group("sleep 100; ls", 120), "sleep only")

    def test_own_background_job(self) -> None:
        self.assertEqual(sw.sleep_group("nohup python3 job.py > out 2>&1 & sleep 100", 120), "sleep+own background job")

    def test_a_short_literal_sleep_is_not_a_sleep_call(self) -> None:
        self.assertIsNone(sw.sleep_group("sleep 10; make", 300))

    def test_literal_sleeps_add_up(self) -> None:
        self.assertEqual(sw.sleep_group(f"sleep 40; sleep 40; {RUN}", 120), "sleep+gh")

    def test_no_sleep(self) -> None:
        self.assertIsNone(sw.sleep_group("make", 300))


class GhWaitKindTest(unittest.TestCase):
    def test_kinds(self) -> None:
        self.assertEqual(sw.gh_wait_kind(RUN), "actions run")
        self.assertEqual(sw.gh_wait_kind("gh pr checks 5"), "check-runs/pr checks")
        self.assertEqual(sw.gh_wait_kind("gh api repos/o/r/commits/abc/check-runs"), "check-runs/pr checks")
        self.assertEqual(sw.gh_wait_kind("gh api repos/o/r/pulls/5/reviews"), "review/comments")
        self.assertEqual(sw.gh_wait_kind("gh pr view 5 --json mergeStateStatus"), "pr state")
        self.assertEqual(sw.gh_wait_kind("gh api user"), "other gh")


class ShareTest(unittest.TestCase):
    def test_counts(self) -> None:
        rows = [
            execute("a", "1", 1, 5, "ls"),
            execute("a", "1", 2, 120, "sleep 100"),
            execute("b", "2", 3, 130, "sleep 100", background=True),
            {"tool": "keeper_skill", "keeper": "a", "ts": 4, "duration_ms": 900_000},
        ]
        out = sw.share_of(rows)
        self.assertEqual(out["execute_calls"], 3)
        self.assertEqual(out["background_calls"], 1)
        self.assertEqual(out["foreground_60s_calls"], 1)
        self.assertEqual(out["background_by_keeper"], [("b", 1)])


class ShapesTest(unittest.TestCase):
    def test_background_and_short_calls_are_left_out(self) -> None:
        rows = [
            execute("a", "1", 1, 120, f"sleep 100; {RUN}"),
            execute("a", "1", 2, 120, f"sleep 100; {RUN}", background=True),
            execute("a", "1", 3, 20, f"sleep 10; {RUN}"),
        ]
        out = sw.shapes_of(rows)
        self.assertEqual(out["foreground_60s_calls"], 1)
        groups = {entry["group"]: entry for entry in out["groups"]}  # type: ignore[attr-defined]
        self.assertEqual(groups["sleep+gh"]["calls"], 1)

    def test_gh_split_does_not_double_count_the_total(self) -> None:
        rows = [execute("a", "1", 1, 120, f"sleep 100; {RUN}")]
        out = sw.shapes_of(rows)
        self.assertEqual(out["foreground_60s_calls"], 1)
        self.assertEqual(out["sleep_gh_by_what_gh_reads"][0]["group"], "actions run")  # type: ignore[index]


class TurnsTest(unittest.TestCase):
    def test_polling_after_a_push_in_one_turn(self) -> None:
        rows = [
            execute("a", "7", 1, 5, "git push origin x"),
            execute("a", "7", 2, 120, f"sleep 100; {RUN}"),
            execute("a", "7", 3, 120, f"sleep 100; {RUN}"),
            execute("a", "8", 4, 120, f"sleep 100; {RUN}"),
            schedule("a", "9", 5, "until_github_run"),
        ]
        out = sw.turns_of(rows)
        entry = out["by_keeper"][0]  # type: ignore[index]
        self.assertEqual(entry["sleep_gh_calls"], 3)
        self.assertEqual(entry["turns"], 2)
        self.assertEqual(entry["after_push_in_same_turn"], 2)
        self.assertEqual(entry["in_turns_with_2_or_more"], 2)
        self.assertEqual(entry["most_in_one_turn"], 2)
        self.assertEqual(entry["until_github_schedules_created"], 1)
        self.assertEqual(out["keepers_with_sleep_gh_that_created_a_watch"], 1)

    def test_push_in_another_turn_does_not_count(self) -> None:
        rows = [
            execute("a", "1", 1, 5, "git push origin x"),
            execute("a", "2", 2, 120, f"sleep 100; {RUN}"),
        ]
        entry = sw.turns_of(rows)["by_keeper"][0]  # type: ignore[index]
        self.assertEqual(entry["after_push_in_same_turn"], 0)

    def test_turn_ids_of_two_keepers_do_not_merge(self) -> None:
        rows = [
            execute("a", "5", 1, 120, f"sleep 100; {RUN}"),
            execute("b", "5", 2, 120, f"sleep 100; {RUN}"),
        ]
        out = sw.turns_of(rows)
        self.assertEqual({entry["keeper"]: entry["turns"] for entry in out["by_keeper"]}, {"a": 1, "b": 1})  # type: ignore[attr-defined]

    def test_schedule_without_a_watch_field_is_not_counted(self) -> None:
        rows = [{"tool": "masc_schedule_create", "keeper": "a", "keeper_turn_id": "1", "ts": 1,
                 "input": {"message": "later", "due_in_sec": 60}}]
        self.assertEqual(sw.turns_of(rows)["until_github_schedules_created"], 0)


if __name__ == "__main__":
    unittest.main()
