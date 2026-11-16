"""Where a Keeper's chat operation queue time went, per Keeper, in one window.

Read-only: opens `<base-path>/.masc/keepers/<keeper>/chat-operations.sqlite3` with mode=ro and
reads `turn-records/*/*.jsonl` and `raw-traces/turn-*.jsonl` next to it. Prints one JSON object.
Hours are summed unrounded and rounded once at print time.

An operation waits from created_at until started_at. An operation that never started waits until
completed_at (a cancel) or, if it has neither, until the window end. Every interval is clipped to
the window.

Per Keeper:
- received: operations whose created_at is in the window.
- waited: operations whose wait interval overlaps the window. waited_started is the subset that
  has a started_at; executions is the number of distinct executions those ran in, and
  bound_to_other is how many of them ran inside another operation's execution (a batch member).
- wait_h: sum of the wait intervals. A requeued continuation clears started_at and writes it
  again, so for a continuation this also counts its earlier run segments.
- first_claim_wait_h: created_at -> the claim that created the operation's execution
  (semantic_executions.created_at). An operation that was never claimed counts its whole wait.
  operations_without_execution counts started operations whose execution record is missing; they
  are left out of this sum.
- mean_run_min: mean of completed_at - started_at over waited_started operations that completed.
  started_at is the last segment start, so this is the last segment of a continuation.
- queued_h: wall-clock hours with at least one operation waiting.
- idle_h: queued_h minus hours when some chat operation ran (started_at..completed_at). Earlier
  segments of a continued operation are missing from "ran", so idle_h is an upper bound.
- turns: count and hours of turns per turn_kind, clipped to the window. A turn spans from its
  raw-trace file start (the millisecond stamp in turn-<ms>-...) to its turn record ts. A record
  whose raw trace name has no stamp is counted in turns_without_start.
- unrecorded_traces: raw traces that no turn record points to (a turn cut by a restart, or one
  still running at read time). Each spans from its file stamp to the ts of its last line.
- idle_overlap_h: idle_h that overlaps each turn_kind, the unrecorded traces, and any of them.
- idle_without_turn_h: idle time that overlaps nothing above. --gaps-out writes every such
  interval as one JSON line for gap_causes.py.

The "sum" object adds every count and hour over the Keepers given.

Usage: chat_queue_split.py --base-path <dir> --since <epoch> --end <epoch> [--gaps-out <file>] <keeper>...
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import re
import sqlite3
import sys
from collections.abc import Iterable

HOUR = 3600.0
MINUTE = 60.0
RAW_TRACE_START = re.compile(r"turn-(\d{13})-")
UNRECORDED = "unrecorded_trace"
TAIL_BYTES = 1 << 16  # how much of a raw trace end is read to find its last line
PRINT_DIGITS = 3

type Interval = tuple[float, float]


def utc(t: float) -> str:
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def union(intervals: Iterable[Interval]) -> list[Interval]:
    out: list[Interval] = []
    for a, b in sorted(intervals):
        if b <= a:
            continue
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def length(intervals: Iterable[Interval]) -> float:
    return sum(b - a for a, b in intervals)


def intersect(xs: list[Interval], ys: list[Interval]) -> list[Interval]:
    out: list[Interval] = []
    i = j = 0
    while i < len(xs) and j < len(ys):
        lo, hi = max(xs[i][0], ys[j][0]), min(xs[i][1], ys[j][1])
        if hi > lo:
            out.append((lo, hi))
        if xs[i][1] < ys[j][1]:
            i += 1
        else:
            j += 1
    return out


def subtract(xs: list[Interval], ys: list[Interval]) -> list[Interval]:
    out: list[Interval] = []
    for a, b in xs:
        cur = a
        for c, d in ys:
            if d <= cur or c >= b:
                continue
            if c > cur:
                out.append((cur, c))
            cur = max(cur, d)
        if cur < b:
            out.append((cur, b))
    return out


def clip(a: float, b: float, since: float, end: float) -> Interval | None:
    lo, hi = max(a, since), min(b, end)
    return (lo, hi) if hi > lo else None


def execution_claims(con: sqlite3.Connection) -> dict[str, float]:
    out: dict[str, float] = {}
    for execution_id, created_at in con.execute(
        "select json_extract(record_json, '$.id.id'), json_extract(record_json, '$.created_at') from semantic_executions"
    ):
        if isinstance(execution_id, str) and isinstance(created_at, float):
            out[execution_id] = created_at
    return out


def trace_start(name: str) -> float | None:
    match = RAW_TRACE_START.search(name)
    return None if match is None else int(match.group(1)) / 1000.0


def last_line_ts(path: pathlib.Path) -> float | None:
    with path.open("rb") as handle:
        handle.seek(0, 2)
        size = handle.tell()
        handle.seek(max(0, size - TAIL_BYTES))
        lines = [line for line in handle.read().splitlines() if line.strip()]
    if not lines:
        return None
    try:
        ts = json.loads(lines[-1]).get("ts")
    except ValueError:
        return None
    return ts if isinstance(ts, float) else None


def turn_spans(keeper_dir: pathlib.Path, since: float, end: float) -> tuple[dict[str, list[Interval]], dict[str, dict[str, float]], int, int]:
    spans: dict[str, list[Interval]] = {}
    totals: dict[str, dict[str, float]] = {}
    without_start = 0
    recorded: set[str] = set()
    for path in sorted((keeper_dir / "turn-records").glob("*/*.jsonl")):
        for line in path.read_text().splitlines():
            record = json.loads(line)
            ts = record.get("ts")
            if not isinstance(ts, float):
                continue
            trace = pathlib.Path(str((record.get("raw_trace_run_ref") or {}).get("path", ""))).name
            recorded.add(trace)
            start = trace_start(trace)
            if start is None or start > ts:
                if since < ts <= end:
                    without_start += 1
                continue
            span = clip(start, ts, since, end)
            if span is None:
                continue
            kind = str(record.get("turn_kind"))
            spans.setdefault(kind, []).append(span)
            t = totals.setdefault(kind, {"turns": 0, "hours": 0.0})
            t["turns"] += 1
            t["hours"] += (span[1] - span[0]) / HOUR
    unreadable = 0
    for path in sorted((keeper_dir / "raw-traces").glob("turn-*.jsonl")):
        start = trace_start(path.name)
        if path.name in recorded or start is None or start >= end:
            continue
        last = last_line_ts(path)
        if last is None:
            unreadable += 1
            continue
        span = clip(start, last, since, end)
        if span is None:
            continue
        spans.setdefault(UNRECORDED, []).append(span)
        t = totals.setdefault(UNRECORDED, {"turns": 0, "hours": 0.0})
        t["turns"] += 1
        t["hours"] += (span[1] - span[0]) / HOUR
    return {k: union(v) for k, v in spans.items()}, totals, without_start, unreadable


def keeper_split(base: pathlib.Path, keeper: str, since: float, end: float) -> tuple[dict[str, object], list[Interval]] | None:
    keeper_dir = base / ".masc" / "keepers" / keeper
    con = sqlite3.connect(f"file:{keeper_dir / 'chat-operations.sqlite3'}?mode=ro", uri=True)
    if con.execute("select 1 from sqlite_master where type = 'table' and name = 'operations'").fetchone() is None:
        return None
    rows: list[tuple[str, float, float | None, float | None]] = con.execute(
        "select operation_id, created_at, started_at, completed_at from operations"
    ).fetchall()
    owner: dict[str, str] = dict(con.execute("select operation_id, execution_id from operation_batch_members"))
    claims = execution_claims(con)

    def wait_end(started: float | None, completed: float | None) -> float:
        if started is not None:
            return started
        return completed if completed is not None else end

    waited = [(o, c, a, z) for o, c, a, z in rows if c < end and wait_end(a, z) > since]
    started = [(o, c, a, z) for o, c, a, z in waited if a is not None]
    wait = sum(min(wait_end(a, z), end) - max(c, since) for _, c, a, z in waited)

    first_claim = 0.0
    without_execution = 0
    for o, c, a, z in waited:
        if a is None:
            first_claim += min(wait_end(a, z), end) - max(c, since)
            continue
        claim = claims.get(owner.get(o, o))
        if claim is None:
            without_execution += 1
            continue
        first_claim += max(0.0, min(claim, end) - max(c, since))

    runs = [z - a for _, _, a, z in started if a is not None and z is not None]
    waits = union(iv for _, c, a, z in waited if (iv := clip(c, wait_end(a, z), since, end)) is not None)
    ran = union(
        iv for _, _, a, z in rows if a is not None and (iv := clip(a, z if z is not None else end, since, end)) is not None
    )
    idle = subtract(waits, ran)
    spans, totals, without_start, unreadable = turn_spans(keeper_dir, since, end)
    any_turn = union(iv for v in spans.values() for iv in v)
    gaps = subtract(idle, any_turn)
    split: dict[str, object] = {
        "received": sum(1 for _, c, _, _ in rows if since < c <= end),
        "waited": len(waited),
        "waited_started": len(started),
        "executions": len({owner.get(o, o) for o, _, _, _ in started}),
        "bound_to_other": sum(1 for o, _, _, _ in started if owner.get(o, o) != o),
        "wait_h": wait / HOUR,
        "first_claim_wait_h": first_claim / HOUR,
        "operations_without_execution": without_execution,
        "mean_run_min": (sum(runs) / len(runs) / MINUTE) if runs else None,
        "queued_h": length(waits) / HOUR,
        "idle_h": length(idle) / HOUR,
        "idle_overlap_h": {k: length(intersect(idle, v)) / HOUR for k, v in sorted(spans.items())}
        | {"any": length(intersect(idle, any_turn)) / HOUR},
        "turns": {k: {"turns": int(v["turns"]), "hours": v["hours"]} for k, v in sorted(totals.items())},
        "turns_without_start": without_start,
        "unreadable_traces": unreadable,
        "idle_without_turn_h": length(gaps) / HOUR,
        "idle_without_turn_gaps": len(gaps),
    }
    return split, gaps


def add_into(total: dict[str, object], part: dict[str, object]) -> None:
    for key, value in part.items():
        if key == "mean_run_min":
            continue
        if isinstance(value, dict):
            inner = total.setdefault(key, {})
            if isinstance(inner, dict):
                add_into(inner, value)  # pyright: ignore[reportUnknownArgumentType]
        elif isinstance(value, (int, float)):
            current = total.get(key, 0)
            total[key] = (current if isinstance(current, (int, float)) else 0) + value


def rounded(value: object) -> object:
    if isinstance(value, float):
        return round(value, PRINT_DIGITS)
    if isinstance(value, dict):
        return {k: rounded(v) for k, v in value.items()}  # pyright: ignore[reportUnknownVariableType]
    return value


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", type=float, required=True)
    parser.add_argument("--end", type=float, required=True)
    parser.add_argument("--gaps-out", type=pathlib.Path)
    parser.add_argument("keepers", nargs="+")
    args = parser.parse_args(argv)
    keepers: dict[str, object] = {}
    total: dict[str, object] = {}
    gap_lines: list[str] = []
    without_table: list[str] = []
    for keeper in args.keepers:
        result = keeper_split(args.base_path, keeper, args.since, args.end)
        if result is None:
            without_table.append(keeper)
            continue
        split, gaps = result
        keepers[keeper] = split
        add_into(total, split)
        gap_lines.extend(
            json.dumps({"keeper": keeper, "start": a, "end": b, "start_utc": utc(a), "end_utc": utc(b)}) for a, b in gaps
        )
    if args.gaps_out is not None:
        args.gaps_out.write_text("".join(line + "\n" for line in gap_lines))
    out = {
        "window": [utc(args.since), utc(args.end)],
        "keepers": keepers,
        "keepers_without_operations_table": without_table,
        "sum": total,
    }
    print(json.dumps(rounded(out), ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
