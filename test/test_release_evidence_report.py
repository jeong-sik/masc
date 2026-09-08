"""Render release reports with private captures outside the artifact directory.

Uses the shell script's actual renderer and synthetic captures, without a
server, lifecycle test run, or OCaml build.
"""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/release-evidence.sh"


class ReleaseEvidenceReport(unittest.TestCase):
    def test_external_scratch_leaves_a_self_contained_receipt(self):
        # Run the final heredoc verbatim, including its real Markdown template.
        renderer = SCRIPT.read_text().rsplit("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        with tempfile.TemporaryDirectory(prefix="masc-report-fixture-") as directory:
            root = Path(directory)
            scratch = root / "private-scratch"
            scratch.mkdir()
            output = root / "dist" / "release-evidence.md"

            def capture(name, payload):
                path = scratch / name
                path.write_text(json.dumps(payload), encoding="utf-8")
                return str(path)

            health = capture("health.json", {"version": "fixture-version"})
            tools = capture("tools.json", {"result": {"tools": [{"name": "fixture_tool"}]}})
            status = capture("status.json", {"result": {"content": [
                {"type": "text", "text": "isolated fixture workspace"}]}})
            briefing = capture("briefing.json", {"summary": []})
            snapshot = capture("snapshot.json", {"project": {}})
            initialize = capture("initialize.json", {"jsonrpc": "2.0", "result": {}})
            secret = "fixture-token-must-not-be-published"
            capture("dashboard-dev-token.json", {"token": secret})
            log = scratch / "server.log"
            log.write_text(secret, encoding="utf-8")
            source_sha = "a" * 40
            bundle_id = "b" * 64
            lifecycle = capture("bundle.json", {
                "schema": "masc.keeper_full_lifecycle_evidence.v1",
                "source_sha": source_sha,
                "bundle_id": bundle_id,
                "status": "passed",
                "passed_count": 14,
                "scenario_count": 14,
                "private_fixture_field": secret,
            })
            result = subprocess.run(
                [sys.executable, "-", str(output), "fixture-version", "dist/masc-fixture",
                 "/isolated-install/masc", "http://127.0.0.1:12345", "fixture-session",
                 "2025-11-25", health, tools, status, briefing, snapshot, initialize,
                 str(log), lifecycle],
                input=renderer, text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            shutil.rmtree(scratch)
            report = output.read_text(encoding="utf-8")
            self.assertIn(f"Source SHA: `{source_sha}`", report)
            self.assertIn(f"Correlation bundle: `{bundle_id}`", report)
            self.assertIn("Result: `passed` (14/14)", report)
            self.assertIn("were verified before this receipt was rendered", report)
            self.assertIn("removed on exit", report)
            self.assertIn("not release attachments", report)
            self.assertNotIn(secret, report)
            self.assertNotIn(str(scratch), report)
            self.assertNotIn("bundle.md", report)
            self.assertNotIn("bundle.json", report)
            self.assertEqual(list(output.parent.iterdir()), [output])

    def test_help_describes_private_captures(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"],
                                text=True, capture_output=True, check=True)
        self.assertIn("Only the Markdown report", result.stdout)
        self.assertIn("private temporary storage", result.stdout)
        self.assertNotIn("Raw files are written next to", result.stdout)


if __name__ == "__main__":
    unittest.main()
