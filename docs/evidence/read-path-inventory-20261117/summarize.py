#!/usr/bin/env python3
"""Summarize the read inventory TSVs into Markdown tables.

Inputs (same directory): code-read-sites.tsv, site-triggers.tsv,
route-reads.tsv, tui-paths.txt. Output: Markdown on stdout.

A site counts as content when its shape is not `meta` (stat/exists) and not
`open` (an open whose read is counted at its read call); `dir` and `db` are
listed separately.
"""

from __future__ import annotations

import csv
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONTENT_EXCLUDED = frozenset({"meta", "open", "dir", "db"})
TURN_ENTRY = "Keeper_agent_run.run_turn"
FOCUS_ROUTES = (
    "ROUTE GET /api/v1/keepers/turns",
    "ROUTE GET /api/v1/gate/keepers",
    "ROUTE GET /api/v1/dashboard/scheduled-automation",
    "ROUTE GET /api/v1/tui/preferences",
    "ROUTE GET /api/v1/dashboard/health-line",
    "ROUTE GET /api/v1/operator",
    "ROUTE PREFIX_GET /api/v1/keepers/",
)


def rows(name: str) -> list[dict[str, str]]:
    with (HERE / name).open(encoding="utf-8") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def table(header: list[str], body: list[list[str]]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(r) + " |" for r in body]
    return "\n".join(out)


def main() -> int:
    sites = rows("code-read-sites.tsv")
    triggers = {r["site"]: r for r in rows("site-triggers.tsv")}
    reach = rows("route-reads.tsv")

    print("## A. Read call sites by kind and where the blocking read runs\n")
    kinds = Counter((r["shape"], r["mech"]) for r in sites)
    print(table(["shape", "mech", "sites"], [[s, m, str(n)] for (s, m), n in kinds.most_common()]))

    print("\n## B. Content-read sites by reaching entry\n")
    reached_by: dict[str, set[str]] = defaultdict(set)
    for r in reach:
        reached_by[r["site"]].add(r["entry"])
    classes: Counter[tuple[str, str]] = Counter()
    for r in sites:
        if r["shape"] in CONTENT_EXCLUDED:
            continue
        site = f"{r['path']}:{r['line']}"
        entries = reached_by.get(site, set())
        kinds = [
            name for name, hit in (
                ("route", any(e.startswith("ROUTE ") for e in entries)),
                ("turn", TURN_ENTRY in entries),
                ("refresh loop", any(not e.startswith("ROUTE ") and e != TURN_ENTRY for e in entries)),
            ) if hit
        ]
        label = " + ".join(kinds) if kinds else "none of these (boot, tool, other loop or unresolved)"
        classes[(label, r["mech"])] += 1
    print(table(["reached from", "mech", "sites"], [[a, b, str(n)] for (a, b), n in sorted(classes.items())]))

    print("\n## C. Entries reaching the most content-read sites (depth <= 30)\n")
    per_entry: dict[str, set[str]] = defaultdict(set)
    for r in reach:
        if r["shape"] not in CONTENT_EXCLUDED:
            per_entry[r["entry"]].add(r["site"])
    top = sorted(per_entry.items(), key=lambda kv: len(kv[1]), reverse=True)[:20]
    print(table(["entry", "content-read sites"], [[e, str(len(s))] for e, s in top]))

    print("\n## D. Routes the TUI refreshes, content reads within reach\n")
    for route in FOCUS_ROUTES:
        found = sorted(
            {(int(r["depth"]), r["site"], r["primitive"], r["mech"]) for r in reach
             if r["entry"] == route and r["shape"] not in CONTENT_EXCLUDED}
        )
        print(f"\n### {route} — {len(found)} sites\n")
        if found:
            print(table(["depth", "site", "primitive", "mech"], [[str(d), s, p, m] for d, s, p, m in found[:40]]))
    del triggers
    return 0


if __name__ == "__main__":
    sys.exit(main())
