# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the blind merge judge: the cases scripts/tinker/librarian/merge_cases.py writes for the
memories an E-synth run's answers absorb, and what merge_decisions.py reads from the judge's classes.

Requests and answers come from `tinker_librarian_synth_fixtures.py`: m4 is
stale, m6 restates m5, and targets come from m1, m2 and m3. `merge_cases`
imports the Tinker caller, which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import admission_template as AT
import audit_decisions as D
import e_synth_audit as A
import memory_scores as M
import merge_cases as MC
import merge_decisions as MD
import synth_render
import synth_spec as S
from tinker_librarian_synth_fixtures import (
    PLANTED,
    accepted,
    answer_text,
    candidates_of,
    claim_json,
    label_answer,
    merged,
    prompt_of,
    request,
)

K = S.CandidateKind
BY_ID = {f.memory_id: f for f in PLANTED}
RULES = synth_render.TEMPLATE.read_text(encoding="utf-8")
ITEM = request(PLANTED, ()).item_id


def item_of(req: S.SynthRequest) -> M.SynthItem:
    return M.SynthItem(req.item_id, prompt_of(req), "", S.label_of(req))


def complement_and_new() -> S.SynthRequest:
    return request(PLANTED, candidates_of((K.COMPLEMENT, K.NEW_DURABLE)))


class CaseTest(unittest.TestCase):
    def test_a_case_is_what_the_gate_reads_for_one_absorbed_memory(self) -> None:
        # The label's answer absorbs m1 into the complement's claim and m6 into m5's claim, and drops m4.
        req = complement_and_new()
        k1, _ = req.candidates
        got = MC.states(item_of(req), accepted(req, label_answer(req)))
        self.assertEqual(got, [
            ("m1", MC.State(BY_ID["m1"].claim, merged(BY_ID["m1"], k1), (("doc_links", k1.claim),))),
            ("m6", MC.State(BY_ID["m6"].claim, BY_ID["m5"].claim, ()))])

    def test_a_claim_cites_only_supporting_candidates_whose_judgment_names_it(self) -> None:
        req = request(PLANTED, candidates_of((K.NEW_DURABLE, K.NEW_DURABLE)))
        k1, k2 = req.candidates
        both = k1.claim + " " + BY_ID["m2"].claim
        # k2 supports the change and names its own claim.
        apart = answer_text(((k1.request_id, "incorporated", both), (k2.request_id, "incorporated", k2.claim)),
                            claims=(claim_json(both, absorbs=("m2",)), claim_json(k2.claim)))
        # k2 names the claim and does not support the change.
        together = cast(dict[str, object], json.loads(answer_text(
            ((k1.request_id, "incorporated", both), (k2.request_id, "incorporated", both)),
            claims=(claim_json(both, absorbs=("m2",)),))))
        together["change_support"] = [k1.request_id]
        for answer in (apart, json.dumps(together, ensure_ascii=False)):
            [(mid, state)] = MC.states(item_of(req), accepted(req, answer))
            self.assertEqual((mid, state.observations), ("m2", (("doc_links", k1.claim),)))

    def test_an_absorbed_planted_stale_fact_gets_no_case(self) -> None:
        req = request(PLANTED, candidates_of((K.NEW_DURABLE,)))
        [k1] = req.candidates
        claim = k1.claim + " " + BY_ID["m4"].claim
        answer = answer_text(((k1.request_id, "incorporated", claim),), claims=(claim_json(claim, absorbs=("m4",)),))
        self.assertEqual(MC.states(item_of(req), accepted(req, answer)), [])

    def test_answers_that_make_one_state_share_a_case_that_shows_no_target_request_or_memory_id(self) -> None:
        req = complement_and_new()
        answer = accepted(req, label_answer(req))
        collected = MC.collect({req.item_id: item_of(req)}, {("base", req.item_id): answer, ("A", req.item_id): answer})
        case_rows, key_rows = MC.render(collected, "20261109:merges")
        self.assertEqual(sorted(sorted(map(tuple, cast(list[list[str]], k["absorbs"]))) for k in key_rows),
                         [[(ITEM, "A", "m1"), (ITEM, "base", "m1")], [(ITEM, "A", "m6"), (ITEM, "base", "m6")]])
        # The complement's claim cites k1; the pair's claim cites nothing, so its case has no observations.
        self.assertEqual(sorted(sorted(c) for c in case_rows),
                         [["case", "new_observations", "proposed_memory", "source_memory"],
                          ["case", "proposed_memory", "source_memory"]])
        shown = json.dumps(case_rows, ensure_ascii=False)
        for hidden in (ITEM, "base", "A", *(c.request_id for c in req.candidates), *BY_ID):
            self.assertNotIn(f'"{hidden}"', shown)

    def test_the_cases_come_in_an_order_drawn_from_the_seed(self) -> None:
        states = {MC.State(f"source {n}", f"claim {n}", ()): [(ITEM, "A", f"m{n}")] for n in range(1, 7)}
        first, _ = MC.render(states, "20261109:merges")
        again, _ = MC.render(states, "20261109:merges")
        self.assertEqual(first, again)
        self.assertNotEqual([c["source_memory"] for c in first], [f"source {n}" for n in range(1, 7)])


