#!/usr/bin/env python3
"""Compare how often a tool call carries one argument, and what its result weighs, before and after a change.

A tool change that adds an optional argument helps only when models pass it.
This script reads the tool-call ledger (`<base>/.masc/tool_calls/YYYY-MM/DD.jsonl`
and its rotated segments, resolved by `scripts/lib/tool_call_log_paths.py`) and,
for one tool and one argument name, reports per time window:

- `calls`, `calls_per_hour` and the distinct keepers that called the tool;
- `calls_with_argument` and its share: a call carries the argument when its
  `input` object has the key with a value that is neither null nor an empty
  string. `false` and `0` count as carried;
- the keepers that carried it, most calls first;
- `result_bytes`: the total, the total per hour, the mean, p50 and p99 of the
  `result_bytes` of the ledger row, and the mean of the calls with and of the
  calls without the argument. A row with no usable `result_bytes` is left out of
  the byte figures and counted in `calls_without_size`.

Windows are half-open: a call at `--split` belongs to the window after it. Give
`--split` the instant the change reached the server, not the instant it was
merged. `first_use_utc` is the earliest call that carries the argument anywhere
in `--from` .. `--until`. A `--split` later than `first_use_utc` puts a call
that carries the argument into the `before` window, which is the check that the
split is not too late. Without `--split` there is one window, `all`.

The ledger holds one row per tool call across all lanes, so the windows compare
different keepers, models and workloads as much as they compare the change.
Read the share of calls that carry the argument first; the bytes per call tell
what a call weighs, not what the change saved.

A line that is not a JSON object is counted under `unreadable_lines`. A row of
the requested tool without a usable `ts` is counted under
`rows_without_timestamp` and belongs to no window. Pass `--until` explicitly: a
result that depends on the clock cannot be read again.

Usage:
    python3 -I -B docs/evidence/tool-argument-adoption-2026-11/measure_argument_adoption.py \\
        --base-path ~/me --tool keeper_artifact_read --argument contains \\
        --from 2026-11-03T00:00:00Z --split 2026-11-05T02:19:09Z --until 2026-11-05T20:00:00Z
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "scripts" / "lib"))

from tool_call_log_paths import tool_call_log_paths  # noqa: E402

JsonObject = dict[str, object]

SECONDS_PER_HOUR = 3600.0
TOP_KEEPERS = 5
P50 = 0.5
P99 = 0.99
UNKNOWN_KEEPER = "?"
ISO_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


@dataclass(frozen=True, slots=True)
class Call:
    ts: float
    keeper: str
    has_argument: bool
    result_bytes: int | None


@dataclass(frozen=True, slots=True)
class Window:
    label: str
    start: float
    end: float


@dataclass(slots=True)
class Unreadable:
    lines: int = 0
    rows_without_timestamp: int = 0


def as_object(value: object) -> JsonObject | None:
    return cast("JsonObject", value) if isinstance(value, dict) else None


def as_timestamp(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        return float(value)
    return None


def as_size(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def carries(input_value: object, argument: str) -> bool:
    fields = as_object(input_value)
    if fields is None:
        return False
    value = fields.get(argument)
    return value is not None and value != ""


def days_between(first_ts: float, last_ts: float) -> list[date]:
    """The UTC days that hold an instant of the half-open range [first_ts, last_ts)."""
    first = datetime.fromtimestamp(first_ts, UTC).date()
    end = datetime.fromtimestamp(last_ts, UTC)
    # An end at 00:00:00 holds no instant of its own day.
    last = end.date() - timedelta(days=1) if end.time() == time.min else end.date()
    return [first + timedelta(days=offset) for offset in range((last - first).days + 1)]


def read_calls(
    base: pathlib.Path, tool: str, argument: str, first_ts: float, last_ts: float, unreadable: Unreadable
) -> list[Call]:
    calls: list[Call] = []
    for day in days_between(first_ts, last_ts):
        live = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
        for path in tool_call_log_paths(base, live):
            with path.open("rb") as handle:
                for line in handle:
                    try:
                        row = as_object(json.loads(line))
                    except ValueError:
                        row = None
                    if row is None:
                        unreadable.lines += 1
                        continue
                    if row.get("tool") != tool:
                        continue
                    ts = as_timestamp(row.get("ts"))
                    if ts is None:
                        unreadable.rows_without_timestamp += 1
                        continue
                    if not first_ts <= ts < last_ts:
                        continue
                    keeper = row.get("keeper")
                    calls.append(
                        Call(
                            ts=ts,
                            keeper=keeper if isinstance(keeper, str) else UNKNOWN_KEEPER,
                            has_argument=carries(row.get("input"), argument),
                            result_bytes=as_size(row.get("result_bytes")),
                        )
                    )
    return calls


def percentile(sorted_values: list[int], share: float) -> int:
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * share))]


def mean(values: list[int]) -> float | None:
    return round(sum(values) / len(values), 1) if values else None


def share(part: int, whole: int) -> float:
    return round(part / whole, 4) if whole else 0.0


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, UTC).strftime(ISO_FORMAT)


def window_report(window: Window, calls: list[Call]) -> JsonObject:
    inside = [call for call in calls if window.start <= call.ts < window.end]
    hours = (window.end - window.start) / SECONDS_PER_HOUR
    report: JsonObject = {
        "label": window.label,
        "from_utc": iso(window.start),
        "until_utc": iso(window.end),
        "hours": round(hours, 2),
        "calls": len(inside),
    }
    if not inside:
        return report
    carrying = [call for call in inside if call.has_argument]
    sizes = sorted(call.result_bytes for call in inside if call.result_bytes is not None)
    by_keeper = Counter(call.keeper for call in carrying)
    report |= {
        "calls_per_hour": round(len(inside) / hours, 2),
        "calls_with_argument": len(carrying),
        "share_with_argument": share(len(carrying), len(inside)),
        "keepers": len({call.keeper for call in inside}),
        "keepers_using_argument": {
            "count": len(by_keeper),
            "top": [
                {"keeper": keeper, "calls": count}
                for keeper, count in sorted(by_keeper.items(), key=lambda item: (-item[1], item[0]))[:TOP_KEEPERS]
            ],
        },
        "calls_without_size": sum(1 for call in inside if call.result_bytes is None),
    }
    if sizes:
        report["result_bytes"] = {
            "total": sum(sizes),
            "per_hour": round(sum(sizes) / hours, 1),
            "mean": mean(sizes),
            "p50": percentile(sizes, P50),
            "p99": percentile(sizes, P99),
            "mean_with_argument": mean([call.result_bytes for call in carrying if call.result_bytes is not None]),
            "mean_without_argument": mean(
                [call.result_bytes for call in inside if not call.has_argument and call.result_bytes is not None]
            ),
        }
    return report


def measure(
    base: pathlib.Path, tool: str, argument: str, first_ts: float, split_ts: float | None, last_ts: float
) -> JsonObject:
    unreadable = Unreadable()
    calls = read_calls(base, tool, argument, first_ts, last_ts, unreadable)
    windows = (
        [Window("all", first_ts, last_ts)]
        if split_ts is None
        else [Window("before", first_ts, split_ts), Window("after", split_ts, last_ts)]
    )
    first_use = min((call.ts for call in calls if call.has_argument), default=None)
    return {
        "tool": tool,
        "argument": argument,
        "read_at_utc": datetime.now(UTC).strftime("%Y-%m-%dT%H:%MZ"),
        "unreadable_lines": unreadable.lines,
        "rows_without_timestamp": unreadable.rows_without_timestamp,
        "first_use_utc": iso(first_use) if first_use is not None else None,
        "windows": [window_report(window, calls) for window in windows],
    }


def parse_instant(text: str) -> float:
    try:
        return datetime.strptime(text, ISO_FORMAT).replace(tzinfo=UTC).timestamp()
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{text!r} is not a UTC instant like 2026-11-05T02:26:04Z") from error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--tool", required=True)
    parser.add_argument("--argument", required=True)
    parser.add_argument("--from", dest="first", type=parse_instant, required=True)
    parser.add_argument("--split", type=parse_instant)
    parser.add_argument("--until", type=parse_instant, required=True)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args()
    if not args.first < (args.split if args.split is not None else args.until) <= args.until:
        parser.error("--from, --split and --until must be in increasing order")
    result = measure(args.base_path.expanduser(), args.tool, args.argument, args.first, args.split, args.until)
    text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.json_out:
        args.json_out.write_text(text + "\n", encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
