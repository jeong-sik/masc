# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the gate arithmetic in scripts/tinker/librarian/eval_admission.py.

Rows and answers are invented. `eval_admission` imports the Tinker caller, which
imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import admission_validator as AV
import eval_admission as V

from tinker_librarian_fixtures import make_prompt

type Row = dict[str, object]


def row(target: str, item: str, *, valid: bool = True, agree: int = 0, candidates: int = 4,
        sent_at: float | None = 0.0, prompt_tokens: int = 1000, cached_tokens: int = 1000) -> Row:
    return {"target": target, "item": item, "valid": valid, "agree": agree, "candidates": candidates,
            "sent_at": sent_at, "prompt_tokens": prompt_tokens, "cached_tokens": cached_tokens}


def answer(judgments: tuple[tuple[str, AV.Outcome, str | None], ...], *, dropped: tuple[str, ...] = (),
           absorbed: tuple[tuple[str, str], ...] = (), added: tuple[str, ...] = (),
           revisions: tuple[tuple[str, str], ...] = ()) -> AV.AdmissionAnswer:
    return AV.AdmissionAnswer(
        judgments=tuple(AV.Judgment(rid, outcome, claim, "r") for rid, outcome, claim in judgments),
        change_support=(), deferred=False, added_claims=added, dropped=dropped, absorbed=absorbed,
        revisions=revisions, memory_after=())


def synth_row(**counts: int) -> Row:
    base: Row = {"target": "A", "status": 200, "wall_s": 1.0, "valid": True, "cost_usd": 0.0,
                 "prompt_tokens": 1, "cached_tokens": 1, "candidates": 2, "correct": 2, "removed": 0,
                 "dropped": 0, "absorbed": 0, "dropped_expected": 0, "planted": 1, "planted_dropped": 0}
    return {**base, **counts}


class PairedTest(unittest.TestCase):
    def test_lead_counts_only_items_both_answered_validly(self) -> None:
        rows = [row("base", "i1", agree=2), row("A", "i1", agree=3),
                row("base", "i2", valid=False), row("A", "i2", agree=4),
                row("base", "i3", agree=4), row("A", "i3", valid=False)]
        self.assertEqual(V.paired(rows, "base", "A"),
                         {"items": 1, "candidates": 4, "agreement": 0.75, "baseline_agreement": 0.5, "lead": 0.25})

    def test_no_shared_valid_item_leaves_the_lead_unknown(self) -> None:
        rows = [row("base", "i1", valid=False), row("A", "i1")]
        self.assertIsNone(V.paired(rows, "base", "A")["lead"])


class WindowTest(unittest.TestCase):
    def test_widest_gap_over_items(self) -> None:
        rows = [row("base", "i1", sent_at=100.0), row("A", "i1", sent_at=130.0),
                row("base", "i2", sent_at=500.0), row("A", "i2", sent_at=440.0)]
        self.assertEqual(V.widest_gap_s(rows, "base", "A"), 60.0)

    def test_a_missing_item_or_send_time_has_no_gap(self) -> None:
        self.assertIsNone(V.widest_gap_s([row("base", "i1"), row("base", "i2"), row("A", "i1")], "base", "A"))
        self.assertIsNone(V.widest_gap_s([row("base", "i1", sent_at=None), row("A", "i1")], "base", "A"))
        self.assertIsNone(V.widest_gap_s([row("base", "i1")], "base", "A"))


class WarmTest(unittest.TestCase):
    def test_warm_needs_nine_tenths_of_the_prompt_from_cache(self) -> None:
        self.assertTrue(V.warm(row("A", "i1", prompt_tokens=1000, cached_tokens=900)))
        self.assertFalse(V.warm(row("A", "i1", prompt_tokens=1000, cached_tokens=899)))
        self.assertFalse(V.warm(row("A", "i1", prompt_tokens=0, cached_tokens=0)))


