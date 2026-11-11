# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Sample teacher answers for synthetic training requests and keep those that leave the memory their labels ask for.

    uv run scripts/tinker/librarian/teacher_sample.py sample \
        --requests artifacts/tinker/librarian/train-audited/requests.jsonl \
        --audit artifacts/tinker/librarian/train-audit \
        --out artifacts/tinker/librarian/teacher --budget 10
    uv run scripts/tinker/librarian/teacher_sample.py cases \
        --requests artifacts/tinker/librarian/train-audited/requests.jsonl --out artifacts/tinker/librarian/teacher
    # the judge gets only <out>/merges/judge/: it reads judge.md and cases.jsonl there and writes decisions.jsonl
    uv run scripts/tinker/librarian/teacher_sample.py apply \
        --requests artifacts/tinker/librarian/train-audited/requests.jsonl --out artifacts/tinker/librarian/teacher

The teacher is the base model on the 256K training ID. It gets the request and
the schema instruction as MASC's exact lane sends them, at the reasoning effort
and output budget pass_lines.json sets for a request. Between the two it gets
one more message, which the kept records do not hold: what the request's label
says of each candidate and of current memory (`label_note`). The teacher
follows its label, so a label no judge confirmed would become a wrong training
target. `sample` therefore takes a request only when an --audit folder
(`e_synth_audit.py cases` and `apply`) holds a case for its item ID and none of
them took the request or its memory out. An audit records no sha256 of the
requests it judged, so the item ID is all that ties a request to its case.

Each request gets up to ATTEMPTS answers, and sampling stops at the first
answer that passes MASC's checks and leaves the memory its label asks for
(`memory_scores.score_synth`): every candidate has the label's outcome and
claim and leaves the memory its kind needs, every planted stale fact is
dropped, not absorbed, every planted duplicate pair ends as one fact, and
nothing else is dropped. Answers from other providers are never used for
training. An HTTP error or a missing response is not an attempt: it stops that
request, and a rerun with the same --out sends it again. `sample` starts only
while the files pass_lines.json pins are unchanged
(`eval_admission.load_pass_lines`), so the answers it keeps are scored by the
code the verdict runs.

An answer that absorbs a memory waits in pending.jsonl, whether its label
expects the merge or not: the label says which memory goes, not whether the
claim it goes into keeps its knowledge. `cases` asks the blind merge judge
what MASC's absorb gate asks of each absorb, in the gate's words
(`merge_cases`), as the verdict asks it of measured answers. `apply` keeps a
waiting answer only when every absorb is judged mergeable, the one class under
which the live gate lets a memory go. The judge's folder works as the
verdict's, and `apply` reads the decisions only for the pending.jsonl the cases
were made from.

