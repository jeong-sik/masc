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
the claim it goes into, and the observations that claim cites, in the shape the
gate reads them. In an admission a claim cites the candidates that support the
change and whose judgment names it (keeper_librarian_runtime.ml
`cited_observations`); an E-synth request has no other observations. The gate
asks without the observations when they would push its request past
REQUEST_BYTES_LIMIT, and does not ask about a claim over STATE_BYTES_LIMIT or
a pair that alone passes the request limit (`classify`). `states` does the
same, and stops at an absorb the gate would not ask about.
`judging` writes the gate's question from the checkout's
config/prompts/librarian.md: the instruction for a pair alone or with
observations, and the four classes with their criteria, word for word.

Each answer comes from the call its row names (`call_key` and `sent_at`), so a
case shows the claim the verdict scores. Answers that make the same state share
one case, whatever target or request made them, and the cases come in an order
drawn from the pinned audit seed. A case shows no label, target, item or memory
ID. An absorbed planted stale fact gets no case (`merge_decisions`). The key in
<out> lists the absorbs each case stands for, and `merge_decisions.RUN_FILES`
the sha256 of the run's call log and rows. The judge's folder works as the drop
judge's does (`e_synth_audit.write_cases`), and the verdict reads the decisions
with `--merges` for that run only.
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
import prompt_facts as PF
import synth_render
import yojson_wire as W
from tinker_oai import Call, call_from_row

type JsonObject = dict[str, object]
# The slots of the gate's forward question (keeper_librarian_absorb_gate.ml `resolve_guidance`).
FORWARD, PAIR, OBSERVATIONS = "absorb_forward", "absorb_pair", "absorb_observations"
# keeper_librarian_absorb_gate.ml `request_bytes_limit` and `state_bytes_limit`.
REQUEST_BYTES_LIMIT = 32_000
STATE_BYTES_LIMIT = REQUEST_BYTES_LIMIT // 2
# keeper_librarian_runtime.ml `cited_observations`: what a cited candidate is to the gate.
OBSERVATION_KIND = "pending_explicit_memory_candidate"
HEADER = """# 합침 판정 기준

case 하나는 기억 하나(source_memory)를 다른 기억(proposed_memory)에 합쳐 없애자는 제안입니다.
new_observations 는 proposed_memory 가 근거로 인용한 기억 후보입니다.
Keeper 가 이번 턴에 저장해 달라고 냈고, 아직 기억에 없습니다. 없는 case 도 있습니다.
아래 영어 글은 MASC 가 같은 질문을 판정 모델에 보낼 때 쓰는 글 그대로입니다.
MASC 의 판정 모델은 이 글과 case 하나만 받습니다.
"""


def guidance(rules: str) -> dict[str, str]:
    """The gate's slots from librarian.md text. SystemExit when one is missing."""
    slots = AT.slots_of(rules)
    names = (FORWARD, PAIR, OBSERVATIONS, *(f"absorb_{c}" for c in MD.CONSOLIDATIONS))
    missing = [name for name in names if name not in slots]
    if missing:
        raise SystemExit(f"the rules lack the slots {', '.join(missing)}")
    return {name: slots[name] for name in names}


def judging(slots: dict[str, str]) -> str:
    """The gate's question as the judge reads it."""
    classes = "\n".join(f'- "{c}": {slots[f"absorb_{c}"]}' for c in MD.CONSOLIDATIONS)
    return (f"{HEADER}\nnew_observations 가 없는 case:\n\n{slots[FORWARD]} {slots[PAIR]}\n\n"
            f"new_observations 가 있는 case:\n\n{slots[FORWARD]} {slots[OBSERVATIONS]}\n\n"
            f"case 마다 그 case 만 보고 다음 넷 가운데 하나를 고릅니다.\n\n{classes}\n\n"
            "case 마다 decisions.jsonl 에 한 줄을 씁니다. 모든 case 를 빠짐없이 판정합니다.\n"
            '{"case": "g001", "decision": "mergeable", "reason": "한 문장"}\n')


@dataclass(frozen=True, slots=True)
class State:
    """What the gate reads for one absorbed memory: its claim, the claim it goes into, and the candidates
    that claim cites when the gate shows them."""

    source: str
    proposed: str
    observations: tuple[PF.Candidate, ...]


def observation_json(candidate: PF.Candidate) -> W.JsonObject:
    """A cited candidate as the gate reads it (keeper_librarian_runtime.ml `cited_observations`)."""
    return W.JsonObject((("observation_kind", OBSERVATION_KIND), ("request_id", candidate.request_id),
                         ("sequence", candidate.sequence),
                         ("proposal", PF.proposed_fact_json(candidate.proposed_fact))))


