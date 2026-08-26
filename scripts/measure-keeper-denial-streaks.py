#!/usr/bin/env python3
"""Count how often a keeper retries the same denied thing.

Turning containment on for a keeper can fail two ways, and they need different
answers. The policy can be too narrow, which shows up as a keeper asking for the
same path over and over; or the work simply moved, which shows up as fewer turns
finishing. This measures both.

Why streaks rather than error text: a denial does not always announce itself. On
this machine `sed -i` reports a blocked write as "No such file or directory",
because it stats before it writes. A keeper reading that concludes the file needs
creating and tries again. Classifying failures by their message would miss it and
would put a string matcher where a boundary belongs -- so the signal here is an
integer, the number of consecutive identical (tool, target) failures, and nothing
reads the message at all.

Falsification is the second half. A run with zero denials is not a pass if the
keeper also stopped finishing turns; --window lets the same command describe the
period before the change so the two can be compared.

Usage:
    scripts/measure-keeper-denial-streaks.py --keeper sangsu --window 24
    scripts/measure-keeper-denial-streaks.py --window 24        # every keeper
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections import Counter
from pathlib import Path

DEFAULT_BASE = Path(os.environ.get("MASC_BASE_PATH", Path.home() / "me"))

# A tool call that produced no result and reported an error. The receipt shape is
# the same across tools, so nothing here is tool-specific.
def failed(record: dict) -> bool:
    if record.get("error"):
        return True
    radius = record.get("action_radius") or {}
    return radius.get("success") is False


def target_of(record: dict) -> str:
    """What the call was aimed at, as the record already states it.

    Deliberately not parsed out of a command string: the point is to group
    retries of the same ask, and the args the runtime logged are that ask.
    """
    args = record.get("args") or {}
    for key in ("path", "file_path", "cwd", "target"):
        value = args.get(key)
        if isinstance(value, str) and value:
            return f"{key}={value}"
    radius = record.get("action_radius") or {}
    key = radius.get("action_key")
    return f"action_key={key}" if key else "(no target in record)"


def scan(trajectory_dir: Path, since: float):
    """Streaks and turn count for one keeper."""
    streaks: Counter[str] = Counter()
    current_key: str | None = None
    current_run = 0
    longest: dict[str, int] = {}
    turns = set()
    failures = 0

    files = sorted(
        (p for p in trajectory_dir.glob("*.jsonl") if p.stat().st_mtime >= since),
        key=lambda p: p.stat().st_mtime,
    )
    for path in files:
        with path.open(errors="replace") as handle:
            for line in handle:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                contract = record.get("runtime_contract") or {}
                turn = contract.get("keeper_turn_id")
                if turn is not None:
                    turns.add((path.name, turn))
                if not failed(record):
                    # A success breaks the streak: that is what distinguishes a
                    # keeper working around a denial from one stuck on it.
                    current_key, current_run = None, 0
                    continue
                failures += 1
                key = f"{record.get('tool_name')} {target_of(record)}"
                streaks[key] += 1
                if key == current_key:
                    current_run += 1
                else:
                    current_key, current_run = key, 1
                longest[key] = max(longest.get(key, 0), current_run)
    return streaks, longest, len(turns), failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=str(DEFAULT_BASE))
    parser.add_argument("--keeper", action="append", default=[])
    parser.add_argument("--window", type=float, default=24.0, help="hours")
    parser.add_argument("--top", type=int, default=5)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    root = Path(args.base) / ".masc" / "trajectories"
    if not root.is_dir():
        print(f"no trajectories under {root}", file=sys.stderr)
        return 2

    since = time.time() - args.window * 3600.0
    wanted = set(args.keeper)
    report = []

    for keeper_dir in sorted(root.iterdir()):
        if not keeper_dir.is_dir():
            continue
        if wanted and keeper_dir.name not in wanted:
            continue
        streaks, longest, turns, failures = scan(keeper_dir, since)
        if not streaks and turns == 0:
            continue
        worst = sorted(longest.items(), key=lambda kv: -kv[1])[: args.top]
        report.append(
            {
                "keeper": keeper_dir.name,
                "turns": turns,
                "failures": failures,
                "longest_streak": worst[0][1] if worst else 0,
                "worst": [{"ask": k, "streak": v, "total": streaks[k]} for k, v in worst],
            }
        )

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0

    if not report:
        print(f"no activity in the last {args.window:g}h")
        return 0

    print(f"window: last {args.window:g}h")
    print(f"{'keeper':<28}{'turns':>7}{'failures':>10}{'longest streak':>16}")
    for row in sorted(report, key=lambda r: -r["longest_streak"]):
        print(
            f"{row['keeper']:<28}{row['turns']:>7}{row['failures']:>10}"
            f"{row['longest_streak']:>16}"
        )
    for row in sorted(report, key=lambda r: -r["longest_streak"]):
        if row["longest_streak"] < 2:
            continue
        print(f"\n{row['keeper']} — repeated asks")
        for item in row["worst"]:
            if item["streak"] < 2:
                continue
            print(f"  x{item['streak']:<4} (total {item['total']:<5}) {item['ask'][:96]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
