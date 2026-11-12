# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for scripts/tinker/librarian/prompt_compare.py: whether a prompt draft goes in.

Counts, runs and pinned lines are invented (`tinker_librarian_prompt_fixtures.py`). `CommandTest`
runs the two commands over invented run folders of every pinned item, under the present pass lines.
`eval_admission` imports the Tinker caller, which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import contextlib
import io
import itertools
import json
import math
import shutil
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from typing import cast
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import eval_admission as V
import prompt_compare as P
import prompt_counts as C
import prompt_lines as L
from tinker_librarian_prompt_fixtures import (
    BASE_T,
    DRAFT_T,
    FILES,
    GLM,
    INKLING,
    LINES,
    OTHER_T,
    PIN,
    RECORD,
    Row,
    baseline,
    measured,
    real_row,
    sha,
    synth_row,
    write_run,
)

type Sides = dict[str, tuple[L.Baseline, list[C.Measured]]]


def sides(inkling_draft: dict[str, tuple[int, int]], glm_draft: dict[str, tuple[int, int]] | None = None) -> Sides:
    """Each model's pinned baseline, every metric at 5 of 10 a run, beside draft runs counting the hits named."""
    out: Sides = {"inkling": (baseline("i1", "i2"), [measured(DRAFT_T, "d1", inkling_draft),
                                                     measured(DRAFT_T, "d2", inkling_draft)])}
    if glm_draft is not None:
        out["glm"] = (baseline("g1"), [measured(DRAFT_T, "d3", glm_draft)])
    return out


