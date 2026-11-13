# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the blind judge of what merged claims add: the cases scripts/tinker/librarian/merge_additions.py
writes for the claims E-synth answers merge memories into, and the counts it reads from the judge's classes.

Requests and answers come from `tinker_librarian_synth_fixtures.py`: m4 is
stale, m6 restates m5, and targets come from m1, m2 and m3. `merge_additions`
imports the Tinker caller, which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import json
import random
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import admission_validator as AV
import audit_decisions as D
import e_synth_audit as A
import memory_scores as M
import merge_additions as MA
import synth_spec as S
from tinker_librarian_synth_fixtures import (
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

type JsonObject = dict[str, object]
K = S.CandidateKind
BY_ID = {f.memory_id: f for f in PLANTED}
ITEM = request(PLANTED, ()).item_id


def item_of(req: S.SynthRequest) -> M.SynthItem:
    return M.SynthItem(req.item_id, prompt_of(req), "", S.label_of(req))


def complement_and_new() -> S.SynthRequest:
    return request(PLANTED, candidates_of((K.COMPLEMENT, K.NEW_DURABLE)))


def joined(*mids: str) -> str:
    return " ".join(BY_ID[m].claim for m in mids)


def uncited(req: S.SynthRequest, claim: str, absorbs: tuple[str, ...]) -> AV.AdmissionAnswer:
    """An answer that finds every candidate not durable and adds one claim absorbing `absorbs`."""
    judged: tuple[Judged, ...] = tuple((c.request_id, "not_durable", None) for c in req.candidates)
    return accepted(req, answer_text(judged, claims=(claim_json(claim, absorbs=absorbs),)))


class MergesTest(unittest.TestCase):
    def test_a_merge_shows_its_claim_the_memories_it_absorbs_and_the_candidates_it_cites(self) -> None:
        # The label's answer merges m1 into the complement's claim, which cites k1.
        req = complement_and_new()
        k1, _ = req.candidates
        c1, _ = item_of(req).prompt.candidates
        answer = accepted(req, label_answer(req))
        self.assertEqual(MA.merges(item_of(req), answer),
                         [(("m1",), MA.Merge((BY_ID["m1"].claim,), (c1,), merged(BY_ID["m1"], k1)))])
        # The pair's claim keeps m5's text and absorbs m6: it adds no words and gets no case.
        self.assertEqual(MA.kept_claims(answer), 1)

    def test_a_merge_that_supersedes_nothing_needs_no_candidate_and_cites_none(self) -> None:
        # RFC-0517 §7.1. The sources and IDs come in memory order, whatever order `absorbs` names them in.
        req = request(PLANTED, candidates_of((K.TRANSIENT,)))
        claim = joined("m1", "m2")
        answer = uncited(req, claim, ("m2", "m1"))
        self.assertEqual(MA.merges(item_of(req), answer),
                         [(("m1", "m2"), MA.Merge((BY_ID["m1"].claim, BY_ID["m2"].claim), (), claim))])
        self.assertEqual(MA.kept_claims(answer), 0)

    def test_a_claim_that_supersedes_one_memory_and_absorbs_another_stands_in_for_both(self) -> None:
        # The correction targets m1; its claim also absorbs m2.
        req = request(PLANTED, candidates_of((K.CORRECTION,)))
        [k1] = req.candidates
        [c1] = item_of(req).prompt.candidates
        claim = k1.claim + " " + BY_ID["m2"].claim
        answer = accepted(req, answer_text(((k1.request_id, "incorporated", claim),),
                                           claims=(claim_json(claim, supersedes="m1", absorbs=("m2",)),),
                                           dropped=("m1",)))
        self.assertEqual(MA.merges(item_of(req), answer),
                         [(("m2",), MA.Merge((BY_ID["m1"].claim, BY_ID["m2"].claim), (c1,), claim))])

    def test_a_claim_cites_only_supporting_candidates_whose_judgment_names_it(self) -> None:
        req = request(PLANTED, candidates_of((K.NEW_DURABLE, K.NEW_DURABLE)))
        k1, k2 = req.candidates
        c1, _ = item_of(req).prompt.candidates
        both = k1.claim + " " + BY_ID["m2"].claim
        # k2 supports the change and names its own claim.
        apart = answer_text(((k1.request_id, "incorporated", both), (k2.request_id, "incorporated", k2.claim)),
                            claims=(claim_json(both, absorbs=("m2",)), claim_json(k2.claim)))
        # k2 names the claim and does not support the change.
        together = cast(JsonObject, json.loads(answer_text(
            ((k1.request_id, "incorporated", both), (k2.request_id, "incorporated", both)),
            claims=(claim_json(both, absorbs=("m2",)),))))
        together["change_support"] = [k1.request_id]
        for answer in (apart, json.dumps(together, ensure_ascii=False)):
            [(mids, merge)] = MA.merges(item_of(req), accepted(req, answer))
            self.assertEqual((mids, merge.observations), (("m2",), (c1,)))


def answers_on_one_request() -> tuple[dict[str, M.SynthItem], dict[tuple[str, str], AV.AdmissionAnswer]]:
    """A and C give the label's answer (m1 into the complement's claim, citing k1); base joins m2 and m3
    into one claim and cites nothing."""
    req = complement_and_new()
    label = accepted(req, label_answer(req))
    return ({ITEM: item_of(req)},
            {("A", ITEM): label, ("C", ITEM): label, ("base", ITEM): uncited(req, joined("m2", "m3"), ("m2", "m3"))})


class CasesTest(unittest.TestCase):
    def test_answers_that_make_one_merge_share_a_case_that_shows_no_target_item_or_memory_id(self) -> None:
        case_rows, key_rows = MA.render(MA.collect(*answers_on_one_request()), "20261109:additions")
        by_case = {cast(str, k["case"]): k["merges"] for k in key_rows}
        shapes = {cast(str, c["case"]): list(c) for c in case_rows}
        self.assertEqual(sorted((shapes[case], merges) for case, merges in by_case.items()), [
            (["case", "source_memories", "new_observations", "proposed_memory"],
             [[ITEM, "A", ["m1"]], [ITEM, "C", ["m1"]]]),
            (["case", "source_memories", "proposed_memory"], [[ITEM, "base", ["m2", "m3"]]])])
        shown = json.dumps(case_rows, ensure_ascii=False)
        for hidden in (ITEM, "base", "A", "C", *BY_ID):
            self.assertNotIn(f'"{hidden}"', shown)

    def test_the_cases_come_in_the_order_the_seed_draws(self) -> None:
        collected = {MA.Merge((f"source {n}",), (), f"claim {n}"): [(ITEM, "A", (f"m{n}",))] for n in range(1, 7)}
        drawn = list(collected)
        random.Random("20261109:additions").shuffle(drawn)
        first, _ = MA.render(collected, "20261109:additions")
        self.assertEqual([c["proposed_memory"] for c in first], [m.claim for m in drawn])
        other, _ = MA.render(collected, "20261110:additions")
        self.assertNotEqual([c["proposed_memory"] for c in other], [c["proposed_memory"] for c in first])

    def test_the_judge_reads_every_class_with_its_criterion(self) -> None:
        text = MA.judging()
        self.assertEqual(set(MA.CRITERIA), set(MA.ADDITIONS))
        for a in MA.ADDITIONS:
            self.assertIn(f'- "{a}": {MA.CRITERIA[a]}\n', text)


def decided(key_rows: list[JsonObject], case_rows: list[JsonObject]) -> list[JsonObject]:
    """`adds_unsupported` for the case that cites nothing, `no_addition` for the rest."""
    return [{"case": k["case"], "reason": "r",
             "decision": "no_addition" if "new_observations" in c else "adds_unsupported"}
            for k, c in zip(key_rows, case_rows, strict=True)]


class CountTest(unittest.TestCase):
    def folder(self, tmp: str, decisions: list[JsonObject] | None = None) -> tuple[Path, list[JsonObject],
                                                                                 list[JsonObject]]:
        case_rows, key_rows = MA.render(MA.collect(*answers_on_one_request()), "s")
        out = Path(tmp) / "additions"
        A.write_cases(out, case_rows, key_rows, MA.judging())
        written = decided(key_rows, case_rows) if decisions is None else decisions
        (out / D.JUDGE_DIR / D.DECISIONS).write_text("".join(json.dumps(d) + "\n" for d in written),
                                                     encoding="utf-8")
        return out, case_rows, key_rows

    def test_each_targets_merges_are_counted_by_class_apart_for_citing_and_not_citing_claims(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out, case_rows, key_rows = self.folder(tmp)
            got = MA.count_folder(out, case_rows, key_rows)
        none = {"merges": 0, "no_addition": 0, "adds_unsupported": 0, "uncertain": 0}
        citing = {**none, "merges": 1, "no_addition": 1}
        self.assertEqual(got["by_target"], {
            "A": {"citing": citing, "not_citing": none}, "C": {"citing": citing, "not_citing": none},
            "base": {"citing": none, "not_citing": {**none, "merges": 1, "adds_unsupported": 1}}})
        self.assertEqual(got["merges"], [
            {"item": ITEM, "target": "A", "absorbs": ["m1"], "citing": True, "judged": "no_addition"},
            {"item": ITEM, "target": "C", "absorbs": ["m1"], "citing": True, "judged": "no_addition"},
            {"item": ITEM, "target": "base", "absorbs": ["m2", "m3"], "citing": False, "judged": "adds_unsupported"}])

    def test_a_missing_extra_doubled_or_unknown_decision_is_refused(self) -> None:
        case_rows, key_rows = MA.render(MA.collect(*answers_on_one_request()), "s")
        good = decided(key_rows, case_rows)
        with self.assertRaisesRegex(SystemExit, "decisions cover 1 cases"):
            MA.adjudicate(key_rows, good[:1])
        with self.assertRaisesRegex(SystemExit, "decisions cover 3 cases"):
            MA.adjudicate(key_rows, [*good, {"case": "a003", "decision": "no_addition"}])
        with self.assertRaisesRegex(SystemExit, "more than once"):
            MA.adjudicate(key_rows, [*good, good[0]])
        for written in ("No_addition", "mergeable", None):
            with self.assertRaisesRegex(SystemExit, "no class of the addition judge"):
                MA.adjudicate(key_rows, [good[0], {**good[1], "decision": written}])

    def test_a_folder_without_decisions_or_with_a_changed_judge_file_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out, case_rows, key_rows = self.folder(tmp)
            (out / D.JUDGE_DIR / D.DECISIONS).unlink()
            with self.assertRaisesRegex(SystemExit, "has not decided yet"):
                MA.count_folder(out, case_rows, key_rows)
        with tempfile.TemporaryDirectory() as tmp:
            out, case_rows, key_rows = self.folder(tmp)
            with (out / D.JUDGE_DIR / "judge.md").open("a", encoding="utf-8") as fh:
                fh.write("\n")
            with self.assertRaisesRegex(SystemExit, "changed after the cases were written"):
                MA.count_folder(out, case_rows, key_rows)

    def test_decisions_are_read_only_for_the_cases_the_run_makes_now(self) -> None:
        items, answers = answers_on_one_request()
        # base joins the same memories into another claim: the key stays, the case does not.
        again = {**answers, ("base", ITEM): uncited(complement_and_new(), joined("m3", "m2"), ("m2", "m3"))}
        now_cases, now_key = MA.render(MA.collect(items, again), "s")
        with tempfile.TemporaryDirectory() as tmp:
            out, _, key_rows = self.folder(tmp)
            self.assertEqual(now_key, key_rows)
            with self.assertRaisesRegex(SystemExit, "cases in .* were made from another run"):
                MA.count_folder(out, now_cases, now_key)
            # Without base's answer the key differs too.
            fewer_cases, fewer_key = MA.render(MA.collect(items, {k: v for k, v in answers.items() if k[0] != "base"}),
                                               "s")
            with self.assertRaisesRegex(SystemExit, "key in .* was made from another run"):
                MA.count_folder(out, fewer_cases, fewer_key)


if __name__ == "__main__":
    unittest.main()
