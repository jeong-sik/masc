#!/usr/bin/env python3
"""Report keeper_memory_search misses from Keeper decision logs.

Reads every ``<keeper>.decisions.jsonl`` (and its rotations ``.1``, ``.2`` ...)
in a keepers runtime directory, keeps the ``event = "memory_search"`` lines,
and prints per Keeper and source how many searches found nothing (a miss
while some store could not be read is counted apart), and per
Keeper how many searches a turn (``turn_ref``) makes.

With ``--replay-out`` it also writes the replay set of
RFC-memory-search-beyond-substring section 3.0: one JSON line per search that
found nothing, with the same Keeper's next search when that one found
something. A miss followed by a hit is the cheapest evidence of a memory the
first wording could not reach; whether the two searches ask for the same thing
is for a reader to label, so the pair is reported as it happened.

Read-only. The keepers directory is an argument; nothing is assumed about
where ``<base-path>/.masc`` lives.

Usage:
    python3 scripts/memory-search-miss-report.py <keepers-dir>
    python3 scripts/memory-search-miss-report.py <keepers-dir> --replay-out misses.jsonl
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

SUFFIX = ".decisions.jsonl"


def keeper_of(path: Path):
    name = path.name
    index = name.find(SUFFIX)
    if index <= 0:
        return None
    rest = name[index + len(SUFFIX):]
    if rest == "" or (rest.startswith(".") and rest[1:].isdigit()):
        return name[:index]
    return None


def read_searches(keepers_dir: Path):
    searches = defaultdict(list)
    unreadable = 0
    for path in sorted(keepers_dir.iterdir()):
        keeper = keeper_of(path)
        if keeper is None or not path.is_file():
            continue
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    unreadable += 1
                    continue
                if not isinstance(row, dict) or row.get("event") != "memory_search":
                    continue
                if not isinstance(row.get("match_count"), int):
                    unreadable += 1
                    continue
                searches[keeper].append(row)
    for rows in searches.values():
        rows.sort(key=lambda row: row.get("ts_unix") or 0.0)
    return searches, unreadable


def partial_read(row):
    """A search that could not read some store or history file.

    Its miss is not one better ranking can answer, so it is counted apart and
    left out of the replay set.
    """
    return row.get("read_errors") is True


def summary(searches):
    table = defaultdict(lambda: [0, 0, 0])
    for keeper, rows in searches.items():
        for row in rows:
            cell = table[(keeper, row.get("source", "?"))]
            cell[0] += 1
            if row["match_count"] == 0:
                cell[2 if partial_read(row) else 1] += 1
    return table


def searches_per_turn(searches):
    """Searches grouped by the turn (turn_ref) that made them, per Keeper.

    Lines without turn_ref (older lines, calls outside a Keeper turn) are not
    counted.
    """
    per_keeper = {}
    for keeper, rows in searches.items():
        turns = defaultdict(int)
        for row in rows:
            turn_ref = row.get("turn_ref")
            if isinstance(turn_ref, str) and turn_ref:
                turns[turn_ref] += 1
        if turns:
            per_keeper[keeper] = sorted(turns.values())
    return per_keeper


def replay_rows(searches):
    for keeper, rows in searches.items():
        for index, row in enumerate(rows):
            if row["match_count"] != 0 or partial_read(row):
                continue
            following = rows[index + 1] if index + 1 < len(rows) else None
            followed_by_hit = following is not None and following["match_count"] > 0
            yield {
                "keeper": keeper,
                "ts_unix": row.get("ts_unix"),
                "query": row.get("query"),
                "source": row.get("source"),
                "durable_candidates": row.get("durable_candidates"),
                "next_search": (
                    {
                        "ts_unix": following.get("ts_unix"),
                        "query": following.get("query"),
                        "source": following.get("source"),
                        "matched_memory_ids": following.get("matched_memory_ids", []),
                    }
                    if followed_by_hit
                    else None
                ),
            }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("keepers_dir", type=Path, help="keepers runtime directory")
    parser.add_argument("--replay-out", type=Path, help="write the miss replay set here")
    args = parser.parse_args()

    if not args.keepers_dir.is_dir():
        print(f"not a directory: {args.keepers_dir}", file=sys.stderr)
        return 2

    searches, unreadable = read_searches(args.keepers_dir)
    table = summary(searches)
    total = sum(cell[0] for cell in table.values())
    misses = sum(cell[1] for cell in table.values())
    partial = sum(cell[2] for cell in table.values())

    header = f"{'keeper':<40} {'source':<10} {'searches':>9} {'no_match':>9} {'share':>7} {'partial':>8}"
    print(header)
    for (keeper, source), (count, miss, part) in sorted(table.items()):
        print(f"{keeper:<40} {source:<10} {count:>9} {miss:>9} {miss / count:>7.1%} {part:>8}")
    if total:
        print(f"{'all':<40} {'':<10} {total:>9} {misses:>9} {misses / total:>7.1%} {partial:>8}")
        print("partial = found nothing while a store could not be read (not in the replay set)")
    else:
        print("no memory_search lines found")
    per_turn = searches_per_turn(searches)
    if per_turn:
        print()
        print(f"{'keeper':<40} {'turns':>7} {'median':>7} {'p90':>5} {'max':>5}  searches per turn")
        for keeper, counts in sorted(per_turn.items()):
            median = counts[len(counts) // 2]
            p90 = counts[min(len(counts) - 1, (len(counts) * 9) // 10)]
            print(f"{keeper:<40} {len(counts):>7} {median:>7} {p90:>5} {counts[-1]:>5}")
    if unreadable:
        print(f"unreadable decision-log lines skipped: {unreadable}", file=sys.stderr)

    if args.replay_out:
        rows = list(replay_rows(searches))
        with args.replay_out.open("w", encoding="utf-8") as out:
            for row in rows:
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
        followed = sum(1 for row in rows if row["next_search"] is not None)
        print(
            f"replay set: {len(rows)} misses, {followed} followed by a hit -> {args.replay_out}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
