#!/usr/bin/env python3
"""What the long Execute calls that wait on GitHub wait for, and whether the Keeper had put that run under a watch.

Read-only.

Usage:
    python3 -I docs/evidence/tool-efficiency-1110-2026-11/github_wait_shapes.py SINCE_ISO END_ISO [BASE_PATH]

The window is [SINCE, END) in UTC by the time a call ended. BASE_PATH defaults to ~/me. The ledger rows are read from
BASE_PATH/.masc/tool_calls/YYYY-MM/*.jsonl.

A long call is an Execute row with duration_ms of 60 s or more. It is a GitHub wait when its command text matches
GITHUB. Its shape is the first rule of SHAPES that matches:
  single_run     names one Actions run by number (actions/runs/<id>, gh run view|watch <id>); the
                 masc_schedule_create until_github_run parameter is meant for this wait
  commit_checks  reads the check runs or status of a commit
  pr_checks      reads a pull request (gh pr checks|view|status|list)
  run_list       lists runs (gh run list)
  api_other      any other gh api call
  watch_other    any other --watch
  other          the rest of GITHUB (for example gh run view with the id in a shell variable)

Prints one JSON object:
  execute                 calls, run_in_background, long_calls, long_run_in_background (all Execute rows of the window)
  github_wait             calls, hours, and per shape: calls, hours, share_of_hours, top_keepers
  single_run_polls        calls, hours, and
                            watched_by_same_keeper  the same Keeper had a completed masc_schedule_create with
                                                    until_github_run on that run id before the call ended
                            not_watched             the rest, with top_keepers
                            schedule_create_in_prior_15_min  of all polls, those preceded by a masc_schedule_create
                                                    of the same Keeper that began at most 15 minutes before the poll
                                                    began (any: any such call; with_until_github_run; refused_missing_due)
Watches are read from 6 hours before the window, so a run watched before the window starts is still seen.
"""

from __future__ import annotations

import collections
import dataclasses
import json
import pathlib
import re
import sys
from collections.abc import Iterable

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import ledger_window as ledger  # noqa: E402

LONG_S = 60.0
PRIOR_ATTEMPT_S = 15 * 60.0
WATCH_LOOKBACK_S = 6 * 3600.0
COMMAND_CHARS = 800
NEED_DUE = "one of due_at_unix, due_at_iso, due_in_sec is required"
HEAD_CHARS = 300
TOP_KEEPERS = 4

GITHUB = re.compile(r"gh\s+(run\s+(watch|view)|pr\s+checks|api)|--watch|gh\s+pr\s+(view|status)")
RUN_ID = re.compile(r"actions/runs/(\d+)|gh\s+run\s+(?:view|watch)\s+(\d+)")
SHAPES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("single_run", RUN_ID),
    ("commit_checks", re.compile(r"/commits/[^\s/\"']+/(check-runs|status|check-suites)")),
    ("pr_checks", re.compile(r"gh\s+pr\s+(checks|view|status|list)")),
    ("run_list", re.compile(r"gh\s+run\s+list")),
    ("api_other", re.compile(r"gh\s+api")),
    ("watch_other", re.compile(r"--watch")),
)
URL_RUN_ID = re.compile(r"actions/runs/(\d+)")


@dataclasses.dataclass(frozen=True, slots=True)
class Create:
    began: float
    ended: float
    keeper: str
    run_id: str | None
    has_until: bool
    completed: bool
    refused_missing_due: bool


@dataclasses.dataclass(frozen=True, slots=True)
class Poll:
    keeper: str
    run_id: str
    began: float
    ended: float


def command_of(row: ledger.Row) -> str:
    inp = ledger.input_of(row)
    command = inp.get("command")
    return command if isinstance(command, str) else json.dumps(inp, ensure_ascii=False)[:COMMAND_CHARS]


def shape_of(command: str) -> str | None:
    """None when the command is not a GitHub wait."""
    if not GITHUB.search(command):
        return None
    return next((name for name, pattern in SHAPES if pattern.search(command)), "other")


def run_id_of(command: str) -> str | None:
    found = RUN_ID.search(command)
    return None if found is None else found.group(1) or found.group(2)


def read_create(row: ledger.Row) -> Create:
    inp = ledger.input_of(row)
    until = inp.get("until_github_run")
    found = URL_RUN_ID.search(until) if isinstance(until, str) else None
    head = ledger.text_of(row.get("output"))[:HEAD_CHARS]
    ended = ledger.number_of(row, "ts")
    return Create(
        began=ended - ledger.number_of(row, "duration_ms") / 1000,
        ended=ended,
        keeper=ledger.keeper_of(row),
        run_id=None if found is None else found.group(1),
        has_until="until_github_run" in inp,
        completed=row.get("disposition") == "completed",
        refused_missing_due=row.get("disposition") == "failed" and NEED_DUE in head,
    )


