"""A coding episode whose Keeper admission fails still leaves an evidence row.

run_one declares `workspace` as a local and assigns it only after the Keeper is
admitted. Bash 5 aborts at the first `${workspace}` under `set -u` when the
local was never assigned, so an episode that failed before it copied the case
workspace in wrote no row at all. This test sources the production script and
calls the production run_one; only the MCP and HTTP boundaries are replaced.
"""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "harness_coding_eval.sh"
REFUSAL = "controlled keeper_up refusal"


@unittest.skipUnless(shutil.which("jq") and shutil.which("curl"), "the eval script needs jq and curl")
class AdmissionFailureRow(unittest.TestCase):
    def run_failed_admission(self, root, *, stale_workspace):
        cases = root / "cases"
        case = cases / "admission-case"
        (case / "workspace").mkdir(parents=True)
        (case / "case.json").write_text(json.dumps({
            "id": "admission-case", "timeout_sec": 5, "verify": "verify.sh",
            "prompt": "Fix the failing check.",
        }))
        (case / "workspace" / "check.sh").write_text("exit 0\n")
        # Grading runs this script. It leaves a marker so the test can tell.
        (case / "verify.sh").write_text('touch "$1/graded.marker"\nexit 0\n')
        out, target, config = root / "out", root / "target", root / "config"
        keeper = "coding-eval-provider-model-admission-case-r1"
        stale = target / ".masc" / "playground" / "docker" / keeper / "workspace"
        if stale_workspace:
            stale.mkdir(parents=True)
        wrapper = root / "wrapper.sh"
        wrapper.write_text(f'''
source "{SCRIPT}"
CONFIG_DIR="{config}"
TARGET_DIR="{target}"
call_mcp_tool() {{ LAST_TOOL_ERROR="{REFUSAL}"; return 1; }}
stop_keeper_best_effort() {{ :; }}
curl() {{ return 22; }}
run_one provider model "{case}" 1
''')
        result = subprocess.run(
            ["bash", str(wrapper)], capture_output=True, text=True, timeout=120,
            env={
                "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
                "HOME": str(root),
                "CODING_EVAL_MODELS": "provider:model",
                "CODING_EVAL_CASES_DIR": str(cases),
                "CODING_EVAL_OUT_DIR": str(out),
                "CODING_EVAL_MEMORY_MODE": "off",
            })
        return result, out, stale

    def assert_failed_admission_row(self, result, out, stale):
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [json.loads(line) for line in (out / "runs.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 1, rows)
        row = rows[0]
        self.assertEqual(row["status"], "transport_error")
        self.assertIn(REFUSAL, row["error"])
        # Nothing was verified, edited or built by this episode.
        for field in ("verify_exit", "regression_exit", "edited_source_files",
                      "edited_target_files", "build_exit"):
            self.assertIsNone(row[field], field)
        self.assertFalse(row["passed"])
        self.assertFalse((stale / "graded.marker").exists(), "a workspace this episode did not prepare was graded")

    def test_failed_admission_without_a_workspace_writes_its_row(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assert_failed_admission_row(
                *self.run_failed_admission(Path(temporary).resolve(), stale_workspace=False))

    def test_failed_admission_does_not_grade_a_leftover_workspace(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assert_failed_admission_row(
                *self.run_failed_admission(Path(temporary).resolve(), stale_workspace=True))


if __name__ == "__main__":
    unittest.main()
