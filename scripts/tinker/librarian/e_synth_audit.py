# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Audit the E-synth labels with an independent judge before the pass lines are fixed.

    uv run scripts/tinker/librarian/e_synth_audit.py cases \
        --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
        --run artifacts/tinker/librarian/eval-base-synth --baseline base \
        --sample 1000 --seed 20261109 --out artifacts/tinker/librarian/e-synth-audit
    # the judge gets only <out>/judge/: it reads judge.md and cases.jsonl there and writes decisions.jsonl
    uv run scripts/tinker/librarian/e_synth_audit.py apply \
        --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
        --audit artifacts/tinker/librarian/e-synth-audit \
        --final artifacts/tinker/librarian/e-synth/requests.jsonl
    uv run scripts/tinker/librarian/e_synth_audit.py drops \
        --requests artifacts/tinker/librarian/e-synth/requests.jsonl \
        --run artifacts/tinker/librarian/verdict-synth --out artifacts/tinker/librarian/verdict-drops
    # the same: the judge gets only <out>/judge/

A synthetic request carries its label by construction, and the model that wrote
the text can miss the kind it was asked for. `cases` picks every request whose
baseline answer was valid and disagreed with the label, plus `--sample` of the
rest (answers that agreed, and answers that were not valid). A sample at least
as large as the rest judges every request, so label errors the baseline shares
are found as often as the ones it disagrees with. A case holds the Keeper's
role material, the candidate claims, FULL_FACTS memory facts in full and the
heads of the other facts in the candidates' categories. The facts in full are
those the label or the answer refers to, the planted stale facts, and for every
candidate the SIMILAR facts whose wording overlaps most with it (character
trigrams), filled up with random others (at least MIN_DISTRACTORS), so how many
there are does not tell the judge which ones matter. On E-synth-2 the judges
named 88 restated memories: 66 were among the candidate's three closest, and 11
were judged from a 90-char head. A case shows neither the label nor the answer.

`cases` and `drops` read every request row (`synth_rows.parts_of`) before they
pick any, and stop on a row the generator cannot write. `apply` keeps a request
only when every classification matches its label. A `restates` or
`complements` must name the label's memory alone: the harness scores an
already_represented answer by that claim (memory_scores.claim_matches) and a
complement by the claim that absorbs that memory, so a candidate that points
at another memory as well is ambiguous and goes. The two facts of a planted
duplicate pair must restate each other alone. A fact misfit that involves no
candidate, such as a non-planted fact judged `drop` or restating another fact,
or a planted stale fact judged `keep`, means the memory itself is wrong, so
every request on that memory goes (`audit_decisions.misfits`). Labels are never
rewritten. The misfit rate of the sample estimates the label errors left in the
requests nobody judged.

`drops` runs after the pass lines are fixed, on the verdict's E-synth run. It
makes one case per request where a valid answer dropped a fact off label
(`audit_decisions`), in the same form. Every case of one memory shows the same
facts in full: the ones the label audit picks on any request of that memory
(planted stale facts, candidate targets, each candidate's SIMILAR closest
facts), each fact dropped off label on it, and a fill drawn once per memory
from the pinned audit seed (FULL_FACTS in all, at least MIN_DISTRACTORS more).
A dropped fact is then neither the one fact the cases have in common nor, when
a candidate restates it, the one fact in full that a candidate points at. The
verdict reads the judge's decisions with `--drops`.

The key stays in <out>, since it names the label's classes and the dropped
facts. The judge's folder <out>/judge/ holds the cases, JUDGE, and a copy of
the rules JUDGE names at the same path (`audit_decisions.RULES`). The judge
decides in that folder itself. The sha256 of those three files go beside the
key, and `apply` and the verdict read the decisions only while the files are
unchanged. `cases` and `drops` refuse an <out> whose judge folder already holds
decisions.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import assert_never, cast

import admission_validator as AV
import audit_decisions as D
import eval_admission as V
import memory_scores as M
import synth_render
import synth_rows as RW
import synth_spec as S
from tinker_oai import HTTP_OK, Call, call_from_row

