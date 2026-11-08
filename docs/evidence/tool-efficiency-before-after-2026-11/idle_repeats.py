#!/usr/bin/env python3
"""How many Execute calls ran a command again and got the same answer, and what they cost in model requests.

A Keeper that waits for something by running one command again and again spends a model request on
every run. This script counts the runs that gave nothing new in the tool-call ledger, and sets them
against the model requests and input tokens the same Keeper used in the window.

Reads, and never writes, the ledger files that `measure_before_after.py` reads and the turn traces
`<base-path>/.masc/keeper_turn_events/<keeper>/<trace_id>-<turn>-<hash>.jsonl`.

Definitions:

- command: the `input` text of an Execute row. When the ledger cut a long `input` short, the text it
  kept is compared, so two commands that share the kept text count as one command.
- answer: the `output` of the row without `execution_time_ms`. Two answers are the same when their
  JSON objects are equal. An answer that is not a JSON object is compared as text.
- repeat: an Execute call of Keeper K whose command K ran before, where the last run of that command
  ended at most `--gap-s` seconds earlier and gave the same answer. Commands that K ran in between
  do not matter. Calls are taken from [since, end), so the first run of a command in the window is
  never a repeat. A failed call that fails the same way again is a repeat too.
- streak: the runs of one command by one Keeper that follow each other inside the gap with the same
  answer. A streak of 12 is one first run and 11 repeats. A changed answer or a longer gap ends it.
- same turn: a repeat whose previous run belongs to the same turn. A turn is the pair of the row's
  `trace_id` and `keeper_turn_id`, and a row without a `keeper_turn_id` is never in the same turn as
  another. `repeat_same_turn_calls` counts these repeats for every Keeper and for each listed Keeper.
- interval: the seconds from the end of the previous run of the command to the end of the repeat, so
  the run time of the repeat is inside it. `repeat_interval_p50_s` and `repeat_interval_p90_s` are the
  values at position `n // 2` and `n * 9 // 10` of the sorted intervals of a Keeper's repeats, the
  position rule `measure_before_after.py` uses for its p50.
- runs: `top_commands[].runs` counts every Execute call of the Keeper whose command head is that head,
  the first run and the runs that gave a new answer included, and `repeats` counts the repeats only.
- model request: a `usage` event of a turn trace, the event `agent_core_stream_message_delta`, with
  `ts` in [since, end). `repeats_per_model_request` is a ratio and not a share: one request can ask
  for several calls, and a request can end with no call.

`execute.date_calls` counts the Execute calls whose whole command is one `date` call (`command` or
`argv`, no pipe, list, redirection or substitution). Once the format shows seconds a clock reading never
repeats its answer, so these calls are counted apart from the repeats; `date_callers` lists the six
Keepers with the most. `execute.keepers_with_repeats` counts the Keepers with at least one repeat and
`top_keepers` lists the six with the most. `input_token_share_of_all_keepers` divides the Keeper's input
tokens by the input tokens of every Keeper that has a trace in the window. `hourly` splits the Execute
calls and the repeats of all Keepers by the UTC hour of the call's end time (`ts`); a repeat is counted in
the hour of the repeat itself, and an hour without an Execute call is left out.

Usage:
    python3 docs/evidence/tool-efficiency-before-after-2026-11/idle_repeats.py \
        --base-path ~/me --since 2026-11-08T00:00:00 --end 2026-11-08T10:40:00 \
        --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-idle-repeats-2026-11-08_00-10.json
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import hashlib
import json
import pathlib
import re
import sys
from collections import Counter, defaultdict
from collections.abc import Iterable, Sequence
from typing import cast

import measure_before_after as ledger

DEFAULT_GAP_S = 1_800.0
STREAK_MIN = 10
TOP_KEEPERS = 6
TOP_COMMANDS = 3
COMMAND_HEAD_CHARS = 100
SECONDS_PER_HOUR = 3_600.0
BYTES_PER_MIB = 1_048_576
HOURS_DIGITS = 3
MIB_DIGITS = 2
SHARE_DIGITS = 4
RATIO_DIGITS = 3
INTERVAL_DIGITS = 1
TIMING_KEY = "execution_time_ms"
TURN_EVENTS = "keeper_turn_events"
USAGE_EVENT = "agent_core_stream_message_delta"
USAGE_MARKER = b'"usage"'
# A whole command that is one `date` call: no pipe, list, redirection or substitution.
DATE_COMMAND = re.compile(r"^date(?: [^;&|<>`$()\n]*)?$")


@dataclasses.dataclass(frozen=True, slots=True)
class Run:
    """The last run of one command by one Keeper."""

    ts: float
    answer: str
    streak: int
    head: str
    turn: str


@dataclasses.dataclass(frozen=True, slots=True)
class Repeat:
    keeper: str
    head: str
    held_s: float
    result_bytes: int
    ts: float
    same_turn: bool
    interval_s: float


@dataclasses.dataclass(frozen=True, slots=True)
class Scan:
    executes: Counter[str]
    executes_by_hour: Counter[float]
    date_calls: Counter[str]
    runs: dict[str, Counter[str]]
    repeats: list[Repeat]
    streaks: dict[str, list[int]]


@dataclasses.dataclass(frozen=True, slots=True)
class Tokens:
    requests: int
    input_tokens: int
    cache_read_tokens: int
    output_tokens: int

    def plus(self, other: Tokens) -> Tokens:
        return Tokens(
            self.requests + other.requests,
            self.input_tokens + other.input_tokens,
            self.cache_read_tokens + other.cache_read_tokens,
            self.output_tokens + other.output_tokens,
        )


NO_TOKENS = Tokens(0, 0, 0, 0)


def digest(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8"), usedforsecurity=False).hexdigest()


def squash(text: str) -> str:
    return " ".join(text.split())[:COMMAND_HEAD_CHARS]


def command_head(input_text: str) -> str:
    """The `command` of an Execute input squeezed to one line, or the input text when it has none."""
    try:
        parsed = cast("object", json.loads(input_text))
    except ValueError:
        return squash(input_text)
    if isinstance(parsed, dict):
        command = cast("dict[str, object]", parsed).get("command")
        if isinstance(command, str):
            return squash(command)
    return squash(input_text)


def is_date_call(input_text: str) -> bool:
    """Whether the whole command of an Execute input is one `date` call, given as `command` or as `argv`."""
    try:
        parsed = cast("object", json.loads(input_text))
    except ValueError:
        return False
    if not isinstance(parsed, dict):
        return False
    fields = cast("dict[str, object]", parsed)
    command = fields.get("command")
    if isinstance(command, str):
        return DATE_COMMAND.match(command.strip()) is not None
    argv = fields.get("argv")
    if isinstance(argv, list) and argv and all(isinstance(token, str) for token in cast("list[object]", argv)):
        return DATE_COMMAND.match(" ".join(cast("list[str]", argv))) is not None
    return False


def answer_digest(output_text: str) -> str:
    """A digest of an Execute answer that leaves its `execution_time_ms` out."""
    try:
        parsed = cast("object", json.loads(output_text))
    except ValueError:
        return digest(output_text)
    if not isinstance(parsed, dict):
        return digest(output_text)
    kept = {key: value for key, value in cast("dict[str, object]", parsed).items() if key != TIMING_KEY}
    return digest(json.dumps(kept, sort_keys=True, ensure_ascii=False))


def hour_start(ts: float) -> float:
    """The start of the UTC hour that holds `ts`."""
    return ts - ts % SECONDS_PER_HOUR


def scan(calls: Iterable[ledger.Call], gap_s: float) -> Scan:
    """Execute calls per Keeper and per hour, the repeats, and the length of each streak of two runs or more."""
    executes: Counter[str] = Counter()
    executes_by_hour: Counter[float] = Counter()
    date_calls: Counter[str] = Counter()
    runs: defaultdict[str, Counter[str]] = defaultdict(Counter)
    repeats: list[Repeat] = []
    streaks: defaultdict[str, list[int]] = defaultdict(list)
    last: dict[tuple[str, str], Run] = {}
    for call in sorted((c for c in calls if c.tool == ledger.EXECUTE), key=lambda c: c.ts):
        executes[call.keeper] += 1
        executes_by_hour[hour_start(call.ts)] += 1
        if is_date_call(call.input_text):
            date_calls[call.keeper] += 1
        head = command_head(call.input_text)
        runs[call.keeper][head] += 1
        key = (call.keeper, digest(call.input_text))
        answer = answer_digest(call.output_text)
        previous = last.get(key)
        if previous is not None and call.ts - previous.ts <= gap_s and previous.answer == answer:
            same_turn = call.turn != "" and call.turn == previous.turn
            repeats.append(Repeat(call.keeper, previous.head, call.duration_ms / 1000, call.result_bytes, call.ts, same_turn, call.ts - previous.ts))
            last[key] = Run(call.ts, answer, previous.streak + 1, previous.head, call.turn)
            continue
        if previous is not None and previous.streak > 1:
            streaks[call.keeper].append(previous.streak)
        last[key] = Run(call.ts, answer, 1, head, call.turn)
    for (keeper, _), run in last.items():
        if run.streak > 1:
            streaks[keeper].append(run.streak)
    return Scan(executes, executes_by_hour, date_calls, dict(runs), repeats, dict(streaks))


def number_of(value: object) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def count_of(value: object) -> int:
    number = number_of(value)
    return int(number) if number is not None else 0


def parse_usage(line: bytes) -> tuple[float, Tokens] | None:
    """(ts, tokens of one model request) of a usage event, or None for any other line."""
    try:
        row = cast("object", json.loads(line))
    except ValueError:
        return None
    if not isinstance(row, dict):
        return None
    fields = cast("dict[str, object]", row)
    event = fields.get("event")
    stamp = number_of(fields.get("ts"))
    if not isinstance(event, dict) or stamp is None:
        return None
    event_fields = cast("dict[str, object]", event)
    usage = event_fields.get("usage")
    if event_fields.get("type") != USAGE_EVENT or not isinstance(usage, dict):
        return None
    counts = cast("dict[str, object]", usage)
    return stamp, Tokens(
        1,
        count_of(counts.get("input_tokens")),
        count_of(counts.get("cache_read_input_tokens")),
        count_of(counts.get("output_tokens")),
    )


def tokens_of_file(path: pathlib.Path, since: float, until: float) -> Tokens:
    total = NO_TOKENS
    with path.open("rb") as handle:
        for line in handle:
            if USAGE_MARKER not in line:
                continue
            parsed = parse_usage(line)
            if parsed is not None and since <= parsed[0] < until:
                total = total.plus(parsed[1])
    return total


def read_tokens(base: pathlib.Path, since: float, until: float) -> dict[str, Tokens]:
    """The model requests of each Keeper that has a turn trace written at or after `since`."""
    root = base / ".masc" / TURN_EVENTS
    found: dict[str, Tokens] = {}
    if not root.is_dir():
        return found
    for keeper_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        total = NO_TOKENS
        for path in sorted(keeper_dir.glob("*.jsonl")):
            try:
                if path.stat().st_mtime < since:
                    continue
            except OSError:
                continue
            total = total.plus(tokens_of_file(path, since, until))
        if total.requests > 0:
            found[keeper_dir.name] = total
    return found


def hours(seconds: float) -> float:
    return round(seconds / SECONDS_PER_HOUR, HOURS_DIGITS)


def round_or_none(value: float | None) -> float | None:
    return round(value, INTERVAL_DIGITS) if value is not None else None


def share(part: float, whole: float) -> float | None:
    return round(part / whole, SHARE_DIGITS) if whole > 0 else None


def rank(sorted_values: Sequence[float], numerator: int, denominator: int) -> float | None:
    """The value at position `n * numerator // denominator` of sorted values (numerator below denominator), None when there are none."""
    return sorted_values[len(sorted_values) * numerator // denominator] if sorted_values else None


def keeper_summary(keeper: str, found: Scan, tokens: dict[str, Tokens], all_input: int) -> dict[str, object]:
    mine = [r for r in found.repeats if r.keeper == keeper]
    interval = sorted(r.interval_s for r in mine)
    runs = found.runs.get(keeper, Counter())
    streaks = found.streaks.get(keeper, [])
    used = tokens.get(keeper, NO_TOKENS)
    return {
        "keeper": keeper,
        "execute_calls": found.executes[keeper],
        "repeat_calls": len(mine),
        "repeat_share": share(len(mine), found.executes[keeper]),
        "repeat_same_turn_calls": sum(1 for r in mine if r.same_turn),
        "repeat_interval_p50_s": round_or_none(rank(interval, 1, 2)),
        "repeat_interval_p90_s": round_or_none(rank(interval, 9, 10)),
        "repeat_held_hours": hours(sum(r.held_s for r in mine)),
        "longest_streak": max(streaks, default=0),
        "streaks_of_10_or_more": sum(1 for length in streaks if length >= STREAK_MIN),
        "model_requests": used.requests,
        "input_tokens": used.input_tokens,
        "input_token_share_of_all_keepers": share(used.input_tokens, all_input),
        "repeats_per_model_request": round(len(mine) / used.requests, RATIO_DIGITS) if used.requests > 0 else None,
        "top_commands": [
            {"command": head, "repeats": count, "runs": runs[head]}
            for head, count in Counter(r.head for r in mine).most_common(TOP_COMMANDS)
        ],
    }


def hourly(found: Scan) -> list[dict[str, object]]:
    repeats_by_hour = Counter(hour_start(r.ts) for r in found.repeats)
    return [
        {
            "hour": ledger.stamp(start),
            "execute_calls": calls,
            "repeat_calls": repeats_by_hour[start],
            "repeat_share": share(repeats_by_hour[start], calls),
        }
        for start, calls in sorted(found.executes_by_hour.items())
    ]


def summarize(found: Scan, tokens: dict[str, Tokens]) -> dict[str, object]:
    total_input = sum(t.input_tokens for t in tokens.values())
    by_repeats = Counter(r.keeper for r in found.repeats)
    return {
        "execute": {
            "calls": sum(found.executes.values()),
            "repeat_calls": len(found.repeats),
            "repeat_share": share(len(found.repeats), sum(found.executes.values())),
            "repeat_same_turn_calls": sum(1 for r in found.repeats if r.same_turn),
            "repeat_held_hours": hours(sum(r.held_s for r in found.repeats)),
            "repeat_result_mib": round(sum(r.result_bytes for r in found.repeats) / BYTES_PER_MIB, MIB_DIGITS),
            "date_calls": sum(found.date_calls.values()),
            "date_call_share": share(sum(found.date_calls.values()), sum(found.executes.values())),
            "keepers_with_repeats": len(by_repeats),
        },
        "model_requests": {
            "keepers": len(tokens),
            "requests": sum(t.requests for t in tokens.values()),
            "input_tokens": total_input,
            "cache_read_tokens": sum(t.cache_read_tokens for t in tokens.values()),
            "output_tokens": sum(t.output_tokens for t in tokens.values()),
        },
        "top_keepers": [keeper_summary(keeper, found, tokens, total_input) for keeper, _ in by_repeats.most_common(TOP_KEEPERS)],
        "date_callers": [
            {
                "keeper": keeper,
                "date_calls": count,
                "execute_calls": found.executes[keeper],
                "date_call_share": share(count, found.executes[keeper]),
            }
            for keeper, count in found.date_calls.most_common(TOP_KEEPERS)
        ],
        "hourly": hourly(found),
    }


def measure(base: pathlib.Path, since: datetime.datetime, end: datetime.datetime, gap_s: float) -> dict[str, object]:
    first = since.timestamp()
    last = end.timestamp()
    skipped = ledger.Skipped()
    paths = ledger.ledger_files(base, since, end)
    found = scan(ledger.read_calls(paths, first, last, skipped), gap_s)
    return {
        "window": [ledger.stamp(first), ledger.stamp(last)],
        "gap_seconds": gap_s,
        "files": len(paths),
        "skipped": {"bad_lines": skipped.bad_lines},
        **summarize(found, read_tokens(base, first, last)),
    }


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", required=True, help="UTC, like 2026-11-08T00:00:00")
    parser.add_argument("--end", required=True, help="UTC, like 2026-11-08T10:40:00")
    parser.add_argument("--gap-s", type=float, default=DEFAULT_GAP_S)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    since = ledger.parse_instant(cast("str", args.since))
    end = ledger.parse_instant(cast("str", args.end))
    gap_s = cast("float", args.gap_s)
    if end <= since or gap_s <= 0:
        print("--end must come after --since and --gap-s must be positive", file=sys.stderr)
        return 2
    if end - since > datetime.timedelta(days=ledger.MAX_DAYS):
        print(f"the span must stay within {ledger.MAX_DAYS} days", file=sys.stderr)
        return 2
    result = measure(cast("pathlib.Path", args.base_path).expanduser(), since, end, gap_s)
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
