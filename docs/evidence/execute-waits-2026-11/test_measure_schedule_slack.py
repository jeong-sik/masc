"""Checks the arithmetic of measure_schedule_slack.py on small synthetic ledgers and runs.

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

import measure_schedule_slack as slack  # noqa: E402

NOON = 1793534400.0  # 2026-11-01T12:00:00Z
SINCE = 1793491200.0  # 2026-11-01T00:00:00Z
DAY_SECONDS = 86400.0
RUN_A = "41258710053"
RUN_B = "41279552260"
MASC = "jeong-sik/masc"
WKBL = "jeong-sik/wkbl"
MINUTE = 60.0


def setUpModule() -> None:
    # A zone other than UTC makes a time built without tzinfo differ from the UTC one.
    patch = mock.patch.dict(os.environ, {"TZ": "Asia/Seoul"})
    patch.start()
    time.tzset()
    unittest.addModuleCleanup(time.tzset)
    unittest.addModuleCleanup(patch.stop)


def schedule_row(
    keeper: str,
    message: object,
    *,
    ts: float = NOON,
    keeper_name: object = None,
    disposition: str = "completed",
    tool: str = "masc_schedule_create",
    **due: object,
) -> dict[str, object]:
    arguments: dict[str, object] = {"keeper_name": keeper if keeper_name is None else keeper_name, **due}
    if message is not None:
        arguments["message"] = message
    return {
        "record_kind": "tool_call",
        "tool": tool,
        "keeper": keeper,
        "ts": ts,
        "disposition": disposition,
        "input": arguments,
    }


def run_answer(*, attempt: object = 1, status: object = "completed", updated: object = "2026-11-01T12:20:00Z") -> dict[str, object]:
    return {"id": 1, "run_attempt": attempt, "status": status, "updated_at": updated}


def wake(due: float | None, *run_ids: str, keeper: str = "k1", stamp: float = NOON, watched: bool = False) -> slack.Wake:
    return slack.Wake(keeper, stamp, due, run_ids, watched)


def lookup_of(runs: dict[str, slack.Run | None]) -> tuple[slack.RunLookup, list[str]]:
    asked: list[str] = []

    def lookup(run_id: str) -> slack.Run | None:
        asked.append(run_id)
        return runs.get(run_id)

    return lookup, asked


def run_ending(end: float, *, repo: str = MASC, attempt: int = 1, completed: bool = True) -> slack.Run:
    return slack.Run(repo, attempt, completed, end)


def object_of(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    return cast(dict[str, object], value)


class DueTime(unittest.TestCase):
    def test_seconds_count_from_the_row(self) -> None:
        self.assertEqual(slack.due_of({"due_in_sec": 1500}, NOON), NOON + 1500)

    def test_unix_time_is_taken_as_it_is(self) -> None:
        self.assertEqual(slack.due_of({"due_at_unix": NOON + 60}, NOON), NOON + 60)

    def test_iso_time_with_a_zone(self) -> None:
        self.assertEqual(slack.due_of({"due_at_iso": "2026-11-01T12:30:00Z"}, NOON), NOON + 1800)
        self.assertEqual(slack.due_of({"due_at_iso": "2026-11-01T21:30:00+09:00"}, NOON), NOON + 1800)

    def test_iso_time_without_a_zone_is_utc_whatever_the_local_zone(self) -> None:
        self.assertEqual(slack.due_of({"due_at_iso": "2026-11-01T12:30:00"}, NOON), NOON + 1800)

    def test_the_first_field_present_wins(self) -> None:
        both: dict[str, object] = {"due_in_sec": 60, "due_at_unix": NOON + 999, "due_at_iso": "2026-11-01T13:00:00Z"}
        self.assertEqual(slack.due_of(both, NOON), NOON + 60)
        self.assertEqual(slack.due_of({"due_at_unix": NOON + 7, "due_at_iso": "2026-11-01T13:00:00Z"}, NOON), NOON + 7)

    def test_a_field_that_is_not_a_number_is_skipped(self) -> None:
        self.assertEqual(slack.due_of({"due_in_sec": True, "due_at_unix": "1793534400"}, NOON), None)
        self.assertEqual(slack.due_of({"due_in_sec": float("nan"), "due_at_unix": NOON + 5}, NOON), NOON + 5)

    def test_no_field_or_an_unreadable_time_gives_none(self) -> None:
        self.assertIsNone(slack.due_of({}, NOON))
        self.assertIsNone(slack.due_of({"due_at_iso": "tomorrow"}, NOON))
        self.assertIsNone(slack.due_of({"due_at_iso": 5}, NOON))


class WakeOf(unittest.TestCase):
    def test_a_self_wake_names_its_runs_once_each_in_order(self) -> None:
        message = f"check run {RUN_B} then runs view {RUN_A} and actions/runs/{RUN_B} again"
        found = slack.wake_of(schedule_row("k1", message, due_in_sec=900), NOON)
        self.assertEqual(found, slack.Wake("k1", NOON, NOON + 900, (RUN_B, RUN_A)))

    def test_a_wake_for_another_keeper_is_not_a_self_wake(self) -> None:
        self.assertIsNone(slack.wake_of(schedule_row("k1", f"run {RUN_A}", keeper_name="k2", due_in_sec=900), NOON))

    def test_a_message_that_is_missing_or_not_text_names_no_run(self) -> None:
        self.assertEqual(slack.wake_of(schedule_row("k1", None, due_in_sec=60), NOON), slack.Wake("k1", NOON, NOON + 60, ()))
        self.assertEqual(slack.wake_of(schedule_row("k1", 5, due_in_sec=60), NOON), slack.Wake("k1", NOON, NOON + 60, ()))

    def test_a_wake_with_a_watch_is_watched_whatever_its_message_says(self) -> None:
        url = f"https://github.com/{MASC}/actions/runs/{RUN_A}"
        watched = slack.wake_of(schedule_row("k1", "look again", due_in_sec=900, until_github_run=url), NOON)
        self.assertEqual(watched, slack.Wake("k1", NOON, NOON + 900, (), True))
        for empty in ("", "  ", 5, None):
            with self.subTest(watch=empty):
                found = slack.wake_of(schedule_row("k1", f"run {RUN_A}", due_in_sec=900, until_github_run=empty), NOON)
                assert found is not None
                self.assertFalse(found.watched)

    def test_an_input_that_is_not_an_object_is_not_a_wake(self) -> None:
        row = schedule_row("k1", "x")
        row["input"] = "text"
        self.assertIsNone(slack.wake_of(row, NOON))


class RunOf(unittest.TestCase):
    def test_a_completed_run(self) -> None:
        self.assertEqual(slack.run_of(MASC, run_answer()), slack.Run(MASC, 1, True, NOON + 20 * MINUTE))

    def test_a_run_in_progress_is_not_completed(self) -> None:
        found = slack.run_of(WKBL, run_answer(status="in_progress"))
        assert found is not None
        self.assertFalse(found.completed)

    def test_an_answer_without_a_readable_end_or_attempt_is_not_a_run(self) -> None:
        bad_answers: tuple[object, ...] = (
            run_answer(updated=None),
            run_answer(updated="soon"),
            run_answer(attempt=True),
            run_answer(attempt="1"),
            [],
            None,
        )
        for bad in bad_answers:
            with self.subTest(answer=bad):
                self.assertIsNone(slack.run_of(MASC, bad))


class Lookup(unittest.TestCase):
    def test_repositories_are_asked_in_order_and_the_first_answer_wins(self) -> None:
        asked: list[tuple[str, str]] = []

        def fetch(repo: str, run_id: str) -> slack.Run | None:
            asked.append((repo, run_id))
            return run_ending(NOON, repo=repo) if repo == WKBL else None

        lookup = slack.lookup_over((MASC, WKBL, "other/repo"), fetch)
        found = lookup(RUN_A)
        assert found is not None
        self.assertEqual(found.repo, WKBL)
        self.assertEqual(asked, [(MASC, RUN_A), (WKBL, RUN_A)])

    def test_an_answer_is_asked_for_once_and_so_is_a_miss(self) -> None:
        asked: list[tuple[str, str]] = []

        def fetch(repo: str, run_id: str) -> slack.Run | None:
            asked.append((repo, run_id))
            return None

        lookup = slack.lookup_over((MASC, WKBL), fetch)
        self.assertIsNone(lookup(RUN_A))
        self.assertIsNone(lookup(RUN_A))
        self.assertEqual(asked, [(MASC, RUN_A), (WKBL, RUN_A)])


class GhRun(unittest.TestCase):
    def completed(self, returncode: int, stdout: str) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(["gh"], returncode, stdout, "")

    def test_the_command_and_a_good_answer(self) -> None:
        with mock.patch.object(slack.subprocess, "run", return_value=self.completed(0, json.dumps(run_answer()))) as run:
            found = slack.gh_run(MASC, RUN_A)
        self.assertEqual(found, slack.Run(MASC, 1, True, NOON + 20 * MINUTE))
        self.assertEqual(run.call_args.args[0], ["gh", "api", f"repos/{MASC}/actions/runs/{RUN_A}"])

    def test_a_failed_command_or_a_body_that_is_not_json_gives_none(self) -> None:
        with mock.patch.object(slack.subprocess, "run", return_value=self.completed(1, '{"message": "Not Found"}')):
            self.assertIsNone(slack.gh_run(MASC, RUN_A))
        with mock.patch.object(slack.subprocess, "run", return_value=self.completed(0, "<html>")):
            self.assertIsNone(slack.gh_run(MASC, RUN_A))


class Judge(unittest.TestCase):
    def verdict_of(self, due: float | None, run: slack.Run | None, *run_ids: str) -> slack.Judged:
        ids = run_ids or (RUN_A,)
        lookup, _ = lookup_of({RUN_A: run})
        return slack.judge(wake(due, *ids), lookup)

    def test_a_watched_wake_is_not_compared_with_its_run(self) -> None:
        lookup, asked = lookup_of({RUN_A: run_ending(NOON + 60)})
        for names in ((), (RUN_A,), (RUN_A, RUN_B)):
            with self.subTest(run_ids=names):
                judged = slack.judge(wake(NOON + 900, *names, watched=True), lookup)
                self.assertEqual((judged.verdict, judged.run, judged.slack), (slack.Verdict.WATCHED, None, None))
        self.assertEqual(asked, [])

    def test_several_runs_are_not_asked_for(self) -> None:
        lookup, asked = lookup_of({})
        judged = slack.judge(wake(NOON + 900, RUN_A, RUN_B), lookup)
        self.assertEqual((judged.verdict, judged.run, judged.slack), (slack.Verdict.SEVERAL_RUNS, None, None))
        self.assertEqual(asked, [])

    def test_a_wake_without_a_due_time_is_not_asked_for(self) -> None:
        lookup, asked = lookup_of({})
        self.assertEqual(slack.judge(wake(None, RUN_A), lookup).verdict, slack.Verdict.NO_DUE_TIME)
        self.assertEqual(asked, [])

    def test_a_wake_that_names_no_run_is_a_misuse(self) -> None:
        lookup, _ = lookup_of({})
        with self.assertRaises(ValueError):
            slack.judge(wake(NOON + 900), lookup)

    def test_an_unreadable_run(self) -> None:
        self.assertEqual(self.verdict_of(NOON + 900, None).verdict, slack.Verdict.RUN_UNREADABLE)

    def test_a_run_with_a_second_attempt_is_set_aside_even_when_it_looks_late(self) -> None:
        judged = self.verdict_of(NOON + 9000, run_ending(NOON + 600, attempt=2))
        self.assertEqual((judged.verdict, judged.slack), (slack.Verdict.RERUN, None))

    def test_a_run_that_has_not_completed(self) -> None:
        self.assertEqual(self.verdict_of(NOON + 900, run_ending(NOON + 600, completed=False)).verdict, slack.Verdict.NOT_COMPLETED)

    def test_a_run_that_had_ended_when_the_wake_was_made(self) -> None:
        self.assertEqual(self.verdict_of(NOON + 900, run_ending(NOON - 60)).verdict, slack.Verdict.ALREADY_COMPLETE)
        self.assertEqual(self.verdict_of(NOON + 900, run_ending(NOON)).verdict, slack.Verdict.ALREADY_COMPLETE)

    def test_a_wake_after_the_end_is_late_by_the_gap(self) -> None:
        judged = self.verdict_of(NOON + 1800, run_ending(NOON + 900))
        self.assertEqual((judged.verdict, judged.slack), (slack.Verdict.LATE, 900.0))

    def test_a_wake_at_the_end_is_late_by_nothing(self) -> None:
        judged = self.verdict_of(NOON + 900, run_ending(NOON + 900))
        self.assertEqual((judged.verdict, judged.slack), (slack.Verdict.LATE, 0.0))

    def test_a_wake_before_the_end_is_early_by_the_gap(self) -> None:
        judged = self.verdict_of(NOON + 600, run_ending(NOON + 1800))
        self.assertEqual((judged.verdict, judged.slack), (slack.Verdict.EARLY, 1200.0))


class ReadWakes(unittest.TestCase):
    def write_day(self, base: pathlib.Path, day: str, lines: list[object]) -> None:
        month, number = day[:7], day[8:10]
        folder = base / ".masc" / "tool_calls" / month
        folder.mkdir(parents=True, exist_ok=True)
        with (folder / f"{number}.jsonl").open("w", encoding="utf-8") as handle:
            for line in lines:
                handle.write((line if isinstance(line, str) else json.dumps(line)) + "\n")

    def test_only_succeeded_self_wakes_in_the_window_count(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            self.write_day(
                base,
                "2026-11-01",
                [
                    schedule_row("k1", f"wait for run {RUN_A}", due_in_sec=1500),
                    schedule_row("k1", f"wait for run {RUN_B}", disposition="failed", due_in_sec=1500),
                    schedule_row("k1", f"wait for run {RUN_B}", keeper_name="k2", due_in_sec=1500),
                    schedule_row("k1", "check the board later", due_in_sec=600),
                    schedule_row("k1", "look again", due_in_sec=600, until_github_run=f"https://github.com/{MASC}/actions/runs/{RUN_B}"),
                    schedule_row("k1", f"run {RUN_B}", tool="masc_schedule_update", due_in_sec=600),
                    schedule_row("k1", f"run {RUN_B}", ts=SINCE - 1, due_in_sec=600),
                    schedule_row("k1", f"run {RUN_B}", ts=SINCE + DAY_SECONDS, due_in_sec=600),
                    "not json",
                    "",
                    {"record_kind": "tool_call", "tool": "masc_schedule_create", "keeper": "k1", "ts": "noon"},
                ],
            )
            named, every = slack.read_wakes(base, date(2026, 11, 1), date(2026, 11, 1), SINCE, SINCE + DAY_SECONDS)
        self.assertEqual(
            named,
            [slack.Wake("k1", NOON, NOON + 1500, (RUN_A,)), slack.Wake("k1", NOON, NOON + 600, (), True)],
        )
        self.assertEqual(every, 3)

    def test_days_are_read_in_order_and_a_missing_day_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            self.write_day(base, "2026-11-01", [schedule_row("k1", f"run {RUN_A}", due_in_sec=60)])
            self.write_day(base, "2026-11-03", [schedule_row("k2", f"run {RUN_B}", ts=NOON + 2 * DAY_SECONDS, due_in_sec=60)])
            named, every = slack.read_wakes(base, date(2026, 11, 1), date(2026, 11, 3), SINCE, SINCE + 3 * DAY_SECONDS)
        self.assertEqual([item.keeper for item in named], ["k1", "k2"])
        self.assertEqual(every, 2)


class Summarize(unittest.TestCase):
    def judged(self) -> list[slack.Judged]:
        runs: dict[str, slack.Run | None] = {
            "10000000001": run_ending(NOON + 20 * MINUTE),  # late1: due 30 min
            "10000000002": run_ending(NOON + 10 * MINUTE),  # late2: due 25 min
            "10000000003": run_ending(NOON + 30 * MINUTE, repo=WKBL),  # late3: due 90 min
            "10000000004": run_ending(NOON + 30 * MINUTE, repo=WKBL),  # early1: due 10 min
            "10000000005": run_ending(NOON - MINUTE),  # already complete
            "10000000007": run_ending(NOON + 5 * MINUTE, repo=WKBL, attempt=2),  # rerun
        }
        lookup, _ = lookup_of(runs)
        wakes = [
            wake(NOON + 30 * MINUTE, "10000000001", keeper="k1"),
            wake(NOON + 25 * MINUTE, "10000000002", keeper="k1"),
            wake(NOON + 90 * MINUTE, "10000000003", keeper="k2"),
            wake(NOON + 10 * MINUTE, "10000000004", keeper="k1"),
            wake(NOON + 10 * MINUTE, "10000000005", keeper="k3"),
            wake(NOON + 10 * MINUTE, "10000000006", "10000000008", keeper="k3"),
            wake(NOON + 10 * MINUTE, "10000000007", keeper="k3"),
            wake(NOON + 10 * MINUTE, keeper="k3", watched=True),
        ]
        return [slack.judge(item, lookup) for item in wakes]

    def test_counts_and_slack(self) -> None:
        summary = slack.summarize(self.judged(), 40, (MASC, WKBL))
        self.assertEqual(summary["schedule_wakes"], 40)
        self.assertEqual(summary["names_a_run"], 7)
        self.assertEqual(
            summary["verdicts"],
            {
                "watched": 1,
                "several_runs": 1,
                "no_due_time": 0,
                "run_unreadable": 0,
                "rerun": 1,
                "not_completed": 0,
                "already_complete": 1,
                "late": 3,
                "early": 1,
            },
        )
        self.assertEqual(summary["distinct_runs_measured"], 5)
        self.assertEqual(summary["running_at_creation"], 4)
        self.assertEqual(summary["already_complete"], 1)
        # late slack: 600 s, 900 s, 3600 s. Nearest rank: median is the 2nd of 3, p90 the 3rd.
        self.assertEqual(summary["late"], {"calls": 3, "hours": 1.42, "median_min": 15.0, "p90_min": 60.0, "max_min": 60.0})
        self.assertEqual(summary["early"], {"calls": 1, "hours": 0.33, "median_min": 20.0, "p90_min": 20.0, "max_min": 20.0})

    def test_what_was_asked_for_and_what_was_left(self) -> None:
        summary = slack.summarize(self.judged(), 40, (MASC, WKBL))
        # due in 10, 25, 30, 90 min and remaining 10, 20, 30, 30 min.
        self.assertEqual(summary["due_in_min"], {"p10": 10.0, "median": 25.0, "p90": 90.0})
        self.assertEqual(summary["remaining_min"], {"p10": 10.0, "median": 20.0, "p90": 30.0})

    def test_the_split_by_repository_and_by_keeper(self) -> None:
        summary = slack.summarize(self.judged(), 40, (MASC, WKBL))
        by_repo = object_of(summary["by_repo"])
        masc = object_of(by_repo[MASC])
        wkbl = object_of(by_repo[WKBL])
        self.assertEqual(masc["already_complete"], 1)
        self.assertEqual(object_of(masc["late"])["calls"], 2)
        self.assertEqual(object_of(masc["late"])["hours"], 0.42)
        self.assertEqual(object_of(masc["early"])["calls"], 0)
        self.assertEqual(wkbl["already_complete"], 0)
        self.assertEqual(object_of(wkbl["late"])["hours"], 1.0)
        self.assertEqual(object_of(wkbl["early"])["hours"], 0.33)
        by_keeper = object_of(summary["by_keeper"])
        self.assertEqual(list(by_keeper), ["k1", "k2"])
        self.assertEqual(object_of(object_of(by_keeper["k1"])["late"])["calls"], 2)
        self.assertEqual(object_of(object_of(by_keeper["k1"])["early"])["calls"], 1)

    def test_nothing_measured_gives_empty_statistics(self) -> None:
        summary = slack.summarize([], 0, (MASC,))
        self.assertEqual(summary["late"], {"calls": 0, "hours": 0.0, "median_min": None, "p90_min": None, "max_min": None})
        self.assertEqual(summary["due_in_min"], {"p10": None, "median": None, "p90": None})


class Program(unittest.TestCase):
    def run_main(self, args: list[str], fetch: Callable[[str, str], slack.Run | None]) -> tuple[int, str]:
        out = io.StringIO()
        with (
            mock.patch.object(sys, "argv", ["measure_schedule_slack.py", *args]),
            mock.patch.object(slack, "gh_run", side_effect=fetch),
            mock.patch.object(slack.shutil, "which", return_value="/usr/bin/gh"),
            contextlib.redirect_stdout(out),
        ):
            status = slack.main()
        return status, out.getvalue()

    def test_a_window_of_one_day_end_to_end(self) -> None:
        def fetch(repo: str, run_id: str) -> slack.Run | None:
            return run_ending(NOON + 10 * MINUTE, repo=repo) if (repo, run_id) == (WKBL, RUN_A) else None

        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            ReadWakes().write_day(base, "2026-11-01", [schedule_row("k1", f"wait for run {RUN_A}", due_in_sec=30 * MINUTE)])
            target = base / "result.json"
            status, text = self.run_main(
                ["--base-path", str(base), "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--json-out", str(target)],
                fetch,
            )
            written = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(text), written)
        self.assertEqual(written["window"]["from"], "2026-11-01")
        self.assertEqual(written["repos"], [MASC, WKBL])
        self.assertEqual(written["verdicts"]["late"], 1)
        self.assertEqual(written["late"], {"calls": 1, "hours": 0.33, "median_min": 20.0, "p90_min": 20.0, "max_min": 20.0})
        self.assertIn("probed_at", written)

    def test_a_window_that_ends_before_it_starts_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as stopped, contextlib.redirect_stderr(io.StringIO()):
            self.run_main(["--base-path", "/nonexistent", "--from-date", "2026-11-02", "--to-date", "2026-11-01"], lambda _repo, _run_id: None)
        self.assertEqual(stopped.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
