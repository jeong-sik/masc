# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the labels of synthetic requests (scripts/tinker/librarian/synth_spec.py), for
scoring answers by the memory they leave (memory_scores.py), and for the teacher answers kept
as training targets (teacher_sample.py).

A label is a Memory decision MASC accepts: the answer it asks for passes
`admission_validator` for the prompt `synth_render` makes from the request, and
scores right on every count. Requests and answers come from
`tinker_librarian_synth_fixtures.py`. `teacher_sample` imports the Tinker caller,
which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import itertools
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import admission_result as AR
import admission_validator as AV
import eval_admission as V
import memory_scores as M
import synth_spec as S
import teacher_sample as T
from tinker_librarian_synth_fixtures import (
    KINDS,
    PLANTED,
    Judged,
    accepted,
    answer_text,
    candidates_of,
    claim_json,
    label_answer,
    merged,
    prompt_of,
    request,
)

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

    def test_a_restatement_deleted_while_naming_another_fact_does_not_survive(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.PARAPHRASE, S.CandidateKind.NEW_DURABLE)))
        restated, new = req.candidates
        judgments: tuple[Judged, ...] = ((restated.request_id, "already_represented", PLANTED[1].claim),
                                        (new.request_id, "incorporated", new.claim))
        s = scored(req, answer_text(judgments, claims=(claim_json(new.claim),), dropped=("m1",)))
        self.assertEqual(s["state_correct"], 1)
        self.assertEqual(s["state_by_kind"], {"new": [1, 1], "restates": [1, 0]})

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


def teacher_answer(req: S.SynthRequest, *, absorbs: tuple[str, ...], pair: bool, dropped: tuple[str, ...]) -> str:
    """An answer MASC accepts on PLANTED with a complement of m1 (k1) and a new fact (k2). The
    complement's claim joins m1 when `absorbs` holds m1; `pair` merges m6 into m5."""
    k1, k2 = req.candidates
    by_id = {f.memory_id: f for f in req.facts}
    first = merged(by_id["m1"], k1) if "m1" in absorbs else k1.claim
    claims = [claim_json(first, absorbs=absorbs), claim_json(k2.claim)]
    if pair:
        claims.append(claim_json(by_id["m5"].claim, absorbs=("m5", "m6")))
    return answer_text(((k1.request_id, "incorporated", first), (k2.request_id, "incorporated", k2.claim)),
                       claims=tuple(claims), dropped=dropped)


def teacher_rejection(req: S.SynthRequest, answer: str) -> str | None:
    accepted(req, answer)
    item = M.SynthItem(req.item_id, prompt_of(req), "", S.label_of(req))
    return T.rejection(item, V.check(item.prompt, answer))


class TeacherTest(unittest.TestCase):
    def test_the_answer_a_label_asks_for_is_kept_with_its_merges(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT, S.CandidateKind.NEW_DURABLE)))
        self.assertIsNone(teacher_rejection(req, label_answer(req)))
        self.assertIsNone(teacher_rejection(req, teacher_answer(req, absorbs=("m1",), pair=True, dropped=("m4",))))

    def test_an_answer_that_skips_a_merge_or_merges_outside_the_label_is_not_kept(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT, S.CandidateKind.NEW_DURABLE)))
        # (complement's absorbs, pair merged, dropped) -> why the answer is not kept
        cases: tuple[tuple[tuple[str, ...], bool, tuple[str, ...], str], ...] = (
            ((), True, ("m4",), "memory_state"),
            (("m1",), False, ("m4",), "duplicate_kept"),
            (("m1", "m4"), True, (), "stale_kept"),
            (("m1", "m2"), True, ("m4",), "absorbed_off_label"),
            (("m1",), True, ("m4", "m2"), "unexpected_drop"))
        for absorbs, pair, dropped, why in cases:
            answer = teacher_answer(req, absorbs=absorbs, pair=pair, dropped=dropped)
            self.assertEqual(teacher_rejection(req, answer), why, (absorbs, pair, dropped))


if __name__ == "__main__":
    unittest.main()
