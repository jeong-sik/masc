#!/usr/bin/env python3
"""Measure how long Execute calls run and what the long ones wait for.

Reads `<base-path>/.masc/tool_calls/YYYY-MM/DD[.NNN].jsonl`, the tool-call
ledger, and never writes to it. The ledger deletes old day files, so the same
window gives the same result until a day in it is deleted. A line that is not a
JSON object, holds NaN or Infinity, or is not valid UTF-8 is skipped and counted
under `skipped_lines`. Such a line has no readable timestamp, so `skipped_lines`
covers the whole day files, not only the window. `rows_in_window` counts every
row stamped inside the window, whatever its tool. `rows_without_timestamp` counts
the rows whose `ts` is not a finite number. `executes_without_duration` counts
the execute rows inside the window whose `duration_ms` is not a finite number of
at least 0. `files_read` counts the ledger files opened and `days_without_file`
lists the requested days that have none. The script exits with an error when it
opens no file.

Definitions:

- execute call: a ledger row with `record_kind == "tool_call"`, `tool == "Execute"`
  and a finite `duration_ms` of at least 0, stamped inside the window: from
  `--from-date` midnight UTC up to, not including, `--until` (the midnight after
  `--to-date` when omitted; a time without a zone is UTC). Its seconds are
  `duration_ms / 1000`. A failed call counts: the turn waited either way. The `ts`
  of a row is the time the row was written, after the call ended. A call belongs
  to the window and to the UTC day of its end.
- command: the `command` string of the input, or else its `argv` list with every
  item written by `str` and joined by spaces. This is the rule of `command_text`
  in scripts/measure-tool-efficiency.py. An input with neither has no command: its
  call is counted under `calls_without_command` and is never sleeping or tied to
  a run.
- sleeping: the command holds `sleep` and then a digit.
- run id: 10 or 11 digits after `actions/runs/`, or after `run ` or `runs `
  with an optional `view `, `watch `, `rerun ` or `cancel ` between. A longer
  digit string holds no run id. A literal id that only a shell loop variable
  carries to the `gh` call is not seen.
- repository: `owner/name` after `repos/`, `-R `, `--repo ` (or `--repo=`) or
  `github.com/`, in lower case without a trailing `.git`. A command that names
  several repositories belongs to each.
- kind: the first of these that fits the command. `names_a_run`: it holds a run id.
  `gh_without_run`: it holds the word `gh`. `build_or_test`: it holds the word
  `dune`, `opam`, `make`, `npm`, `pnpm`, `yarn`, `cargo`, `pytest`, `vitest` or
  `tsc`, or `python -m unittest`. `rest`: none of those, which includes a call
  without a command.
- long call: an execute call of 60 seconds or more.
- by day: the execute calls grouped by the UTC date of their `ts`. A window that
  ends inside a day holds only the part before `--until` for that day.
- poll call: a sleeping execute call that names at least one run id.
- run wait: the poll calls of one Keeper that name the same run id. A poll call
  that names several run ids is a poll of the wait of each. The wait is the sum of
  its polls' seconds and names the repositories that any of its polls name. The
  totals (`polls`, `blocked_hours`, the hours of a Keeper or a repository) count
  each poll call once. The per-wait figures count a call in each wait it belongs
  to, and `polls_summed_over_waits` and `blocked_hours_summed_over_waits` are the
  totals when every wait counts its own polls.
- schedule wake: a `masc_schedule_create` row whose recorded outcome is succeeded
  (scripts/lib/recorded_tool_outcome.py: `disposition` is `completed`, else
  `wire_outcome` is `ok`) and whose input `keeper_name` equals the row's Keeper, a
  Keeper waking itself. It names a run when its `message` holds a run id.

The command, run id and kind matching only labels a call in this report. No
runtime decision reads it. Percentiles are nearest rank: the ceil(p * n)-th value
of the sorted n values.

Usage:
    docs/evidence/execute-waits-2026-11/measure_execute_waits.py --base-path ~/me \
        --from-date 2026-11-01 --to-date 2026-11-05 --json-out result.json
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import sys
from collections import defaultdict
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from itertools import pairwise
from typing import cast

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))

import masc_base_path  # noqa: E402
from recorded_tool_outcome import RecordedCallOutcome, recorded_call_outcome  # noqa: E402
from tool_call_log_paths import tool_call_log_paths  # noqa: E402

TOOL_CALL_RECORD_KIND = "tool_call"
EXECUTE_TOOL = "Execute"
SCHEDULE_CREATE_TOOL = "masc_schedule_create"
UNKNOWN = "?"
MS_PER_SECOND = 1000
SECONDS_PER_MINUTE = 60
SECONDS_PER_HOUR = 3600
PERCENT = 100
MEDIAN = 0.5
P10 = 0.1
P90 = 0.9
LONG_CALL_SECONDS = 60
# Upper edges of the duration buckets in seconds. LONG_CALL_SECONDS is one of them.
DURATION_EDGES_SECONDS = (1, 3, 10, LONG_CALL_SECONDS, 300)
TOP_KEEPERS = 8
TOP_REPOS = 8
SLEEPING = re.compile(r"\bsleep\s+[0-9]")
REPO_NAME = re.compile(r"(?:\brepos/|-R\s+|--repo[ =]|github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)")
GIT_SUFFIX = ".git"
GH_CLI = re.compile(r"\bgh\b")
BUILD_TOOL = re.compile(r"\b(?:dune|opam|make|npm|pnpm|yarn|cargo|pytest|vitest|tsc)\b|\bpython3?\s+-m\s+unittest\b")
KIND_RUN = "names_a_run"
KIND_GH = "gh_without_run"
KIND_BUILD = "build_or_test"
KIND_REST = "rest"
KINDS = (KIND_RUN, KIND_GH, KIND_BUILD, KIND_REST)
GITHUB_KINDS = (KIND_RUN, KIND_GH)
RUN_ID = re.compile(r"(?:actions/runs/|\bruns?\s+(?:(?:view|watch|rerun|cancel)\s+)?)([0-9]{10,11})(?![0-9])")


@dataclass(frozen=True, slots=True)
class ExecuteCall:
    keeper: str
    seconds: float
    has_command: bool
    sleeping: bool
    run_ids: tuple[str, ...]
    repos: tuple[str, ...]
    kind: str
    day: date


@dataclass(frozen=True, slots=True)
class ScheduleWake:
    keeper: str
    due_in_sec: float | None
    run_ids: tuple[str, ...]


@dataclass(slots=True)
class Ledger:
    executes: list[ExecuteCall] = field(default_factory=lambda: [])
    wakes: list[ScheduleWake] = field(default_factory=lambda: [])
    schedule_creates: int = 0
    rows_in_window: int = 0
    skipped_lines: int = 0
    rows_without_timestamp: int = 0
    executes_without_duration: int = 0
    files_read: int = 0
    days_without_file: list[date] = field(default_factory=lambda: [])


def number_of(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        number = float(value)
    except OverflowError:
        return None
    return number if math.isfinite(number) else None


def reject_constant(token: str) -> object:
    raise ValueError(f"{token} is not a JSON number")


def as_object(value: object) -> dict[str, object] | None:
    return cast(dict[str, object], value) if isinstance(value, dict) else None


def parse_row(line: bytes) -> dict[str, object] | None:
    try:
        row: object = json.loads(line.decode("utf-8"), parse_constant=reject_constant)
    except ValueError:
        return None
    return as_object(row)


def command_of(tool_input: object) -> str | None:
    fields = as_object(tool_input)
    if fields is None:
        return None
    command = fields.get("command")
    if isinstance(command, str):
        return command
    argv = fields.get("argv")
    if isinstance(argv, list):
        return " ".join(str(part) for part in cast(list[object], argv))
    return None


def run_ids_of(text: str) -> tuple[str, ...]:
    return tuple(dict.fromkeys(RUN_ID.findall(text)))


def kind_of(text: str, run_ids: tuple[str, ...]) -> str:
    if run_ids:
        return KIND_RUN
    if GH_CLI.search(text) is not None:
        return KIND_GH
    if BUILD_TOOL.search(text) is not None:
        return KIND_BUILD
    return KIND_REST


def repos_of(text: str) -> tuple[str, ...]:
    names = (name.lower().removesuffix(GIT_SUFFIX) for name in REPO_NAME.findall(text))
    return tuple(dict.fromkeys(names))


def keeper_of(row: dict[str, object]) -> str:
    keeper = row.get("keeper")
    return keeper if isinstance(keeper, str) else UNKNOWN


def execute_call_of(row: dict[str, object], stamp: float) -> ExecuteCall | None:
    duration = number_of(row.get("duration_ms"))
    if duration is None or duration < 0:
        return None
    command = command_of(row.get("input"))
    text = command if command is not None else ""
    run_ids = run_ids_of(text)
    return ExecuteCall(
        keeper_of(row),
        duration / MS_PER_SECOND,
        command is not None,
        SLEEPING.search(text) is not None,
        run_ids,
        repos_of(text),
        kind_of(text, run_ids),
        datetime.fromtimestamp(stamp, timezone.utc).date(),
    )


def schedule_wake_of(row: dict[str, object]) -> ScheduleWake | None:
    arguments = as_object(row.get("input"))
    if arguments is None or arguments.get("keeper_name") != keeper_of(row):
        return None
    message = arguments.get("message")
    return ScheduleWake(
        keeper_of(row),
        number_of(arguments.get("due_in_sec")),
        run_ids_of(message) if isinstance(message, str) else (),
    )


def read_ledger(base: pathlib.Path, first: date, last: date, since: float, until: float) -> Ledger:
    ledger = Ledger()
    day = first
    while day <= last:
        live = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
        paths = tool_call_log_paths(base, live)
        if not paths:
            ledger.days_without_file.append(day)
        day += timedelta(days=1)
        for path in paths:
            ledger.files_read += 1
            with path.open("rb") as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    row = parse_row(line)
                    if row is None:
                        ledger.skipped_lines += 1
                        continue
                    stamp = number_of(row.get("ts"))
                    if stamp is None:
                        ledger.rows_without_timestamp += 1
                        continue
                    if not since <= stamp < until:
                        continue
                    ledger.rows_in_window += 1
                    if row.get("record_kind") != TOOL_CALL_RECORD_KIND:
                        continue
                    tool = row.get("tool")
                    if tool == EXECUTE_TOOL:
                        call = execute_call_of(row, stamp)
                        if call is None:
                            ledger.executes_without_duration += 1
                        else:
                            ledger.executes.append(call)
                    elif tool == SCHEDULE_CREATE_TOOL and recorded_call_outcome(row) is RecordedCallOutcome.SUCCEEDED:
                        ledger.schedule_creates += 1
                        wake = schedule_wake_of(row)
                        if wake is not None:
                            ledger.wakes.append(wake)
    return ledger


def hours(seconds: float) -> float:
    return round(seconds / SECONDS_PER_HOUR, 2)


def percent(part: float, whole: float) -> float | None:
    return round(PERCENT * part / whole, 1) if whole > 0 else None


def nearest_rank(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(math.ceil(fraction * len(ordered)) - 1, 0)]


def bucket_labels() -> list[str]:
    edges = DURATION_EDGES_SECONDS
    labels = [f"<{edges[0]}s"]
    labels += [f"{low}-{high}s" for low, high in pairwise(edges)]
    labels.append(f">={edges[-1]}s")
    return labels


def bucket_index(seconds: float) -> int:
    for index, edge in enumerate(DURATION_EDGES_SECONDS):
        if seconds < edge:
            return index
    return len(DURATION_EDGES_SECONDS)


def summarize_days(calls: list[ExecuteCall]) -> list[dict[str, object]]:
    grouped: dict[date, list[ExecuteCall]] = defaultdict(list)
    for call in calls:
        grouped[call.day].append(call)
    rows: list[dict[str, object]] = []
    for day in sorted(grouped):
        day_calls = grouped[day]
        long_calls = [call for call in day_calls if call.seconds >= LONG_CALL_SECONDS]
        rows.append(
            {
                "day": day.isoformat(),
                "calls": len(day_calls),
                "hours": hours(sum(call.seconds for call in day_calls)),
                "long_calls": len(long_calls),
                "long_hours": hours(sum(call.seconds for call in long_calls)),
                "sleeping_long_hours": hours(sum(call.seconds for call in long_calls if call.sleeping)),
            }
        )
    return rows


def summarize_kinds(long_calls: list[ExecuteCall], long_seconds: float, sleeping_seconds: float) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for kind in KINDS:
        members = [call for call in long_calls if call.kind == kind]
        sleeping = [call for call in members if call.sleeping]
        seconds = sum(call.seconds for call in members)
        kind_sleeping_seconds = sum(call.seconds for call in sleeping)
        rows.append(
            {
                "kind": kind,
                "calls": len(members),
                "hours": hours(seconds),
                "hours_percent_of_long": percent(seconds, long_seconds),
                "sleeping_calls": len(sleeping),
                "sleeping_hours": hours(kind_sleeping_seconds),
                "sleeping_hours_percent_of_sleeping": percent(kind_sleeping_seconds, sleeping_seconds),
            }
        )
    return rows


def summarize_execute(calls: list[ExecuteCall]) -> dict[str, object]:
    total = sum(call.seconds for call in calls)
    counts = [0] * len(bucket_labels())
    seconds = [0.0] * len(bucket_labels())
    for call in calls:
        index = bucket_index(call.seconds)
        counts[index] += 1
        seconds[index] += call.seconds
    buckets = [
        {"label": label, "calls": counts[index], "hours": hours(seconds[index]), "hours_percent": percent(seconds[index], total)}
        for index, label in enumerate(bucket_labels())
    ]
    long_calls = [call for call in calls if call.seconds >= LONG_CALL_SECONDS]
    long_seconds = sum(call.seconds for call in long_calls)
    sleeping = [call for call in long_calls if call.sleeping]
    sleeping_seconds = sum(call.seconds for call in sleeping)
    sleeping_github_seconds = sum(call.seconds for call in sleeping if call.kind in GITHUB_KINDS)
    return {
        "calls": len(calls),
        "calls_without_command": sum(1 for call in calls if not call.has_command),
        "hours": hours(total),
        "duration_buckets": buckets,
        "by_day": summarize_days(calls),
        "long_calls": {
            "threshold_seconds": LONG_CALL_SECONDS,
            "calls": len(long_calls),
            "calls_percent": percent(len(long_calls), len(calls)),
            "calls_without_command": sum(1 for call in long_calls if not call.has_command),
            "hours": hours(long_seconds),
            "hours_percent_of_execute": percent(long_seconds, total),
            "sleeping_calls": len(sleeping),
            "sleeping_hours": hours(sleeping_seconds),
            "sleeping_hours_percent_of_long": percent(sleeping_seconds, long_seconds),
            "sleeping_github_hours": hours(sleeping_github_seconds),
            "sleeping_github_percent_of_sleeping": percent(sleeping_github_seconds, sleeping_seconds),
            "by_kind": summarize_kinds(long_calls, long_seconds, sleeping_seconds),
        },
    }


def poll_calls(calls: list[ExecuteCall]) -> list[ExecuteCall]:
    return [call for call in calls if call.sleeping and call.run_ids]


def polls(calls: list[ExecuteCall]) -> Iterator[tuple[tuple[str, str], ExecuteCall]]:
    for call in poll_calls(calls):
        for run_id in call.run_ids:
            yield (call.keeper, run_id), call


def run_waits(calls: list[ExecuteCall]) -> dict[tuple[str, str], list[float]]:
    waits: dict[tuple[str, str], list[float]] = defaultdict(list)
    for key, call in polls(calls):
        waits[key].append(call.seconds)
    return waits


def run_wait_repos(calls: list[ExecuteCall]) -> dict[tuple[str, str], set[str]]:
    repos: dict[tuple[str, str], set[str]] = defaultdict(set)
    for key, call in polls(calls):
        repos[key].update(call.repos)
    return repos


def summarize_repos(calls: list[ExecuteCall]) -> dict[str, object]:
    waits = run_waits(calls)
    named = run_wait_repos(calls)
    count: dict[str, int] = defaultdict(int)
    blocked: dict[str, float] = defaultdict(float)
    without_seconds = 0.0
    for repos in named.values():
        for repo in repos:
            count[repo] += 1
    for call in poll_calls(calls):
        call_repos: set[str] = set()
        for run_id in call.run_ids:
            call_repos |= named[(call.keeper, run_id)]
        if not call_repos:
            without_seconds += call.seconds
        for repo in call_repos:
            blocked[repo] += call.seconds
    top = sorted(blocked, key=lambda repo: (-blocked[repo], repo))[:TOP_REPOS]
    return {
        "waits_without_a_repo": sum(1 for key in waits if not named[key]),
        "blocked_hours_without_a_repo": hours(without_seconds),
        "by_repo": [{"repo": repo, "waits": count[repo], "blocked_hours": hours(blocked[repo])} for repo in top],
    }


def spread(values: list[float], digits: int) -> dict[str, float | None]:
    def rounded(value: float | None) -> float | None:
        return None if value is None else round(value, digits)

    return {
        "median": rounded(nearest_rank(values, MEDIAN)),
        "p90": rounded(nearest_rank(values, P90)),
        "max": rounded(max(values)) if values else None,
    }


def blocked_seconds_by_keeper(calls: list[ExecuteCall]) -> dict[str, float]:
    blocked: dict[str, float] = defaultdict(float)
    for call in poll_calls(calls):
        blocked[call.keeper] += call.seconds
    return blocked


def summarize_run_waits(calls: list[ExecuteCall]) -> dict[str, object]:
    waits = run_waits(calls)
    distinct = poll_calls(calls)
    per_wait = [float(len(items)) for items in waits.values()]
    minutes = [sum(items) / SECONDS_PER_MINUTE for items in waits.values()]
    blocked = blocked_seconds_by_keeper(calls)
    blocked_seconds = sum(call.seconds for call in distinct)
    groups_by_keeper: dict[str, int] = defaultdict(int)
    for keeper, _ in waits:
        groups_by_keeper[keeper] += 1
    top = sorted(blocked, key=lambda keeper: (-blocked[keeper], keeper))[:TOP_KEEPERS]
    return {
        "waits": len(waits),
        "polls": len(distinct),
        "polls_naming_several_runs": sum(1 for call in distinct if len(call.run_ids) > 1),
        "polls_summed_over_waits": sum(len(items) for items in waits.values()),
        "single_poll_waits": sum(1 for items in waits.values() if len(items) == 1),
        "polls_per_wait": spread(per_wait, 0),
        "blocked_minutes_per_wait": spread(minutes, 1),
        "blocked_hours": hours(blocked_seconds),
        "blocked_hours_percent_of_execute": percent(blocked_seconds, sum(call.seconds for call in calls)),
        "blocked_hours_summed_over_waits": hours(sum(sum(items) for items in waits.values())),
        "top_keepers": [{"keeper": keeper, "blocked_hours": hours(blocked[keeper]), "waits": groups_by_keeper[keeper]} for keeper in top],
        "repos": summarize_repos(calls),
    }


def summarize_wakes(wakes: list[ScheduleWake], schedule_creates: int) -> dict[str, object]:
    naming = [wake for wake in wakes if wake.run_ids]
    delays = [wake.due_in_sec for wake in naming if wake.due_in_sec is not None]
    pairs = {(wake.keeper, run_id) for wake in naming for run_id in wake.run_ids}
    by_keeper: dict[str, int] = defaultdict(int)
    for wake in naming:
        by_keeper[wake.keeper] += 1
    top = sorted(by_keeper, key=lambda keeper: (-by_keeper[keeper], keeper))[:TOP_KEEPERS]
    return {
        "creates": schedule_creates,
        "self_wakes": len(wakes),
        "self_wakes_naming_a_run": len(naming),
        "distinct_keeper_run_pairs": len(pairs),
        "due_in_sec_of_those": {"p10": nearest_rank(delays, P10), "median": nearest_rank(delays, MEDIAN), "p90": nearest_rank(delays, P90)},
        "top_keepers": [{"keeper": keeper, "wakes": by_keeper[keeper]} for keeper in top],
    }


def keepers_in_both(calls: list[ExecuteCall], wakes: list[ScheduleWake]) -> list[dict[str, object]]:
    blocked = blocked_seconds_by_keeper(calls)
    woken: dict[str, int] = defaultdict(int)
    for wake in wakes:
        if wake.run_ids:
            woken[wake.keeper] += 1
    both = sorted(set(blocked) & set(woken), key=lambda keeper: (-blocked[keeper], keeper))
    return [{"keeper": keeper, "blocked_hours": hours(blocked[keeper]), "self_wakes_naming_a_run": woken[keeper]} for keeper in both]


def summarize(ledger: Ledger) -> dict[str, object]:
    return {
        "rows_in_window": ledger.rows_in_window,
        "skipped_lines": ledger.skipped_lines,
        "rows_without_timestamp": ledger.rows_without_timestamp,
        "executes_without_duration": ledger.executes_without_duration,
        "files_read": ledger.files_read,
        "days_without_file": [day.isoformat() for day in ledger.days_without_file],
        "execute": summarize_execute(ledger.executes),
        "run_waits": summarize_run_waits(ledger.executes),
        "schedule_wakes": summarize_wakes(ledger.wakes, ledger.schedule_creates),
        "keepers_in_both": keepers_in_both(ledger.executes, ledger.wakes),
    }


def parse_day(text: str) -> date:
    return date.fromisoformat(text)


def parse_until(text: str) -> float:
    moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.timestamp()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", default=None, help="directory that contains .masc; MASC_BASE_PATH when omitted")
    parser.add_argument("--from-date", type=parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--until", type=parse_until, default=None, help="ignore anything at or after this ISO-8601 time")
    parser.add_argument("--json-out", default=None, help="write the summary to this file")
    args = parser.parse_args()
    base = masc_base_path.require(parser, args.base_path, "--base-path")

    if args.to_date < args.from_date:
        parser.error("--to-date is before --from-date")
    since = datetime(args.from_date.year, args.from_date.month, args.from_date.day, tzinfo=timezone.utc).timestamp()
    end_of_last_day = (datetime(args.to_date.year, args.to_date.month, args.to_date.day, tzinfo=timezone.utc) + timedelta(days=1)).timestamp()
    until = args.until if args.until is not None else end_of_last_day
    if not since < until <= end_of_last_day:
        parser.error("--until must be after --from-date midnight and not after the end of --to-date")
    ledger = read_ledger(base, args.from_date, args.to_date, since, until)
    if ledger.files_read == 0:
        parser.error(f"no ledger file for {args.from_date.isoformat()}..{args.to_date.isoformat()} under {base}")
    summary = {
        "window": {
            "from": args.from_date.isoformat(),
            "to": args.to_date.isoformat(),
            "until": datetime.fromtimestamp(until, timezone.utc).isoformat(),
        },
        **summarize(ledger),
    }
    text = json.dumps(summary, indent=2, sort_keys=True)
    print(text)
    if args.json_out:
        pathlib.Path(args.json_out).write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
