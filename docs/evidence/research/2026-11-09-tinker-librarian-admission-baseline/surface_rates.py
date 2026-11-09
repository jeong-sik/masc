# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Print how often claims carry a date, a time and a number, by label. Prints numbers only.

    uv run docs/evidence/research/2026-11-09-tinker-librarian-admission-baseline/surface_rates.py \
        synth artifacts/tinker/librarian/e-synth/requests.jsonl
    MASC_BASE_PATH=<base> uv run .../surface_rates.py real

synth: memory facts by `planted_stale` (each distinct fact of a memory once) and
candidates by label kind. real: distinct current facts of the E-real records by
whether the live answer took them out (dropped or absorbed), and candidates by
live outcome. The marks are `synth_spec`'s DATE, TIME and REFERENCE patterns.
Each candidate group also gets `longer_than_rest`: the chance that one of its
claims is longer than a claim of another group, ties counting half. At 0.5 the
length says nothing about the group.
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "scripts" / "tinker" / "librarian"))

import eval_admission as V
import exact_store as E
import synth_spec as S

type JsonObject = dict[str, object]


def rates(claims: list[str]) -> JsonObject:
    def share(hit: list[bool]) -> float:
        return round(sum(hit) / len(claims), 3) if claims else 0.0
    dates = [bool(S.DATE_PATTERN.search(c)) for c in claims]
    times = [bool(S.TIME_PATTERN.search(c)) for c in claims]
    return {"n": len(claims), "date": share(dates), "time": share(times),
            "date_and_time": share([d and t for d, t in zip(dates, times, strict=True)]),
            "reference": share([bool(S.REFERENCE_PATTERN.search(c)) for c in claims]),
            "chars_p50": sorted(len(c) for c in claims)[len(claims) // 2] if claims else None}


def by_group(candidates: dict[str, list[str]]) -> dict[str, JsonObject]:
    lengths = {k: [len(c) for c in v] for k, v in candidates.items()}
    out: dict[str, JsonObject] = {}
    for name, claims in sorted(candidates.items()):
        mine = lengths[name]
        rest = [n for other, ns in lengths.items() if other != name for n in ns]
        pairs = len(mine) * len(rest)
        wins = sum((a > b) + 0.5 * (a == b) for a in mine for b in rest)
        out[name] = {**rates(claims), "longer_than_rest": round(wins / pairs, 3) if pairs else 0.5}
    return out


def kind_of(label: JsonObject) -> str:
    if label.get("supersedes") is not None:
        return "correction"
    match label["outcome"]:
        case "already_represented":
            return "paraphrase"
        case "incorporated":
            return "new_durable"
        case _:
            return cast(str, label["outcome"])


def synth(path: Path) -> JsonObject:
    facts: dict[tuple[str, str], tuple[bool, str]] = {}
    candidates: dict[str, list[str]] = defaultdict(list)
    for item in V.synth_items(path):
        memory = item.item_id.rsplit("-", 1)[0]
        stale = set(cast(list[str], item.label["planted_stale"]))
        current = item.prompt.current_memory.facts if item.prompt.current_memory is not None else ()
        for i, fact in enumerate(current):
            facts[(memory, f"m{i + 1}")] = (f"m{i + 1}" in stale, fact.claim)
        labels = {cast(str, c["request_id"]): c for c in cast(list[JsonObject], item.label["candidates"])}
        for c in item.prompt.candidates:
            candidates[kind_of(labels[c.request_id])].append(c.proposed_fact.claim)
    return {"set": str(path), "facts": {"planted_stale": rates([c for s, c in facts.values() if s]),
                                        "durable": rates([c for s, c in facts.values() if not s])},
            "candidates": by_group(candidates)}


def real() -> JsonObject:
    lines = cast(JsonObject, json.loads(V.PASS_LINES.read_text(encoding="utf-8")))
    manifest = V.HERE / cast(str, cast(JsonObject, lines["e_real"])["manifest"])
    facts: dict[tuple[str, str], bool] = {}
    candidates: dict[str, list[str]] = defaultdict(list)
    for item in V.real_items(manifest, E.base_path(None)):
        gone = V.removed(item.live)
        current = item.prompt.current_memory.facts if item.prompt.current_memory is not None else ()
        for i, fact in enumerate(current):
            key = (item.prompt.keeper_id, fact.claim)
            facts[key] = facts.get(key, False) or f"m{i + 1}" in gone
        outcomes = V.outcomes(item.live)
        for c in item.prompt.candidates:
            candidates[outcomes[c.request_id][0] if c.request_id in outcomes else "none"].append(
                c.proposed_fact.claim)
    return {"set": "e-real", "facts": {"live_removed": rates([c for (_, c), g in facts.items() if g]),
                                       "live_kept": rates([c for (_, c), g in facts.items() if not g])},
            "candidates": by_group(candidates)}


if __name__ == "__main__":
    print(json.dumps(synth(Path(sys.argv[2])) if sys.argv[1] == "synth" else real(), ensure_ascii=False, indent=1))
