#!/usr/bin/env python3
"""Pair the output of `scan_args old` with `scan_args new` and print the
registrations whose with_* chains differ.

usage: compare_args.py OLD.tsv NEW.tsv

A chain is the helpers that enclose one another, outermost first, so a change of
order or of how often a helper runs shows as a difference. Rows are paired by file,
function and path text, not by position: the two scans list the files in different
orders. Registrations with a variable path can share a key, so the chains of one key
are compared as sorted lists.

Exits 1 when a key exists on one side only. A chain that differs is printed and does
not change the exit code: each one needs a reason, which the README gives.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from pathlib import Path

Key = tuple[str, str, str]


def load(path: Path) -> dict[Key, list[str]]:
    table: dict[Key, list[str]] = defaultdict(list)
    for line in path.read_text(encoding="utf-8").splitlines():
        file, function, path_text, wrappers = line.split("\t")
        table[(file, function, path_text)].append(wrappers)
    return table


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("old", type=Path)
    ap.add_argument("new", type=Path)
    args = ap.parse_args()

    old, new = load(args.old), load(args.new)
    unpaired = sorted(set(old) ^ set(new))
    for key in unpaired:
        print(f"only on one side: {key}")

    same = 0
    differ = 0
    for key in sorted(set(old) & set(new)):
        before, after = sorted(old[key]), sorted(new[key])
        if before == after:
            same += len(before)
            continue
        differ += len(before)
        print(f"{key[0]} {key[1]} {key[2]}\n    old: {before}\n    new: {after}")
    print(f"{same} registrations with the same chains, {differ} with different ones")
    return 1 if unpaired else 0


if __name__ == "__main__":
    raise SystemExit(main())
