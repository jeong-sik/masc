# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the labels of synthetic requests (scripts/tinker/librarian/synth_spec.py) and for
the teacher answers kept as training targets (teacher_sample.py), with the merge judge's
classes for the answers that absorb a memory.

A label is a Memory decision MASC accepts: the answer it asks for passes
`admission_validator` for the prompt `synth_render` makes from the request.
`test_tinker_librarian_memory_scores.py` scores that answer. Requests and answers come from
`tinker_librarian_synth_fixtures.py`. `teacher_sample` imports the Tinker caller,
which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import argparse
import dataclasses
import itertools
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import admission_result as AR
import admission_validator as AV
import audit_decisions as D
import eval_admission as V
import memory_scores as M
import synth_rows as RW
import synth_spec as S
import teacher_sample as T
from tinker_librarian_synth_fixtures import (
    KINDS,
    PLANTED,
    SCHEDULED,
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
    def test_a_label_names_the_planted_facts_and_asks_for_them_only_with_support(self) -> None:
        alone = S.label_of(request(PLANTED, candidates_of((S.CandidateKind.TRANSIENT, S.CandidateKind.TRANSIENT))))
        supported = S.label_of(request(PLANTED, candidates_of((S.CandidateKind.TRANSIENT, S.CandidateKind.PARAPHRASE))))
        for label in (alone, supported):
            self.assertEqual((label.planted_stale, label.duplicates), (frozenset({"m4"}), (("m5", "m6"),)))
        self.assertEqual((alone.supports_change, supported.supports_change), (False, True))

    def test_a_label_keeps_a_record_ahead_and_drops_a_past_one(self) -> None:
        label = S.label_of(request(SCHEDULED, candidates_of((S.CandidateKind.PARAPHRASE,))))
        self.assertEqual((label.planted_stale, label.scheduled_ahead, label.scheduled_past),
                         (frozenset({"m4", "m8"}), frozenset({"m7"}), frozenset({"m8"})))

    def test_a_complement_absorbs_its_target(self) -> None:
        [cl] = S.label_of(request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT,)))).candidates
        self.assertEqual((cl.outcome, cl.supersedes, cl.absorbs, cl.already_claim), ("incorporated", None, "m1", None))


class ContractTest(unittest.TestCase):
    def test_masc_accepts_the_answer_every_label_asks_for(self) -> None:
        for facts in (PLANTED, SCHEDULED):
            by_id = {f.memory_id: f for f in facts}
            for n in (1, 2, 3):
                for kinds in itertools.product(KINDS, repeat=n):
                    with self.subTest(facts=len(facts), kinds=[k.value for k in kinds]):
                        req = request(facts, candidates_of(kinds))
                        label = S.label_of(req)
                        got = accepted(req, label_answer(req))
                        by_request = {c.request_id: c for c in req.candidates}
                        corrected = {cl.supersedes for cl in label.candidates if cl.supersedes is not None}
                        complemented = {cl.absorbs: merged(by_id[cl.absorbs], by_request[cl.request_id])
                                        for cl in label.candidates if cl.absorbs is not None}
                        asks = label.supports_change
                        self.assertEqual(set(got.dropped),
                                         (label.planted_stale if asks else frozenset[str]()) | corrected)
                        self.assertEqual(dict(got.absorbed), complemented | {
                            gone: by_id[kept].claim for kept, gone in label.duplicates if asks})
                        gone = set(got.dropped) | set(dict(got.absorbed))
                        self.assertEqual(set(got.memory_after) - set(got.added_claims),
                                         {f.claim for f in facts if f.memory_id not in gone})

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