def call_row(label: str, content: str | None, status: int = 200) -> dict[str, object]:
    return {"key": label, "label": label, "status": status, "finish": "stop", "content": content,
            "reasoning": None, "prompt_tokens": 1, "cached_tokens": 1, "completion_tokens": 1, "wall_s": 1.0,
            "sent_at": 1.0}


class AnswersTest(unittest.TestCase):
    def test_a_valid_row_takes_its_measured_call_and_not_a_warm_or_failed_one(self) -> None:
        req = complement_and_new()
        text = label_answer(req)
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            # A failed attempt holds no answer wherever the log puts it.
            calls = [call_row(f"synth:A:{ITEM}", text), call_row(f"synth:A:{ITEM}", None, 500),
                     call_row(f"synth:A:{ITEM}:warm", "x")]
            (run / "calls.jsonl").write_text("".join(json.dumps(c) + "\n" for c in calls), encoding="utf-8")
            (run / "rows.jsonl").write_text(json.dumps({"item": ITEM, "target": "A", "valid": True}) + "\n",
                                            encoding="utf-8")
            self.assertEqual(MC.answers_of(run, {ITEM: item_of(req)}), {("A", ITEM): accepted(req, text)})
            (run / "calls.jsonl").write_text(json.dumps(call_row(f"synth:A:{ITEM}", "{}")) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "holds no valid answer"):
                MC.answers_of(run, {ITEM: item_of(req)})


class JudgingTest(unittest.TestCase):
    def test_the_judge_reads_the_gates_question_in_the_rules_words(self) -> None:
        slots = AT.slots_of(RULES)
        text = MC.judging(RULES)
        self.assertIn(f"{slots['absorb_forward']} {slots['absorb_pair']}", text)
        self.assertIn(f"{slots['absorb_forward']} {slots['absorb_observations']}", text)
        for c in MD.CONSOLIDATIONS:
            self.assertIn(f'- "{c}": {slots[f"absorb_{c}"]}\n', text)

    def test_rules_without_one_of_the_gates_slots_stop_the_cases(self) -> None:
        cut = RULES.replace("### absorb_uncertain", "### absorb_unsure")
        with self.assertRaisesRegex(SystemExit, "absorb_uncertain"):
            MC.judging(cut)


KEYS: list[MD.JsonObject] = [{"case": "g001", "absorbs": [[ITEM, "A", "m1"], [ITEM, "base", "m1"]]},
                             {"case": "g002", "absorbs": [[ITEM, "A", "m6"]]}]
ABSORBS = frozenset({(ITEM, "A", "m1"), (ITEM, "base", "m1"), (ITEM, "A", "m6")})
DECISIONS: list[MD.JsonObject] = [{"case": "g001", "decision": "mergeable", "reason": "r"},
                                  {"case": "g002", "decision": "loses_knowledge", "reason": "r"}]


