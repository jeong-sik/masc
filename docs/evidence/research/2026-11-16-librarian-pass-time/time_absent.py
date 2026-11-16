# pyright: basic
"""What the claim of a `memory_claim_absent` answer points at, in the pass-time research runs.
Numbers only.

    uv run --python 3.12 --with openai==3.46.0 time_absent.py \
        --scripts <harness scripts/tinker/librarian> --runs screen-runs.json \
        --requests <requests.jsonl> [--root <runs folder>] [--out absent.json]

MASC refuses an admission answer when a judgment's `memory_claim` is not, character for character,
a claim of final memory (keeper_memory_admission_judgment.ml `verify`; the harness's
`admission_judgment.verify`). This script reads the answers of the runs `time_screen.py` compares
(the groups a contrast names) whose row names that problem, parses each with the harness as the
verdict does, and sorts every judgment whose claim final memory lacks by what the claim equals:

- an input memory's claim that final memory no longer holds,
- the candidate's own text,
- neither, but close to a claim of final memory: `difflib.SequenceMatcher(None, a, b).ratio()` of
  NEAR or more with the closest one. Such a claim is split by whether the closest final claim is an
  input memory the answer kept (it has a short ID the answer could have named) or a claim the answer
  wrote,
- neither, and no final claim that close.

NEAR is a cut for description, not a rule of MASC; the script prints every ratio so the cut can be
read against them. For the close claims it prints how many characters differ.
"""

from __future__ import annotations

import argparse
import collections
import difflib
import json
import sys
from pathlib import Path
from typing import Any

PROBLEM = "memory_claim_absent"
# A claim this close to a final claim, and not equal to it, is counted as a copy that changed.
NEAR = 0.9


def ratio(a: str, b: str) -> float:
    return difflib.SequenceMatcher(None, a, b).ratio()


def changed_characters(a: str, b: str) -> int:
    codes = difflib.SequenceMatcher(None, a, b).get_opcodes()
    return sum(max(i2 - i1, j2 - j1) for tag, i1, i2, j1, j2 in codes if tag != "equal")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scripts", required=True)
    parser.add_argument("--runs", required=True)
    parser.add_argument("--requests", required=True)
    parser.add_argument("--root", default=None)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    sys.path.insert(0, args.scripts)
    import admission_judgment  # noqa: PLC0415  # pyright: ignore[reportMissingImports]
    import eval_admission  # noqa: PLC0415  # pyright: ignore[reportMissingImports]
    import lane_addon_checks  # noqa: PLC0415  # pyright: ignore[reportMissingImports]
    import librarian_selection  # noqa: PLC0415  # pyright: ignore[reportMissingImports]
    import memory_scores  # noqa: PLC0415  # pyright: ignore[reportMissingImports]
    from yojson_wire import parse as parse_json  # noqa: PLC0415  # pyright: ignore[reportMissingImports]

    config_path = Path(args.runs).resolve()
    root = config_path.parent.parent if args.root is None else Path(args.root).resolve()
    config = json.loads(config_path.read_text(encoding="utf-8"))
    compared = {group for pair in config.get("contrasts", []) for group in pair}
    prompts = {item.item_id: item.prompt for item in eval_admission.synth_items(Path(args.requests))}
    answers = 0
    kinds: collections.Counter[tuple[str, str]] = collections.Counter()
    ratios: list[float] = []
    changed: list[int] = []
    runs = [run for run in config["runs"] if run["group"] in compared]
    for run in runs:
        synth = Path(run["synth"]) if Path(run["synth"]).is_absolute() else root / run["synth"]
        calls: dict[str, str] = {}
        for line in (synth / "calls.jsonl").open(encoding="utf-8"):
            call = json.loads(line)
            if call.get("content"):
                calls[call["key"]] = call["content"]
        for line in (synth / "rows.jsonl").open(encoding="utf-8"):
            row = json.loads(line)
            if row["valid"] or PROBLEM not in {str(problem).split(":")[0] for problem in row["problems"]}:
                continue
            answers += 1
            prompt = prompts[row["item"]]
            shaped = lane_addon_checks.shape(lane_addon_checks.canonical(parse_json(calls[row["call_key"]])))
            judgments = admission_judgment.unwrap(prompt, shaped)[0]
            final = set(librarian_selection.select(prompt, shaped).memory_after)
            inputs = set(memory_scores.fact_claims(prompt).values())
            own = {c.request_id: c.proposed_fact.claim for c in prompt.candidates}
            for judgment in judgments:
                claim = judgment.memory_claim
                if claim is None or claim in final:
                    continue
                closest = max(final, key=lambda held: ratio(claim, held))
                best = ratio(claim, closest)
                ratios.append(round(best, 2))
                if claim in inputs:
                    kind = "an input memory's claim that final memory no longer holds"
                elif claim == own[judgment.request_id]:
                    kind = "the candidate's own text"
                elif best >= NEAR:
                    changed.append(changed_characters(claim, closest))
                    kind = ("close to an input memory the answer kept" if closest in inputs
                            else "close to a claim the answer wrote")
                else:
                    kind = "no final claim that close"
                kinds[(judgment.outcome, kind)] += 1
    report: dict[str, Any] = {
        "runs": len(runs), "answers": answers, "claims": sum(kinds.values()), "near": NEAR,
        "kinds": [{"outcome": outcome, "kind": kind, "claims": n} for (outcome, kind), n in sorted(kinds.items())],
        "ratios": sorted(ratios), "changed_characters": sorted(changed),
    }
    print(f"runs {len(runs)}: {answers} answers name {PROBLEM}; {sum(kinds.values())} judgments point at a claim final memory lacks")
    for (outcome, kind), n in sorted(kinds.items(), key=lambda held: (-held[1], held[0])):
        print(f"  {n:3d}  {outcome}: {kind}")
    print("ratio with the closest final claim, every claim: " + " ".join(f"{r:.2f}" for r in sorted(ratios)))
    print("characters that differ, the close claims: " + " ".join(str(n) for n in sorted(changed)))
    if args.out is not None:
        Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