def state_json(state: State) -> W.JsonObject:
    """keeper_librarian_absorb_gate.ml `forward_state`."""
    members: tuple[tuple[str, W.Json], ...] = (("source_memory", state.source), ("proposed_memory", state.proposed))
    if state.observations:
        members += (("new_observations", tuple(observation_json(c) for c in state.observations)),)
    return W.JsonObject(members)


def question_json(slots: dict[str, str], observed: bool) -> W.JsonObject:
    """`forward_question` as Typesafeai_types.question_to_yojson writes it."""
    context = slots[OBSERVATIONS] if observed else slots[PAIR]
    criteria = W.JsonObject(tuple((c, slots[f"absorb_{c}"]) for c in MD.CONSOLIDATIONS))
    return W.JsonObject((("type", "choice"), ("instructions", f"{slots[FORWARD]} {context}"), ("criteria", criteria)))


def fits(state: State, slots: dict[str, str]) -> bool:
    """The gate's `fits`: the state and its question within REQUEST_BYTES_LIMIT."""
    question = question_json(slots, bool(state.observations))
    return len(W.write(state_json(state)).encode()) + len(W.write(question).encode()) <= REQUEST_BYTES_LIMIT


def states(item: M.SynthItem, answer: AV.AdmissionAnswer, slots: dict[str, str]) -> list[tuple[str, State]]:
    """(memory ID, state) for each memory the answer absorbs but planted stale facts, in its order.
    SystemExit at an absorb the gate would not ask about."""
    claims = M.fact_claims(item.prompt)
    named = {j.request_id: j.memory_claim for j in answer.judgments}
    support = set(answer.change_support)
    out: list[tuple[str, State]] = []
    for mid, into in answer.absorbed:
        if mid in item.label.planted_stale:
            continue
        cited = tuple(c for c in item.prompt.candidates if c.request_id in support and named.get(c.request_id) == into)
        state = State(claims[mid], into, cited)
        if cited and not fits(state, slots):
            state = State(claims[mid], into, ())
        if len(into.encode()) > STATE_BYTES_LIMIT or not fits(state, slots):
            raise SystemExit(f"{item.item_id}: the absorb gate would not ask about {mid}: "
                             f"its claim or pair passes the gate's byte limits")
        out.append((mid, state))
    return out


def collect(items: dict[str, M.SynthItem], answers: dict[tuple[str, str], AV.AdmissionAnswer],
            slots: dict[str, str]) -> dict[State, list[MD.Absorb]]:
    """Each state with the absorbs that make it, from the answers by (target, item)."""
    out: dict[State, list[MD.Absorb]] = {}
    for (target, item_id), answer in sorted(answers.items()):
        for mid, state in states(items[item_id], answer, slots):
            out.setdefault(state, []).append((item_id, target, mid))
    return out


def case_of(case_id: str, state: State) -> JsonObject:
    return {"case": case_id, **cast(JsonObject, json.loads(W.write(state_json(state))))}


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
    """Each valid answer of the run by (target, item), from the call its row names. SystemExit when the
    call log does not hold a valid answer for a valid row's call."""
    calls: dict[tuple[str, float | None], Call] = {}
    for row in D.read_jsonl(run / "calls.jsonl"):
        call = call_from_row(row)
        if call is not None:
            calls[(call.key, call.sent_at)] = call
    out: dict[tuple[str, str], AV.AdmissionAnswer] = {}
    for row in V.read_rows(run):
        if not row["valid"]:
            continue
        key = (cast(str, row["target"]), cast(str, row["item"]))
        call = calls.get((cast(str, row["call_key"]), cast(float, row["sent_at"])))
        answer = V.check(items[key[1]].prompt, call.answer() if call is not None else None).answer
        if answer is None:
            raise SystemExit(f"{key}: the row is valid and the call log holds no valid answer for its call")
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
    slots = guidance(synth_render.TEMPLATE.read_text(encoding="utf-8"))
    items = {i.item_id: i for i in V.synth_items(path)}
    answers = answers_of(run, items)
    collected = collect(items, answers, slots)
    case_rows, key_rows = render(collected, f"{e_synth['audit_seed']}:merges")
    A.write_cases(out, case_rows, key_rows, judging(slots))
    MD.record_run_files(out, run)
    summary = {"absorbs": sum(len(a) for a in collected.values()),
               "stale_absorbs": sum(mid in items[i].label.planted_stale
                                    for (_, i), answer in answers.items() for mid, _ in answer.absorbed),
               "cases": len(case_rows)}
    (out / "cases-summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
