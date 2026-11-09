# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the labels of synthetic requests (scripts/tinker/librarian/synth_spec.py) and for
scoring answers by the memory they leave (memory_scores.py).

A label is a Memory decision MASC accepts: the answer it asks for passes
`admission_validator` for the prompt `synth_render` makes from the request, and
scores right on every count.
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
import memory_scores as M
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


type Judged = tuple[str, S.Outcome, str | None]


def answer_text(judgments: tuple[Judged, ...], *, claims: tuple[dict[str, object], ...] = (),
                dropped: tuple[str, ...] = ()) -> str:
    """An admission answer whose support is every candidate that can give it."""
    return json.dumps({"memory": {"new_claims": list(claims), "dropped": [drop_json(m, "근거") for m in dropped],
                                  "working_state": None, "working_contexts": []},
                       "candidates": [{"request_id": rid, "outcome": outcome, "memory_claim": claim, "reason": "근거"}
                                      for rid, outcome, claim in judgments],
                       "change_support": [rid for rid, outcome, _ in judgments if S.can_support(outcome)]},
                      ensure_ascii=False)


def label_answer(req: S.SynthRequest) -> str:
    """The answer the label asks for. A complement's claim joins its target and the candidate;
    a duplicate pair keeps its first fact, restated byte for byte with both IDs in `absorbs`."""
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
    claims += [claim_json(by_id[kept].claim, absorbs=(kept, gone)) for kept, gone in label.duplicates]
    corrected = tuple(cl.supersedes for cl in label.candidates if cl.supersedes is not None)
    return answer_text(tuple(judgments), claims=tuple(claims), dropped=corrected + tuple(sorted(label.planted_stale)))


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


def scored(req: S.SynthRequest, answer: str) -> M.JsonObject:
    return M.score_synth(M.SynthItem(req.item_id, prompt_of(req), "", S.label_of(req)), accepted(req, answer))


def one(kind: S.CandidateKind) -> tuple[S.SynthRequest, S.Candidate]:
    req = request(PLANTED, candidates_of((kind,)))
    return req, req.candidates[0]


class MemoryStateTest(unittest.TestCase):
    def test_the_answer_a_label_asks_for_is_right_on_every_count(self) -> None:
        for n in (1, 2, 3):
            for kinds in itertools.product(KINDS, repeat=n):
                with self.subTest(kinds=[k.value for k in kinds]):
                    req = request(PLANTED, candidates_of(kinds))
                    s = scored(req, label_answer(req))
                    self.assertEqual((s["correct"], s["state_correct"]), (s["candidates"], s["candidates"]))
                    self.assertEqual((s["planted_dropped"], s["pairs_merged"], s["merges_done"]),
                                     (s["planted"], s["pairs"], s["merges"]))
                    self.assertEqual((s["dropped_expected"], s["dropped_unmerged"], s["dropped_off_label"],
                                      s["planted_absorbed"]), (s["dropped"], [], [], 0))
                    self.assertEqual((s["added"], s["removed"]), (s["expected_added"], s["expected_removed"]))

    def test_a_complement_kept_beside_its_target_is_not_merged(self) -> None:
        req, c = one(S.CandidateKind.COMPLEMENT)
        s = scored(req, answer_text(((c.request_id, "incorporated", c.claim),), claims=(claim_json(c.claim),)))
        self.assertEqual((s["correct"], s["state_correct"], s["merges_done"]), (1, 0, 0))

    def test_a_duplicate_kept_or_dropped_is_not_merged_and_its_drop_is_not_asked_for(self) -> None:
        req, c = one(S.CandidateKind.PARAPHRASE)
        judged: tuple[Judged, ...] = ((c.request_id, "already_represented", PLANTED[0].claim),)
        kept, dropped = scored(req, answer_text(judged)), scored(req, answer_text(judged, dropped=("m6",)))
        self.assertEqual((kept["pairs"], kept["pairs_merged"], dropped["pairs_merged"]), (1, 0, 0))
        self.assertEqual((dropped["dropped"], dropped["dropped_expected"], dropped["dropped_unmerged"],
                          dropped["dropped_off_label"]), (1, 0, ["m6"], []))

    def test_both_duplicates_in_one_claim_leave_one_fact_and_one_beside_a_kept_twin_does_not(self) -> None:
        req, c = one(S.CandidateKind.NEW_DURABLE)
        both = PLANTED[4].claim + " " + c.claim
        s = scored(req, answer_text(((c.request_id, "incorporated", both),), claims=(claim_json(both, absorbs=("m5", "m6")),)))
        self.assertEqual((s["pairs_merged"], s["absorbs"]), (1, {"m5": "duplicate", "m6": "duplicate"}))
        apart = scored(req, answer_text(((c.request_id, "incorporated", c.claim),),
                                        claims=(claim_json(c.claim, absorbs=("m6",)),)))
        self.assertEqual(apart["pairs_merged"], 0)

    def test_a_restatement_rewritten_into_a_claim_that_absorbs_its_target_leaves_one_fact(self) -> None:
        req, c = one(S.CandidateKind.PARAPHRASE)
        judged: tuple[Judged, ...] = ((c.request_id, "incorporated", c.claim),)
        s = scored(req, answer_text(judged, claims=(claim_json(c.claim, absorbs=("m1",)),)))
        self.assertEqual((s["correct"], s["state_correct"], s["absorbs"]), (0, 1, {"m1": "paraphrase"}))
        elsewhere = scored(req, answer_text(judged, claims=(claim_json(c.claim, absorbs=("m2",)),)))
        self.assertEqual(elsewhere["state_correct"], 0)

    def test_a_stale_fact_absorbed_instead_of_dropped_is_counted_apart(self) -> None:
        req, c = one(S.CandidateKind.NEW_DURABLE)
        s = scored(req, answer_text(((c.request_id, "incorporated", c.claim),),
                                    claims=(claim_json(c.claim, absorbs=("m4",)),)))
        self.assertEqual((s["planted"], s["planted_dropped"], s["planted_absorbed"], s["absorbs"]),
                         (1, 0, 1, {"m4": "stale"}))

    def test_a_corrected_target_absorbed_into_the_new_claim_leaves_memory(self) -> None:
        req, c = one(S.CandidateKind.CORRECTION)
        s = scored(req, answer_text(((c.request_id, "incorporated", c.claim),),
                                    claims=(claim_json(c.claim, absorbs=("m1",)),)))
        self.assertEqual((s["correct"], s["state_correct"]), (0, 1))

    def test_a_transient_candidate_judged_already_represented_adds_nothing(self) -> None:
        req, c = one(S.CandidateKind.TRANSIENT)
        s = scored(req, answer_text(((c.request_id, "already_represented", PLANTED[1].claim),)))
        self.assertEqual((s["correct"], s["state_correct"], s["added"], s["removed"]), (0, 1, 0, 0))


class ReadBackTest(unittest.TestCase):
    def test_a_written_label_reads_back_and_others_do_not(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT, S.CandidateKind.PARAPHRASE)))
        self.assertEqual(S.label_from_json(json.loads(G.request_json(req))["label"]), S.label_of(req))
        earlier = {"candidates": [{"request_id": "r", "outcome": "not_durable", "supersedes": None,
                                   "already_claim": None}], "planted_stale": []}
        mismatched = {"candidates": [{"request_id": "r", "outcome": "not_durable", "supersedes": "m1",
                                      "absorbs": None, "already_claim": None}], "planted_stale": [], "duplicates": []}
        self.assertIsNone(S.label_from_json(earlier))
        self.assertIsNone(S.label_from_json(mismatched))


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


if __name__ == "__main__":
    unittest.main()
