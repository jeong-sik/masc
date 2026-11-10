# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for scripts/tinker/librarian/prompt_compare.py: whether a prompt draft goes in.

Rows and runs are invented. `eval_admission` imports the Tinker caller, which
imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import hashlib
import json
import math
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import eval_admission as V
import prompt_compare as P

type Row = dict[str, object]

BASE_T, DRAFT_T, OTHER_T = "t-base", "t-draft", "t-other"
PIN = "pin"
INKLING = P.ModelLines("tinker", "inkling-model", 2, frozenset({"s1", "s2"}), frozenset({"r1", "r2"}))
GLM = P.ModelLines("glm", "glm-model", 1, frozenset({"gs"}), frozenset({"gr"}))
LINES = P.Lines(PIN, BASE_T, 2.5, 2.0, frozenset({"inkling"}), {"inkling": INKLING, "glm": GLM})


def synth_row(item: str, **counts: object) -> Row:
    base: Row = {"target": "base", "item": item, "status": 200, "wall_s": 1.0, "valid": True, "cost_usd": 0.0,
                 "prompt_tokens": 1, "cached_tokens": 1, "candidates": 2, "correct": 2, "dropped": 0,
                 "absorbed": 0, "dropped_expected": 0, "planted": 1, "planted_dropped": 0, "state_correct": 2,
                 "state_by_kind": {"new": [2, 2]}, "dropped_unmerged": [], "planted_absorbed": 0, "merges": 0,
                 "merges_done": 0, "added": 0, "removed": 0, "expected_added": 0, "expected_removed": 0,
                 "dropped_off_label": [], "absorbs": {}, "merges_absorbed": []}
    return {**base, **counts}


def real_row(item: str, **counts: object) -> Row:
    base: Row = {"target": "base", "item": item, "status": 200, "wall_s": 1.0, "valid": True, "cost_usd": 0.0,
                 "prompt_tokens": 1, "cached_tokens": 1, "candidates": 2, "agree": 1,
                 "dropped_not_in_live": [], "absorbed_not_in_live": [], "added": 0, "removed": 0,
                 "live_added": 0, "live_removed": 0}
    return {**base, **counts}


def counts(hits: dict[str, tuple[int, int]]) -> dict[P.Metric, P.Count]:
    """Every metric at 5 of 10, but those named."""
    out = {m: P.Count(5, 10) for m in P.Metric}
    out.update({P.Metric(k): P.Count(*v) for k, v in hits.items()})
    return out


def measured(template: str, synth: str = "s", real: str = "r",
             hits: dict[str, tuple[int, int]] | None = None) -> P.Measured:
    return P.Measured(counts(hits or {}), template, synth, real,
                      {"agree": 1, "candidates": 2, "dropped_not_in_live": 0})


def sides(inkling_draft: dict[str, tuple[int, int]], glm_draft: dict[str, tuple[int, int]] | None = None,
          ) -> dict[str, tuple[list[P.Measured], list[P.Measured]]]:
    out = {"inkling": ([measured(BASE_T, "s1", "r1"), measured(BASE_T, "s2", "r2")],
                       [measured(DRAFT_T, hits=inkling_draft), measured(DRAFT_T, hits=inkling_draft)])}
    if glm_draft is not None:
        out["glm"] = ([measured(BASE_T, "gs", "gr")], [measured(DRAFT_T, hits=glm_draft)])
    return out


class ChangeTest(unittest.TestCase):
    def test_the_noise_width_decides_worse_and_better(self) -> None:
        base = P.Count(80, 100)
        self.assertEqual(P.change_of(base, P.Count(70, 100), 2.5, 2.0)[0], P.Change.SAME)
        self.assertEqual(P.change_of(base, P.Count(70, 100), 1.5, 2.0)[0], P.Change.WORSE)
        self.assertEqual(P.change_of(base, P.Count(95, 100), 2.5, 2.0)[0], P.Change.BETTER)
        self.assertEqual(P.change_of(base, P.Count(95, 100), 2.5, 3.5)[0], P.Change.SAME)

    def test_a_drop_reaching_the_edge_is_not_worse_and_one_past_it_is(self) -> None:
        base, draft = P.Count(30, 41), P.Count(20, 41)
        _, d, sigma = P.change_of(base, draft, 9.0, 9.0)
        assert d is not None and sigma is not None
        edge = abs(d) / sigma
        self.assertEqual(P.change_of(base, draft, edge * (1 + 1e-9), 9.0)[0], P.Change.SAME)
        self.assertEqual(P.change_of(base, draft, edge * (1 - 1e-9), 9.0)[0], P.Change.WORSE)

    def test_sigma_is_the_standard_error_at_the_pooled_rate(self) -> None:
        _, d, sigma = P.change_of(P.Count(5, 82), P.Count(20, 82), 2.5, 2.0)
        p = 25 / 164
        self.assertAlmostEqual(cast(float, d), 15 / 82)
        self.assertAlmostEqual(cast(float, sigma), math.sqrt(p * (1 - p) * (2 / 82)))

    def test_a_side_with_nothing_to_count_is_uncounted(self) -> None:
        self.assertEqual(P.change_of(P.Count(0, 0), P.Count(3, 4), 2.5, 2.0), (P.Change.UNCOUNTED, None, None))
        self.assertEqual(P.change_of(P.Count(3, 4), P.Count(0, 0), 2.5, 2.0), (P.Change.UNCOUNTED, None, None))

    def test_every_hit_on_both_sides_is_the_same(self) -> None:
        self.assertEqual(P.change_of(P.Count(10, 10), P.Count(20, 20), 2.5, 2.0)[0], P.Change.SAME)


