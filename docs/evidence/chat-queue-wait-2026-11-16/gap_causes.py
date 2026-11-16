"""Split the idle-without-turn intervals from chat_queue_split.py --gaps-out by declared causes.

Each cause is a window read from the server log, given on the command line with the Keepers it
covers ("*" for all). A second of a gap goes to the first cause, in argument order, whose window
and Keeper list contain it. What no cause covers is reported as the remainder.

Usage: gap_causes.py <gaps.jsonl> [--cause NAME KEEPERS START_UTC END_UTC]...
  KEEPERS is "*" or a comma list. START_UTC and END_UTC look like 2026-11-15T13:43:51Z.
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import sys

HOUR = 3600.0
PRINT_DIGITS = 3

type Interval = tuple[float, float]


def epoch(text: str) -> float:
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()


def cut(gap: Interval, window: Interval) -> tuple[Interval | None, list[Interval]]:
    lo, hi = max(gap[0], window[0]), min(gap[1], window[1])
    if hi <= lo:
        return None, [gap]
    rest = [iv for iv in ((gap[0], lo), (hi, gap[1])) if iv[1] > iv[0]]
    return (lo, hi), rest


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("gaps", type=pathlib.Path)
    parser.add_argument("--cause", nargs=4, action="append", default=[], metavar=("NAME", "KEEPERS", "START", "END"))
    args = parser.parse_args(argv)
    left: list[tuple[str, Interval]] = []
    for line in args.gaps.read_text().splitlines():
        row = json.loads(line)
        left.append((str(row["keeper"]), (float(row["start"]), float(row["end"]))))
    total = sum(b - a for _, (a, b) in left)
    causes: dict[str, dict[str, object]] = {}
    for name, keepers, start, end in args.cause:
        window = (epoch(start), epoch(end))
        covered = keepers.split(",")
        taken = 0.0
        per_keeper: dict[str, float] = {}
        rest: list[tuple[str, Interval]] = []
        for keeper, gap in left:
            if keepers != "*" and keeper not in covered:
                rest.append((keeper, gap))
                continue
            hit, remaining = cut(gap, window)
            if hit is not None:
                taken += hit[1] - hit[0]
                per_keeper[keeper] = per_keeper.get(keeper, 0.0) + (hit[1] - hit[0])
            rest.extend((keeper, iv) for iv in remaining)
        left = rest
        causes[name] = {
            "window": [start, end],
            "keepers": keepers,
            "hours": round(taken / HOUR, PRINT_DIGITS),
            "per_keeper_h": {k: round(v / HOUR, PRINT_DIGITS) for k, v in sorted(per_keeper.items())},
        }
    out = {
        "gaps_h": round(total / HOUR, PRINT_DIGITS),
        "causes": causes,
        "remainder_h": round(sum(b - a for _, (a, b) in left) / HOUR, PRINT_DIGITS),
        "remainder_intervals": len(left),
    }
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
