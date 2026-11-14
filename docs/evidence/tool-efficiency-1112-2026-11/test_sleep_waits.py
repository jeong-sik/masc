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


def in_kind(row: Row, kind: str) -> Row:
    return {**row, "turn_kind": kind}


class KindsTest(unittest.TestCase):
    def test_sleep_gh_calls_are_split_by_turn_kind(self) -> None:
        rows = [
            in_kind(execute("a", "1", 1, 300, f"sleep 290; {RUN}"), "direct"),
            in_kind(execute("a", "2", 2, 100, f"sleep 90; {RUN}"), "autonomous"),
            in_kind(execute("b", "3", 3, 200, f"sleep 190; {RUN}"), "autonomous"),
            in_kind(execute("b", "3", 4, 5, "ls"), "autonomous"),
        ]
        result = sw.kinds_of(rows)
        self.assertEqual(result["execute_calls_by_turn_kind"], {"direct": 1, "autonomous": 3})
        self.assertEqual(result["sleep_gh_calls_by_turn_kind"], {"direct": 1, "autonomous": 2})
        self.assertEqual(result["sleep_gh_hours_by_turn_kind"], {"direct": 0.08, "autonomous": 0.08})
        self.assertEqual(result["sleep_gh_hours_percent_by_turn_kind"], {"direct": 50.0, "autonomous": 50.0})

    def test_a_call_that_is_not_sleep_gh_is_only_an_execute_call(self) -> None:
        rows = [
            in_kind(execute("a", "1", 1, 300, "sleep 290; echo done"), "direct"),
            in_kind(execute("a", "1", 2, 30, f"sleep 20; {RUN}"), "direct"),
        ]
        result = sw.kinds_of(rows)
        self.assertEqual(result["execute_calls_by_turn_kind"], {"direct": 2})
        self.assertEqual(result["sleep_gh_calls_by_turn_kind"], {})
        self.assertEqual(result["sleep_gh_hours_percent_by_turn_kind"], {})

    def test_a_row_without_a_turn_kind_is_counted_as_none(self) -> None:
        result = sw.kinds_of([execute("a", "1", 1, 70, f"sleep 65; {RUN}")])
        self.assertEqual(result["sleep_gh_calls_by_turn_kind"], {"None": 1})

    def test_keepers_are_sorted_by_their_calls(self) -> None:
        rows = [
            in_kind(execute("few", "1", 1, 70, f"sleep 65; {RUN}"), "direct"),
            in_kind(execute("many", "2", 2, 70, f"sleep 65; {RUN}"), "autonomous"),
            in_kind(execute("many", "3", 3, 70, f"sleep 65; {RUN}"), "direct"),
        ]
        self.assertEqual(
            sw.kinds_of(rows)["github_wait_by_keeper"],
            [{"keeper": "many", "autonomous": 1, "direct": 1}, {"keeper": "few", "direct": 1}],
        )


LOOP = "for i in 1 2 3 4 5 6; do " + RUN + "; sleep 30; done"


class LoopPollTest(unittest.TestCase):
    def test_a_loop_poll_of_github_is_counted_apart_from_sleep_gh(self) -> None:
        rows = [
            in_kind(execute("a", "1", 1, 300, f"sleep 290; {RUN}"), "direct"),
            in_kind(execute("a", "2", 2, 180, LOOP), "autonomous"),
            in_kind(execute("b", "3", 3, 180, LOOP), "direct"),
        ]
        result = sw.kinds_of(rows)
        self.assertEqual(result["sleep_gh_calls_by_turn_kind"], {"direct": 1})
        self.assertEqual(result["loop_sleep_gh_calls_by_turn_kind"], {"autonomous": 1, "direct": 1})
        self.assertEqual(result["loop_sleep_gh_hours_by_turn_kind"], {"autonomous": 0.05, "direct": 0.05})
        self.assertEqual(result["github_wait_hours_by_turn_kind"], {"direct": 0.13, "autonomous": 0.05})
        self.assertEqual(result["github_wait_hours_percent_by_turn_kind"], {"direct": 72.7, "autonomous": 27.3})

    def test_a_loop_that_does_not_read_github_is_not_counted(self) -> None:
        loop = "for i in 1 2 3 4 5 6; do curl -s localhost:8935/health; sleep 30; done"
        result = sw.kinds_of([in_kind(execute("a", "1", 1, 180, loop), "direct")])
        self.assertEqual(result["loop_sleep_gh_calls_by_turn_kind"], {})
        self.assertEqual(result["github_wait_hours_percent_by_turn_kind"], {})

    def test_a_short_loop_is_not_counted(self) -> None:
        result = sw.kinds_of([in_kind(execute("a", "1", 1, 40, LOOP), "direct")])
        self.assertEqual(result["loop_sleep_gh_calls_by_turn_kind"], {})

    def test_the_keeper_list_counts_both_kinds_of_wait(self) -> None:
        rows = [
            in_kind(execute("a", "1", 1, 300, f"sleep 290; {RUN}"), "direct"),
            in_kind(execute("a", "2", 2, 180, LOOP), "autonomous"),
        ]
        self.assertEqual(
            sw.kinds_of(rows)["github_wait_by_keeper"],
            [{"keeper": "a", "direct": 1, "autonomous": 1}],
        )

    def test_loop_polls_are_split_by_what_gh_reads(self) -> None:
        checks = "for i in 1 2 3 4 5 6; do gh pr checks 5; sleep 30; done"
        rows = [
            in_kind(execute("a", "1", 1, 180, LOOP), "direct"),
            in_kind(execute("a", "2", 2, 180, LOOP), "autonomous"),
            in_kind(execute("b", "3", 3, 180, checks), "autonomous"),
            in_kind(execute("b", "4", 4, 300, f"sleep 290; {RUN}"), "direct"),
        ]
        self.assertEqual(
            sw.kinds_of(rows)["loop_sleep_gh_calls_by_what_gh_reads"],
            {"actions run": 2, "check-runs/pr checks": 1},
        )