class ChooseTest(unittest.TestCase):
    @staticmethod
    def result(a_pass: bool, b_pass: bool) -> dict[str, object]:
        return {"A": {"pass": a_pass}, "B": {"pass": b_pass}}

    @staticmethod
    def rows(a_agree: int, b_agree: int) -> list[Row]:
        return [row("A", "i1", agree=a_agree, candidates=100), row("B", "i1", agree=b_agree, candidates=100)]

    def test_a_wins_unless_b_leads_it_on_both_by_the_margin(self) -> None:
        synth: dict[str, dict[str, object]] = {"A": {"outcome_accuracy": 0.95}, "B": {"outcome_accuracy": 0.98}}
        self.assertEqual(V.choose(["A", "B"], self.result(True, True), synth, self.rows(80, 83), 0.03), "B")
        self.assertEqual(V.choose(["A", "B"], self.result(True, True), synth, self.rows(80, 82), 0.03), "A")
        synth["B"] = {"outcome_accuracy": 0.97}
        self.assertEqual(V.choose(["A", "B"], self.result(True, True), synth, self.rows(80, 90), 0.03), "A")

    def test_the_two_are_compared_on_items_both_answered_validly(self) -> None:
        # B's lead over the baseline could come from i2, which A did not answer validly.
        synth: dict[str, dict[str, object]] = {"A": {"outcome_accuracy": 0.95}, "B": {"outcome_accuracy": 0.99}}
        rows = [row("A", "i1", agree=50, candidates=100), row("B", "i1", agree=50, candidates=100),
                row("A", "i2", valid=False, candidates=100), row("B", "i2", agree=100, candidates=100)]
        self.assertEqual(V.choose(["A", "B"], self.result(True, True), synth, rows, 0.03), "A")

    def test_only_passing_candidates_are_chosen(self) -> None:
        synth: dict[str, dict[str, object]] = {"A": {"outcome_accuracy": 0.99}, "B": {"outcome_accuracy": 0.95}}
        self.assertEqual(V.choose(["A", "B"], self.result(False, True), synth, self.rows(0, 0), 0.03), "B")
        self.assertIsNone(V.choose(["A", "B"], self.result(False, False), synth, self.rows(0, 0), 0.03))


class BindingTest(unittest.TestCase):
    BASE = "base-model"
    PIN = "p" * 64

    def problem(self, real: dict[str, str], synth: dict[str, str], trained: dict[str, dict[str, object]]) -> str | None:
        return V.binding_problem(real, synth, "base", self.BASE, ["A"], trained, self.PIN)

    def test_a_candidate_is_the_checkpoint_its_training_run_saved(self) -> None:
        targets = {"base": self.BASE, "A": "tinker://run-a/sampler"}
        saved: dict[str, object] = {"branch": "A", "pass_lines_sha256": self.PIN, "sampler_path": "tinker://run-a/sampler"}
        self.assertIsNone(self.problem(targets, dict(targets), {"A": saved}))
        self.assertIsNotNone(self.problem(targets, dict(targets), {"A": {**saved, "sampler_path": "tinker://other"}}))
        self.assertIsNotNone(self.problem(targets, dict(targets), {"A": {**saved, "pass_lines_sha256": "q" * 64}}))
        self.assertIsNotNone(self.problem(targets, dict(targets), {}))

    def test_both_runs_send_the_same_model_under_each_name(self) -> None:
        real = {"base": self.BASE, "A": "tinker://run-a/sampler"}
        saved: dict[str, object] = {"branch": "A", "pass_lines_sha256": self.PIN, "sampler_path": "tinker://run-a/sampler"}
        self.assertIsNotNone(self.problem(real, {**real, "A": "tinker://run-b/sampler"}, {"A": saved}))
        self.assertIsNotNone(self.problem({**real, "base": "other"}, {**real, "base": "other"}, {"A": saved}))


