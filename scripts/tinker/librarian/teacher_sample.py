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
requests it judged, so the item ID is all that ties a request to its case. A
kept record names its request by item ID too, so requests of which two share
one are not sampled.

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
Training reads the targets from kept.jsonl, pending.jsonl and the judge's
decisions as `apply` does (`accepted`), not from accepted.jsonl. `cases`,
`apply` and training take a record only when its answer is the reply the call
log holds for its request, asked as `sample` asks it now, and the answer is
still the target its file holds (`target_answer`). They stop at a record that
is not, at a request with two records, and at a record file that holds another
number of records than the summary counts.
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
from tinker_oai import Call, Caller, call_from_row, call_key

TEACHER = "thinkingmachines/Inkling-2-Small:peft:262144"
ATTEMPTS = 4
WORKERS = 8
# The target the merge judge's key names for teacher answers.
TARGET = "teacher"
CALLS, KEPT, PENDING, ACCEPTED = "calls.jsonl", "kept.jsonl", "pending.jsonl", "accepted.jsonl"
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
    """What the label says of current memory, in the order the prompt shows it (`shown`), whatever
    the candidates: MASC takes these drops and merges without a supporting candidate (RFC-0517 §7.1)."""
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


def by_item(items: list[M.SynthItem]) -> dict[str, M.SynthItem]:
    """The requests by item ID. A record names its request by that ID alone, as an audit names the
    request of a case. SystemExit when two requests share one."""
    shared = sorted(item_id for item_id, n in Counter(item.item_id for item in items).items() if n > 1)
    if shared:
        raise SystemExit(f"{len(shared)} item IDs name more than one request, the first {shared[0]}")
    return {item.item_id: item for item in items}


def sample(args: argparse.Namespace) -> int:
    request = cast(JsonObject, V.load_pass_lines()["request"])
    effort, max_tokens = cast(str, request["reasoning_effort"]), cast(int, request["max_tokens"])
    out, requests = Path(cast(str, args.out)), Path(cast(str, args.requests))
    items = list(by_item(V.synth_items(requests)).values())
    audits = [audit_of(Path(audit)) for audit in cast(list[str], args.audit)]
    without = unconfirmed((item.item_id for item in items), audits)
    if without:
        raise SystemExit(f"no audit confirmed the labels of {len(without)} requests, the first {without[0]}")
    out.mkdir(parents=True, exist_ok=True)
    instruction = V.schema_instruction()
    asked = [(item, messages_for(item, instruction)) for item in items]
    caller = Caller(out / CALLS, cast(float, args.budget))

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


def read_jsonl(path: Path) -> list[JsonObject]:
    """The rows `write_jsonl` wrote. A row ends at a line feed only: an answer may hold other
    characters `str.splitlines` breaks a line at."""
    return [cast(JsonObject, json.loads(line)) for line in path.read_text(encoding="utf-8").split("\n") if line]


@dataclass(frozen=True, slots=True)
class Sampling:
    """A folder `sample` left, as `cases`, `apply` and training read it: its summary, the sampled
    requests by item ID, what a teacher call is keyed by besides its messages, and the replies of
    the call log by call key."""

    summary: JsonObject
    items: dict[str, M.SynthItem]
    effort: str
    max_tokens: int
    instruction: str
    replies: dict[str, Call]

    def reply(self, item: M.SynthItem, attempt: int) -> str | None:
        """The answer the call log holds for the request on that attempt, asked as `sample` asks it
        now: the request as the template renders it, its label note and the schema instruction, at
        the pass lines' reasoning effort and output budget."""
        call = self.replies.get(call_key(TEACHER, self.effort, self.max_tokens, attempt,
                                         messages_for(item, self.instruction)))
        return call.answer() if call is not None else None


def sampling_of(requests: Path, out: Path) -> Sampling:
    """The folder `sample` left in `out` for `requests`. SystemExit when `requests` is not the file
    `sample` read, or two of its requests share an item ID."""
    summary = cast(JsonObject, json.loads((out / "summary.json").read_text(encoding="utf-8")))
    if summary["requests_sha256"] != D.file_sha256(requests):
        raise SystemExit(f"{out} was sampled from other requests than {requests}")
    request = cast(JsonObject, V.load_pass_lines()["request"])
    calls = (call_from_row(row) for row in read_jsonl(out / CALLS))
    return Sampling(summary, by_item(V.synth_items(requests)), cast(str, request["reasoning_effort"]),
                    cast(int, request["max_tokens"]), V.schema_instruction(),
                    {call.key: call for call in calls if call is not None and call.replied()})


