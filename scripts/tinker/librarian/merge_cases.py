# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Make the blind merge judge's cases for the memories an E-synth run's answers absorb.

    uv run scripts/tinker/librarian/merge_cases.py \
        --requests artifacts/tinker/librarian/e-synth/requests.jsonl \
        --run artifacts/tinker/librarian/verdict-synth --out artifacts/tinker/librarian/verdict-merges
    # the judge gets only <out>/judge/: it reads judge.md and cases.jsonl there and writes decisions.jsonl

A case is the state MASC's absorb gate sends its judgment model for one absorbed
memory (keeper_librarian_absorb_gate.ml `forward_state`): the memory's claim,
the claim it goes into, and the observations that claim cites. In an admission
a claim cites the candidates that support the change and whose judgment names
it (keeper_librarian_runtime.ml `cited_observations`); an E-synth request has
no other observations. `judging` writes the gate's question from the
checkout's config/prompts/librarian.md: the instruction for a pair alone or
with observations, and the four classes with their criteria, word for word.

Answers that make the same state share one case, whatever target or request
made them, and the cases come in an order drawn from the pinned audit seed. A
case shows no label, target, request or memory ID. An absorbed planted stale
fact gets no case (`merge_decisions`). The key in <out> lists the absorbs each
case stands for. The judge's folder works as the drop judge's does
(`e_synth_audit.write_cases`), and the verdict reads the decisions with `--merges`.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import cast

import admission_template as AT
import admission_validator as AV
import audit_decisions as D
import e_synth_audit as A
import eval_admission as V
import memory_scores as M
import merge_decisions as MD
import synth_render
from tinker_oai import HTTP_OK, Call, call_from_row

type JsonObject = dict[str, object]
# The slots of the gate's forward question (keeper_librarian_absorb_gate.ml `resolve_guidance`).
FORWARD, PAIR, OBSERVATIONS = "absorb_forward", "absorb_pair", "absorb_observations"
HEADER = """# 합침 판정 기준

한 case 는 기억 하나(source_memory)를 다른 기억(proposed_memory)에 합쳐 없애자는 제안입니다.
new_observations 는 proposed_memory 가 근거로 삼은 이번 턴 관측이고, 없는 case 도 있습니다.
아래 영어 글은 MASC 가 같은 질문을 판정 모델에 보낼 때 쓰는 글 그대로입니다(`config/prompts/librarian.md`).
"""


def judging(rules: str) -> str:
    """The gate's question as the judge reads it, from librarian.md text. SystemExit when a slot is missing."""
    slots = AT.slots_of(rules)
    names = (FORWARD, PAIR, OBSERVATIONS, *(f"absorb_{c}" for c in MD.CONSOLIDATIONS))
    missing = [name for name in names if name not in slots]
    if missing:
        raise SystemExit(f"the rules lack the slots {', '.join(missing)}")
    classes = "\n".join(f'- "{c}": {slots[f"absorb_{c}"]}' for c in MD.CONSOLIDATIONS)
    return (f"{HEADER}\nnew_observations 가 없는 case:\n\n{slots[FORWARD]} {slots[PAIR]}\n\n"
            f"new_observations 가 있는 case:\n\n{slots[FORWARD]} {slots[OBSERVATIONS]}\n\n"
            f"case 마다 다음 넷 가운데 하나를 고릅니다.\n\n{classes}\n\n"
            "case 마다 decisions.jsonl 에 한 줄을 씁니다. 모든 case 를 빠짐없이 판정합니다.\n"
            '{"case": "g001", "decision": "mergeable", "reason": "한 문장"}\n')


@dataclass(frozen=True, slots=True)
class State:
    """What the gate reads for one absorbed memory: its claim, the claim it goes into, and the category
    and claim of each candidate that claim cites."""

    source: str
    proposed: str
    observations: tuple[tuple[str, str], ...]