class ChangeTest(unittest.TestCase):
    def test_the_noise_width_decides_worse_and_better(self) -> None:
        base = C.Count(80, 100)
        self.assertEqual(P.change_of(base, C.Count(70, 100), 2.5, 2.0)[0], P.Change.SAME)
        self.assertEqual(P.change_of(base, C.Count(70, 100), 1.5, 2.0)[0], P.Change.WORSE)
        self.assertEqual(P.change_of(base, C.Count(95, 100), 2.5, 2.0)[0], P.Change.BETTER)
        self.assertEqual(P.change_of(base, C.Count(95, 100), 2.5, 3.5)[0], P.Change.SAME)

    def test_a_drop_reaching_the_edge_is_not_worse_and_one_past_it_is(self) -> None:
        base, draft = C.Count(30, 41), C.Count(20, 41)
        _, d, sigma = P.change_of(base, draft, 9.0, 9.0)
        assert d is not None and sigma is not None
        edge = abs(d) / sigma
        self.assertEqual(P.change_of(base, draft, edge * (1 + 1e-9), 9.0)[0], P.Change.SAME)
        self.assertEqual(P.change_of(base, draft, edge * (1 - 1e-9), 9.0)[0], P.Change.WORSE)

    def test_a_difference_of_exactly_a_width_is_the_same(self) -> None:
        # 45/50 against 35/50: p = 0.8, σ = 0.08, and the rates differ by 0.2 = 2.5σ.
        # In floats 0.9 - 0.7 is a little more than 0.2 and 2.5 times σ a little less.
        high, low = C.Count(45, 50), C.Count(35, 50)
        self.assertEqual(P.change_of(high, low, 2.5, 9.0)[0], P.Change.SAME)
        self.assertEqual(P.change_of(low, high, 9.0, 2.5)[0], P.Change.SAME)
        self.assertEqual(P.change_of(high, C.Count(34, 50), 2.5, 9.0)[0], P.Change.WORSE)
        self.assertEqual(P.change_of(low, C.Count(46, 50), 9.0, 2.5)[0], P.Change.BETTER)

    def test_a_width_is_the_decimal_written_not_the_float_nearest_to_it(self) -> None:
        # 198/40401 against 204/40401 differ by exactly 0.3σ. The float nearest to 0.3 is a little less.
        low, high = C.Count(198, 40401), C.Count(204, 40401)
        self.assertEqual(P.change_of(low, high, 9.0, 0.3)[0], P.Change.SAME)
        self.assertEqual(P.change_of(high, low, 0.3, 9.0)[0], P.Change.SAME)
        self.assertEqual(P.change_of(low, C.Count(205, 40401), 9.0, 0.3)[0], P.Change.BETTER)
        self.assertEqual(P.change_of(high, C.Count(197, 40401), 0.3, 9.0)[0], P.Change.WORSE)

    def test_a_width_of_zero_makes_any_difference_a_change(self) -> None:
        self.assertEqual(P.change_of(C.Count(50, 100), C.Count(49, 100), 0.0, 0.0)[0], P.Change.WORSE)
        self.assertEqual(P.change_of(C.Count(50, 100), C.Count(51, 100), 0.0, 0.0)[0], P.Change.BETTER)
        self.assertEqual(P.change_of(C.Count(50, 100), C.Count(25, 50), 0.0, 0.0)[0], P.Change.SAME)

    def test_sigma_is_the_standard_error_at_the_pooled_rate(self) -> None:
        _, d, sigma = P.change_of(C.Count(5, 82), C.Count(20, 82), 2.5, 2.0)
        p = 25 / 164
        self.assertAlmostEqual(cast(float, d), 15 / 82)
        self.assertAlmostEqual(cast(float, sigma), math.sqrt(p * (1 - p) * (2 / 82)))

    def test_sigma_takes_each_sides_own_chances(self) -> None:
        # 10/100 against 20/50: p = 30/150 = 0.2, and 1/100 + 1/50 = 0.03.
        _, d, sigma = P.change_of(C.Count(10, 100), C.Count(20, 50), 2.5, 2.0)
        self.assertAlmostEqual(cast(float, d), 0.3)
        self.assertAlmostEqual(cast(float, sigma), math.sqrt(0.2 * 0.8 * 0.03))

    def test_a_side_with_nothing_to_count_is_uncounted(self) -> None:
        self.assertEqual(P.change_of(C.Count(0, 0), C.Count(3, 4), 2.5, 2.0), (P.Change.UNCOUNTED, None, None))
        self.assertEqual(P.change_of(C.Count(3, 4), C.Count(0, 0), 2.5, 2.0), (P.Change.UNCOUNTED, None, None))

    def test_every_hit_or_no_hit_on_both_sides_is_the_same(self) -> None:
        self.assertEqual(P.change_of(C.Count(10, 10), C.Count(20, 20), 2.5, 2.0)[0], P.Change.SAME)
        self.assertEqual(P.change_of(C.Count(0, 10), C.Count(0, 20), 2.5, 2.0)[0], P.Change.SAME)


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

    def test_better_guard_metric_or_glm_is_not_the_improvement(self) -> None:
        for inkling, glm in (({"synth_valid_rate": (10, 10)}, {}), ({"drop_precision": (10, 10)}, {}),
                             ({"absorb_precision": (10, 10)}, {}),
                             ({}, {"stale_drop_recall": (10, 10)})):
            with self.subTest(inkling=inkling, glm=glm):
                result = P.compared(LINES, sides(inkling, glm))
                self.assertEqual((result["better"], result["complete"], result["goes_in"]), ([], True, False))

    def test_a_draft_waiting_for_its_glm_runs_does_not_go_in(self) -> None:
        result = P.compared(LINES, sides({"stale_drop_recall": (9, 10)}))
        self.assertEqual((result["complete"], result["goes_in"]), (False, False))
        self.assertEqual(result["draft_template_sha256"], [DRAFT_T])

    def test_the_base_side_is_the_pinned_baseline(self) -> None:
        pinned = replace(baseline("i1", "i2"), counts={m: C.Count(7, 30) for m in C.Metric},
                         real_record=(C.RealRecord(3, 4, 5), C.RealRecord(0, 7, 1)))
        draft = [measured(DRAFT_T, "d1", record=C.RealRecord(2, 2, 0)), measured(DRAFT_T, "d2")]
        got = cast(Row, cast(Row, P.compared(LINES, {"inkling": (pinned, draft)})["models"])["inkling"])
        for metric in C.Metric:
            row = cast(Row, cast(Row, got["metrics"])[metric.value])
            self.assertEqual((row["base"], row["draft"]), ([7, 30], [10, 20]), msg=metric)
        self.assertEqual(got["real_record"],
                         {"base": [{"agree": 3, "candidates": 4, "dropped_not_in_live": 5},
                                   {"agree": 0, "candidates": 7, "dropped_not_in_live": 1}],
                          "draft": [{"agree": 2, "candidates": 2, "dropped_not_in_live": 0},
                                    {"agree": RECORD.agree, "candidates": RECORD.candidates,
                                     "dropped_not_in_live": RECORD.dropped_not_in_live}]})
        self.assertEqual(got["base_rows_sha256"], {"synth": [sha("i1 synth"), sha("i2 synth")],
                                                   "real": [sha("i1 real"), sha("i2 real")]})

    def test_precision_with_chances_on_only_one_side_cannot_prove_non_degradation(self) -> None:
        for model in ("inkling", "glm"):
            for zero_base in (True, False):
                for metric in (C.Metric.DROP_PRECISION, C.Metric.ABSORB_PRECISION):
                    with self.subTest(model=model, zero_base=zero_base, metric=metric):
                        plan = sides({"memory_state_accuracy": (10, 10)}, {})
                        base, draft = plan[model]
                        if zero_base:
                            base = replace(base, counts={**base.counts, metric: C.Count(0, 0)})
                        else:
                            draft = [replace(m, counts={**m.counts, metric: C.Count(0, 0)}) for m in draft]
                        plan[model] = (base, draft)
                        result = P.compared(LINES, plan)
                        self.assertEqual(result["uncompared"], [f"{model}.{metric.value}"])
                        self.assertEqual((result["worse"], result["complete"], result["goes_in"]),
                                         ([], False, False))
                        self.assertTrue(result["better"])

    def test_no_actions_on_either_side_are_not_an_improvement_or_a_missing_comparison(self) -> None:
        plan = sides({"memory_state_accuracy": (10, 10)}, {})
        for model, (base, draft) in list(plan.items()):
            plan[model] = (replace(base, counts={**base.counts, C.Metric.ABSORB_PRECISION: C.Count(0, 0)}),
                           [replace(m, counts={**m.counts, C.Metric.ABSORB_PRECISION: C.Count(0, 0)}) for m in draft])
        result = P.compared(LINES, plan)
        self.assertEqual((result["uncompared"], result["complete"], result["goes_in"]), ([], True, True))
        self.assertEqual(result["better"], ["inkling.memory_state_accuracy"])
        for model in ("inkling", "glm"):
            metrics = cast(dict[str, Row], cast(dict[str, Row], result["models"])[model]["metrics"])
            self.assertEqual(metrics[C.Metric.ABSORB_PRECISION]["change"], P.Change.UNCOUNTED)


