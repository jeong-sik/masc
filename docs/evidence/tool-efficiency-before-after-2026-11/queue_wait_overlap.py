#!/usr/bin/env python3
"""How much chat-operation queue wait coincided with a long Execute call of the same Keeper.

A Keeper runs one chat operation at a time (the unique index `operations_single_running` of its
`chat-operations.sqlite3`). An operation that arrives while another one runs waits from
`created_at` to `started_at`. This script counts the waiting seconds that fell inside an Execute
call of `--hold-s` seconds or more that the same Keeper was running, and the seconds of those
calls during which at least one operation waited. Both size what an asynchronous Execute could
address: the Keeper could serve a waiting operation while the command runs. They leave out two
effects of opposite sign. An operation that arrived after the call and waited behind the queue
the call delayed would gain too. The turn that continues after the command costs model time that
the change adds back.

Reads, and never writes, the ledger files that `measure_before_after.py` reads and the operation
stores of the Keepers.

Definitions:

- A hold is an Execute row of the tool-call ledger with `duration_ms` of `--hold-s` seconds or
  more, drawn as [ts - duration, ts] because a ledger line is written when the call ends. A
  failed Execute holds the turn too and counts.
- A wait is [created_at, started_at] of an operation that started. Queued and cancelled
  operations never started and are left out.
- Holds and waits are clipped to [since, end). Ledger lines are read for one hour past `end`, so
  a hold that began inside the window and ended just after it is clipped, not lost.
- The holds of one Keeper are merged first, so two holds that overlap count their shared seconds
  once.
- Queue wait is a sum over operations (operation-seconds): two operations waiting at the same
  moment count twice, and `overlap` is counted the same way.
- `holds.hours_with_a_waiting_operation` is wall-clock time: the seconds of the merged holds that
  lie inside the union of the Keeper's waits, so two operations waiting together count once.

`queue_wait.hours_all_keepers` sums every Keeper that has an operation store.
`queue_wait.hours_holding_keepers` sums the Keepers that had at least one hold. A Keeper with
holds but no store, and a store that could not be read, are listed, not dropped.

Usage:
    python3 docs/evidence/tool-efficiency-before-after-2026-11/queue_wait_overlap.py \
        --base-path ~/me --since 2026-11-05T00:00:00 --end 2026-11-08T15:30:00 \
        --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-queue-wait-overlap-2026-11-05_11-08.json
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import datetime
import json
import pathlib
import sqlite3
import sys
from collections import Counter, defaultdict
from collections.abc import Iterable, Sequence
from typing import cast

import measure_before_after as ledger

DEFAULT_HOLD_S = 60.0
HOLD_MARGIN_S = 3_600.0
OPERATIONS_DB = "chat-operations.sqlite3"
SECONDS_PER_HOUR = 3_600.0
TOP_KEEPERS = 6
HOURS_DIGITS = 3
SHARE_DIGITS = 4

Interval = tuple[float, float]


@dataclasses.dataclass(frozen=True, slots=True)
class KeeperRow:
    keeper: str
    hold_calls: int
    held_s: float
    operations: int
    wait_s: float
    overlap_s: float
    queued_hold_s: float


def clipped(start: float, end: float, since: float, until: float) -> Interval | None:
    low = max(start, since)
    high = min(end, until)
    return (low, high) if high > low else None


def merged(intervals: Iterable[Interval]) -> list[Interval]:
    """The sorted, disjoint union of the intervals. Intervals that touch join."""
    union: list[Interval] = []
    for start, end in sorted(intervals):
        if union and start <= union[-1][1]:
            union[-1] = (union[-1][0], max(union[-1][1], end))
        else:
            union.append((start, end))
    return union


def inside_s(wait: Interval, holds: Sequence[Interval]) -> float:
    """Seconds of `wait` that lie inside `holds`, which must be merged."""
    total = 0.0
    for hold_start, hold_end in holds:
        if hold_start >= wait[1]:
            break
        total += max(0.0, min(wait[1], hold_end) - max(wait[0], hold_start))
    return total


def holds_by_keeper(
    calls: Iterable[ledger.Call], hold_s: float, since: float, until: float
) -> tuple[dict[str, list[Interval]], Counter[str]]:
    """The merged holds of each Keeper and how many Execute calls made them."""
    spans: dict[str, list[Interval]] = defaultdict(list)
    counts: Counter[str] = Counter()
    for call in calls:
        if call.tool != ledger.EXECUTE or call.duration_ms < hold_s * 1000:
            continue
        span = clipped(call.ts - call.duration_ms / 1000, call.ts, since, until)
        if span is not None:
            spans[call.keeper].append(span)
            counts[call.keeper] += 1
    return {keeper: merged(found) for keeper, found in spans.items()}, counts


def read_waits(store: pathlib.Path, since: float, until: float) -> list[Interval] | None:
    """The clipped waits of the operations that started, or None when the store cannot be read.

    A queued or cancelled operation has a NULL `started_at`, which `started_at > ?` never matches.
    """
    try:
        with contextlib.closing(sqlite3.connect(f"{store.resolve().as_uri()}?mode=ro", uri=True)) as connection:
            rows = cast(
                "list[tuple[float, float]]",
                connection.execute(
                    "SELECT created_at, started_at FROM operations WHERE started_at > ? AND created_at < ?",
                    (since, until),
                ).fetchall(),
            )
    except sqlite3.Error:
        return None
    return [wait for created, started in rows if (wait := clipped(created, started, since, until)) is not None]


def keeper_row(keeper: str, hold_calls: int, holds: Sequence[Interval], waits: Sequence[Interval]) -> KeeperRow:
    return KeeperRow(
        keeper=keeper,
        hold_calls=hold_calls,
        held_s=sum(end - start for start, end in holds),
        operations=len(waits),
        wait_s=sum(end - start for start, end in waits),
        overlap_s=sum(inside_s(wait, holds) for wait in waits),
        queued_hold_s=sum(inside_s(span, holds) for span in merged(waits)),
    )


def hours(seconds: float) -> float:
    return round(seconds / SECONDS_PER_HOUR, HOURS_DIGITS)


def share(part: float, whole: float) -> float | None:
    return round(part / whole, SHARE_DIGITS) if whole > 0 else None


def summarize(
    rows: Sequence[KeeperRow], holds: dict[str, list[Interval]], counts: Counter[str], without_store: Sequence[str], unreadable: Sequence[str]
) -> dict[str, object]:
    holding = [row for row in rows if row.hold_calls > 0]
    wait_all = sum(row.wait_s for row in rows)
    wait_holding = sum(row.wait_s for row in holding)
    overlap = sum(row.overlap_s for row in rows)
    top = sorted(holding, key=lambda row: row.overlap_s, reverse=True)[:TOP_KEEPERS]
    held = sum(end - start for spans in holds.values() for start, end in spans)
    queued_hold = sum(row.queued_hold_s for row in rows)
    return {
        "holds": {
            "calls": sum(counts.values()),
            "keepers": len(holds),
            "hours": hours(held),
            "hours_with_a_waiting_operation": hours(queued_hold),
            "share_with_a_waiting_operation": share(queued_hold, sum(row.held_s for row in rows)),
        },
        "queue_wait": {
            "operations": sum(row.operations for row in rows),
            "hours_all_keepers": hours(wait_all),
            "hours_holding_keepers": hours(wait_holding),
        },
        "overlap": {
            "hours": hours(overlap),
            "share_of_all_keepers": share(overlap, wait_all),
            "share_of_holding_keepers": share(overlap, wait_holding),
        },
        "top_keepers": [
            {
                "keeper": row.keeper,
                "overlap_hours": hours(row.overlap_s),
                "hold_calls": row.hold_calls,
                "held_hours": hours(row.held_s),
                "held_hours_with_a_waiting_operation": hours(row.queued_hold_s),
                "queue_wait_hours": hours(row.wait_s),
            }
            for row in top
        ],
        "keepers_with_holds_and_no_store": sorted(without_store),
        "unreadable_stores": sorted(unreadable),
    }


def measure(base: pathlib.Path, since: datetime.datetime, end: datetime.datetime, hold_s: float) -> dict[str, object]:
    first = since.timestamp()
    last = end.timestamp()
    skipped = ledger.Skipped()
    paths = ledger.ledger_files(base, since, end + datetime.timedelta(seconds=HOLD_MARGIN_S))
    calls = ledger.read_calls(paths, first, last + HOLD_MARGIN_S, skipped)
    holds, counts = holds_by_keeper(calls, hold_s, first, last)
    stores = {store.parent.name: store for store in sorted((base / ".masc" / "keepers").glob(f"*/{OPERATIONS_DB}"))}
    rows: list[KeeperRow] = []
    unreadable: list[str] = []
    for keeper, store in stores.items():
        waits = read_waits(store, first, last)
        if waits is None:
            unreadable.append(keeper)
            continue
        rows.append(keeper_row(keeper, counts[keeper], holds.get(keeper, []), waits))
    without_store = [keeper for keeper in holds if keeper not in stores]
    result = summarize(rows, holds, counts, without_store, unreadable)
    return {
        "window": [ledger.stamp(first), ledger.stamp(last)],
        "hold_seconds": hold_s,
        "files": len(paths),
        "skipped": {"bad_lines": skipped.bad_lines},
        **result,
    }


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", required=True, help="UTC, like 2026-11-05T00:00:00")
    parser.add_argument("--end", required=True, help="UTC, like 2026-11-09T00:00:00")
    parser.add_argument("--hold-s", type=float, default=DEFAULT_HOLD_S)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    since = ledger.parse_instant(cast("str", args.since))
    end = ledger.parse_instant(cast("str", args.end))
    hold_s = cast("float", args.hold_s)
    if end <= since or hold_s <= 0:
        print("--end must come after --since and --hold-s must be positive", file=sys.stderr)
        return 2
    if end - since > datetime.timedelta(days=ledger.MAX_DAYS):
        print(f"the span must stay within {ledger.MAX_DAYS} days", file=sys.stderr)
        return 2
    result = measure(cast("pathlib.Path", args.base_path).expanduser(), since, end, hold_s)
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