class DecisionsTest(unittest.TestCase):
    def test_each_absorb_takes_the_class_of_its_case(self) -> None:
        self.assertEqual(dict(MD.adjudicate(KEYS, DECISIONS, ABSORBS).judged),
                         {(ITEM, "A", "m1"): "mergeable", (ITEM, "base", "m1"): "mergeable",
                          (ITEM, "A", "m6"): "loses_knowledge"})

    def test_cases_made_for_other_absorbs_are_refused(self) -> None:
        twice: list[MD.JsonObject] = [*KEYS, {"case": "g003", "absorbs": [[ITEM, "A", "m6"]]}]
        for keys, absorbs in ((KEYS, ABSORBS - {(ITEM, "A", "m6")}), (KEYS, ABSORBS | {(ITEM, "A", "m2")}),
                              (twice, ABSORBS)):
            with self.assertRaisesRegex(SystemExit, "other absorbs"):
                MD.adjudicate(keys, DECISIONS, absorbs)

    def test_a_missing_or_unknown_decision_is_refused(self) -> None:
        with self.assertRaisesRegex(SystemExit, "decisions cover 1 cases"):
            MD.adjudicate(KEYS, DECISIONS[:1], ABSORBS)
        for written in ("Mergeable", "merge", None):
            with self.assertRaisesRegex(SystemExit, "no class of the absorb gate"):
                MD.adjudicate(KEYS, [DECISIONS[0], {"case": "g002", "decision": written}], ABSORBS)
        with self.assertRaisesRegex(SystemExit, "more than once"):
            MD.adjudicate(KEYS, [*DECISIONS, DECISIONS[1]], ABSORBS)


def merge_row(item: str, absorbs: dict[str, str], merges: int, made: list[list[str]]) -> MD.JsonObject:
    return {"item": item, "target": "A", "absorbs": absorbs, "merges": merges, "merges_absorbed": made}


class NumbersTest(unittest.TestCase):
    def test_precision_counts_every_absorb_and_recall_needs_every_absorb_of_a_merge_mergeable(self) -> None:
        scored = merge_row("i1", {"m1": "complement", "m4": "stale", "m5": "duplicate", "m6": "duplicate"}, 2,
                           [["m1"], ["m5", "m6"]])
        left_out = merge_row("i2", {"m3": "other"}, 1, [])
        judged = MD.MergeAdjudication({("i1", "A", "m1"): "mergeable", ("i1", "A", "m5"): "mergeable",
                                       ("i1", "A", "m6"): "different_context", ("i2", "A", "m3"): "mergeable"})
        self.assertEqual(judged.numbers([scored, left_out], [scored], "A"),
                         {"absorbs": 5, "absorbs_mergeable": 3, "absorb_precision": 0.6,
                          "merges": 2, "merges_mergeable": 1, "judged_merge_recall": 0.5})

    def test_no_absorbs_is_full_precision_and_no_expected_merge_leaves_recall_unknown(self) -> None:
        empty = merge_row("i1", {}, 0, [])
        got = MD.NO_MERGES.numbers([empty], [empty], "A")
        self.assertEqual((got["absorb_precision"], got["judged_merge_recall"]), (1.0, None))


class FolderTest(unittest.TestCase):
    rows: list[MD.JsonObject] = [{"item": ITEM, "target": "A", "absorbs": {"m1": "complement", "m6": "duplicate",
                                                                           "m4": "stale"}},
                                 {"item": ITEM, "target": "base", "absorbs": {"m1": "complement"}}]

    def test_absorbs_need_the_judge_unless_all_are_planted_stale_facts(self) -> None:
        with self.assertRaisesRegex(SystemExit, "3 E-synth absorbs need the merge judge"):
            MD.for_run(self.rows, None, synth_render.TEMPLATE)
        stale_only: list[MD.JsonObject] = [{"item": ITEM, "target": "A", "absorbs": {"m4": "stale"}}]
        self.assertIs(MD.for_run(stale_only, None, synth_render.TEMPLATE), MD.NO_MERGES)

    def test_decisions_are_read_only_beside_the_cases_the_judge_was_given(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            A.write_cases(out, [{"case": "g001"}, {"case": "g002"}], KEYS, MC.judging(RULES))
            (out / D.JUDGE_DIR / D.DECISIONS).write_text("".join(json.dumps(d) + "\n" for d in DECISIONS),
                                                         encoding="utf-8")
            self.assertEqual((out / D.JUDGE_DIR / "judge.md").read_text(encoding="utf-8"), MC.judging(RULES))
            got = MD.for_run(self.rows, out, synth_render.TEMPLATE)
            self.assertEqual((len(got.judged), dict(got.judge_files)["judge.md"]),
                             (3, D.file_sha256(out / D.JUDGE_DIR / "judge.md")))
            (out / D.JUDGE_DIR / "cases.jsonl").write_text('{"case": "g001"}\n', encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "changed after the cases were written"):
                MD.for_run(self.rows, out, synth_render.TEMPLATE)


if __name__ == "__main__":
    unittest.main()