class RunsProblemTest(unittest.TestCase):
    def test_the_pinned_number_of_runs_of_the_pinned_template_is_a_baseline(self) -> None:
        self.assertIsNone(P.baseline_problem("inkling", INKLING, [measured(BASE_T, "i1"), measured(BASE_T, "i2")], BASE_T))

    def test_runs_that_cannot_be_a_baseline(self) -> None:
        cases = {"inkling takes 2 baseline runs, not 1": [measured(BASE_T)],
                 "inkling takes 2 baseline runs, not 3": [measured(BASE_T)] * 3,
                 "another template than the pinned one": [measured(BASE_T), measured(OTHER_T)]}
        for want, base in cases.items():
            with self.subTest(want=want):
                self.assertIn(want, P.baseline_problem("inkling", INKLING, base, BASE_T) or "")

    def test_the_pinned_number_of_runs_of_one_other_template_is_a_draft(self) -> None:
        self.assertIsNone(P.draft_problem("inkling", INKLING, [measured(DRAFT_T)] * 2, BASE_T))

    def test_runs_that_cannot_be_a_draft(self) -> None:
        cases = {"inkling takes 2 draft runs, not 1": [measured(DRAFT_T)],
                 "inkling takes 2 draft runs, not 3": [measured(DRAFT_T)] * 3,
                 "do not share one template": [measured(DRAFT_T), measured(OTHER_T)],
                 "other than the pinned one": [measured(BASE_T)] * 2}
        for want, draft in cases.items():
            with self.subTest(want=want):
                self.assertIn(want, P.draft_problem("inkling", INKLING, draft, BASE_T) or "")


