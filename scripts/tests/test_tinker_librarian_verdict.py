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
import math
import sys
import tempfile
import unittest
from dataclasses import astuple
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import admission_request as R
import admission_validator as AV
import eval_admission as V
import memory_scores as M
import synth_render
import synth_rows as RW
import synth_spec as S

from tinker_librarian_fixtures import make_prompt, make_template
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


GATES: dict[str, object] = {
    "G1_e_real_valid_rate_min": 0.95, "G2_e_real_dropped_not_in_live_max": 2,
    "G3_e_synth_memory_state_accuracy_min": 0.97, "G3_e_synth_drop_precision_min": 1.0,
    "G3_e_synth_stale_drop_recall_min": 0.9, "G4_e_real_paired_lead_min": -0.06,
    "G5_e_real_latency_p50_ratio_max": 1.16, "G6_e_synth_absorb_precision_min": 0.8,
    "G6_e_synth_judged_merge_recall_min": 0.7}


class GatesTest(unittest.TestCase):
    def test_each_gate_reads_its_own_key(self) -> None:
        # GATES lists its keys in the order of the Gates fields; distinct numbers show a swapped key.
        raw: dict[str, object] = {key: (i + 1) / 100 for i, key in enumerate(GATES)}
        self.assertEqual(astuple(V.gates_of(raw)), tuple((i + 1) / 100 for i in range(len(GATES))))

    def test_a_gate_without_a_finite_number_stops_the_verdict(self) -> None:
        unset = {k: v for k, v in GATES.items() if k != "G6_e_synth_judged_merge_recall_min"}
        for raw in (unset, {**GATES, "G6_e_synth_absorb_precision_min": None},
                    {**GATES, "G1_e_real_valid_rate_min": True}, {**GATES, "G1_e_real_valid_rate_min": "0.95"},
                    {**GATES, "G6_e_synth_absorb_precision_min": -math.inf},
                    {**GATES, "G5_e_real_latency_p50_ratio_max": math.inf},
                    {**GATES, "G3_e_synth_stale_drop_recall_min": math.nan}):
            with self.subTest(raw=raw), self.assertRaises(SystemExit):
                V.gates_of(raw)

    def test_a_gate_the_verdict_does_not_read_stops_it(self) -> None:
        with self.assertRaises(SystemExit):
            V.gates_of({**GATES, "G3_e_synth_outcome_accuracy_min": 0.95})


class ChoiceTest(unittest.TestCase):
    def test_the_order_is_read_alone(self) -> None:
        self.assertEqual(V.choice_of({"order": ["A"]}), ["A"])
        refused: tuple[dict[str, object], ...] = (
            {"order": ["A"], "prefer_later_when_ahead_by": 0.03}, {"order": []}, {"order": "A"}, {"order": [1]}, {})
        for raw in refused:
            with self.subTest(raw=raw), self.assertRaises(SystemExit):
                V.choice_of(raw)

    def test_training_needs_every_gate_and_its_candidate_in_the_order(self) -> None:
        lines: dict[str, object] = {"gates": GATES, "choice": {"order": ["A"]}}
        self.assertEqual(V.ready_to_train(lines, "A"), V.gates_of(GATES))
        unset = {k: v for k, v in GATES.items() if not k.startswith("G6")}
        for bad, candidate in (({**lines, "gates": unset}, "A"), (lines, "B")):
            with self.subTest(candidate=candidate), self.assertRaises(SystemExit):
                V.ready_to_train(bad, candidate)


