"""Checks the arithmetic of measure_watched_wakes.py on small synthetic ledgers, server logs and turn files.

Run: python3 -B -m unittest discover -s docs/evidence/execute-waits-2026-11
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest
from datetime import date, datetime, timezone
from typing import cast
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_execute_waits as waits  # noqa: E402
import measure_schedule_slack as slack  # noqa: E402
import measure_watched_wakes as watched  # noqa: E402

NOON = 1793534400.0  # 2026-11-01T12:00:00Z
SINCE = 1793491200.0  # 2026-11-01T00:00:00Z
DAY_SECONDS = 86400.0
RUN_A = "41258710053"
RUN_B = "41279552260"
RUN_C = "41300000001"
MASC = "jeong-sik/masc"
WKBL = "jeong-sik/wkbl"
SCHED = "sched-0a"
CLOCK_OF = waits.load_lane_time().clock_of


def setUpModule() -> None:
    # A zone other than UTC makes a time built without tzinfo differ from the UTC one.
    patch = mock.patch.dict(os.environ, {"TZ": "Asia/Seoul"})
    patch.start()
    time.tzset()
    unittest.addModuleCleanup(time.tzset)
    unittest.addModuleCleanup(patch.stop)


def url(run_id: str, repo: str = MASC) -> str:
    return f"https://github.com/{repo}/actions/runs/{run_id}"


def create_row(
    keeper: str,
    watch: object,
    *,
    ts: float = NOON,
    keeper_name: object = None,
    disposition: str = "completed",
    tool: str = "masc_schedule_create",
) -> dict[str, object]:
    arguments: dict[str, object] = {"keeper_name": keeper if keeper_name is None else keeper_name, "message": "look again", "due_in_sec": 3000}
    if watch is not None:
        arguments["until_github_run"] = watch
    return {"record_kind": "tool_call", "tool": tool, "keeper": keeper, "ts": ts, "disposition": disposition, "input": arguments}


def log_row(ts: float, message: str) -> dict[str, object]:
    return {"ts": datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "level": "INFO", "message": message}


def woke_row(ts: float, schedule: str, *, repo: str = MASC, run_id: str = RUN_A, conclusion: str = "success") -> dict[str, object]:
    return log_row(ts, f"schedule_run_watch: woke {schedule}, {repo} run {run_id} completed: {conclusion}")


def dispatch_row(ts: float, schedule: str, *, outcome: str = "succeeded") -> dict[str, object]:
    return log_row(ts, f"schedule_runner: occurrence=abc123 schedule_id={schedule} dispatch={outcome}")


def delivered_row(ts: float, schedule: str, keeper: str) -> dict[str, object]:
    return log_row(ts, f"turn entry: scheduled wake delivered schedule_id={schedule} due_at=1793537400 (keeper={keeper})")


def write_lines(path: pathlib.Path, lines: list[object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    chunks = [line.encode("utf-8") if isinstance(line, str) else json.dumps(line).encode("utf-8") for line in lines]
    path.write_bytes(b"\n".join(chunks) + b"\n")


def write_ledger(base: pathlib.Path, name: str, lines: list[object], month: str = "2026-11") -> None:
    write_lines(base / ".masc" / "tool_calls" / month / name, lines)


def write_log(base: pathlib.Path, day: str, lines: list[object]) -> None:
    write_lines(base / ".masc" / "logs" / f"system_log_{day}.jsonl", lines)


def write_turn(base: pathlib.Path, keeper: str, name: str, first: float, last: float) -> None:
    """A turn file whose first line is stamped `first` and last line `last`, as read by the lane-time script."""
    folder = base / ".masc" / "keeper_turn_events" / keeper
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    path.write_text(json.dumps({"ts": first}) + "\n" + json.dumps({"ts": last}) + "\n", encoding="utf-8")
    os.utime(path, (last, last))


def run_ending(end: float, *, repo: str = MASC, attempt: int = 1, completed: bool = True) -> slack.Run:
    return slack.Run(repo, attempt, completed, end)


def fetch_of(runs: dict[tuple[str, str], slack.Run | None]) -> tuple[watched.Fetch, list[tuple[str, str]]]:
    asked: list[tuple[str, str]] = []

    def fetch(repo: str, run_id: str) -> slack.Run | None:
        asked.append((repo, run_id))
        return runs.get((repo, run_id))

    return fetch, asked


def woke_at(ts: float, *, run_id: str = RUN_A, schedule: str = SCHED, repo: str = MASC, conclusion: str = "success") -> watched.Woke:
    return watched.Woke(schedule, repo, run_id, conclusion, ts)


def lines_of(
    dispatched: dict[str, tuple[float, ...]] | None = None,
    delivered: dict[str, tuple[tuple[float, str], ...]] | None = None,
) -> watched.LogLines:
    return watched.LogLines((), dispatched or {}, delivered or {}, 1, 0)


def clocks_of(runs: dict[str, list[waits.Interval]]) -> dict[str, waits.TurnTime]:
    return {keeper: CLOCK_OF(intervals) for keeper, intervals in runs.items()}


def object_of(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    return cast(dict[str, object], value)


def chain(
    *,
    end: float | None = NOON + 600,
    woke: float = NOON + 610,
    dispatched: float | None = NOON + 625,
    delivered: float | None = NOON + 625,
    keeper: str | None = "k1",
    inside: bool | None = False,
    created: float | None = NOON,
    other: int | None = 2,
    conclusion: str = "success",
) -> watched.Followed:
    return watched.Followed(SCHED, RUN_A, conclusion, keeper, end, woke, dispatched, delivered, inside, created, other)


class CreateOf(unittest.TestCase):
    def test_a_watch_on_one_run_is_a_create(self) -> None:
        self.assertEqual(watched.create_of(create_row("k1", url(RUN_A)), NOON), watched.Create("k1", NOON, RUN_A))

    def test_the_same_run_named_twice_is_one_run(self) -> None:
        self.assertEqual(watched.create_of(create_row("k1", f"{url(RUN_A)} {url(RUN_A)}"), NOON), watched.Create("k1", NOON, RUN_A))

    def test_a_watch_that_names_two_runs_or_none_is_not_a_create(self) -> None:
        for watch in (f"{url(RUN_A)} {url(RUN_B)}", "soon", 5, None):
            with self.subTest(watch=watch):
                self.assertIsNone(watched.create_of(create_row("k1", watch), NOON))

    def test_a_schedule_for_another_keeper_is_not_a_create(self) -> None:
        self.assertIsNone(watched.create_of(create_row("k1", url(RUN_A), keeper_name="k2"), NOON))

    def test_an_input_that_is_not_an_object_is_not_a_create(self) -> None:
        row = create_row("k1", url(RUN_A))
        row["input"] = "text"
        self.assertIsNone(watched.create_of(row, NOON))


class ReadCreates(unittest.TestCase):
    def test_only_succeeded_watched_self_creates_in_the_window_count(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(
                base,
                "01.jsonl",
                [
                    create_row("k1", url(RUN_A)),
                    create_row("k1", url(RUN_B), disposition="failed"),
                    create_row("k1", url(RUN_B), keeper_name="k2"),
                    create_row("k1", None),
                    create_row("k1", url(RUN_B), tool="masc_schedule_update"),
                    create_row("k1", url(RUN_B), ts=SINCE - 1),
                    create_row("k1", url(RUN_B), ts=SINCE + DAY_SECONDS),
                    "not json",
                    "",
                    {"record_kind": "tool_call", "tool": "masc_schedule_create", "keeper": "k1", "ts": "noon"},
                ],
            )
            write_ledger(base, "01.001.jsonl", [create_row("k2", url(RUN_C), ts=NOON + 5)])
            found = watched.read_creates(base, date(2026, 11, 1), date(2026, 11, 1), SINCE, SINCE + DAY_SECONDS)
        self.assertEqual(sorted(found, key=lambda item: item.stamp), [watched.Create("k1", NOON, RUN_A), watched.Create("k2", NOON + 5, RUN_C)])

    def test_a_missing_day_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(base, "03.jsonl", [create_row("k1", url(RUN_A), ts=NOON + 2 * DAY_SECONDS)])
            found = watched.read_creates(base, date(2026, 11, 1), date(2026, 11, 3), SINCE, SINCE + 3 * DAY_SECONDS)
        self.assertEqual(found, [watched.Create("k1", NOON + 2 * DAY_SECONDS, RUN_A)])


class ReadLog(unittest.TestCase):
    def test_the_three_lines_of_a_wake_are_read_and_the_rest_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_log(
                base,
                "2026-11-01",
                [
                    log_row(NOON, "boot stage=resolved elapsed_ms=0.0"),
                    woke_row(NOON + 10, "sched-0a", repo=WKBL, run_id=RUN_B, conclusion="failure"),
                    woke_row(NOON + 90, "sched-0a"),
                    dispatch_row(NOON + 12, "sched-0a"),
                    dispatch_row(NOON + 13, "sched-0a", outcome="failed"),
                    delivered_row(NOON + 14, "sched-0a", "k1"),
                    log_row(NOON + 15, "schedule_runner: nothing is due for sched-0b"),
                    woke_row(SINCE - 5, "sched-0c"),
                    woke_row(SINCE + DAY_SECONDS, "sched-0e"),
                    "{broken sched-0d",
                ],
            )
            lines = watched.read_log(base, date(2026, 11, 1), date(2026, 11, 1), SINCE, SINCE + DAY_SECONDS)
        self.assertEqual(lines.woke, (watched.Woke("sched-0a", WKBL, RUN_B, "failure", NOON + 10),))
        self.assertEqual(dict(lines.dispatched), {"sched-0a": (NOON + 12,)})
        self.assertEqual(dict(lines.delivered), {"sched-0a": ((NOON + 14, "k1"),)})
        self.assertEqual((lines.files, lines.unreadable), (1, 1))

    def test_days_are_read_in_order_and_a_missing_day_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_log(base, "2026-11-01", [woke_row(NOON, "sched-01")])
            write_log(base, "2026-11-03", [woke_row(NOON + 2 * DAY_SECONDS, "sched-03")])
            lines = watched.read_log(base, date(2026, 11, 1), date(2026, 11, 3), SINCE, SINCE + 3 * DAY_SECONDS)
        self.assertEqual([item.schedule for item in lines.woke], ["sched-01", "sched-03"])
        self.assertEqual(lines.files, 2)

    def test_no_log_for_the_window_reads_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            lines = watched.read_log(pathlib.Path(raw), date(2026, 11, 1), date(2026, 11, 1), SINCE, SINCE + DAY_SECONDS)
        self.assertEqual((lines.woke, lines.files, lines.unreadable), ((), 0, 0))


class Follow(unittest.TestCase):
    def follow(
        self,
        woke: watched.Woke,
        lines: watched.LogLines,
        *,
        creates: list[watched.Create] | None = None,
        runs: dict[str, list[waits.Interval]] | None = None,
        known: dict[tuple[str, str], slack.Run | None] | None = None,
    ) -> tuple[watched.Followed, list[tuple[str, str]]]:
        fetch, asked = fetch_of(known if known is not None else {(MASC, RUN_A): run_ending(NOON + 600)})
        made = runs if runs is not None else {}
        followed = watched.follow(woke, lines, creates if creates is not None else [watched.Create("k1", NOON, RUN_A)], fetch, made, clocks_of(made))
        return followed, asked

    def test_a_keeper_between_turns_takes_the_wake_at_once(self) -> None:
        runs = {"k1": [(NOON - 100, NOON + 50), (NOON + 100, NOON + 200), (NOON + 300, NOON + 400), (NOON + 625.5, NOON + 800)]}
        followed, asked = self.follow(woke_at(NOON + 610), lines_of({SCHED: (NOON + 625,)}, {SCHED: ((NOON + 625, "k1"),)}), runs=runs)
        # the turn before the create and the turn the wake starts are not other turns
        self.assertEqual(followed, chain())
        self.assertEqual(asked, [(MASC, RUN_A)])

    def test_a_keeper_inside_a_turn_at_dispatch_takes_the_wake_at_the_boundary(self) -> None:
        runs = {"k1": [(NOON + 500, NOON + 900), (NOON + 900.5, NOON + 1000)]}
        followed, _ = self.follow(woke_at(NOON + 610), lines_of({SCHED: (NOON + 625,)}, {SCHED: ((NOON + 900, "k1"),)}), runs=runs)
        self.assertEqual(followed, chain(delivered=NOON + 900, inside=True, other=1))

    def test_the_turn_the_wake_starts_in_the_dispatch_second_is_not_a_turn_in_progress(self) -> None:
        dispatched = lines_of({SCHED: (NOON + 625,)}, {SCHED: ((NOON + 625, "k1"),)})
        for start, inside in ((NOON + 625.5, False), (NOON + 624.9, True)):
            with self.subTest(start=start):
                followed, _ = self.follow(woke_at(NOON + 610), dispatched, runs={"k1": [(start, NOON + 700)]})
                self.assertEqual(followed.inside_turn, inside)

    def test_a_turn_that_starts_within_two_seconds_of_the_delivery_line_is_the_wakes_own(self) -> None:
        lines = lines_of({SCHED: (NOON + 625,)}, {SCHED: ((NOON + 625, "k1"),)})
        for start, counted in ((NOON + 622.5, True), (NOON + 623.5, False), (NOON + 624.9, False)):
            with self.subTest(start=start):
                followed, _ = self.follow(woke_at(NOON + 610), lines, runs={"k1": [(start, NOON + 700)]})
                self.assertEqual(followed.other_turns, 1 if counted else 0)

    def test_a_turn_that_starts_at_or_before_the_create_is_not_a_turn_during_the_wait(self) -> None:
        lines = lines_of({SCHED: (NOON + 625,)}, {SCHED: ((NOON + 625, "k1"),)})
        followed, _ = self.follow(woke_at(NOON + 610), lines, runs={"k1": [(NOON - 1, NOON + 100), (NOON, NOON + 100)]})
        self.assertEqual(followed.other_turns, 0)

    def test_a_wake_without_a_delivery_line_has_only_the_first_stages(self) -> None:
        followed, _ = self.follow(woke_at(NOON + 610), lines_of({SCHED: (NOON + 625,)}), runs={"k1": [(NOON + 100, NOON + 200)]})
        self.assertEqual(followed, chain(delivered=None, keeper=None, inside=None, created=None, other=None))

    def test_a_wake_without_any_runner_line_keeps_its_delivery(self) -> None:
        followed, _ = self.follow(woke_at(NOON + 610), lines_of(None, {SCHED: ((NOON + 625, "k1"),)}), runs={"k1": [(NOON + 100, NOON + 200)]})
        self.assertEqual(followed, chain(dispatched=None, inside=None, other=1))

    def test_lines_of_an_earlier_occurrence_are_not_this_wake(self) -> None:
        lines = lines_of({SCHED: (NOON + 100, NOON + 625)}, {SCHED: ((NOON + 100, "k2"), (NOON + 625, "k1"))})
        followed, _ = self.follow(woke_at(NOON + 610), lines, runs={"k1": [(NOON + 100, NOON + 200)]})
        self.assertEqual((followed.dispatched, followed.delivered, followed.keeper), (NOON + 625, NOON + 625, "k1"))

    def test_a_runner_line_two_seconds_before_the_watcher_line_still_belongs(self) -> None:
        for stamp, belongs in ((NOON + 608, True), (NOON + 607, False)):
            with self.subTest(stamp=stamp):
                followed, _ = self.follow(woke_at(NOON + 610), lines_of({SCHED: (stamp,)}))
                self.assertEqual(followed.dispatched, stamp if belongs else None)

    def test_the_create_is_the_latest_of_that_keeper_for_that_run_before_the_watcher_line(self) -> None:
        creates = [
            watched.Create("k1", NOON - 50, RUN_A),
            watched.Create("k1", NOON, RUN_A),
            watched.Create("k2", NOON + 5, RUN_A),
            watched.Create("k1", NOON + 7, RUN_B),
            watched.Create("k1", NOON + 700, RUN_A),
        ]
        followed, _ = self.follow(woke_at(NOON + 610), lines_of({SCHED: (NOON + 625,)}, {SCHED: ((NOON + 625, "k1"),)}), creates=creates, runs={"k1": []})
        self.assertEqual((followed.created, followed.other_turns), (NOON, 0))

    def test_a_wake_without_a_create_has_no_parked_time(self) -> None:
        followed, _ = self.follow(woke_at(NOON + 610), lines_of({SCHED: (NOON + 625,)}, {SCHED: ((NOON + 625, "k1"),)}), creates=[], runs={"k1": [(NOON + 100, NOON + 200)]})
        self.assertEqual((followed.created, followed.other_turns), (None, None))

    def test_a_keeper_without_a_turn_file_has_no_turn_state_and_no_count(self) -> None:
        followed, _ = self.follow(woke_at(NOON + 610), lines_of({SCHED: (NOON + 625,)}, {SCHED: ((NOON + 625, "k1"),)}), runs={"k2": [(NOON + 100, NOON + 200)]})
        self.assertEqual((followed.inside_turn, followed.other_turns), (None, None))

    def test_a_run_that_is_unknown_unfinished_or_rerun_has_no_end(self) -> None:
        cases: dict[str, slack.Run | None] = {"unknown": None, "unfinished": run_ending(NOON + 600, completed=False), "rerun": run_ending(NOON + 600, attempt=2)}
        for name, answer in cases.items():
            with self.subTest(name=name):
                followed, _ = self.follow(woke_at(NOON + 610), lines_of(), known={(MASC, RUN_A): answer})
                self.assertIsNone(followed.end)


class Stages(unittest.TestCase):
    def test_nearest_rank_over_the_known_values_only(self) -> None:
        self.assertEqual(watched.stage([None, 4.0, 1.0, 3.0, 2.0]), {"n": 4, "median": 2.0, "p90": 4.0, "max": 4.0})
        self.assertEqual(watched.stage([None]), {"n": 0, "median": None, "p90": None, "max": None})

    def test_a_difference_below_zero_reads_as_zero(self) -> None:
        # the run ended 0.9 s after the second the watcher line is stamped with
        stages = watched.stages_of([chain(end=NOON + 610.9)])
        self.assertEqual(stages["end_to_woke"], {"n": 1, "median": 0.0, "p90": 0.0, "max": 0.0})

    def test_a_missing_time_leaves_the_stage_out(self) -> None:
        stages = watched.stages_of([chain(end=None, dispatched=None, delivered=None)])
        self.assertEqual([stages[name]["n"] for name in ("end_to_woke", "woke_to_dispatch", "dispatch_to_delivered", "end_to_delivered")], [0, 0, 0, 0])


class Summarize(unittest.TestCase):
    def test_nothing_followed_gives_empty_statistics(self) -> None:
        summary = watched.summarize([], 0, 0)
        self.assertEqual((summary["wakes"], summary["delivered"], summary["by_conclusion"], summary["by_keeper"]), (0, 0, {}, {}))
        self.assertEqual(
            summary["parked"],
            {
                "wakes": 0,
                "hours": 0.0,
                "median_min": None,
                "p90_min": None,
                "max_min": None,
                "other_turns": 0,
                "wakes_with_other_turns": 0,
                "other_turns_per_wake": {"n": 0, "median": None, "p90": None, "max": None},
            },
        )

    def test_the_counts_that_say_what_was_left_out(self) -> None:
        followed = [
            chain(),
            chain(delivered=None, keeper=None, inside=None, created=None, other=None, conclusion="failure"),
            chain(end=None, created=None, other=None, conclusion="cancelled"),
            chain(inside=None, other=None),
        ]
        summary = watched.summarize(followed, 5, 3)
        self.assertEqual(summary["watched_creates"], 5)
        self.assertEqual(summary["wakes"], 4)
        self.assertEqual(summary["by_conclusion"], {"cancelled": 1, "failure": 1, "success": 2})
        self.assertEqual(summary["delivered"], 3)
        self.assertEqual(summary["without_delivery_line"], 1)
        self.assertEqual(summary["end_unknown"], 1)
        self.assertEqual(summary["without_create"], 1)
        self.assertEqual(summary["turn_state_unknown"], 1)
        self.assertEqual(summary["unreadable_log_lines"], 3)
        self.assertEqual(object_of(summary["idle_at_dispatch"])["wakes"], 2)
        self.assertEqual(object_of(summary["parked"])["wakes"], 1)

    def test_the_split_by_keeper_is_ranked_by_wakes_then_name_and_capped(self) -> None:
        followed = [chain(keeper=f"k{number}") for number in range(1, 10)] + [chain(keeper="k9")]
        by_keeper = object_of(watched.summarize(followed, 10, 0)["by_keeper"])
        self.assertEqual(list(by_keeper), ["k9", "k1", "k2", "k3", "k4", "k5", "k6", "k7"])
        self.assertEqual(object_of(by_keeper["k9"])["wakes"], 2)


class Build(unittest.TestCase):
    def write_fixture(self, base: pathlib.Path) -> None:
        write_ledger(
            base,
            "01.jsonl",
            [
                create_row("k1", url(RUN_A), ts=NOON),
                create_row("k3", url(RUN_C), ts=NOON + 10),
                create_row("k2", url(RUN_B, WKBL), ts=NOON + 50),
            ],
        )
        write_log(
            base,
            "2026-11-01",
            [
                woke_row(NOON + 610, "sched-01", run_id=RUN_A),
                dispatch_row(NOON + 625, "sched-01"),
                delivered_row(NOON + 625, "sched-01", "k1"),
                woke_row(NOON + 700, "sched-03", run_id=RUN_C, conclusion="cancelled"),
                dispatch_row(NOON + 705, "sched-03"),
                woke_row(NOON + 1020, "sched-02", repo=WKBL, run_id=RUN_B, conclusion="failure"),
                dispatch_row(NOON + 1030, "sched-02"),
                delivered_row(NOON + 1500, "sched-02", "k2"),
            ],
        )
        write_turn(base, "k1", "t0.jsonl", NOON - 100, NOON + 50)
        write_turn(base, "k1", "t1.jsonl", NOON + 100, NOON + 200)
        write_turn(base, "k1", "t2.jsonl", NOON + 300, NOON + 400)
        write_turn(base, "k1", "t3.jsonl", NOON + 625.5, NOON + 800)
        write_turn(base, "k2", "t4.jsonl", NOON + 200, NOON + 300)
        write_turn(base, "k2", "t5.jsonl", NOON + 900, NOON + 1500)
        write_turn(base, "k2", "t6.jsonl", NOON + 1500.5, NOON + 1600)

    def known(self) -> dict[tuple[str, str], slack.Run | None]:
        return {(MASC, RUN_A): run_ending(NOON + 600), (WKBL, RUN_B): run_ending(NOON + 1000, repo=WKBL), (MASC, RUN_C): None}

    def test_three_wakes_end_to_end(self) -> None:
        fetch, asked = fetch_of(self.known())
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            self.write_fixture(base)
            summary, log_files = watched.build(base, date(2026, 11, 1), date(2026, 11, 1), SINCE, SINCE + DAY_SECONDS, fetch, waits.load_lane_time())
        self.assertEqual(log_files, 1)
        self.assertEqual(
            [summary[name] for name in ("watched_creates", "wakes", "delivered", "without_delivery_line", "end_unknown", "without_create", "turn_state_unknown")],
            [3, 3, 2, 1, 1, 0, 0],
        )
        self.assertEqual(summary["by_conclusion"], {"cancelled": 1, "failure": 1, "success": 1})
        # k1: 10, 15, 0, 25 s. k2: 20, 10, 470, 500 s. k3 has no end and no delivery: 5 s from the watcher line to the runner line.
        self.assertEqual(
            summary["stages_s"],
            {
                "end_to_woke": {"n": 2, "median": 10.0, "p90": 20.0, "max": 20.0},
                "woke_to_dispatch": {"n": 3, "median": 10.0, "p90": 15.0, "max": 15.0},
                "dispatch_to_delivered": {"n": 2, "median": 0.0, "p90": 470.0, "max": 470.0},
                "end_to_delivered": {"n": 2, "median": 25.0, "p90": 500.0, "max": 500.0},
            },
        )
        idle = object_of(summary["idle_at_dispatch"])
        inside = object_of(summary["inside_a_turn_at_dispatch"])
        self.assertEqual((idle["wakes"], inside["wakes"]), (1, 1))
        self.assertEqual(object_of(object_of(idle["stages_s"])["end_to_delivered"])["median"], 25.0)
        self.assertEqual(object_of(object_of(inside["stages_s"])["dispatch_to_delivered"])["median"], 470.0)
        # parked 625 s and 1450 s; k1 ran two other turns (t1, t2), k2 two (t4, t5)
        self.assertEqual(
            summary["parked"],
            {
                "wakes": 2,
                "hours": 0.58,
                "median_min": 10.4,
                "p90_min": 24.2,
                "max_min": 24.2,
                "other_turns": 4,
                "wakes_with_other_turns": 2,
                "other_turns_per_wake": {"n": 2, "median": 2.0, "p90": 2.0, "max": 2.0},
            },
        )
        by_keeper = object_of(summary["by_keeper"])
        self.assertEqual(list(by_keeper), ["k1", "k2"])
        self.assertEqual(object_of(object_of(by_keeper["k1"])["parked"])["hours"], 0.17)
        self.assertEqual(object_of(object_of(by_keeper["k2"])["parked"])["hours"], 0.4)
        self.assertEqual(sorted(asked), sorted(self.known()))

    def test_a_run_shared_by_two_wakes_is_asked_once(self) -> None:
        fetch, asked = fetch_of({(MASC, RUN_A): run_ending(NOON + 600)})
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_log(
                base,
                "2026-11-01",
                [
                    woke_row(NOON + 610, "sched-01"),
                    woke_row(NOON + 611, "sched-02"),
                ],
            )
            summary, _ = watched.build(base, date(2026, 11, 1), date(2026, 11, 1), SINCE, SINCE + DAY_SECONDS, fetch, waits.load_lane_time())
        self.assertEqual(summary["wakes"], 2)
        self.assertEqual(asked, [(MASC, RUN_A)])

    def test_a_create_of_the_evening_before_meets_its_wake(self) -> None:
        fetch, _ = fetch_of({(MASC, RUN_A): run_ending(NOON - 20)})
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            write_ledger(base, "31.jsonl", [create_row("k1", url(RUN_A), ts=SINCE - 3600)], month="2026-10")
            write_log(
                base,
                "2026-11-01",
                [woke_row(NOON - 10, "sched-01"), dispatch_row(NOON - 5, "sched-01"), delivered_row(NOON - 5, "sched-01", "k1")],
            )
            write_turn(base, "k1", "t1.jsonl", SINCE - 1800, SINCE - 1700)
            summary, _ = watched.build(base, date(2026, 11, 1), date(2026, 11, 1), SINCE, SINCE + DAY_SECONDS, fetch, waits.load_lane_time())
        self.assertEqual((summary["watched_creates"], summary["without_create"]), (1, 0))
        parked = object_of(summary["parked"])
        self.assertEqual((parked["wakes"], parked["other_turns"]), (1, 1))
        self.assertEqual(parked["hours"], round((NOON - 5 - (SINCE - 3600)) / 3600, 2))


class Program(unittest.TestCase):
    def run_main(self, args: list[str], known: dict[tuple[str, str], slack.Run | None]) -> tuple[int, str]:
        fetch, _ = fetch_of(known)
        out = io.StringIO()
        with (
            mock.patch.object(sys, "argv", ["measure_watched_wakes.py", *args]),
            mock.patch.object(slack, "gh_run", side_effect=fetch),
            mock.patch.object(watched.shutil, "which", return_value="/usr/bin/gh"),
            contextlib.redirect_stdout(out),
        ):
            status = watched.main()
        return status, out.getvalue()

    def test_a_window_of_one_day_end_to_end(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            Build().write_fixture(base)
            target = base / "result.json"
            status, text = self.run_main(
                ["--base-path", str(base), "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--until", "2026-11-01T13:00:00", "--json-out", str(target)],
                Build().known(),
            )
            written = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(text), written)
        self.assertEqual(written["window"], {"from": "2026-11-01", "to": "2026-11-01", "until": "2026-11-01T13:00:00+00:00"})
        self.assertEqual((written["wakes"], written["delivered"]), (3, 2))
        self.assertEqual(written["parked"]["hours"], 0.58)
        self.assertIn("probed_at", written)

    def test_a_window_without_a_server_log_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as raw, self.assertRaises(SystemExit) as stopped, contextlib.redirect_stderr(io.StringIO()):
            self.run_main(["--base-path", raw, "--from-date", "2026-11-01", "--to-date", "2026-11-01"], {})
        self.assertEqual(stopped.exception.code, 2)

    def test_a_window_that_ends_before_it_starts_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as stopped, contextlib.redirect_stderr(io.StringIO()):
            self.run_main(["--base-path", "/nonexistent", "--from-date", "2026-11-02", "--to-date", "2026-11-01"], {})
        self.assertEqual(stopped.exception.code, 2)

    def test_an_until_outside_the_window_is_refused(self) -> None:
        for until in ("2026-10-31T23:00:00", "2026-11-02T00:00:01"):
            with self.subTest(until=until), self.assertRaises(SystemExit) as stopped, contextlib.redirect_stderr(io.StringIO()):
                self.run_main(["--base-path", "/nonexistent", "--from-date", "2026-11-01", "--to-date", "2026-11-01", "--until", until], {})
            self.assertEqual(stopped.exception.code, 2)

    def test_a_missing_gh_is_refused(self) -> None:
        with (
            mock.patch.object(sys, "argv", ["measure_watched_wakes.py", "--base-path", "/nonexistent", "--from-date", "2026-11-01", "--to-date", "2026-11-01"]),
            mock.patch.object(watched.shutil, "which", return_value=None),
            self.assertRaises(SystemExit) as stopped,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            watched.main()
        self.assertEqual(stopped.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
