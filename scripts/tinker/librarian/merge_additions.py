# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Ask a blind judge whether the claims E-synth answers merge memories into say what their sources do not
(RFC-0517 §7.2), and count its classes.

    uv run scripts/tinker/librarian/merge_additions.py cases \
        --requests artifacts/tinker/librarian/e-synth/requests.jsonl \
        --run artifacts/tinker/librarian/verdict-synth --out artifacts/tinker/librarian/verdict-additions
    # the judge gets only <out>/judge/: it reads judge.md and cases.jsonl there and writes decisions.jsonl
    uv run scripts/tinker/librarian/merge_additions.py count \
        --requests artifacts/tinker/librarian/e-synth/requests.jsonl \
        --run artifacts/tinker/librarian/verdict-synth --out artifacts/tinker/librarian/verdict-additions

A merge is a claim a valid answer adds that absorbs one or more memories. MASC
checks what such a claim leaves out: its absorb gate asks, for each absorbed
memory, whether the claim holds that memory's knowledge (`merge_cases.py` puts
the same question to a judge). No check reads what the claim says beyond its
sources, and since RFC-0517 §7.1 a merge that supersedes nothing needs no
supporting candidate (keeper_librarian_runtime.ml `additions`).

A case shows one merge: the memories the claim stands in for (the ones it
absorbs and the one it supersedes), the candidates it cites as the absorb gate
gets them (keeper_librarian_runtime.ml `cited_observations`: candidates that
support the change and whose judgment names the claim) and the claim. Unlike
the gate, a case keeps every cited candidate whatever its size. A claim that
keeps an existing memory's text says nothing new and gets no case.

Each answer comes from the call its row names (`merge_cases.answers_of`).
Answers that make the same merge share one case, and the cases come in an order
drawn from the pinned audit seed. A case shows no label, target, item or memory
ID; the key lists the merges each case stands for, by item, target and the
memory IDs the claim absorbs. The judge's folder works as the drop judge's does
(`e_synth_audit.write_cases`).

`count` makes the cases again from the run and reads the decisions only while
the judge's cases and the key are those, so a folder made from another run, or
from this run before its rows changed, is refused. It counts each target's
merges by class, apart for merges whose claim cites a candidate and merges whose
claim cites none: §7.1 lets the latter in. No gate and no pass line reads these
numbers.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Literal, cast

import admission_validator as AV
import audit_decisions as D
import e_synth_audit as A
import eval_admission as V
import memory_scores as M
import merge_cases as MC
import prompt_facts as PF
import synth_render
import yojson_wire as W

type JsonObject = dict[str, object]
type Addition = Literal["no_addition", "adds_unsupported", "uncertain"]
ADDITIONS: tuple[Addition, ...] = ("no_addition", "adds_unsupported", "uncertain")
CRITERIA: Mapping[Addition, str] = MappingProxyType({
    "no_addition": "proposed_memory 의 내용은 모두 source_memories 나 new_observations 가 말하거나, "
                   "그 말에서 바로 나옵니다.",
    "adds_unsupported": "proposed_memory 가 source_memories 와 new_observations 어디에도 없고, "
                        "그 말에서 바로 나오지도 않는 사실, 조건, 원인, 수, 이름, 때, 상태를 말합니다.",
    "uncertain": "case 만으로는 가를 수 없습니다.",
})
# Merges whose claim cites a candidate, and merges whose claim cites none (RFC-0517 §7.1).
GROUPS = ("citing", "not_citing")
HEADER = """# 더한 말 판정 기준

case 하나는 기억 여러 개를 합쳐 새로 쓴 기억 하나입니다.

- source_memories: proposed_memory 가 대신하는 원래 기억입니다.
- new_observations: proposed_memory 가 근거로 인용한 기억 후보입니다. Keeper 가 이번 턴에 저장해 달라고 냈고, 아직 기억에 없습니다. 없는 case 도 있습니다.
- proposed_memory: 원래 기억 대신 남는 새 기억입니다.

proposed_memory 가 source_memories 와 new_observations 에 없는 말을 더했는지 봅니다.
문장을 바꿔 쓰거나, 합치거나, 순서를 정하거나, 세부를 뺀 것은 더한 말이 아닙니다.
세부가 빠졌는지는 보지 않습니다.
"""

