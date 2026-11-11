# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for scripts/tinker/librarian/tinker_oai.py: when the caller stops and what a rerun sends.

`_send` answers from a list of invented statuses, so nothing is sent.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import tinker_oai as T

HTTP_BAD_REQUEST = 400


class Scripted(T.Caller):
    """A caller whose attempts come from a list of statuses. It keeps the label of each attempt it sends."""

    def __init__(self, log: Path, statuses: list[int]) -> None:
        super().__init__(log, budget=10.0)
        self.statuses = statuses
        self.sent: list[str] = []

    def _send(self, key: str, label: str, model: str, messages: Sequence[str], effort: str,
              max_tokens: int) -> T.Call:
        self.sent.append(label)
        status = self.statuses.pop(0)
        if status == T.HTTP_OK:
            return T.Call(key, label, status, "stop", "{}", None, 10, 0, 1, 0.1, 1.0)
        return T.Call(key, label, status, None, None, None, 0, 0, 0, 0.1, 1.0)


class StopTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.log = Path(tmp.name) / "calls.jsonl"
        # The caller builds its client from the variable and the fake `_send` never uses the client.
        env = mock.patch.dict(os.environ, {"TINKER_API_KEY": "not-a-key"})
        env.start()
        self.addCleanup(env.stop)

    def ask(self, caller: T.Caller, text: str) -> T.Call | None:
        return caller.ask(model="m", label=text, messages=[text], effort="low", max_tokens=8)

    def test_http_402_stops_the_caller_and_nothing_more_is_sent(self) -> None:
        caller = Scripted(self.log, [T.HTTP_OK, T.HTTP_PAYMENT_REQUIRED])
        self.assertIsNotNone(self.ask(caller, "a"))
        self.assertIsNone(caller.stopped)
        self.assertIsNone(self.ask(caller, "b"))
        self.assertIn("402", caller.stopped or "")
        self.assertIsNone(self.ask(caller, "c"))
        self.assertEqual(caller.sent, ["a", "b"])
        self.assertEqual(len(self.log.read_text(encoding="utf-8").splitlines()), 2)

    def test_a_rerun_sends_the_refused_call_again_and_reuses_the_reply(self) -> None:
        first = Scripted(self.log, [T.HTTP_OK, T.HTTP_PAYMENT_REQUIRED])
        self.ask(first, "a")
        self.ask(first, "b")
        again = Scripted(self.log, [T.HTTP_OK])
        self.assertIsNone(again.stopped)
        replies = [self.ask(again, "a"), self.ask(again, "b")]
        self.assertEqual(again.sent, ["b"])
        self.assertEqual([r is not None and r.replied() for r in replies], [True, True])

    def test_another_refusal_is_the_calls_result_and_the_caller_goes_on(self) -> None:
        caller = Scripted(self.log, [HTTP_BAD_REQUEST, T.HTTP_OK])
        refused = self.ask(caller, "a")
        assert refused is not None
        self.assertEqual(refused.status, HTTP_BAD_REQUEST)
        self.assertIsNone(caller.stopped)
        self.assertIsNotNone(self.ask(caller, "b"))


if __name__ == "__main__":
    unittest.main()
