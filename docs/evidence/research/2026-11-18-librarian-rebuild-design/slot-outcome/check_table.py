#!/usr/bin/env python3
"""Check the slot-outcome table against the constructors extracted from the code.

Usage: check_table.py constructors.tsv table.tsv
Fails when a constructor has no row, a row names no constructor, a constructor
has two rows that are not told apart by a case, an outcome is not one of the
allowed values, a "> type" row points at a type with no rows, or a type is not
reachable from a root.
"""
import csv
import sys
from collections import defaultdict
from pathlib import PurePosixPath

OUTCOMES = frozenset(
    {
        "Refused (Sized Input_too_large)",
        "Refused (Sized Output_over_reserve)",
        "Refused (Sized Window_reached)",
        "Refused Unsized",
        "Silent Not_called",
        "Silent Unavailable",
        "Silent Busy",
        "Silent Lost",
        "Silent (Unusable Not_json)",
        "Silent (Unusable Schema_violation)",
        "Silent (Unusable Echo_mismatch)",
        "Silent (Unusable Empty_or_partial)",
    }
)
ROOTS = (
    ("exact_output.mli", "candidate_rejection_disposition"),
    ("exact_output.mli", "execution_error_cause"),
    ("keeper_lane_cli_oneshot.mli", "failure"),
)


def main() -> int:
    extracted_path, table_path = sys.argv[1], sys.argv[2]
    extracted: set[tuple[str, str, str]] = set()
    with open(extracted_path, encoding="utf-8") as handle:
        for path, type_name, constructor in csv.reader(handle, delimiter="\t"):
            extracted.add((PurePosixPath(path).name, type_name, constructor))
    rows: dict[tuple[str, str, str], list[tuple[str, str]]] = defaultdict(list)
    with open(table_path, encoding="utf-8") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            key = (row["file"], row["type"], row["constructor"])
            rows[key].append((row["case"], row["outcome"]))
    errors: list[str] = []
    for key in sorted(extracted - set(rows)):
        errors.append(f"no row: {key}")
    for key in sorted(set(rows) - extracted):
        errors.append(f"row names no constructor: {key}")
    types = {(file, type_name) for file, type_name, _ in extracted}
    edges: dict[tuple[str, str], set[tuple[str, str]]] = defaultdict(set)
    counts: dict[str, int] = defaultdict(int)
    for key, cases in rows.items():
        names = [case for case, _ in cases]
        if len(cases) == 1 and names != ["-"]:
            errors.append(f"one row with a case: {key}")
        if len(cases) > 1 and ("-" in names or len(set(names)) != len(names)):
            errors.append(f"rows not told apart: {key}")
        for _, outcome in cases:
            if outcome.startswith("> "):
                file, type_name = outcome[2:].split(" ", 1)
                target = (file, type_name)
                if target not in types:
                    errors.append(f"points at a type with no rows: {key} -> {target}")
                edges[(key[0], key[1])].add(target)
            elif outcome in OUTCOMES:
                counts[outcome] += 1
            else:
                errors.append(f"unknown outcome: {key} {outcome}")
    seen: set[tuple[str, str]] = set()
    stack = list(ROOTS)
    while stack:
        node = stack.pop()
        if node in seen:
            continue
        seen.add(node)
        stack.extend(edges[node])
    for node in sorted(types - seen):
        errors.append(f"type not reachable from a root: {node}")
    for error in errors:
        print(error)
    print(f"constructors {len(extracted)}, rows {sum(len(v) for v in rows.values())}, types {len(types)}")
    for outcome in sorted(counts):
        print(f"{counts[outcome]:4d}  {outcome}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
