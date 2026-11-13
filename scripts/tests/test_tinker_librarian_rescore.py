# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for `eval_admission.py rescore`: a finished run scored again from its call log under the
current pass lines, with no call sent.

A run here is made the way `run` makes one, by `run_item` over one E-synth request and
`run_summary`: on GLM through a fake endpoint, or on Tinker with every reply already in the call
log and a budget of 0, so a call the log does not hold stops the run. The pass lines are the
pinned ones with the request's output budget and the E-synth requests file of the test.
`eval_admission` imports the Tinker caller, which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import eval_admission as V
import glm_chat as G
import synth_rows as RW
import synth_spec as S
import tinker_oai as O
from tinker_librarian_synth_fixtures import (
    PLANTED,
    candidates_of,
    label_answer,
    request,
)

type JsonObject = dict[str, object]

# An output budget no module holds, so a key made with it was made from the pass lines the test gives.
MAX_TOKENS = 4321
EFFORT = "low"
TARGETS = [("a", "model-a"), ("b", "model-b")]


def completion(content: str) -> str:
    return json.dumps({"choices": [{"finish_reason": "stop", "message": {"content": content}}],
                       "usage": {"prompt_tokens": 10, "completion_tokens": 3}})


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class RescoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.folder = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.req = request(PLANTED, candidates_of((S.CandidateKind.CORRECTION, S.CandidateKind.TRANSIENT)))
        self.requests = self.folder / "requests.jsonl"
        self.requests.write_text(json.dumps({"request": RW.row_of(self.req)}, ensure_ascii=False) + "\n",
                                 encoding="utf-8")
        self.lines = self.pass_lines(MAX_TOKENS)
        self.template, [self.item] = V.set_items(self.lines, "synth", self.args())

    def pass_lines(self, max_tokens: int) -> JsonObject:
        pinned = V.load_pass_lines()
        return {**pinned, "request": {"reasoning_effort": EFFORT, "max_tokens": max_tokens},
                "e_synth": {**cast(JsonObject, pinned["e_synth"]), "requests_sha256": sha256(self.requests)}}

    def args(self, run: Path | None = None, out: Path | None = None) -> argparse.Namespace:
        return argparse.Namespace(run=str(run), out=str(out), requests=str(self.requests), base=None, template=None)

    def write_run(self, lane: V.Lane, run: Path) -> Path:
        """<run>/rows.jsonl and summary.json as `run` writes them, beside the lane's call log."""
        rows = V.run_item(lane, TARGETS, self.item)
        (run / "rows.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows),
                                        encoding="utf-8")
        summary = V.run_summary("synth", self.template, TARGETS, lane, rows)
        (run / "summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
        return run

    def glm_run(self, name: str = "glm") -> Path:
        run = self.folder / name
        run.mkdir()
        answers = [(200, completion(label_answer(self.req))) for _ in TARGETS]
        replies = iter(answers)
        lane = V.GlmLane(G.Caller(run / "calls.jsonl", 10, lambda _: next(replies), lambda _: None), MAX_TOKENS)
        return self.write_run(lane, run)

    def tinker_run(self) -> Path:
        """Every warm and measured call is logged before the run, under the key the Tinker caller asks."""
        run = self.folder / "tinker"
        run.mkdir()
        messages = [self.item.text, V.schema_instruction()]
        calls = [O.Call(O.call_key(model, EFFORT, budget, 0, messages), name, O.HTTP_OK, "stop",
                        label_answer(self.req), None, 10, 9, 3, 0.5, 1_700_000_000.0 + n)
                 for n, (name, model) in enumerate(TARGETS)
                 for budget in (V.WARM_MAX_TOKENS, MAX_TOKENS)]
        (run / "calls.jsonl").write_text("".join(json.dumps(dataclasses.asdict(c)) + "\n" for c in calls),
                                         encoding="utf-8")
        with mock.patch.dict(os.environ, {"TINKER_API_KEY": "not-a-key"}):
            lane = V.TinkerLane(O.Caller(run / "calls.jsonl", 0.0), EFFORT, MAX_TOKENS)
        return self.write_run(lane, run)

    def rescore(self, run: Path, out: Path, lines: JsonObject | None = None) -> JsonObject:
        with (mock.patch.object(V, "load_pass_lines", return_value=lines or self.lines),
              contextlib.redirect_stdout(io.StringIO())):
            self.assertEqual(V.rescore(self.args(run, out)), 0)
        return cast(JsonObject, json.loads((out / "summary.json").read_text(encoding="utf-8")))

    def test_a_run_scored_again_under_its_own_pass_lines_keeps_its_rows(self) -> None:
        for run in (self.glm_run(), self.tinker_run()):
            with self.subTest(run=run.name):
                out = self.folder / f"{run.name}-again"
                summary = self.rescore(run, out)
                before = cast(JsonObject, json.loads((run / "summary.json").read_text(encoding="utf-8")))
                self.assertEqual(V.read_rows(out), V.read_rows(run))
                self.assertEqual((out / "calls.jsonl").read_bytes(), (run / "calls.jsonl").read_bytes())
                self.assertEqual({k: v for k, v in summary.items() if k != "rescored_from"}, before)
                self.assertEqual(summary["rescored_from"], {
                    "run": str(run), "pass_lines_sha256": before["pass_lines_sha256"],
                    "rows_sha256": sha256(run / "rows.jsonl"), "calls_sha256": sha256(run / "calls.jsonl")})

    def test_each_answer_is_checked_and_scored_again_and_the_call_stays_as_logged(self) -> None:
        refused = V.Check(None, ("refused",))
        with mock.patch.object(V, "check", return_value=refused):
            run = self.glm_run()
        self.assertEqual([r["valid"] for r in V.read_rows(run)], [False, False])
        self.rescore(run, self.folder / "again")
        old, new = V.read_rows(run), V.read_rows(self.folder / "again")
        self.assertEqual([(r["valid"], r["state_correct"]) for r in new], [(True, 2), (True, 2)])
        logged = ("target", "call_key", "status", "finish", "sent_at", "wall_s", "cost_usd", "completion_tokens")
        self.assertEqual([[r[k] for k in logged] for r in new], [[r[k] for k in logged] for r in old])

    def test_a_call_the_current_pass_lines_would_not_send_is_refused(self) -> None:
        run = self.glm_run()
        why = "the call log holds no call sent when the row says under the key the current pass lines give"
        with self.subTest("another output budget"), self.assertRaisesRegex(SystemExit, why):
            self.rescore(run, self.folder / "budget", self.pass_lines(MAX_TOKENS + 1))
        rows = V.read_rows(run)
        (run / "rows.jsonl").write_text("".join(json.dumps({**r, "sent_at": cast(float, r["sent_at"]) + 1}) + "\n"
                                                for r in rows), encoding="utf-8")
        with self.subTest("another send time"), self.assertRaisesRegex(SystemExit, why):
            self.rescore(run, self.folder / "time")

    def test_a_run_it_cannot_score_again_is_refused_before_anything_is_written(self) -> None:
        run = self.glm_run()
        summary = cast(JsonObject, json.loads((run / "summary.json").read_text(encoding="utf-8")))
        cases: tuple[tuple[str, JsonObject, str], ...] = (
            ("another template", {**summary, "template_sha256": "0" * 64}, "drew its prompts with another template"),
            ("another provider", {**summary, "provider": "other"}, "is not one `run` makes"),
            ("another target", {**summary, "targets": {"a": "model-a"}}, "names an item or a target"))
        for name, changed, why in cases:
            (run / "summary.json").write_text(json.dumps(changed), encoding="utf-8")
            out = self.folder / name
            with self.subTest(name), self.assertRaisesRegex(SystemExit, why):
                self.rescore(run, out)
            self.assertFalse(out.exists())
        with self.subTest("an existing folder"), self.assertRaisesRegex(SystemExit, "exists"):
            self.rescore(run, self.folder)


if __name__ == "__main__":
    unittest.main()
