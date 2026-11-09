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

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import admission_validator as AV
import eval_admission as V
import memory_scores as M
import synth_rows as RW
import synth_spec as S

from tinker_librarian_fixtures import make_prompt
from tinker_librarian_synth_fixtures import PLANTED, candidates_of, request

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


def synth_row(**counts: object) -> Row:
    base: Row = {"target": "A", "status": 200, "wall_s": 1.0, "valid": True, "cost_usd": 0.0,
                 "prompt_tokens": 1, "cached_tokens": 1, "candidates": 2, "correct": 2,
                 "dropped": 0, "absorbed": 0, "dropped_expected": 0, "planted": 1, "planted_dropped": 0,
                 "state_correct": 2, "state_by_kind": {"new": [2, 2]}, "dropped_unmerged": [],
                 "planted_absorbed": 0, "merges": 0, "merges_done": 0, "added": 0, "removed": 0,
                 "expected_added": 0, "expected_removed": 0}
    return {**base, **counts}


def real_row(**counts: object) -> Row:
    base: Row = {"target": "A", "status": 200, "wall_s": 1.0, "valid": True, "cost_usd": 0.0,
                 "prompt_tokens": 1, "cached_tokens": 1, "candidates": 2, "agree": 2,
                 "dropped_not_in_live": [], "absorbed_not_in_live": [], "added": 0, "removed": 0,
                 "live_added": 0, "live_removed": 0}
    return {**base, **counts}


def part_of(summary: dict[str, object]) -> dict[str, object]:
    part = summary["A"]
    assert isinstance(part, dict)
    return cast(dict[str, object], part)


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

    def test_a_target_the_pass_lines_do_not_name_is_refused(self) -> None:
        targets = {"base": self.BASE, "A": "tinker://run-a/sampler", "C": "tinker://run-c/sampler"}
        saved: dict[str, object] = {"branch": "A", "pass_lines_sha256": self.PIN, "sampler_path": "tinker://run-a/sampler"}
        self.assertIsNotNone(self.problem(targets, dict(targets), {"A": saved}))

    def test_both_runs_send_the_same_model_under_each_name(self) -> None:
        real = {"base": self.BASE, "A": "tinker://run-a/sampler"}
        saved: dict[str, object] = {"branch": "A", "pass_lines_sha256": self.PIN, "sampler_path": "tinker://run-a/sampler"}
        self.assertIsNotNone(self.problem(real, {**real, "A": "tinker://run-b/sampler"}, {"A": saved}))
        self.assertIsNotNone(self.problem({**real, "base": "other"}, {**real, "base": "other"}, {"A": saved}))