FULL_FACTS = 12
MIN_DISTRACTORS = 2
# Facts shown in full for each candidate because their wording overlaps most with it.
SIMILAR = 3
HEAD = 90
JUDGE = """# E-synth 라벨 감사 판정 기준

한 case는 keeper-librarian admission 요청 하나입니다. Keeper 역할 자료(role), 이번 턴
후보(k1, k2, …), 현재 기억 일부의 전문(facts), 후보 카테고리의 다른 기억 앞부분(context)이
있습니다. 보이지 않는 기억은 판단하지 않습니다.

판단 규칙은 `config/prompts/librarian.md`의 「카테고리와 항목 정리」, 「유지·삭제·교정」,
「남길 지식과 증거」, `admission_policy` 절입니다. 먼저 그 네 절을 읽고, 그 규칙대로 분류하세요.

후보마다 하나를 고릅니다.
- "new": 보이는 기억에 없는 지속 지식이다. 새 결정, 제약, 교훈, 환경 사실.
- "corrects:<m>": 보이는 기억 <m>이 말하는 값·조건·결정 가운데 하나를 바꾸고, 바뀐 내용이 앞으로도 유효하다.
- "complements:<m>": 보이는 기억 <m>은 그대로 참이고, 후보가 같은 갈래에 함께 유효한 조건·예외·근거를 더한다.
  둘은 한 기억으로 묶을 내용이다.
- "restates:<m>": 보이는 기억 <m>(전문이나 앞부분)이 이미 같은 지식을 담는다. 날짜, PR 번호, 이름 같은 부수 정보만 다르다.
  context는 앞 90자만 보이므로, 보이는 글만으로 같은 지식임이 분명할 때만 context의 <m>을 고른다.
  같은 기억의 전문이 받은 다른 case에 나왔으면 그 전문으로 판단해도 된다.
  같은 지식을 담은 기억이 둘 이상이면 모두 쉼표로 적는다. 예: "restates:m3,m7".
- "transient": 지속 지식이 아니다. 진행 중이거나 기다리는 일, 특정 PR·CI·task의 현재 상태,
  큐 길이, 깨움 시각, 턴 진행, 도구 호출, 인사.

전문으로 보이는 기억(facts)마다 하나를 고릅니다.
- "keep": 지금도 참이고 앞으로 기억할 가치가 있다. 다른 기억과 일부가 겹쳐도 같은 지식이 아니면 keep이다.
  지속되는 결정·제약·교훈에 날짜, PR 번호, 설정값 같은 부수 정보가 붙어 있어도 keep이다.
- "restates:<m>": 보이는 다른 기억 <m>이 같은 지식을 담는다. 후보의 "restates"와 같은 기준으로 고른다.
  같은 지식을 담은 두 기억은 서로를 적는다. 예: m5에 "restates:m6", m6에 "restates:m5".
- "drop": 항목 전체가 낡은 상태, 일시적 관측, 쉽게 유도하거나 권위 있는 원천에서 복구할 수 있는 세부다.
- "superseded:<k>": 이번 턴 후보 <k>가 이 기억의 값·조건·결정을 바꾼다.

case마다 decisions.jsonl에 한 줄을 씁니다. 모든 후보와 모든 facts를 빠짐없이 분류합니다.
{"case": "c001", "candidates": {"k1": "new"}, "facts": {"m3": "keep"}, "reasons": {"k1": "한 문장", "m3": "한 문장"}}
"""

type JsonObject = dict[str, object]
KEEP = D.Classed[D.FactVerb]("keep", frozenset())


@dataclass(frozen=True, slots=True)
class Request:
    """A request row as the audit reads it: the facts and candidates `synth_rows.parts_of` reads,
    and the role material a case shows."""

    item_id: str
    role: str
    facts: tuple[S.MemoryFact, ...]
    candidates: tuple[S.Candidate, ...]


def requests_of(path: Path) -> dict[str, Request]:
    """Every request of a requests.jsonl by item ID. SystemExit on a row the generator cannot write,
    such as one an earlier generator wrote."""
    out: dict[str, Request] = {}
    for number, row in enumerate(D.read_jsonl(path), start=1):
        request = cast(JsonObject, row["request"])
        parts = RW.parts_of(request)
        if parts is None:
            raise SystemExit(f"{path}:{number}: the request is not one synth_generate.py writes")
        item_id = cast(str, request["item_id"])
        out[item_id] = Request(item_id, cast(str, cast(JsonObject, request["keeper"])["role_material"]), *parts)
    return out


