#!/usr/bin/env python3
"""Split Execute overhead by the time since the last server boot, to see what restarts do.

Reuses the ledger reader and the overhead definition of `measure_before_after.py`: for a
successful Execute whose output reports `execution_time_ms`, the overhead is `duration_ms`
minus that time, and a call is slow at 500 ms or more. A call within `--cold-s` seconds after a
boot is cold, any other call is warm. A call before the first boot given is warm and has the
segment `before first`.

A window that holds several boots mixes cold starts into its slow share. This prints the slow
share of each boot segment for cold and warm calls apart, per sandbox.

    python3 cold_start_split.py --since 2026-11-09T01:58:31 --end 2026-11-09T08:00:00 \
        --boot 2026-11-09T02:04:59 --boot 2026-11-09T04:57:31

Boots are UTC instants, `YYYY-MM-DDTHH:MM:SS`; read them from the server's `/health`
`build.started_at`. Unreadable ledger lines are counted and reported.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime
import pathlib
from collections.abc import Iterable, Sequence

import measure_before_after as ledger

COLD_S_DEFAULT = 300.0
COLD = "cold"
WARM = "warm"
BEFORE_FIRST_BOOT = 0.0


@dataclasses.dataclass(slots=True)
class Cell:
    calls: int = 0
    slow: int = 0
    overhead_ms: float = 0.0


type Key = tuple[float, str, str]


def instant(text: str) -> float:
    return datetime.datetime.fromisoformat(text).replace(tzinfo=datetime.UTC).timestamp()


def split(calls: Iterable[ledger.Call], boots: Sequence[float], cold_s: float) -> dict[Key, Cell]:
    """Cells keyed by (boot of the segment, sandbox, `cold` or `warm`). `boots` is sorted by this function."""
    ordered = sorted(boots)
    cells: dict[Key, Cell] = collections.defaultdict(Cell)
    for call in calls:
        if call.tool != ledger.EXECUTE or call.failed:
            continue
        run = ledger.execution_time_ms_of(call.output_text)
        if run is None:
            continue
        since_boot = [boot for boot in ordered if boot <= call.ts]
        segment = since_boot[-1] if since_boot else BEFORE_FIRST_BOOT
        phase = COLD if segment != BEFORE_FIRST_BOOT and call.ts - segment < cold_s else WARM
        outside = call.duration_ms - run
        cell = cells[(segment, call.sandbox, phase)]
        cell.calls += 1
        cell.slow += 1 if outside >= ledger.OVERHEAD_SLOW_MS else 0
        cell.overhead_ms += outside
    return dict(cells)


def label(segment: float) -> str:
    if segment == BEFORE_FIRST_BOOT:
        return "before first"
    return datetime.datetime.fromtimestamp(segment, datetime.UTC).strftime("%m-%d %H:%M:%S")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, default=pathlib.Path("~/me").expanduser())
    parser.add_argument("--since", required=True)
    parser.add_argument("--end", required=True)
    parser.add_argument("--boot", action="append", required=True, help="UTC boot time, repeatable")
    parser.add_argument("--cold-s", type=float, default=COLD_S_DEFAULT)
    args = parser.parse_args()

    start = ledger.parse_instant(args.since)
    end = ledger.parse_instant(args.end)
    skipped = ledger.Skipped()
    paths = ledger.ledger_files(args.base_path.expanduser(), start, end)
    cells = split(ledger.read_calls(paths, start.timestamp(), end.timestamp(), skipped), [instant(text) for text in args.boot], args.cold_s)

    print(f"window {args.since}..{args.end} UTC, cold = first {args.cold_s:.0f} s after a boot, unreadable lines {skipped.bad_lines}")
    print("segment(boot UTC)    sandbox     phase  calls  slow  slow%   mean_overhead_ms")
    for (segment, sandbox, phase), cell in sorted(cells.items()):
        share = 100.0 * cell.slow / cell.calls
        print(f"{label(segment):19} {sandbox:11} {phase:5} {cell.calls:6} {cell.slow:5} {share:5.1f}%  {cell.overhead_ms / cell.calls:8.0f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