class CountsTest(unittest.TestCase):
    def test_rates_match_the_verdicts_numbers(self) -> None:
        rows = [synth_row("m1-01", valid=False, candidates=3, state_correct=1, planted=2, planted_dropped=1,
                          dropped=2, dropped_expected=1),
                synth_row("m1-02", candidates=4, state_correct=4, planted=1, planted_dropped=1, dropped=1,
                          dropped_expected=1),
                synth_row("m2-01", candidates=2, state_correct=1, planted=0)]
        merges: dict[str, object] = {"absorbs": 4, "absorbs_mergeable": 3, "merges": 5, "merges_mergeable": 2}
        got = P.synth_counts(rows, 1, merges)
        want = cast(dict[str, object], V.summarize("synth", rows, {"base": 1})["base"])
        for metric, key in ((P.Metric.SYNTH_VALID, "valid_rate"), (P.Metric.MEMORY_STATE, "memory_state_accuracy"),
                            (P.Metric.STALE_RECALL, "stale_drop_recall"), (P.Metric.DROP_PRECISION, "drop_precision")):
            self.assertAlmostEqual(got[metric].hits / got[metric].chances, cast(float, want[key]), msg=metric)
        self.assertEqual((got[P.Metric.ABSORB_PRECISION], got[P.Metric.MERGE_RECALL]), (P.Count(3, 4), P.Count(2, 5)))

    def test_the_real_record_counts_valid_answers_only(self) -> None:
        rows = [real_row("e1", agree=2, candidates=3, dropped_not_in_live=["m1"]),
                real_row("e2", valid=False, agree=0, candidates=5, dropped_not_in_live=["m4", "m5"])]
        self.assertEqual(P.real_record(rows), {"agree": 2, "candidates": 3, "dropped_not_in_live": 1})


class ComparedTest(unittest.TestCase):
    def test_a_draft_that_changes_nothing_does_not_go_in(self) -> None:
        result = P.compared(LINES, sides({}, {}))
        self.assertEqual((result["worse"], result["better"], result["complete"], result["goes_in"]), ([], [], True, False))

    def test_a_better_quality_metric_on_inkling_and_nothing_worse_goes_in(self) -> None:
        result = P.compared(LINES, sides({"stale_drop_recall": (9, 10)}, {}))
        self.assertEqual((result["better"], result["goes_in"]), (["inkling.stale_drop_recall"], True))

    def test_one_worse_metric_on_either_model_keeps_it_out(self) -> None:
        result = P.compared(LINES, sides({"stale_drop_recall": (9, 10)}, {"real_valid_rate": (0, 10)}))
        self.assertEqual((result["worse"], result["goes_in"]), (["glm.real_valid_rate"], False))

    def test_better_validity_drop_precision_or_glm_is_not_the_improvement(self) -> None:
        for inkling, glm in (({"synth_valid_rate": (10, 10)}, {}), ({"drop_precision": (10, 10)}, {}),
                             ({}, {"stale_drop_recall": (10, 10)})):
            with self.subTest(inkling=inkling, glm=glm):
                self.assertFalse(P.compared(LINES, sides(inkling, glm))["goes_in"])

    def test_a_draft_waiting_for_its_glm_runs_does_not_go_in(self) -> None:
        result = P.compared(LINES, sides({"stale_drop_recall": (9, 10)}))
        self.assertEqual((result["complete"], result["goes_in"]), (False, False))
        self.assertEqual(result["draft_template_sha256"], [DRAFT_T])