class ScoreTest(unittest.TestCase):
    def test_real_counts_absorbs_as_live_removals(self) -> None:
        live = answer((("r1", "incorporated", "c"),), dropped=("m1",), absorbed=(("m2", "c"),), added=("c",))
        item = M.RealItem("i1", make_prompt(), "", live)
        mine = answer((("r1", "incorporated", "c"),), dropped=("m2", "m3"), absorbed=(("m4", "c"),), added=("c", "d"))
        score = M.score_real(item, mine)
        self.assertEqual((score["agree"], score["dropped_not_in_live"], score["absorbed_not_in_live"]),
                         (1, ["m3"], ["m4"]))
        self.assertEqual((score["live_added"], score["live_removed"], score["added"], score["removed"]), (1, 2, 2, 3))
        self.assertEqual(M.score_real(item, None)["outcomes"], {"r1": ["incorporated", None]})

    def test_real_growth_per_item_of_each_answer(self) -> None:
        rows = [real_row(added=3, removed=1, live_added=2, live_removed=1), real_row(live_added=2)]
        part = part_of(V.summarize("real", rows))
        self.assertEqual((part["net_per_item"], part["live_net_per_item"]), (1.0, 1.5))

    def test_synth_drops_split_into_asked_and_off_label(self) -> None:
        label = S.RequestLabel((S.CandidateLabel("r1", "incorporated", "m1", None, None),
                                S.CandidateLabel("r2", "not_durable", None, None, None)), frozenset({"m5"}), ())
        item = M.SynthItem("i1", make_prompt(), "", label)
        both = answer((("r1", "incorporated", "new"), ("r2", "not_durable", None)),
                      dropped=("m1", "m5", "m6"), revisions=(("m1", "new"),))
        score = M.score_synth(item, both)
        self.assertEqual((score["correct"], score["dropped"], score["dropped_expected"], score["planted_dropped"],
                          score["dropped_off_label"]), (2, 3, 2, 1, ["m6"]))
        self.assertEqual(M.score_synth(item, None)["correct"], 0)

    def test_synth_new_fact_and_paraphrase_need_the_claim_their_kind_names(self) -> None:
        label = S.RequestLabel((S.CandidateLabel("r1", "incorporated", None, None, None),
                                S.CandidateLabel("r2", "already_represented", None, None, "old")), frozenset(), ())
        item = M.SynthItem("i1", make_prompt(), "", label)
        right = answer((("r1", "incorporated", "new"), ("r2", "already_represented", "old")), added=("new",))
        # MASC accepts both: every named claim is in final memory.
        wrong = answer((("r1", "incorporated", "old"), ("r2", "already_represented", "new")), added=("new",))
        self.assertEqual(M.score_synth(item, right)["correct"], 2)
        self.assertEqual(M.score_synth(item, wrong)["correct"], 0)

    def test_synth_absorbs_are_counted_apart_and_never_drops(self) -> None:
        label = S.RequestLabel((S.CandidateLabel("r1", "incorporated", None, None, None),), frozenset({"m5"}), ())
        item = M.SynthItem("i1", make_prompt(), "", label)
        mine = answer((("r1", "incorporated", "new"),), added=("new",), absorbed=(("m5", "new"), ("m6", "new")))
        score = M.score_synth(item, mine)
        self.assertEqual((score["correct"], score["dropped"], score["absorbed"], score["dropped_expected"],
                          score["planted_dropped"], score["planted_absorbed"], score["absorbs"]),
                         (1, 0, 2, 0, 0, 1, {"m5": "stale", "m6": "other"}))

    def test_synth_precision_counts_drops_and_reports_absorbs(self) -> None:
        part = V.summarize("synth", [synth_row(dropped=2, absorbed=3, dropped_expected=1,
                                               planted=2, planted_dropped=1)])["A"]
        assert isinstance(part, dict)
        self.assertEqual((part["drop_precision"], part["absorbed"], part["stale_drop_recall"]), (0.5, 3, 0.5))

    def test_wrong_drops_outside_the_scored_rows_still_lower_precision(self) -> None:
        rows = [synth_row(dropped=2, dropped_expected=2)]
        for wrong, precision in (({}, 1.0), ({"A": 1}, 2 / 3), ({"B": 1}, 1.0)):
            with self.subTest(wrong=wrong):
                part = V.summarize("synth", rows, wrong)["A"]
                assert isinstance(part, dict)
                self.assertEqual(part["drop_precision"], precision)

    def test_synth_without_drops_has_full_precision(self) -> None:
        part = V.summarize("synth", [synth_row()])["A"]
        assert isinstance(part, dict)
        self.assertEqual((part["drop_precision"], part["stale_drop_recall"]), (1.0, 0.0))

    def test_synth_memory_counts_sum_over_rows(self) -> None:
        rows = [synth_row(candidates=4, correct=1, state_correct=3, state_by_kind={"new": [3, 2], "restates": [1, 1]},
                          dropped=3, dropped_expected=1, dropped_unmerged=["m1", "m2"], planted_absorbed=1,
                          merges=2, merges_done=1, added=3, removed=1, expected_added=2, expected_removed=1),
                synth_row(candidates=4, correct=4, state_correct=4, state_by_kind={"new": [1, 1], "transient": [3, 3]})]
        part = part_of(V.summarize("synth", rows))
        self.assertEqual((part["outcome_accuracy"], part["memory_state_accuracy"], part["drop_precision"]),
                         (5 / 8, 7 / 8, 1 / 3))
        self.assertEqual(part["state_by_kind"], {"new": {"candidates": 4, "accuracy": 0.75},
                                                 "restates": {"candidates": 1, "accuracy": 1.0},
                                                 "transient": {"candidates": 3, "accuracy": 1.0}})
        self.assertEqual((part["dropped_unmerged"], part["planted_absorbed"], part["merge_recall"]), (2, 1, 0.5))
        self.assertEqual((part["net_per_item"], part["expected_net_per_item"]), (1.0, 0.5))
        self.assertIsNone(part_of(V.summarize("synth", [synth_row()]))["merge_recall"])


class SynthItemsTest(unittest.TestCase):
    def test_a_request_no_generator_writes_stops_the_run(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.CORRECTION, S.CandidateKind.TRANSIENT)))
        written = RW.row_of(req)
        earlier = copy.deepcopy(written)
        del cast(list[dict[str, object]], earlier["facts"])[0]["duplicate_of"]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "requests.jsonl"
            path.write_text(json.dumps({"request": written}, ensure_ascii=False) + "\n", encoding="utf-8")
            [item] = V.synth_items(path)
            self.assertEqual((item.item_id, item.label), (req.item_id, S.label_of(req)))
            path.write_text("".join(json.dumps({"request": r}, ensure_ascii=False) + "\n" for r in (written, earlier)),
                            encoding="utf-8")
            with self.assertRaises(SystemExit) as stop:
                V.synth_items(path)
            self.assertEqual(str(stop.exception), f"{path}:2: the request is not one synth_generate.py writes")


if __name__ == "__main__":
    unittest.main()
