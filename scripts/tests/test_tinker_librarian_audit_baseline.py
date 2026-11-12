# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for the base model's answers to requests pass_lines.json does not pin
(scripts/tinker/librarian/audit_baseline.py), which the blind label audit reads.

The request is invented and is not the pinned E-synth. `audit_baseline` imports the Tinker caller,
which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import dataclasses
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import audit_baseline as B
import e_synth_audit as A
import eval_admission as V
import synth_rows as RW
import synth_spec as S
import tinker_oai as O
from tinker_librarian_synth_fixtures import SCHEDULED, candidates_of, label_answer, request


class AuditBaselineTest(unittest.TestCase):
    """`run` over a call log that already holds the base model's calls. The budget is 0, so a call
    the log does not hold stops the run and nothing is sent."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        folder = Path(tmp.name)
        self.out = folder / "base"
        self.out.mkdir()
        self.req = dataclasses.replace(request(SCHEDULED, candidates_of((S.CandidateKind.CORRECTION,))),
                                       item_id="train-docs-gardener-00-001")
        self.requests = folder / "requests.jsonl"
        self.requests.write_text(json.dumps({"request": RW.row_of(self.req)}, ensure_ascii=False) + "\n",
                                 encoding="utf-8")
        [self.item] = V.synth_items(self.requests)
        lines = V.load_pass_lines()
        pinned, comparison = cast(dict[str, object], lines["request"]), cast(dict[str, object], lines["comparison"])
        self.effort, self.max_tokens = cast(str, pinned["reasoning_effort"]), cast(int, pinned["max_tokens"])
        self.name, self.model = cast(str, comparison["baseline"]), cast(str, comparison["baseline_model"])
        # The caller builds its client from the variable; a logged reply is returned before the client is used.
        env = mock.patch.dict(os.environ, {"TINKER_API_KEY": "not-a-key"})
        env.start()
        self.addCleanup(env.stop)

    def log(self, *, answered: bool) -> None:
        """Write the call log: the warm call of the one request and, when `answered`, its answer."""
        messages = [self.item.text, V.schema_instruction()]
        label = f"synth:{self.name}:{self.item.item_id}"
        calls = [O.Call(O.call_key(self.model, self.effort, V.WARM_MAX_TOKENS, 0, messages), label + ":warm",
                        O.HTTP_OK, "length", None, None, 10, 0, 1, 0.1, 1.0)]
        if answered:
            calls.append(O.Call(O.call_key(self.model, self.effort, self.max_tokens, 0, messages), label,
                                O.HTTP_OK, "stop", label_answer(self.req), None, 10, 0, 1, 0.1, 2.0))
        (self.out / "calls.jsonl").write_text(
            "".join(json.dumps(dataclasses.asdict(c), ensure_ascii=False) + "\n" for c in calls), encoding="utf-8")

    def summary(self) -> dict[str, object]:
        return cast(dict[str, object], json.loads((self.out / "summary.json").read_text(encoding="utf-8")))

    def test_requests_the_pass_lines_do_not_pin_are_answered_for_the_label_audit(self) -> None:
        self.assertNotEqual(V.sha256_file(self.requests),
                            cast(dict[str, object], V.load_pass_lines()["e_synth"])["requests_sha256"])
        self.log(answered=True)
        self.assertEqual(B.run(self.requests, self.out, 0.0), 0)
        summary = self.summary()
        self.assertEqual((summary["set"], summary["requests"], summary["answered"], summary["valid"],
                          summary["stopped"]), ("audit", 1, 1, 1, None))
        self.assertEqual(summary["targets"], {self.name: self.model})
        # The audit reads the answer under the item, as it reads a measured run's.
        answer = A.answers(self.out, self.name)[self.item.item_id]
        self.assertEqual(answer.answer(), label_answer(self.req))
        self.assertFalse((self.out / "rows.jsonl").exists())

    def test_a_request_the_log_holds_no_answer_for_stops_the_run(self) -> None:
        self.log(answered=False)
        self.assertEqual(B.run(self.requests, self.out, 0.0), 2)
        summary = self.summary()
        self.assertEqual((summary["answered"], summary["valid"]), (0, 0))
        self.assertIsNotNone(summary["stopped"])
        self.assertNotIn(self.item.item_id, A.answers(self.out, self.name))


if __name__ == "__main__":
    unittest.main()
