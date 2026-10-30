"""A no-op CLI exit must never become a scored baseline trial again."""
import json
from pathlib import Path
import tempfile
import unittest

from agents.kimi_code_agent import inspect_stream, KimiCodeProtocolError


class BaselineEvidence(unittest.TestCase):
    def inspect(self, text):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "cli.jsonl"
            path.write_text(text)
            return inspect_stream(path)

    def test_successful_process_with_notice_is_rejected(self):
        with self.assertRaises(json.JSONDecodeError):
            self.inspect("kimi-cli is no longer maintained.\n")

    def test_no_response_and_unfinished_tool_exchange_are_rejected(self):
        for messages in [[], [{"role": "assistant", "tool_calls": [{"id": "x"}]}],
                         [{"role": "tool", "content": "command output"}]]:
            with self.subTest(messages=messages), self.assertRaises(KimiCodeProtocolError):
                self.inspect("\n".join(json.dumps(m) for m in messages))

    def test_real_completed_exchange_keeps_execution_evidence(self):
        messages = [
            {"role": "meta", "type": "system.version", "version": "2.2.0"},
            {"role": "assistant", "tool_calls": [{"id": "x"}]},
            {"role": "tool", "tool_call_id": "x", "content": "wrote result"},
            {"role": "assistant", "content": "Done"},
            {"role": "meta", "type": "session.resume_hint", "session_id": "x"},
        ]
        evidence = self.inspect("\n".join(json.dumps(m) for m in messages))
        self.assertEqual(evidence, {"messages": 5, "assistant_messages": 2,
                                    "tool_calls": 1, "tool_results": 1})


if __name__ == "__main__":
    unittest.main()
