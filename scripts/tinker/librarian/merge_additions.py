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
sources.

A case shows one merge: the memories the claim stands in for (the ones it
absorbs and the ones it supersedes), the candidates it cites as the absorb gate
gets them (keeper_librarian_runtime.ml `cited_observations`: candidates that
support the change and whose judgment names the claim) and the claim. Unlike
the gate, a case keeps every cited candidate whatever its size. A claim that
keeps an existing memory's text says nothing new and gets no case.

Each answer comes from the call its row names (`merge_cases.answers_of`).
Answers that make the same merge share one case, and the cases come in an order
drawn from the pinned audit seed. A case shows no label, target, item or memory
ID; the key lists the merges each case stands for, by item, target, the memory
IDs the claim absorbs and whether the merge is supported. The judge's folder
holds only the cases and judge.md: the judge gets none of librarian.md, so the
absorb gate's classes do not reach it.

The count splits merges in two. A supported merge has a candidate that supports
the change and whose judgment incorporates the claim: before RFC-0517 §7.1
every new claim needed one (`verify_support`). A merge-only merge has none, so
only §7.1 lets it in (keeper_librarian_runtime.ml `additions`), whatever
`already_represented` candidates it cites.

`count` makes the cases, the key and judge.md again from the run and this
module, and reads the decisions only while the folder holds exactly those, so a
folder made from another run, from this run before its rows changed, or under
other criteria is refused. Decisions are not bound to the cases they were made
on: ones copied in from another folder with the same case IDs pass. The output
holds the sha256 of the judge's files. No gate and no pass line reads the counts.
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
GROUPS = ("supported", "merge_only")
HEADER = """# 더한 말 판정 기준

case 하나는 기억 여러 개를 합쳐 새로 쓴 기억 하나입니다.

- source_memories: proposed_memory 가 대신하는 원래 기억입니다.
- new_observations: proposed_memory 가 근거로 인용한 기억 후보입니다. Keeper 가 이번 턴에 저장해 달라고 냈고, 아직 기억에 없습니다. 없는 case 도 있습니다.
- proposed_memory: 원래 기억 대신 남는 새 기억입니다.

proposed_memory 가 source_memories 와 new_observations 에 없는 말을 더했는지 봅니다.
문장을 바꿔 쓰거나, 합치거나, 순서를 정하거나, 세부를 뺀 것은 더한 말이 아닙니다.
세부가 빠졌는지는 보지 않습니다.
"""
KEY, CASES, JUDGING = "key.jsonl", "cases.jsonl", "judge.md"

# (item, target, memory IDs the claim absorbs, supported): one merge one target's answer made on one request.
type Made = tuple[str, str, tuple[str, ...], bool]


def addition(text: object) -> Addition | None:
    """A decision's class, or None when the judge has no such class."""
    return next((a for a in ADDITIONS if a == text), None)


def judging() -> str:
    """The judge's text: what a case shows, the question, and the classes with their criteria."""
    classes = "\n".join(f'- "{a}": {CRITERIA[a]}' for a in ADDITIONS)
    return (f"{HEADER}\ncase 마다 그 case 만 보고 다음 셋 가운데 하나를 고릅니다.\n\n{classes}\n\n"
            "case 마다 decisions.jsonl 에 한 줄을 씁니다. 모든 case 를 빠짐없이 판정합니다.\n"
            '{"case": "a001", "decision": "no_addition", "reason": "한 문장"}\n')


def seed_of(audit_seed: object) -> str:
    """The order of the cases, drawn apart from the merge judge's (`:merges`)."""
    return f"{audit_seed}:additions"


@dataclass(frozen=True, slots=True)
class Merge:
    """What the judge reads for one merged claim: the memories it stands in for, the candidates it
    cites, and the claim."""

    sources: tuple[str, ...]
    observations: tuple[PF.Candidate, ...]
    claim: str


def merges(item: M.SynthItem, answer: AV.AdmissionAnswer) -> list[tuple[tuple[str, ...], bool, Merge]]:
    """(memory IDs the claim absorbs, supported, merge) for each claim the answer adds that absorbs a memory,
    in the order of the claims' first absorbs. Memory IDs and sources come in memory order."""
    claims = M.fact_claims(item.prompt)
    named = {j.request_id: j.memory_claim for j in answer.judgments}
    support = set(answer.change_support)
    added = set(answer.added_claims)
    out: list[tuple[tuple[str, ...], bool, Merge]] = []
    for into in dict.fromkeys(into for _, into in answer.absorbed):
        if into not in added:
            continue
        absorbed = {mid for mid, claim in answer.absorbed if claim == into}
        replaced = absorbed | {mid for mid, claim in answer.revisions if claim == into}
        cited = tuple(c for c in item.prompt.candidates if c.request_id in support and named.get(c.request_id) == into)
        supported = any(j.request_id in support and j.outcome == "incorporated" and j.memory_claim == into
                        for j in answer.judgments)
        sources = tuple(text for mid, text in claims.items() if mid in replaced)
        out.append((tuple(mid for mid in claims if mid in absorbed), supported, Merge(sources, cited, into)))
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
        for mids, supported, merge in merges(items[item_id], answer):
            out.setdefault(merge, []).append((item_id, target, mids, supported))
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
        key_rows.append({"case": case_id, "merges": [[item, target, list(mids), supported]
                                                     for item, target, mids, supported in made]})
    return case_rows, key_rows


