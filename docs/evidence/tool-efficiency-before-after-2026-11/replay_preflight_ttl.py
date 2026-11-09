#!/usr/bin/env python3
"""Replay remote_ssh tool calls against the SSH preflight cache of `keeper_sandbox_remote.ml`.

A preflight pass opens up to eight SSH connections. `check_preflight` reuses the last pass of a
Keeper for a number of seconds that depends on the caller. This script counts how many passes a
ledger span would have run for a given pair of lifetimes, so a change of those lifetimes can be
read as a number before the server runs it. The result is an estimate from a replay, never a
measurement of a running server.

Reads, and never writes, the same ledger files as `measure_before_after.py`.

Model, one cache entry per Keeper as in `preflight_cache_key`:

- A call uses the cache when its `runtime_contract.sandbox_profile` is `remote_ssh` and its tool is
  one of Read, Grep, Glob, Edit, Write or Execute. Edit, Write and an Execute whose input says
  `intent=request_effect` are writers; the other calls are readers.
- A call starts at `ts - duration_ms`: a ledger line is written when the call ends. A pass is
  dated at the start of the call that ran it.
- A call runs a pass when its Keeper has none, or the newest one is at least as old as the
  lifetime of the call's class: `--read-ttl` for a reader, `--write-ttl` for a writer. Every pass
  is taken to let readers through, as it does on a healthy endpoint.
- Only passes run by calls that ended inside [since, end) are counted. The calls of the
  `--warmup-hours` before `since` only fill the cache.

`overhead_by_gap` is the observed side of the same question: for each successful Execute that
reports `execution_time_ms`, the time the tool held the turn beyond the command (`duration_ms`
minus that value), grouped by the time since the Keeper's previous call that used the cache.
A call that found the cache full should cost close to nothing, and a call that ran a pass should
not. `slow_calls` are those with 0.5 s or more of overhead.

Usage:
    python3 docs/evidence/tool-efficiency-before-after-2026-11/replay_preflight_ttl.py \
        --base-path ~/me --since 2026-11-07T18:29:19 --end 2026-11-08T14:08:00 \
        --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-preflight-replay-2026-11-07_11-08.json
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import sys
from collections import Counter
from collections.abc import Sequence
from typing import cast

import measure_before_after as ledger

REMOTE_SSH = "remote_ssh"
READER_TOOLS = ("Read", "Grep", "Glob")
WRITER_TOOLS = ("Edit", "Write")
DEFAULT_READ_TTLS = (60, 120, 300, 600, 1800)
DEFAULT_WRITE_TTL_S = 60.0
DEFAULT_WARMUP_HOURS = 2.0
GAP_BUCKETS_S = ((10.0, "0-10s"), (30.0, "10-30s"), (60.0, "30-60s"), (120.0, "60-120s"), (600.0, "120-600s"))
LAST_GAP_BUCKET = "600s+"


def access_of(call: ledger.Call) -> str | None:
    """`read` or `write` for a call that goes through the preflight cache, else None."""
    if call.sandbox != REMOTE_SSH:
        return None
    if call.tool in WRITER_TOOLS:
        return "write"
    if call.tool in READER_TOOLS:
        return "read"
    if call.tool == ledger.EXECUTE:
        return "write" if ledger.intent_of(call.input_text) == "request_effect" else "read"
    return None


def started_at(call: ledger.Call) -> float:
    return call.ts - call.duration_ms / 1000


def replay(calls: Sequence[ledger.Call], since: float, read_ttl_s: float, write_ttl_s: float) -> dict[str, int]:
    """The passes run by calls that ended at or after `since`, by the class of the call that ran them."""
    newest: dict[str, float] = {}
    passes: Counter[str] = Counter()
    for call in sorted(calls, key=lambda each: (each.keeper, started_at(each))):
        access = access_of(call)
        if access is None:
            continue
        start = started_at(call)
        lifetime = write_ttl_s if access == "write" else read_ttl_s
        last = newest.get(call.keeper)
        if last is not None and start - last < lifetime:
            continue
        newest[call.keeper] = start
        if call.ts >= since:
            passes[access] += 1
    return {"read": passes["read"], "write": passes["write"], "total": passes["read"] + passes["write"]}


def gap_bucket(gap_s: float) -> str:
    for upper, label in GAP_BUCKETS_S:
        if gap_s < upper:
            return label
    return LAST_GAP_BUCKET


def overhead_by_gap(calls: Sequence[ledger.Call], since: float) -> dict[str, dict[str, object]]:
    """Overhead of successful Execute calls that ended at or after `since`, by the gap before them."""
    previous_start: dict[str, float] = {}
    overhead_ms: dict[str, list[float]] = {}
    for call in sorted(calls, key=lambda each: (each.keeper, started_at(each))):
        if access_of(call) is None:
            continue
        start = started_at(call)
        previous = previous_start.get(call.keeper)
        previous_start[call.keeper] = start
        if previous is None or call.ts < since or call.failed or call.tool != ledger.EXECUTE:
            continue
        run = ledger.execution_time_ms_of(call.output_text)
        if run is not None:
            overhead_ms.setdefault(gap_bucket(start - previous), []).append(call.duration_ms - run)
    labels = [label for _, label in GAP_BUCKETS_S] + [LAST_GAP_BUCKET]
    result: dict[str, dict[str, object]] = {}
    for label in labels:
        values = sorted(overhead_ms.get(label, []))
        if values:
            result[label] = {
                "calls": len(values),
                "overhead_p50_s": round(values[len(values) // 2] / 1000, 3),
                "overhead_mean_s": round(sum(values) / len(values) / 1000, 2),
                "slow_calls": sum(1 for value in values if value >= ledger.OVERHEAD_SLOW_MS),
                "overhead_hours": ledger.hours(sum(values)),
            }
    return result


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", required=True, help="UTC, like 2026-11-07T18:29:19")
    parser.add_argument("--end", required=True, help="UTC, like 2026-11-08T14:08:00")
    parser.add_argument("--warmup-hours", type=float, default=DEFAULT_WARMUP_HOURS)
    parser.add_argument("--read-ttls", type=int, nargs="+", default=list(DEFAULT_READ_TTLS))
    parser.add_argument("--write-ttl", type=float, default=DEFAULT_WRITE_TTL_S)
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    since = ledger.parse_instant(cast("str", args.since))
    end = ledger.parse_instant(cast("str", args.end))
    warmup = cast("float", args.warmup_hours)
    if end <= since or warmup < 0:
        print("--end must come after --since and --warmup-hours must not be negative", file=sys.stderr)
        return 2
    first = since - datetime.timedelta(hours=warmup)
    if end - first > datetime.timedelta(days=ledger.MAX_DAYS):
        print(f"the span must stay within {ledger.MAX_DAYS} days", file=sys.stderr)
        return 2
    base = cast("pathlib.Path", args.base_path).expanduser()
    skipped = ledger.Skipped()
    paths = ledger.ledger_files(base, first, end)
    calls = list(ledger.read_calls(paths, first.timestamp(), end.timestamp(), skipped))
    in_window = [call for call in calls if call.ts >= since.timestamp() and access_of(call) is not None]
    write_ttl = cast("float", args.write_ttl)
    rows = [
        {"read_ttl_s": ttl, "write_ttl_s": write_ttl, **replay(calls, since.timestamp(), float(ttl), write_ttl)}
        for ttl in cast("list[int]", args.read_ttls)
    ]
    result: dict[str, object] = {
        "window": [ledger.stamp(since.timestamp()), ledger.stamp(end.timestamp())],
        "warmup_hours": warmup,
        "files": len(paths),
        "skipped": {"bad_lines": skipped.bad_lines},
        "remote_ssh_calls": {
            "total": len(in_window),
            "read": sum(1 for call in in_window if access_of(call) == "read"),
            "write": sum(1 for call in in_window if access_of(call) == "write"),
        },
        "passes": rows,
        "overhead_by_gap": overhead_by_gap(calls, since.timestamp()),
    }
    out = cast("pathlib.Path | None", args.json_out)
    if out is not None:
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
