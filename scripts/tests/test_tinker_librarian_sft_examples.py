# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the training examples of the LoRA candidate (scripts/tinker/librarian/sft_examples.py):
the teacher answers that become examples, the steps of the one pass, what the plan records, and
the teacher folders `plan` refuses.

The folder is one `teacher_sample.py sample` leaves over a written call log, with the merge
judge's decisions written by the fixture (`tinker_librarian_teacher_fixtures.py`). `sft_examples`
imports `teacher_sample`, which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import audit_decisions as D
import eval_admission as V
import sft_examples as X
import teacher_sample as T
from tinker_librarian_synth_fixtures import label_answer
from tinker_librarian_teacher_fixtures import (
    EVAL_KEEPER,
    absorbing_m2,
    record,
    request_lines,
    train_folder,
)

type JsonObject = dict[str, object]


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


class OnePassTest(unittest.TestCase):
    def test_every_example_is_in_one_step_and_a_step_holds_at_most_the_batch(self) -> None:
        for n, batch, sizes in ((10, 4, [4, 4, 2]), (8, 4, [4, 4]), (3, 4, [3]), (0, 4, [])):
            with self.subTest(n=n):
                steps = X.one_pass(n, batch, X.SEED)
                self.assertEqual([len(step) for step in steps], sizes)
                self.assertEqual(sorted(i for step in steps for i in step), list(range(n)))

    def test_the_order_comes_from_the_seed(self) -> None:
        once = [i for step in X.one_pass(40, 4, X.SEED) for i in step]
        self.assertEqual(once, [i for step in X.one_pass(40, 4, X.SEED) for i in step])
        self.assertNotEqual(once, list(range(40)))
        self.assertNotEqual(once, [i for step in X.one_pass(40, 4, X.SEED + 1) for i in step])


class EffortTest(unittest.TestCase):
    def test_the_named_efforts_are_tinkers_scalars(self) -> None:
        self.assertEqual(dict(X.EFFORTS), {"none": 0.0, "minimal": 0.1, "low": 0.2, "medium": 0.7, "high": 0.9,
                                           "xhigh": 0.99})


class ExamplesHashTest(unittest.TestCase):
    def test_the_hash_names_the_items_the_requests_the_answers_and_their_order(self) -> None:
        a, b = X.Example("train-a-00-001", "request a", "answer a"), X.Example("train-b-00-001", "request b", "answer b")
        lines = [f"{e.item_id} {sha256(e.request)} {sha256(e.answer)}\n" for e in (a, b)]
        self.assertEqual(X.examples_sha256((a, b)), sha256("".join(lines)))
        others = ((b, a), (a,), (X.Example("train-a-00-002", a.request, a.answer), b),
                  (X.Example(a.item_id, "another request", a.answer), b),
                  (X.Example(a.item_id, a.request, "another answer"), b))
        self.assertEqual(len({X.examples_sha256(examples) for examples in ((a, b), *others)}), 6)