def write_jsonl(path: Path, rows: list[JsonObject]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


def answers(run: Path, baseline: str) -> dict[str, Call]:
    """The baseline's answered call per item, from the run's call log."""
    prefix = f"synth:{baseline}:"
    out: dict[str, Call] = {}
    for row in D.read_jsonl(run / "calls.jsonl"):
        call = call_from_row(row)
        if call is not None and call.label.startswith(prefix) and call.status == HTTP_OK:
            out[call.label.removeprefix(prefix)] = call
    return out


def agrees(item: M.SynthItem, answer: AV.AdmissionAnswer) -> bool:
    score = M.score_synth(item, answer)
    return (score["correct"] == score["candidates"] and score["planted_dropped"] == score["planted"]
            and score["dropped"] == score["dropped_expected"])


def label_class(candidate: S.Candidate) -> D.Classed[D.CandidateVerb]:
    """The class JUDGE gives a candidate of its label kind."""
    target = frozenset[str]() if candidate.target_memory_id is None else frozenset({candidate.target_memory_id})
    match candidate.kind:
        case S.CandidateKind.NEW_DURABLE:
            return D.Classed("new", frozenset())
        case S.CandidateKind.CORRECTION:
            return D.Classed("corrects", target)
        case S.CandidateKind.COMPLEMENT:
            return D.Classed("complements", target)
        case S.CandidateKind.PARAPHRASE:
            return D.Classed("restates", target)
        case S.CandidateKind.TRANSIENT:
            return D.Classed("transient", frozenset())
        case _:
            assert_never(candidate.kind)


def expected(request: Request) -> tuple[dict[str, D.Classed[D.CandidateVerb]], dict[str, D.Classed[D.FactVerb]]]:
    """What the label means in JUDGE's terms: the class of each candidate ref, and of each memory ID
    the label fixes. A planted stale fact is dropped, a correction target is superseded by its
    candidate, and the two facts of a duplicate pair restate each other; the label keeps the rest."""
    cands = {f"k{i + 1}": label_class(c) for i, c in enumerate(request.candidates)}
    fixed: dict[str, D.Classed[D.FactVerb]] = {}
    for f in request.facts:
        if f.planted_stale:
            fixed[f.memory_id] = D.Classed("drop", frozenset())
        if f.duplicate_of is not None:
            fixed[f.memory_id] = D.Classed("restates", frozenset({f.duplicate_of}))
            fixed[f.duplicate_of] = D.Classed("restates", frozenset({f.memory_id}))
    for i, c in enumerate(request.candidates):
        if c.kind is S.CandidateKind.CORRECTION and c.target_memory_id is not None:
            fixed[c.target_memory_id] = D.Classed("superseded", frozenset({f"k{i + 1}"}))
    return cands, fixed


def trigrams(text: str) -> frozenset[str]:
    squeezed = "".join(text.split())
    return frozenset(squeezed[i:i + 3] for i in range(len(squeezed) - 2))


def closest(claim: str, facts: dict[str, S.MemoryFact], n: int) -> set[str]:
    """The n memory ids whose claims share the most character trigrams with `claim`, relative to the shorter text."""
    mine = trigrams(claim)

    def overlap(memory_id: str) -> float:
        theirs = trigrams(facts[memory_id].claim)
        return len(mine & theirs) / max(1, min(len(mine), len(theirs)))
    return set(sorted(facts, key=lambda m: (-overlap(m), int(m[1:])))[:n])


def answer_refs(request: Request, answer: AV.AdmissionAnswer | None) -> set[str]:
    """Memory IDs an answer refers to: what it drops or revises, and the facts its judgments name."""
    if answer is None:
        return set()
    by_claim = {f.claim: f.memory_id for f in request.facts}
    return (set(answer.dropped) | {old for old, _ in answer.revisions}
            | {by_claim[j.memory_claim] for j in answer.judgments
               if j.memory_claim is not None and j.memory_claim in by_claim})


def render_case(case_id: str, request: Request, full: set[str]) -> tuple[JsonObject, JsonObject]:
    """The judge's case showing the memory IDs `full` in full, and the key its decision is checked against."""
    cands, fixed = expected(request)
    categories = {c.category for c in request.candidates}
    order = sorted(request.facts, key=lambda f: int(f.memory_id[1:]))
    case: JsonObject = {
        "case": case_id, "role": request.role,
        "candidates": [{"ref": f"k{i + 1}", "category": c.category, "claim": c.claim}
                       for i, c in enumerate(request.candidates)],
        "facts": [{"ref": f.memory_id, "category": f.category, "claim": f.claim} for f in order if f.memory_id in full],
        "context": [{"ref": f.memory_id, "category": f.category, "head": f.claim[:HEAD]}
                    for f in order if f.memory_id not in full and f.category in categories]}
    key: JsonObject = {"case": case_id, "item": request.item_id,
                       "candidates": {ref: c.text() for ref, c in cands.items()},
                       "facts": {f.memory_id: fixed.get(f.memory_id, KEEP).text() for f in order if f.memory_id in full},
                       "refs": [f.memory_id for f in order if f.memory_id in full or f.category in categories]}
    return case, key


def label_picks(request: Request) -> set[str]:
    """Memory IDs the label or a candidate's wording points at: the facts the label fixes, the
    candidates' targets, and for every candidate the SIMILAR facts closest to its claim."""
    facts = {f.memory_id: f for f in request.facts}
    _, fixed = expected(request)
    picks = set(fixed) | {c.target_memory_id for c in request.candidates if c.target_memory_id is not None}
    for c in request.candidates:
        picks |= closest(c.claim, facts, SIMILAR)
    return picks


def with_fill(request: Request, suspects: set[str], rng: random.Random) -> set[str]:
    """`suspects` and random other facts of the request: FULL_FACTS in all, at least MIN_DISTRACTORS others."""
    others = sorted({f.memory_id for f in request.facts} - suspects, key=lambda m: int(m[1:]))
    fill = max(FULL_FACTS - len(suspects), MIN_DISTRACTORS)
    return suspects | set(rng.sample(others, min(fill, len(others))))


def case_of(case_id: str, request: Request, shown: set[str], rng: random.Random) -> tuple[JsonObject, JsonObject]:
    """The label audit's case. `shown` are memory IDs to show in full besides the label's picks."""
    return render_case(case_id, request, with_fill(request, label_picks(request) | shown, rng))


def drop_full_sets(drops: D.OffLabel, requests: dict[str, Request], seed: int) -> dict[str, set[str]]:
    """Per memory with an off-label drop, the memory IDs every drop case of it shows in full: the
    label's picks on each of the memory's requests and each fact dropped off label on the memory,
    filled up with facts drawn once for the memory."""
    out: dict[str, set[str]] = {}
    for memory, dropped in sorted(D.dropped_on_memory(drops).items()):
        mine = [r for item, r in sorted(requests.items()) if D.memory_of(item) == memory]
        if any(r.facts != mine[0].facts for r in mine):
            raise SystemExit(f"{memory}: its requests carry different facts, so one fact set cannot serve them")
        suspects = dropped.union(*(label_picks(r) for r in mine))
        out[memory] = with_fill(mine[0], suspects, random.Random(f"{seed}:{memory}"))
    return out


def write_cases(out: Path, case_rows: list[JsonObject], key_rows: list[JsonObject]) -> None:
    """The key and the sha256 of the judge's files in <out>; the cases, JUDGE and a copy of the rules
    JUDGE names (synth_render.TEMPLATE) in the judge's folder, which the key never enters. SystemExit
    when that folder already holds decisions: they were made on the cases written there before."""
    judge = out / D.JUDGE_DIR
    if (judge / D.DECISIONS).exists():
        raise SystemExit(f"{judge} already holds a judge's {D.DECISIONS}: write the cases to a new --out")
    write_jsonl(out / "key.jsonl", key_rows)
    write_jsonl(judge / "cases.jsonl", case_rows)
    (judge / "judge.md").write_text(JUDGE, encoding="utf-8")
    (judge / D.RULES).parent.mkdir(parents=True, exist_ok=True)
    (judge / D.RULES).write_bytes(synth_render.TEMPLATE.read_bytes())
    D.record_judge_files(out)


def cases(args: argparse.Namespace) -> int:
    path = Path(cast(str, args.requests))
    by_id = requests_of(path)
    items = {i.item_id: i for i in V.synth_items(path)}
    calls = answers(Path(cast(str, args.run)), cast(str, args.baseline))
    disagree: list[str] = []
    agree: list[str] = []
    invalid: list[str] = []
    parsed: dict[str, AV.AdmissionAnswer] = {}
    for item_id, item in items.items():
        call = calls.get(item_id)
        check = V.check(item.prompt, call.answer() if call is not None else None)
        if check.answer is None:
            invalid.append(item_id)
            continue
        parsed[item_id] = check.answer
        (agree if agrees(item, check.answer) else disagree).append(item_id)
    rng = random.Random(cast(int, args.seed))
    # The sample estimates label errors in every request nobody judges: the agreeing ones
    # and the ones whose baseline answer was not valid.
    unjudged = sorted(agree + invalid)
    sample = sorted(rng.sample(unjudged, min(cast(int, args.sample), len(unjudged))))
    picked = [(i, "disagreement") for i in sorted(disagree)] + [(i, "sample") for i in sample]
    out = Path(cast(str, args.out))
    case_rows: list[JsonObject] = []
    key_rows: list[JsonObject] = []
    for n, (item_id, why) in enumerate(picked):
        case, key = case_of(f"c{n + 1:03d}", by_id[item_id], answer_refs(by_id[item_id], parsed.get(item_id)), rng)
        case_rows.append(case)
        key_rows.append({**key, "picked": why})
    write_cases(out, case_rows, key_rows)
    summary = {"requests": len(items), "baseline_invalid": len(invalid), "agree": len(agree),
               "disagree": len(disagree), "sample": len(sample), "cases": len(case_rows)}
    (out / "cases-summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 0


def apply(args: argparse.Namespace) -> int:
    audit = Path(cast(str, args.audit))
    keys = {cast(str, k["case"]): k for k in D.read_jsonl(audit / "key.jsonl")}
    decisions = D.decisions_by_case(D.judge_decisions(audit, synth_render.TEMPLATE)[1])
    if set(decisions) != set(keys):
        raise SystemExit(f"decisions cover {len(decisions)} cases, the audit has {len(keys)}")
    removed_items: set[str] = set()
    removed_memories: set[str] = set()
    per_case: list[JsonObject] = []
    for case_id, key in sorted(keys.items()):
        request, memory = D.misfits(key, decisions[case_id])
        item = cast(str, key["item"])
        if request:
            removed_items.add(item)
        if memory:
            removed_memories.add(D.memory_of(item))
        per_case.append({"case": case_id, "item": item, "picked": key["picked"],
                         "request_misfits": request, "memory_misfits": memory})
    rows = D.read_jsonl(Path(cast(str, args.requests)))
    kept = [r for r in rows if (i := cast(str, cast(JsonObject, r["request"])["item_id"])) not in removed_items
            and D.memory_of(i) not in removed_memories]
    write_jsonl(Path(cast(str, args.final)), kept)
    sampled = [c for c in per_case if c["picked"] == "sample"]
    summary = {"requests_in": len(rows), "requests_out": len(kept), "cases": len(per_case),
               "removed_items": sorted(removed_items), "removed_memories": sorted(removed_memories),
               "sample_cases": len(sampled),
               "sample_misfit_rate": (sum(bool(c["request_misfits"] or c["memory_misfits"]) for c in sampled)
                                      / len(sampled)) if sampled else None,
               "per_case": per_case}
    (audit / "audit.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in summary.items() if k != "per_case"}))
    return 0


def drops(args: argparse.Namespace) -> int:
    lines = V.load_pass_lines()
    e_synth = cast(JsonObject, lines["e_synth"])
    path, run = Path(cast(str, args.requests)), Path(cast(str, args.run))
    if V.sha256_file(path) != e_synth["requests_sha256"]:
        raise SystemExit("the E-synth requests differ from pass_lines.json")
    run_summary = cast(JsonObject, json.loads((run / "summary.json").read_text(encoding="utf-8")))
    if (run_summary["set"], run_summary["pass_lines_sha256"]) != ("synth", V.sha256_file(V.PASS_LINES)):
        raise SystemExit("--run is not an E-synth run under these pass lines")
    by_id = requests_of(path)
    off = D.off_label(V.read_rows(run))
    full = drop_full_sets(off, by_id, cast(int, e_synth["audit_seed"]))
    case_rows: list[JsonObject] = []
    key_rows: list[JsonObject] = []
    for n, (item_id, mids) in enumerate(off.items()):
        case, key = render_case(f"d{n + 1:03d}", by_id[item_id], full[D.memory_of(item_id)])
        case_rows.append(case)
        key_rows.append({**key, "off_label": mids})
    out = Path(cast(str, args.out))
    write_cases(out, case_rows, key_rows)
    summary = {"items": len(off), "off_label_drops": sum(len(m) for m in off.values()), "cases": len(case_rows)}
    (out / "cases-summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    c = sub.add_parser("cases")
    c.add_argument("--requests", required=True)
    c.add_argument("--run", required=True, help="a harness run of the baseline on these requests")
    c.add_argument("--baseline", required=True)
    c.add_argument("--sample", type=int, required=True)
    c.add_argument("--seed", type=int, required=True)
    c.add_argument("--out", required=True)
    a = sub.add_parser("apply")
    a.add_argument("--requests", required=True)
    a.add_argument("--audit", required=True)
    a.add_argument("--final", required=True)
    d = sub.add_parser("drops")
    d.add_argument("--requests", required=True, help="the pinned E-synth requests.jsonl")
    d.add_argument("--run", required=True, help="the verdict's E-synth run")
    d.add_argument("--out", required=True)
    args = ap.parse_args()
    match cast(str, args.command):
        case "cases":
            return cases(args)
        case "apply":
            return apply(args)
        case "drops":
            return drops(args)
        case other:
            raise SystemExit(f"unknown command {other!r}")


if __name__ == "__main__":
    sys.exit(main())