class PlanProblemTest(unittest.TestCase):
    def test_one_draft_template_and_runs_with_their_own_calls_compare(self) -> None:
        plan = {"inkling": [measured(DRAFT_T, answered=frozenset({("a", 1.0)})),
                            measured(DRAFT_T, answered=frozenset({("a", 2.0)}))],
                "glm": [measured(DRAFT_T, answered=frozenset({("c", 1.0)}))]}
        self.assertIsNone(P.plan_problem(plan))

    def test_models_whose_drafts_drew_different_templates_are_refused(self) -> None:
        plan = {"inkling": [measured(DRAFT_T)], "glm": [measured(OTHER_T)]}
        self.assertIn("different templates", P.plan_problem(plan) or "")

    def test_a_run_listed_twice_or_copied_is_refused(self) -> None:
        run = measured(DRAFT_T, answered=frozenset({("k1", 1.0), ("k2", 1.0)}))
        copied = measured(DRAFT_T, answered=frozenset({("k1", 1.0), ("k3", 1.0)}))
        for name, draft in {"twice": [run, run], "copied": [run, copied]}.items():
            with self.subTest(name=name):
                self.assertIn("two inkling runs count the same answered call", P.plan_problem({"inkling": draft}) or "")


class BaselinesTest(unittest.TestCase):
    def test_a_baseline_sums_its_runs_and_keeps_their_order(self) -> None:
        first = measured(BASE_T, "i1", {"stale_drop_recall": (1, 3)}, frozenset({("a", 1.0)}), C.RealRecord(3, 4, 5))
        second = measured(BASE_T, "i2", {"stale_drop_recall": (2, 4)}, frozenset({("a", 2.0)}), C.RealRecord(0, 7, 1))
        counts = {m: C.Count(10, 20) for m in C.Metric} | {C.Metric.STALE_RECALL: C.Count(3, 7)}
        self.assertEqual(P.baselines(LINES, {"inkling": [first, second]}),
                         {"inkling": L.Baseline(PIN, BASE_T, FILES[L.COUNTS], counts,
                                                (C.RealRecord(3, 4, 5), C.RealRecord(0, 7, 1)),
                                                (sha("i1 synth"), sha("i2 synth")), (sha("i1 real"), sha("i2 real")))})

    def test_runs_that_cannot_be_a_baseline_are_refused(self) -> None:
        run = measured(BASE_T, answered=frozenset({("k", 1.0)}))
        cases = {"inkling takes 2 baseline runs, not 1": {"inkling": [measured(BASE_T)]},
                 "a glm baseline run drew its prompts with another template": {"glm": [measured(DRAFT_T)]},
                 "two inkling runs count the same answered call": {"inkling": [run, run]},
                 "names no model another": {"another": [run]}}
        for want, runs in cases.items():
            with self.subTest(want=want):
                with self.assertRaises(SystemExit) as caught:
                    P.baselines(LINES, runs)
                self.assertIn(want, str(caught.exception))