class GateChecksTest(unittest.TestCase):
    # Every number sits on its line in GATES; the outcome words are far below any line.
    REAL: dict[str, object] = {"valid_rate": 0.95, "dropped_not_in_live": 2, "latency_p50_s": 10.0 * 1.16}
    BASELINE: dict[str, object] = {"latency_p50_s": 10.0}
    SYNTH: dict[str, object] = {"memory_state_accuracy": 0.97, "outcome_accuracy": 0.5, "drop_precision": 1.0,
                                "stale_drop_recall": 0.9}
    MERGES: dict[str, object] = {"absorb_precision": 0.8, "judged_merge_recall": 0.7}
    PAIR: dict[str, object] = {"lead": -0.06}

    def failed(self, synth: dict[str, object] | None = None, merges: dict[str, object] | None = None,
               real: dict[str, object] | None = None, pair: dict[str, object] | None = None,
               baseline: dict[str, object] | None = None) -> set[str]:
        checks = V.gate_checks(V.gates_of(GATES), real or self.REAL, synth or self.SYNTH, merges or self.MERGES,
                               pair or self.PAIR, baseline or self.BASELINE)
        return {k for k, v in checks.items() if not v}

    def test_a_candidate_on_every_line_passes(self) -> None:
        checks = V.gate_checks(V.gates_of(GATES), self.REAL, self.SYNTH, self.MERGES, self.PAIR, self.BASELINE)
        self.assertEqual(checks, dict.fromkeys(("G1", "G2", "G3", "G4", "G5", "G6"), True))

    def test_each_e_real_gate_fails_just_past_its_line(self) -> None:
        cases: tuple[tuple[str, dict[str, object], dict[str, object], dict[str, object]], ...] = (
            ("G1", {**self.REAL, "valid_rate": 0.94}, self.PAIR, self.BASELINE),
            ("G2", {**self.REAL, "dropped_not_in_live": 3}, self.PAIR, self.BASELINE),
            ("G4", self.REAL, {"lead": -0.07}, self.BASELINE), ("G4", self.REAL, {"lead": None}, self.BASELINE),
            ("G5", {**self.REAL, "latency_p50_s": 11.7}, self.PAIR, self.BASELINE),
            ("G5", {**self.REAL, "latency_p50_s": None}, self.PAIR, self.BASELINE),
            ("G5", self.REAL, self.PAIR, {"latency_p50_s": None}))
        for gate, real, pair, baseline in cases:
            with self.subTest(gate=gate, real=real, pair=pair, baseline=baseline):
                self.assertEqual(self.failed(real=real, pair=pair, baseline=baseline), {gate})

    def test_g3_reads_the_memory_state_and_not_the_outcome_words(self) -> None:
        self.assertEqual(self.failed({**self.SYNTH, "memory_state_accuracy": 0.96, "outcome_accuracy": 1.0}), {"G3"})
        for key, value in (("drop_precision", 0.99), ("drop_precision", None), ("stale_drop_recall", 0.89),
                           ("stale_drop_recall", None)):
            with self.subTest(key=key, value=value):
                self.assertEqual(self.failed({**self.SYNTH, key: value}), {"G3"})

    def test_g6_needs_both_merge_numbers_at_their_lines(self) -> None:
        for key, value in (("absorb_precision", 0.79), ("absorb_precision", None), ("judged_merge_recall", 0.69),
                           ("judged_merge_recall", None)):
            with self.subTest(key=key, value=value):
                self.assertEqual(self.failed(merges={**self.MERGES, key: value}), {"G6"})


class JudgedCandidateTest(unittest.TestCase):
    # The baseline's E-synth numbers fail G3 and G6, so a check that reads them in place of A's shows.
    BAD_SYNTH: dict[str, object] = {**GateChecksTest.SYNTH, "memory_state_accuracy": 0.5}
    BAD_MERGES: dict[str, object] = {**GateChecksTest.MERGES, "judged_merge_recall": 0.1}

    def judged(self, synth: dict[str, dict[str, object]], merges: dict[str, dict[str, object]],
               base_p50: float) -> dict[str, object]:
        real = {"base": {**GateChecksTest.REAL, "latency_p50_s": base_p50}, "A": GateChecksTest.REAL}
        return V.judged_candidate(V.gates_of(GATES), "A", "base", real, synth, merges, GateChecksTest.PAIR)

    def test_a_candidate_is_judged_on_its_own_numbers(self) -> None:
        good = self.judged({"base": self.BAD_SYNTH, "A": GateChecksTest.SYNTH},
                           {"base": self.BAD_MERGES, "A": GateChecksTest.MERGES}, 10.0)
        self.assertEqual((good["pass"], good["paired"]), (True, GateChecksTest.PAIR))
        bad = self.judged({"base": GateChecksTest.SYNTH, "A": self.BAD_SYNTH},
                          {"base": GateChecksTest.MERGES, "A": self.BAD_MERGES}, 10.0)
        self.assertEqual({k for k in ("G1", "G2", "G3", "G4", "G5", "G6") if not bad[k]}, {"G3", "G6"})
        self.assertFalse(bad["pass"])

    def test_g5_compares_with_the_baselines_latency(self) -> None:
        slower = self.judged({"base": GateChecksTest.SYNTH, "A": GateChecksTest.SYNTH},
                             {"base": GateChecksTest.MERGES, "A": GateChecksTest.MERGES}, 9.0)
        self.assertEqual((slower["pass"], slower["G5"]), (False, False))


