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
SCRIPT_PATH = REPO_ROOT / "scripts" / "goal_loop_metrics_snapshot.py"
VERIFY_SCRIPT_PATH = REPO_ROOT / "scripts" / "goal_loop_verify_pipeline.py"

spec = importlib.util.spec_from_file_location("goal_loop_metrics_snapshot", SCRIPT_PATH)
assert spec is not None
goal_loop_metrics_snapshot = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = goal_loop_metrics_snapshot
spec.loader.exec_module(goal_loop_metrics_snapshot)

verify_spec = importlib.util.spec_from_file_location(
    "goal_loop_verify_pipeline",
    VERIFY_SCRIPT_PATH,
)
assert verify_spec is not None
goal_loop_verify_pipeline = importlib.util.module_from_spec(verify_spec)
assert verify_spec.loader is not None
sys.modules[verify_spec.name] = goal_loop_verify_pipeline
verify_spec.loader.exec_module(goal_loop_verify_pipeline)


PROMETHEUS_TEXT = """\
# HELP masc_keeper_turns_total Total keeper turns by outcome.
# TYPE masc_keeper_turns_total counter
masc_keeper_turns_total{keeper_name="alpha",outcome="success"} 99
masc_keeper_turns_total{keeper_name="alpha",outcome="failure"} 1
masc_keeper_semaphore_wait_timeout_total{keeper="alpha",channel="turn"} 0
masc_pricing_catalog_miss_total 0
masc_persistence_utf8_repair_total 0
masc_inference_queue_depth{cascade_name="primary"} 2
masc_inference_queue_wait_seconds_sum{cascade_name="primary"} 0.125
masc_dashboard_snapshot_latency_seconds_bucket{le="0.5"} 98
masc_dashboard_snapshot_latency_seconds_bucket{le="1.5"} 100
masc_dashboard_snapshot_latency_seconds_bucket{le="+Inf"} 100
"""


class GoalLoopMetricsSnapshotTest(unittest.TestCase):
    def test_builds_verify_snapshot_from_prometheus_text(self) -> None:
        snapshot = goal_loop_metrics_snapshot.build_snapshot(
            goal_loop_metrics_snapshot.parse_prometheus_text(PROMETHEUS_TEXT),
            [
                "recovery_strategy_executed_total_1h=1",
                "orient_recheck_still_present=0",
                "orient_recheck_new_finding=0",
            ],
        )

        self.assertEqual(snapshot["schema_version"], 1)
        metrics = snapshot["metrics"]
        self.assertEqual(metrics["keeper_turn_success_rate"], 0.99)
        self.assertEqual(metrics["keeper_skipping_turn_rate_5m"], 0)
        self.assertEqual(metrics["pricing_catalog_miss_total"], 0)
        self.assertEqual(metrics["persistence_utf8_repair_total"], 0)
        self.assertEqual(metrics["recovery_strategy_executed_total_1h"], 1)
        self.assertEqual(metrics["admission_queue_depth"], 2)
        self.assertEqual(metrics["admission_queue_wait_ms"], 125)
        self.assertGreater(metrics["dashboard_snapshot_latency_p99"], 0.5)
        self.assertLess(metrics["dashboard_snapshot_latency_p99"], 1.5)

    def test_snapshot_can_feed_verify_metric_gates(self) -> None:
        snapshot = goal_loop_metrics_snapshot.build_snapshot(
            goal_loop_metrics_snapshot.parse_prometheus_text(PROMETHEUS_TEXT),
            [
                "recovery_strategy_executed_total_1h=1",
                "orient_recheck_still_present=0",
                "orient_recheck_new_finding=0",
            ],
        )

        with tempfile.TemporaryDirectory() as raw_dir:
            repo_root = Path(raw_dir)
            repo_root.joinpath("specs").mkdir()
            report = goal_loop_verify_pipeline.build_pipeline_report(
                repo_root=repo_root,
                metrics_json=snapshot,
                tla_results=None,
                log_paths=[],
                unit_tests_passed=False,
                unit_tests_failed=False,
            )

        by_id = {gate.gate_id: gate for gate in report.gates}
        for gate_id in (
            "keeper_turn_success_rate_healthy",
            "no_semaphore_skip",
            "no_pricing_miss",
            "no_utf8_repair",
            "recovery_executed",
            "admission_backpressure_observed",
            "dashboard_snapshot_latency_p99",
            "orient_recheck_no_still_present",
            "orient_recheck_no_new_finding",
        ):
            self.assertEqual(by_id[gate_id].status, "PASS", gate_id)

    def test_cli_reads_file_and_applies_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "metrics.prom"
            path.write_text(PROMETHEUS_TEXT, encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(path),
                    "--set",
                    "orient_recheck_still_present=0",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["metrics"]["orient_recheck_still_present"], 0)


if __name__ == "__main__":
    unittest.main()
