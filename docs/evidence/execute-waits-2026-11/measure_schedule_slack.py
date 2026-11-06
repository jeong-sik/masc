#!/usr/bin/env python3
"""Compare when a Keeper's self-wake schedule fires with when the run it names ends.

Reads `<base-path>/.masc/tool_calls/YYYY-MM/DD[.NNN].jsonl`, the tool-call
ledger, and never writes to it. For each schedule the message of which names one
GitHub Actions run, it asks GitHub for the run (`gh api
repos/<owner>/<name>/actions/runs/<id>`) and compares the schedule's due time
with the end of that run. The answer depends on the day it is asked and on what
the `gh` login can read.

Definitions:

- schedule wake: a `masc_schedule_create` row whose recorded outcome is succeeded
  and whose input `keeper_name` equals the row's Keeper, a Keeper waking itself.
  This is the rule of measure_execute_waits.py.
- names a run: the `message` of the input holds a run id (`RUN_ID` of
  measure_execute_waits.py).
- watched: the input carries `until_github_run`, so the server wakes the schedule
  when that run ends and the due time is only the fallback. A watched wake says
  nothing about when its Keeper was woken, and it is not compared with the run.
  The tool has no such field before RFC-0379 section 6.5 is deployed.
- due time: `ts + due_in_sec`, else `due_at_unix`, else `due_at_iso` (a time
  without a zone is UTC), the first the input carries. `ts` is the time the row
  was written, after the call ended. A wake with none of them (a daily or cron
  recurrence) has no due time.
- run: the answer of the first repository of `--repos` for which GitHub answers.
  The end of the run is its `updated_at`.
- verdict, the first that fits:
  `watched`. `several_runs`: the message names more than one run, and the text does not say
  which one the wake waits for. `no_due_time`. `run_unreadable`: no repository
  answers, for whatever reason (404, no access, no network). `rerun`: the run has
  more than one attempt, so its `updated_at` may be the end of an attempt the
  Keeper did not wait for. `not_completed`: the run has not completed.
  `already_complete`: the run ended at or before the row's `ts`, so there was
  nothing to wait for. `late`: the run was still running at `ts` and the due time is
  at or after its end; the slack is due time minus end. `early`: the due time is
  before the end; the slack is end minus due time.
- remaining: end of the run minus `ts`, for the `late` and `early` wakes.

Percentiles are nearest rank: the ceil(p * n)-th value of the sorted n values.
The matching of run ids labels a wake in this report only. No runtime decision
reads it.

Usage:
    docs/evidence/execute-waits-2026-11/measure_schedule_slack.py --base-path ~/me \
        --from-date 2026-11-01 --to-date 2026-11-05 --json-out result.json
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys
from collections import Counter
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from enum import StrEnum

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[2] / "scripts" / "lib"))

import masc_base_path  # noqa: E402
import measure_execute_waits as waits  # noqa: E402
from recorded_tool_outcome import RecordedCallOutcome, recorded_call_outcome  # noqa: E402
from tool_call_log_paths import tool_call_log_paths  # noqa: E402

DEFAULT_REPOS = ("jeong-sik/masc", "jeong-sik/wkbl")
GH_TIMEOUT_SECONDS = 60
SECONDS_PER_MINUTE = 60
P10 = 0.1
TOP_KEEPERS = 8


class Verdict(StrEnum):
    WATCHED = "watched"
    SEVERAL_RUNS = "several_runs"
    NO_DUE_TIME = "no_due_time"
    RUN_UNREADABLE = "run_unreadable"
    RERUN = "rerun"
    NOT_COMPLETED = "not_completed"
    ALREADY_COMPLETE = "already_complete"
    LATE = "late"
    EARLY = "early"


@dataclass(frozen=True, slots=True)
class Wake:
    keeper: str
    stamp: float
    due: float | None
    run_ids: tuple[str, ...]
    watched: bool = False


@dataclass(frozen=True, slots=True)
class Run:
    repo: str
    attempt: int
    completed: bool
    end: float


@dataclass(frozen=True, slots=True)
class Judged:
    wake: Wake
    verdict: Verdict
    run: Run | None
    slack: float | None  # seconds; set for `late` and `early`


RunLookup = Callable[[str], Run | None]


def epoch_of(text: str) -> float | None:
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.timestamp()


def due_of(arguments: dict[str, object], stamp: float) -> float | None:
    seconds = waits.number_of(arguments.get("due_in_sec"))
    if seconds is not None:
        return stamp + seconds
    absolute = waits.number_of(arguments.get("due_at_unix"))
    if absolute is not None:
        return absolute
    text = arguments.get("due_at_iso")
    return epoch_of(text) if isinstance(text, str) else None


def wake_of(row: dict[str, object], stamp: float) -> Wake | None:
    arguments = waits.as_object(row.get("input"))
    if arguments is None or arguments.get("keeper_name") != waits.keeper_of(row):
        return None
    message = arguments.get("message")
    run_ids = waits.run_ids_of(message) if isinstance(message, str) else ()
    watch = arguments.get("until_github_run")
    watched = isinstance(watch, str) and watch.strip() != ""
    return Wake(waits.keeper_of(row), stamp, due_of(arguments, stamp), run_ids, watched)


def read_wakes(base: pathlib.Path, first: date, last: date, since: float, until: float) -> tuple[list[Wake], int]:
    """The schedule wakes in the window that name a run or are watched, and the schedule wakes of all kinds."""
    named: list[Wake] = []
    every = 0
    day = first
    while day <= last:
        live = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
        for path in tool_call_log_paths(base, live):
            with path.open("rb") as handle:
                for line in handle:
                    row = waits.parse_row(line) if line.strip() else None
                    stamp = waits.number_of(row.get("ts")) if row is not None else None
                    if row is None or stamp is None or not since <= stamp < until:
                        continue
                    if row.get("record_kind") != waits.TOOL_CALL_RECORD_KIND or row.get("tool") != waits.SCHEDULE_CREATE_TOOL:
                        continue
                    if recorded_call_outcome(row) is not RecordedCallOutcome.SUCCEEDED:
                        continue
                    wake = wake_of(row, stamp)
                    if wake is None:
                        continue
                    every += 1
                    if wake.run_ids or wake.watched:
                        named.append(wake)
        day += timedelta(days=1)
    return named, every


def run_of(repo: str, answer: object) -> Run | None:
    fields = waits.as_object(answer)
    if fields is None:
        return None
    attempt = fields.get("run_attempt")
    updated = fields.get("updated_at")
    end = epoch_of(updated) if isinstance(updated, str) else None
    if isinstance(attempt, bool) or not isinstance(attempt, int) or end is None:
        return None
    return Run(repo, attempt, fields.get("status") == "completed", end)


def gh_run(repo: str, run_id: str) -> Run | None:
    done = subprocess.run(
        ["gh", "api", f"repos/{repo}/actions/runs/{run_id}"],
        capture_output=True,
        text=True,
        timeout=GH_TIMEOUT_SECONDS,
        check=False,
    )
    if done.returncode != 0:
        return None
    try:
        return run_of(repo, json.loads(done.stdout))
    except ValueError:
        return None


def lookup_over(repos: Sequence[str], fetch: Callable[[str, str], Run | None]) -> RunLookup:
    cache: dict[str, Run | None] = {}

    def lookup(run_id: str) -> Run | None:
        if run_id not in cache:
            cache[run_id] = next((run for repo in repos if (run := fetch(repo, run_id)) is not None), None)
        return cache[run_id]

    return lookup


def judge(wake: Wake, lookup: RunLookup) -> Judged:
    """The verdict on a wake that names a run or is watched."""
    if wake.watched:
        return Judged(wake, Verdict.WATCHED, None, None)
    match wake.run_ids:
        case ():
            raise ValueError("judge is given a wake that names no run")
        case (run_id,):
            return judge_one(wake, run_id, lookup)
        case _:
            return Judged(wake, Verdict.SEVERAL_RUNS, None, None)


def judge_one(wake: Wake, run_id: str, lookup: RunLookup) -> Judged:
    if wake.due is None:
        return Judged(wake, Verdict.NO_DUE_TIME, None, None)
    run = lookup(run_id)
    if run is None:
        return Judged(wake, Verdict.RUN_UNREADABLE, None, None)
    if run.attempt > 1:
        return Judged(wake, Verdict.RERUN, run, None)
    if not run.completed:
        return Judged(wake, Verdict.NOT_COMPLETED, run, None)
    if run.end <= wake.stamp:
        return Judged(wake, Verdict.ALREADY_COMPLETE, run, None)
    if wake.due >= run.end:
        return Judged(wake, Verdict.LATE, run, wake.due - run.end)
    return Judged(wake, Verdict.EARLY, run, run.end - wake.due)


def minutes(seconds: float | None) -> float | None:
    return None if seconds is None else round(seconds / SECONDS_PER_MINUTE, 1)


def slack_summary(seconds: list[float]) -> dict[str, float | int | None]:
    return {
        "calls": len(seconds),
        "hours": waits.hours(sum(seconds)),
        "median_min": minutes(waits.nearest_rank(seconds, waits.MEDIAN)),
        "p90_min": minutes(waits.nearest_rank(seconds, waits.P90)),
        "max_min": minutes(max(seconds)) if seconds else None,
    }


def tally(judged: list[Judged]) -> dict[str, object]:
    late = [item.slack for item in judged if item.verdict is Verdict.LATE and item.slack is not None]
    early = [item.slack for item in judged if item.verdict is Verdict.EARLY and item.slack is not None]
    return {
        "already_complete": sum(1 for item in judged if item.verdict is Verdict.ALREADY_COMPLETE),
        "late": slack_summary(late),
        "early": slack_summary(early),
    }


def spread_minutes(seconds: list[float]) -> dict[str, float | None]:
    return {
        "p10": minutes(waits.nearest_rank(seconds, P10)),
        "median": minutes(waits.nearest_rank(seconds, waits.MEDIAN)),
        "p90": minutes(waits.nearest_rank(seconds, waits.P90)),
    }


def summarize(judged: list[Judged], schedule_wakes: int, repos: Sequence[str]) -> dict[str, object]:
    counts = Counter(item.verdict for item in judged)
    waited = [item for item in judged if item.verdict in (Verdict.LATE, Verdict.EARLY) and item.run is not None]
    due_in = [item.wake.due - item.wake.stamp for item in waited if item.wake.due is not None]
    remaining = [item.run.end - item.wake.stamp for item in waited if item.run is not None]
    by_repo = {repo: tally([item for item in judged if item.run is not None and item.run.repo == repo]) for repo in repos}
    keepers = Counter(item.wake.keeper for item in waited)
    by_keeper = {
        keeper: tally([item for item in judged if item.wake.keeper == keeper])
        for keeper, _ in keepers.most_common(TOP_KEEPERS)
    }
    return {
        "schedule_wakes": schedule_wakes,
        "names_a_run": sum(1 for item in judged if item.wake.run_ids),
        "verdicts": {verdict.value: counts.get(verdict, 0) for verdict in Verdict},
        "distinct_runs_measured": len({item.wake.run_ids[0] for item in judged if item.verdict in (Verdict.ALREADY_COMPLETE, Verdict.LATE, Verdict.EARLY)}),
        "running_at_creation": len(waited),
        **tally(judged),
        "due_in_min": spread_minutes(due_in),
        "remaining_min": spread_minutes(remaining),
        "by_repo": by_repo,
        "by_keeper": by_keeper,
    }


def parse_repos(text: str) -> tuple[str, ...]:
    return tuple(part for part in text.split(",") if part)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", default=None, help="directory that contains .masc; MASC_BASE_PATH when omitted")
    parser.add_argument("--from-date", type=waits.parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=waits.parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--until", type=waits.parse_until, default=None, help="ignore anything at or after this ISO-8601 time")
    parser.add_argument("--repos", type=parse_repos, default=DEFAULT_REPOS, help="owner/name list, comma separated; asked in this order")
    parser.add_argument("--json-out", default=None, help="write the summary to this file")
    args = parser.parse_args()
    base = masc_base_path.require(parser, args.base_path, "--base-path")

    if args.to_date < args.from_date:
        parser.error("--to-date is before --from-date")
    if args.to_date == date.max:
        parser.error(f"--to-date must be before {date.max.isoformat()}")
    if shutil.which("gh") is None:
        parser.error("the gh command is not on PATH")
    since = datetime(args.from_date.year, args.from_date.month, args.from_date.day, tzinfo=timezone.utc).timestamp()
    end_of_last_day = (datetime(args.to_date.year, args.to_date.month, args.to_date.day, tzinfo=timezone.utc) + timedelta(days=1)).timestamp()
    until = args.until if args.until is not None else end_of_last_day
    if not since < until <= end_of_last_day:
        parser.error("--until must be after --from-date midnight and not after the end of --to-date")
    named, every = read_wakes(base, args.from_date, args.to_date, since, until)
    lookup = lookup_over(args.repos, gh_run)
    summary = {
        "window": {
            "from": args.from_date.isoformat(),
            "to": args.to_date.isoformat(),
            "until": datetime.fromtimestamp(until, timezone.utc).isoformat(),
        },
        "probed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "repos": list(args.repos),
        **summarize([judge(wake, lookup) for wake in named], every, args.repos),
    }
    text = json.dumps(summary, indent=2, sort_keys=True)
    if args.json_out:
        try:
            pathlib.Path(args.json_out).write_text(text + "\n", encoding="utf-8")
        except OSError as error:
            parser.error(f"cannot write --json-out {args.json_out}: {error}")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
