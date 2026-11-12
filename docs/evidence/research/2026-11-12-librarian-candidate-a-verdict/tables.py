# pyright: strict
"""Print the numbers this folder's README states, from verdict.json, runs.json and rows.jsonl.

    python3 tables.py <this folder>

Prints one JSON object. `real` and `synth` count rows.jsonl per target; `paired` joins the two
targets' rows of one item; `judged` counts what the blind judges said of the off-label drops and the
absorbs; `train` gives the mean of the per-step loss over blocks of STEP_BLOCK steps.
"""

from __future__ import annotations

import json
import statistics
import sys
from collections import Counter
from pathlib import Path
from typing import cast

type JsonObject = dict[str, object]

TARGETS = ("base", "A")
HTTP_OK = 200
STEP_BLOCK = 8
SYNTH_SUMS = ("candidates", "correct", "state_correct", "dropped", "dropped_expected", "absorbed", "planted",
              "planted_dropped", "planted_absorbed", "scheduled_ahead", "scheduled_ahead_dropped", "scheduled_past",
              "scheduled_past_dropped", "pairs", "pairs_merged", "merges", "merges_done", "added", "removed",
              "expected_added", "expected_removed")
REAL_SUMS = ("candidates", "agree", "live_added", "live_removed", "added", "removed")


def read_json(path: Path) -> JsonObject:
    return cast(JsonObject, json.loads(path.read_text(encoding="utf-8")))


def read_jsonl(path: Path) -> list[JsonObject]:
    return [cast(JsonObject, json.loads(line)) for line in path.read_text(encoding="utf-8").split("\n") if line]


def total(rows: list[JsonObject], key: str) -> int:
    return sum(cast(int, r[key]) for r in rows)


def listed(rows: list[JsonObject], key: str) -> int:
    return sum(len(cast(list[object], r[key])) for r in rows)


def answers(rows: list[JsonObject]) -> JsonObject:
    """What every target's rows share: how many answered, were valid, thought, and how long they took."""
    answered = [r for r in rows if r["status"] == HTTP_OK]
    invalid = Counter("+".join(cast(list[str], r["problems"])) for r in rows if not r["valid"])
    return {
        "items": len(rows), "valid": sum(bool(r["valid"]) for r in rows),
        "status": dict(sorted(Counter(str(r["status"]) for r in rows).items())),
        "finish": dict(sorted(Counter(str(r["finish"]) for r in answered).items())),
        "invalid": dict(sorted(invalid.items())),
        "answered": len(answered),
        "answered_without_thinking": sum(r["reasoning_chars"] == 0 for r in answered),
        "completion_tokens_p50": statistics.median(cast(int, r["completion_tokens"]) for r in answered),
        "wall_s_p50": round(statistics.median(cast(float, r["wall_s"]) for r in answered), 2),
        "cost_usd": round(sum(cast(float, r["cost_usd"]) for r in rows), 4),
    }


def by_item(rows: list[JsonObject], target: str) -> dict[str, JsonObject]:
    return {cast(str, r["item"]): r for r in rows if r["target"] == target}


def real(rows: list[JsonObject], refused: list[str]) -> JsonObject:
    out: JsonObject = {}
    for target in TARGETS:
        mine = [r for r in rows if r["target"] == target]
        reach = [r for r in mine if r["item"] not in refused]
        out[target] = answers(mine) | {key: total(mine, key) for key in REAL_SUMS} | {
            "valid_in_reach": [sum(bool(r["valid"]) for r in reach), len(reach)],
            "dropped_not_in_live": listed(mine, "dropped_not_in_live"),
            "items_with_dropped_not_in_live": sum(bool(r["dropped_not_in_live"]) for r in mine),
            "absorbed_not_in_live": listed(mine, "absorbed_not_in_live"),
        }
    base, cand = by_item(rows, TARGETS[0]), by_item(rows, TARGETS[1])
    both = sorted(i for i in base if base[i]["valid"] and i in cand and cand[i]["valid"])
    triples: Counter[str] = Counter()
    for item in both:
        ours = cast(list[list[str]], base[item]["outcomes"])
        theirs = cast(list[list[str]], cand[item]["outcomes"])
        triples.update(f"{live}/{b}/{a}" for (live, b), (_, a) in zip(ours, theirs, strict=True))
    out["paired"] = {
        "items": len(both), "candidates": sum(triples.values()),
        "base_agrees": sum(n for k, n in triples.items() if k.split("/")[0] == k.split("/")[1]),
        "A_agrees": sum(n for k, n in triples.items() if k.split("/")[0] == k.split("/")[2]),
        "live/base/A": dict(sorted(triples.items(), key=lambda kv: (-kv[1], kv[0]))),
    }
    return out


