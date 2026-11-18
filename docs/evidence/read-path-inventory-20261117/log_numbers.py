#!/usr/bin/env python3
"""Recount the log numbers of the read-path inventory note (sections 1 and 6).

Reads two local logs and prints aggregates only; no Keeper name is printed.

- Server log: `Operator_control_snapshot.keepers_json` writes
  `[keepers_json:<keeper>] sub-op: meta=..ms audit=..ms ... total=..ms` when
  one Keeper's work exceeds 300 ms (operator_control_snapshot.ml:192), and
  `[keepers_json:<keeper>] wait=..ms work=..ms` when the semaphore wait or the
  work exceeds 500 ms (operator_control_snapshot.ml:72). Rows below those
  thresholds are not in the log, so every number here describes slow rows only.
- TUI log: `http GET <path> took <n> ms elapsed, <m> ms cpu` for requests the
  TUI reports as slow (over 1 s).

A burst is a run of sub-op lines whose timestamps are at most --burst-gap
seconds apart. The log has one-second resolution.
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

TS_FORMAT = "%Y-%m-%d %H:%M:%S"
SUB_OP_RE = re.compile(
    r"^\[(?P<ts>[\d-]+ [\d:]+)\] .*\[keepers_json:[^\]]+\] sub-op: "
    r"meta=(?P<meta>\d+)ms audit=(?P<audit>\d+)ms profile=(?P<profile>\d+)ms "
    r"phase=(?P<phase>\d+)ms trust=(?P<trust>\d+)ms activity=(?P<activity>\d+)ms total=(?P<total>\d+)ms"
)
WAIT_RE = re.compile(r"^\[(?P<ts>[\d-]+ [\d:]+)\] .*\[keepers_json:[^\]]+\] wait=(?P<wait>\d+)ms work=(?P<work>\d+)ms")
TUI_RE = re.compile(
    r"^\[(?P<ts>[\d-]+ [\d:]+)\] .*http (?P<verb>[A-Z]+) (?P<path>[^ ?]+)\S* took (?P<ms>\d+) ms elapsed, (?P<cpu>\d+) ms cpu"
)
SUB_OPS = ("meta", "audit", "profile", "phase", "trust", "activity", "total")


@dataclass(frozen=True, slots=True)
class Window:
    since: datetime
    until: datetime

    def holds(self, ts: datetime) -> bool:
        return self.since <= ts <= self.until


def parse_ts(text: str) -> datetime:
    return datetime.strptime(text, TS_FORMAT)


def percentile(values: list[int], q: float) -> int:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * len(ordered)))]


def server_numbers(path: Path, window: Window, burst_gap: int) -> None:
    times: list[datetime] = []
    sub_ops: dict[str, list[int]] = defaultdict(list)
    waits: list[int] = []
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            m = SUB_OP_RE.match(line)
            if m and window.holds(ts := parse_ts(m["ts"])):
                times.append(ts)
                for op in SUB_OPS:
                    sub_ops[op].append(int(m[op]))
                continue
            w = WAIT_RE.match(line)
            if w and window.holds(parse_ts(w["ts"])):
                waits.append(int(w["wait"]))
    if not times:
        print("server: no sub-op line in the window")
        return
    bursts: list[list[datetime]] = [[times[0]]]
    for previous, current in zip(times, times[1:]):
        if (current - previous).total_seconds() <= burst_gap:
            bursts[-1].append(current)
        else:
            bursts.append([current])
    sizes = [len(b) for b in bursts]
    starts = [b[0] for b in bursts]
    gaps = [int((b - a).total_seconds()) for a, b in zip(starts, starts[1:])]
    print(f"server: slow Keeper rows (sub-op lines) = {len(times)}")
    print(f"server: bursts (gap <= {burst_gap}s) = {len(bursts)}, rows per burst min/median/max = "
          f"{min(sizes)}/{statistics.median(sizes):g}/{max(sizes)}, bursts over 31 rows = {sum(s > 31 for s in sizes)}")
    print(f"server: seconds between burst starts, most common = {sorted(set(gaps), key=gaps.count, reverse=True)[:5]}")
    for op in SUB_OPS:
        values = sub_ops[op]
        print(f"server: sub-op {op:8s} median = {statistics.median(values):g} ms, mean = {statistics.fmean(values):.0f} ms")
    if waits:
        print(f"server: wait/work lines = {len(waits)}, wait median = {statistics.median(waits):g} ms, "
              f"p90 = {percentile(waits, 0.9)} ms")


def tui_numbers(path: Path, window: Window) -> None:
    by_route: dict[str, list[tuple[datetime, int, int]]] = defaultdict(list)
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            m = TUI_RE.match(line)
            if m and window.holds(ts := parse_ts(m["ts"])):
                by_route[f"{m['verb']} {m['path']}"].append((ts, int(m["ms"]), int(m["cpu"])))
    for route, hits in sorted(by_route.items(), key=lambda kv: -len(kv[1])):
        elapsed = [ms for _, ms, _ in hits]
        cpu = [c for _, _, c in hits]
        print(f"tui: {route} slow={len(hits)} elapsed min/max = {min(elapsed)}/{max(elapsed)} ms, "
              f"cpu max = {max(cpu)} ms")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-log", type=Path, required=True)
    parser.add_argument("--tui-log", type=Path, help="omit to skip the TUI counts")
    parser.add_argument("--since", required=True, help="local time, e.g. '2026-11-17 22:22:00'")
    parser.add_argument("--until", required=True)
    parser.add_argument("--burst-gap", type=int, default=5)
    args = parser.parse_args(argv)
    window = Window(parse_ts(args.since), parse_ts(args.until))
    server_numbers(args.server_log, window, args.burst_gap)
    if args.tui_log is not None:
        tui_numbers(args.tui_log, window)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