Output: <out>/calls.jsonl (with the teacher's reasoning), <out>/kept.jsonl and
<out>/pending.jsonl (item, attempt, answer), <out>/summary.json,
<out>/merges/ (the judge's folder and the key), and from `apply`
<out>/accepted.jsonl, the training targets, with <out>/accepted-summary.json.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from collections.abc import Callable, Iterable, Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import assert_never, cast

import admission_validator as AV
import audit_decisions as D
import e_synth_audit as A
import eval_admission as V
import memory_scores as M
import merge_cases as MC
import merge_decisions as MD
import synth_render
import synth_spec as S
from tinker_oai import Caller

TEACHER = "thinkingmachines/Inkling-2-Small:peft:262144"
ATTEMPTS = 4
WORKERS = 8
# The target the merge judge's key names for teacher answers.
TARGET = "teacher"
KEPT, PENDING, ACCEPTED = "kept.jsonl", "pending.jsonl", "accepted.jsonl"
MERGES = "merges"

type JsonObject = dict[str, object]


@dataclass(frozen=True, slots=True)
class Target:
    """A teacher answer that leaves the memory its label asks for. It `waits` for the merge judge
    while it absorbs a memory."""

    record: JsonObject
    waits: bool


@dataclass(frozen=True, slots=True)
class Sampled:
    """One request's teacher answers: the target, why each earlier attempt was not one, and the HTTP
    status that stopped the request."""

    target: Target | None
    rejected: tuple[str, ...]
    http_error: int | None


# The label note is Korean, as the template's memory rules are. It calls a memory or a candidate
# what the template calls it where the template has a word, and names what the answer holds in the
# schema's field names. No particle follows an ID: which one fits depends on the ID's last digit.
NOTE_HEAD = ("이 요청의 후보와 현재 기억을 하나씩 대조해 확인한 사실입니다. 답은 아래 사실과 맞습니다.\n"
             "reason 은 기억과 후보의 내용으로 적고, 이 글은 말하지 않습니다.")
NOTE_UNSUPPORTED = ("- 기억 변경을 지지하는 후보가 없습니다. 현재 기억은 모두 그대로 남습니다. "
                    "new_claims 와 dropped 는 비어 있고 change_support 는 [] 입니다.")
# A correction's or complement's target has its ID in its candidate's line, so this line leaves it out.
NOTE_REST = "- 이 글에 ID 가 나오지 않는 기억은 모두 그대로 남습니다. dropped, absorbs, supersedes 어디에도 없습니다."


def candidate_line(label: S.CandidateLabel, ids: dict[str, str]) -> str:
    """What the label says of one candidate. `ids` gives the short ID of each current claim.
    SystemExit when the label restates a claim current memory does not hold; no request
    `eval_admission.synth_items` reads has such a label."""
    rid = label.request_id
    match label.outcome:
        case "incorporated":
            if label.supersedes is not None:
                return (f"- {rid}: 교정입니다(대상 {label.supersedes}). 대상의 내용은 더는 맞지 않습니다. "
                        "incorporated 이고, 새 claim 의 supersedes 에 대상 ID 가 있으며 같은 ID 가 dropped 에도 있습니다.")
            if label.absorbs is not None:
                return (f"- {rid}: 보완입니다(대상 {label.absorbs}). 대상과 함께 유효한 조건·예외를 더합니다. "
                        "incorporated 이고, 두 내용을 합쳐 쓴 새 claim 의 absorbs 에 대상 ID 가 있습니다.")
            return f"- {rid}: 현재 기억에 없는 새 지식입니다. incorporated 이고, 이 지식을 적은 새 claim 이 들어갑니다."
        case "already_represented":
            target = ids.get(label.already_claim) if label.already_claim is not None else None
            if target is None:
                raise SystemExit(f"{rid}: the label restates a claim current memory does not hold")
            return (f"- {rid}: 이미 기억에 있는 지식입니다(대상 {target}). already_represented 이고, "
                    "memory_claim 은 대상의 claim 그대로입니다. 이 후보로 새 claim 을 쓰지 않고, 대상은 그대로 남습니다.")
        case "not_durable":
            return f"- {rid}: 한 시점의 일시적 상태입니다. not_durable 이고, memory_claim 은 null 입니다."
        case _:
            assert_never(label.outcome)


def memory_lines(label: S.RequestLabel, shown: list[str]) -> list[str]:
    """What the label says of current memory, in the order the prompt shows it (`shown`). A label
    no candidate supports asks for no change, whatever is planted: MASC refuses one."""
    if not label.supports_change:
        return [NOTE_UNSUPPORTED]
    lines: list[str] = []
    for mid in shown:
        if mid in label.scheduled_past:
            lines.append(f"- {mid}: 쓸 날이 이미 지난 기록입니다. dropped 에 있고, 어떤 claim 의 absorbs 에도 없습니다.")
        elif mid in label.planted_stale:
            lines.append(f"- {mid}: 한 시점의 상태만 적은 기억입니다. dropped 에 있고, 어떤 claim 의 absorbs 에도 없습니다.")
        elif mid in label.scheduled_ahead:
            lines.append(f"- {mid}: 쓸 날이 아직 남은 기록입니다. 그대로 남습니다.")
    for a, b in label.duplicates:
        lines.append(f"- {a}, {b}: 같은 지식을 표현만 바꿔 적은 두 기억입니다. 둘 중 남길 기억의 문장을 그대로 복사한 "
                     "claim 이 new_claims 에 있고, 그 absorbs 에 두 ID 가 모두 있습니다.")
    return [*lines, NOTE_REST]


def label_note(item: M.SynthItem) -> str:
    """What the request's label says, as the message the teacher gets between the request and the
    schema instruction."""
    claims = M.fact_claims(item.prompt)
    ids = {claim: mid for mid, claim in claims.items()}
    return "\n".join([NOTE_HEAD, "", "후보", *(candidate_line(c, ids) for c in item.label.candidates),
                      "", "현재 기억", *memory_lines(item.label, list(claims))])


def messages_for(item: M.SynthItem, instruction: str) -> list[str]:
    """What the teacher is sent: the request, the label note, and last the schema instruction, the
    message MASC ends an admission request with."""
    return [item.text, label_note(item), instruction]


def rejection(item: M.SynthItem, check: V.Check) -> str | None:
    """Why the answer cannot be a training target, or None when it can, once its absorbs are judged."""
    if check.answer is None:
        return "invalid:" + check.problems[0]
    score = M.score_synth(item, check.answer)
    if score["correct"] != score["candidates"]:
        return "outcome"
    if score["state_correct"] != score["candidates"]:
        return "memory_state"
    if score["planted_absorbed"]:
        return "stale_absorbed"
    if score["planted_dropped"] != score["planted"]:
        return "stale_kept"
    if score["pairs_merged"] != score["pairs"]:
        return "duplicate_kept"
    if score["dropped"] != score["dropped_expected"]:
        return "unexpected_drop"
    return None


def screened(item: M.SynthItem, check: V.Check, record: JsonObject) -> Target | str:
    """The training target `record` makes, waiting while the answer absorbs a memory, or why it is none."""
    why = rejection(item, check)
    if why is not None:
        return why
    return Target(record, check.answer is not None and bool(check.answer.absorbed))


def write_jsonl(path: Path, rows: list[JsonObject]) -> None:
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


@dataclass(frozen=True, slots=True)
class Audit:
    """What `sample` reads of a finished label audit: the sha256 of its audit.json
    (`e_synth_audit.py apply`), the items its judge decided on, and the items and memories it took out."""

    sha256: str
    judged: frozenset[str]
    items_out: frozenset[str]
    memories_out: frozenset[str]


def audit_of(folder: Path) -> Audit:
    path = folder / "audit.json"
    done = cast(JsonObject, json.loads(path.read_text(encoding="utf-8")))
    return Audit(V.sha256_file(path),
                 frozenset(cast(str, case["item"]) for case in cast(list[JsonObject], done["per_case"])),
                 frozenset(cast(list[str], done["removed_items"])),
                 frozenset(cast(list[str], done["removed_memories"])))


def unconfirmed(item_ids: Iterable[str], audits: Sequence[Audit]) -> list[str]:
    """The items whose label no judge confirmed: no audit holds a case for the item ID, or an audit
    took the item out, alone or with its memory. An audit that kept a request does not overrule
    one that took it out."""
    judged = frozenset[str]().union(*(a.judged for a in audits))
    items_out = frozenset[str]().union(*(a.items_out for a in audits))
    memories_out = frozenset[str]().union(*(a.memories_out for a in audits))
    return sorted(i for i in set(item_ids)
                  if i not in judged or i in items_out or D.memory_of(i) in memories_out)


def sample(args: argparse.Namespace) -> int:
    request = cast(JsonObject, V.load_pass_lines()["request"])
    effort, max_tokens = cast(str, request["reasoning_effort"]), cast(int, request["max_tokens"])
    out, requests = Path(cast(str, args.out)), Path(cast(str, args.requests))
    items = V.synth_items(requests)
    audits = [audit_of(Path(audit)) for audit in cast(list[str], args.audit)]
    without = unconfirmed((item.item_id for item in items), audits)
    if without:
        raise SystemExit(f"no audit confirmed the labels of {len(without)} requests, the first {without[0]}")
    out.mkdir(parents=True, exist_ok=True)
    instruction = V.schema_instruction()
    asked = [(item, messages_for(item, instruction)) for item in items]
    caller = Caller(out / "calls.jsonl", cast(float, args.budget))

    # Each worker returns what it saw; the counts are summed here, outside the worker threads.
    def one(job: tuple[M.SynthItem, list[str]]) -> Sampled:
        item, messages = job
        rejected: list[str] = []
        for attempt in range(ATTEMPTS):
            call = caller.ask(model=TEACHER, label=f"teacher:{item.item_id}", messages=messages,
                              effort=effort, max_tokens=max_tokens, attempt=attempt)
            if call is None:
                return Sampled(None, tuple(rejected), None)
            if not call.replied():
                return Sampled(None, tuple(rejected), call.status)
            record: JsonObject = {"item": item.item_id, "attempt": attempt, "answer": call.answer()}
            got = screened(item, V.check(item.prompt, call.answer()), record)
            if isinstance(got, Target):
                return Sampled(got, tuple(rejected), None)
            rejected.append(got)
        return Sampled(None, tuple(rejected), None)

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        sampled = list(pool.map(one, asked))
    targets = [s.target for s in sampled if s.target is not None]
    write_jsonl(out / KEPT, [t.record for t in targets if not t.waits])
    write_jsonl(out / PENDING, [t.record for t in targets if t.waits])
    summary = {"teacher": TEACHER, "effort": effort, "max_tokens": max_tokens, "label_note": True,
               "audits_sha256": [a.sha256 for a in audits], "requests": len(items),
               "requests_sha256": D.file_sha256(requests), "kept": sum(not t.waits for t in targets),
               "pending": sum(t.waits for t in targets),
               "by_attempt": Counter(cast(int, t.record["attempt"]) for t in targets),
               "rejections": Counter(why for s in sampled for why in s.rejected),
               "http_errors": Counter(s.http_error for s in sampled if s.http_error is not None),
               "spent_usd": round(caller.spent, 4), "stopped": caller.stopped}
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 2 if caller.stopped is not None else 0


def items_of(requests: Path, out: Path) -> dict[str, M.SynthItem]:
    """The sampled requests by item. SystemExit when `requests` is not the file `sample` read."""
    sampled = cast(JsonObject, json.loads((out / "summary.json").read_text(encoding="utf-8")))
    if sampled["requests_sha256"] != D.file_sha256(requests):
        raise SystemExit(f"{out} was sampled from other requests than {requests}")
    return {i.item_id: i for i in V.synth_items(requests)}


def waiting(items: dict[str, M.SynthItem], pending: list[JsonObject]) -> dict[tuple[str, str], AV.AdmissionAnswer]:
    """Each waiting answer by (TARGET, item), as MASC's checks read it."""
    out: dict[tuple[str, str], AV.AdmissionAnswer] = {}
    for record in pending:
        item = items[cast(str, record["item"])]
        answer = V.check(item.prompt, cast(str, record["answer"])).answer
        if answer is None:
            raise SystemExit(f"{item.item_id}: the waiting answer is no longer accepted")
        out[(TARGET, item.item_id)] = answer
    return out


def pending_files(out: Path) -> dict[str, str | None]:
    return {PENDING: D.file_sha256(out / PENDING)}


def cases(args: argparse.Namespace) -> int:
    out = Path(cast(str, args.out))
    items = items_of(Path(cast(str, args.requests)), out)
    slots = MC.guidance(synth_render.TEMPLATE.read_text(encoding="utf-8"))
    collected = MC.collect(items, waiting(items, D.read_jsonl(out / PENDING)), slots)
    case_rows, key_rows = MC.render(collected, f"{pending_files(out)[PENDING]}:teacher-merges")
    folder = out / MERGES
    A.write_cases(folder, case_rows, key_rows, MC.judging(slots))
    (folder / MD.RUN_FILES).write_text(json.dumps(pending_files(out), indent=1) + "\n", encoding="utf-8")
    summary = {"absorbs": sum(len(a) for a in collected.values()), "cases": len(case_rows)}
    (folder / "cases-summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 0


def judged_merges(out: Path, absorbs: frozenset[MD.Absorb]) -> MD.MergeAdjudication:
    """The judge's class for each absorb of the waiting answers. SystemExit when the cases were made
    from another pending.jsonl, or the decisions do not fit them (`merge_decisions.adjudicate`)."""
    if not absorbs:
        return MD.NO_MERGES
    folder = out / MERGES
    if json.loads((folder / MD.RUN_FILES).read_text(encoding="utf-8")) != pending_files(out):
        raise SystemExit(f"the merge cases in {folder} were made from another {PENDING}: run cases again")
    files, decisions = D.judge_decisions(folder, synth_render.TEMPLATE)
    judged = MD.adjudicate(D.read_jsonl(folder / "key.jsonl"), decisions, absorbs)
    return MD.MergeAdjudication(judged.judged, tuple(sorted(files.items())))


def apply(args: argparse.Namespace) -> int:
    out = Path(cast(str, args.out))
    items = items_of(Path(cast(str, args.requests)), out)
    kept, pending = D.read_jsonl(out / KEPT), D.read_jsonl(out / PENDING)
    answers = waiting(items, pending)
    absorbs = frozenset((item, TARGET, mid) for (_, item), answer in answers.items() for mid, _ in answer.absorbed)
    merges = judged_merges(out, absorbs)
    merged = [r for r in pending
              if all(merges.judged.get((cast(str, r["item"]), TARGET, mid)) == "mergeable"
                     for mid, _ in answers[(TARGET, cast(str, r["item"]))].absorbed)]
    write_jsonl(out / ACCEPTED, kept + merged)
    summary = {"kept": len(kept), "pending": len(pending), "merged": len(merged), "accepted": len(kept) + len(merged),
               "absorbs": dict(Counter(merges.judged.values())), "judge_files": dict(merges.judge_files)}
    (out / "accepted-summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    s = sub.add_parser("sample")
    s.add_argument("--requests", required=True)
    s.add_argument("--audit", required=True, nargs="+",
                   help="the --audit folders of `e_synth_audit.py apply` that judged these requests")
    s.add_argument("--out", required=True)
    s.add_argument("--budget", type=float, required=True)
    s.set_defaults(command_run=sample)
    for name, command in (("cases", cases), ("apply", apply)):
        p = sub.add_parser(name)
        p.add_argument("--requests", required=True, help="the requests.jsonl `sample` read")
        p.add_argument("--out", required=True, help="the --out of `sample`")
        p.set_defaults(command_run=command)
    args = ap.parse_args()
    return cast(Callable[[argparse.Namespace], int], args.command_run)(args)


if __name__ == "__main__":
    sys.exit(main())
