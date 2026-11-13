# pyright: strict
"""Invented synthetic requests and the admission answers MASC accepts on them, for the tests of
synthetic labels, request rows, memory scoring and the teacher filter.
"""

from __future__ import annotations

import datetime as dt
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import admission_request as R
import admission_result as AR
import admission_validator as AV
import synth_render as SR
import synth_rows as RW
import synth_spec as S

KEEPER = S.KeeperProfile("docs-gardener", "synth-docs-gardener", "문서 사이트를 돌보는 Keeper.", "가상의 문서 저장소.",
                         ("doc_links", "style_rules"), S.GoalDraft("깨진 링크 줄이기", "깨진 링크 수", "0"))
NO_EVIDENCE: dict[str, object] = {"conversation": [], "tools": [], "counterpart": False, "task_contexts": False}
KINDS = tuple(S.CandidateKind)
CANDIDATE_SEEN = dt.datetime(2026, 11, 7, 9, 0, tzinfo=dt.UTC).timestamp()


def fact(index: int, *, stale: bool = False, duplicate_of: str | None = None, use_at: str | None = None) -> S.MemoryFact:
    seen = dt.datetime(2026, 10, 1, tzinfo=dt.UTC) + dt.timedelta(hours=index)
    return S.MemoryFact(f"m{index}", f"기억 {index}: 문서 링크를 고칠 때 지키는 규칙 {index}번.", "doc_links", None,
                        seen.strftime("%Y-%m-%dT%H:%M:%SZ"), stale, duplicate_of, use_at)


def candidate(index: int, kind: S.CandidateKind, target: str | None) -> S.Candidate:
    return S.Candidate(f"memory-admission-{index:032x}", index, f"후보 {index}: 이번 턴의 관측 {index}번.", "doc_links",
                       CANDIDATE_SEEN + index, None, f"trace-{index:013d}-00000", kind, target)


def request(facts: tuple[S.MemoryFact, ...], candidates: tuple[S.Candidate, ...]) -> S.SynthRequest:
    return S.SynthRequest("eval-docs-gardener-00-000", KEEPER, facts, S.NoTask(), candidates)


# A memory with every plant: m4 is stale, m6 restates m5. Targets come from m1, m2 and m3.
PLANTED = (fact(1), fact(2), fact(3), fact(4, stale=True), fact(5), fact(6, duplicate_of="m5"))
TARGETS = ("m1", "m2", "m3")
# The same memory with two records: m7 is used on a day after the candidates' (11-07), and m8
# was used the day after it was written, before them.
RECORD_AHEAD, RECORD_PAST = "2026-11-09T09:00:00Z", "2026-10-02T09:00:00Z"
SCHEDULED = PLANTED + (fact(7, use_at=RECORD_AHEAD), fact(8, stale=True, use_at=RECORD_PAST))


def candidates_of(kinds: tuple[S.CandidateKind, ...]) -> tuple[S.Candidate, ...]:
    """Candidates of these kinds; each one that needs a target gets its own."""
    free = iter(TARGETS)
    out: list[S.Candidate] = []
    for index, kind in enumerate(kinds, start=1):
        match kind:
            case S.CandidateKind.CORRECTION | S.CandidateKind.COMPLEMENT | S.CandidateKind.PARAPHRASE:
                out.append(candidate(index, kind, next(free)))
            case S.CandidateKind.NEW_DURABLE | S.CandidateKind.TRANSIENT:
                out.append(candidate(index, kind, None))
    return tuple(out)


def claim_json(claim: str, *, supersedes: str | None = None, absorbs: tuple[str, ...] = ()) -> dict[str, object]:
    return {"claim": claim, "category": "doc_links", "board_post_id": None, "board_comment_id": None,
            "supersedes": supersedes, "absorbs": list(absorbs), "evidence": NO_EVIDENCE}


def drop_json(memory_id: str, reason: str) -> dict[str, object]:
    return {"memory_id": memory_id, "reason": reason}


def merged(target: S.MemoryFact, c: S.Candidate) -> str:
    return target.claim + " " + c.claim


type Judged = tuple[str, S.Outcome, str | None]


def answer_text(judgments: tuple[Judged, ...], *, claims: tuple[dict[str, object], ...] = (),
                dropped: tuple[str, ...] = ()) -> str:
    """An admission answer whose support is every candidate that can give it: `verify_support` takes
    incorporated and already_represented candidates."""
    return json.dumps({"memory": {"new_claims": list(claims), "dropped": [drop_json(m, "근거") for m in dropped],
                                  "working_state": None, "working_contexts": []},
                       "candidates": [{"request_id": rid, "outcome": outcome, "memory_claim": claim, "reason": "근거"}
                                      for rid, outcome, claim in judgments],
                       "change_support": [rid for rid, outcome, _ in judgments
                                          if outcome in ("incorporated", "already_represented")]},
                      ensure_ascii=False)


def label_answer(req: S.SynthRequest) -> str:
    """The answer the label asks for. A complement's claim joins its target and the candidate;
    a duplicate pair keeps its first fact, restated byte for byte with both IDs in `absorbs`.
    It drops the stale facts and merges the pairs whatever the candidates (RFC-0517 §7.1)."""
    label = S.label_of(req)
    by_id = {f.memory_id: f for f in req.facts}
    by_request = {c.request_id: c for c in req.candidates}
    judgments: list[Judged] = []
    claims: list[dict[str, object]] = []
    for cl in label.candidates:
        c = by_request[cl.request_id]
        match cl.outcome:
            case "incorporated":
                claim = merged(by_id[cl.absorbs], c) if cl.absorbs is not None else c.claim
                claims.append(claim_json(claim, supersedes=cl.supersedes,
                                         absorbs=(cl.absorbs,) if cl.absorbs is not None else ()))
                judgments.append((cl.request_id, cl.outcome, claim))
            case "already_represented":
                judgments.append((cl.request_id, cl.outcome, cl.already_claim))
            case "not_durable":
                judgments.append((cl.request_id, cl.outcome, None))
    pairs, stale = label.duplicates, tuple(sorted(label.planted_stale))
    claims += [claim_json(by_id[kept].claim, absorbs=(kept, gone)) for kept, gone in pairs]
    corrected = tuple(cl.supersedes for cl in label.candidates if cl.supersedes is not None)
    return answer_text(tuple(judgments), claims=tuple(claims), dropped=corrected + stale)


def prompt_of(req: S.SynthRequest) -> R.AdmissionPrompt:
    """The prompt MASC would send for the request, read back from its row as stored."""
    return SR.prompt_of(json.loads(json.dumps(RW.row_of(req), ensure_ascii=False)))


def accepted(req: S.SynthRequest, answer: str) -> AR.AdmissionAnswer:
    result = AV.validate(prompt_of(req), answer)
    if isinstance(result, AV.Invalid):
        raise AssertionError(f"refused: {result.violations}")
    return result.answer
