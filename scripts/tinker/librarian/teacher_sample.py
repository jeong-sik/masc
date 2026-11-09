# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Sample teacher answers for synthetic training requests and keep those that leave the memory their labels ask for.

    uv run scripts/tinker/librarian/teacher_sample.py sample \
        --requests artifacts/tinker/librarian/synth-train/requests.jsonl \
        --out artifacts/tinker/librarian/teacher --budget 30
    uv run scripts/tinker/librarian/teacher_sample.py cases \
        --requests artifacts/tinker/librarian/synth-train/requests.jsonl --out artifacts/tinker/librarian/teacher
    # the judge gets only <out>/merges/judge/: it reads judge.md and cases.jsonl there and writes decisions.jsonl
    uv run scripts/tinker/librarian/teacher_sample.py apply \
        --requests artifacts/tinker/librarian/synth-train/requests.jsonl --out artifacts/tinker/librarian/teacher

The teacher is the base model on the 256K training ID at reasoning_effort
"high", asked exactly as MASC's exact lane asks. Each request gets up to
ATTEMPTS answers, and sampling stops at the first answer that passes MASC's
checks and leaves the memory its label asks for (`memory_scores.score_synth`):
every candidate has the label's outcome and claim and leaves the memory its
kind needs, every planted stale fact is dropped, not absorbed, every planted
duplicate pair ends as one fact, and nothing else is dropped. Answers from
other providers are never used for training. An HTTP error or a missing
response is not an attempt: it stops that request, and a rerun with the same
--out sends it again. `sample` starts only while the files pass_lines.json pins
are unchanged (`eval_admission.load_pass_lines`), so the answers it keeps are
scored by the code the verdict runs.

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
<out>/pending.jsonl (item, attempt, answer, reasoning), <out>/summary.json,
<out>/merges/ (the judge's folder and the key), and from `apply`
<out>/accepted.jsonl, the training targets, with <out>/accepted-summary.json.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import cast

import admission_validator as AV
import audit_decisions as D
import e_synth_audit as A
import eval_admission as V
import memory_scores as M
import merge_cases as MC
import merge_decisions as MD
import synth_render
from tinker_oai import Caller

TEACHER = "thinkingmachines/Inkling-2-Small:peft:262144"
EFFORT = "high"
MAX_TOKENS = 32768
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


def sample(args: argparse.Namespace) -> int:
    V.load_pass_lines()
    out, requests = Path(cast(str, args.out)), Path(cast(str, args.requests))
    out.mkdir(parents=True, exist_ok=True)
    instruction = V.schema_instruction()
    items = V.synth_items(requests)
    caller = Caller(out / "calls.jsonl", cast(float, args.budget))

    # Each worker returns what it saw; the counts are summed here, outside the worker threads.
    def one(item: M.SynthItem) -> Sampled:
        rejected: list[str] = []
        for attempt in range(ATTEMPTS):
            call = caller.ask(model=TEACHER, label=f"teacher:{item.item_id}", messages=[item.text, instruction],
                              effort=EFFORT, max_tokens=MAX_TOKENS, attempt=attempt)
            if call is None:
                return Sampled(None, tuple(rejected), None)
            if not call.replied():
                return Sampled(None, tuple(rejected), call.status)
            record: JsonObject = {"item": item.item_id, "attempt": attempt, "answer": call.answer(),
                                  "reasoning": call.reasoning}
            got = screened(item, V.check(item.prompt, call.answer()), record)
            if isinstance(got, Target):
                return Sampled(got, tuple(rejected), None)
            rejected.append(got)
        return Sampled(None, tuple(rejected), None)

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        sampled = list(pool.map(one, items))
    targets = [s.target for s in sampled if s.target is not None]
    write_jsonl(out / KEPT, [t.record for t in targets if not t.waits])
    write_jsonl(out / PENDING, [t.record for t in targets if t.waits])
    summary = {"teacher": TEACHER, "effort": EFFORT, "requests": len(items),
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
