#!/usr/bin/env python3
"""Report wall-clock tool spans from immutable JSONL trace snapshots.

These spans include the trace boundary's tool/hook work, not model inference or
client transport. They are not monotonic-clock or deployed-binary attestations.
No tool arguments, results, or assistant text are copied into the report.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def collect(path):
    raw = path.read_bytes()
    starts, finishes, rows = {}, set(), []
    orphan_finishes = 0
    for line_number, line in enumerate(raw.splitlines(), 1):
        event = json.loads(line)
        kind = event.get("record_type")
        if kind not in ("tool_execution_started", "tool_execution_finished"):
            continue
        worker, call, tool = (event.get(k) for k in
                              ("worker_run_id", "tool_use_id", "tool_name"))
        if not all(isinstance(v, str) and v for v in (worker, call, tool)):
            raise ValueError(f"{path}:{line_number}: missing tool identity")
        ts = event.get("ts")
        if isinstance(ts, bool) or not isinstance(ts, (int, float)) or not math.isfinite(ts):
            raise ValueError(f"{path}:{line_number}: invalid timestamp")
        key = worker, call
        if kind == "tool_execution_started":
            if key in starts or key in finishes:
                raise ValueError(f"{path}:{line_number}: duplicate or late start")
            starts[key] = tool, ts
            continue
        if key in finishes:
            raise ValueError(f"{path}:{line_number}: duplicate finish")
        finishes.add(key)
        start = starts.pop(key, None)
        if start is None:
            orphan_finishes += 1
            continue
        if start[0] != tool:
            raise ValueError(f"{path}:{line_number}: tool identity changed")
        error = event.get("tool_error")
        outcome = "failed" if error is True else "succeeded" if error is False else "unknown"
        elapsed = (ts - start[1]) * 1000
        rows.append({"worker_run_id": worker, "tool_use_id": call,
                     "tool": tool, "outcome": outcome,
                     "wall_span_ms": elapsed if elapsed >= 0 else None,
                     "clock_regression": elapsed < 0})
    return {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
            "pending_starts": len(starts), "orphan_finishes": orphan_finishes,
            "rows": rows}


def report(paths):
    sources = [collect(path) for path in paths]
    identities = set()
    groups = {}
    for source in sources:
        for row in source["rows"]:
            identity = row["worker_run_id"], row["tool_use_id"]
            if identity in identities:
                raise ValueError("overlapping trace inputs contain the same tool call")
            identities.add(identity)
            groups.setdefault((row["tool"], row["outcome"]), []).append(row)
    summaries = []
    for (tool, outcome), rows in sorted(groups.items()):
        values = sorted(row["wall_span_ms"] for row in rows if row["wall_span_ms"] is not None)
        summaries.append({"tool": tool, "outcome": outcome, "paired": len(rows),
                          "valid_spans": len(values), "clock_regressions": len(rows) - len(values),
                          "p50_ms": values[math.ceil(len(values) * .5) - 1] if values else None,
                          "p95_ms": values[math.ceil(len(values) * .95) - 1] if values else None})
    return {"measurement": "wall-clock tool execution boundary span",
            "limitations": "Not monotonic timing, client latency, or binary identity proof; input snapshots may be incomplete.",
            "sources": sources, "summary": summaries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("traces", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = report(args.traces)
    args.output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
