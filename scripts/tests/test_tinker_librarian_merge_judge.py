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

import dataclasses
import json
import random
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import admission_template as AT
import admission_validator as AV
import audit_decisions as D
import e_synth_audit as A
import memory_scores as M
import merge_cases as MC
import merge_decisions as MD
import synth_render
import synth_spec as S
import yojson_wire as W
from tinker_librarian_synth_fixtures import (
    PLANTED,
    accepted,
    answer_text,
    candidate,
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
SLOTS = MC.guidance(RULES)
ITEM = request(PLANTED, ()).item_id


def item_of(req: S.SynthRequest) -> M.SynthItem:
    return M.SynthItem(req.item_id, prompt_of(req), "", S.label_of(req))


def complement_and_new() -> S.SynthRequest:
    return request(PLANTED, candidates_of((K.COMPLEMENT, K.NEW_DURABLE)))


def absorbing_m2(claim_chars: int) -> tuple[M.SynthItem, AV.AdmissionAnswer, str]:
    """One new candidate whose claim is `claim_chars` Hangul syllables (3 bytes each), and an answer
    whose claim joins it with m2 and absorbs m2."""
    req = request(PLANTED, (dataclasses.replace(candidate(1, K.NEW_DURABLE, None), claim="가" * claim_chars),))
    [k1] = req.candidates
    into = k1.claim + " " + BY_ID["m2"].claim
    answer = answer_text(((k1.request_id, "incorporated", into),), claims=(claim_json(into, absorbs=("m2",)),))
    return item_of(req), accepted(req, answer), into


class CaseTest(unittest.TestCase):
    def test_a_case_is_what_the_gate_reads_for_one_absorbed_memory(self) -> None:
        # The label's answer absorbs m1 into the complement's claim and m6 into m5's claim, and drops m4.
        req = complement_and_new()
        item = item_of(req)
        k1, _ = req.candidates
        c1, _ = item.prompt.candidates
        got = MC.states(item, accepted(req, label_answer(req)), SLOTS)
        self.assertEqual(got, [
            ("m1", MC.State(BY_ID["m1"].claim, merged(BY_ID["m1"], k1), (c1,))),
            ("m6", MC.State(BY_ID["m6"].claim, BY_ID["m5"].claim, ()))])

    def test_an_observation_is_the_candidate_as_the_gate_reads_it(self) -> None:
        c1, _ = item_of(complement_and_new()).prompt.candidates
        fact = c1.proposed_fact
        [case], _ = MC.render({MC.State("source", "claim", (c1,)): [(ITEM, "A", "m1")]}, "20261109:merges")
        self.assertEqual(list(case), ["case", "source_memory", "proposed_memory", "new_observations"])
        [shown] = cast(list[dict[str, object]], case["new_observations"])
        self.assertEqual(shown, {
            "observation_kind": "pending_explicit_memory_candidate", "request_id": c1.request_id,
            "sequence": c1.sequence,
            "proposal": {"claim": fact.claim, "category": "doc_links", "first_seen": fact.first_seen,
                         "last_seen": fact.last_seen, "origin": {"kind": "authored", "trace_id": fact.origin.trace_id},
                         "basis": {"kind": "observed"}}})
        self.assertEqual(list(shown), ["observation_kind", "request_id", "sequence", "proposal"])
        self.assertEqual(list(cast(dict[str, object], shown["proposal"])),
                         ["claim", "category", "first_seen", "last_seen", "origin", "basis"])

    def test_a_claim_cites_only_supporting_candidates_whose_judgment_names_it(self) -> None:
        req = request(PLANTED, candidates_of((K.NEW_DURABLE, K.NEW_DURABLE)))
        k1, k2 = req.candidates
        c1, _ = item_of(req).prompt.candidates
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
            [(mid, state)] = MC.states(item_of(req), accepted(req, answer), SLOTS)
            self.assertEqual((mid, state.observations), ("m2", (c1,)))

    def test_observations_that_would_pass_the_gates_request_limit_are_left_out(self) -> None:
        # 15,000 bytes in the claim and as much in its candidate: the pair fits, the pair with the candidate not.
        item, answer, into = absorbing_m2(5000)
        self.assertEqual(MC.states(item, answer, SLOTS), [("m2", MC.State(BY_ID["m2"].claim, into, ()))])

    def test_an_absorb_the_gate_would_not_ask_about_stops_the_cases(self) -> None:
        # A claim of 16,500 bytes passes the state limit.
        item, answer, _ = absorbing_m2(5500)
        with self.assertRaisesRegex(SystemExit, "would not ask about m2"):
            MC.states(item, answer, SLOTS)
        # A short claim with a memory of 31,500 bytes: the pair alone passes the request limit.
        long_m2 = dataclasses.replace(BY_ID["m2"], claim="나" * 10_500)
        req = request(tuple(long_m2 if f.memory_id == "m2" else f for f in PLANTED), candidates_of((K.NEW_DURABLE,)))
        [k1] = req.candidates
        answer_ = answer_text(((k1.request_id, "incorporated", k1.claim),), claims=(claim_json(k1.claim, absorbs=("m2",)),))
        with self.assertRaisesRegex(SystemExit, "would not ask about m2"):
            MC.states(item_of(req), accepted(req, answer_), SLOTS)

    def test_an_absorbed_planted_stale_fact_gets_no_case(self) -> None:
        req = request(PLANTED, candidates_of((K.NEW_DURABLE,)))
        [k1] = req.candidates
        claim = k1.claim + " " + BY_ID["m4"].claim
        answer = answer_text(((k1.request_id, "incorporated", claim),), claims=(claim_json(claim, absorbs=("m4",)),))
        self.assertEqual(MC.states(item_of(req), accepted(req, answer), SLOTS), [])

    def test_answers_that_make_one_state_share_a_case_that_shows_no_target_item_or_memory_id(self) -> None:
        req = complement_and_new()
        answer = accepted(req, label_answer(req))
        collected = MC.collect({req.item_id: item_of(req)}, {("base", req.item_id): answer, ("A", req.item_id): answer},
                               SLOTS)
        case_rows, key_rows = MC.render(collected, "20261109:merges")
        self.assertEqual(sorted(sorted(map(tuple, cast(list[list[str]], k["absorbs"]))) for k in key_rows),
                         [[(ITEM, "A", "m1"), (ITEM, "base", "m1")], [(ITEM, "A", "m6"), (ITEM, "base", "m6")]])
        # The complement's claim cites k1; the pair's claim cites nothing, so its case has no observations.
        self.assertEqual(sorted(sorted(c) for c in case_rows),
                         [["case", "new_observations", "proposed_memory", "source_memory"],
                          ["case", "proposed_memory", "source_memory"]])
        # A cited candidate keeps its request ID, as the gate shows it; the ID is random and names nothing else.
        shown = json.dumps(case_rows, ensure_ascii=False)
        for hidden in (ITEM, "base", "A", *BY_ID):
            self.assertNotIn(f'"{hidden}"', shown)

    def test_the_cases_come_in_the_order_the_seed_draws(self) -> None:
        states = {MC.State(f"source {n}", f"claim {n}", ()): [(ITEM, "A", f"m{n}")] for n in range(1, 7)}
        drawn = list(states)
        random.Random("20261109:merges").shuffle(drawn)
        first, _ = MC.render(states, "20261109:merges")
        self.assertEqual([c["source_memory"] for c in first], [s.source for s in drawn])
        other, _ = MC.render(states, "20261110:merges")
        self.assertNotEqual([c["source_memory"] for c in other], [c["source_memory"] for c in first])


def call_row(key: str, sent_at: float, content: str | None, status: int = 200) -> dict[str, object]:
    return {"key": key, "label": f"synth:A:{ITEM}", "status": status, "finish": "stop", "content": content,
            "reasoning": None, "prompt_tokens": 1, "cached_tokens": 1, "completion_tokens": 1, "wall_s": 1.0,
            "sent_at": sent_at}


class AnswersTest(unittest.TestCase):
    def test_a_valid_row_takes_the_call_it_names(self) -> None:
        req = complement_and_new()
        k1, k2 = req.candidates
        text = label_answer(req)
        other = answer_text(((k1.request_id, "not_durable", None), (k2.request_id, "not_durable", None)))
        items = {ITEM: item_of(req)}
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            # The same label holds a failed attempt and an answer from another model sent later.
            calls = [call_row("k1", 1.0, None, 500), call_row("k1", 2.0, text), call_row("k2", 3.0, other)]
            (run / "calls.jsonl").write_text("".join(json.dumps(c) + "\n" for c in calls), encoding="utf-8")
            for named, want in ((("k1", 2.0), text), (("k2", 3.0), other)):
                row = {"item": ITEM, "target": "A", "valid": True, "call_key": named[0], "sent_at": named[1]}
                (run / "rows.jsonl").write_text(json.dumps(row) + "\n", encoding="utf-8")
                self.assertEqual(MC.answers_of(run, items), {("A", ITEM): accepted(req, want)})
            for named in (("k1", 1.0), ("k1", 3.0)):
                row = {"item": ITEM, "target": "A", "valid": True, "call_key": named[0], "sent_at": named[1]}
                (run / "rows.jsonl").write_text(json.dumps(row) + "\n", encoding="utf-8")
                with self.assertRaisesRegex(SystemExit, "holds no valid answer"):
                    MC.answers_of(run, items)


class JudgingTest(unittest.TestCase):
    def test_the_judge_reads_the_gates_question_in_the_rules_words(self) -> None:
        slots = AT.slots_of(RULES)
        text = MC.judging(SLOTS)
        forward = slots["absorb_forward"]
        self.assertIn(f"new_observations 가 없는 case:\n\n{forward} {slots['absorb_pair']}\n\n", text)
        self.assertIn(f"new_observations 가 있는 case:\n\n{forward} {slots['absorb_observations']}\n\n", text)
        for c in MD.CONSOLIDATIONS:
            self.assertIn(f'- "{c}": {slots[f"absorb_{c}"]}\n', text)

    def test_the_question_is_measured_as_the_gate_writes_it(self) -> None:
        slots = AT.slots_of(RULES)
        for observed, context in ((True, "absorb_observations"), (False, "absorb_pair")):
            written = json.loads(W.write(MC.question_json(SLOTS, observed)))
            self.assertEqual(list(written), ["type", "instructions", "criteria"])
            self.assertEqual((written["type"], written["instructions"]),
                             ("choice", f"{slots['absorb_forward']} {slots[context]}"))
            self.assertEqual(list(written["criteria"].items()),
                             [(c, slots[f"absorb_{c}"]) for c in MD.CONSOLIDATIONS])

    def test_rules_without_one_of_the_gates_slots_stop_the_cases(self) -> None:
        cut = RULES.replace("### absorb_uncertain", "### absorb_unsure")
        with self.assertRaisesRegex(SystemExit, "absorb_uncertain"):
            MC.guidance(cut)


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

    def test_a_missing_extra_or_unknown_decision_is_refused(self) -> None:
        with self.assertRaisesRegex(SystemExit, "decisions cover 1 cases"):
            MD.adjudicate(KEYS, DECISIONS[:1], ABSORBS)
        with self.assertRaisesRegex(SystemExit, "decisions cover 3 cases"):
            MD.adjudicate(KEYS, [*DECISIONS, {"case": "g003", "decision": "mergeable"}], ABSORBS)
        for written in ("Mergeable", "merge", None):
            with self.assertRaisesRegex(SystemExit, "no class of the absorb gate"):
                MD.adjudicate(KEYS, [DECISIONS[0], {"case": "g002", "decision": written}], ABSORBS)
        with self.assertRaisesRegex(SystemExit, "more than once"):
            MD.adjudicate(KEYS, [*DECISIONS, DECISIONS[1]], ABSORBS)


def merge_row(item: str, absorbs: dict[str, str], merges: int, made: list[list[str]],
              target: str = "A") -> MD.JsonObject:
    return {"item": item, "target": target, "absorbs": absorbs, "merges": merges, "merges_absorbed": made}


class NumbersTest(unittest.TestCase):
    def test_precision_counts_every_absorb_and_recall_needs_every_absorb_of_a_merge_mergeable(self) -> None:
        scored = merge_row("i1", {"m1": "complement", "m4": "stale", "m5": "duplicate", "m6": "duplicate"}, 2,
                           [["m1"], ["m5", "m6"]])
        # A row left out of scoring counts toward precision and not toward recall.
        left_out = merge_row("i2", {"m3": "complement"}, 1, [["m3"]])
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
    rows: list[MD.JsonObject] = [merge_row(ITEM, {"m1": "complement", "m6": "duplicate", "m4": "stale"}, 2,
                                           [["m1"], ["m6"]]),
                                 merge_row(ITEM, {"m1": "complement"}, 2, [["m1"]], target="base")]

    def folder(self, tmp: str) -> tuple[Path, Path]:
        """A run whose files hold `rows`, and merge cases made from it with the judge's decisions."""
        run, out = Path(tmp) / "run", Path(tmp) / "merges"
        run.mkdir()
        (run / "calls.jsonl").write_text("{}\n", encoding="utf-8")
        (run / "rows.jsonl").write_text("".join(json.dumps(r) + "\n" for r in self.rows), encoding="utf-8")
        A.write_cases(out, [{"case": "g001"}, {"case": "g002"}], KEYS, MC.judging(SLOTS))
        MD.record_run_files(out, run)
        (out / D.JUDGE_DIR / D.DECISIONS).write_text("".join(json.dumps(d) + "\n" for d in DECISIONS),
                                                     encoding="utf-8")
        return run, out

    def test_absorbs_need_the_judge_unless_all_are_planted_stale_facts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            with self.assertRaisesRegex(SystemExit, "3 E-synth absorbs need the merge judge"):
                MD.for_run(self.rows, None, synth_render.TEMPLATE, run)
            stale_only = [merge_row(ITEM, {"m4": "stale"}, 0, [])]
            self.assertIs(MD.for_run(stale_only, None, synth_render.TEMPLATE, run), MD.NO_MERGES)

    def test_decisions_are_read_only_beside_the_cases_the_judge_was_given(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run, out = self.folder(tmp)
            self.assertEqual((out / D.JUDGE_DIR / "judge.md").read_text(encoding="utf-8"), MC.judging(SLOTS))
            got = MD.for_run(self.rows, out, synth_render.TEMPLATE, run)
            self.assertEqual((len(got.judged), dict(got.judge_files)["judge.md"]),
                             (3, D.file_sha256(out / D.JUDGE_DIR / "judge.md")))
            (out / D.JUDGE_DIR / "cases.jsonl").write_text('{"case": "g001"}\n', encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "changed after the cases were written"):
                MD.for_run(self.rows, out, synth_render.TEMPLATE, run)

    def test_decisions_are_read_only_for_the_run_files_the_cases_came_from(self) -> None:
        for name in ("calls.jsonl", "rows.jsonl"):
            with tempfile.TemporaryDirectory() as tmp:
                run, out = self.folder(tmp)
                with (run / name).open("a", encoding="utf-8") as fh:
                    fh.write("{}\n")
                with self.assertRaisesRegex(SystemExit, "other run files"):
                    MD.for_run(self.rows, out, synth_render.TEMPLATE, run)

    def test_the_report_gives_precision_over_every_row_and_recall_over_the_scored(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run, out = self.folder(tmp)
            # Only base's row is scored: A's precision still counts its row, and A has no recall.
            got = MD.report(self.rows, self.rows[1:], out, synth_render.TEMPLATE, run, ["base", "A"])
        self.assertEqual(got["by_target"], {
            "base": {"absorbs": 1, "absorbs_mergeable": 1, "absorb_precision": 1.0,
                     "merges": 2, "merges_mergeable": 1, "judged_merge_recall": 0.5},
            "A": {"absorbs": 3, "absorbs_mergeable": 1, "absorb_precision": 1 / 3,
                  "merges": 0, "merges_mergeable": 0, "judged_merge_recall": None}})
        self.assertEqual(len(cast(list[object], got["absorbs"])), 3)


if __name__ == "__main__":
    unittest.main()
