"""wait_for_keeper_turn in image/keeper_turn_wait.sh, against a fake docker and a fake mcp.

The wait ends a probe on the turn's own state (Keeper_chat_operation.state)
instead of only on the marker file. No container, server or provider is used.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

WAIT_SH = Path(__file__).resolve().parent / "keeper_turn_wait.sh"

FAKE_DOCKER = """#!/usr/bin/env bash
case "$1" in
  inspect)
    if [[ -f "$FAKE_DIR/dead" ]]; then echo false; else echo true; fi ;;
  exec)
    n=$(cat "$FAKE_DIR/exec_count" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$FAKE_DIR/exec_count"
    if [[ -f "$FAKE_DIR/marker_after" ]] && [[ "$n" -ge "$(cat "$FAKE_DIR/marker_after")" ]]; then
      exit 0
    fi
    exit 1 ;;
esac
"""

# One reply per line, in order; the last one repeats. FAIL makes the call fail.
DRIVER = """
set -u
source "$WAIT_SH"
NAME=probe-container KEEPER=bench-1 MARKER=/tmp/arm-k-keeper-was-here
sleep() { :; }
mcp() {
  local i total line
  i=$(cat "$FAKE_DIR/mcp_i" 2>/dev/null || echo 0)
  total=$(wc -l < "$FAKE_DIR/replies" | tr -d ' ')
  [[ "$i" -ge "$total" ]] && i=$((total - 1))
  line=$(sed -n "$((i + 1))p" "$FAKE_DIR/replies")
  echo $((i + 1)) > "$FAKE_DIR/mcp_i"
  printf '%s\\t%s\\n' "$2" "$3" >> "$FAKE_DIR/mcp_calls"
  [[ "$line" == FAIL ]] && return 1
  printf '%s' "$line"
}
wait_for_keeper_turn kmsg-abc123
"""


def state(name, **extra):
    return json.dumps({"operation_id": "kmsg-abc123", "state": name, **extra})


@unittest.skipUnless(shutil.which("jq") and shutil.which("bash"), "needs jq and bash")
class WaitForKeeperTurn(unittest.TestCase):
    def run_wait(self, replies, *, marker_after=None, dead=False, env=None):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / "bin").mkdir()
            docker = root / "bin" / "docker"
            docker.write_text(FAKE_DOCKER)
            docker.chmod(0o755)
            (root / "replies").write_text("\n".join(replies) + "\n")
            if marker_after is not None:
                (root / "marker_after").write_text(str(marker_after))
            if dead:
                (root / "dead").write_text("")
            run_env = {
                **os.environ,
                "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
                "FAKE_DIR": str(root),
                "WAIT_SH": str(WAIT_SH),
                **(env or {}),
            }
            done = subprocess.run(
                ["bash", "-c", DRIVER], env=run_env, capture_output=True, text=True, timeout=60
            )
            calls_file = root / "mcp_calls"
            calls = calls_file.read_text().splitlines() if calls_file.exists() else []
            return done.returncode, done.stderr, calls

    def test_a_failed_turn_ends_the_probe_at_once_with_its_detail(self):
        code, err, calls = self.run_wait(
            [state("Failed", failure_kind="attempt_rejected", failure_detail="no effort contract")]
        )
        self.assertEqual(code, 1)
        self.assertIn("STAGE_FAIL keeper-turn-Failed", err)
        self.assertIn("no effort contract", err)
        self.assertEqual(len(calls), 1)

    def test_the_status_call_names_the_keeper_and_the_operation(self):
        _, _, calls = self.run_wait([state("Failed")])
        tool, args = calls[0].split("\t", 1)
        self.assertEqual(tool, "masc_keeper_delegate_status")
        self.assertEqual(
            json.loads(args),
            {"target": {"kind": "keeper", "name": "bench-1"}, "operation_id": "kmsg-abc123"},
        )

    def test_a_cancelled_turn_ends_the_probe(self):
        code, err, _ = self.run_wait([state("Cancelled")])
        self.assertEqual(code, 1)
        self.assertIn("STAGE_FAIL keeper-turn-Cancelled", err)

    def test_queued_and_running_keep_waiting_until_the_marker_appears(self):
        code, err, calls = self.run_wait(
            [state("Queued"), state("Running"), state("Running")], marker_after=3
        )
        self.assertEqual(code, 0, err)
        self.assertEqual(len(calls), 2)

    def test_a_marker_that_is_already_there_needs_no_poll(self):
        code, _, calls = self.run_wait([state("Running")], marker_after=1)
        self.assertEqual(code, 0)
        self.assertEqual(calls, [])

    def test_succeeded_with_the_marker_passes(self):
        code, err, _ = self.run_wait([state("Succeeded")], marker_after=2)
        self.assertEqual(code, 0, err)

    def test_succeeded_without_the_marker_is_its_own_failure(self):
        code, err, calls = self.run_wait([state("Succeeded")])
        self.assertEqual(code, 1)
        self.assertIn("keeper-turn-Succeeded-without-marker", err)
        self.assertEqual(len(calls), 1)

    def test_a_state_the_probe_was_not_taught_ends_it_under_that_name(self):
        code, err, _ = self.run_wait([state("Paused")])
        self.assertEqual(code, 1)
        self.assertIn("keeper-turn-unknown-state Paused", err)

    def test_a_run_of_unreadable_polls_ends_the_probe_as_an_observation_failure(self):
        code, err, calls = self.run_wait(["FAIL"], env={"POLL_FAILURE_LIMIT": "3"})
        self.assertEqual(code, 1)
        self.assertIn("delegate_status-unreadable after 3 polls", err)
        self.assertNotIn("keeper-did-not-act", err)
        self.assertEqual(len(calls), 3)

    def test_an_answer_with_no_state_counts_as_unreadable(self):
        code, err, _ = self.run_wait(["{}"], env={"POLL_FAILURE_LIMIT": "2"})
        self.assertEqual(code, 1)
        self.assertIn("delegate_status-unreadable after 2 polls", err)

    def test_a_readable_poll_resets_the_unreadable_count(self):
        code, err, _ = self.run_wait(
            ["FAIL", "FAIL", state("Running"), "FAIL", "FAIL"],
            env={"POLL_FAILURE_LIMIT": "3", "WAIT_ROUNDS": "5"},
        )
        self.assertEqual(code, 2, err)

    def test_a_turn_still_running_when_the_rounds_end_returns_two(self):
        code, _, calls = self.run_wait([state("Running")], env={"WAIT_ROUNDS": "4"})
        self.assertEqual(code, 2)
        self.assertEqual(len(calls), 4)

    def test_a_dead_container_ends_the_probe_before_any_poll(self):
        code, err, calls = self.run_wait([state("Running")], dead=True)
        self.assertEqual(code, 1)
        self.assertIn("container-died", err)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