def states(item: M.SynthItem, answer: AV.AdmissionAnswer) -> list[tuple[str, State]]:
    """(memory ID, state) for each memory the answer absorbs but planted stale facts, in its order."""
    claims = M.fact_claims(item.prompt)
    named = {j.request_id: j.memory_claim for j in answer.judgments}
    support = set(answer.change_support)

    def cited(claim: str) -> tuple[tuple[str, str], ...]:
        return tuple((c.proposed_fact.category, c.proposed_fact.claim) for c in item.prompt.candidates
                     if c.request_id in support and named.get(c.request_id) == claim)
    return [(mid, State(claims[mid], into, cited(into))) for mid, into in answer.absorbed
            if mid not in item.label.planted_stale]


def collect(items: dict[str, M.SynthItem], answers: dict[tuple[str, str], AV.AdmissionAnswer]
            ) -> dict[State, list[MD.Absorb]]:
    """Each state with the absorbs that make it, from the answers by (target, item)."""
    out: dict[State, list[MD.Absorb]] = {}
    for (target, item_id), answer in sorted(answers.items()):
        for mid, state in states(items[item_id], answer):
            out.setdefault(state, []).append((item_id, target, mid))
    return out


def case_of(case_id: str, state: State) -> JsonObject:
    case: JsonObject = {"case": case_id, "source_memory": state.source, "proposed_memory": state.proposed}
    if state.observations:
        case["new_observations"] = [{"category": category, "claim": claim} for category, claim in state.observations]
    return case


def render(collected: dict[State, list[MD.Absorb]], seed: str) -> tuple[list[JsonObject], list[JsonObject]]:
    """The cases in an order drawn from `seed`, and the key: the absorbs of each case."""
    ordered = list(collected.items())
    random.Random(seed).shuffle(ordered)
    case_rows: list[JsonObject] = []
    key_rows: list[JsonObject] = []
    for n, (state, absorbs) in enumerate(ordered):
        case_id = f"g{n + 1:03d}"
        case_rows.append(case_of(case_id, state))
        key_rows.append({"case": case_id, "absorbs": [list(a) for a in absorbs]})
    return case_rows, key_rows


def answers_of(run: Path, items: dict[str, M.SynthItem]) -> dict[tuple[str, str], AV.AdmissionAnswer]:
    """Each valid answer of the run by (target, item): the rows say which are valid, the call log holds
    them. SystemExit when the call log does not hold a row's valid answer."""
    calls: dict[tuple[str, str], Call] = {}
    for row in D.read_jsonl(run / "calls.jsonl"):
        call = call_from_row(row)
        parts = call.label.split(":") if call is not None else []
        if call is not None and call.status == HTTP_OK and len(parts) == 3 and parts[0] == "synth":
            calls[(parts[1], parts[2])] = call
    out: dict[tuple[str, str], AV.AdmissionAnswer] = {}
    for row in V.read_rows(run):
        if not row["valid"]:
            continue
        key = (cast(str, row["target"]), cast(str, row["item"]))
        call = calls.get(key)
        answer = V.check(items[key[1]].prompt, call.answer() if call is not None else None).answer
        if answer is None:
            raise SystemExit(f"{key}: the row is valid and the call log holds no valid answer for it")
        out[key] = answer
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--requests", required=True, help="the pinned E-synth requests.jsonl")
    ap.add_argument("--run", required=True, help="the verdict's E-synth run")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    path, run, out = Path(cast(str, args.requests)), Path(cast(str, args.run)), Path(cast(str, args.out))
    e_synth = A.pinned_run(path, run)
    items = {i.item_id: i for i in V.synth_items(path)}
    answers = answers_of(run, items)
    collected = collect(items, answers)
    case_rows, key_rows = render(collected, f"{e_synth['audit_seed']}:merges")
    A.write_cases(out, case_rows, key_rows, judging(synth_render.TEMPLATE.read_text(encoding="utf-8")))
    summary = {"absorbs": sum(len(a) for a in collected.values()),
               "stale_absorbs": sum(mid in items[i].label.planted_stale
                                    for (_, i), answer in answers.items() for mid, _ in answer.absorbed),
               "cases": len(case_rows)}
    (out / "cases-summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