# (item, target, memory IDs the claim absorbs): one merge one target's answer made on one request.
type Made = tuple[str, str, tuple[str, ...]]


def addition(text: object) -> Addition | None:
    """A decision's class, or None when the judge has no such class."""
    return next((a for a in ADDITIONS if a == text), None)


def judging() -> str:
    """The judge's text: what a case shows, the question, and the classes with their criteria."""
    classes = "\n".join(f'- "{a}": {CRITERIA[a]}' for a in ADDITIONS)
    return (f"{HEADER}\ncase 마다 그 case 만 보고 다음 셋 가운데 하나를 고릅니다.\n\n{classes}\n\n"
            "case 마다 decisions.jsonl 에 한 줄을 씁니다. 모든 case 를 빠짐없이 판정합니다.\n"
            '{"case": "a001", "decision": "no_addition", "reason": "한 문장"}\n')


@dataclass(frozen=True, slots=True)
class Merge:
    """What the judge reads for one merged claim: the memories it stands in for, the candidates it
    cites, and the claim."""

    sources: tuple[str, ...]
    observations: tuple[PF.Candidate, ...]
    claim: str


def merges(item: M.SynthItem, answer: AV.AdmissionAnswer) -> list[tuple[tuple[str, ...], Merge]]:
    """(memory IDs the claim absorbs, merge) for each claim the answer adds that absorbs a memory, in the
    order of the claims' first absorbs. Memory IDs and sources come in memory order."""
    claims = M.fact_claims(item.prompt)
    named = {j.request_id: j.memory_claim for j in answer.judgments}
    support = set(answer.change_support)
    added = set(answer.added_claims)
    out: list[tuple[tuple[str, ...], Merge]] = []
    for into in dict.fromkeys(into for _, into in answer.absorbed):
        if into not in added:
            continue
        absorbed = {mid for mid, claim in answer.absorbed if claim == into}
        replaced = absorbed | {mid for mid, claim in answer.revisions if claim == into}
        cited = tuple(c for c in item.prompt.candidates if c.request_id in support and named.get(c.request_id) == into)
        sources = tuple(text for mid, text in claims.items() if mid in replaced)
        out.append((tuple(mid for mid in claims if mid in absorbed), Merge(sources, cited, into)))
    return out


def kept_claims(answer: AV.AdmissionAnswer) -> int:
    """Claims that keep an existing memory's text and absorb other memories: no new words, no case."""
    added = set(answer.added_claims)
    return len({into for _, into in answer.absorbed if into not in added})


def collect(items: dict[str, M.SynthItem],
            answers: dict[tuple[str, str], AV.AdmissionAnswer]) -> dict[Merge, list[Made]]:
    """Each merge with the answers that make it, from the answers by (target, item)."""
    out: dict[Merge, list[Made]] = {}
    for (target, item_id), answer in sorted(answers.items()):
        for mids, merge in merges(items[item_id], answer):
            out.setdefault(merge, []).append((item_id, target, mids))
    return out


def case_json(merge: Merge) -> W.JsonObject:
    members: tuple[tuple[str, W.Json], ...] = (("source_memories", merge.sources),)
    if merge.observations:
        members += (("new_observations", tuple(MC.observation_json(c) for c in merge.observations)),)
    return W.JsonObject((*members, ("proposed_memory", merge.claim)))


def render(collected: dict[Merge, list[Made]], seed: str) -> tuple[list[JsonObject], list[JsonObject]]:
    """The cases in an order drawn from `seed`, and the key: the merges of each case."""
    ordered = list(collected.items())
    random.Random(seed).shuffle(ordered)
    case_rows: list[JsonObject] = []
    key_rows: list[JsonObject] = []
    for n, (merge, made) in enumerate(ordered):
        case_id = f"a{n + 1:03d}"
        case_rows.append({"case": case_id, **cast(JsonObject, json.loads(W.write(case_json(merge))))})
        key_rows.append({"case": case_id, "merges": [[item, target, list(mids)] for item, target, mids in made]})
    return case_rows, key_rows