class SideProblemTest(unittest.TestCase):
    def base(self) -> list[P.Measured]:
        return [measured(BASE_T, "s1", "r1"), measured(BASE_T, "s2", "r2")]

    def test_pinned_runs_and_one_draft_template_compare(self) -> None:
        self.assertIsNone(P.side_problem("inkling", INKLING, self.base(), [measured(DRAFT_T)] * 2, BASE_T))

    def test_each_refusal(self) -> None:
        cases = {
            "takes 2 base and 2 draft": (INKLING, self.base(), [measured(DRAFT_T)]),
            "pins no inkling baseline": (P.ModelLines("tinker", "m", 2, frozenset(), frozenset()), self.base(),
                                         [measured(DRAFT_T)] * 2),
            "not the ones": (INKLING, [measured(BASE_T, "s1", "r1"), measured(BASE_T, "s3", "r2")],
                             [measured(DRAFT_T)] * 2),
            "another template than the pinned": (INKLING, [measured(BASE_T, "s1", "r1"), measured(OTHER_T, "s2", "r2")],
                                                 [measured(DRAFT_T)] * 2),
            "do not share one template": (INKLING, self.base(), [measured(DRAFT_T), measured(OTHER_T)]),
        }
        for want, (model, base, draft) in cases.items():
            with self.subTest(want=want):
                self.assertIn(want, P.side_problem("inkling", model, base, draft, BASE_T) or "")
        self.assertIn("other than the pinned",
                      P.side_problem("inkling", INKLING, self.base(), [measured(BASE_T)] * 2, BASE_T) or "")


class MeasureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, name: str, kind: str, rows: list[Row], **summary: object) -> Path:
        run = self.root / name
        run.mkdir()
        (run / "rows.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
        body = {"set": kind, "pass_lines_sha256": PIN, "template_sha256": DRAFT_T, "provider": "tinker",
                "targets": {"base": "inkling-model"}, "stopped": None, **summary}
        (run / "summary.json").write_text(json.dumps(body), encoding="utf-8")
        return run

    def run_(self, **summary: object) -> P.Run:
        synth = self.write("synth", "synth", [synth_row("m1-01", planted=2, planted_dropped=1, merges=1),
                                              synth_row("m2-01", valid=False)], **summary)
        real = self.write("real", "real", [real_row("e1"), real_row("e2", valid=False)])
        return P.Run(synth, real, None, None)

    def test_counts_come_from_the_rows(self) -> None:
        run = self.run_()
        got = P.measure(run, INKLING, PIN, (2, 2))
        self.assertEqual((got.counts[P.Metric.SYNTH_VALID], got.counts[P.Metric.STALE_RECALL],
                          got.counts[P.Metric.MERGE_RECALL], got.counts[P.Metric.REAL_VALID]),
                         (P.Count(1, 2), P.Count(1, 3), P.Count(0, 1), P.Count(1, 2)))
        self.assertEqual((got.template_sha256, got.synth_rows_sha256),
                         (DRAFT_T, hashlib.sha256((run.synth / "rows.jsonl").read_bytes()).hexdigest()))

    def test_refuses_runs_it_cannot_count(self) -> None:
        cases: dict[str, tuple[dict[str, object], tuple[int, int]]] = {
            "not an E-synth run": ({"pass_lines_sha256": "other"}, (2, 2)),
            "stopped before": ({"stopped": "quota"}, (2, 2)),
            "under one name": ({"targets": {"base": "inkling-model", "again": "inkling-model"}}, (2, 2)),
            "all 3 E-synth": ({}, (3, 2)),
            "all 3 E-real": ({}, (2, 3)),
        }
        for want, (summary, items) in cases.items():
            with self.subTest(want=want):
                self.tearDown()
                self.setUp()
                with self.assertRaises(SystemExit) as caught:
                    P.measure(self.run_(**summary), INKLING, PIN, items)
                self.assertIn(want, str(caught.exception))

    def test_an_absorb_needs_the_merge_judge(self) -> None:
        synth = self.write("synth", "synth", [synth_row("m1-01", absorbs={"m3": "merge"})])
        real = self.write("real", "real", [real_row("e1")])
        with self.assertRaises(SystemExit):
            P.measure(P.Run(synth, real, None, None), INKLING, PIN, (1, 1))


class PinTest(unittest.TestCase):
    def test_the_lines_pin_this_compare_the_pass_lines_and_their_template(self) -> None:
        raw = cast(dict[str, object], json.loads(P.PROMPT_LINES.read_text(encoding="utf-8")))
        compare = Path(P.__file__)
        self.assertEqual(raw["files_sha256"], {compare.name: hashlib.sha256(compare.read_bytes()).hexdigest()})
        lines = P.lines_of(raw)
        pass_lines = V.load_pass_lines()
        self.assertEqual(lines.pass_lines_sha256, hashlib.sha256(V.PASS_LINES.read_bytes()).hexdigest())
        self.assertEqual(lines.baseline_template_sha256,
                         cast(dict[str, str], pass_lines["files_sha256"])["../../../config/prompts/librarian.md"])
        self.assertLessEqual(lines.better_from, frozenset(lines.models))


if __name__ == "__main__":
    unittest.main()