def teacher_answer(req: S.SynthRequest, *, absorbs: tuple[str, ...], pair: bool, dropped: tuple[str, ...]) -> str:
    """An answer MASC accepts on PLANTED or SCHEDULED with a complement of m1 (k1) and a new fact
    (k2). The complement's claim joins m1 when `absorbs` holds m1; `pair` merges m6 into m5."""
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
    def test_the_answer_a_label_asks_for_passes_and_so_does_a_merge_outside_the_label(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT, S.CandidateKind.NEW_DURABLE)))
        self.assertIsNone(teacher_rejection(req, label_answer(req)))
        self.assertIsNone(teacher_rejection(req, teacher_answer(req, absorbs=("m1",), pair=True, dropped=("m4",))))
        # m2 goes into the complement's claim: the merge judge decides whether that answer is kept.
        self.assertIsNone(teacher_rejection(req, teacher_answer(req, absorbs=("m1", "m2"), pair=True,
                                                                dropped=("m4",))))

    def test_an_answer_that_absorbs_a_memory_waits_for_the_merge_judge(self) -> None:
        both = request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT, S.CandidateKind.NEW_DURABLE)))
        plain = request(PLANTED, candidates_of((S.CandidateKind.TRANSIENT, S.CandidateKind.TRANSIENT)))
        for req, answer, waits in ((both, label_answer(both), True), (plain, label_answer(plain), False)):
            item = M.SynthItem(req.item_id, prompt_of(req), "", S.label_of(req))
            self.assertEqual(T.screened(item, V.check(item.prompt, answer), {"item": req.item_id}),
                             T.Target({"item": req.item_id}, waits))
        item = M.SynthItem(both.item_id, prompt_of(both), "", S.label_of(both))
        stale = teacher_answer(both, absorbs=("m1", "m4"), pair=True, dropped=())
        self.assertEqual(T.screened(item, V.check(item.prompt, stale), {}), "stale_absorbed")

    def test_an_answer_that_skips_a_merge_or_absorbs_a_stale_fact_is_not_kept(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT, S.CandidateKind.NEW_DURABLE)))
        # (complement's absorbs, pair merged, dropped) -> why the answer is not kept
        cases: tuple[tuple[tuple[str, ...], bool, tuple[str, ...], str], ...] = (
            ((), True, ("m4",), "memory_state"),
            (("m1",), False, ("m4",), "duplicate_kept"),
            (("m1", "m4"), True, (), "stale_absorbed"),
            (("m1",), True, (), "stale_kept"),
            (("m1",), True, ("m4", "m2"), "unexpected_drop"))
        for absorbs, pair, dropped, why in cases:
            answer = teacher_answer(req, absorbs=absorbs, pair=pair, dropped=dropped)
            self.assertEqual(teacher_rejection(req, answer), why, (absorbs, pair, dropped))

    def test_an_answer_that_drops_a_record_ahead_or_keeps_a_past_one_is_not_kept(self) -> None:
        req = request(SCHEDULED, candidates_of((S.CandidateKind.COMPLEMENT, S.CandidateKind.NEW_DURABLE)))
        self.assertIsNone(teacher_rejection(req, label_answer(req)))
        # (complement's absorbs, dropped) -> why the answer is not kept; m7 is ahead, m8 past.
        cases: tuple[tuple[tuple[str, ...], tuple[str, ...], str], ...] = (
            (("m1",), ("m4", "m8", "m7"), "unexpected_drop"),
            (("m1",), ("m4",), "stale_kept"),
            (("m1", "m8"), ("m4",), "stale_absorbed"))
        for absorbs, dropped, why in cases:
            answer = teacher_answer(req, absorbs=absorbs, pair=True, dropped=dropped)
            self.assertEqual(teacher_rejection(req, answer), why, (absorbs, dropped))

    def test_an_answer_that_misjudges_a_candidate_is_not_kept_though_its_memory_is_right(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.TRANSIENT, S.CandidateKind.NEW_DURABLE)))
        c1, c2 = req.candidates
        by_id = {f.memory_id: f for f in req.facts}
        # The transient is judged incorporated into the kept claim of m2, so nothing of it is added.
        answer = answer_text(((c1.request_id, "incorporated", by_id["m2"].claim), (c2.request_id, "incorporated", c2.claim)),
                             claims=(claim_json(c2.claim), claim_json(by_id["m5"].claim, absorbs=("m5", "m6"))),
                             dropped=("m4",))
        item = M.SynthItem(req.item_id, prompt_of(req), "", S.label_of(req))
        self.assertEqual(M.score_synth(item, accepted(req, answer))["state_correct"], 2)
        self.assertEqual(teacher_rejection(req, answer), "outcome")


def record(req: S.SynthRequest, answer: str) -> dict[str, object]:
    return {"item": req.item_id, "attempt": 0, "answer": answer}