@dataclass(frozen=True, slots=True)
class Cases:
    """The cases and the key for one run, their summary, and the targets with a valid answer."""

    case_rows: list[JsonObject]
    key_rows: list[JsonObject]
    summary: JsonObject
    targets: tuple[str, ...]


def made(items: dict[str, M.SynthItem], answers: dict[tuple[str, str], AV.AdmissionAnswer],
         audit_seed: object) -> Cases:
    collected = collect(items, answers)
    case_rows, key_rows = render(collected, seed_of(audit_seed))
    summary: JsonObject = {"merges": sum(len(m) for m in collected.values()),
                           "merges_supported": sum(m[3] for ms in collected.values() for m in ms),
                           "kept_claims": sum(kept_claims(a) for a in answers.values()), "cases": len(case_rows)}
    return Cases(case_rows, key_rows, summary, tuple(sorted({target for target, _ in answers})))


def made_from(path: Path, run: Path) -> Cases:
    """The cases for the pinned E-synth requests in `path` and the E-synth run in `run`. SystemExit unless
    both are the pinned ones (`e_synth_audit.pinned_run`)."""
    e_synth = A.pinned_run(path, run)
    items = {i.item_id: i for i in V.synth_items(path)}
    return made(items, MC.answers_of(run, items), e_synth["audit_seed"])


def write_folder(out: Path, cases: Cases) -> None:
    """The key in <out>; the cases and judge.md in the judge's folder, which the key never enters.
    SystemExit when that folder already holds decisions: they were made on the cases written there before."""
    judge = out / D.JUDGE_DIR
    if (judge / D.DECISIONS).exists():
        raise SystemExit(f"{judge} already holds a judge's {D.DECISIONS}: write the cases to a new --out")
    A.write_jsonl(out / KEY, cases.key_rows)
    A.write_jsonl(judge / CASES, cases.case_rows)
    (judge / JUDGING).write_text(judging(), encoding="utf-8")


def adjudicate(key_rows: list[JsonObject], decisions: list[JsonObject]) -> dict[str, Addition]:
    """The class of each case. SystemExit when a decision is missing, extra, doubled or no class."""
    by_case = D.decisions_by_case(decisions)
    case_ids = [cast(str, k["case"]) for k in key_rows]
    if set(by_case) != set(case_ids):
        raise SystemExit(f"decisions cover {len(by_case)} cases, the addition cases are {len(case_ids)}")
    out: dict[str, Addition] = {}
    for case in case_ids:
        written = by_case[case].get("decision")
        got = addition(written)
        if got is None:
            raise SystemExit(f"{case}: {written!r} is no class of the addition judge")
        out[case] = got
    return out


def tally(key_rows: list[JsonObject], judged: dict[str, Addition], targets: tuple[str, ...]) -> JsonObject:
    """Each merge's class, and each target's merges by class, apart for supported and merge-only merges."""
    by_target = {t: {g: {"merges": 0, **dict.fromkeys(ADDITIONS, 0)} for g in GROUPS} for t in targets}
    record: list[JsonObject] = []
    for key in key_rows:
        judged_as = judged[cast(str, key["case"])]
        for item, target, mids, supported in cast(list[tuple[str, str, list[str], bool]], key["merges"]):
            counts = by_target[target]["supported" if supported else "merge_only"]
            counts["merges"] += 1
            counts[judged_as] += 1
            record.append({"item": item, "target": target, "absorbs": mids, "supported": supported,
                           "judged": judged_as})
    return {"merges": sorted(record, key=lambda r: (str(r["item"]), str(r["target"]), str(r["absorbs"]))),
            "by_target": by_target}


def count_folder(out: Path, cases: Cases) -> JsonObject:
    """The tally of the decisions in <out> on `cases`, and the sha256 of the judge's files. SystemExit
    when <out> holds no cases, other cases, another key or another judge.md, or no decisions on its cases."""
    judge = out / D.JUDGE_DIR
    if not (out / KEY).is_file():
        raise SystemExit(f"{out} holds no addition cases: run merge_additions.py cases first")
    if D.read_jsonl(out / KEY) != cases.key_rows or D.read_jsonl(judge / CASES) != cases.case_rows:
        raise SystemExit(f"the cases in {out} were made from another run: run merge_additions.py cases on this run")
    if (judge / JUDGING).read_text(encoding="utf-8") != judging():
        raise SystemExit(f"{judge / JUDGING} is not this module's judging text: the criteria changed")
    if cases.case_rows and not (judge / D.DECISIONS).is_file():
        raise SystemExit(f"{judge} holds no {D.DECISIONS}: the judge has not decided yet")
    decisions = D.read_jsonl(judge / D.DECISIONS) if cases.case_rows else []
    files = {name: D.file_sha256(judge / name) for name in (CASES, JUDGING, D.DECISIONS)}
    return {**tally(cases.key_rows, adjudicate(cases.key_rows, decisions), cases.targets), "judge_files": files}


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
    cases = made_from(Path(cast(str, args.requests)), Path(cast(str, args.run)))
    if args.cmd == "cases":
        write_folder(out, cases)
        (out / "cases-summary.json").write_text(json.dumps(cases.summary, indent=1) + "\n", encoding="utf-8")
        print(json.dumps(cases.summary))
        return 0
    print(json.dumps({"summary": cases.summary, **count_folder(out, cases)}, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
