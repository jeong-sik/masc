#!/usr/bin/env python3
"""How much of the Execute time Keepers spend reading pull requests with `gh`, and how much of it is a loop.

A reviewer Keeper that wants the open pull requests that still need a look runs `gh pr list`, then
`gh pr view` and `gh api .../reviews` once for each pull request. Every `gh` call is its own process and
its own request to GitHub, and the turn of the Keeper is held until the last one returns. This script
counts these Execute calls in the tool-call ledger, the hours they held a turn, and how many of them are
such loops.

Reads, and never writes, the ledger files that `measure_before_after.py` reads.

Definitions:

- command text: the `command` of an Execute `input`. When it has none, the `argv` joined by spaces, or
  the script of an `argv` that is `sh`, `bash` or `zsh` followed by `-c` or `-lc`. When the input is not
  a JSON object, the input text itself.
- PR read: an Execute call whose command text holds `gh pr view`, `gh pr list`, `gh pr checks` or
  `gh pr status`, or a `gh api` whose arguments name `/pulls` or `pullRequest` (the REST path or a GraphQL
  query). `gh pr diff` is not counted. The match is on text: a call that only quotes such a command
  counts, and a read of the body or the comments of one pull request counts like a read of its state.
- shape: `fan_out` when the text has a shell loop (`for x in`, `while`, `xargs`) and a list that `gh` made
  for it (`$(gh pr list`, `$(gh api`, the `<(` and backtick forms, or `gh pr list ... | while` / `xargs`). Otherwise `wait`
  when the text has `sleep` and a number, or `--watch`. Otherwise `single`. A call has the first shape
  that fits, so a loop that sleeps is `fan_out`.
- day: the UTC day of the end time (`ts`) of the call.
- hours: `duration_ms` summed, the time the tool held the turn.

Output: `days` holds one row per UTC day with Execute calls, and `total` the same row for the whole
window. A row has the Execute calls and hours, the PR reads and their hours, the share of the Execute
calls and of the Execute hours that PR reads make, the Keepers that made one, and the calls and hours of
each shape. `top_keepers` lists the six Keepers whose PR reads held the most hours: their calls, hours,
the `fan_out` calls and hours, and the median seconds of a `fan_out` call (the element at index `n // 2`
of the sorted seconds, as the p50 of `measure_before_after.py`).

Usage:
    python3 docs/evidence/tool-efficiency-before-after-2026-11/pr_state_reads.py \
        --base-path ~/me --since 2026-11-06T00:00:00 --end 2026-11-09T00:00:00 \
        --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-pr-state-reads-2026-11-06_11-08.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import pathlib
import re
import sys
from collections import Counter, defaultdict
from collections.abc import Iterable, Sequence
from typing import cast

import measure_before_after as ledger

TOP_KEEPERS = 6
SHARE_DIGITS = 4
MEDIAN_DIGITS = 1
MS_PER_SECOND = 1_000.0
FAN_OUT = "fan_out"
WAIT = "wait"
SINGLE = "single"
SHAPES = (FAN_OUT, WAIT, SINGLE)
SHELLS = ("sh", "bash", "zsh")
SHELL_SCRIPT_FLAGS = ("-c", "-lc")
SCRIPT_ARGV_LENGTH = 3

PR_READ = re.compile(
    r"\bgh\s+pr\s+(?:view|list|checks|status)\b"
    r"|\bgh\s+api\b[^|;&]*?(?:/pulls\b|pullRequest)"
)
LOOP = re.compile(r"\b(?:for\s+\w+\s+in|while|xargs)\b")
LISTED_BY_GH = re.compile(
    r"(?:\$\(|<\(|`)\s*gh\s+(?:pr\s+list|api)\b"
    r"|\bgh\s+(?:pr\s+list|api)\b[^\n]*\|\s*(?:while|xargs)\b"
)
WAITS = re.compile(r"\bsleep\s+[0-9]|--watch\b")


@dataclasses.dataclass(frozen=True, slots=True)
class PrRead:
    day: str
    keeper: str
    shape: str
    held_ms: float


@dataclasses.dataclass(frozen=True, slots=True)
class Scan:
    execute_calls: Counter[str]
    execute_ms: dict[str, float]
    reads: list[PrRead]


def command_text(input_text: str) -> str:
    """The command of an Execute input as one text, whether it was given as `command` or as `argv`."""
    try:
        parsed = cast("object", json.loads(input_text))
    except ValueError:
        return input_text
    if not isinstance(parsed, dict):
        return input_text
    fields = cast("dict[str, object]", parsed)
    command = fields.get("command")
    if isinstance(command, str):
        return command
    argv = fields.get("argv")
    if isinstance(argv, list) and argv and all(isinstance(token, str) for token in cast("list[object]", argv)):
        tokens = cast("list[str]", argv)
        if len(tokens) == SCRIPT_ARGV_LENGTH and tokens[0] in SHELLS and tokens[1] in SHELL_SCRIPT_FLAGS:
            return tokens[2]
        return " ".join(tokens)
    return input_text


def shape_of(text: str) -> str:
    if LOOP.search(text) is not None and LISTED_BY_GH.search(text) is not None:
        return FAN_OUT
    if WAITS.search(text) is not None:
        return WAIT
    return SINGLE


def day_of(ts: float) -> str:
    return datetime.datetime.fromtimestamp(ts, ledger.UTC).strftime("%Y-%m-%d")


def scan(calls: Iterable[ledger.Call]) -> Scan:
    """Execute calls per UTC day, and the PR reads among them."""
    execute_calls: Counter[str] = Counter()
    execute_ms: defaultdict[str, float] = defaultdict(float)
    reads: list[PrRead] = []
    for call in calls:
        if call.tool != ledger.EXECUTE:
            continue
        day = day_of(call.ts)
        execute_calls[day] += 1
        execute_ms[day] += call.duration_ms
        text = command_text(call.input_text)
        if PR_READ.search(text) is not None:
            reads.append(PrRead(day, call.keeper, shape_of(text), call.duration_ms))
    return Scan(execute_calls, dict(execute_ms), reads)


def share(part: float, whole: float) -> float | None:
    return round(part / whole, SHARE_DIGITS) if whole > 0 else None


def row_of(day: str, execute_calls: int, execute_ms: float, reads: Sequence[PrRead]) -> dict[str, object]:
    held_ms = sum(read.held_ms for read in reads)
    by_shape: dict[str, object] = {}
    for shape in SHAPES:
        mine = [read for read in reads if read.shape == shape]
        by_shape[shape] = {"calls": len(mine), "hours": ledger.hours(sum(read.held_ms for read in mine))}
    return {
        "day": day,
        "execute_calls": execute_calls,
        "execute_hours": ledger.hours(execute_ms),
        "pr_read_calls": len(reads),
        "pr_read_hours": ledger.hours(held_ms),
        "pr_read_call_share": share(len(reads), execute_calls),
        "pr_read_hour_share": share(held_ms, execute_ms),
        "keepers": len({read.keeper for read in reads}),
        "by_shape": by_shape,
    }


def keeper_row(keeper: str, reads: Sequence[PrRead]) -> dict[str, object]:
    loops = sorted(read.held_ms / MS_PER_SECOND for read in reads if read.shape == FAN_OUT)
    return {
        "keeper": keeper,
        "pr_read_calls": len(reads),
        "pr_read_hours": ledger.hours(sum(read.held_ms for read in reads)),
        "fan_out_calls": len(loops),
        "fan_out_hours": ledger.hours(sum(loops) * MS_PER_SECOND),
        "fan_out_p50_s": round(loops[len(loops) // 2], MEDIAN_DIGITS) if loops else None,
    }


def summarize(found: Scan) -> dict[str, object]:
    days = [
        row_of(day, found.execute_calls[day], found.execute_ms[day], [read for read in found.reads if read.day == day])
        for day in sorted(found.execute_calls)
    ]
    total = row_of("all", sum(found.execute_calls.values()), sum(found.execute_ms.values()), found.reads)
    by_keeper: defaultdict[str, list[PrRead]] = defaultdict(list)
    for read in found.reads:
        by_keeper[read.keeper].append(read)
    ranked = sorted(by_keeper.items(), key=lambda item: (-sum(read.held_ms for read in item[1]), item[0]))
    return {
        "days": days,
        "total": total,
        "top_keepers": [keeper_row(keeper, reads) for keeper, reads in ranked[:TOP_KEEPERS]],
    }


def measure(base: pathlib.Path, since: datetime.datetime, end: datetime.datetime) -> dict[str, object]:
    first = since.timestamp()
    last = end.timestamp()
    skipped = ledger.Skipped()
    paths = ledger.ledger_files(base, since, end)
    found = scan(ledger.read_calls(paths, first, last, skipped))
    return {
        "window": [ledger.stamp(first), ledger.stamp(last)],
        "files": len(paths),
        "skipped": {"bad_lines": skipped.bad_lines},
        **summarize(found),
    }


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", required=True, help="UTC, like 2026-11-06T00:00:00")
    parser.add_argument("--end", required=True, help="UTC, like 2026-11-09T00:00:00")
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    since = ledger.parse_instant(cast("str", args.since))
    end = ledger.parse_instant(cast("str", args.end))
    if end <= since:
        print("--end must come after --since", file=sys.stderr)
        return 2
    if end - since > datetime.timedelta(days=ledger.MAX_DAYS):
        print(f"the span must stay within {ledger.MAX_DAYS} days", file=sys.stderr)
        return 2
    result = measure(cast("pathlib.Path", args.base_path).expanduser(), since, end)
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
