#!/usr/bin/env python3
"""Compare two runs of the auth baseline (plan layer A1), taken before and after a change.

Each directory holds `default/` and `strict/` with the `results.json` and
`extra.json` that `run.sh` writes. A route probe is keyed by method, route path and
probed path. The router can register a path twice and the later registration is the
one that answers, so rows with the same key collapse to the last one. The
`WWW-Authenticate` challenge names the server's own address, which differs per run,
so the port is blanked before comparing.

Exits 1 when a status differs, a probe exists on one side only, or a run lost its
server part-way (every later probe would read 0 and look equal).
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

MODES = ("default", "strict")
STATUS_FIELDS = ("http1_none", "http1_bad", "h2_none", "h2_bad")
SERVER_ADDRESS = re.compile(r"127\.0\.0\.1:\d+")

ProbeKey = tuple[str, str, str]
Statuses = tuple[int, ...]
ExtraKey = tuple[str, str, str]
ExtraView = tuple[int, str]


def load_results(directory: Path, mode: str) -> tuple[dict[ProbeKey, Statuses], list[str]]:
    data = json.loads((directory / mode / "results.json").read_text(encoding="utf-8"))
    table: dict[ProbeKey, Statuses] = {}
    for row in data["rows"]:
        key = (row["method"], row["route_path"], row["probed_path"])
        table[key] = tuple(int(row[field]) for field in STATUS_FIELDS)
    return table, list(data["server_stopped_at"])


def load_extra(directory: Path, mode: str) -> tuple[dict[ExtraKey, ExtraView], object]:
    data = json.loads((directory / mode / "extra.json").read_text(encoding="utf-8"))
    table: dict[ExtraKey, ExtraView] = {}
    for row in data["rows"]:
        challenge = SERVER_ADDRESS.sub("127.0.0.1:PORT", row.get("www_authenticate") or "")
        table[(row["case"], row["protocol"], row["credential"])] = (int(row["status"]), challenge)
    return table, data.get("dev_token")


def compare_routes(
    before_dir: Path, after_dir: Path, mode: str, csv_rows: list[list[object]]
) -> tuple[int, int]:
    """Print what differs in one mode. Returns (probes compared, problems found)."""
    before, before_stopped = load_results(before_dir, mode)
    after, after_stopped = load_results(after_dir, mode)
    problems = 0
    for side, stopped in (("before", before_stopped), ("after", after_stopped)):
        if stopped:
            problems += 1
            print(f"[{mode}] {side}: the server stopped at {stopped[:3]}")
    for key in sorted(set(before) - set(after)):
        problems += 1
        print(f"[{mode}] only before: {key}")
    for key in sorted(set(after) - set(before)):
        problems += 1
        print(f"[{mode}] only after:  {key}")
    shared = sorted(set(before) & set(after))
    for key in shared:
        csv_rows.append([mode, *key, *before[key], *after[key]])
        if before[key] != after[key]:
            problems += 1
            print(f"[{mode}] {key[0]:6s} {key[1]:52s} before={before[key]} after={after[key]}")
    print(f"[{mode}] route probes: {len(before)} before, {len(after)} after, {len(shared)} shared")
    return len(shared) * len(STATUS_FIELDS), problems


def compare_extra(before_dir: Path, after_dir: Path, mode: str) -> tuple[int, int]:
    """Print what differs in the cases outside the router table. Returns (cases, problems)."""
    before, before_dev = load_extra(before_dir, mode)
    after, after_dev = load_extra(after_dir, mode)
    problems = 0
    for key in sorted(set(before) | set(after)):
        if before.get(key) != after.get(key):
            problems += 1
            print(f"[{mode}] extra {key} before={before.get(key)} after={after.get(key)}")
    if before_dev != after_dev:
        problems += 1
        print(f"[{mode}] dev-token probe differs: {before_dev} vs {after_dev}")
    print(f"[{mode}] extra cases: {len(before)} before, {len(after)} after")
    return len(set(before) & set(after)), problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("before", type=Path, help="out-dir of the run before the change")
    ap.add_argument("after", type=Path, help="out-dir of the run after the change")
    ap.add_argument("--csv", type=Path, help="write every route probe of both runs here")
    args = ap.parse_args()

    csv_rows: list[list[object]] = []
    compared = 0
    problems = 0
    for mode in MODES:
        route_count, route_problems = compare_routes(args.before, args.after, mode, csv_rows)
        extra_count, extra_problems = compare_extra(args.before, args.after, mode)
        compared += route_count + extra_count
        problems += route_problems + extra_problems
    print(f"compared {compared} statuses, {problems} problems")

    if args.csv is not None:
        with args.csv.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(
                ["mode", "method", "route_path", "probed_path"]
                + [f"before_{field}" for field in STATUS_FIELDS]
                + [f"after_{field}" for field in STATUS_FIELDS]
            )
            writer.writerows(csv_rows)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
