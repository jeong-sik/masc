# pyright: strict
"""Tests for scoring an admission answer by the memory it leaves (scripts/tinker/librarian/memory_scores.py).

Every answer here passes `admission_validator` for the prompt `synth_render`
makes from its request, so each score is one a run can produce. Requests and
answers come from `tinker_librarian_synth_fixtures.py`: m4 is stale, m6
restates m5, and targets come from m1, m2 and m3.
"""

from __future__ import annotations

import itertools
import json
import sys
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import memory_scores as M
import synth_spec as S
from tinker_librarian_synth_fixtures import (
    KINDS,
    PLANTED,
    Judged,
    accepted,
    answer_text,
    candidates_of,
    claim_json,
    label_answer,
    prompt_of,
    request,
)

K = S.CandidateKind
M1, M2, M5, M6 = (PLANTED[i].claim for i in (0, 1, 4, 5))


def scored(req: S.SynthRequest, answer: str | None) -> M.JsonObject:
    """The score of an answer MASC accepts; None scores a refused answer."""
    item = M.SynthItem(req.item_id, prompt_of(req), "", S.label_of(req))
    return M.score_synth(item, accepted(req, answer) if answer is not None else None)


def one(kind: S.CandidateKind) -> tuple[S.SynthRequest, S.Candidate]:
    req = request(PLANTED, candidates_of((kind,)))
    return req, req.candidates[0]


def two(first: S.CandidateKind, second: S.CandidateKind) -> tuple[S.SynthRequest, S.Candidate, S.Candidate]:
    req = request(PLANTED, candidates_of((first, second)))
    return req, req.candidates[0], req.candidates[1]


def state(score: M.JsonObject, kind: M.Kind) -> list[int]:
    """The candidates of the kind and how many of them leave the memory the kind needs."""
    return cast(dict[str, list[int]], score["state_by_kind"])[kind]


def both_incorporated(c1: S.Candidate, c2: S.Candidate) -> tuple[Judged, ...]:
    return (c1.request_id, "incorporated", c1.claim), (c2.request_id, "incorporated", c2.claim)


class MemoryStateTest(unittest.TestCase):
    def test_a_restatement_deleted_while_naming_another_fact_does_not_survive(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.PARAPHRASE, S.CandidateKind.NEW_DURABLE)))
        restated, new = req.candidates
        judgments: tuple[Judged, ...] = ((restated.request_id, "already_represented", PLANTED[1].claim),
                                        (new.request_id, "incorporated", new.claim))
        s = scored(req, answer_text(judgments, claims=(claim_json(new.claim),), dropped=("m1",)))
        self.assertEqual(s["state_correct"], 1)
        self.assertEqual(s["state_by_kind"], {"new": [1, 1], "restates": [1, 0]})

    def test_the_answer_a_label_asks_for_is_right_on_every_count(self) -> None:
        for n in (1, 2, 3):
            for kinds in itertools.product(KINDS, repeat=n):
                with self.subTest(kinds=[k.value for k in kinds]):
                    req = request(PLANTED, candidates_of(kinds))
                    s = scored(req, label_answer(req))
                    self.assertEqual((s["correct"], s["state_correct"]), (s["candidates"], s["candidates"]))
                    self.assertEqual(set(cast(dict[str, list[int]], s["state_by_kind"])),
                                     {M.kind_of(cl) for cl in S.label_of(req).candidates})
                    self.assertEqual((s["planted_dropped"], s["pairs_merged"], s["merges_done"]),
                                     (s["planted"], s["pairs"], s["merges"]))
                    self.assertEqual((s["dropped_expected"], s["dropped_unmerged"], s["dropped_off_label"],
                                      s["planted_absorbed"]), (s["dropped"], [], [], 0))
                    self.assertEqual((s["added"], s["removed"]), (s["expected_added"], s["expected_removed"]))

    def test_a_complement_kept_beside_its_target_is_not_merged(self) -> None:
        req, c = one(K.COMPLEMENT)
        s = scored(req, answer_text(((c.request_id, "incorporated", c.claim),), claims=(claim_json(c.claim),)))
        self.assertEqual((s["correct"], s["state_correct"], s["merges_done"]), (1, 0, 0))

    def test_a_duplicate_kept_or_dropped_is_not_merged_and_its_drop_is_not_asked_for(self) -> None:
        req, c = one(K.PARAPHRASE)
        judged: tuple[Judged, ...] = ((c.request_id, "already_represented", M1),)
        kept, dropped = scored(req, answer_text(judged)), scored(req, answer_text(judged, dropped=("m6",)))
        self.assertEqual((kept["pairs"], kept["pairs_merged"], dropped["pairs_merged"]), (1, 0, 0))
        self.assertEqual((dropped["dropped"], dropped["dropped_expected"], dropped["dropped_unmerged"],
                          dropped["dropped_off_label"]), (1, 0, ["m6"], []))

    def test_a_dropped_complement_target_is_not_merged_and_its_drop_is_not_asked_for(self) -> None:
        req, c = one(K.COMPLEMENT)
        s = scored(req, answer_text(((c.request_id, "incorporated", c.claim),), claims=(claim_json(c.claim),),
                                    dropped=("m1",)))
        self.assertEqual((s["dropped_expected"], s["dropped_unmerged"], s["dropped_off_label"], s["merges_done"]),
                         (0, ["m1"], [], 0))

    def test_a_stale_fact_absorbed_instead_of_dropped_is_counted_apart(self) -> None:
        req, c = one(K.NEW_DURABLE)
        s = scored(req, answer_text(((c.request_id, "incorporated", c.claim),),
                                    claims=(claim_json(c.claim, absorbs=("m4",)),)))
        self.assertEqual((s["planted"], s["planted_dropped"], s["planted_absorbed"], s["absorbs"]),
                         (1, 0, 1, {"m4": "stale"}))


