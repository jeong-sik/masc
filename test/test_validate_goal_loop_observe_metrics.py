#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "validate_goal_loop_observe_metrics.py"
CONTRACT_PATH = (
    REPO_ROOT
    / "infrastructure"
    / "monitoring"
    / "goal-loop-observe-metrics.contract.json"
)
ALERTS_PATH = (
    REPO_ROOT / "infrastructure" / "monitoring" / "goal-loop-observe-alerts.yml"
)
DASHBOARD_PATH = (
    REPO_ROOT
    / "infrastructure"
    / "monitoring"
    / "grafana-goal-loop-observe-dashboard.json"
)

spec = importlib.util.spec_from_file_location(
    "validate_goal_loop_observe_metrics", SCRIPT_PATH
)
assert spec is not None
validate_goal_loop_observe_metrics = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = validate_goal_loop_observe_metrics
spec.loader.exec_module(validate_goal_loop_observe_metrics)


def load_current_report(
    *,
    contract: dict[str, object] | None = None,
    alert_text: str | None = None,
    dashboard_text: str | None = None,
) -> object:
    return validate_goal_loop_observe_metrics.validate_contract(
        contract
        if contract is not None
        else validate_goal_loop_observe_metrics.load_json_object(str(CONTRACT_PATH)),
        alert_text=(
            alert_text
            if alert_text is not None
            else ALERTS_PATH.read_text(encoding="utf-8")
        ),
        dashboard_text=(
            dashboard_text
            if dashboard_text is not None
            else DASHBOARD_PATH.read_text(encoding="utf-8")
        ),
    )


