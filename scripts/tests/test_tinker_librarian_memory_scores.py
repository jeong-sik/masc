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
    SCHEDULED,
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
        for facts in (PLANTED, SCHEDULED):
            for n in (1, 2, 3):
                for kinds in itertools.product(KINDS, repeat=n):
                    with self.subTest(facts=len(facts), kinds=[k.value for k in kinds]):
                        req = request(facts, candidates_of(kinds))
                        s = scored(req, label_answer(req))
                        self.assertEqual((s["correct"], s["state_correct"]), (s["candidates"], s["candidates"]))
                        self.assertEqual(set(cast(dict[str, list[int]], s["state_by_kind"])),
                                         {M.kind_of(cl) for cl in S.label_of(req).candidates})
                        self.assertEqual((s["planted_dropped"], s["pairs_merged"], s["merges_done"]),
                                         (s["planted"], s["pairs"], s["merges"]))
                        self.assertEqual((s["dropped_expected"], s["dropped_unmerged"], s["dropped_off_label"],
                                          s["planted_absorbed"]), (s["dropped"], [], [], 0))
                        self.assertEqual((s["added"], s["removed"]), (s["expected_added"], s["expected_removed"]))
                        self.assertEqual((s["scheduled_ahead_dropped"], s["scheduled_past_dropped"]),
                                         (0, s["scheduled_past"]))

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


class RecordTest(unittest.TestCase):
    def test_a_record_ahead_that_is_dropped_counts_as_lost_and_off_label(self) -> None:
        req = request(SCHEDULED, candidates_of((K.NEW_DURABLE,)))
        [c] = req.candidates
        right = scored(req, label_answer(req))
        self.assertEqual((right["scheduled_ahead"], right["scheduled_ahead_dropped"], right["scheduled_past"],
                          right["scheduled_past_dropped"], right["planted"]), (1, 0, 1, 1, 2))
        judged: tuple[Judged, ...] = ((c.request_id, "incorporated", c.claim),)
        swapped = scored(req, answer_text(judged, claims=(claim_json(c.claim), claim_json(M5, absorbs=("m5", "m6"))),
                                          dropped=("m4", "m7")))
        self.assertEqual((swapped["scheduled_ahead_dropped"], swapped["scheduled_past_dropped"],
                          swapped["planted_dropped"], swapped["dropped_off_label"]), (1, 0, 1, ["m7"]))

    def test_records_count_whatever_the_candidates(self) -> None:
        # RFC-0517 §7.1: MASC takes drops and merges without a supporting candidate.
        req = request(SCHEDULED, candidates_of((K.TRANSIENT,)))
        s = scored(req, label_answer(req))
        self.assertEqual((s["scheduled_ahead"], s["scheduled_past"], s["planted"], s["pairs"]), (1, 1, 2, 1))
        self.assertEqual((s["scheduled_ahead_dropped"], s["scheduled_past_dropped"], s["planted_dropped"],
                          s["pairs_merged"]), (0, 1, 2, 1))


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

    def test_a_correction_adds_the_claim_that_supersedes_its_target(self) -> None:
        req, c = one(K.CORRECTION)
        # A kept claim takes the supersedes: the target goes, and the correction's knowledge never comes in.
        s = scored(req, answer_text(((c.request_id, "incorporated", M2),), claims=(claim_json(M2, supersedes="m1"),),
                                    dropped=("m1",)))
        self.assertEqual((s["added"], s["dropped_expected"], s["correct"], state(s, "corrects")), (0, 1, 0, [1, 0]))

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


