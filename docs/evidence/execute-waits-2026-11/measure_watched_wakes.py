#!/usr/bin/env python3
"""Follow each watched schedule wake from the end of its GitHub run to the turn it starts.

Reads three stores under `<base-path>/.masc`, never writes to them, and asks GitHub
for the end of each run:

- `tool_calls/YYYY-MM/DD[.NNN].jsonl`, the tool-call ledger: the rows that created
  the watched schedules.
- `logs/system_log_YYYY-MM-DD.jsonl`, the server log: three lines per wake, each
  stamped to the second. A schedule id is any text without whitespace or a comma; a
  caller may choose it.
  - watcher: `schedule_run_watch: woke <schedule id>, <owner/name> run <id> completed: <conclusion>`.
    The run reads `run <id> attempt <n>` when the watch names an attempt. The line ends
    `completed with no conclusion` when GitHub gave none, and reads
    `woke <schedule id> early, <run> cannot be read: <reason>` when the run could not be
    read. The conclusion of the wake is the written conclusion, `no_conclusion` or
    `unreadable`. A line that starts `schedule_run_watch: woke ` and fits none of these
    forms is counted under `unrecognized_watcher_lines` and is not a wake.
  - runner: `schedule_runner: occurrence=<id> schedule_id=<schedule id> dispatch=succeeded`
  - delivery: `scheduled wake delivered schedule_id=<schedule id> due_at=<n> (keeper=<name>)`
- `keeper_turn_events/<keeper>/*.jsonl`, through measure_lane_time.py: the run
  intervals of each Keeper. A run interval is the first to the last event of its
  trace file, read from one day before the window. A turn that writes no trace file (an
  operator's direct chat turn) is not an interval: a Keeper inside one reads as idle and
  its other turns miss it.

Definitions:

- watched create: a `masc_schedule_create` row whose recorded outcome is succeeded,
  whose input `keeper_name` equals the row's Keeper (a Keeper waking itself) and whose
  `until_github_run` holds exactly one run id. `ts` of the row is the time the call
  ended. The ledger is read from one day before the window, so that a create made the
  evening before can meet its wake.
- wake: a watcher line in the window, once per schedule id, the first. The first runner
  line and the first delivery line of the same schedule id, stamped at most
  `JOIN_LOOKBACK_SECONDS` before the watcher line or later, belong to it. The watcher
  writes its lines after it has read every watched run of the pass, and the runner can
  pick up a woken schedule before that. A watched schedule is one-shot, so it has one
  runner line; the lookback only keeps out an earlier use of an id the caller chose again.
  A wake without a delivery line (the line is outside the window or was never written) is
  counted under `without_delivery_line` and has no stage after the runner.
- end: `updated_at` of the run, read from GitHub for the repository the watcher line
  names. A run that has not completed, whose latest attempt is not the attempt the watch
  names (attempt 1 when it names none), or that GitHub does not answer for has no end
  (`end_unknown`). Its wake has no first stage.
- stages, in seconds. The logs are stamped to the second, so a difference below zero reads as 0.
  `end_to_woke` is the watcher line minus the end. `woke_to_dispatch` is the runner line
  minus the watcher line. `dispatch_to_delivered` is the delivery line minus the runner
  line. `end_to_delivered` is the delivery line minus the end.
- inside a turn at dispatch: a run interval of the delivered Keeper covers the instant the
  runner line is stamped (the start of that second). The runner hands the wake to the
  Keeper at that moment, and a Keeper inside a turn takes it at the turn boundary. The
  rest of the second is not tested: the turn the wake itself starts can begin there. A
  delivered wake without a runner line, or whose Keeper has no run interval, is
  `turn_state_unknown`.
- create match: the latest watched create of the delivered Keeper for the same run id
  whose `ts` is at or before the watcher line and that no earlier wake has taken. Wakes
  take their create in the order of their watcher lines, so two schedules of one Keeper on
  one run take one create each. A wake without one has no parked time. The ledger keeps no
  schedule id, so the create of a cancelled schedule can be taken in place of the right one.
- parked: the delivery line minus the `ts` of the create match. other turns: run intervals
  of the same Keeper that start after the create and more than two seconds before the
  delivery line. The turn the wake starts is not counted; the two seconds are the
  resolution of the log. A wake whose Keeper has no run interval has no count and is left
  out of `parked`.

`server_log` in the output names the server log files read and the days of the window
that have none. A day without its file leaves that day's wakes out without a word
otherwise.

Percentiles are nearest rank: the ceil(p * n)-th value of the sorted n values. The answer
for the end of a run depends on the day it is asked and on what the `gh` login can read.
The matching of a wake to its create labels a wake in this report only. No runtime
decision reads it.

Usage:
    python3 docs/evidence/execute-waits-2026-11/measure_watched_wakes.py --base-path ~/me \
        --from-date 2026-11-06 --to-date 2026-11-06 --until 2026-11-06T12:40:00 --json-out result.json
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import sys
from collections import Counter, defaultdict
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[2] / "scripts" / "lib"))

import masc_base_path  # noqa: E402
import measure_execute_waits as waits  # noqa: E402
import measure_schedule_slack as slack  # noqa: E402
from recorded_tool_outcome import RecordedCallOutcome, recorded_call_outcome  # noqa: E402
from tool_call_log_paths import tool_call_log_paths  # noqa: E402

LOG_TIME = "%Y-%m-%dT%H:%M:%SZ"
WOKE = re.compile(r"schedule_run_watch: woke ([^\s,]+)(?: early)?, (.*)$")
WOKE_RUN = re.compile(
    r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) run ([0-9]+)(?: attempt ([0-9]+))? "
    r"(?:completed: (\S+)|(completed with no conclusion)|(cannot be read: .*))$"
)
DISPATCHED = re.compile(r"schedule_runner: occurrence=\S+ schedule_id=(\S+) dispatch=succeeded")
DELIVERED = re.compile(r"scheduled wake delivered schedule_id=(\S+) .*\(keeper=([A-Za-z0-9_.-]+)\)")
LOG_LINE_MARKS = re.compile(rb"schedule_run_watch: woke |schedule_runner: occurrence=|scheduled wake delivered")
NO_CONCLUSION = "no_conclusion"
UNREADABLE = "unreadable"
LOG_RESOLUTION_SECONDS = 2.0
JOIN_LOOKBACK_SECONDS = 60.0
INSTANT = 0.001  # TurnClock.overlap has no point test; a span that covers [t, t + INSTANT] covers t
LOOKBACK = timedelta(days=1)

Fetch = Callable[[str, str], slack.Run | None]


@dataclass(frozen=True, slots=True)
class Create:
    keeper: str
    stamp: float
    run_id: str


@dataclass(frozen=True, slots=True)
class Woke:
    schedule: str
    repo: str
    run_id: str
    conclusion: str
    stamp: float
    attempt: int | None = None


@dataclass(frozen=True, slots=True)
class LogLines:
    woke: tuple[Woke, ...]
    dispatched: Mapping[str, tuple[float, ...]]
    delivered: Mapping[str, tuple[tuple[float, str], ...]]
    files: int
    unreadable: int
    unrecognized: int = 0
    missing_days: tuple[str, ...] = ()


class Creates:
    """The watched creates. A wake takes one create and no other wake takes it again."""

    def __init__(self, items: list[Create]) -> None:
        self.total = len(items)
        self._stamps: dict[tuple[str, str], list[float]] = defaultdict(list)
        for item in sorted(items, key=lambda entry: entry.stamp):
            self._stamps[(item.keeper, item.run_id)].append(item.stamp)

    def claim(self, keeper: str, run_id: str, at_or_before: float) -> float | None:
        """The latest create of the keeper for the run at or before the time, or None."""
        stamps = self._stamps.get((keeper, run_id), [])
        for index in range(len(stamps) - 1, -1, -1):
            if stamps[index] <= at_or_before:
                return stamps.pop(index)
        return None


@dataclass(frozen=True, slots=True)
class Followed:
    schedule: str
    run_id: str
    conclusion: str
    keeper: str | None
    end: float | None
    woke: float
    dispatched: float | None
    delivered: float | None
    inside_turn: bool | None
    created: float | None
    other_turns: int | None


def create_of(row: dict[str, object], stamp: float) -> Create | None:
    arguments = waits.as_object(row.get("input"))
    if arguments is None or arguments.get("keeper_name") != waits.keeper_of(row):
        return None
    watch = arguments.get("until_github_run")
    run_ids = waits.run_ids_of(watch) if isinstance(watch, str) else ()
    return Create(waits.keeper_of(row), stamp, run_ids[0]) if len(run_ids) == 1 else None


def read_creates(base: pathlib.Path, first: date, last: date, since: float, until: float) -> list[Create]:
    creates: list[Create] = []
    day = first
    while day <= last:
        live = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
        day += timedelta(days=1)
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
                    create = create_of(row, stamp)
                    if create is not None:
                        creates.append(create)
    return creates


def log_epoch(text: object) -> float | None:
    if not isinstance(text, str):
        return None
    try:
        return datetime.strptime(text, LOG_TIME).replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def log_path(base: pathlib.Path, day: date) -> pathlib.Path:
    return base / ".masc" / "logs" / f"system_log_{day.isoformat()}.jsonl"


def days_of(first: date, last: date) -> list[date]:
    return [first + timedelta(days=offset) for offset in range((last - first).days + 1)]


def woke_of(schedule: str, rest: str, stamp: float) -> Woke | None:
    """The wake a watcher line names, or None when the line is in none of the known forms."""
    found = WOKE_RUN.match(rest)
    if found is None:
        return None
    repo, run_id, attempt, conclusion, no_conclusion = found.groups()[:5]
    word = conclusion if conclusion is not None else NO_CONCLUSION if no_conclusion is not None else UNREADABLE
    return Woke(schedule, repo, run_id, word, stamp, int(attempt) if attempt is not None else None)


def read_log(base: pathlib.Path, first: date, last: date, since: float, until: float) -> LogLines:
    woke: dict[str, Woke] = {}
    dispatched: dict[str, list[float]] = defaultdict(list)
    delivered: dict[str, list[tuple[float, str]]] = defaultdict(list)
    files = 0
    unreadable = 0
    unrecognized = 0
    missing: list[str] = []
    for day in days_of(first, last):
        path = log_path(base, day)
        if not path.is_file():
            missing.append(day.isoformat())
            continue
        files += 1
        with path.open("rb") as handle:
            for line in handle:
                if LOG_LINE_MARKS.search(line) is None:
                    continue
                row = waits.parse_row(line)
                stamp = log_epoch(row.get("ts")) if row is not None else None
                message = row.get("message") if row is not None else None
                if row is None or stamp is None or not isinstance(message, str):
                    unreadable += 1
                    continue
                if not since <= stamp < until:
                    continue
                if (found := WOKE.search(message)) is not None:
                    parsed = woke_of(found.group(1), found.group(2), stamp)
                    if parsed is None:
                        unrecognized += 1
                    else:
                        woke.setdefault(parsed.schedule, parsed)
                elif (found := DISPATCHED.search(message)) is not None:
                    dispatched[found.group(1)].append(stamp)
                elif (found := DELIVERED.search(message)) is not None:
                    delivered[found.group(1)].append((stamp, found.group(2)))
    return LogLines(
        tuple(woke.values()),
        {schedule: tuple(stamps) for schedule, stamps in dispatched.items()},
        {schedule: tuple(items) for schedule, items in delivered.items()},
        files,
        unreadable,
        unrecognized,
        tuple(missing),
    )


def end_of(run: slack.Run | None, attempt: int | None) -> float | None:
    wanted = 1 if attempt is None else attempt
    return run.end if run is not None and run.completed and run.attempt == wanted else None


def follow(
    woke: Woke,
    lines: LogLines,
    creates: Creates,
    fetch: Fetch,
    runs: Mapping[str, list[waits.Interval]],
    clocks: Mapping[str, waits.TurnTime],
) -> Followed:
    floor = woke.stamp - JOIN_LOOKBACK_SECONDS
    dispatched = next((stamp for stamp in sorted(lines.dispatched.get(woke.schedule, ())) if stamp >= floor), None)
    delivery = next(((stamp, keeper) for stamp, keeper in sorted(lines.delivered.get(woke.schedule, ())) if stamp >= floor), None)
    delivered, keeper = delivery if delivery is not None else (None, None)
    inside: bool | None = None
    if dispatched is not None and keeper is not None and keeper in clocks:
        inside = clocks[keeper].overlap(dispatched, dispatched + INSTANT) > 0
    created = creates.claim(keeper, woke.run_id, woke.stamp) if keeper is not None else None
    other: int | None = None
    if created is not None and delivered is not None and keeper is not None and keeper in runs:
        other = sum(1 for start, _ in runs[keeper] if created < start < delivered - LOG_RESOLUTION_SECONDS)
    return Followed(
        woke.schedule,
        woke.run_id,
        woke.conclusion,
        keeper,
        end_of(fetch(woke.repo, woke.run_id), woke.attempt),
        woke.stamp,
        dispatched,
        delivered,
        inside,
        created,
        other,
    )


def gap(later: float | None, earlier: float | None) -> float | None:
    return None if later is None or earlier is None else max(0.0, later - earlier)


def stage(values: list[float | None]) -> dict[str, float | int | None]:
    known = [value for value in values if value is not None]
    return {
        "n": len(known),
        "median": waits.nearest_rank(known, waits.MEDIAN),
        "p90": waits.nearest_rank(known, waits.P90),
        "max": max(known) if known else None,
    }


def stages_of(items: list[Followed]) -> dict[str, dict[str, float | int | None]]:
    return {
        "end_to_woke": stage([gap(item.woke, item.end) for item in items]),
        "woke_to_dispatch": stage([gap(item.dispatched, item.woke) for item in items]),
        "dispatch_to_delivered": stage([gap(item.delivered, item.dispatched) for item in items]),
        "end_to_delivered": stage([gap(item.delivered, item.end) for item in items]),
    }


def parked_of(items: list[Followed]) -> dict[str, object]:
    parked = [item for item in items if item.created is not None and item.delivered is not None and item.other_turns is not None]
    seconds = [gap(item.delivered, item.created) or 0.0 for item in parked]
    turns = [item.other_turns for item in parked if item.other_turns is not None]
    return {
        "wakes": len(parked),
        "hours": waits.hours(sum(seconds)),
        "median_min": slack.minutes(waits.nearest_rank(seconds, waits.MEDIAN)),
        "p90_min": slack.minutes(waits.nearest_rank(seconds, waits.P90)),
        "max_min": slack.minutes(max(seconds) if seconds else None),
        "other_turns": sum(turns),
        "wakes_with_other_turns": sum(1 for count in turns if count > 0),
        "other_turns_per_wake": stage([float(count) for count in turns]),
    }


def summarize(followed: list[Followed], creates: int, unreadable: int, unrecognized: int = 0) -> dict[str, object]:
    delivered = [item for item in followed if item.delivered is not None]
    inside = [item for item in delivered if item.inside_turn is True]
    idle = [item for item in delivered if item.inside_turn is False]
    by_keeper: dict[str, list[Followed]] = defaultdict(list)
    for item in delivered:
        if item.keeper is not None:
            by_keeper[item.keeper].append(item)
    ranked = sorted(by_keeper.items(), key=lambda entry: (-len(entry[1]), entry[0]))[: waits.TOP_KEEPERS]
    return {
        "watched_creates": creates,
        "wakes": len(followed),
        "by_conclusion": dict(sorted(Counter(item.conclusion for item in followed).items())),
        "delivered": len(delivered),
        "without_delivery_line": len(followed) - len(delivered),
        "end_unknown": sum(1 for item in followed if item.end is None),
        "without_create": sum(1 for item in delivered if item.created is None),
        "turn_state_unknown": sum(1 for item in delivered if item.inside_turn is None),
        "unreadable_log_lines": unreadable,
        "unrecognized_watcher_lines": unrecognized,
        "stages_s": stages_of(followed),
        "idle_at_dispatch": {"wakes": len(idle), "stages_s": stages_of(idle)},
        "inside_a_turn_at_dispatch": {"wakes": len(inside), "stages_s": stages_of(inside)},
        "parked": parked_of(delivered),
        "by_keeper": {keeper: {"wakes": len(items), "parked": parked_of(items)} for keeper, items in ranked},
    }


def build(base: pathlib.Path, first: date, last: date, since: float, until: float, fetch: Fetch, lane: waits.LaneTime) -> dict[str, object]:
    creates = Creates(read_creates(base, first - LOOKBACK, last, since - LOOKBACK.total_seconds(), until))
    lines = read_log(base, first, last, since, until)
    runs = lane.read_runs(base, since - LOOKBACK.total_seconds(), until)
    clocks = {keeper: lane.clock_of(intervals) for keeper, intervals in runs.items()}
    cache: dict[tuple[str, str], slack.Run | None] = {}

    def cached(repo: str, run_id: str) -> slack.Run | None:
        if (repo, run_id) not in cache:
            cache[(repo, run_id)] = fetch(repo, run_id)
        return cache[(repo, run_id)]

    followed = [follow(woke, lines, creates, cached, runs, clocks) for woke in sorted(lines.woke, key=lambda item: (item.stamp, item.schedule))]
    summary = summarize(followed, creates.total, lines.unreadable, lines.unrecognized)
    summary["server_log"] = {"files_read": lines.files, "days_without_file": list(lines.missing_days)}
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", default=None, help="directory that contains .masc; MASC_BASE_PATH when omitted")
    parser.add_argument("--from-date", type=waits.parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=waits.parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--until", type=waits.parse_until, default=None, help="ignore anything at or after this ISO-8601 time")
    parser.add_argument("--json-out", default=None, help="write the summary to this file")
    args = parser.parse_args()
    base = masc_base_path.require(parser, args.base_path, "--base-path")

    if args.to_date < args.from_date:
        parser.error("--to-date is before --from-date")
    if args.to_date == date.max:
        parser.error(f"--to-date must be before {date.max.isoformat()}")
    if args.from_date < date.min + LOOKBACK:
        parser.error(f"--from-date must be on or after {(date.min + LOOKBACK).isoformat()}, the ledger is read one day earlier")
    if shutil.which("gh") is None:
        parser.error("the gh command is not on PATH")
    since = datetime(args.from_date.year, args.from_date.month, args.from_date.day, tzinfo=timezone.utc).timestamp()
    end_of_last_day = (datetime(args.to_date.year, args.to_date.month, args.to_date.day, tzinfo=timezone.utc) + timedelta(days=1)).timestamp()
    until = args.until if args.until is not None else end_of_last_day
    if not since < until <= end_of_last_day:
        parser.error("--until must be after --from-date midnight and not after the end of --to-date")
    try:
        lane = waits.load_lane_time()
    except (ImportError, OSError, SyntaxError, AttributeError) as error:
        parser.error(f"cannot load the turn reader from {waits.LANE_TIME_SCRIPT}: {error}")
    if not any(log_path(base, day).is_file() for day in days_of(args.from_date, args.to_date)):
        parser.error(f"no server log for {args.from_date.isoformat()}..{args.to_date.isoformat()} under {base}")
    summary = build(base, args.from_date, args.to_date, since, until, slack.gh_run, lane)
    report = {
        "window": {
            "from": args.from_date.isoformat(),
            "to": args.to_date.isoformat(),
            "until": datetime.fromtimestamp(until, timezone.utc).isoformat(),
        },
        "probed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        **summary,
    }
    text = json.dumps(report, indent=2, sort_keys=True)
    if args.json_out:
        try:
            pathlib.Path(args.json_out).write_text(text + "\n", encoding="utf-8")
        except OSError as error:
            parser.error(f"cannot write --json-out {args.json_out}: {error}")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
