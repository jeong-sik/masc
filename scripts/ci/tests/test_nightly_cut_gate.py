"""Exercise the RC nightly gate against stubbed gh responses.

The gate is plain logic over three gh api reads (workflow runs, compare
ancestry, failed jobs); each scenario here serves its own fixture and
checks the verdict the release lane would print.
"""

import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2]
GATE = SCRIPTS / "ci/nightly_cut_gate.py"

NIGHTLY = {
    "id": 42667421470,
    "head_sha": "343ddda32ce8ddca6e432cb940d597d67cffc8a7",
    "event": "schedule",
    "status": "completed",
    "conclusion": "failure",
    "created_at": "2026-11-09T17:43:39Z",
}
CUT_SHA = "5a8e1e760123456789abcdef0123456789abcdef"
# An older scheduled nightly that is a strict ancestor of the cut and
# ended green — the run the gate must NOT fall back to past a newer red.
OLDER_GREEN = dict(NIGHTLY, id=42600000000, head_sha="b" * 40,
                   conclusion="success", created_at="2026-11-08T17:43:39Z")

FAKE_GH = """#!/usr/bin/env python3
\"\"\"A stub gh that serves the scenario fixtures named in the environment.\"\"\"
import json
import os
import re
import sys
from pathlib import Path

args = sys.argv[1:]
if not args or args[0] != "api":
    sys.stderr.write("fake gh: only 'gh api' is supported: " + " ".join(args) + "\\n")
    raise SystemExit(70)
path = args[1]
if "actions/workflows/test.yml/runs" in path:
    sys.stdout.write(Path(os.environ["FAKE_RUNS_JSON"]).read_text())
elif re.search(r"/compare/", path):
    overrides = {}
    if os.environ.get("FAKE_COMPARE_BY_SHA"):
        overrides = json.loads(
            Path(os.environ["FAKE_COMPARE_BY_SHA"]).read_text())
    head = path.split("/compare/", 1)[1].split("...", 1)[0]
    sys.stdout.write(json.dumps({
        "status": overrides.get(
            head, os.environ.get("FAKE_COMPARE_STATUS", "diverged"))}) + "\\n")
elif re.search(r"/actions/runs/\\d+/jobs$", path):
    fixture = os.environ.get("FAKE_JOBS_JSON")
    sys.stdout.write(Path(fixture).read_text() if fixture else '{"jobs": []}')
else:
    sys.stderr.write("fake gh: unexpected call: " + " ".join(args) + "\\n")
    raise SystemExit(70)
"""


class NightlyCutGate(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="masc-nightly-gate-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "gh"
        fake.write_text(FAKE_GH)
        fake.chmod(fake.stat().st_mode
                   | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.baseline = self.root / "nightly_baseline.json"

    def run_gate(self, *, runs, compare="ahead", compare_by_sha=None,
                 jobs=None, baseline=None):
        runs_file = self.root / "runs.json"
        runs_file.write_text(json.dumps({"workflow_runs": runs}))
        env = {**os.environ,
               "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
               "FAKE_RUNS_JSON": str(runs_file),
               "FAKE_COMPARE_STATUS": compare,
               "GH_TOKEN": "test-token",
               "GITHUB_SHA": CUT_SHA}
        if compare_by_sha is not None:
            by_sha = self.root / "compare_by_sha.json"
            by_sha.write_text(json.dumps(compare_by_sha))
            env["FAKE_COMPARE_BY_SHA"] = str(by_sha)
        if jobs is not None:
            jobs_file = self.root / "jobs.json"
            jobs_file.write_text(json.dumps({"jobs": jobs}))
            env["FAKE_JOBS_JSON"] = str(jobs_file)
        if baseline is not None:
            self.baseline.write_text(json.dumps(baseline))
        return subprocess.run(
            [sys.executable, str(GATE), "--repo", "test/masc",
             "--baseline", str(self.baseline)],
            env=env, text=True, capture_output=True, timeout=30,
        )

    def test_red_ancestor_without_waiver_refuses_and_names_the_run(self):
        result = self.run_gate(runs=[NIGHTLY])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("REFUSED", result.stderr)
        self.assertIn("42667421470", result.stderr)

    def test_recorded_waiver_passes_and_says_so(self):
        result = self.run_gate(
            runs=[NIGHTLY],
            baseline={"schema_version": 1, "allowed_failure_runs": [
                {"run_id": 42667421470, "head_sha": NIGHTLY["head_sha"],
                 "recorded_by": "release owner",
                 "reviewed_failure": "test_setup_cli muse deadline boundary"}]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("explicitly waived", result.stdout)
        self.assertIn("42667421470", result.stdout)

    def test_baseline_head_mismatch_refuses(self):
        result = self.run_gate(
            runs=[NIGHTLY],
            baseline={"schema_version": 1, "allowed_failure_runs": [
                {"run_id": 42667421470, "head_sha": "a" * 40}]})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refresh the baseline", result.stderr)

    def test_green_ancestor_passes(self):
        result = self.run_gate(runs=[dict(NIGHTLY, conclusion="success")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nightly green", result.stdout)

    def test_running_ancestor_refuses(self):
        result = self.run_gate(
            runs=[dict(NIGHTLY, status="in_progress", conclusion=None)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("in_progress", result.stderr)

    def test_running_ancestor_with_recorded_waiver_passes(self):
        # The refusal message promises the baseline as the recorded way to
        # cut over an unread nightly, so a recorded in-progress run must
        # pass before any verdict exists (CR P3, PR #50784).
        result = self.run_gate(
            runs=[dict(NIGHTLY, status="in_progress", conclusion=None)],
            baseline={"schema_version": 1, "allowed_failure_runs": [
                {"run_id": 42667421470, "head_sha": NIGHTLY["head_sha"],
                 "recorded_by": "release owner",
                 "reviewed_failure": "nightly still running at cut time"}]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("recorded in the baseline", result.stdout)
        self.assertIn("unread nightly", result.stdout)

    def test_no_ancestor_refuses(self):
        result = self.run_gate(runs=[NIGHTLY], compare="diverged")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no scheduled nightly", result.stderr)

    def test_identical_red_outranks_older_green_ancestor(self):
        # The cut head equals the newest nightly's head, so compare answers
        # "identical" for it and "ahead" for the older green run below it.
        # The verdict the cut sits on is the red one; the older green must
        # not speak for it (CR P2, PR #50784).
        result = self.run_gate(
            runs=[NIGHTLY, OLDER_GREEN],
            compare_by_sha={NIGHTLY["head_sha"]: "identical"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("REFUSED", result.stderr)
        self.assertIn("42667421470", result.stderr)

    def test_identical_green_passes_without_an_ancestor(self):
        result = self.run_gate(
            runs=[dict(NIGHTLY, conclusion="success")],
            compare_by_sha={NIGHTLY["head_sha"]: "identical"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nightly green", result.stdout)

    def test_failed_jobs_are_listed_for_the_release_owner(self):
        jobs = [{"name": "test suite", "conclusion": "failure",
                 "steps": [{"name": "Test", "conclusion": "failure"}],
                 "html_url": "https://example.invalid/job/1"}]
        result = self.run_gate(runs=[NIGHTLY], jobs=jobs)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nightly failures this cut would ride past", result.stdout)
        self.assertIn("test suite", result.stdout)
        self.assertIn("(Test)", result.stdout)


if __name__ == "__main__":
    unittest.main()
