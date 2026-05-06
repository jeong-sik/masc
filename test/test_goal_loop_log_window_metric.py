#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "goal_loop_log_window_metric.py"

spec = importlib.util.spec_from_file_location(
    "goal_loop_log_window_metric", SCRIPT_PATH
)
assert spec is not None
goal_loop_log_window_metric = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = goal_loop_log_window_metric
spec.loader.exec_module(goal_loop_log_window_metric)


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.write_text(
        "\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\n",
        encoding="utf-8",
    )


class GoalLoopLogWindowMetricTest(unittest.TestCase):
    def test_counts_only_matching_lines_inside_timestamp_window(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            log_path = Path(raw_dir) / "system.jsonl"
            write_jsonl(
                log_path,
                [
                    {"ts": "2026-05-06T15:48:59Z", "message": "before wait"},
                    {
                        "ts": "2026-05-06T15:49:30Z",
                        "message": "keeper: skipping turn semaphore wait",
                    },
                    {"ts": "2026-05-06T15:50:00Z", "message": "normal turn"},
                    {
                        "ts": "2026-05-06T15:54:02Z",
                        "message": "keeper: skipping turn semaphore wait",
                    },
                ],
            )

            report = goal_loop_log_window_metric.build_metric_report(
                [str(log_path)],
                metric_name="keeper_skipping_turn_rate_5m",
                pattern="skipping turn.*semaphore wait",
                window_start="2026-05-06T15:49:02Z",
                window_end="2026-05-06T15:54:02Z",
                display_paths=["<MASC_BASE_PATH>/.masc/logs/system.jsonl"],
            )

        self.assertEqual(report["matching_lines"], 1)
        self.assertEqual(report["window_lines"], 2)
        self.assertEqual(
            report["metrics"]["keeper_skipping_turn_rate_5m"],
            1.0,
        )
        self.assertEqual(
            report["checked_files"],
            ["<MASC_BASE_PATH>/.masc/logs/system.jsonl"],
        )
        self.assertFalse(report["raw_log_lines_committed"])

    def test_invalid_window_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            goal_loop_log_window_metric.build_metric_report(
                ["unused"],
                metric_name="keeper_skipping_turn_rate_5m",
                pattern="skipping turn",
                window_start="2026-05-06T15:54:02Z",
                window_end="2026-05-06T15:54:02Z",
                display_paths=[],
            )

    def test_cli_emits_metric_json(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            log_path = Path(raw_dir) / "system.jsonl"
            write_jsonl(
                log_path,
                [
                    {
                        "ts": "2026-05-06T15:50:00Z",
                        "message": "dashboard snapshot",
                    }
                ],
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(log_path),
                    "--metric-name",
                    "keeper_skipping_turn_rate_5m",
                    "--pattern",
                    "skipping turn.*semaphore wait",
                    "--window-start",
                    "2026-05-06T15:49:02Z",
                    "--window-end",
                    "2026-05-06T15:54:02Z",
                    "--display-path",
                    "<MASC_BASE_PATH>/.masc/logs/system.jsonl",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["matching_lines"], 0)
        self.assertEqual(payload["metrics"]["keeper_skipping_turn_rate_5m"], 0.0)
        self.assertEqual(
            payload["checked_files"],
            ["<MASC_BASE_PATH>/.masc/logs/system.jsonl"],
        )


if __name__ == "__main__":
    unittest.main()