class PlanTest(unittest.TestCase):
    """`plan` over the folder `train_folder` makes: five answers kept at once, one waiting answer
    whose absorbs are its label's (`labeled`), and one that also absorbs m2 (`off`), which the
    judge finds to lose knowledge."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.made = train_folder(Path(tmp.name))
        self.requests, self.teacher = self.made.requests, self.made.teacher

    def rewrite_summary(self, **changed: object) -> None:
        path = self.teacher / "summary.json"
        summary = cast(JsonObject, json.loads(path.read_text(encoding="utf-8")))
        path.write_text(json.dumps({**summary, **changed}), encoding="utf-8")

    def drop_from_summary(self, name: str) -> None:
        path = self.teacher / "summary.json"
        summary = cast(JsonObject, json.loads(path.read_text(encoding="utf-8")))
        path.write_text(json.dumps({key: value for key, value in summary.items() if key != name}), encoding="utf-8")

    def plan(self) -> X.Plan:
        return X.plan(self.requests, self.teacher)

    def test_the_examples_are_the_kept_answers_and_the_waiting_one_the_judge_found_mergeable(self) -> None:
        items = {item.item_id: item for item in V.synth_items(self.requests)}
        # `off` waits too: the judge's class for its absorb of m2 keeps it out.
        self.assertEqual([r["item"] for r in T.read_jsonl(self.teacher / T.PENDING)],
                         [self.made.labeled.item_id, self.made.off.item_id])
        self.assertEqual(list(self.plan().examples), [
            X.Example(req.item_id, items[req.item_id].text, label_answer(req))
            for req in (self.made.labeled, *self.made.kept)])

    def test_the_examples_go_in_one_pass_of_steps_of_the_batch(self) -> None:
        steps = self.plan().steps
        self.assertEqual(steps, X.one_pass(6, X.BATCH, X.SEED))
        self.assertEqual(([len(step) for step in steps], X.BATCH), ([4, 2], 4))

    def test_the_examples_are_rendered_at_the_scalar_of_the_effort_the_teacher_was_asked_at(self) -> None:
        self.assertEqual(self.plan().effort, 0.2)
        # The same requests sampled and planned while the pass lines ask for another effort.
        other = {**V.load_pass_lines(), "request": {"reasoning_effort": "medium", "max_tokens": 4096}}
        with mock.patch.object(V, "load_pass_lines", return_value=other), tempfile.TemporaryDirectory() as tmp:
            made = train_folder(Path(tmp))
            self.assertEqual(X.plan(made.requests, made.teacher).effort, 0.7)

    def test_answers_the_teacher_gave_under_other_request_settings_than_the_pass_lines_are_refused(self) -> None:
        effort, max_tokens = request_lines()
        for name, request in (("effort", {"reasoning_effort": "medium", "max_tokens": max_tokens}),
                              ("output budget", {"reasoning_effort": effort, "max_tokens": max_tokens // 2})):
            with (self.subTest(name), mock.patch.object(V, "load_pass_lines",
                                                        return_value={**V.load_pass_lines(), "request": request}),
                  self.assertRaisesRegex(SystemExit,
                                         "is not the teacher's logged reply to the request as it is asked now")):
                self.plan()

    def test_the_plan_records_the_sha256_of_what_it_read_and_of_its_examples(self) -> None:
        plan = self.plan()
        merges = self.teacher / T.MERGES
        lines = [f"{e.item_id} {sha256(e.request)} {sha256(e.answer)}\n" for e in plan.examples]
        self.assertEqual(plan.teacher, {
            "requests_sha256": V.sha256_file(self.requests),
            "audits_sha256": [V.sha256_file(self.requests.parent / "audit" / "audit.json")],
            "summary_sha256": V.sha256_file(self.teacher / "summary.json"),
            "calls_sha256": V.sha256_file(self.teacher / T.CALLS),
            "kept_sha256": V.sha256_file(self.teacher / T.KEPT),
            "pending_sha256": V.sha256_file(self.teacher / T.PENDING),
            "judge_files": json.loads((merges / D.JUDGE_FILES).read_text(encoding="utf-8")),
            "decisions_sha256": V.sha256_file(merges / D.JUDGE_DIR / D.DECISIONS),
            "requests": 7, "kept": 5, "merged": 1, "examples_sha256": sha256("".join(lines))})

    def test_accepted_jsonl_is_not_read(self) -> None:
        before = self.plan()
        T.write_jsonl(self.teacher / T.ACCEPTED, [record(self.made.off, absorbing_m2(self.made.off))])
        self.assertEqual(self.plan(), before)

    def test_a_teacher_run_that_did_not_ask_every_request_to_the_end_is_refused(self) -> None:
        unfinished: tuple[JsonObject, ...] = ({"stopped": "spent 1.0 + worst 0.1 > 1.0"}, {"http_errors": {"500": 1}})
        for changed in unfinished:
            with self.subTest(changed=changed):
                self.rewrite_summary(stopped=None, http_errors={})
                self.rewrite_summary(**changed)
                with self.assertRaisesRegex(SystemExit, "did not ask every request to the end"):
                    self.plan()
        for name in ("stopped", "http_errors"):
            with self.subTest(missing=name):
                self.rewrite_summary(stopped=None, http_errors={})
                self.drop_from_summary(name)
                with self.assertRaisesRegex(SystemExit, "did not ask every request to the end"):
                    self.plan()

    def test_a_teacher_run_that_names_no_label_audit_is_refused(self) -> None:
        self.rewrite_summary(audits_sha256=[])
        with self.assertRaisesRegex(SystemExit, "names no label audit"):
            self.plan()
        self.drop_from_summary("audits_sha256")
        with self.assertRaisesRegex(SystemExit, "names no label audit"):
            self.plan()

    def test_requests_other_than_the_sampled_ones_are_refused(self) -> None:
        self.requests.write_text(self.requests.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        with self.assertRaisesRegex(SystemExit, "other requests"):
            self.plan()

    def test_requests_that_share_an_item_id_are_refused(self) -> None:
        rows = self.requests.read_text(encoding="utf-8")
        self.requests.write_text(rows + rows.splitlines()[0] + "\n", encoding="utf-8")
        self.rewrite_summary(requests_sha256=D.file_sha256(self.requests))
        with self.assertRaisesRegex(SystemExit, "1 item IDs name more than one request"):
            self.plan()

    def test_requests_of_a_keeper_of_e_synth_are_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            made = train_folder(Path(tmp), last_keeper=EVAL_KEEPER)
            with self.assertRaisesRegex(SystemExit, r"E-synth Keepers \['docs-gardener'\]"):
                X.plan(made.requests, made.teacher)

    def test_an_answer_the_call_log_does_not_hold_is_refused(self) -> None:
        first, *rest = T.read_jsonl(self.teacher / T.KEPT)
        T.write_jsonl(self.teacher / T.KEPT, [{**first, "answer": cast(str, first["answer"]) + " "}, *rest])
        with self.assertRaisesRegex(SystemExit, "is not the teacher's logged reply to the request as it is asked now"):
            self.plan()

    def test_a_folder_without_an_accepted_answer_is_refused(self) -> None:
        T.write_jsonl(self.teacher / T.KEPT, [])
        T.write_jsonl(self.teacher / T.PENDING, [])
        with self.assertRaisesRegex(SystemExit, "holds no accepted answer"):
            self.plan()


if __name__ == "__main__":
    unittest.main()
