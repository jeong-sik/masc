# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Audit the E-synth labels with an independent judge before the pass lines are fixed.

    uv run scripts/tinker/librarian/e_synth_audit.py cases \
        --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
        --run artifacts/tinker/librarian/eval-base-synth --baseline base \
        --sample 30 --seed 20261109 --out artifacts/tinker/librarian/e-synth-audit
    # the judge reads <out>/judge.md and <out>/cases.jsonl, and writes <out>/decisions.jsonl
    uv run scripts/tinker/librarian/e_synth_audit.py apply \
        --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
        --audit artifacts/tinker/librarian/e-synth-audit \
        --final artifacts/tinker/librarian/e-synth/requests.jsonl

A synthetic request carries its label by construction, and the model that wrote
the text can miss the kind it was asked for. `cases` picks every request whose
baseline answer was valid and disagreed with the label, plus `--sample` of the
rest (answers that agreed, and answers that were not valid). A case holds the
Keeper's role material, the
candidate claims, some memory facts in full (those the label or the answer
refers to, the planted stale facts, and DISTRACTORS random others) and the heads
of the other facts in the candidates' categories. A case shows neither the
label nor the answer.

`apply` keeps a request only when every classification matches its label. A
non-planted fact judged `drop`, or a planted stale fact judged `keep`, means the
memory itself is wrong, so every request on that memory goes. Labels are never
rewritten. The misfit rate of the sample estimates the label errors left in the
requests nobody judged.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path
from typing import cast

import admission_validator as AV
import eval_admission as V
from tinker_oai import HTTP_OK, Call, call_from_row

DISTRACTORS = 2
HEAD = 90
JUDGE = """# E-synth 라벨 감사 판정 기준

한 case는 keeper-librarian admission 요청 하나입니다. Keeper 역할 자료(role), 이번 턴
후보(k1, k2, …), 현재 기억 일부의 전문(facts), 후보 카테고리의 다른 기억 앞부분(context)이
있습니다. 보이지 않는 기억은 판단하지 않습니다.

판단 규칙은 `config/prompts/librarian.md`의 「유지·삭제·교정」, 「남길 지식과 증거」,
`admission_policy` 절입니다. 먼저 그 세 절을 읽고, 그 규칙대로 분류하세요.

후보마다 하나를 고릅니다.
- "new": 보이는 기억에 없는 지속 지식이다. 새 결정, 제약, 교훈, 환경 사실.
- "corrects:<m>": 보이는 기억 <m>이 말하는 값·조건·결정 가운데 하나를 바꾸고, 바뀐 내용이 앞으로도 유효하다.
- "restates:<m>": 보이는 기억 <m>(전문이나 앞부분)이 이미 같은 지식을 담는다. 날짜, PR 번호, 이름 같은 부수 정보만 다르다.
  context는 앞 90자만 보이므로, 보이는 글만으로 같은 지식임이 분명할 때만 context의 <m>을 고른다.
- "transient": 지속 지식이 아니다. 진행 중이거나 기다리는 일, 특정 PR·CI·task의 현재 상태,
  큐 길이, 깨움 시각, 턴 진행, 도구 호출, 인사.

전문으로 보이는 기억(facts)마다 하나를 고릅니다.
- "keep": 지금도 참이고 앞으로 기억할 가치가 있다. 다른 기억과 겹쳐도 keep이다. 겹침은 삭제가 아니라 묶기로 없앤다.
  지속되는 결정·제약·교훈에 날짜, PR 번호, 설정값 같은 부수 정보가 붙어 있어도 keep이다.
- "drop": 항목 전체가 낡은 상태, 일시적 관측, 쉽게 유도하거나 권위 있는 원천에서 복구할 수 있는 세부다.
- "superseded:<k>": 이번 턴 후보 <k>가 이 기억의 값·조건·결정을 바꾼다.

case마다 decisions.jsonl에 한 줄을 씁니다. 모든 후보와 모든 facts를 빠짐없이 분류합니다.
{"case": "c001", "candidates": {"k1": "new"}, "facts": {"m3": "keep"}, "reasons": {"k1": "한 문장", "m3": "한 문장"}}
"""

type JsonObject = dict[str, object]


