# pyright: strict
"""Folders `teacher_sample.py sample` leaves, for the tests of `cases` and `apply` and of the
training examples and the training run read from them.

A folder is made the way a run makes it: the teacher's replies are written into the call log, and
`sample` runs over them on a budget of 0, so a call the log does not hold stops the run and nothing
is sent. `teacher_sample` imports the Tinker caller, which imports openai, so a test that uses
this file runs with `uv run`.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import io
import json
import os
import sys
from pathlib import Path
from typing import cast
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import audit_decisions as D
import eval_admission as V
import synth_rows as RW
import synth_spec as S
import teacher_sample as T
import tinker_oai as O
from tinker_librarian_synth_fixtures import (
    PLANTED,
    answer_text,
    candidates_of,
    claim_json,
    fact,
    label_answer,
    merged,
    request,
)

# The messages of a call, its attempt, and the teacher's reply.
type Reply = tuple[list[str], int, str]

# A Keeper of the train split, and one whose memories belong to E-synth.
TRAIN_KEEPER, EVAL_KEEPER = "release-steward", "docs-gardener"
# A memory with nothing planted, and candidates whose label absorbs no memory there: the answer
# such a label asks for is kept at once.
BARE = (fact(1), fact(2), fact(3))
# A memory whose one plant is the stale m4: the answer drops it and absorbs nothing, so it is kept
# at once whatever the candidates (RFC-0517 §7.1).
STALE_ONLY = (*BARE, fact(4, stale=True))
KEPT_AT_ONCE =((S.CandidateKind.NEW_DURABLE,), (S.CandidateKind.CORRECTION,), (S.CandidateKind.PARAPHRASE,),
                (S.CandidateKind.NEW_DURABLE, S.CandidateKind.TRANSIENT))


def write_requests(path: Path, *reqs: S.SynthRequest) -> Path:
    path.write_text("".join(json.dumps({"request": RW.row_of(r)}, ensure_ascii=False) + "\n" for r in reqs),
                    encoding="utf-8")
    return path


def write_audit(folder: Path, judged: list[str], items: tuple[str, ...] = (), memories: tuple[str, ...] = ()) -> Path:
    """An audit folder with what `sample` reads of the audit.json `e_synth_audit.py apply` writes:
    a case per judged item, and the items and memories the audit took out."""
    folder.mkdir(exist_ok=True)
    (folder / "audit.json").write_text(json.dumps({
        "removed_items": list(items), "removed_memories": list(memories),
        "per_case": [{"case": f"c{n:03d}", "item": item} for n, item in enumerate(judged, start=1)]}),
        encoding="utf-8")
    return folder


def request_lines() -> tuple[str, int]:
    """The reasoning effort and the output budget pass_lines.json sets for a request."""
    pinned = cast(dict[str, object], V.load_pass_lines()["request"])
    return cast(str, pinned["reasoning_effort"]), cast(int, pinned["max_tokens"])


def log_calls(out: Path, effort: str, max_tokens: int, *replies: Reply) -> None:
    """Write the call log of `out`: `content` as the teacher's reply to `messages` on that attempt,
    asked at that effort and output budget."""
    calls = [O.Call(O.call_key(T.TEACHER, effort, max_tokens, attempt, messages), "teacher", O.HTTP_OK, "stop",
                    content, None, 10, 0, 1, 0.1, 1.0) for messages, attempt, content in replies]
    out.mkdir(exist_ok=True)
    (out / T.CALLS).write_text("".join(json.dumps(dataclasses.asdict(c), ensure_ascii=False) + "\n" for c in calls),
                               encoding="utf-8")


def run_sample(requests: Path, audits: list[Path], out: Path) -> tuple[int, dict[str, object]]:
    """`sample` on a budget of 0, and the summary it wrote. The caller builds its client from
    TINKER_API_KEY; a logged reply is returned before the client is used."""
    with mock.patch.dict(os.environ, {"TINKER_API_KEY": "not-a-key"}), contextlib.redirect_stdout(io.StringIO()):
        code = T.sample(argparse.Namespace(requests=str(requests), audit=[str(a) for a in audits], out=str(out),
                                           budget=0.0))
    return code, cast(dict[str, object], json.loads((out / "summary.json").read_text(encoding="utf-8")))


def sampled_folder(folder: Path, answered: list[tuple[S.SynthRequest, tuple[str, ...]]]) -> tuple[Path, Path]:
    """<folder>/requests.jsonl with the requests, an audit that judged them all, and
    <folder>/teacher as `sample` leaves it when the teacher's replies to each request are the given
    ones, in attempt order. Returns the requests file and the teacher folder. The requests differ
    in what they hold: a call is keyed by its messages, so two requests with the same text would
    get one reply."""
    requests = write_requests(folder / "requests.jsonl", *(req for req, _ in answered))
    audit = write_audit(folder / "audit", [req.item_id for req, _ in answered])
    instruction = V.schema_instruction()
    out = folder / "teacher"
    log_calls(out, *request_lines(), *((T.messages_for(item, instruction), attempt, reply)
                                       for item, (_, replies) in zip(V.synth_items(requests), answered, strict=True)
                                       for attempt, reply in enumerate(replies)))
    run_sample(requests, [audit], out)
    return requests, out


def record(req: S.SynthRequest, answer: str, attempt: int = 0) -> dict[str, object]:
    return {"item": req.item_id, "attempt": attempt, "answer": answer}


def run_cases(requests: Path, teacher: Path) -> int:
    with contextlib.redirect_stdout(io.StringIO()):
        return T.cases(argparse.Namespace(requests=str(requests), out=str(teacher)))


def run_apply(requests: Path, teacher: Path) -> int:
    with contextlib.redirect_stdout(io.StringIO()):
        return T.apply(argparse.Namespace(requests=str(requests), out=str(teacher)))


def write_decisions(teacher: Path, off: tuple[str, str], verdict: str) -> None:
    """The merge judge's decisions for the cases in `teacher`: `verdict` for the case of the absorb
    `off` (an item and the memory its answer absorbs), mergeable for every other case."""
    folder = teacher / T.MERGES
    item, memory = off
    decisions = [json.dumps({"case": key["case"], "reason": "r", "decision":
                             verdict if [item, T.TARGET, memory] in cast(list[list[str]], key["absorbs"])
                             else "mergeable"})
                 for key in D.read_jsonl(folder / "key.jsonl")]
    (folder / D.JUDGE_DIR / D.DECISIONS).write_text("\n".join(decisions) + "\n", encoding="utf-8")


def train_request(req: S.SynthRequest, index: int, keeper: str = TRAIN_KEEPER) -> S.SynthRequest:
    return dataclasses.replace(req, item_id=f"train-{keeper}-00-{index:03d}",
                               keeper=dataclasses.replace(req.keeper, key=keeper))


# The candidates of the request `absorbing_m2` answers.
OFF_KINDS = (S.CandidateKind.COMPLEMENT, S.CandidateKind.NEW_DURABLE, S.CandidateKind.TRANSIENT)


def absorbing_m2(req: S.SynthRequest) -> str:
    """The label's answer for OFF_KINDS on PLANTED (a complement of m1, a new fact and a passing
    state), with m2 absorbed into the complement's claim as well: a merge the label does not ask for."""
    k1, k2, k3 = req.candidates
    by_id = {f.memory_id: f for f in req.facts}
    first = merged(by_id["m1"], k1)
    return answer_text(((k1.request_id, "incorporated", first), (k2.request_id, "incorporated", k2.claim),
                        (k3.request_id, "not_durable", None)),
                       claims=(claim_json(first, absorbs=("m1", "m2")), claim_json(k2.claim),
                               claim_json(by_id["m5"].claim, absorbs=("m5", "m6"))),
                       dropped=("m4",))


