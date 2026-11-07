#!/usr/bin/env python3
"""Measure how long Execute calls hold a Keeper's turn, and how often a Delegate completion lands inside a long one.

Reads, and never writes, `<base-path>/.masc/tool_calls/<YYYY-MM>/<DD>.jsonl` and `<DD>.<NNN>.jsonl` (one JSON object
per line) and `<base-path>/.masc/keepers/<keeper>/chat-operations.sqlite3`. A ledger line counts when `record_kind`
is `tool_call`, `tool` is `Execute` and `ts` (UTC seconds, the end of the call) lies in [--since, --until).

Definitions:

- held time: `duration_ms` of the call, in seconds.
- sleep poll: a call of one of the --poll-keeper Keepers whose `input.command` contains `sleep <digits>` and whose
  held time is at least --long-sec.
- timeout exit: a call whose `output`, cut to its first 600 characters with spaces removed, contains
  `"status":{"kind":"exit","code":124}`. Any held time counts.
- delegation: a row of `operations` in the target Keeper's chat-operations database with `state` of `succeeded` or
  `failed`, `completed_at` in [--since, --until), `source_json.channel` equal to `agent`, and a `sender_keeper`
  that is not the target.
- inside: the delegation's `completed_at` lies in [ts - held time, ts] of an Execute call of the sender whose held
  time is at least --long-sec. The ledger is read from one day before --since, so a call that began earlier counts.

Usage:
    python3 docs/evidence/execute-background-2026-11/measure_execute_held_time.py \
        --base-path ~/me --since 2026-11-05T00:00:00 --until 2026-11-08T00:00:00 --json-out result.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import pathlib
import re
import sqlite3
import sys
from collections.abc import Iterator, Sequence
from typing import cast

LEDGER_FILE = re.compile(r"^(?P<day>[0-9]{2})(?:\.[0-9]{3})?\.jsonl$")
SLEEP_COMMAND = re.compile(r"\bsleep\s+[0-9]")
TIMEOUT_STATUS = '"status":{"kind":"exit","code":124}'
OUTPUT_HEAD_CHARS = 600
DEFAULT_POLL_KEEPERS = ("github-pr-checker", "pr-updater")
SECONDS_PER_HOUR = 3600.0


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    keeper: str
    ended_at: float
    held_sec: float
    command: str
    output_head: str


@dataclasses.dataclass(frozen=True, slots=True)
class Tally:
    calls: int
    hours: float


@dataclasses.dataclass(frozen=True, slots=True)
class Overlap:
    delegations: int
    inside: int
    remaining_sec: tuple[float, ...]


def as_object(value: object) -> dict[str, object] | None:
    return cast("dict[str, object]", value) if isinstance(value, dict) else None


def parse_utc(text: str) -> float:
    parsed = datetime.datetime.fromisoformat(text)
    return parsed.replace(tzinfo=datetime.timezone.utc).timestamp()


def ledger_files(base: pathlib.Path, first: datetime.date, last: datetime.date) -> Iterator[pathlib.Path]:
    day = first
    while day <= last:
        directory = base / ".masc" / "tool_calls" / f"{day:%Y-%m}"
        if directory.is_dir():
            for path in sorted(directory.iterdir()):
                match = LEDGER_FILE.match(path.name)
                if match and int(match.group("day")) == day.day:
                    yield path
        day += datetime.timedelta(days=1)


def execute_calls(base: pathlib.Path, since: float, until: float, lead_sec: float) -> Iterator[Call]:
    first = datetime.datetime.fromtimestamp(since - lead_sec, datetime.timezone.utc).date()
    last = datetime.datetime.fromtimestamp(until, datetime.timezone.utc).date()
    for path in ledger_files(base, first, last):
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                if "Execute" not in line:
                    continue
                row = as_object(json.loads(line))
                if row is None or row.get("record_kind") != "tool_call" or row.get("tool") != "Execute":
                    continue
                ended_at, duration_ms, keeper = row.get("ts"), row.get("duration_ms"), row.get("keeper")
                if not isinstance(ended_at, (int, float)) or not isinstance(keeper, str):
                    continue
                if not isinstance(duration_ms, (int, float)):
                    continue
                arguments = as_object(row.get("input")) or {}
                command = arguments.get("command")
                output = row.get("output")
                head = output if isinstance(output, str) else json.dumps(output)
                yield Call(
                    keeper=keeper,
                    ended_at=float(ended_at),
                    held_sec=float(duration_ms) / 1000.0,
                    command=command if isinstance(command, str) else "",
                    output_head=head[:OUTPUT_HEAD_CHARS].replace(" ", ""),
                )


def tally(calls: Sequence[Call]) -> Tally:
    return Tally(calls=len(calls), hours=round(sum(call.held_sec for call in calls) / SECONDS_PER_HOUR, 2))


def delegations(base: pathlib.Path, since: float, until: float) -> list[tuple[str, float]]:
    found: list[tuple[str, float]] = []
    for database in sorted((base / ".masc" / "keepers").glob("*/chat-operations.sqlite3")):
        target = database.parent.name
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        try:
            rows = connection.execute(
                "select source_json, completed_at from operations "
                "where completed_at >= ? and completed_at < ? and state in ('succeeded', 'failed')",
                (since, until),
            ).fetchall()
        except sqlite3.Error:
            rows = []
        finally:
            connection.close()
        for source_json, completed_at in rows:
            source = as_object(json.loads(str(source_json)))
            sender = source.get("sender_keeper") if source else None
            if source and source.get("channel") == "agent" and isinstance(sender, str) and sender != target:
                found.append((sender, float(completed_at)))
    return found


def overlap(ended: Sequence[tuple[str, float]], long_calls: Sequence[Call]) -> Overlap:
    remaining: list[float] = []
    for sender, completed_at in ended:
        for call in long_calls:
            if call.keeper == sender and call.ended_at - call.held_sec <= completed_at <= call.ended_at:
                remaining.append(round(call.ended_at - completed_at, 1))
                break
    return Overlap(delegations=len(ended), inside=len(remaining), remaining_sec=tuple(sorted(remaining)))


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", required=True, help="UTC, ISO 8601")
    parser.add_argument("--until", required=True, help="UTC, ISO 8601")
    parser.add_argument("--long-sec", type=float, default=60.0)
    parser.add_argument("--poll-keeper", action="append", default=list(DEFAULT_POLL_KEEPERS))
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    base = args.base_path.expanduser()
    since, until = parse_utc(args.since), parse_utc(args.until)
    every = list(execute_calls(base, since, until, lead_sec=86400.0))
    window = [call for call in every if since <= call.ended_at < until]
    long_calls = [call for call in every if call.held_sec >= args.long_sec]
    polls = [
        call
        for call in window
        if call.keeper in args.poll_keeper and call.held_sec >= args.long_sec and SLEEP_COMMAND.search(call.command)
    ]
    result = {
        "window": {"since": args.since, "until": args.until, "long_sec": args.long_sec},
        "execute_all": dataclasses.asdict(tally(window)),
        "sleep_polls": {"keepers": sorted(set(args.poll_keeper)), **dataclasses.asdict(tally(polls))},
        "timeout_exit": dataclasses.asdict(tally([call for call in window if TIMEOUT_STATUS in call.output_head])),
        "delegation_overlap": dataclasses.asdict(overlap(delegations(base, since, until), long_calls)),
    }
    text = json.dumps(result, indent=2, sort_keys=True)
    if args.json_out:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    sys.stdout.write(text + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
