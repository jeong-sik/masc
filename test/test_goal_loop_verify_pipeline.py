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
SCRIPT_PATH = REPO_ROOT / "scripts" / "goal_loop_verify_pipeline.py"

spec = importlib.util.spec_from_file_location("goal_loop_verify_pipeline", SCRIPT_PATH)
assert spec is not None
goal_loop_verify_pipeline = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = goal_loop_verify_pipeline
spec.loader.exec_module(goal_loop_verify_pipeline)


def passing_metrics() -> dict[str, object]:
    return {
        "metrics": {
            "keeper_turn_success_rate": 0.99,
            "keeper_skipping_turn_rate_5m": 0,
            "pricing_catalog_miss_total": 0,
            "persistence_utf8_repair_total": 0,
            "recovery_strategy_executed_total_1h": 1,
            "admission_queue_depth": 2,
            "admission_queue_wait_ms": 0,
            "dashboard_snapshot_latency_p99": 1.5,
            "orient_recheck_still_present": 0,
            "orient_recheck_new_finding": 0,
        }
    }


class GoalLoopVerifyPipelineTest(unittest.TestCase):
    def test_missing_evidence_blocks_every_prompt_level_gate(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            repo_root = Path(raw_dir)
            repo_root.joinpath("specs").mkdir()
            report = goal_loop_verify_pipeline.build_pipeline_report(
                repo_root=repo_root,
                metrics_json=None,
                tla_results=None,
                log_paths=[],
                unit_tests_passed=False,
                unit_tests_failed=False,
            )

        self.assertEqual(report.status, "BLOCKED")
        by_id = {item.gate_id: item for item in report.gates}
        self.assertEqual(by_id["unit_tests"].status, "SKIPPED")
        self.assertEqual(
            by_id["keeper_turn_success_rate_healthy"].reason,
            "missing_metric_snapshot",
        )
        self.assertEqual(
            by_id["tla_prompt_spec_tierrouting"].reason,
            "prompt_tla_spec_missing",
        )
        self.assertEqual(
            by_id["tla_prompt_spec_validation"].reason,
            "prompt_tla_spec_missing",
        )
        self.assertEqual(
            by_id["tla_prompt_spec_liveness"].reason,
            "prompt_tla_spec_missing",
        )
        self.assertEqual(by_id["post_act_log_contract"].reason, "missing_post_act_logs")

    def test_metric_snapshot_covers_required_production_gates(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            repo_root = Path(raw_dir)
            repo_root.joinpath("specs").mkdir()
            report = goal_loop_verify_pipeline.build_pipeline_report(
                repo_root=repo_root,
                metrics_json=passing_metrics(),
                tla_results=None,
                log_paths=[],
                unit_tests_passed=True,
                unit_tests_failed=False,
            )

        by_id = {item.gate_id: item for item in report.gates}
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
        self.assertEqual(report.status, "BLOCKED")
        self.assertEqual(by_id["tla_prompt_spec_tierrouting"].status, "BLOCKED")

    def test_metric_gate_commands_reference_snapshot_metric_keys(self) -> None:
        report = goal_loop_verify_pipeline.build_pipeline_report(
            repo_root=REPO_ROOT,
            metrics_json=passing_metrics(),
            tla_results=None,
            log_paths=[],
            unit_tests_passed=True,
            unit_tests_failed=False,
        )

        by_id = {item.gate_id: item for item in report.gates}
        for gate_id in (
            "keeper_turn_success_rate_healthy",
            "no_semaphore_skip",
            "no_pricing_miss",
            "no_utf8_repair",
            "recovery_executed",
            "dashboard_snapshot_latency_p99",
        ):
            metric_name = by_id[gate_id].evidence["metric_name"]
            command = " ".join(by_id[gate_id].command or [])
            self.assertIn(metric_name, command)
            self.assertNotIn("prometheus query", command)
            self.assertEqual(
                by_id[gate_id].evidence["metric_source"],
                "GOAL_LOOP_METRICS_JSON (--metrics-json)",
            )

    def test_required_gate_id_contract_is_exact(self) -> None:
        report = goal_loop_verify_pipeline.build_pipeline_report(
            repo_root=REPO_ROOT,
            metrics_json=passing_metrics(),
            tla_results=None,
            log_paths=[],
            unit_tests_passed=True,
            unit_tests_failed=False,
        )

        self.assertEqual(
            [item.gate_id for item in report.gates],
            list(goal_loop_verify_pipeline.REQUIRED_VERIFY_GATE_IDS),
        )

    def test_prometheus_sources_cover_metric_backed_snapshot_keys(self) -> None:
        sources = goal_loop_verify_pipeline.PROMETHEUS_METRIC_SOURCES
        self.assertEqual(
            sources["persistence_utf8_repair_total"],
            ["masc_persistence_utf8_repair_total"],
        )
        self.assertEqual(
            sources["dashboard_snapshot_latency_p99"],
            ["masc_dashboard_snapshot_latency_seconds_bucket"],
        )

    def test_tla_results_accept_top_level_spec_keys(self) -> None:
        self.assertEqual(
            goal_loop_verify_pipeline.tla_result_for(
                {"TierRouting.tla": "PASS"},
                "TierRouting.tla",
            ),
            "PASS",
        )

    def test_log_contract_fails_on_forbidden_pattern(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "post-act.log"
            path.write_text(
                "\n".join(
                    [
                        "recovery_strategy_executed keeper=executor",
                        "provider_health_probe_completed provider=ollama",
                        "fallback_ladder_activated keeper=executor",
                        "[WARN] pricing_catalog_miss model=bad",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            report = goal_loop_verify_pipeline.build_pipeline_report(
                repo_root=REPO_ROOT,
                metrics_json=passing_metrics(),
                tla_results=None,
                log_paths=[str(path)],
                unit_tests_passed=True,
                unit_tests_failed=False,
            )

        by_id = {item.gate_id: item for item in report.gates}
        self.assertEqual(by_id["post_act_log_contract"].status, "FAIL")
        self.assertEqual(by_id["post_act_log_contract"].reason, "log_contract_failed")

    def test_cli_require_pass_returns_nonzero_for_blocked_tla_specs(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            metrics_path = Path(raw_dir) / "metrics.json"
            metrics_path.write_text(json.dumps(passing_metrics()), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--metrics-json",
                    str(metrics_path),
                    "--unit-tests-passed",
                    "--require-pass",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "BLOCKED")
        self.assertGreater(payload["gates_blocked"], 0)

    def test_emitted_gate_ids_match_required_contract(self) -> None:
        # Real build path emits exactly the REQUIRED_VERIFY_GATE_IDS set
        # — no missing, extra, or duplicate gate IDs.
        with tempfile.TemporaryDirectory() as raw_dir:
            repo_root = Path(raw_dir)
            repo_root.joinpath("specs").mkdir()
            report = goal_loop_verify_pipeline.build_pipeline_report(
                repo_root=repo_root,
                metrics_json=None,
                tla_results=None,
                log_paths=[],
                unit_tests_passed=False,
                unit_tests_failed=False,
            )
        emitted = sorted(item.gate_id for item in report.gates)
        required = sorted(goal_loop_verify_pipeline.REQUIRED_VERIFY_GATE_IDS)
        self.assertEqual(emitted, required)

    def test_gate_id_contract_assertion_catches_drift(self) -> None:
        # Contract assertion raises when emitted gate IDs drift from
        # REQUIRED_VERIFY_GATE_IDS, so future edits cannot silently
        # rename/drop/duplicate a gate without surfacing it here.
        VerifyGate = goal_loop_verify_pipeline.VerifyGate
        bogus = [
            VerifyGate(
                gate_id="not_a_required_id",
                category="x",
                status="PASS",
                summary="",
                command=None,
                reason=None,
                evidence={},
            )
        ]
        with self.assertRaises(AssertionError) as ctx:
            goal_loop_verify_pipeline._assert_emitted_gate_ids_match_required(bogus)
        message = str(ctx.exception)
        self.assertIn("missing=", message)
        self.assertIn("extra=", message)


if __name__ == "__main__":
    unittest.main()
