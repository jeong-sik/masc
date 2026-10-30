#!/usr/bin/env python3
"""Seed a synthetic MASC telemetry store for the request-cost harness.

The request-cost defect (a single unbounded dashboard read materialising the
whole store in the heap) is invisible on an empty store: with little data the
full scan is fast. Reproducing it deterministically therefore needs a store of
a known shape, which is what this script writes.

Layout mirrors the production reader contract:

    <root>/keepers/<name>/metrics/YYYY-MM/DD.jsonl   per-keeper fan-out source
    <root>/telemetry/YYYY-MM/DD.jsonl                Agent_event
    <root>/tool_calls/YYYY-MM/DD.jsonl               Tool_call_io
    <root>/tool_usage/YYYY-MM/DD.jsonl               Tool_usage
    <root>/agent-core-events/YYYY-MM/DD.jsonl        Agent_core_event

Entries carry the field names the reader extracts (`ts`, `ts_unix`, `name`,
`session_id`, `operation_id`) so timestamp extraction and scope filtering do
the same work they do in production, plus filler to reach a realistic line
size.

The keeper count is a parameter because the per-request cost is expected to
scale with it: the scan cap in the reader is per-store, not per-request, so
doubling `--keepers` doubles the entries one request can materialise. A run at
two keeper counts measures that directly.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Fixed-path sources the unified reader scans in addition to the per-keeper
# fan-out. Names match `telemetry_unified_source_meta.fixed_store_dir`.
FIXED_SOURCES: tuple[str, ...] = (
    "telemetry",
    "tool_calls",
    "tool_usage",
    "agent-core-events",
)

# Padding target per JSONL line. Production keeper.metrics.v1 rows run several
# hundred bytes; a too-small row would understate parse and heap cost.
TARGET_LINE_BYTES = 520

# Deterministic epoch for generated timestamps. Fixed (not `now`) so two runs
# of the harness produce byte-identical stores and results stay comparable.
BASE_EPOCH = datetime(2026, 8, 1, tzinfo=timezone.utc)


@dataclass(frozen=True, slots=True)
class SeedPlan:
    root: Path
    keepers: int
    entries_per_store: int
    days: int


def _entry(index: int, source: str, keeper: str, ts: datetime) -> str:
    """One JSONL row shaped like the rows the reader parses."""
    record: dict[str, object] = {
        "schema": f"masc.harness.{source}.v1",
        "record_kind": "turn",
        "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ts_unix": ts.timestamp(),
        "name": keeper,
        "agent_name": f"keeper-{keeper}-agent",
        "session_id": f"harness-session-{index % 32}",
        "operation_id": f"harness-op-{index}",
        "trace_id": f"harness-trace-{index // 128}",
        "channel": "scheduled_autonomous",
        "generation": 1,
        "index": index,
    }
    # Pad to a realistic line width so parse cost per entry is representative.
    encoded = json.dumps(record, separators=(",", ":"))
    deficit = TARGET_LINE_BYTES - len(encoded) - len('"filler":"",')
    if deficit > 0:
        record["filler"] = "x" * deficit
        encoded = json.dumps(record, separators=(",", ":"))
    return encoded


def _write_store(store_dir: Path, source: str, keeper: str, plan: SeedPlan) -> int:
    """Write one dated store; returns the number of entries written."""
    per_day = max(1, plan.entries_per_store // plan.days)
    written = 0
    for day_offset in range(plan.days):
        day = BASE_EPOCH + timedelta(days=day_offset)
        day_dir = store_dir / day.strftime("%Y-%m")
        day_dir.mkdir(parents=True, exist_ok=True)
        target = day_dir / f"{day.strftime('%d')}.jsonl"
        remaining = plan.entries_per_store - written
        count = min(per_day, remaining) if day_offset < plan.days - 1 else remaining
        if count <= 0:
            break
        with target.open("w", encoding="utf-8") as handle:
            for i in range(count):
                ts = day + timedelta(seconds=i % 86_400)
                handle.write(_entry(written + i, source, keeper, ts))
                handle.write("\n")
        written += count
    return written


def seed(plan: SeedPlan) -> dict[str, object]:
    stores = 0
    entries = 0

    for k in range(plan.keepers):
        keeper = f"harness-keeper-{k:02d}"
        store = plan.root / "keepers" / keeper / "metrics"
        entries += _write_store(store, "keeper_metric", keeper, plan)
        stores += 1

    for source in FIXED_SOURCES:
        store = plan.root / source
        entries += _write_store(store, source, "harness-fixed", plan)
        stores += 1

    total_bytes = sum(p.stat().st_size for p in plan.root.rglob("*.jsonl"))
    return {
        "root": str(plan.root),
        "keepers": plan.keepers,
        "stores": stores,
        "entries": entries,
        "bytes": total_bytes,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path,
                        help="masc root to seed (created if absent)")
    parser.add_argument("--keepers", type=int, default=8,
                        help="per-keeper fan-out stores to create (default: 8)")
    parser.add_argument("--entries-per-store", type=int, default=20_000,
                        help="entries written per store (default: 20000)")
    parser.add_argument("--days", type=int, default=4,
                        help="dated partitions to spread entries across (default: 4)")
    args = parser.parse_args(argv)

    if args.keepers < 1 or args.entries_per_store < 1 or args.days < 1:
        print("ERROR: --keepers, --entries-per-store and --days must be >= 1",
              file=sys.stderr)
        return 1

    plan = SeedPlan(
        root=args.root,
        keepers=args.keepers,
        entries_per_store=args.entries_per_store,
        days=args.days,
    )
    plan.root.mkdir(parents=True, exist_ok=True)
    print(json.dumps(seed(plan)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
