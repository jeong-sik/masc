#!/usr/bin/env python3
"""Summarize the read inventory TSVs into Markdown tables.

Inputs (same directory): code-read-sites.tsv from code_read_sites.py,
route-reads.tsv from route_reach.py, and focus-routes.txt (the route nodes the
TUI requests, one per line). Output: Markdown on stdout.

A site is one primitive on one line. Its kind is `content` unless its shape is
`meta` (stat/exists), `open` (an open whose read is counted at its read call),
`dir` or `db`, which are kinds of their own. `tree` and `layer` are the columns
code_read_sites.py writes: lib or bin, and call or wrapper (a site inside a
wrapper library).
"""

from __future__ import annotations

import csv
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
OWN_KINDS = ("meta", "open", "dir", "db")
KINDS = ("content", *OWN_KINDS)
TURN_ENTRY = "Keeper_agent_run.run_turn"
FOCUS_ROUTES_FILE = "focus-routes.txt"


def rows(name: str) -> list[dict[str, str]]:
    with (HERE / name).open(encoding="utf-8") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def kind(shape: str) -> str:
    return shape if shape in OWN_KINDS else "content"


def table(header: list[str], body: list[list[str]]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(r) + " |" for r in body]
    return "\n".join(out)


def main() -> int:
    sites = rows("code-read-sites.tsv")
    reach = rows("route-reads.tsv")
    layer_of = {f"{r['path']}:{r['line']}": r["layer"] for r in sites}

    print("## A. Read call sites by kind, tree and layer\n")
    by_place = Counter((kind(r["shape"]), r["tree"], r["layer"]) for r in sites)
    places = (("lib", "call"), ("lib", "wrapper"), ("bin", "call"))
    print(table(
        ["kind", *(f"{tree}/{layer}" for tree, layer in places), "all"],
        [[k, *(str(by_place[(k, tree, layer)]) for tree, layer in places),
          str(sum(by_place[(k, tree, layer)] for tree, layer in places))]
         for k in KINDS],
    ))

    print("\n## B. lib call sites by kind and mech\n")
    lib_call = [r for r in sites if r["tree"] == "lib" and r["layer"] == "call"]
    by_mech = Counter((kind(r["shape"]), r["mech"]) for r in lib_call)
    print(table(["kind", "mech", "sites"], [[k, m, str(n)] for (k, m), n in sorted(by_mech.items())]))

    print("\n## C. lib call content sites by reaching entry (depth <= 30)\n")
    reached_by: dict[str, set[str]] = defaultdict(set)
    for r in reach:
        reached_by[r["site"]].add(r["entry"])
    classes: Counter[str] = Counter()
    for r in lib_call:
        if kind(r["shape"]) != "content":
            continue
        entries = reached_by.get(f"{r['path']}:{r['line']}", set())
        hits = [
            name for name, hit in (
                ("route", any(e.startswith("ROUTE ") for e in entries)),
                ("turn", TURN_ENTRY in entries),
                ("refresh loop", any(not e.startswith("ROUTE ") and e != TURN_ENTRY for e in entries)),
            ) if hit
        ]
        classes[" + ".join(hits) if hits else "none of these (boot, tool, other loop or unresolved)"] += 1
    print(table(["reached from", "sites"], [[a, str(n)] for a, n in sorted(classes.items())]))

    print("\n## D. Entries reaching the most lib call content sites\n")
    per_entry: dict[str, set[str]] = defaultdict(set)
    for r in reach:
        site = r["site"]
        if kind(r["shape"]) == "content" and layer_of.get(site) == "call" and site.startswith("lib/"):
            per_entry[r["entry"]].add(site)
    top = sorted(per_entry.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:20]
    print(table(["entry", "sites"], [[e, str(len(s))] for e, s in top]))

    print("\n## E. Routes the TUI requests, content sites within reach\n")
    focus_routes = [line for line in (HERE / FOCUS_ROUTES_FILE).read_text(encoding="utf-8").splitlines() if line]
    for route in focus_routes:
        found = sorted(
            {(int(r["depth"]), r["site"], r["primitive"], r["mech"], layer_of.get(r["site"], "?")) for r in reach
             if r["entry"] == route and kind(r["shape"]) == "content"}
        )
        calls = sum(1 for f in found if f[4] == "call")
        print(f"\n### {route} — {calls} call sites, {len(found) - calls} wrapper sites\n")
        if found:
            print(table(
                ["depth", "site", "primitive", "mech", "layer"],
                [[str(depth), site, prim, mech, layer] for depth, site, prim, mech, layer in found[:40]],
            ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