def synth(rows: list[JsonObject]) -> JsonObject:
    out: JsonObject = {}
    for target in TARGETS:
        mine = [r for r in rows if r["target"] == target]
        kinds: dict[str, list[int]] = {}
        for r in mine:
            for kind, (candidates, correct) in cast(dict[str, list[int]], r["state_by_kind"]).items():
                tally = kinds.setdefault(kind, [0, 0])
                tally[0] += candidates
                tally[1] += correct
        out[target] = answers(mine) | {key: total(mine, key) for key in SYNTH_SUMS} | {
            "state_by_kind": {k: {"candidates": c, "state_correct": ok} for k, (c, ok) in sorted(kinds.items())},
            "dropped_off_label": listed(mine, "dropped_off_label"),
            "dropped_unmerged": listed(mine, "dropped_unmerged"),
            "absorbs_by_label": dict(sorted(Counter(
                what for r in mine for what in cast(dict[str, str], r["absorbs"]).values()).items())),
        }
    base, cand = by_item(rows, TARGETS[0]), by_item(rows, TARGETS[1])
    both = sorted(i for i in base if base[i]["valid"] and i in cand and cand[i]["valid"])
    out["paired"] = {"items": len(both), "candidates": total([base[i] for i in both], "candidates"),
                     "base_state_correct": total([base[i] for i in both], "state_correct"),
                     "A_state_correct": total([cand[i] for i in both], "state_correct")}
    return out


def judged(verdict: JsonObject) -> JsonObject:
    drops = cast(list[JsonObject], cast(JsonObject, verdict["e_synth_drops"])["off_label_drops"])
    merges = cast(JsonObject, verdict["e_synth_merges"])
    absorbs = cast(list[JsonObject], merges["absorbs"])
    return {
        "off_label_drops": len(drops),
        "off_label_drops_by_target": dict(sorted(Counter(
            f"{t}:{d['judged']}" for d in drops for t in cast(list[str], d["targets"])).items())),
        "absorbs_by_target": dict(sorted(Counter(f"{a['target']}:{a['judged']}" for a in absorbs).items())),
        "merges_by_target": merges["by_target"],
    }


def train(record: JsonObject) -> JsonObject:
    steps = cast(list[JsonObject], record["steps"])
    loss = [cast(float, s["train_mean_nll"]) for s in steps]
    blocks = [loss[i:i + STEP_BLOCK] for i in range(0, len(loss), STEP_BLOCK)]
    return {"steps": len(steps), "examples": total(steps, "examples"), "tokens": total(steps, "tokens"),
            "wall_s": round(sum(cast(float, s["wall_s"]) for s in steps)),
            "loss_min_max": [round(min(loss), 4), round(max(loss), 4)],
            "loss_by_block": [[len(b), round(statistics.fmean(b), 4)] for b in blocks]}


def main() -> int:
    here = Path(sys.argv[1])
    verdict, runs = read_json(here / "verdict.json"), read_json(here / "runs.json")
    rows = read_jsonl(here / "rows.jsonl")
    print(json.dumps({
        "verdict": verdict["A"], "choice": verdict["choice"], "e_real_refused": verdict["e_real_refused"],
        "real": real([r for r in rows if r["set"] == "real"], cast(list[str], verdict["e_real_refused"])),
        "synth": synth([r for r in rows if r["set"] == "synth"]),
        "judged": judged(verdict),
        "train": train(cast(JsonObject, runs["train-A"])),
    }, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
