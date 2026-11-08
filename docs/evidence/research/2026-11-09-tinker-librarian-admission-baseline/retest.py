# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Print what G4 and G5 give when the base model is compared with itself.

    uv run docs/evidence/research/2026-11-09-tinker-librarian-admission-baseline/retest.py

The three E-real runs next to this file sent the same model the same bytes:
every measured call has the same cache key in all three. A candidate exactly as
good as the base would score like the second run of a pair against the first.
For each pair this prints G4's paired lead and its spread over items
(bootstrap, seed 20261109), how often the two runs gave a candidate different
outcomes, and G5's p50 ratio with the widest gap between an item's two calls.
Writes nothing.
"""

from __future__ import annotations

import json
import random
import statistics
import sys
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "scripts" / "tinker" / "librarian"))

import eval_admission as V

type JsonObject = dict[str, object]

HERE = Path(__file__).resolve().parent
RUNS = ("run1", "run2", "run3")
BOOTSTRAP = 4000
SEED = 20261109


def rows_of(run: str) -> list[JsonObject]:
    text = (HERE / f"e-real-base-{run}-rows.jsonl").read_text(encoding="utf-8")
    return [{**cast(JsonObject, json.loads(line)), "target": run} for line in text.splitlines()]


def lead_spread(first: dict[str, JsonObject], second: dict[str, JsonObject], items: list[str]) -> float:
    rng = random.Random(SEED)
    leads: list[float] = []
    for _ in range(BOOTSTRAP):
        pick = [rng.choice(items) for _ in items]
        cands = sum(cast(int, first[i]["candidates"]) for i in pick)
        leads.append(sum(cast(int, second[i]["agree"]) - cast(int, first[i]["agree"]) for i in pick) / cands)
    return statistics.pstdev(leads)


def pair(a: str, b: str, rows: list[JsonObject]) -> JsonObject:
    first, second = V.by_item(rows, a), V.by_item(rows, b)
    both = sorted(i for i in first.keys() & second.keys() if first[i]["valid"] and second[i]["valid"])
    outcomes = [(cast(dict[str, object], first[i]["outcomes"]), cast(dict[str, object], second[i]["outcomes"]))
                for i in both]
    same = sum(x.get(k) == y.get(k) for x, y in outcomes for k in x.keys() | y.keys())
    total = sum(len(x.keys() | y.keys()) for x, y in outcomes)
    p50 = {run: statistics.median(cast(float, r["wall_s"]) for r in side.values() if r["status"] == 200)
           for run, side in ((a, first), (b, second))}
    lead = V.paired(rows, a, b)
    return {"pair": f"{a}->{b}", "both_valid": len(both),
            "validity_flips": sum(first[i]["valid"] != second[i]["valid"] for i in first.keys() & second.keys()),
            "G4_lead": round(cast(float, lead["lead"]), 4), "G4_lead_spread": round(lead_spread(first, second, both), 4),
            "same_outcome": f"{same}/{total}", "p50_s": p50, "G5_ratio": round(p50[b] / p50[a], 3),
            "widest_gap_s": V.widest_gap_s(rows, a, b)}


rows = [r for run in RUNS for r in rows_of(run)]
for run, part in cast(dict[str, JsonObject], V.summarize("real", rows)).items():
    print(json.dumps({"run": run, **part}))
for a, b in (("run1", "run2"), ("run2", "run3"), ("run1", "run3")):
    print(json.dumps(pair(a, b, rows)))