def hours_of(row: ledger.Row) -> float:
    return ledger.number_of(row, "duration_ms") / 3.6e6


def measure(execute_rows: Iterable[ledger.Row], schedule_rows: Iterable[ledger.Row]) -> dict[str, object]:
    """`execute_rows` are the Execute rows of the window. `schedule_rows` are the masc_schedule_create rows from
    WATCH_LOOKBACK_S before the window to its end."""
    creates = [read_create(row) for row in schedule_rows if row.get("tool") == "masc_schedule_create"]
    watched_at: dict[tuple[str, str], list[float]] = collections.defaultdict(list)
    for create in creates:
        if create.has_until and create.completed and create.run_id is not None:
            watched_at[(create.keeper, create.run_id)].append(create.ended)

    execute = collections.Counter[str]()
    shape_calls = collections.Counter[str]()
    shape_hours: collections.defaultdict[str, float] = collections.defaultdict(float)
    shape_keepers: collections.defaultdict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    polls: list[tuple[Poll, float]] = []
    for row in execute_rows:
        if row.get("tool") != "Execute":
            continue
        background = ledger.input_of(row).get("run_in_background") is True
        duration_s = ledger.number_of(row, "duration_ms") / 1000
        execute["calls"] += 1
        execute["run_in_background"] += background
        if duration_s < LONG_S:
            continue
        execute["long_calls"] += 1
        execute["long_run_in_background"] += background
        command = command_of(row)
        shape = shape_of(command)
        if shape is None:
            continue
        keeper = ledger.keeper_of(row)
        shape_calls[shape] += 1
        shape_hours[shape] += hours_of(row)
        shape_keepers[shape][keeper] += 1
        run_id = run_id_of(command) if shape == "single_run" else None
        if run_id is not None:
            ended = ledger.number_of(row, "ts")
            polls.append((Poll(keeper, run_id, ended - duration_s, ended), hours_of(row)))

    total_hours = sum(shape_hours.values())
    shapes = {
        name: {
            "calls": shape_calls[name],
            "hours": round(shape_hours[name], 3),
            "share_of_hours": round(shape_hours[name] / total_hours, 4) if total_hours else None,
            "top_keepers": shape_keepers[name].most_common(TOP_KEEPERS),
        }
        for name in sorted(shape_calls, key=lambda name: -shape_hours[name])
    }

    watched = {"calls": 0, "hours": 0.0}
    unwatched = {"calls": 0, "hours": 0.0}
    unwatched_keepers = collections.Counter[str]()
    prior = collections.Counter[str]()
    for poll, hours in polls:
        if any(ts <= poll.ended for ts in watched_at.get((poll.keeper, poll.run_id), [])):
            bucket = watched
        else:
            bucket = unwatched
            unwatched_keepers[poll.keeper] += 1
        bucket["calls"] += 1
        bucket["hours"] += hours
        before = [
            create
            for create in creates
            if create.keeper == poll.keeper and poll.began - PRIOR_ATTEMPT_S <= create.began <= poll.began
        ]
        if before:
            prior["any"] += 1
        prior["with_until_github_run"] += any(create.has_until for create in before)
        prior["refused_missing_due"] += any(create.refused_missing_due for create in before)

    return {
        "execute": {key: execute[key] for key in ("calls", "run_in_background", "long_calls", "long_run_in_background")},
        "github_wait": {"calls": sum(shape_calls.values()), "hours": round(total_hours, 3), "shapes": shapes},
        "single_run_polls": {
            "calls": len(polls),
            "hours": round(sum(hours for _, hours in polls), 3),
            "watched_by_same_keeper": {"calls": watched["calls"], "hours": round(watched["hours"], 3)},
            "not_watched": {
                "calls": unwatched["calls"],
                "hours": round(unwatched["hours"], 3),
                "top_keepers": unwatched_keepers.most_common(TOP_KEEPERS),
            },
            "schedule_create_in_prior_15_min": {
                key: prior[key] for key in ("any", "with_until_github_run", "refused_missing_due")
            },
        },
    }


def main() -> None:
    since, end = ledger.parse_utc(sys.argv[1]), ledger.parse_utc(sys.argv[2])
    base = pathlib.Path(sys.argv[3] if len(sys.argv) > 3 else "~/me").expanduser()
    window = {"since": sys.argv[1], "end": sys.argv[2], "hours": round((end - since) / 3600, 2)}
    execute_rows = ledger.read_rows(base, since, end, ('"tool":"Execute"',))
    schedule_rows = ledger.read_rows(base, since - WATCH_LOOKBACK_S, end, ('"tool":"masc_schedule_create"',))
    print(json.dumps({"window": window, **measure(execute_rows, schedule_rows)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
