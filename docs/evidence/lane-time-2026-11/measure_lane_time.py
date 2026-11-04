#!/usr/bin/env python3
"""Measure where Keeper turn time goes and what chat operations wait for.

Reads three stores under `<base-path>/.masc`, never writes to them:

- `tool_calls/YYYY-MM/DD[.NNN].jsonl`: the tool-call ledger (`record_kind` is
  `tool_call`). `ts` is the time the call ended; `duration_ms` is its length.
- `keeper_turn_events/<keeper>/*.jsonl`: one trace file per turn run. The first
  line is the run's first event, the last line its last event.
- `keepers/<keeper>/chat-operations.sqlite3`: delegated and chat operations,
  opened read-only. One operation per Keeper runs at a time.
- `agent-core-events/YYYY-MM/DD.jsonl`: MASC bus events. Only the
  `provider_admission:waited` ones are read: a model request that found every
  permit of its provider account held and queued.

Definitions:

- run interval: [first event ts, last event ts] of one trace file. Turn time of
  a Keeper is the union of its run intervals, so overlapping runs count once.
- tool time: the sum of `duration_ms` over all calls.
- between-calls time: inside one turn (`trace_id`, `keeper_turn_id`), calls sorted
  by start (`ts` minus duration). The gap before every call after the first is
  its start minus the previous call's end. Overlapping calls count as 0.
  The gap holds model inference and provider queueing together.
- reread: a call whose (keeper, tool, `input_fingerprint`) was seen at most one
  hour earlier with the same `output_fingerprint`. Same rule as
  scripts/measure-tool-efficiency.py, except the one-hour memory carries over
  midnight here.
- long Execute: an Execute call of 60 seconds or more. Polling when its command
  has `sleep`, a `for ... in`, `while` or `until`.
- queue wait: `started_at` minus `created_at` of an operation. An operation is
  a delegate when its source has a `sender_keeper`.
- admission wait: `waited_ms` of a `provider_admission:waited` event. A request
  granted a permit at once is not reported, so the events are the requests that
  queued.

Nothing here reads message text. Command text is read only for the polling test.

Usage:
    docs/evidence/lane-time-2026-11/measure_lane_time.py --base-path ~/me \
        --from-date 2026-11-01 --to-date 2026-11-04 --until 2026-11-04T19:10:00Z
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sqlite3
import statistics
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))

import masc_base_path  # noqa: E402
from tool_call_log_paths import tool_call_log_paths  # noqa: E402

TOOL_CALL_RECORD_KIND = "tool_call"
EXECUTE_TOOL = "Execute"
LONG_EXECUTE_SEC = 60.0
REREAD_WINDOW_SEC = 3600.0
TRACE_TAIL_BYTES = 65536
SECONDS_PER_HOUR = 3600.0
SECONDS_PER_MINUTE = 60.0
ADMISSION_MARKER = b"provider_admission:waited"
ADMISSION_WAIT_HOURS_HIGH = 5.0
POLL_COMMAND = re.compile(r"\bsleep\b|\bfor\s+\w+\s+in\b|\bwhile\b|\buntil\b")

Interval = tuple[float, float]


@dataclass(frozen=True, slots=True)
class Call:
    keeper: str
    turn: str
    tool: str
    start: float
    end: float
    reread: bool
    polling: bool


@dataclass(frozen=True, slots=True)
class Operation:
    keeper: str
    origin: str
    state: str
    created_at: float
    started_at: float | None
    completed_at: float | None
    failure_kind: str | None


@dataclass(frozen=True, slots=True)
class AdmissionWait:
    ts: float
    provider: str
    model: str
    admission_class: str
    waited_s: float


def text_of(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def number_of(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def command_text(value: object) -> str:
    if not isinstance(value, dict):
        return ""
    for key in ("command", "cmd"):
        found = value.get(key)
        if isinstance(found, str) and found.strip():
            return found
    argv = value.get("argv")
    if isinstance(argv, list) and all(isinstance(part, str) for part in argv):
        return " ".join(argv)
    return ""


def ledger_files(base: pathlib.Path, day: date) -> list[pathlib.Path]:
    live = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
    return tool_call_log_paths(base, live)


def read_calls(base: pathlib.Path, first: date, last: date, until: float) -> list[Call]:
    calls: list[Call] = []
    last_seen: dict[tuple[str, str, str], tuple[float, str]] = {}
    day = first
    while day <= last:
        for path in ledger_files(base, day):
            with path.open("rb") as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(row, dict) or row.get("record_kind") != TOOL_CALL_RECORD_KIND:
                        continue
                    end = number_of(row.get("ts"))
                    if end is None or end > until:
                        continue
                    duration = (number_of(row.get("duration_ms")) or 0.0) / 1000.0
                    keeper = text_of(row.get("keeper")) or "?"
                    tool = text_of(row.get("tool")) or "?"
                    turn = f"{keeper}/{text_of(row.get('trace_id')) or '?'}#{row.get('keeper_turn_id')}"
                    reread = False
                    input_fp = text_of(row.get("input_fingerprint"))
                    output_fp = text_of(row.get("output_fingerprint"))
                    if input_fp is not None and output_fp is not None:
                        key = (keeper, tool, input_fp)
                        previous = last_seen.get(key)
                        reread = previous is not None and previous[1] == output_fp and end - previous[0] <= REREAD_WINDOW_SEC
                        last_seen[key] = (end, output_fp)
                    polling = tool == EXECUTE_TOOL and POLL_COMMAND.search(command_text(row.get("input"))) is not None
                    calls.append(Call(keeper, turn, tool, end - duration, end, reread, polling))
        day += timedelta(days=1)
    return calls


def union_seconds(intervals: list[Interval]) -> float:
    total = 0.0
    current: Interval | None = None
    for start, end in sorted(intervals):
        if current is None or start > current[1]:
            if current is not None:
                total += current[1] - current[0]
            current = (start, end)
        else:
            current = (current[0], max(current[1], end))
    if current is not None:
        total += current[1] - current[0]
    return total


def overlap_seconds(start: float, end: float, intervals: list[Interval]) -> float:
    """Time of [start, end] covered by the union of `intervals`."""
    clipped = [(max(a, start), min(b, end)) for a, b in intervals if b > start and a < end]
    return union_seconds(clipped)


def first_event_ts(path: pathlib.Path) -> float | None:
    with path.open("rb") as handle:
        try:
            return number_of(json.loads(handle.readline()).get("ts"))
        except (ValueError, AttributeError):
            return None


def last_event_ts(path: pathlib.Path) -> float | None:
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        handle.seek(max(0, handle.tell() - TRACE_TAIL_BYTES))
        for line in reversed(handle.read().splitlines()):
            try:
                ts = number_of(json.loads(line).get("ts"))
            except (ValueError, AttributeError):
                continue
            if ts is not None:
                return ts
    return None


def read_runs(base: pathlib.Path, since: float, until: float) -> dict[str, list[Interval]]:
    runs: dict[str, list[Interval]] = defaultdict(list)
    root = base / ".masc" / "keeper_turn_events"
    if not root.is_dir():
        return runs
    for keeper_dir in sorted(root.iterdir()):
        if not keeper_dir.is_dir():
            continue
        for path in keeper_dir.glob("*.jsonl"):
            try:
                if path.stat().st_mtime < since:
                    continue
            except OSError:
                continue
            start, end = first_event_ts(path), last_event_ts(path)
            if start is None or end is None or end < since or start > until:
                continue
            runs[keeper_dir.name].append((max(start, since), min(end, until)))
    return runs


def read_operations(base: pathlib.Path, since: float, until: float) -> list[Operation]:
    operations: list[Operation] = []
    for db in sorted((base / ".masc" / "keepers").glob("*/chat-operations.sqlite3")):
        try:
            connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            rows = connection.execute(
                "select state, created_at, started_at, completed_at, failure_kind, source_json from operations"
            ).fetchall()
            connection.close()
        except sqlite3.Error:
            continue
        for state, created, started, completed, failure_kind, source_json in rows:
            if created is None or created < since or created > until:
                continue
            try:
                source = json.loads(source_json)
            except (TypeError, ValueError):
                source = {}
            source = source if isinstance(source, dict) else {}
            origin = "delegate" if source.get("sender_keeper") else f"channel:{source.get('channel')}"
            operations.append(Operation(db.parent.name, origin, str(state), float(created), started, completed, failure_kind))
    return operations


def read_admission_waits(base: pathlib.Path, since: float, until: float) -> list[AdmissionWait]:
    waits: list[AdmissionWait] = []
    day = datetime.fromtimestamp(since, timezone.utc).date()
    last = datetime.fromtimestamp(until, timezone.utc).date()
    while day <= last:
        path = base / ".masc" / "agent-core-events" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
        if path.is_file():
            with path.open("rb") as handle:
                for line in handle:
                    if ADMISSION_MARKER not in line:
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(event, dict):
                        continue
                    ts = number_of(event.get("ts_unix"))
                    payload = event.get("payload")
                    waited_ms = number_of(payload.get("waited_ms")) if isinstance(payload, dict) else None
                    if ts is None or waited_ms is None or ts < since or ts > until or not isinstance(payload, dict):
                        continue
                    waits.append(
                        AdmissionWait(
                            ts,
                            str(payload.get("provider_id")),
                            str(payload.get("model")),
                            str(payload.get("admission_class")),
                            waited_ms / 1000.0,
                        )
                    )
        day += timedelta(days=1)
    return waits


def quantiles(values: list[float]) -> dict[str, float | int]:
    if not values:
        return {"n": 0}
    ordered = sorted(values)

    def at(fraction: float) -> float:
        return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]

    return {
        "n": len(ordered),
        "p50_s": round(at(0.5), 1),
        "p90_s": round(at(0.9), 1),
        "mean_s": round(statistics.fmean(ordered), 1),
        "sum_s": round(sum(ordered), 1),
    }


def summarize_calls(calls: list[Call], busy_by_keeper: dict[str, float]) -> dict[str, object]:
    by_turn: dict[str, list[Call]] = defaultdict(list)
    for call in calls:
        by_turn[call.turn].append(call)
    gaps: list[float] = []
    reread_gaps: list[float] = []
    overlapping = 0
    for turn_calls in by_turn.values():
        turn_calls.sort(key=lambda call: (call.start, call.end))
        for previous, current in zip(turn_calls, turn_calls[1:]):
            gap = current.start - previous.end
            if gap < 0:
                overlapping += 1
                gap = 0.0
            gaps.append(gap)
            if current.reread:
                reread_gaps.append(gap + (current.end - current.start))
    tool_s = sum(call.end - call.start for call in calls)
    execute_s = sum(call.end - call.start for call in calls if call.tool == EXECUTE_TOOL)
    busy_s = sum(busy_by_keeper.values())
    long_execute = [call for call in calls if call.tool == EXECUTE_TOOL and call.end - call.start >= LONG_EXECUTE_SEC]
    polling = [call for call in long_execute if call.polling]
    polling_s: dict[str, float] = defaultdict(float)
    for call in polling:
        polling_s[call.keeper] += call.end - call.start
    return {
        "turns": len(by_turn),
        "calls": len(calls),
        "turn_time_s": round(busy_s, 1),
        "tool_time_s": round(tool_s, 1),
        "execute_time_s": round(execute_s, 1),
        "between_calls": {**quantiles(gaps), "overlapping_pairs": overlapping},
        "other_turn_time_s": round(busy_s - tool_s - sum(gaps), 1),
        "rereads_after_first_call": {"calls": len(reread_gaps), "turn_time_s": round(sum(reread_gaps), 1)},
        "long_execute": {
            "calls": len(long_execute),
            "time_s": round(sum(call.end - call.start for call in long_execute), 1),
            "polling_calls": len(polling),
            "polling_time_s": round(sum(polling_s.values()), 1),
            "polling_by_keeper": {
                keeper: {
                    "polling_s": round(seconds, 1),
                    "turn_time_s": round(busy_by_keeper.get(keeper, 0.0), 1),
                }
                for keeper, seconds in sorted(polling_s.items(), key=lambda item: -item[1])
            },
        },
    }


def summarize_operations(
    operations: list[Operation],
    long_execute: dict[str, list[Interval]],
    runs: dict[str, list[Interval]],
) -> dict[str, object]:
    started = [op for op in operations if op.started_at is not None]
    total_wait = overlap_long = overlap_run = 0.0
    blocked_waits: list[float] = []
    for op in started:
        assert op.started_at is not None
        wait = op.started_at - op.created_at
        if wait <= 0:
            continue
        total_wait += wait
        overlap_long += overlap_seconds(op.created_at, op.started_at, long_execute.get(op.keeper, []))
        overlap_run += overlap_seconds(op.created_at, op.started_at, runs.get(op.keeper, []))
        if any(a <= op.created_at < b for a, b in long_execute.get(op.keeper, [])):
            blocked_waits.append(wait)
    by_origin: dict[str, dict[str, object]] = {}
    for origin in sorted({op.origin for op in operations}):
        group = [op for op in operations if op.origin == origin]
        waits = [op.started_at - op.created_at for op in group if op.started_at is not None]
        run_times = [
            op.completed_at - op.started_at
            for op in group
            if op.started_at is not None and op.completed_at is not None
        ]
        by_origin[origin] = {
            "operations": len(group),
            "states": dict(Counter(op.state for op in group)),
            "failure_kinds": dict(Counter(str(op.failure_kind) for op in group if op.state == "failed")),
            "wait": quantiles(waits),
            "run": quantiles(run_times),
        }
    return {
        "operations": len(operations),
        "started": len(started),
        "total_wait_s": round(total_wait, 1),
        "wait_overlapping_long_execute_s": round(overlap_long, 1),
        "wait_overlapping_a_run_of_the_same_keeper_s": round(overlap_run, 1),
        "created_during_long_execute": quantiles(blocked_waits),
        "by_origin": by_origin,
    }


def summarize_admission(waits: list[AdmissionWait]) -> dict[str, object]:
    by_provider: dict[str, float] = defaultdict(float)
    by_class: dict[str, float] = defaultdict(float)
    by_hour: dict[str, float] = defaultdict(float)
    for wait in waits:
        by_provider[f"{wait.provider}/{wait.model}"] += wait.waited_s
        by_class[wait.admission_class] += wait.waited_s
        by_hour[datetime.fromtimestamp(wait.ts, timezone.utc).strftime("%Y-%m-%dT%HZ")] += wait.waited_s
    hourly = sorted(seconds / SECONDS_PER_HOUR for seconds in by_hour.values())
    return {
        "events": len(waits),
        "wait": quantiles([wait.waited_s for wait in waits]),
        "by_provider_model_s": {
            key: round(seconds, 1) for key, seconds in sorted(by_provider.items(), key=lambda item: -item[1])[:8]
        },
        "by_class_s": {key: round(seconds, 1) for key, seconds in sorted(by_class.items())},
        "clock_hours_with_events": len(hourly),
        "median_wait_hours_per_clock_hour": round(hourly[len(hourly) // 2], 2) if hourly else None,
        "clock_hours_over_5_wait_hours": sum(1 for hours in hourly if hours > ADMISSION_WAIT_HOURS_HIGH),
    }


def parse_day(text: str) -> date:
    return date.fromisoformat(text)


def parse_until(text: str) -> float:
    return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", default=None, help="directory that contains .masc; MASC_BASE_PATH when omitted")
    parser.add_argument("--from-date", type=parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument("--until", type=parse_until, required=True, help="ignore anything after this ISO-8601 time")
    parser.add_argument("--json-out", default=None, help="write the summary to this file")
    args = parser.parse_args()
    base = masc_base_path.require(parser, args.base_path, "--base-path")

    since = datetime(args.from_date.year, args.from_date.month, args.from_date.day, tzinfo=timezone.utc).timestamp()
    calls = read_calls(base, args.from_date, args.to_date, args.until)
    runs = read_runs(base, since, args.until)
    busy_by_keeper = {keeper: union_seconds(intervals) for keeper, intervals in runs.items()}
    long_execute: dict[str, list[Interval]] = defaultdict(list)
    for call in calls:
        if call.tool == EXECUTE_TOOL and call.end - call.start >= LONG_EXECUTE_SEC:
            long_execute[call.keeper].append((call.start, call.end))
    summary = {
        "window": {
            "from": args.from_date.isoformat(),
            "to": args.to_date.isoformat(),
            "until": datetime.fromtimestamp(args.until, timezone.utc).isoformat(),
            "hours": round((args.until - since) / SECONDS_PER_HOUR, 2),
            "keepers_with_turn_traces": len(runs),
        },
        "turn_time": summarize_calls(calls, busy_by_keeper),
        "chat_operations": summarize_operations(read_operations(base, since, args.until), long_execute, runs),
        "provider_admission": summarize_admission(read_admission_waits(base, since, args.until)),
    }
    text = json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True)
    print(text)
    if args.json_out:
        pathlib.Path(args.json_out).write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