def read_jsonl(path: Path) -> list[JsonObject]:
    return [cast(JsonObject, json.loads(line)) for line in path.read_text(encoding="utf-8").splitlines()]


def write_jsonl(path: Path, rows: list[JsonObject]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


def memory_of(item_id: str) -> str:
    """`<split>-<memory key>-<index>`; the memory key names one generated memory."""
    return item_id.rsplit("-", 1)[0]


def answers(run: Path, baseline: str) -> dict[str, Call]:
    """The baseline's answered call per item, from the run's call log."""
    prefix = f"synth:{baseline}:"
    out: dict[str, Call] = {}
    for row in read_jsonl(run / "calls.jsonl"):
        call = call_from_row(row)
        if call is not None and call.label.startswith(prefix) and call.status == HTTP_OK:
            out[call.label.removeprefix(prefix)] = call
    return out


def agrees(item: V.SynthItem, answer: AV.AdmissionAnswer) -> bool:
    score = V.score_synth(item, answer)
    return (score["correct"] == score["candidates"] and score["planted_dropped"] == score["planted"]
            and score["dropped"] == score["dropped_expected"])


def expected(request: JsonObject) -> tuple[dict[str, str], dict[str, str]]:
    """What the label means in judge terms: per candidate ref and per memory id with a fixed status."""
    cands: dict[str, str] = {}
    facts: dict[str, str] = {}
    for i, c in enumerate(cast(list[JsonObject], request["candidates"])):
        ref, target = f"k{i + 1}", cast(str | None, c["target_memory_id"])
        match c["kind"]:
            case "new_durable":
                cands[ref] = "new"
            case "correction":
                cands[ref], facts[cast(str, target)] = f"corrects:{target}", f"superseded:{ref}"
            case "paraphrase":
                cands[ref] = f"restates:{target}"
            case "transient":
                cands[ref] = "transient"
            case other:
                raise SystemExit(f"unknown candidate kind {other!r}")
    for f in cast(list[JsonObject], request["facts"]):
        if f["planted_stale"]:
            facts[cast(str, f["memory_id"])] = "drop"
    return cands, facts


def case_of(case_id: str, request: JsonObject, answer: AV.AdmissionAnswer | None,
            rng: random.Random) -> tuple[JsonObject, JsonObject]:
    """The judge's case and the key that `apply` checks it against."""
    facts = {cast(str, f["memory_id"]): f for f in cast(list[JsonObject], request["facts"])}
    cands, fixed = expected(request)
    full = set(fixed) | {cast(str, c["target_memory_id"]) for c in cast(list[JsonObject], request["candidates"])
                         if c["target_memory_id"] is not None}
    if answer is not None:
        by_claim = {cast(str, f["claim"]): mid for mid, f in facts.items()}
        full |= set(answer.dropped) | {old for old, _ in answer.revisions}
        full |= {by_claim[j.memory_claim] for j in answer.judgments
                 if j.memory_claim is not None and j.memory_claim in by_claim}
    others = sorted(set(facts) - full, key=lambda m: int(m[1:]))
    full |= set(rng.sample(others, min(DISTRACTORS, len(others))))
    categories = {cast(str, c["category"]) for c in cast(list[JsonObject], request["candidates"])}
    order = sorted(facts, key=lambda m: int(m[1:]))
    keeper = cast(JsonObject, request["keeper"])
    case: JsonObject = {
        "case": case_id, "role": keeper["role_material"],
        "candidates": [{"ref": f"k{i + 1}", "category": c["category"], "claim": c["claim"]}
                       for i, c in enumerate(cast(list[JsonObject], request["candidates"]))],
        "facts": [{"ref": m, "category": facts[m]["category"], "claim": facts[m]["claim"]} for m in order if m in full],
        "context": [{"ref": m, "category": facts[m]["category"], "head": cast(str, facts[m]["claim"])[:HEAD]}
                    for m in order if m not in full and facts[m]["category"] in categories]}
    key: JsonObject = {"case": case_id, "item": request["item_id"], "candidates": cands,
                       "facts": {m: fixed.get(m, "keep") for m in order if m in full},
                       "refs": [m for m in order if m in full or facts[m]["category"] in categories]}
    return case, key


def cases(args: argparse.Namespace) -> int:
    requests = read_jsonl(Path(cast(str, args.requests)))
    items = {i.item_id: i for i in V.synth_items(Path(cast(str, args.requests)))}
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
    by_id = {cast(str, cast(JsonObject, r["request"])["item_id"]): cast(JsonObject, r["request"]) for r in requests}
    out = Path(cast(str, args.out))
    case_rows: list[JsonObject] = []
    key_rows: list[JsonObject] = []
    for n, (item_id, why) in enumerate(picked):
        case, key = case_of(f"c{n + 1:03d}", by_id[item_id], parsed.get(item_id), rng)
        case_rows.append(case)
        key_rows.append({**key, "picked": why})
    write_jsonl(out / "cases.jsonl", case_rows)
    write_jsonl(out / "key.jsonl", key_rows)
    (out / "judge.md").write_text(JUDGE, encoding="utf-8")
    summary = {"requests": len(items), "baseline_invalid": len(invalid), "agree": len(agree),
               "disagree": len(disagree), "sample": len(sample), "cases": len(case_rows)}
    (out / "cases-summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 0


def misfits(key: JsonObject, decision: JsonObject) -> tuple[list[str], list[str]]:
    """(request-level misfits, memory-level misfits) as ID-only strings, or SystemExit on a malformed decision."""
    case = cast(str, key["case"])
    refs = set(cast(list[str], key["refs"]))
    want_c, want_f = cast(dict[str, str], key["candidates"]), cast(dict[str, str], key["facts"])
    got_c, got_f = cast(dict[str, str], decision.get("candidates", {})), cast(dict[str, str], decision.get("facts", {}))
    if set(got_c) != set(want_c) or set(got_f) != set(want_f):
        raise SystemExit(f"{case}: the decision does not classify exactly the case's candidates and facts")
    request: list[str] = []
    memory: list[str] = []
    for ref, want in want_c.items():
        got = got_c[ref]
        verb, _, target = got.partition(":")
        if verb not in {"new", "transient", "restates", "corrects"} or (bool(target) != (verb in {"restates", "corrects"})):
            raise SystemExit(f"{case}: {ref} has an unknown classification {got!r}")
        if target and target not in refs:
            raise SystemExit(f"{case}: {ref} names {target}, which the case does not show")
        fits = got.startswith("restates:") if want.startswith("restates:") else got == want
        if not fits:
            request.append(f"{ref} expect {want} got {got}")
    for mid, want in want_f.items():
        got = got_f[mid]
        verb, _, target = got.partition(":")
        if verb not in {"keep", "drop", "superseded"} or (bool(target) != (verb == "superseded")):
            raise SystemExit(f"{case}: {mid} has an unknown classification {got!r}")
        if target and target not in want_c:
            raise SystemExit(f"{case}: {mid} names {target}, which is not a candidate of the case")
        if got == want:
            continue
        line = f"{mid} expect {want} got {got}"
        flawed = (want == "keep" and got == "drop") or (want == "drop" and got == "keep")
        (memory if flawed else request).append(line)
    return request, memory


def apply(args: argparse.Namespace) -> int:
    audit = Path(cast(str, args.audit))
    keys = {cast(str, k["case"]): k for k in read_jsonl(audit / "key.jsonl")}
    decisions = {cast(str, d["case"]): d for d in read_jsonl(audit / "decisions.jsonl")}
    if set(decisions) != set(keys):
        raise SystemExit(f"decisions cover {len(decisions)} cases, the audit has {len(keys)}")
    removed_items: set[str] = set()
    removed_memories: set[str] = set()
    per_case: list[JsonObject] = []
    for case_id, key in sorted(keys.items()):
        request, memory = misfits(key, decisions[case_id])
        item = cast(str, key["item"])
        if request:
            removed_items.add(item)
        if memory:
            removed_memories.add(memory_of(item))
        per_case.append({"case": case_id, "item": item, "picked": key["picked"],
                         "request_misfits": request, "memory_misfits": memory})
    rows = read_jsonl(Path(cast(str, args.requests)))
    kept = [r for r in rows if (i := cast(str, cast(JsonObject, r["request"])["item_id"])) not in removed_items
            and memory_of(i) not in removed_memories]
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
    args = ap.parse_args()
    return cases(args) if args.command == "cases" else apply(args)


if __name__ == "__main__":
    sys.exit(main())