class GoalLoopObserveMetricsValidatorTest(unittest.TestCase):
    def test_contract_passes_current_alerts_and_dashboard(self) -> None:
        report = load_current_report()

        self.assertEqual("PASS", report.status)
        self.assertEqual(15, report.checked_signals)
        self.assertEqual(15, report.passing_signals)
        self.assertEqual(0, report.failing_signals)

    def test_cli_require_complete_passes(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                str(CONTRACT_PATH),
                "--alerts-yml",
                str(ALERTS_PATH),
                "--dashboard-json",
                str(DASHBOARD_PATH),
                "--require-complete",
                "--format",
                "text",
            ],
            check=True,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        self.assertIn("GOAL LOOP Observe Metrics Contract: PASS", result.stdout)

    def test_missing_alert_name_fails(self) -> None:
        alert_text = ALERTS_PATH.read_text(encoding="utf-8").replace(
            "GoalLoopProviderHealthProbeSkippedWarning",
            "GoalLoopProviderHealthProbeSkippedMissing",
        )

        report = load_current_report(alert_text=alert_text)

        self.assertEqual("FAIL", report.status)
        failed = {
            check.signal_id: check
            for check in report.signal_checks
            if check.status == "FAIL"
        }
        self.assertIn("provider_health_probe_skipped", failed)
        self.assertEqual(
            ["GoalLoopProviderHealthProbeSkippedWarning"],
            failed["provider_health_probe_skipped"].missing_alerts,
        )

    def test_missing_alert_metric_fails(self) -> None:
        alert_text = ALERTS_PATH.read_text(encoding="utf-8").replace(
            "masc_pricing_catalog_miss_total",
            "masc_pricing_catalog_missing_total",
        )

        report = load_current_report(alert_text=alert_text)

        self.assertEqual("FAIL", report.status)
        failed = {
            check.signal_id: check
            for check in report.signal_checks
            if check.status == "FAIL"
        }
        self.assertIn("pricing_catalog_miss", failed)
        self.assertEqual(
            ["masc_pricing_catalog_miss_total"],
            failed["pricing_catalog_miss"].missing_alert_metrics,
        )

    def test_missing_dashboard_metric_fails(self) -> None:
        dashboard_text = DASHBOARD_PATH.read_text(encoding="utf-8").replace(
            "masc_write_meta_cas_retry_total",
            "masc_write_meta_cas_missing_total",
        )

        report = load_current_report(dashboard_text=dashboard_text)

        self.assertEqual("FAIL", report.status)
        failed = {
            check.signal_id: check
            for check in report.signal_checks
            if check.status == "FAIL"
        }
        self.assertIn("write_meta_cas_retry", failed)
        self.assertEqual(
            ["masc_write_meta_cas_retry_total"],
            failed["write_meta_cas_retry"].missing_dashboard_metrics,
        )

    def test_cli_require_complete_fails_when_contract_broken(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            broken_alerts = Path(tmpdir) / "alerts.yml"
            broken_alerts.write_text(
                ALERTS_PATH.read_text(encoding="utf-8").replace(
                    "masc_dashboard_metric_all_zeros",
                    "masc_dashboard_metric_missing",
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(CONTRACT_PATH),
                    "--alerts-yml",
                    str(broken_alerts),
                    "--dashboard-json",
                    str(DASHBOARD_PATH),
                    "--require-complete",
                    "--format",
                    "json",
                ],
                check=False,
                cwd=REPO_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

        self.assertEqual(1, result.returncode)
        self.assertIn('"status": "FAIL"', result.stdout)

    def test_rejects_empty_required_signals(self) -> None:
        contract = {
            "schema_version": 1,
            "required_signals": [],
        }

        with self.assertRaisesRegex(ValueError, "must not be empty"):
            load_current_report(contract=contract)

    def test_rejects_non_object_required_signal(self) -> None:
        contract = {
            "schema_version": 1,
            "required_signals": ["pricing_catalog_miss"],
        }

        with self.assertRaisesRegex(ValueError, r"required_signals\[0\]"):
            load_current_report(contract=contract)

    def test_report_reflects_contract_schema_version(self) -> None:
        report = load_current_report()

        self.assertEqual(1, report.schema_version)

    def test_rejects_unsupported_schema_version(self) -> None:
        contract = {
            "schema_version": 2,
            "required_signals": [
                {
                    "signal_id": "pricing_catalog_miss",
                    "metric_names": ["masc_pricing_catalog_miss_total"],
                    "alert_names": ["GoalLoopPricingCatalogMissCritical"],
                }
            ],
        }

        with self.assertRaisesRegex(ValueError, "unsupported"):
            load_current_report(contract=contract)

    def test_alert_metrics_are_checked_within_required_alert_exprs(self) -> None:
        contract = {
            "schema_version": 1,
            "required_signals": [
                {
                    "signal_id": "pricing_catalog_miss",
                    "metric_names": ["masc_pricing_catalog_miss_total"],
                    "alert_names": ["GoalLoopPricingCatalogMissCritical"],
                    "threshold_fragments": ["> 0"],
                }
            ],
        }
        alert_text = """
groups:
  - name: test
    rules:
      - alert: GoalLoopPricingCatalogMissCritical
        expr: |
          increase(masc_pricing_catalog_miss_total_shadow[5m]) > 0
      - alert: OtherAlert
        expr: |
          increase(masc_pricing_catalog_miss_total[5m]) > 0
"""
        dashboard_text = """
{
  "panels": [
    {
      "targets": [
        {"expr": "increase(masc_pricing_catalog_miss_total[5m])"}
      ]
    }
  ]
}
"""

        report = load_current_report(
            contract=contract,
            alert_text=alert_text,
            dashboard_text=dashboard_text,
        )

        self.assertEqual("FAIL", report.status)
        self.assertEqual(
            ["masc_pricing_catalog_miss_total"],
            report.signal_checks[0].missing_alert_metrics,
        )

    def test_dashboard_metrics_are_checked_from_target_exprs(self) -> None:
        contract = {
            "schema_version": 1,
            "required_signals": [
                {
                    "signal_id": "pricing_catalog_miss",
                    "metric_names": ["masc_pricing_catalog_miss_total"],
                    "alert_names": ["GoalLoopPricingCatalogMissCritical"],
                }
            ],
        }
        alert_text = """
groups:
  - name: test
    rules:
      - alert: GoalLoopPricingCatalogMissCritical
        expr: |
          increase(masc_pricing_catalog_miss_total[5m]) > 0
"""
        dashboard_text = """
{
  "panels": [
    {
      "title": "masc_pricing_catalog_miss_total",
      "targets": [
        {"expr": "increase(masc_pricing_catalog_miss_total_shadow[5m])"}
      ]
    }
  ]
}
"""

        report = load_current_report(
            contract=contract,
            alert_text=alert_text,
            dashboard_text=dashboard_text,
        )

        self.assertEqual("FAIL", report.status)
        self.assertEqual(
            ["masc_pricing_catalog_miss_total"],
            report.signal_checks[0].missing_dashboard_metrics,
        )


if __name__ == "__main__":
    unittest.main()