def made_from(path: Path, run: Path) -> tuple[list[JsonObject], list[JsonObject], JsonObject]:
    """The cases, the key and their summary for the pinned E-synth requests in `path` and the run in `run`."""
    e_synth = A.pinned_run(path, run)
    items = {i.item_id: i for i in V.synth_items(path)}
    answers = MC.answers_of(run, items)
    collected = collect(items, answers)
    case_rows, key_rows = render(collected, f"{e_synth['audit_seed']}:additions")
    summary: JsonObject = {"merges": sum(len(m) for m in collected.values()),
                           "merges_citing": sum(len(m) for merge, m in collected.items() if merge.observations),
                           "kept_claims": sum(kept_claims(a) for a in answers.values()), "cases": len(case_rows)}
    return case_rows, key_rows, summary


def adjudicate(key_rows: list[JsonObject], decisions: list[JsonObject]) -> dict[str, Addition]:
    """The class of each case. SystemExit when a decision is missing, extra, doubled or no class."""
    by_case = D.decisions_by_case(decisions)
    cases = [cast(str, k["case"]) for k in key_rows]
    if set(by_case) != set(cases):
        raise SystemExit(f"decisions cover {len(by_case)} cases, the addition cases are {len(cases)}")
    out: dict[str, Addition] = {}
    for case in cases:
        written = by_case[case].get("decision")
        got = addition(written)
        if got is None:
            raise SystemExit(f"{case}: {written!r} is no class of the addition judge")
        out[case] = got
    return out


def tally(case_rows: list[JsonObject], key_rows: list[JsonObject], judged: dict[str, Addition]) -> JsonObject:
    """Each merge's class, and each target's merges by class, apart for citing and not citing claims."""
    by_target: dict[str, dict[str, dict[str, int]]] = {}
    record: list[JsonObject] = []
    for case, key in zip(case_rows, key_rows, strict=True):
        citing = "new_observations" in case
        judged_as = judged[cast(str, key["case"])]
        for item, target, mids in cast(list[tuple[str, str, list[str]]], key["merges"]):
            groups = by_target.setdefault(target, {g: {"merges": 0, **dict.fromkeys(ADDITIONS, 0)} for g in GROUPS})
            counts = groups["citing" if citing else "not_citing"]
            counts["merges"] += 1
            counts[judged_as] += 1
            record.append({"item": item, "target": target, "absorbs": mids, "citing": citing, "judged": judged_as})
    return {"merges": sorted(record, key=lambda r: (str(r["item"]), str(r["target"]), str(r["absorbs"]))),
            "by_target": {t: by_target[t] for t in sorted(by_target)}}


def count_folder(out: Path, case_rows: list[JsonObject], key_rows: list[JsonObject]) -> JsonObject:
    """The tally of the decisions in <out>, made on `case_rows` with `key_rows`, and the sha256 of the
    judge's files. SystemExit when <out> holds other cases or another key, or a judge file changed."""
    if D.read_jsonl(out / "key.jsonl") != key_rows:
        raise SystemExit(f"the key in {out} was made from another run: run merge_additions.py cases on this run")
    if not (out / D.JUDGE_DIR / D.DECISIONS).is_file():
        raise SystemExit(f"{out / D.JUDGE_DIR} holds no {D.DECISIONS}: the judge has not decided yet")
    files, decisions = D.judge_decisions(out, synth_render.TEMPLATE)
    if D.read_jsonl(out / D.JUDGE_DIR / "cases.jsonl") != case_rows:
        raise SystemExit(f"the cases in {out} were made from another run: run merge_additions.py cases on this run")
    return {**tally(case_rows, key_rows, adjudicate(key_rows, decisions)), "judge_files": files}


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("cases", "count"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--requests", required=True, help="the pinned E-synth requests.jsonl")
        cmd.add_argument("--run", required=True, help="an E-synth run under these pass lines")
        cmd.add_argument("--out", required=True)
    args = ap.parse_args()
    out = Path(cast(str, args.out))
    case_rows, key_rows, summary = made_from(Path(cast(str, args.requests)), Path(cast(str, args.run)))
    if args.cmd == "cases":
        A.write_cases(out, case_rows, key_rows, judging())
        (out / "cases-summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
        print(json.dumps(summary))
        return 0
    print(json.dumps({"summary": summary, **count_folder(out, case_rows, key_rows)}, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
