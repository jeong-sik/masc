#!/usr/bin/env python3
"""Time spent inside calls that ran a minute or more, read from the tool metrics store.

Groups the rows of `<base-path>/.masc/tool-metrics.sqlite3` the way
`lib/tool_metrics_store/tool_metrics_series.ml` does, so the numbers match what
`GET /api/v1/tool-metrics/series` answers once a server runs that code. The store is
opened read-only and nothing is written except the optional --json file.

Examples:
  long_call_series.py --until 1794276000 --since-hours 720 --bucket day --per-bucket
  long_call_series.py --until 1794276000 --since-hours 168 --bucket hour --json h168.json
  long_call_series.py --until 1794276000 --since-hours 168 --bucket hour --compare server_h168.json

--compare reads the answer of the server's own code (every field of the total, of each bucket
and of each tool row) and prints the differences, or "equal".
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import sqlite3
import sys
from dataclasses import dataclass, field
from typing import TypeGuard, cast

LONG_CALL_MS = 60_000.0
TOP_TOOL_LIMIT = 20
SECONDS_PER_MINUTE = 60
WIDTH_SECONDS = {"hour": 3600, "day": 86400}
MS_PER_HOUR = 3_600_000.0
MEDIAN = 0.50
TAIL = 0.95

type Stat = dict[str, float | int | None]


@dataclass(slots=True)
class Accumulator:
    calls: int = 0
    failed: int = 0
    deferred: int = 0
    sum_ms: float = 0.0
    peak_ms: float = 0.0
    long_calls: int = 0
    long_sum_ms: float = 0.0
    durations: list[float] = field(default_factory=list[float])

    def record(self, disposition: str, duration_ms: float) -> None:
        self.calls += 1
        if disposition == "failed":
            self.failed += 1
        elif disposition == "deferred":
            self.deferred += 1
        self.sum_ms += duration_ms
        self.peak_ms = max(self.peak_ms, duration_ms)
        if duration_ms >= LONG_CALL_MS:
            self.long_calls += 1
            self.long_sum_ms += duration_ms
        self.durations.append(duration_ms)

    def stat(self) -> Stat:
        if self.calls == 0:
            return {
                "call_count": 0,
                "failure_count": 0,
                "deferred_count": 0,
                "total_ms": 0.0,
                "p50_ms": None,
                "p95_ms": None,
                "max_ms": None,
                "long_count": 0,
                "long_total_ms": 0.0,
            }
        ordered = sorted(self.durations)
        return {
            "call_count": self.calls,
            "failure_count": self.failed,
            "deferred_count": self.deferred,
            "total_ms": self.sum_ms,
            "p50_ms": percentile(ordered, MEDIAN),
            "p95_ms": percentile(ordered, TAIL),
            "max_ms": self.peak_ms,
            "long_count": self.long_calls,
            "long_total_ms": self.long_sum_ms,
        }


def percentile(ordered: list[float], p: float) -> float:
    """The sample at rank round((n - 1) * p), halves away from zero: the rule of Tool_metrics."""
    rank = math.floor((len(ordered) - 1) * p + 0.5)
    return ordered[max(0, min(len(ordered) - 1, rank))]


@dataclass(frozen=True, slots=True)
class Series:
    since: float
    until: float
    bucket: str
    utc_offset_min: int
    tool: str | None
    starts: tuple[int, ...]
    buckets: tuple[Stat, ...]
    total: Stat
    top_by_time: tuple[tuple[str, Stat], ...]

    def to_json(self) -> dict[str, object]:
        return {
            "generated_at": self.until,
            "source": {"kind": "tool_metrics", "persistence": "sqlite"},
            "window": {
                "since": self.since,
                "until": self.until,
                "bucket": self.bucket,
                "bucket_seconds": WIDTH_SECONDS[self.bucket],
                "utc_offset_min": self.utc_offset_min,
            },
            "tool": self.tool,
            "long_call_ms": LONG_CALL_MS,
            "total": self.total,
            "buckets": [
                {"start": start, **stat}
                for start, stat in zip(self.starts, self.buckets)
            ],
            "top_by_time": [
                {"name": name, "public_names": [], **stat}
                for name, stat in self.top_by_time
            ],
        }


def build_series(
    connection: sqlite3.Connection,
    *,
    until: float,
    since_hours: float,
    bucket: str,
    utc_offset_min: int,
    tool: str | None,
) -> Series:
    since = until - since_hours * 3600.0
    width_s = WIDTH_SECONDS[bucket]
    offset_s = utc_offset_min * SECONDS_PER_MINUTE
    first = (math.floor(since) + offset_s) // width_s
    last = (math.floor(math.nextafter(until, -math.inf)) + offset_s) // width_s
    slots = [Accumulator() for _ in range(last - first + 1)]
    overall = Accumulator()
    per_tool: dict[str, Accumulator] = {}
    sql = "SELECT ts, tool_name, disposition, duration_ms FROM tool_metric_events WHERE ts >= ? AND ts < ?"
    params: list[float | str] = [since, until]
    if tool is not None:
        sql += " AND tool_name = ?"
        params.append(tool)
    for row in connection.execute(sql, params):
        ts, name, disposition, duration_ms = cast(tuple[float, str, str, float], row)
        if (
            disposition not in ("completed", "deferred", "failed")
            or not math.isfinite(duration_ms)
            or duration_ms < 0
        ):
            raise SystemExit(f"bad row: {ts} {name} {disposition} {duration_ms}")
        slots[(math.floor(ts) + offset_s) // width_s - first].record(
            disposition, duration_ms
        )
        overall.record(disposition, duration_ms)
        per_tool.setdefault(name, Accumulator()).record(disposition, duration_ms)
    longest_first = sorted(
        per_tool.items(), key=lambda item: (-item[1].sum_ms, item[0])
    )[:TOP_TOOL_LIMIT]
    return Series(
        since=since,
        until=until,
        bucket=bucket,
        utc_offset_min=utc_offset_min,
        tool=tool,
        starts=tuple((first + slot) * width_s - offset_s for slot in range(len(slots))),
        buckets=tuple(slot.stat() for slot in slots),
        total=overall.stat(),
        top_by_time=tuple(
            (name, accumulator.stat()) for name, accumulator in longest_first
        ),
    )


def same(a: float | int | None, b: float | int | None) -> bool:
    if a is None or b is None:
        return a is b
    return (
        a == b
        if isinstance(a, int) and isinstance(b, int)
        else math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-6)
    )


def number_or_null(value: object) -> TypeGuard[float | int | None]:
    return value is None or (
        isinstance(value, (int, float)) and not isinstance(value, bool)
    )


def stat_differences(label: str, mine: Stat, theirs: dict[str, object]) -> list[str]:
    found: list[str] = []
    for key, value in mine.items():
        other = theirs.get(key, "(missing)")
        if not number_or_null(other) or not same(value, other):
            found.append(f"{label}.{key}: script {value!r}, server answer {other!r}")
    return found


def as_object_dict(value: object) -> dict[str, object]:
    """A JSON object read as text keys; anything else is an empty object."""
    if not isinstance(value, dict):
        return {}
    return {str(key): item for key, item in cast(dict[object, object], value).items()}


def as_object_list(value: object) -> list[object]:
    return list(cast(list[object], value)) if isinstance(value, list) else []


def compare(series: Series, answer: dict[str, object]) -> list[str]:
    found: list[str] = []
    if answer.get("long_call_ms") != LONG_CALL_MS:
        found.append(
            f"long_call_ms: script {LONG_CALL_MS}, server answer {answer.get('long_call_ms')!r}"
        )
    found += stat_differences(
        "total", series.total, as_object_dict(answer.get("total"))
    )
    their_buckets = as_object_list(answer.get("buckets"))
    if len(their_buckets) != len(series.buckets):
        found.append(
            f"buckets: script {len(series.buckets)}, server answer {len(their_buckets)}"
        )
    for index, (start, stat) in enumerate(zip(series.starts, series.buckets)):
        row = as_object_dict(their_buckets[index]) if index < len(their_buckets) else {}
        if row.get("start") != start:
            found.append(
                f"buckets[{index}].start: script {start}, server answer {row.get('start')!r}"
            )
        found += stat_differences(f"buckets[{index}]", stat, row)
    their_tools = as_object_list(answer.get("top_by_time"))
    if len(their_tools) != len(series.top_by_time):
        found.append(
            f"top_by_time: script {len(series.top_by_time)} rows, server answer {len(their_tools)}"
        )
    for index, (name, stat) in enumerate(series.top_by_time):
        row = as_object_dict(their_tools[index]) if index < len(their_tools) else {}
        if row.get("name") != name:
            found.append(
                f"top_by_time[{index}].name: script {name}, server answer {row.get('name')!r}"
            )
        found += stat_differences(f"top_by_time[{index}]", stat, row)
    return found


def hours(ms: object) -> float:
    return float(ms) / MS_PER_HOUR if isinstance(ms, (int, float)) else math.nan


def share(part: object, whole: object) -> float:
    return (
        100.0 * float(part) / float(whole)
        if isinstance(part, (int, float)) and isinstance(whole, (int, float)) and whole
        else 0.0
    )


def print_summary(series: Series, per_bucket: bool) -> None:
    total = series.total
    print(
        f"window {series.since:.0f}..{series.until:.0f} ({series.bucket}, utc+{series.utc_offset_min}min): "
        f"{total['call_count']} calls, {hours(total['total_ms']):.2f} h; "
        f"{total['long_count']} calls of {LONG_CALL_MS / 1000:.0f} s or more took {hours(total['long_total_ms']):.2f} h "
        f"({share(total['long_total_ms'], total['total_ms']):.1f}% of the time)"
    )
    if per_bucket:
        for start, stat in zip(series.starts, series.buckets):
            print(
                f"  {start}: calls={stat['call_count']} time={hours(stat['total_ms']):.2f} h "
                f"long={stat['long_count']} long_time={hours(stat['long_total_ms']):.2f} h "
                f"({share(stat['long_total_ms'], stat['total_ms']):.1f}%)"
            )
    for name, stat in series.top_by_time[:8]:
        print(
            f"  tool {name}: calls={stat['call_count']} time={hours(stat['total_ms']):.2f} h "
            f"long={stat['long_count']} long_time={hours(stat['long_total_ms']):.2f} h"
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--base-path", type=pathlib.Path, default=pathlib.Path.home() / "me"
    )
    parser.add_argument(
        "--until", type=float, required=True, help="end of the window, epoch seconds"
    )
    parser.add_argument("--since-hours", type=float, required=True)
    parser.add_argument("--bucket", choices=sorted(WIDTH_SECONDS), default="hour")
    parser.add_argument(
        "--utc-offset-min",
        type=int,
        default=540,
        help="minutes east of UTC (default Seoul)",
    )
    parser.add_argument("--tool", default=None, help="a stored tool name")
    parser.add_argument("--per-bucket", action="store_true")
    parser.add_argument(
        "--json",
        type=pathlib.Path,
        default=None,
        help="write the answer in the endpoint's shape",
    )
    parser.add_argument(
        "--compare",
        type=pathlib.Path,
        default=None,
        help="answer of the server's code to compare with",
    )
    args = parser.parse_args()
    store = args.base_path / ".masc" / "tool-metrics.sqlite3"
    if not store.is_file():
        raise SystemExit(f"no tool metrics store at {store}")
    with sqlite3.connect(f"file:{store}?mode=ro", uri=True) as connection:
        series = build_series(
            connection,
            until=args.until,
            since_hours=args.since_hours,
            bucket=args.bucket,
            utc_offset_min=args.utc_offset_min,
            tool=args.tool,
        )
    if args.json is not None:
        args.json.write_text(json.dumps(series.to_json(), indent=1))
    if args.compare is not None:
        answer: dict[str, object] = json.loads(args.compare.read_text())
        found = compare(series, answer)
        print("equal" if not found else f"{len(found)} differences")
        for line in found[:20]:
            print("  " + line)
        return 0 if not found else 1
    print_summary(series, args.per_bucket)
    return 0


if __name__ == "__main__":
    sys.exit(main())