class ScoreTest(unittest.TestCase):
    def test_real_counts_absorbs_as_live_removals(self) -> None:
        live = answer((("r1", "incorporated", "c"),), dropped=("m1",), absorbed=(("m2", "c"),))
        item = V.RealItem("i1", make_prompt(), "", live)
        mine = answer((("r1", "incorporated", "c"),), dropped=("m2", "m3"), absorbed=(("m4", "c"),))
        score = V.score_real(item, mine)
        self.assertEqual((score["agree"], score["dropped_not_in_live"], score["absorbed_not_in_live"]),
                         (1, ["m3"], ["m4"]))

    def test_synth_correction_needs_the_revision_and_the_drop(self) -> None:
        label: dict[str, object] = {"candidates": [{"request_id": "r1", "outcome": "incorporated", "supersedes": "m1"},
                                                   {"request_id": "r2", "outcome": "not_durable"}],
                                    "planted_stale": ["m5"]}
        item = V.SynthItem("i1", make_prompt(), "", label)
        both = answer((("r1", "incorporated", "new"), ("r2", "not_durable", None)),
                      dropped=("m1", "m5", "m6"), revisions=(("m1", "new"),))
        score = V.score_synth(item, both)
        self.assertEqual((score["correct"], score["dropped"], score["dropped_expected"], score["planted_dropped"]),
                         (2, 3, 2, 1))
        no_drop = answer((("r1", "incorporated", "new"), ("r2", "not_durable", None)), revisions=(("m1", "new"),))
        self.assertEqual(V.score_synth(item, no_drop)["correct"], 1)
        self.assertEqual(V.score_synth(item, None)["correct"], 0)

    def test_synth_new_fact_and_paraphrase_need_the_claim_their_kind_names(self) -> None:
        label: dict[str, object] = {"candidates": [
            {"request_id": "r1", "outcome": "incorporated", "supersedes": None, "already_claim": None},
            {"request_id": "r2", "outcome": "already_represented", "supersedes": None, "already_claim": "old"}],
            "planted_stale": []}
        item = V.SynthItem("i1", make_prompt(), "", label)
        right = answer((("r1", "incorporated", "new"), ("r2", "already_represented", "old")), added=("new",))
        # MASC accepts both: every named claim is in final memory.
        wrong = answer((("r1", "incorporated", "old"), ("r2", "already_represented", "new")), added=("new",))
        self.assertEqual(V.score_synth(item, right)["correct"], 2)
        self.assertEqual(V.score_synth(item, wrong)["correct"], 0)

    def test_synth_absorbs_are_removals_and_never_drops(self) -> None:
        label: dict[str, object] = {"candidates": [
            {"request_id": "r1", "outcome": "incorporated", "supersedes": None, "already_claim": None}],
            "planted_stale": ["m5"]}
        item = V.SynthItem("i1", make_prompt(), "", label)
        mine = answer((("r1", "incorporated", "new"),), added=("new",), absorbed=(("m5", "new"), ("m6", "new")))
        score = V.score_synth(item, mine)
        self.assertEqual((score["correct"], score["removed"], score["absorbed"], score["dropped_expected"],
                          score["planted_dropped"]), (1, 2, 2, 0, 0))

    def test_synth_precision_counts_absorbed_ids_against_it(self) -> None:
        part = V.summarize("synth", [synth_row(removed=4, dropped=2, absorbed=2, dropped_expected=2,
                                               planted=2, planted_dropped=2)])["A"]
        assert isinstance(part, dict)
        self.assertEqual((part["drop_precision"], part["absorbed"], part["stale_drop_recall"]), (0.5, 2, 1.0))

    def test_synth_without_removals_has_full_precision(self) -> None:
        part = V.summarize("synth", [synth_row()])["A"]
        assert isinstance(part, dict)
        self.assertEqual((part["drop_precision"], part["stale_drop_recall"]), (1.0, 0.0))


if __name__ == "__main__":
    unittest.main()