class MeasureSynthTest(unittest.TestCase):
    def rows(self) -> list[Row]:
        return [synth_row(target=t, item=f"eval-k1-m{m}-00{m}", dropped_off_label=[], absorbs={}, merges_absorbed=[])
                for t in ("base", "A") for m in (1, 2)]

    def measure(self, rows: list[Row]) -> V.SynthMeasure:
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            (run / "rows.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
            return V.measure_synth(run, 2, ["base", "A"], None, None)

    def test_each_target_gets_the_numbers_of_its_own_rows(self) -> None:
        rows = self.rows()
        rows[2] = {**rows[2], "state_correct": 0}
        got = self.measure(rows)
        self.assertEqual((got.by_target["base"]["memory_state_accuracy"], got.by_target["A"]["memory_state_accuracy"]),
                         (1.0, 0.5))
        merges = cast(dict[str, dict[str, object]], got.merges["by_target"])
        self.assertEqual((merges["A"]["absorb_precision"], merges["A"]["judged_merge_recall"]), (None, None))

    def test_a_missing_answer_or_an_unjudged_drop_stops_it(self) -> None:
        dropped = self.rows()
        dropped[0] = {**dropped[0], "dropped_off_label": ["m9"]}
        for rows in (self.rows()[:-1], dropped):
            with self.subTest(rows=len(rows)), self.assertRaises(SystemExit):
                self.measure(rows)


class ChooseTest(unittest.TestCase):
    def test_the_first_passing_candidate_in_order_is_chosen(self) -> None:
        result: dict[str, object] = {"A": {"pass": False}, "C": {"pass": True}, "D": {"pass": True}}
        self.assertEqual(V.choose(["A", "C", "D"], result), "C")
        self.assertIsNone(V.choose(["A"], result))


class BindingTest(unittest.TestCase):
    BASE = "base-model"
    PIN = "p" * 64

    def problem(self, real: dict[str, str], synth: dict[str, str], trained: dict[str, dict[str, object]]) -> str | None:
        return V.binding_problem(real, synth, "base", self.BASE, ["A"], trained, self.PIN)

    def test_a_candidate_is_the_checkpoint_its_training_run_saved(self) -> None:
        targets = {"base": self.BASE, "A": "tinker://run-a/sampler"}
        saved: dict[str, object] = {"candidate": "A", "pass_lines_sha256": self.PIN, "sampler_path": "tinker://run-a/sampler"}
        self.assertIsNone(self.problem(targets, dict(targets), {"A": saved}))
        self.assertIsNotNone(self.problem(targets, dict(targets), {"A": {**saved, "sampler_path": "tinker://other"}}))
        self.assertIsNotNone(self.problem(targets, dict(targets), {"A": {**saved, "pass_lines_sha256": "q" * 64}}))
        self.assertIsNotNone(self.problem(targets, dict(targets), {"A": {**saved, "candidate": "B"}}))
        unnamed = {k: v for k, v in saved.items() if k != "candidate"}
        self.assertIsNotNone(self.problem(targets, dict(targets), {"A": unnamed}))
        self.assertIsNotNone(self.problem(targets, dict(targets), {}))

    def test_a_target_the_pass_lines_do_not_name_is_refused(self) -> None:
        targets = {"base": self.BASE, "A": "tinker://run-a/sampler", "C": "tinker://run-c/sampler"}
        saved: dict[str, object] = {"candidate": "A", "pass_lines_sha256": self.PIN, "sampler_path": "tinker://run-a/sampler"}
        self.assertIsNotNone(self.problem(targets, dict(targets), {"A": saved}))

    def test_both_runs_send_the_same_model_under_each_name(self) -> None:
        real = {"base": self.BASE, "A": "tinker://run-a/sampler"}
        saved: dict[str, object] = {"candidate": "A", "pass_lines_sha256": self.PIN, "sampler_path": "tinker://run-a/sampler"}
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
                      dropped=("m1", "m5", "m6"), added=("new",), revisions=(("m1", "new"),))
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

    def test_a_reply_that_states_an_error_is_a_failed_call(self) -> None:
        part = part_of(V.summarize("synth", [synth_row(), synth_row(error="GLM 1305: busy", wall_s=9.0, valid=False)]))
        self.assertEqual((part["http_errors"], part["latency_p50_s"]), (1, 1.0))

    def test_a_ratio_over_nothing_is_none(self) -> None:
        part = part_of(V.summarize("synth", [synth_row()]))
        self.assertEqual((part["drop_precision"], part["stale_drop_recall"]), (None, 0.0))
        self.assertIsNone(part_of(V.summarize("synth", [synth_row(planted=0)]))["stale_drop_recall"])

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