def records(sampled: Sampling, out: Path) -> tuple[list[JsonObject], list[JsonObject]]:
    """The records of kept.jsonl and of pending.jsonl. SystemExit when a record names no sampled
    request, two records name one, or a file holds another number of records than the summary
    counts for it: `sample` writes at most one record for a request, and the summary with them."""
    kept, pending = read_jsonl(out / KEPT), read_jsonl(out / PENDING)
    named = Counter(cast(str, record["item"]) for record in (*kept, *pending))
    odd = sorted(item for item, n in named.items() if n > 1 or item not in sampled.items)
    if odd:
        raise SystemExit(f"{len(odd)} items of {KEPT} and {PENDING} have two records or no sampled request, "
                         f"the first {odd[0]}")
    counted = (sampled.summary["kept"], sampled.summary["pending"])
    if (len(kept), len(pending)) != counted:
        raise SystemExit(f"{KEPT} and {PENDING} hold {len(kept)} and {len(pending)} records where summary.json "
                         f"counts {counted[0]} and {counted[1]}; run `sample` again with the same --out")
    return kept, pending


def target_answer(sampled: Sampling, record: JsonObject, waits: bool) -> AV.AdmissionAnswer:
    """The answer of a record of kept.jsonl (`waits` false) or pending.jsonl, as MASC's checks read
    it. SystemExit unless the answer is the reply the call log holds for the record's request and
    attempt (`Sampling.reply`), and `screened` still makes it the target that file holds."""
    item = sampled.items[cast(str, record["item"])]
    file = PENDING if waits else KEPT
    reply = sampled.reply(item, cast(int, record["attempt"]))
    if reply is None or reply != record["answer"]:
        raise SystemExit(f"{item.item_id}: the answer in {file} is not the teacher's logged reply to the "
                         "request as it is asked now")
    check = V.check(item.prompt, reply)
    got = screened(item, check, record)
    if check.answer is None or not isinstance(got, Target) or got.waits != waits:
        raise SystemExit(f"{item.item_id}: the answer in {file} is not a training target of that file any more")
    return check.answer


def waiting(sampled: Sampling, pending: list[JsonObject]) -> dict[tuple[str, str], AV.AdmissionAnswer]:
    """Each waiting answer by (TARGET, item), as MASC's checks read it. SystemExit as `target_answer` says."""
    return {(TARGET, cast(str, record["item"])): target_answer(sampled, record, True) for record in pending}


def pending_files(out: Path) -> dict[str, str | None]:
    return {PENDING: D.file_sha256(out / PENDING)}


def cases(args: argparse.Namespace) -> int:
    out = Path(cast(str, args.out))
    sampled = sampling_of(Path(cast(str, args.requests)), out)
    _, pending = records(sampled, out)
    slots = MC.guidance(synth_render.TEMPLATE.read_text(encoding="utf-8"))
    collected = MC.collect(sampled.items, waiting(sampled, pending), slots)
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


@dataclass(frozen=True, slots=True)
class Accepted:
    """The training targets of a sampled folder: the answers kept at once (`kept`) and, of the
    waiting answers (`pending`), those whose every absorb the merge judge classed mergeable (`merged`)."""

    kept: tuple[JsonObject, ...]
    pending: tuple[JsonObject, ...]
    merged: tuple[JsonObject, ...]
    merges: MD.MergeAdjudication

    def records(self) -> list[JsonObject]:
        return [*self.kept, *self.merged]


def accepted(sampled: Sampling, out: Path) -> Accepted:
    """The training targets in `out`, read from kept.jsonl, pending.jsonl and the judge's decisions.
    SystemExit as `records`, `target_answer` and `judged_merges` say."""
    kept, pending = records(sampled, out)
    for record in kept:
        target_answer(sampled, record, False)
    answers = waiting(sampled, pending)
    absorbs = frozenset((item, TARGET, mid) for (_, item), answer in answers.items() for mid, _ in answer.absorbed)
    merges = judged_merges(out, absorbs)
    merged = [r for r in pending
              if all(merges.judged.get((cast(str, r["item"]), TARGET, mid)) == "mergeable"
                     for mid, _ in answers[(TARGET, cast(str, r["item"]))].absorbed)]
    return Accepted(tuple(kept), tuple(pending), tuple(merged), merges)


def apply(args: argparse.Namespace) -> int:
    out = Path(cast(str, args.out))
    got = accepted(sampling_of(Path(cast(str, args.requests)), out), out)
    write_jsonl(out / ACCEPTED, got.records())
    summary = {"kept": len(got.kept), "pending": len(got.pending), "merged": len(got.merged),
               "accepted": len(got.records()), "absorbs": dict(Counter(got.merges.judged.values())),
               "judge_files": dict(got.merges.judge_files)}
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