class AttributionTest(unittest.TestCase):
    def test_a_claim_that_copies_a_candidate_carries_that_candidates_knowledge(self) -> None:
        kinds: tuple[tuple[S.CandidateKind, M.Kind], ...] = ((K.TRANSIENT, "transient"), (K.PARAPHRASE, "restates"))
        for first, kind in kinds:
            req, c1, c2 = two(first, K.NEW_DURABLE)
            j1: Judged = ((c1.request_id, "not_durable", None) if first is K.TRANSIENT
                          else (c1.request_id, "already_represented", M1))
            # c2 names c1's words, so c2's own knowledge never comes in and c1's does.
            s = scored(req, answer_text((j1, (c2.request_id, "incorporated", c1.claim)), claims=(claim_json(c1.claim),)))
            self.assertEqual((s["correct"], state(s, kind), state(s, "new")), (1, [1, 0], [1, 0]), kind)

    def test_candidates_that_name_each_others_words_are_both_wrong(self) -> None:
        req, c1, c2 = two(K.NEW_DURABLE, K.NEW_DURABLE)
        swapped = scored(req, answer_text(((c1.request_id, "incorporated", c2.claim),
                                           (c2.request_id, "incorporated", c1.claim)),
                                          claims=(claim_json(c1.claim), claim_json(c2.claim))))
        rewritten = "새로 정한 두 규칙을 한 문장으로 다시 쓴 기억."
        own = scored(req, answer_text(((c1.request_id, "incorporated", c1.claim),
                                       (c2.request_id, "incorporated", rewritten)),
                                      claims=(claim_json(c1.claim), claim_json(rewritten))))
        self.assertEqual([(s["correct"], state(s, "new")) for s in (swapped, own)], [(0, [2, 0]), (2, [2, 2])])


    def test_a_correction_that_names_another_candidates_words_is_wrong(self) -> None:
        req, c1, c2 = two(K.CORRECTION, K.NEW_DURABLE)
        s = scored(req, answer_text(((c1.request_id, "incorporated", c2.claim), (c2.request_id, "incorporated", c2.claim)),
                                    claims=(claim_json(c2.claim, supersedes="m1"),), dropped=("m1",)))
        self.assertEqual((s["per_candidate"], state(s, "corrects"), state(s, "new")),
                         ({c1.request_id: False, c2.request_id: True}, [1, 0], [1, 1]))


class SupportTest(unittest.TestCase):
    def test_a_request_no_candidate_supports_still_asks_for_its_drops_and_merges(self) -> None:
        # RFC-0517 §7.1: MASC takes drops and merges without a supporting candidate, so the answer that
        # leaves memory as it is misses the stale fact and the pair.
        req, c = one(K.TRANSIENT)
        judged: tuple[Judged, ...] = ((c.request_id, "not_durable", None),)
        left = scored(req, answer_text(judged))
        cleaned = scored(req, answer_text(judged, claims=(claim_json(M5, absorbs=("m6",)),), dropped=("m4",)))
        self.assertEqual([(s["correct"], s["state_correct"]) for s in (left, cleaned)], [(1, 1), (1, 1)])
        self.assertEqual([(s["planted"], s["pairs"], s["merges"], s["expected_removed"]) for s in (left, cleaned)],
                         [(1, 1, 1, 2), (1, 1, 1, 2)])
        self.assertEqual([(s["planted_dropped"], s["pairs_merged"], s["merges_done"], s["removed"])
                          for s in (left, cleaned)], [(0, 0, 0, 0), (1, 1, 1, 2)])


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

    def test_a_made_merge_names_the_memories_it_absorbed(self) -> None:
        # The merge judge's verdict on those absorbs decides whether the merge kept its knowledge.
        req = request(PLANTED, candidates_of((K.COMPLEMENT,)))
        self.assertEqual(scored(req, label_answer(req))["merges_absorbed"], [["m1"], ["m6"]])
        req, c = one(K.NEW_DURABLE)
        both = M5 + " " + c.claim
        joined = scored(req, answer_text(((c.request_id, "incorporated", both),),
                                         claims=(claim_json(both, absorbs=("m5", "m6")),)))
        self.assertEqual(joined["merges_absorbed"], [["m5", "m6"]])
        req, c = one(K.COMPLEMENT)
        beside = scored(req, answer_text(((c.request_id, "incorporated", c.claim),), claims=(claim_json(c.claim),)))
        self.assertEqual(beside["merges_absorbed"], [])
        # The complement's target goes into another candidate's claim: the expected merge is not made.
        req, c, new = two(K.COMPLEMENT, K.NEW_DURABLE)
        elsewhere = new.claim + " " + M1
        moved = scored(req, answer_text(((c.request_id, "incorporated", c.claim),
                                         (new.request_id, "incorporated", elsewhere)),
                                        claims=(claim_json(c.claim), claim_json(elsewhere, absorbs=("m1",)))))
        self.assertEqual(moved["merges_absorbed"], [])


if __name__ == "__main__":
    unittest.main()
