"""Where a Keeper's chat operation queue time went, per Keeper, in one window.

Read-only: opens `<base-path>/.masc/keepers/<keeper>/chat-operations.sqlite3` with mode=ro and
reads `turn-records/*/*.jsonl` next to it. Prints one JSON object.

Per Keeper:
- operations, executions: chat operations that started in the window, and the distinct
  executions they ran in (a batch member counts toward its batch owner).
- wait_h: sum of created_at -> started_at, clipped to the window. A requeued continuation clears
  started_at and writes it again, so this also counts the operation's earlier run segments.
- first_call_wait_h: created_at -> first native call of the execution. A native call id is a
  UUIDv7 whose first 48 bits are Unix milliseconds. Operations whose execution has no call keep
  wait_h. This is the lower bound; wait_h is the upper bound.
- queued_h: wall-clock hours with at least one operation waiting.
- idle_h: queued_h minus hours when some chat operation ran (started_at..completed_at). Earlier
  segments of a continued operation are missing from "ran", so idle_h is an upper bound.
- idle_overlap_h: idle_h that overlaps a turn of each turn_kind. A turn spans from its raw-trace
  file start to its turn record ts; the start is the millisecond stamp in the raw-trace file name
  (turn-<ms>-...). A turn whose raw trace is missing is counted in turns_without_start.
- turns: count and hours of turns per turn_kind whose record ts falls in the window.

Usage: chat_queue_split.py --base-path <dir> --since <epoch> --end <epoch> <keeper>...
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sqlite3
import sys
import uuid
from collections.abc import Iterable

HOUR = 3600.0
RAW_TRACE_START = re.compile(r"turn-(\d{13})-")

type Interval = tuple[float, float]


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


def uuid7_seconds(text: str) -> float | None:
    try:
        value = uuid.UUID(text)
    except ValueError:
        return None
    if value.version != 7:
        return None
    return (value.int >> 80) / 1000.0


def first_calls(con: sqlite3.Connection) -> dict[str, float]:
    out: dict[str, float] = {}
    for (record,) in con.execute("select record_json from semantic_executions"):
        parsed = json.loads(record)
        times = [
            t
            for t in (uuid7_seconds(str(c.get("call_id", ""))) for c in parsed.get("native_calls", []))
            if t is not None
        ]
        if times:
            out[str(parsed["id"]["id"])] = min(times)
    return out


def turn_intervals(keeper_dir: pathlib.Path, since: float, end: float) -> tuple[dict[str, list[Interval]], dict[str, dict[str, float]], int]:
    spans: dict[str, list[Interval]] = {}
    totals: dict[str, dict[str, float]] = {}
    without_start = 0
    for path in sorted((keeper_dir / "turn-records").glob("*/*.jsonl")):
        for line in path.read_text().splitlines():
            record = json.loads(line)
            ts = record.get("ts")
            if not isinstance(ts, float) or ts <= since or ts > end:
                continue
            kind = str(record.get("turn_kind"))
            match = RAW_TRACE_START.search(str((record.get("raw_trace_run_ref") or {}).get("path", "")))
            if match is None or int(match.group(1)) / 1000.0 > ts:
                without_start += 1
                continue
            start = int(match.group(1)) / 1000.0
            spans.setdefault(kind, []).append((max(start, since), ts))
            t = totals.setdefault(kind, {"turns": 0, "hours": 0.0})
            t["turns"] += 1
            t["hours"] += (ts - start) / HOUR
    return {k: union(v) for k, v in spans.items()}, totals, without_start


def keeper_split(base: pathlib.Path, keeper: str, since: float, end: float) -> dict[str, object]:
    keeper_dir = base / ".masc" / "keepers" / keeper
    con = sqlite3.connect(f"file:{keeper_dir / 'chat-operations.sqlite3'}?mode=ro", uri=True)
    rows = con.execute("select operation_id, created_at, started_at, completed_at from operations").fetchall()
    owner = dict(con.execute("select operation_id, execution_id from operation_batch_members"))
    calls = first_calls(con)

    started = [(o, c, a) for o, c, a, _ in rows if a is not None and c < end and a > since]
    wait = sum(min(a, end) - max(c, since) for _, c, a in started)
    first_wait = 0.0
    for o, c, a in started:
        first = calls.get(owner.get(o, o))
        first_wait += (min(a, end) - max(c, since)) if first is None else max(0.0, min(first, end) - max(c, since))

    waits = union((max(c, since), min(a if a is not None else end, end)) for _, c, a, _ in rows if c < end and (a is None or a > since))
    ran = union((max(a, since), min(z if z is not None else end, end)) for _, _, a, z in rows if a is not None and a < end and (z is None or z > since))
    idle = subtract(waits, ran)
    spans, totals, without_start = turn_intervals(keeper_dir, since, end)
    any_turn = union(iv for v in spans.values() for iv in v)
    return {
        "operations": len(started),
        "executions": len({owner.get(o, o) for o, _, _ in started}),
        "wait_h": round(wait / HOUR, 1),
        "first_call_wait_h": round(first_wait / HOUR, 1),
        "queued_h": round(length(waits) / HOUR, 1),
        "idle_h": round(length(idle) / HOUR, 1),
        "idle_overlap_h": {k: round(length(intersect(idle, v)) / HOUR, 1) for k, v in sorted(spans.items())}
        | {"any_turn": round(length(intersect(idle, any_turn)) / HOUR, 1)},
        "turns": {k: {"turns": int(v["turns"]), "hours": round(v["hours"], 1)} for k, v in sorted(totals.items())},
        "turns_without_start": without_start,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", type=float, required=True)
    parser.add_argument("--end", type=float, required=True)
    parser.add_argument("keepers", nargs="+")
    args = parser.parse_args(argv)
    out = {
        "window": [args.since, args.end],
        "keepers": {k: keeper_split(args.base_path, k, args.since, args.end) for k in args.keepers},
    }
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