class KindTest(unittest.TestCase):
    def test_a_new_fact_or_a_complement_adds_its_claim(self) -> None:
        req, c = one(K.NEW_DURABLE)
        self.assertEqual(state(scored(req, answer_text(((c.request_id, "incorporated", M2),))), "new"), [1, 0])
        req, c = one(K.COMPLEMENT)
        into_kept = answer_text(((c.request_id, "incorporated", M2),), claims=(claim_json(M2, absorbs=("m1",)),))
        self.assertEqual(state(scored(req, into_kept), "complements"), [1, 0])

    def test_a_correction_takes_its_target_out(self) -> None:
        req, c = one(K.CORRECTION)
        judged: tuple[Judged, ...] = ((c.request_id, "incorporated", c.claim),)
        kept = scored(req, answer_text(judged, claims=(claim_json(c.claim),)))
        dropped = scored(req, answer_text(judged, claims=(claim_json(c.claim),), dropped=("m1",)))
        absorbed = scored(req, answer_text(judged, claims=(claim_json(c.claim, absorbs=("m1",)),)))
        # Only a claim that supersedes the target names it in the record.
        self.assertEqual([(s["correct"], state(s, "corrects")) for s in (kept, dropped, absorbed)],
                         [(0, [1, 0]), (0, [1, 1]), (0, [1, 1])])

    def test_a_target_goes_into_the_claim_of_its_own_candidate(self) -> None:
        kinds: tuple[tuple[S.CandidateKind, M.Kind], ...] = ((K.CORRECTION, "corrects"), (K.COMPLEMENT, "complements"))
        for kind, name in kinds:
            req, c1, c2 = two(kind, K.NEW_DURABLE)
            own = answer_text(both_incorporated(c1, c2),
                              claims=(claim_json(c1.claim, absorbs=("m1",)), claim_json(c2.claim)))
            other = answer_text(both_incorporated(c1, c2),
                                claims=(claim_json(c1.claim), claim_json(c2.claim, absorbs=("m1",))))
            self.assertEqual((state(scored(req, own), name), state(scored(req, other), name)), ([1, 1], [1, 0]), name)

    def test_a_correction_record_names_the_claim_that_supersedes_its_target(self) -> None:
        req, c1, c2 = two(K.CORRECTION, K.CORRECTION)
        joint = "교정: 링크 규칙 1번과 2번을 함께 바꾼다."
        s = scored(req, answer_text(((c1.request_id, "incorporated", joint), (c2.request_id, "incorporated", joint)),
                                    claims=(claim_json(joint, supersedes="m1"), claim_json(joint, supersedes="m2")),
                                    dropped=("m1", "m2")))
        self.assertEqual((s["correct"], state(s, "corrects")), (2, [2, 2]))
        req, c1, c2 = two(K.CORRECTION, K.NEW_DURABLE)
        other = scored(req, answer_text(both_incorporated(c1, c2),
                                        claims=(claim_json(c1.claim), claim_json(c2.claim, supersedes="m1")),
                                        dropped=("m1",)))
        self.assertEqual((other["per_candidate"], state(other, "corrects")),
                         ({c1.request_id: False, c2.request_id: True}, [1, 1]))

    def test_a_restated_fact_keeps_its_knowledge_once(self) -> None:
        req, c = one(K.PARAPHRASE)
        elsewhere: tuple[Judged, ...] = ((c.request_id, "already_represented", M2),)
        rewrite: tuple[Judged, ...] = ((c.request_id, "incorporated", c.claim),)
        absorbing = answer_text(rewrite, claims=(claim_json(c.claim, absorbs=("m1",)),))
        cases: tuple[tuple[str, str, int], ...] = (
            ("judged already_represented", answer_text(((c.request_id, "already_represented", M1),)), 1),
            ("judged not_durable", answer_text(((c.request_id, "not_durable", None),)), 1),
            ("the fact dropped", answer_text(elsewhere, dropped=("m1",)), 0),
            ("the fact absorbed into a kept claim", answer_text(elsewhere, claims=(claim_json(M2, absorbs=("m1",)),)), 0),
            ("rewritten beside the fact", answer_text(rewrite, claims=(claim_json(c.claim),)), 0),
            ("rewritten, absorbing the fact", absorbing, 1),
            ("rewritten, absorbing another fact", answer_text(rewrite, claims=(claim_json(c.claim, absorbs=("m2",)),)), 0))
        for name, answer, ok in cases:
            self.assertEqual(state(scored(req, answer), "restates"), [1, ok], name)
        s = scored(req, absorbing)
        self.assertEqual((s["correct"], s["absorbs"]), (0, {"m1": "paraphrase"}))

    def test_a_restated_fact_can_go_into_a_claim_the_answer_adds(self) -> None:
        req, c1, c2 = two(K.PARAPHRASE, K.NEW_DURABLE)
        into_c2 = claim_json(c2.claim, absorbs=("m1",))
        kept = answer_text(((c1.request_id, "already_represented", c2.claim), (c2.request_id, "incorporated", c2.claim)),
                           claims=(into_c2,))
        rewritten = answer_text(both_incorporated(c1, c2), claims=(claim_json(c1.claim), into_c2))
        self.assertEqual((state(scored(req, kept), "restates"), state(scored(req, rewritten), "restates")),
                         ([1, 1], [1, 0]))

    def test_a_transient_candidate_adds_no_claim(self) -> None:
        req, c = one(K.TRANSIENT)
        cases: tuple[tuple[str, str, int], ...] = (
            ("judged already_represented", answer_text(((c.request_id, "already_represented", M2),)), 1),
            ("judged incorporated, naming a kept claim", answer_text(((c.request_id, "incorporated", M2),)), 1),
            ("judged incorporated, adding its claim",
             answer_text(((c.request_id, "incorporated", c.claim),), claims=(claim_json(c.claim),)), 0))
        for name, answer, ok in cases:
            s = scored(req, answer)
            self.assertEqual((s["correct"], state(s, "transient")), (0, [1, ok]), name)
        req, c1, c2 = two(K.TRANSIENT, K.NEW_DURABLE)
        s = scored(req, answer_text(((c1.request_id, "already_represented", c2.claim),
                                     (c2.request_id, "incorporated", c2.claim)), claims=(claim_json(c2.claim),)))
        self.assertEqual((state(s, "transient"), state(s, "new")), ([1, 1], [1, 1]))

    def test_a_deferred_or_refused_candidate_is_right_for_no_kind(self) -> None:
        for kind in KINDS:
            req, c = one(kind)
            deferred = json.dumps({"memory": {"new_claims": [], "dropped": [], "working_state": None,
                                              "working_contexts": []},
                                   "candidates": [{"request_id": c.request_id, "outcome": "deferred",
                                                   "memory_claim": None, "reason": "근거"}],
                                   "change_support": []}, ensure_ascii=False)
            for name, answer in (("deferred", deferred), ("refused", None)):
                s = scored(req, answer)
                self.assertEqual((s["correct"], s["state_correct"]), (0, 0), f"{kind.value} {name}")


