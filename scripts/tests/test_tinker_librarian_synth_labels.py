# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the labels of synthetic requests (scripts/tinker/librarian/synth_spec.py).

A label is a Memory decision MASC accepts: the answer it asks for passes
`admission_validator` for the prompt `synth_render` makes from the request.
`synth_generate` imports the Tinker caller, which imports openai, so this file
runs with `uv run`.
"""

from __future__ import annotations

import datetime as dt
import itertools
import json
import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import admission_request as R
import admission_result as AR
import admission_validator as AV
import synth_generate as G
import synth_render as SR
import synth_spec as S

KEEPER = S.KeeperProfile("docs-gardener", "synth-docs-gardener", "문서 사이트를 돌보는 Keeper.", "가상의 문서 저장소.",
                         ("doc_links", "style_rules"), S.GoalDraft("깨진 링크 줄이기", "깨진 링크 수", "0"))
NO_EVIDENCE: dict[str, object] = {"conversation": [], "tools": [], "counterpart": False, "task_contexts": False}
KINDS = tuple(S.CandidateKind)
CANDIDATE_SEEN = dt.datetime(2026, 11, 7, 9, 0, tzinfo=dt.UTC).timestamp()


def fact(index: int, *, stale: bool = False, duplicate_of: str | None = None) -> S.MemoryFact:
    seen = dt.datetime(2026, 10, 1, tzinfo=dt.UTC) + dt.timedelta(hours=index)
    return S.MemoryFact(f"m{index}", f"기억 {index}: 문서 링크를 고칠 때 지키는 규칙 {index}번.", "doc_links", None,
                        seen.strftime("%Y-%m-%dT%H:%M:%SZ"), stale, duplicate_of)


def candidate(index: int, kind: S.CandidateKind, target: str | None) -> S.Candidate:
    return S.Candidate(f"memory-admission-{index:032x}", index, f"후보 {index}: 이번 턴의 관측 {index}번.", "doc_links",
                       CANDIDATE_SEEN + index, None, f"trace-{index:013d}-00000", kind, target)


def request(facts: tuple[S.MemoryFact, ...], candidates: tuple[S.Candidate, ...]) -> S.SynthRequest:
    return S.SynthRequest("eval-docs-gardener-00-000", KEEPER, facts, S.NoTask(), candidates)


# A memory with every plant: m4 is stale, m6 restates m5. Targets come from m1, m2 and m3.
PLANTED = (fact(1), fact(2), fact(3), fact(4, stale=True), fact(5), fact(6, duplicate_of="m5"))
TARGETS = ("m1", "m2", "m3")


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


def label_answer(req: S.SynthRequest) -> str:
    """The answer the label asks for. A complement's claim joins its target and the candidate;
    a duplicate pair keeps its first fact, restated byte for byte with both IDs in `absorbs`."""
    label = S.label_of(req)
    by_id = {f.memory_id: f for f in req.facts}
    by_request = {c.request_id: c for c in req.candidates}
    claims: list[dict[str, object]] = []
    dropped: list[dict[str, object]] = []
    judgments: list[dict[str, object]] = []
    support: list[str] = []
    for cl in label.candidates:
        c = by_request[cl.request_id]
        memory_claim: str | None = None
        match cl.outcome:
            case "incorporated":
                memory_claim = merged(by_id[cl.absorbs], c) if cl.absorbs is not None else c.claim
                claims.append(claim_json(memory_claim, supersedes=cl.supersedes,
                                         absorbs=(cl.absorbs,) if cl.absorbs is not None else ()))
                if cl.supersedes is not None:
                    dropped.append(drop_json(cl.supersedes, "교정됨"))
                support.append(cl.request_id)
            case "already_represented":
                memory_claim = cl.already_claim
                support.append(cl.request_id)
            case "not_durable":
                pass
        judgments.append({"request_id": cl.request_id, "outcome": cl.outcome, "memory_claim": memory_claim,
                          "reason": "라벨"})
    dropped += [drop_json(mid, "낡은 상태") for mid in sorted(label.planted_stale)]
    claims += [claim_json(by_id[kept].claim, absorbs=(kept, gone)) for kept, gone in label.duplicates]
    return json.dumps({"memory": {"new_claims": claims, "dropped": dropped, "working_state": None,
                                  "working_contexts": []},
                       "candidates": judgments, "change_support": support}, ensure_ascii=False)


def prompt_of(req: S.SynthRequest) -> R.AdmissionPrompt:
    return SR.prompt_of(json.loads(G.request_json(req))["request"])


def accepted(req: S.SynthRequest, answer: str) -> AR.AdmissionAnswer:
    result = AV.validate(prompt_of(req), answer)
    if isinstance(result, AV.Invalid):
        raise AssertionError(f"refused: {result.violations}")
    return result.answer


class LabelTest(unittest.TestCase):
    def test_transient_candidates_alone_leave_the_planted_facts(self) -> None:
        label = S.label_of(request(PLANTED, candidates_of((S.CandidateKind.TRANSIENT, S.CandidateKind.TRANSIENT))))
        self.assertEqual(label.planted_stale, frozenset())
        self.assertEqual(label.duplicates, ())

    def test_one_supporting_candidate_takes_out_the_planted_facts(self) -> None:
        label = S.label_of(request(PLANTED, candidates_of((S.CandidateKind.TRANSIENT, S.CandidateKind.PARAPHRASE))))
        self.assertEqual(label.planted_stale, frozenset({"m4"}))
        self.assertEqual(label.duplicates, (("m5", "m6"),))

    def test_a_complement_absorbs_its_target(self) -> None:
        [cl] = S.label_of(request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT,)))).candidates
        self.assertEqual((cl.outcome, cl.supersedes, cl.absorbs, cl.already_claim), ("incorporated", None, "m1", None))


class ContractTest(unittest.TestCase):
    def test_masc_accepts_the_answer_every_label_asks_for(self) -> None:
        by_id = {f.memory_id: f for f in PLANTED}
        for n in (1, 2, 3):
            for kinds in itertools.product(KINDS, repeat=n):
                with self.subTest(kinds=[k.value for k in kinds]):
                    req = request(PLANTED, candidates_of(kinds))
                    label = S.label_of(req)
                    got = accepted(req, label_answer(req))
                    by_request = {c.request_id: c for c in req.candidates}
                    corrected = {cl.supersedes for cl in label.candidates if cl.supersedes is not None}
                    complemented = {cl.absorbs: merged(by_id[cl.absorbs], by_request[cl.request_id])
                                    for cl in label.candidates if cl.absorbs is not None}
                    self.assertEqual(set(got.dropped), label.planted_stale | corrected)
                    self.assertEqual(dict(got.absorbed),
                                     complemented | {gone: by_id[kept].claim for kept, gone in label.duplicates})
                    gone = set(got.dropped) | set(dict(got.absorbed))
                    self.assertEqual(set(got.memory_after) - set(got.added_claims),
                                     {f.claim for f in PLANTED if f.memory_id not in gone})

    def test_masc_refuses_planted_facts_taken_out_without_support(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.TRANSIENT,)))
        [c] = req.candidates
        answer = json.dumps({"memory": {"new_claims": [], "dropped": [{"memory_id": "m4", "reason": "낡은 상태"}],
                                        "working_state": None, "working_contexts": []},
                             "candidates": [{"request_id": c.request_id, "outcome": "not_durable",
                                             "memory_claim": None, "reason": "일시 상태"}],
                             "change_support": []}, ensure_ascii=False)
        result = AV.validate(prompt_of(req), answer)
        assert isinstance(result, AV.Invalid)
        self.assertEqual([v.kind for v in result.violations], [AR.Kind.CHANGES_WITHOUT_SUPPORT])


class GenerateTest(unittest.TestCase):
    def test_no_target_is_a_planted_fact(self) -> None:
        self.assertEqual([f.memory_id for f in G.target_choices(PLANTED)], list(TARGETS))

    def test_a_duplicate_names_the_id_its_fact_gets_once_sorted_by_time(self) -> None:
        late, early = dt.datetime(2026, 10, 9, tzinfo=dt.UTC), dt.datetime(2026, 10, 2, tzinfo=dt.UTC)
        written = [G.Written(late, "doc_links", False, "원래 기억", None),
                   G.Written(early, "doc_links", False, "같은 지식의 다른 문장", "원래 기억"),
                   G.Written(early + dt.timedelta(days=1), "doc_links", True, "낡은 상태", None)]
        facts = G.facts_of(random.Random(1), written)
        self.assertEqual([(f.memory_id, f.claim, f.planted_stale, f.duplicate_of) for f in facts],
                         [("m1", "같은 지식의 다른 문장", False, "m3"), ("m2", "낡은 상태", True, None),
                          ("m3", "원래 기억", False, None)])

    def test_a_planned_duplicate_lands_in_a_category_of_its_memory(self) -> None:
        keeper = S.KeeperProfile("docs-gardener", "synth-docs-gardener", "r", "w",
                                 tuple(f"topic_{i}" for i in range(12)), S.GoalDraft("t", "m", "v"))
        for seed in range(20):
            plan = G.plan_memory(random.Random(seed), keeper, 0, True)
            assert plan.duplicate is not None
            self.assertIn(plan.duplicate.category, {slot.category for slot in plan.slots})
            self.assertIsNone(G.plan_memory(random.Random(seed), keeper, 0, False).duplicate)


if __name__ == "__main__":
    unittest.main()
