"""run_one keeps one honest evidence row per episode, whatever the server says.

Two ways an episode used to lose or misstate its row:

- run_one declares `workspace` as a local and assigns it only after the Keeper
  is admitted. Bash 5 aborts at the first `${workspace}` under `set -u` when
  the local was never assigned, so an episode that failed before it copied the
  case workspace in wrote no row.
- The status poll settled the admitted request on any response whose `state`
  was terminal, without checking which operation the response described.

The tests source the production script and call the production run_one; only
the MCP and HTTP boundaries are replaced.
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
ADMITTED = "kmsg-accepted"
RUN_ID = "provider-model-admission-case-r1"


class Episode:
    """One run_one call against a throwaway corpus and output directory."""

    def __init__(self, root, *, up_refused=False, status=None, stale_workspace=False):
        self.root = root
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
        self.out = root / "out"
        self.run_dir = self.out / "runs" / RUN_ID
        target, config = root / "target", root / "config"
        keeper = f"coding-eval-{RUN_ID}"
        self.workspace = target / ".masc" / "playground" / "docker" / keeper / "workspace"
        if stale_workspace:
            self.workspace.mkdir(parents=True)
        up = "return 1" if up_refused else "MOCK_RESULT='{}'"
        status_payload = "" if status is None else status
        wrapper = root / "wrapper.sh"
        wrapper.write_text(f'''
source "{SCRIPT}"
CONFIG_DIR="{config}"
TARGET_DIR="{target}"
call_mcp_tool() {{
  case "$2" in
    masc_keeper_up) LAST_TOOL_ERROR="{REFUSAL}"; {up} ;;
    masc_keeper_msg) MOCK_RESULT='{{"operation_id":"{ADMITTED}","state":"Queued"}}' ;;
    masc_keeper_delegate_status) MOCK_RESULT=$(cat "{root}/status.json") ;;
  esac
  return 0
}}
tool_result_json() {{ printf '%s' "$MOCK_RESULT"; }}
stop_keeper_best_effort() {{ :; }}
curl() {{ return 0; }}
run_one provider model "{case}" 1
''')
        (root / "status.json").write_text(status_payload)
        self.result = subprocess.run(
            ["bash", str(wrapper)], capture_output=True, text=True, timeout=120,
            env={
                "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
                "HOME": str(root),
                "CODING_EVAL_MODELS": "provider:model",
                "CODING_EVAL_CASES_DIR": str(cases),
                "CODING_EVAL_OUT_DIR": str(self.out),
                "CODING_EVAL_MEMORY_MODE": "off",
                "CODING_EVAL_POLL_INTERVAL_SEC": "0",
            })

    def row(self):
        if self.result.returncode != 0:
            raise AssertionError(f"run_one aborted: {self.result.stderr}")
        rows = [json.loads(line) for line in (self.out / "runs.jsonl").read_text().splitlines()]
        if len(rows) != 1:
            raise AssertionError(rows)
        return rows[0]


@unittest.skipUnless(shutil.which("jq") and shutil.which("curl"), "the eval script needs jq and curl")
class AdmissionFailureRow(unittest.TestCase):
    def assert_failed_admission_row(self, episode):
        row = episode.row()
        self.assertEqual(row["status"], "transport_error")
        self.assertIn(REFUSAL, row["error"])
        # Nothing was verified, edited or built by this episode.
        for field in ("verify_exit", "regression_exit", "edited_source_files",
                      "edited_target_files", "build_exit"):
            self.assertIsNone(row[field], field)
        self.assertFalse(row["passed"])
        self.assertFalse((episode.workspace / "graded.marker").exists(),
                         "a workspace this episode did not prepare was graded")

    def test_failed_admission_without_a_workspace_writes_its_row(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assert_failed_admission_row(Episode(Path(temporary).resolve(), up_refused=True))

    def test_failed_admission_does_not_grade_a_leftover_workspace(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assert_failed_admission_row(
                Episode(Path(temporary).resolve(), up_refused=True, stale_workspace=True))


@unittest.skipUnless(shutil.which("jq") and shutil.which("curl"), "the eval script needs jq and curl")
class StatusIdentity(unittest.TestCase):
    def episode(self, status):
        with tempfile.TemporaryDirectory() as temporary:
            episode = Episode(Path(temporary).resolve(), status=status)
            row = episode.row()
            mismatch = episode.run_dir / "operation-status-mismatch.json"
            return row, mismatch.read_text() if mismatch.exists() else None

    def assert_refused_status(self, status, named):
        row, kept = self.episode(status)
        self.assertEqual(row["status"], "transport_error")
        self.assertFalse(row["passed"])
        self.assertIn(f"named '{named}', not the admitted '{ADMITTED}'", row["error"])
        # The response that did not settle the episode stays for the reader.
        self.assertEqual(kept, status)
        # The prepared workspace is still verified as a diagnostic.
        self.assertEqual(row["verify_exit"], 0)

    def test_a_status_for_another_operation_does_not_settle_the_request(self):
        self.assert_refused_status('{"operation_id":"kmsg-other","state":"Succeeded"}', "kmsg-other")

    def test_a_status_without_an_operation_id_does_not_settle_the_request(self):
        self.assert_refused_status('{"state":"Succeeded"}', "<none>")

    def test_a_malformed_status_does_not_settle_the_request(self):
        self.assert_refused_status("not json", "<none>")

    def test_the_admitted_operation_that_succeeded_passes(self):
        row, kept = self.episode(json.dumps({"operation_id": ADMITTED, "state": "Succeeded"}))
        self.assertEqual((row["status"], row["verify_exit"], row["passed"]), ("ok", 0, True))
        self.assertIsNone(kept)

    def test_the_admitted_operation_that_failed_is_a_provider_error(self):
        row, kept = self.episode(json.dumps({
            "operation_id": ADMITTED, "state": "Failed",
            "failure_kind": "provider_error", "failure_detail": "model refused"}))
        self.assertEqual((row["status"], row["passed"]), ("provider_error", False))
        self.assertIn("Failed: provider_error: model refused", row["error"])
        self.assertIsNone(kept)


if __name__ == "__main__":
    unittest.main()
