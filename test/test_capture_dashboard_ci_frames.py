"""Recorded PTY evidence survives full GitHub logs without accepting commands."""
import importlib.util
import json
from pathlib import Path
import unittest

SOURCE_MODULES = ("scripts/capture-dashboard-ci-frames.py",)

spec = importlib.util.spec_from_file_location(
    "dashboard_ci_frames",
    Path(__file__).resolve().parents[1] / SOURCE_MODULES[0],
)
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)


def github_line(payload):
    return "test suite\tTest\t2026-09-30T00:00:00.0000000Z " + payload


class EvidenceRecords(unittest.TestCase):
    def test_plain_and_github_frames_ignore_echoed_commands(self):
        record = {"name": "wide", "columns": 140, "rows": 42}
        frame = "STUDIO_CAPTURE=" + json.dumps(record)
        echoed = github_line("if ! rg -q 'STUDIO_CAPTURE=' \"$STUDIO_LOG\"; then")
        log = "\n".join([echoed, frame, github_line(frame)])
        self.assertEqual(replay.captures(log), [record, record])

    def test_malformed_frame_records_fail_in_both_transports(self):
        for record in ("STUDIO_CAPTURE={broken", "STUDIO_CAPTURE=not-json"):
            for line in (record, github_line(record)):
                with self.subTest(line=line), self.assertRaises(json.JSONDecodeError):
                    replay.captures(line)

    def test_binary_hashes_ignore_echoed_source_and_commands(self):
        digest = "a" * 64
        log = "\n".join([
            github_line('print("STUDIO_BINARY_SHA256=" + digest)'),
            'printf "STUDIO_BINARY_SHA256=%s\\n" "$digest"',
            "STUDIO_BINARY_SHA256=" + digest,
            github_line("STUDIO_BINARY_SHA256=" + digest.upper()),
        ])
        self.assertEqual(replay.binary_hashes(log), {digest})

    def test_malformed_binary_records_fail_in_both_transports(self):
        for value in ("abc", "z" * 64, "a" * 64 + " extra"):
            record = "STUDIO_BINARY_SHA256=" + value
            for line in (record, github_line(record)):
                with self.subTest(line=line), self.assertRaises(ValueError):
                    replay.binary_hashes(line)


if __name__ == "__main__":
    unittest.main()