@dataclasses.dataclass(frozen=True, slots=True)
class TrainFolder:
    """A sampled folder of train-split requests whose merge cases are made and judged. `labeled`
    waits with the absorbs its label asks for, `off` waits and absorbs m2 as well, and the answers
    to `kept` absorb nothing. The judge finds every absorb mergeable but m2's, which loses knowledge."""

    requests: Path
    teacher: Path
    labeled: S.SynthRequest
    off: S.SynthRequest
    kept: tuple[S.SynthRequest, ...]


def train_folder(folder: Path, last_keeper: str = TRAIN_KEEPER) -> TrainFolder:
    """The folder `TrainFolder` describes, under `folder`. `last_keeper` is the Keeper of the last
    kept request."""
    labeled = train_request(
        request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT, S.CandidateKind.NEW_DURABLE))), 1)
    off = train_request(request(PLANTED, candidates_of(OFF_KINDS)), 2)
    plain = train_request(request(STALE_ONLY, candidates_of((S.CandidateKind.TRANSIENT, S.CandidateKind.TRANSIENT))),
                          3)
    more = [train_request(request(BARE, candidates_of(kinds)), index, last_keeper if index == 7 else TRAIN_KEEPER)
            for index, kinds in enumerate(KEPT_AT_ONCE, start=4)]
    kept = (plain, *more)
    requests, teacher = sampled_folder(folder, [(labeled, (label_answer(labeled),)), (off, (absorbing_m2(off),)),
                                                *((req, (label_answer(req),)) for req in kept)])
    run_cases(requests, teacher)
    write_decisions(teacher, (off.item_id, "m2"), "loses_knowledge")
    return TrainFolder(requests, teacher, labeled, off, kept)