class ScheduleKindsTest(unittest.TestCase):
    def test_schedule_creates_and_their_watches_are_split_by_turn_kind(self) -> None:
        rows = [
            in_kind(schedule("a", "1", 1, "until_github_run"), "autonomous"),
            in_kind(schedule("a", "2", 2, "until_github_checks"), "direct"),
            in_kind({"tool": "masc_schedule_create", "keeper": "a", "keeper_turn_id": "3", "ts": 3,
                     "input": {"message": "later", "due_in_sec": 60}}, "autonomous"),
        ]
        result = sw.kinds_of(rows)
        self.assertEqual(result["schedule_create_calls_by_turn_kind"], {"autonomous": 2, "direct": 1})
        self.assertEqual(result["until_github_schedule_create_calls_by_turn_kind"], {"autonomous": 1, "direct": 1})
        self.assertEqual(result["execute_calls_by_turn_kind"], {})

    def test_an_update_that_sets_a_watch_is_not_a_create(self) -> None:
        row: Row = {"tool": "masc_schedule_update", "keeper": "a", "keeper_turn_id": "1", "ts": 1,
                    "input": {"schedule_id": "s", "until_github_run": "https://github.com/o/r/actions/runs/1"}}
        result = sw.kinds_of([in_kind(row, "autonomous")])
        self.assertEqual(result["schedule_create_calls_by_turn_kind"], {})
        self.assertEqual(result["until_github_schedule_create_calls_by_turn_kind"], {})


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


def only_keeper(rows: list[Row]) -> dict[str, object]:
    return sw.turns_of(rows)["by_keeper"][0]  # type: ignore[index]


class LiteralSleepTest(unittest.TestCase):
    def test_percentiles_are_nearest_rank_over_the_sleep_gh_calls(self) -> None:
        rows = [execute("a", str(i), 1000 * i, 100 * i + 5, f"sleep {100 * i}; {RUN}") for i in range(1, 11)]
        self.assertEqual(only_keeper(rows)["literal_sleep_s"], {"p10": 100, "p50": 500, "p90": 900})

    def test_each_percentile_is_a_value_some_call_had(self) -> None:
        rows = [execute("a", str(i), 1000 * i, 100 * i + 5, f"sleep {100 * i}; {RUN}") for i in range(1, 5)]
        self.assertEqual(only_keeper(rows)["literal_sleep_s"], {"p10": 100, "p50": 200, "p90": 400})

    def test_the_sleeps_of_one_call_add_up_and_other_calls_are_left_out(self) -> None:
        rows = [
            execute("a", "1", 1, 120, f"sleep 40; sleep 40; {RUN}"),
            execute("a", "1", 2, 300, "sleep 290; echo done"),
            execute("a", "1", 3, 300, f"sleep 10; {RUN}"),
        ]
        self.assertEqual(only_keeper(rows)["literal_sleep_s"], {"p10": 80, "p50": 80, "p90": 80})


class BusiestTurnTest(unittest.TestCase):
    def test_the_span_runs_from_the_first_call_start_to_the_last_call_end(self) -> None:
        rows = [
            execute("a", "7", 360, 360, f"sleep 350; {RUN}"),
            execute("a", "7", 3000, 5, "git status"),
            execute("a", "7", 7200, 720, f"sleep 710; {RUN}"),
            execute("a", "7", 14400, 1800, f"sleep 1790; {RUN}"),
            execute("a", "7", 18000, 5, "git push origin x"),
            execute("a", "8", 30000, 120, f"sleep 100; {RUN}"),
        ]
        self.assertEqual(
            only_keeper(rows)["busiest_turn"],
            {"keeper_turn_id": "7", "sleep_gh_calls": 3, "first_to_last_hours": 4.0, "call_hours": 0.8},
        )

    def test_of_turns_with_as_many_calls_the_one_with_more_call_time_wins(self) -> None:
        rows = [
            execute("a", "1", 1000, 100, f"sleep 90; {RUN}"),
            execute("a", "1", 2000, 100, f"sleep 90; {RUN}"),
            execute("a", "2", 3000, 200, f"sleep 190; {RUN}"),
            execute("a", "2", 4000, 200, f"sleep 190; {RUN}"),
            execute("a", "3", 9000, 900, f"sleep 890; {RUN}"),
        ]
        self.assertEqual(
            only_keeper(rows)["busiest_turn"],
            {"keeper_turn_id": "2", "sleep_gh_calls": 2, "first_to_last_hours": 0.33, "call_hours": 0.11},
        )

    def test_of_two_equal_turns_the_one_the_ledger_holds_first_wins(self) -> None:
        rows = [
            execute("a", "9", 1000, 100, f"sleep 90; {RUN}"),
            execute("a", "3", 2000, 100, f"sleep 90; {RUN}"),
        ]
        self.assertEqual(
            only_keeper(rows)["busiest_turn"],
            {"keeper_turn_id": "9", "sleep_gh_calls": 1, "first_to_last_hours": 0.03, "call_hours": 0.03},
        )


if __name__ == "__main__":
    unittest.main()
