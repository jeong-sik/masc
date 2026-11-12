# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for scripts/tinker/librarian/prompt_counts.py: what one run counts for a prompt comparison.

Rows, runs and judges' folders are invented (`tinker_librarian_prompt_fixtures.py`). `eval_admission`
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

import audit_decisions as D
import e_synth_audit as A
import eval_admission as V
import merge_decisions as MD
import prompt_counts as C
from tinker_librarian_prompt_fixtures import DRAFT_T, OTHER_T, PIN, Row, measured, real_row, synth_row, write_run


class CountsTest(unittest.TestCase):
    def test_rates_match_the_verdicts_numbers(self) -> None:
        rows = [synth_row("m1-01", valid=False, candidates=3, correct=3, state_correct=1, planted=2, planted_dropped=1,
                          dropped=2, dropped_expected=1),
                synth_row("m1-02", candidates=4, state_correct=4, planted=1, planted_dropped=1, dropped=1,
                          dropped_expected=1),
                synth_row("m2-01", candidates=2, state_correct=1, planted=0)]
        merges: dict[str, object] = {"absorbs": 4, "absorbs_mergeable": 3, "merges": 5, "merges_mergeable": 2}
        got = C.synth_counts(rows, 1, merges)
        want = cast(dict[str, object], V.summarize("synth", rows, {"base": 1})["base"])
        for metric, key in ((C.Metric.SYNTH_VALID, "valid_rate"), (C.Metric.MEMORY_STATE, "memory_state_accuracy"),
                            (C.Metric.STALE_RECALL, "stale_drop_recall"), (C.Metric.DROP_PRECISION, "drop_precision")):
            self.assertAlmostEqual(got[metric].hits / got[metric].chances, cast(float, want[key]), msg=metric)
        self.assertEqual((got[C.Metric.ABSORB_PRECISION], got[C.Metric.MERGE_RECALL]), (C.Count(3, 4), C.Count(2, 5)))

    def test_the_real_record_counts_valid_answers_only(self) -> None:
        rows = [real_row("e1", agree=2, candidates=3, dropped_not_in_live=["m1"]),
                real_row("e2", valid=False, agree=0, candidates=5, dropped_not_in_live=["m4", "m5"])]
        self.assertEqual(C.real_record(rows), C.RealRecord(2, 3, 1))

    def test_runs_sum_metric_by_metric(self) -> None:
        got = C.summed([measured(DRAFT_T, hits={"stale_drop_recall": (1, 3)}),
                        measured(DRAFT_T, hits={"stale_drop_recall": (2, 4), "drop_precision": (0, 0)})])
        self.assertEqual((got[C.Metric.STALE_RECALL], got[C.Metric.DROP_PRECISION], got[C.Metric.REAL_VALID]),
                         (C.Count(3, 7), C.Count(5, 10), C.Count(10, 20)))

    def test_a_judge_folder_left_out_or_null_is_none(self) -> None:
        self.assertEqual(C.run_of({"synth": "s", "real": "r", "drops": None, "merges": "m"}),
                         C.Run(Path("s"), Path("r"), None, Path("m")))
        self.assertEqual(C.run_of({"synth": "s", "real": "r"}), C.Run(Path("s"), Path("r"), None, None))

    def test_a_run_of_another_shape_is_refused(self) -> None:
        cases: list[object] = [{"synth": "s"}, {"real": "r"}, {"synth": "s", "real": 7}, {"synth": None, "real": "r"},
                               {"synth": "s", "real": "r", "drops": 7}, {"synth": "s", "real": "r", "merges": ["m"]},
                               {"synth": "s", "real": "r", "base": []}, ["s", "r"], "s"]
        for raw in cases:
            with self.subTest(raw=raw):
                with self.assertRaises(SystemExit) as caught:
                    C.run_of(raw)
                self.assertIn("a run names its synth and real folders", str(caught.exception))


class MeasureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_(self, synth: dict[str, object] | None = None, real: dict[str, object] | None = None) -> C.Run:
        """A run of two E-synth and two E-real items, its summaries changed by `synth` and `real`."""
        return C.Run(write_run(self.root, "synth", "synth", [synth_row("m1-01", planted=2, planted_dropped=1, merges=1),
                                                             synth_row("m2-01", valid=False)], **(synth or {})),
                     write_run(self.root, "real", "real", [real_row("e1", dropped_not_in_live=["m7"]),
                                                           real_row("e2", valid=False)], **(real or {})), None, None)

    def measure(self, run: C.Run, items: tuple[int, int] = (2, 2)) -> C.Measured:
        return C.measure(run, provider="tinker", model="inkling-model", pin=PIN, items=items)

    def test_counts_come_from_the_rows(self) -> None:
        run = self.run_()
        got = self.measure(run)
        self.assertEqual((got.counts[C.Metric.SYNTH_VALID], got.counts[C.Metric.STALE_RECALL],
                          got.counts[C.Metric.MERGE_RECALL], got.counts[C.Metric.REAL_VALID]),
                         (C.Count(1, 2), C.Count(1, 3), C.Count(0, 1), C.Count(1, 2)))
        self.assertEqual((got.template_sha256, got.synth_rows_sha256, got.real_rows_sha256),
                         (DRAFT_T, C.sha256_file(run.synth / "rows.jsonl"), C.sha256_file(run.real / "rows.jsonl")))
        self.assertEqual(got.real_record, C.RealRecord(1, 2, 1))
        self.assertEqual(got.answered, frozenset({("key-m1-01", 1.0), ("key-m2-01", 1.0),
                                                  ("key-e1", 2.0), ("key-e2", 2.0)}))

    def test_each_set_is_read_under_the_name_its_own_summary_gives_the_model(self) -> None:
        synth = write_run(self.root, "synth", "synth", [synth_row("m1-01")])
        real = write_run(self.root, "real", "real", [real_row("e1", target="again"), real_row("e2", valid=False)],
                         targets={"again": "inkling-model", "base": "another-model"})
        got = self.measure(C.Run(synth, real, None, None), (1, 1))
        self.assertEqual((got.counts[C.Metric.REAL_VALID], got.real_record), (C.Count(1, 1), C.RealRecord(1, 2, 0)))
        self.assertEqual(got.answered, frozenset({("key-m1-01", 1.0), ("key-e1", 2.0)}))

    def test_refuses_runs_it_cannot_count(self) -> None:
        cases: list[tuple[str, dict[str, object], dict[str, object], tuple[int, int]]] = [
            ("synth is not an E-synth run on tinker", {"pass_lines_sha256": "other"}, {}, (2, 2)),
            ("synth is not an E-synth run on tinker", {"provider": "glm"}, {}, (2, 2)),
            ("synth is not an E-synth run on tinker", {"set": "real"}, {}, (2, 2)),
            ("real is not an E-real run on tinker", {}, {"pass_lines_sha256": "other"}, (2, 2)),
            ("real is not an E-real run on tinker", {}, {"provider": "glm"}, (2, 2)),
            ("real is not an E-real run on tinker", {}, {"set": "synth"}, (2, 2)),
            ("synth stopped before", {"stopped": "quota"}, {}, (2, 2)),
            ("real stopped before", {}, {"stopped": "quota"}, (2, 2)),
            ("under one name", {"targets": {"base": "inkling-model", "again": "inkling-model"}}, {}, (2, 2)),
            ("does not send inkling-model", {"targets": {"base": "another-model"}}, {}, (2, 2)),
            ("different templates", {}, {"template_sha256": OTHER_T}, (2, 2)),
            ("synth does not hold one row for each of the 3 E-synth items", {}, {}, (3, 2)),
            ("synth does not hold one row for each of the 1 E-synth items", {}, {}, (1, 2)),
            ("real does not hold one row for each of the 3 E-real items", {}, {}, (2, 3)),
            ("real does not hold one row for each of the 1 E-real items", {}, {}, (2, 1)),
        ]
        for want, synth, real, items in cases:
            with self.subTest(want=want, synth=synth, real=real, items=items):
                self.tearDown()
                self.setUp()
                with self.assertRaises(SystemExit) as caught:
                    self.measure(self.run_(synth, real), items)
                self.assertIn(want, str(caught.exception))

    def one_item_run(self, row: Row) -> C.Run:
        return C.Run(write_run(self.root, "synth", "synth", [row]), write_run(self.root, "real", "real", [real_row("e1")]),
                     None, None)

    def test_an_absorb_needs_the_merge_judge(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            self.measure(self.one_item_run(synth_row("m1-01", absorbs={"m3": "merge"})), (1, 1))
        self.assertIn("need the merge judge", str(caught.exception))

    def test_an_off_label_drop_needs_the_drop_judge(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            self.measure(self.one_item_run(synth_row("m1-01", dropped=1, dropped_off_label=["m9"])), (1, 1))
        self.assertIn("no drop judge's folder", str(caught.exception))


class JudgedMeasureTest(unittest.TestCase):
    """`measure` over a run with an off-label drop and two absorbs, read with its judges' folders.

    Memory k has two items. On eval-k-0 the answer drops m7 off label and absorbs m1, as the label
    expects; on eval-k-1 it drops m3, which the label asks to absorb, and is not valid. On eval-j-0
    it absorbs m5, as the label expects. The merge judge finds m1 mergeable and m5 not."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.rows = [synth_row("eval-k-0", dropped=1, dropped_off_label=["m7"], absorbs={"m1": "complement"},
                               merges=1, merges_absorbed=[["m1"]]),
                     synth_row("eval-k-1", valid=False, dropped_unmerged=["m3"]),
                     synth_row("eval-j-0", candidates=4, state_correct=3, planted=2, planted_dropped=1, dropped=2,
                               dropped_expected=1, absorbs={"m5": "duplicate"}, merges=1, merges_absorbed=[["m5"]])]

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_(self, m7: str, rows: list[Row] | None = None) -> C.Run:
        """The run of `rows`, all three unless given, with a drop judge that classes m7 as `m7`."""
        rows = self.rows if rows is None else rows
        synth = write_run(self.root, "synth", "synth", rows)
        real = write_run(self.root, "real", "real", [real_row("e1")])
        drops, merges = self.root / "drops", self.root / "merges"
        key: Row = {"case": "d001", "item": "eval-k-0", "candidates": {"k1": "new"},
                    "facts": {"m2": "drop", "m7": "keep"}, "refs": ["m2", "m7"], "off_label": {"m7": ["base"]}}
        A.write_cases(drops, [{"case": "d001"}], [key], A.JUDGE)
        decision: Row = {"case": "d001", "candidates": {"k1": "new"}, "facts": {"m2": "drop", "m7": m7}}
        (drops / D.JUDGE_DIR / D.DECISIONS).write_text(json.dumps(decision) + "\n", encoding="utf-8")
        absorbs = [[cast(str, r["item"]), "base", mid] for r in rows for mid in cast(dict[str, str], r["absorbs"])]
        keys: list[Row] = [{"case": f"g{n:03}", "absorbs": [absorb]} for n, absorb in enumerate(absorbs)]
        A.write_cases(merges, [{"case": k["case"]} for k in keys], keys, "Class each absorb.")
        MD.record_run_files(merges, synth)
        decisions = [{"case": k["case"], "decision": "mergeable" if absorb[2] == "m1" else "loses_knowledge"}
                     for k, absorb in zip(keys, absorbs, strict=True)]
        (merges / D.JUDGE_DIR / D.DECISIONS).write_text("".join(json.dumps(d) + "\n" for d in decisions),
                                                        encoding="utf-8")
        return C.Run(synth, real, drops, merges)

    def counts(self, run: C.Run, items: int = 3) -> dict[str, C.Count]:
        got = C.measure(run, provider="tinker", model="inkling-model", pin=PIN, items=(items, 1))
        return {metric.value: got.counts[metric] for metric in C.Metric}

    def test_a_drop_the_judge_takes_out_leaves_its_memory_out_of_scoring(self) -> None:
        # Only eval-j-0 is scored. The drop of m3 on the memory left out still counts against drop
        # precision, and the absorb of m1 there still counts toward absorb precision.
        self.assertEqual(self.counts(self.run_("drop")),
                         {"synth_valid_rate": C.Count(1, 1), "real_valid_rate": C.Count(1, 1),
                          "memory_state_accuracy": C.Count(3, 4), "stale_drop_recall": C.Count(1, 2),
                          "judged_merge_recall": C.Count(0, 1), "drop_precision": C.Count(1, 3),
                          "absorb_precision": C.Count(1, 2)})

    def test_a_drop_the_judge_keeps_leaves_every_row_scored(self) -> None:
        self.assertEqual(self.counts(self.run_("keep")),
                         {"synth_valid_rate": C.Count(2, 3), "real_valid_rate": C.Count(1, 1),
                          "memory_state_accuracy": C.Count(7, 8), "stale_drop_recall": C.Count(1, 4),
                          "judged_merge_recall": C.Count(1, 2), "drop_precision": C.Count(1, 3),
                          "absorb_precision": C.Count(1, 2)})

    def test_a_judge_that_leaves_no_row_to_score_stops_it(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            self.counts(self.run_("drop", self.rows[:2]), 2)
        self.assertIn("leave none of", str(caught.exception))

    def test_each_judges_decisions_are_read_only_under_the_pinned_rules(self) -> None:
        for judge in ("drops", "merges"):
            with self.subTest(judge=judge):
                self.tearDown()
                self.setUp()
                run = self.run_("drop")
                rules = self.root / judge / D.JUDGE_DIR / D.RULES
                rules.write_text(rules.read_text(encoding="utf-8") + "\nAnother rule.\n", encoding="utf-8")
                D.record_judge_files(self.root / judge)
                with self.assertRaises(SystemExit) as caught:
                    self.counts(run)
                self.assertIn(f"{judge}/judge: its {D.RULES} is not", str(caught.exception))

    def test_merge_cases_made_from_another_runs_files_are_refused(self) -> None:
        run = self.run_("drop")
        (run.synth / "calls.jsonl").write_text("{}\n", encoding="utf-8")
        with self.assertRaises(SystemExit) as caught:
            self.counts(run)
        self.assertIn("were made from other run files", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
