#!/usr/bin/env python3
"""Summarize exact keeper wake-payload component observations.

Consumes records emitted by [Dashboard_harness_health.record_wake_payload]
and prints per-keeper and overall distributions (p50, p95, max, mean) of
exact component byte counts and message/tool counts in TSV. Message bytes cover
content blocks only; tool bytes cover canonical schema JSON values only.

Usage:
    wake_payload_stats.py <path-to-jsonl> [<more> ...]
    cat <file>.jsonl | wake_payload_stats.py -

Only records with record_type=="wake_payload" are counted. Malformed
lines are skipped with a warning to stderr.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import defaultdict
from typing import Iterable, List, Sequence


NUMERIC_FIELDS = (
    "system_prompt_bytes",
    "tool_schema_json_bytes",
    "message_content_bytes",
    "message_count",
    "tool_count",
)


def iter_records(paths: Sequence[str]) -> Iterable[dict]:
    for path in paths:
        if path == "-":
            source = sys.stdin
            close = False
        else:
            try:
                source = open(path, "r", encoding="utf-8")
                close = True
            except OSError as exc:
                print(f"[warn] cannot open {path!r}: {exc}", file=sys.stderr)
                continue
        try:
            for lineno, line in enumerate(source, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as exc:
                    print(
                        f"[warn] {path}:{lineno} skipped (JSONDecodeError: {exc})",
                        file=sys.stderr,
                    )
                    continue
                if not isinstance(record, dict):
                    continue
                if record.get("record_type") != "wake_payload":
                    continue
                yield record
        finally:
            if close:
                source.close()


def percentile(values: List[int], p: float) -> int:
    """Nearest-rank percentile for integer samples. Returns 0 for empty."""
    if not values:
        return 0
    sorted_vals = sorted(values)
    rank = max(1, min(len(sorted_vals), int(round(p / 100.0 * len(sorted_vals)))))
    return sorted_vals[rank - 1]


def summarize(name: str, records: List[dict]) -> List[str]:
    n = len(records)
    row = [name, str(n)]
    for field in NUMERIC_FIELDS:
        vals = [int(r.get(field, 0)) for r in records]
        if not vals:
            row += ["0", "0", "0", "0"]
            continue
        row += [
            str(percentile(vals, 50)),
            str(percentile(vals, 95)),
            str(max(vals)),
            str(int(statistics.mean(vals))),
        ]
    return row


def average_role_counts(records: List[dict]) -> dict[str, float]:
    """Compute mean of each role's count across all records."""
    totals: dict[str, int] = defaultdict(int)
    for r in records:
        counts = r.get("role_counts") or {}
        if isinstance(counts, dict):
            for role, n in counts.items():
                try:
                    totals[role] += int(n)
                except (TypeError, ValueError):
                    pass
    if not records:
        return {}
    return {role: total / len(records) for role, total in totals.items()}


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Summarize exact keeper wake-payload component observations.",
    )
    parser.add_argument(
        "paths",
        nargs="+",
        help="JSONL files to analyze. Use '-' to read from stdin.",
    )
    parser.add_argument(
        "--roles",
        action="store_true",
        help="Also print mean role_counts distribution per keeper.",
    )
    args = parser.parse_args(argv)

    records = list(iter_records(args.paths))
    if not records:
        print("[warn] no wake_payload records found", file=sys.stderr)
        return 1

    by_keeper: dict[str, List[dict]] = defaultdict(list)
    for r in records:
        keeper = r.get("keeper_name") or "(unknown)"
        by_keeper[keeper].append(r)

    header = ["keeper", "n"]
    for field in NUMERIC_FIELDS:
        header += [f"{field}_p50", f"{field}_p95", f"{field}_max", f"{field}_mean"]
    print("\t".join(header))

    for keeper in sorted(by_keeper):
        print("\t".join(summarize(keeper, by_keeper[keeper])))
    print("\t".join(summarize("(all)", records)))

    if args.roles:
        print()
        print("# role_counts mean per keeper")
        print("\t".join(["keeper", "system", "user", "assistant", "tool"]))
        for keeper in sorted(by_keeper):
            avgs = average_role_counts(by_keeper[keeper])
            row = [keeper]
            for role in ("system", "user", "assistant", "tool"):
                row.append(f"{avgs.get(role, 0.0):.2f}")
            print("\t".join(row))
        avgs_all = average_role_counts(records)
        row_all = ["(all)"]
        for role in ("system", "user", "assistant", "tool"):
            row_all.append(f"{avgs_all.get(role, 0.0):.2f}")
        print("\t".join(row_all))

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
