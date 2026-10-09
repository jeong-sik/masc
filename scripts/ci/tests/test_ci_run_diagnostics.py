"""Exercise the real observer with synthetic process data, never host argv."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


OBSERVER = Path(__file__).resolve().parents[2] / "ci-run-tests.sh"
SECRET = "SYNTHETIC_CI_DIAGNOSTIC_SECRET"
FAKE_PS = r'''
import json
import os
from pathlib import Path
import sys

with open(os.environ["CI_DIAG_PS_CALLS"], "a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\n")
if len(sys.argv) != 3 or sys.argv[1] not in ("-eo", "-axo"):
    raise SystemExit("unexpected fixture ps request")
columns = sys.argv[2].split(",")
fields = [column.removesuffix("=") for column in columns]
pid_file = Path(os.environ["CI_DIAG_COMMAND_PID"])
active_pid = pid_file.read_text().strip() if pid_file.exists() else "42001"
rows = []
for pid, comm in ((active_pid, "test_grep_worker"), ("42002", "grep"), ("42003", "curl"), ("42004", "runner")):
    rows.append({"pid": pid, "ppid": "1", "pgid": pid, "etime": "00:42",
                 "%cpu": "1.2", "%mem": "0.3", "comm": comm,
                 "args": comm + " --token=SYNTHETIC_CI_DIAGNOSTIC_SECRET" + (" --mode=grep-worker" if comm == "runner" else ""),
                 "command": comm + " --token=SYNTHETIC_CI_DIAGNOSTIC_SECRET"})
if not all(column.endswith("=") for column in columns):
    print(" ".join(fields))
for row in rows:
    print(" ".join(row[field] for field in fields))
if "%cpu" in fields and all(column.endswith("=") for column in columns):
    Path(os.environ["CI_DIAG_TREE_CAPTURED"]).touch()
'''


class CiRunDiagnostics(unittest.TestCase):
    def observe_failure(self, active=False):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            fake_ps = bin_dir / "ps"
            fake_ps.write_text(f"#!{sys.executable}\n" + FAKE_PS)
            fake_ps.chmod(0o755)
            fake_df = bin_dir / "df"
            fake_df.write_text("#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 100 99 1 99%% /\\n'\n")
            fake_df.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                       CI_DIAG_PS_CALLS=str(root / "ps-calls.jsonl"),
                       CI_DIAG_COMMAND_PID=str(root / "command.pid"),
                       CI_DIAG_TREE_CAPTURED=str(root / "tree-captured"),
                       CI_TEST_LOG_FILE=str(root / "test.log"),
                       CI_TEST_HEARTBEAT_SEC="1", CI_TEST_TIMEOUT_SEC="0",
                       CI_TEST_DISK_MIN_AVAILABLE_MB="2" if active else "0",
                       CI_TEST_DISK_CHECK_SEC="1", CI_CONTRACT_HARNESS_ENABLED="0",
                       DUNE_BUILD_DIR=str(root / "no-build"), DUNE_SOURCEROOT=str(root))
            command = 'exit 23'
            if active:
                command = ('printf "%s" "$$" > "$CI_DIAG_COMMAND_PID"; '
                           'for attempt in {1..50}; do '
                           '[[ -f "$CI_DIAG_TREE_CAPTURED" ]] && break; sleep 0.1; done; exit 23')
            result = subprocess.run(["bash", str(OBSERVER), command], cwd=root,
                                    env=env, text=True, capture_output=True, timeout=20)
            calls = [json.loads(line) for line in (root / "ps-calls.jsonl").read_text().splitlines()]
            return result, calls, (root / "tree-captured").exists()

    def assert_safe_snapshots(self, result, calls):
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertIn("reason=nonzero_exit_23", result.stdout)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        allowed = {"pid", "ppid", "pgid", "etime", "%cpu", "%mem", "comm"}
        for _, columns in calls:
            self.assertLessEqual({column.removesuffix("=") for column in columns.split(",")}, allowed)

    def test_nonzero_snapshot_omits_arguments_and_keeps_grep_processes(self):
        result, calls, _ = self.observe_failure()
        self.assert_safe_snapshots(result, calls)
        filtered, global_snapshot = result.stdout.split("[ci-diag] global process snapshot:", 1)
        self.assertIn("test_grep_worker", filtered)
        for comm in ("test_grep_worker", "grep", "curl", "runner"):
            self.assertIn("00:42 1.2 0.3 " + comm, global_snapshot)

    def test_active_tree_snapshot_omits_arguments(self):
        result, calls, captured = self.observe_failure(active=True)
        self.assert_safe_snapshots(result, calls)
        self.assertTrue(captured)
        self.assertIn("reason=disk_pressure_observed", result.stdout)
        tree = result.stdout.split("[ci-diag] active command process tree snapshot:", 1)[1]
        self.assertIn("00:42 1.2 0.3 test_grep_worker", tree)


if __name__ == "__main__":
    unittest.main()