class PinnedTest(unittest.TestCase):
    PIN, TEMPLATE = "p" * 64, "t" * 64

    def test_both_runs_are_made_under_the_pass_lines_with_the_pinned_template(self) -> None:
        made: dict[str, object] = {"pass_lines_sha256": self.PIN, "template_sha256": self.TEMPLATE}
        self.assertIsNone(V.pinned_problem([made, dict(made)], self.PIN, self.TEMPLATE))
        self.assertEqual(V.pinned_problem([made, {**made, "pass_lines_sha256": "q" * 64}], self.PIN, self.TEMPLATE),
                         "a run used other pass lines")
        self.assertEqual(V.pinned_problem([{**made, "template_sha256": "u" * 64}, made], self.PIN, self.TEMPLATE),
                         "a run drew its prompts with another template than the pinned one")


class RetemplateTest(unittest.TestCase):
    def test_another_template_draws_the_same_data_and_the_pinned_one_the_same_prompt(self) -> None:
        req = request(PLANTED, candidates_of((S.CandidateKind.COMPLEMENT, S.CandidateKind.NEW_DURABLE)))
        rules = synth_render.TEMPLATE.read_text(encoding="utf-8")
        added = "규칙 문장 하나를 더한 템플릿입니다."
        first_slot = rules.index("\n### ")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "requests.jsonl"
            path.write_text(json.dumps({"request": RW.row_of(req)}, ensure_ascii=False) + "\n", encoding="utf-8")
            [item] = V.synth_items(path)
            other_rules = Path(tmp) / "librarian.md"
            other_rules.write_text(rules[:first_slot] + "\n" + added + rules[first_slot:], encoding="utf-8")
            path, [other] = V.drawn_with(other_rules, [item])
        self.assertEqual(path, other_rules)
        self.assertEqual(V.drawn_with(None, [item]), (synth_render.TEMPLATE, [item]))
        self.assertEqual(V.retemplated(item, synth_render.template()), item)
        self.assertNotIn(added, item.text)
        self.assertIn(added, other.text)
        self.assertEqual((other.prompt.current_memory, other.prompt.candidates),
                         (item.prompt.current_memory, item.prompt.candidates))
        data = item.text.index(R.CANDIDATE_HEADER)
        self.assertTrue(other.text.endswith(item.text[data:]))

    def test_retirement_evidence_goes_out_under_the_new_templates_policy(self) -> None:
        payload = '{"evidence_kind":"exact_identity_retirement_history","status":"unavailable","detail":"x"}'
        old, new = "Old retirement policy.", "New retirement policy."
        prompt = make_prompt(make_template(old), retirement=R.RetirementSection(old, payload))
        item = M.RealItem("i1", prompt, R.render(prompt), answer((("r1", "deferred", None),)))
        other = V.retemplated(item, make_template(new))
        self.assertTrue(other.text.endswith("\n\n" + new + "\n" + payload))
        self.assertNotIn(old, other.text)
        self.assertEqual(R.parse(other.text, make_template(new)), other.prompt)
        with self.assertRaises(SystemExit):
            V.retemplated(item, make_template())


if __name__ == "__main__":
    unittest.main()