class TeacherMergeTest(unittest.TestCase):
    """`cases` and `apply` over a sampled folder: one answer without absorbs, one that absorbs as its
    label asks, and one that also absorbs m2 into the complement's claim."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        folder = Path(self.tmp.name)
        self.out = folder / "teacher"
        self.out.mkdir()
        both = request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT, S.CandidateKind.NEW_DURABLE)))
        self.labeled = dataclasses.replace(both, item_id="train-docs-gardener-00-001")
        self.off = dataclasses.replace(both, item_id="train-docs-gardener-00-002")
        self.plain = dataclasses.replace(
            request(PLANTED, candidates_of((S.CandidateKind.TRANSIENT, S.CandidateKind.TRANSIENT))),
            item_id="train-docs-gardener-00-003")
        self.requests = folder / "requests.jsonl"
        self.requests.write_text("".join(json.dumps({"request": RW.row_of(r)}, ensure_ascii=False) + "\n"
                                         for r in (self.labeled, self.off, self.plain)), encoding="utf-8")
        T.write_jsonl(self.out / T.KEPT, [record(self.plain, label_answer(self.plain))])
        T.write_jsonl(self.out / T.PENDING, [
            record(self.labeled, label_answer(self.labeled)),
            record(self.off, teacher_answer(self.off, absorbs=("m1", "m2"), pair=True, dropped=("m4",)))])
        (self.out / "summary.json").write_text(json.dumps({"requests_sha256": D.file_sha256(self.requests)}),
                                               encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def args(self) -> argparse.Namespace:
        return argparse.Namespace(requests=str(self.requests), out=str(self.out))

    def decide(self) -> None:
        """m2's absorb loses knowledge; every other absorb is mergeable."""
        folder = self.out / T.MERGES
        decisions: list[str] = []
        for key in D.read_jsonl(folder / "key.jsonl"):
            off = [self.off.item_id, T.TARGET, "m2"] in cast(list[list[str]], key["absorbs"])
            decisions.append(json.dumps({"case": key["case"], "reason": "r",
                                         "decision": "loses_knowledge" if off else "mergeable"}))
        (folder / D.JUDGE_DIR / D.DECISIONS).write_text("\n".join(decisions) + "\n", encoding="utf-8")

    def accepted_items(self) -> list[object]:
        return [r["item"] for r in D.read_jsonl(self.out / T.ACCEPTED)]

    def test_an_answer_with_absorbs_is_kept_only_when_the_judge_finds_each_mergeable(self) -> None:
        self.assertEqual(T.cases(self.args()), 0)
        keys = D.read_jsonl(self.out / T.MERGES / "key.jsonl")
        self.assertEqual(sorted(tuple(a) for k in keys for a in cast(list[list[str]], k["absorbs"])),
                         sorted((r.item_id, T.TARGET, m) for r, ms in ((self.labeled, ("m1", "m6")),
                                                                      (self.off, ("m1", "m2", "m6")))
                                for m in ms))
        self.decide()
        self.assertEqual(T.apply(self.args()), 0)
        self.assertEqual(self.accepted_items(), [self.plain.item_id, self.labeled.item_id])
        summary = json.loads((self.out / "accepted-summary.json").read_text(encoding="utf-8"))
        self.assertEqual((summary["kept"], summary["pending"], summary["merged"]), (1, 2, 1))

    def test_decisions_are_read_only_for_the_waiting_answers_the_cases_were_made_from(self) -> None:
        T.cases(self.args())
        self.decide()
        T.write_jsonl(self.out / T.PENDING, D.read_jsonl(self.out / T.PENDING)[:1])
        with self.assertRaisesRegex(SystemExit, "were made from another pending.jsonl"):
            T.apply(self.args())

    def test_without_waiting_answers_apply_needs_no_judge(self) -> None:
        T.write_jsonl(self.out / T.PENDING, [])
        self.assertEqual(T.apply(self.args()), 0)
        self.assertEqual(self.accepted_items(), [self.plain.item_id])

    def test_requests_other_than_the_sampled_ones_are_refused(self) -> None:
        self.requests.write_text(self.requests.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        for command in (T.cases, T.apply):
            with self.subTest(command=command.__name__), self.assertRaisesRegex(SystemExit, "other requests"):
                command(self.args())


if __name__ == "__main__":
    unittest.main()
