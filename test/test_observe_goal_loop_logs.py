#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "observe_goal_loop_logs.py"

spec = importlib.util.spec_from_file_location("observe_goal_loop_logs", SCRIPT_PATH)
assert spec is not None
observe_goal_loop_logs = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = observe_goal_loop_logs
spec.loader.exec_module(observe_goal_loop_logs)


class ObserveGoalLoopLogsTest(unittest.TestCase):
    def test_scan_counts_prompt_signatures(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "server.log"
            path.write_text(
                "\n".join(
                    [
                        '{"status":"skipped","error":"runtime provider health is advisory; bootstrap skips live probe"}',
                        "[WARN] [Auth] archived credential sangsu.json (reason: bare-form keeper credential is dead after PR-3b1 starvation)",
                        "[WARN] [Keeper] nick0cave: alive-but-stuck detected (elapsed=924857s)",
                        "[WARN] [Governance] Governance judge returned unparseable response (Lenient_json fallback hit; 3809 chars)",
                        "[WARN] [Keeper] keeper TOML jobsian_purist.toml has unknown keys: keeper.base",
                        "[keepers_json:*] sub-op: meta=12ms agent=7ms ka=0ms audit=0ms profile=0ms phase=0ms activity=0ms",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            report = observe_goal_loop_logs.scan_logs([str(path)], max_samples=2)

        self.assertEqual(report.total_lines, 6)
        self.assertEqual(report.patterns["provider_health_skipped"].count, 1)
        self.assertEqual(report.patterns["credential_archived_starvation"].count, 1)
        self.assertEqual(report.patterns["alive_but_stuck"].count, 1)
        self.assertEqual(report.patterns["governance_unparseable"].count, 1)
        self.assertEqual(report.patterns["lenient_json_fallback"].count, 1)
        self.assertEqual(report.patterns["config_unknown_key"].count, 1)
        self.assertEqual(report.patterns["metric_all_zero"].count, 1)

    def test_fail_on_critical_exits_nonzero(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fail-on",
                "critical",
                "-",
            ],
            input="[WARN] [Keeper] alive-but-stuck detected\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("alive_but_stuck", result.stdout)


if __name__ == "__main__":
    unittest.main()
