#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "goal_loop_scheduler.py"

spec = importlib.util.spec_from_file_location("goal_loop_scheduler", SCRIPT_PATH)
assert spec is not None
goal_loop_scheduler = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = goal_loop_scheduler
spec.loader.exec_module(goal_loop_scheduler)


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat()


def no_command_config() -> dict[str, object]:
    return {"schema_version": 1, "phases": {}}


class GoalLoopSchedulerTest(unittest.TestCase):
    def test_select_due_phases_uses_prompt_cadences(self) -> None:
        now = datetime(2026, 5, 6, 0, 0, 0, tzinfo=timezone.utc)
        configs = goal_loop_scheduler.phase_configs(no_command_config())
        state = goal_loop_scheduler.normalize_state({}, configs, now)
        state["phases"]["observe"]["last_completed_at"] = iso(
            now - timedelta(seconds=4)
        )
        state["phases"]["orient"]["last_completed_at"] = iso(
            now - timedelta(seconds=60)
        )
        state["phases"]["decide"]["last_completed_at"] = iso(
            now - timedelta(seconds=3599)
        )
        state["phases"]["act"]["last_completed_at"] = iso(
            now - timedelta(seconds=86400)
        )
        state["phases"]["verify"]["last_completed_at"] = iso(
            now - timedelta(seconds=300)
        )

        due = goal_loop_scheduler.select_due_phases(state, configs, now)

        self.assertEqual([item.name for item in due], ["orient", "act", "verify"])
        self.assertEqual([item.reason for item in due], ["cadence_due"] * 3)
        self.assertEqual(due[0].cadence_seconds, 60)
        self.assertEqual(due[1].cadence_seconds, 86400)
        self.assertEqual(due[2].cadence_seconds, 300)

    def test_missed_deadline_is_visible_in_scheduler_state(self) -> None:
        now = datetime(2026, 5, 6, 0, 10, 0, tzinfo=timezone.utc)
        configs = goal_loop_scheduler.phase_configs(no_command_config())
        state = goal_loop_scheduler.normalize_state({}, configs, now)
        state["phases"]["orient"]["last_completed_at"] = iso(
            now - timedelta(seconds=120)
        )

        due = goal_loop_scheduler.select_due_phases(state, configs, now)
        orient_due = next(item for item in due if item.name == "orient")
        goal_loop_scheduler.update_phase_state(
            state,
            configs["orient"],
            orient_due,
            None,
            now,
        )

        self.assertEqual(orient_due.reason, "missed_deadline")
        self.assertEqual(orient_due.lateness_seconds, 60)
        self.assertTrue(state["phases"]["orient"]["missed_deadline"])

    def test_verify_fail_reenters_observe_before_observe_cadence(self) -> None:
        now = datetime(2026, 5, 6, 0, 0, 0, tzinfo=timezone.utc)
        configs = goal_loop_scheduler.phase_configs(no_command_config())
        state = goal_loop_scheduler.normalize_state({}, configs, now)
        state["phases"]["observe"]["last_started_at"] = iso(now - timedelta(seconds=1))
        state["phases"]["observe"]["last_completed_at"] = iso(
            now - timedelta(seconds=1)
        )
        state["phases"]["verify"]["last_status"] = "FAIL"
        state["phases"]["verify"]["last_completed_at"] = iso(now)

        due = goal_loop_scheduler.select_due_phases(state, configs, now)

        self.assertEqual(due[0].name, "observe")
        self.assertEqual(due[0].reason, "verify_failed_reenter_observe")

    def test_tick_records_command_failure_as_critical_state(self) -> None:
        now = datetime(2026, 5, 6, 0, 0, 0, tzinfo=timezone.utc)
        config = {
            "schema_version": 1,
            "phases": {
                "observe": {
                    "command": [
                        sys.executable,
                        "-c",
                        "import sys; sys.stderr.write('boom'); sys.exit(7)",
                    ]
                }
            },
        }

        state = goal_loop_scheduler.scheduler_tick(
            config=config,
            state={},
            now=now,
            dry_run=False,
        )

        observe = state["phases"]["observe"]
        self.assertEqual(state["overall_status"], "critical")
        self.assertEqual(observe["last_status"], "ERROR")
        self.assertEqual(observe["last_exit_code"], 7)
        self.assertEqual(observe["last_error"], "boom")
        self.assertEqual(observe["consecutive_failures"], 1)

    def test_verify_fail_from_json_output_forces_next_observe_reentry(self) -> None:
        now = datetime(2026, 5, 6, 0, 0, 0, tzinfo=timezone.utc)
        config = {
            "schema_version": 1,
            "phases": {
                "verify": {
                    "command": [
                        sys.executable,
                        "-c",
                        "import json; print(json.dumps({'status': 'FAIL'}))",
                    ]
                }
            },
        }
        initial = goal_loop_scheduler.normalize_state(
            {},
            goal_loop_scheduler.phase_configs(config),
            now,
        )
        initial["phases"]["observe"]["last_started_at"] = iso(
            now - timedelta(seconds=1)
        )
        initial["phases"]["observe"]["last_completed_at"] = iso(
            now - timedelta(seconds=1)
        )
        initial["phases"]["verify"]["last_completed_at"] = iso(
            now - timedelta(seconds=300)
        )

        after_verify = goal_loop_scheduler.scheduler_tick(
            config=config,
            state=initial,
            now=now,
            dry_run=False,
        )
        due = goal_loop_scheduler.select_due_phases(
            after_verify,
            goal_loop_scheduler.phase_configs(config),
            now + timedelta(seconds=1),
        )

        self.assertEqual(after_verify["phases"]["verify"]["last_status"], "FAIL")
        self.assertEqual(due[0].name, "observe")
        self.assertEqual(due[0].reason, "verify_failed_reenter_observe")

    def test_cli_once_writes_observable_state_json(self) -> None:
        now = "2026-05-06T00:00:00+00:00"
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            config_path = root / "config.json"
            state_path = root / "state.json"
            status_path = root / "status.json"
            output_path = root / "observe.json"
            config_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "phases": {
                            name: {
                                "command": [
                                    sys.executable,
                                    "-c",
                                    "import json; print(json.dumps({'status': 'PASS'}))",
                                ],
                                **(
                                    {"output_path": str(output_path)}
                                    if name == "observe"
                                    else {}
                                ),
                            }
                            for name in goal_loop_scheduler.PHASE_ORDER
                        },
                    }
                ),
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--config",
                    str(config_path),
                    "--state",
                    str(state_path),
                    "--status-out",
                    str(status_path),
                    "--now",
                    now,
                    "--format",
                    "json",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            emitted = json.loads(completed.stdout)
            state = json.loads(state_path.read_text(encoding="utf-8"))
            status = json.loads(status_path.read_text(encoding="utf-8"))
            self.assertEqual(emitted["phases"]["observe"]["last_status"], "PASS")
            self.assertEqual(state["phases"]["observe"]["last_status"], "PASS")
            self.assertEqual(status["phases"]["observe"]["last_status"], "PASS")
            self.assertEqual(
                json.loads(output_path.read_text(encoding="utf-8"))["status"],
                "PASS",
            )


if __name__ == "__main__":
    unittest.main()
