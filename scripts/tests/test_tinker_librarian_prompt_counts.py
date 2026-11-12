# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for scripts/tinker/librarian/prompt_counts.py: what one run counts for a prompt comparison.

Rows and runs are invented (`tinker_librarian_prompt_fixtures.py`). `eval_admission` imports the
Tinker caller, which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import eval_admission as V
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
            ("all 3 E-synth", {}, {}, (3, 2)),
            ("all 3 E-real", {}, {}, (2, 3)),
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


if __name__ == "__main__":
    unittest.main()