class SidesTest(unittest.TestCase):
    def test_a_models_draft_runs_stand_beside_its_pinned_baseline(self) -> None:
        draft = [measured(DRAFT_T, "d1"), measured(DRAFT_T, "d2")]
        self.assertEqual(P.sides_of(LINES, {"inkling": draft}), {"inkling": (INKLING.baseline, draft)})

    def test_draft_runs_that_cannot_be_compared_are_refused(self) -> None:
        unpinned = replace(LINES, models={**LINES.models, "glm": replace(GLM, baseline=None)})
        run = measured(DRAFT_T, answered=frozenset({("k", 1.0)}))
        cases: dict[str, tuple[L.Lines, dict[str, list[C.Measured]]]] = {
            "prompt_lines.json pins no glm baseline yet": (unpinned, {"glm": [measured(DRAFT_T)]}),
            "inkling takes 2 draft runs, not 1": (LINES, {"inkling": [measured(DRAFT_T)]}),
            "different templates": (LINES, {"inkling": [measured(DRAFT_T)] * 2, "glm": [measured(OTHER_T)]}),
            "two inkling runs count the same answered call": (LINES, {"inkling": [run, run]}),
            "names no model another": (LINES, {"another": [run]}),
        }
        for want, (lines, drafts) in cases.items():
            with self.subTest(want=want):
                with self.assertRaises(SystemExit) as caught:
                    P.sides_of(lines, drafts)
                self.assertIn(want, str(caught.exception))

    def test_runs_of_a_model_the_lines_do_not_hold_are_not_measured(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            P.measured_runs(LINES, {"another": []}, (1, 1))
        self.assertIn("names no model another", str(caught.exception))


class CommandTest(unittest.TestCase):
    """The two commands over invented run folders of every pinned item, under the present pass lines
    and a prompt_lines.json of one model, in a temporary folder."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        pass_lines = V.load_pass_lines()
        self.items = (cast(int, cast(Row, pass_lines["e_synth"])["items"]),
                      cast(int, cast(Row, pass_lines["e_real"])["items"]))
        self.pin = C.sha256_file(V.PASS_LINES)
        self.lines = self.root / "prompt_lines.json"
        self.sent = itertools.count(1)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write_lines(self, pinned: object) -> None:
        """A prompt_lines.json that pins the present files and holds `pinned` as the Inkling baseline."""
        raw = {"schema": L.SCHEMA, "pass_lines_sha256": self.pin, "baseline_template_sha256": BASE_T,
               "worse_sigmas": 2.5, "better_sigmas": 2.0, "better_from": ["inkling"],
               "models": {"inkling": {"provider": "tinker", "model": "inkling-model", "runs": 2, "baseline": pinned}},
               "files_sha256": {name: C.sha256_file(L.HERE / name) for name in L.PINNED_FILES}}
        self.lines.write_text(json.dumps(raw), encoding="utf-8")

    def runs(self, name: str, template: str, planted_dropped: int) -> Path:
        """runs.json of two Inkling runs drawn with `template`. Each answers every item at its own time
        and drops `planted_dropped` of the one stale fact planted on each E-synth item."""
        listed: list[dict[str, str]] = []
        for n in (1, 2):
            sent_at = float(next(self.sent))
            summary: Row = {"pass_lines_sha256": self.pin, "template_sha256": template}
            synth = write_run(self.root, f"{name}-synth-{n}", "synth",
                              [synth_row(f"m{i}", sent_at=sent_at, planted_dropped=planted_dropped)
                               for i in range(self.items[0])], **summary)
            real = write_run(self.root, f"{name}-real-{n}", "real",
                             [real_row(f"e{i}", sent_at=sent_at) for i in range(self.items[1])], **summary)
            listed.append({"synth": str(synth), "real": str(real)})
        path = self.root / f"{name}.json"
        path.write_text(json.dumps({"inkling": listed}), encoding="utf-8")
        return path

    def command(self, *argv: str) -> str:
        """What `prompt_compare.py <argv>` prints, reading the temporary prompt_lines.json."""
        printed = io.StringIO()
        with (mock.patch.object(L, "PROMPT_LINES", self.lines), mock.patch.object(sys, "argv", ["prompt_compare.py", *argv]),
              contextlib.redirect_stdout(printed)):
            self.assertEqual(P.main(), 0)
        return printed.getvalue()

    def test_compare_reads_the_printed_baseline_after_its_runs_are_gone(self) -> None:
        both = 2 * self.items[0]
        self.write_lines(None)
        printed = cast(dict[str, Row], json.loads(self.command("baseline", "--runs", str(self.runs("base", BASE_T, 0)))))
        pinned = printed["inkling"]
        self.assertEqual(cast(Row, pinned["counts"])["stale_drop_recall"], [0, both])
        self.write_lines(pinned)
        for folder in self.root.glob("base-*"):
            shutil.rmtree(folder)
        out = self.root / "compare.json"
        said = cast(Row, json.loads(self.command("compare", "--runs", str(self.runs("draft", DRAFT_T, 1)),
                                                 "--out", str(out))))
        self.assertEqual(said, {"worse": [], "better": ["inkling.stale_drop_recall"], "uncompared": [],
                                "complete": True, "goes_in": True})
        result = cast(Row, cast(Row, cast(Row, json.loads(out.read_text(encoding="utf-8")))["models"])["inkling"])
        stale = cast(Row, cast(Row, result["metrics"])["stale_drop_recall"])
        self.assertEqual((stale["base"], stale["draft"], stale["change"]), ([0, both], [both, both], "better"))
        self.assertEqual(result["base_rows_sha256"], {"synth": pinned["synth_rows_sha256"],
                                                      "real": pinned["real_rows_sha256"]})

    def test_compare_before_the_baseline_is_pinned_is_refused(self) -> None:
        self.write_lines(None)
        with self.assertRaises(SystemExit) as caught:
            self.command("compare", "--runs", str(self.runs("draft", DRAFT_T, 1)), "--out", str(self.root / "c.json"))
        self.assertIn("prompt_lines.json pins no inkling baseline yet", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