class PairTest(unittest.TestCase):
    def test_a_pair_ends_as_one_fact_inside_itself_or_in_one_claim_the_answer_adds(self) -> None:
        req, c = one(K.PARAPHRASE)
        judged: tuple[Judged, ...] = ((c.request_id, "already_represented", M1),)
        cases: tuple[tuple[str, dict[str, object], int], ...] = (
            ("m6 into m5", claim_json(M5, absorbs=("m6",)), 1),
            ("m5 into m6", claim_json(M6, absorbs=("m5",)), 1),
            ("both into a kept claim", claim_json(M2, absorbs=("m5", "m6")), 0))
        for name, claim, merged in cases:
            self.assertEqual(scored(req, answer_text(judged, claims=(claim,)))["pairs_merged"], merged, name)
        req, c = one(K.NEW_DURABLE)
        both = M5 + " " + c.claim
        joined = scored(req, answer_text(((c.request_id, "incorporated", both),),
                                         claims=(claim_json(both, absorbs=("m5", "m6")),)))
        self.assertEqual((joined["pairs_merged"], joined["absorbs"]), (1, {"m5": "duplicate", "m6": "duplicate"}))
        beside = scored(req, answer_text(((c.request_id, "incorporated", c.claim),),
                                         claims=(claim_json(c.claim, absorbs=("m6",)),)))
        self.assertEqual(beside["pairs_merged"], 0)
        req, c1, c2 = two(K.NEW_DURABLE, K.NEW_DURABLE)
        apart = answer_text(both_incorporated(c1, c2),
                            claims=(claim_json(c1.claim, absorbs=("m5",)), claim_json(c2.claim, absorbs=("m6",))))
        self.assertEqual(scored(req, apart)["pairs_merged"], 0)


if __name__ == "__main__":
    unittest.main()
