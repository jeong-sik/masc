#!/usr/bin/env python3
"""Measure the tool calls a Keeper run repeats.

A run is one raw trace file of a Keeper (`<base>/.masc/keepers/<keeper>/raw-traces/turn-*.jsonl`).
A call is a `tool_execution_started` record and the `tool_execution_finished`
record with the same `tool_use_id`. A call repeats when its tool, its input and
its result equal those of the call that finished right before it in the same
run. A streak is a maximal stretch of calls that each repeat the one before, so
a streak of N calls holds N - 1 repeats.

A repeat told the model nothing the previous call had not. It is not
necessarily a mistake: a model may poll a state that happens to stay the same.
The report only counts them, per tool, per streak length and per run.

Reported:

- `calls`: runs, runs with at least one finished call, finished calls, repeats,
  their share, and the repeats whose result was an error.
- `by_tool`: per tool with a repeat, its calls and repeats.
- `streaks`: how many, their length (p50 / p90 / p99 / max), the repeats by
  streak length, and the wall time from the first start to the last finish of
  every streak, summed.
- `by_profile`: per runtime profile with a repeat, its calls and repeats.
- `runs_with_the_most_repeats`: the eight runs with the most repeats.

Reads the raw traces and never writes to them. A line that is not a JSON object
is counted under `unreadable_lines`. A file that is listed and gone before it is
opened (a Keeper rotates its raw traces while this runs) is counted under
`unreadable_files`. A finished call whose start record is missing never
repeats, because its input is unknown. Measure a window whose last UTC day is
over to get a repeatable result.

Usage:
    python3 -I -B docs/evidence/repeated-calls-2026-11/measure_repeated_calls.py \\
        --base-path ~/me --json-out result.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
from collections import Counter
from dataclasses import dataclass
from datetime import UTC, date, datetime
from typing import cast

JsonObject = dict[str, object]

RECORD_HOOK = "hook_invoked"
RECORD_TOOL_STARTED = "tool_execution_started"
RECORD_TOOL_FINISHED = "tool_execution_finished"
RECORD_RUN_STARTED = "run_started"
RECORD_RUN_FINISHED = "run_finished"
BEFORE_TURN_PARAMS = "before_turn_params"
# Streak lengths are reported in these bands (lower bound, upper bound; the last band is open).
STREAK_BANDS: tuple[tuple[int, int | None], ...] = ((2, 9), (10, 99), (100, None))
TOP_RUNS = 8
ERROR_KIND_CHARS = 40
DIGEST_CHARS = 16
SECONDS_PER_HOUR = 3600.0
P50 = 0.5
P90 = 0.9
P99 = 0.99


@dataclass(frozen=True, slots=True)
class Call:
    tool: str
    input_digest: str | None
    result_digest: str | None
    error: bool
    started: float | None
    finished: float | None

    def repeats(self, previous: Call) -> bool:
        return (
            self.tool == previous.tool
            and self.input_digest is not None
            and self.input_digest == previous.input_digest
            and self.result_digest is not None
            and self.result_digest == previous.result_digest
        )


@dataclass(frozen=True, slots=True)
class Streak:
    tool: str
    length: int
    seconds: float | None


@dataclass(frozen=True, slots=True)
class Run:
    keeper: str
    profile: str
    start: float
    end: float
    rounds: int
    calls: tuple[Call, ...]
    ended_by: str | None


@dataclass(slots=True)
class Unreadable:
    lines: int = 0
    files: int = 0


def as_object(value: object) -> JsonObject | None:
    return cast("JsonObject", value) if isinstance(value, dict) else None


def as_float(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        return float(value)
    return None


def as_text(value: object) -> str | None:
    return value if isinstance(value, str) else None


def digest_of(row: JsonObject, key: str) -> str | None:
    """A record without the key says nothing, so it has no digest and equals nothing."""
    if key not in row:
        return None
    text = json.dumps(row[key], sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:DIGEST_CHARS]


def profile_of(agent_name: str | None) -> str:
    """`agent_core-glm-coding.glm-5.3-flash` names the profile after the first dot."""
    if agent_name is None:
        return "unrecorded"
    return agent_name.split(".", 1)[1] if "." in agent_name else agent_name


def read_run(path: pathlib.Path, keeper: str, unreadable: Unreadable) -> Run | None:
    started: dict[str, tuple[str, str | None, float | None]] = {}
    calls: list[Call] = []
    rounds = 0
    first_ts: float | None = None
    last_ts: float | None = None
    agent: str | None = None
    error: str | None = None
    with path.open("rb") as handle:
        for line in handle:
            try:
                row = as_object(json.loads(line))
            except ValueError:
                row = None
            if row is None:
                unreadable.lines += 1
                continue
            ts = as_float(row.get("ts"))
            if ts is not None:
                first_ts = ts if first_ts is None else first_ts
                last_ts = ts
            kind = row.get("record_type")
            if kind == RECORD_HOOK and row.get("hook_name") == BEFORE_TURN_PARAMS:
                rounds += 1
            elif kind == RECORD_RUN_STARTED:
                agent = as_text(row.get("agent_name"))
            elif kind == RECORD_RUN_FINISHED:
                error = as_text(row.get("error"))
            elif kind == RECORD_TOOL_STARTED:
                use_id = as_text(row.get("tool_use_id"))
                if use_id is not None:
                    started[use_id] = (as_text(row.get("tool_name")) or "?", digest_of(row, "tool_input"), ts)
            elif kind == RECORD_TOOL_FINISHED:
                use_id = as_text(row.get("tool_use_id"))
                begin = started.pop(use_id, None) if use_id is not None else None
                calls.append(
                    Call(
                        tool=begin[0] if begin else (as_text(row.get("tool_name")) or "?"),
                        input_digest=begin[1] if begin else None,
                        result_digest=digest_of(row, "tool_result"),
                        error=row.get("tool_error") is True,
                        started=begin[2] if begin else None,
                        finished=ts,
                    )
                )
    if first_ts is None or last_ts is None:
        return None
    return Run(
        keeper=keeper,
        profile=profile_of(agent),
        start=first_ts,
        end=last_ts,
        rounds=rounds,
        calls=tuple(calls),
        ended_by=error[:ERROR_KIND_CHARS] if error else None,
    )


def read_runs(base: pathlib.Path, unreadable: Unreadable) -> list[Run]:
    runs: list[Run] = []
    for path in sorted((base / ".masc" / "keepers").glob("*/raw-traces/turn-*.jsonl")):
        try:
            run = read_run(path, path.parent.parent.name, unreadable)
        except FileNotFoundError:
            # A Keeper rotates its raw traces while this script lists them.
            unreadable.files += 1
            continue
        if run is not None:
            runs.append(run)
    return runs


def streaks_of(calls: tuple[Call, ...]) -> list[Streak]:
    found: list[Streak] = []
    first = 0
    for index in range(1, len(calls) + 1):
        if index < len(calls) and calls[index].repeats(calls[index - 1]):
            continue
        if index - first >= 2:
            head, tail = calls[first], calls[index - 1]
            seconds = tail.finished - head.started if head.started is not None and tail.finished is not None else None
            found.append(Streak(tool=head.tool, length=index - first, seconds=seconds))
        first = index
    return found


def percentile(sorted_values: list[float], share: float) -> float:
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * share))]


def day_of(ts: float) -> str:
    return datetime.fromtimestamp(ts, UTC).strftime("%Y-%m-%d")


def in_window(ts: float, first_day: date | None, last_day: date | None) -> bool:
    day = datetime.fromtimestamp(ts, UTC).date()
    return (first_day is None or day >= first_day) and (last_day is None or day <= last_day)


def band_label(low: int, high: int | None) -> str:
    return f"{low}+" if high is None else f"{low}-{high}"


def share(part: int, whole: int) -> float:
    return round(part / whole, 4) if whole else 0.0


def counted_rows(label: str, calls: Counter[str], repeats: Counter[str]) -> list[JsonObject]:
    ordered = sorted(repeats.items(), key=lambda item: (-item[1], item[0]))
    return [
        {label: name, "calls": calls[name], "repeats": count, "share_of_calls": share(count, calls[name])}
        for name, count in ordered
    ]


def streak_stats(streaks: list[Streak]) -> JsonObject:
    if not streaks:
        return {"count": 0}
    lengths = sorted(float(streak.length) for streak in streaks)
    bands: JsonObject = {}
    for low, high in STREAK_BANDS:
        inside = [s for s in streaks if s.length >= low and (high is None or s.length <= high)]
        bands[band_label(low, high)] = {"streaks": len(inside), "repeats": sum(s.length - 1 for s in inside)}
    return {
        "count": len(streaks),
        "length": {"p50": percentile(lengths, P50), "p90": percentile(lengths, P90), "p99": percentile(lengths, P99), "max": lengths[-1]},
        "by_length": bands,
        "wall_hours": round(sum(s.seconds or 0.0 for s in streaks) / SECONDS_PER_HOUR, 2),
    }


def run_row(run: Run, streaks: list[Streak]) -> JsonObject:
    repeats: Counter[str] = Counter()
    for streak in streaks:
        repeats[streak.tool] += streak.length - 1
    top_tool = sorted(repeats.items(), key=lambda item: (-item[1], item[0]))[0][0]
    return {
        "keeper": run.keeper,
        "profile": run.profile,
        "day": day_of(run.start),
        "rounds": run.rounds,
        "hours": round((run.end - run.start) / SECONDS_PER_HOUR, 2),
        "calls": len(run.calls),
        "repeats": sum(repeats.values()),
        "top_repeated_tool": top_tool,
        "ended_by": run.ended_by,
    }


def measure(base: pathlib.Path, first_day: date | None, last_day: date | None) -> JsonObject:
    unreadable = Unreadable()
    runs = [run for run in read_runs(base, unreadable) if in_window(run.start, first_day, last_day)]
    calls_by_tool: Counter[str] = Counter()
    repeats_by_tool: Counter[str] = Counter()
    calls_by_profile: Counter[str] = Counter()
    repeats_by_profile: Counter[str] = Counter()
    all_streaks: list[Streak] = []
    rows_by_run: list[tuple[int, JsonObject]] = []
    repeated_errors = 0
    for run in runs:
        for call in run.calls:
            calls_by_tool[call.tool] += 1
            calls_by_profile[run.profile] += 1
        streaks = streaks_of(run.calls)
        all_streaks.extend(streaks)
        for streak in streaks:
            repeats_by_tool[streak.tool] += streak.length - 1
            repeats_by_profile[run.profile] += streak.length - 1
        repeated_errors += sum(1 for index, call in enumerate(run.calls) if index > 0 and call.error and call.repeats(run.calls[index - 1]))
        if streaks:
            rows_by_run.append((sum(s.length - 1 for s in streaks), run_row(run, streaks)))
    total_calls = sum(calls_by_tool.values())
    total_repeats = sum(repeats_by_tool.values())
    rows_by_run.sort(key=lambda item: (-item[0], str(item[1]["keeper"]), str(item[1]["day"])))
    return {
        "window": {
            "first_run_utc": day_of(min(run.start for run in runs)) if runs else None,
            "last_run_utc": day_of(max(run.start for run in runs)) if runs else None,
        },
        "read_at_utc": datetime.now(UTC).strftime("%Y-%m-%dT%H:%MZ"),
        "unreadable_lines": unreadable.lines,
        "unreadable_files": unreadable.files,
        "calls": {
            "runs": len(runs),
            "runs_with_calls": sum(1 for run in runs if run.calls),
            "rounds": sum(run.rounds for run in runs),
            "calls": total_calls,
            "repeats": total_repeats,
            "share_of_calls": share(total_repeats, total_calls),
            "repeats_that_were_errors": repeated_errors,
        },
        "by_tool": counted_rows("tool", calls_by_tool, repeats_by_tool),
        "streaks": streak_stats(all_streaks),
        "by_profile": counted_rows("profile", calls_by_profile, repeats_by_profile),
        "runs_with_the_most_repeats": [row for _, row in rows_by_run[:TOP_RUNS]],
    }


def parse_day(text: str) -> date:
    return datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=UTC).date()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--from-date", help="first UTC day of a run's start, YYYY-MM-DD")
    parser.add_argument("--to-date", help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args()
    first_day = parse_day(args.from_date) if args.from_date else None
    last_day = parse_day(args.to_date) if args.to_date else None
    if first_day and last_day and first_day > last_day:
        parser.error("--from-date is after --to-date")
    text = json.dumps(measure(args.base_path.expanduser(), first_day, last_day), indent=2, ensure_ascii=False)
    if args.json_out:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
