#!/usr/bin/env python3
"""Validate GOAL LOOP Observe metric alert and dashboard coverage."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass
class SignalCheck:
    signal_id: str
    status: str
    missing_alerts: list[str]
    missing_alert_metrics: list[str]
    missing_dashboard_metrics: list[str]
    missing_threshold_fragments: list[str]


@dataclass
class ValidationReport:
    schema_version: int
    status: str
    checked_signals: int
    passing_signals: int
    failing_signals: int
    signal_checks: list[SignalCheck]


def load_json_object(path: str) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object: {path}")
    return data


def read_text(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def alert_names(alert_text: str) -> set[str]:
    names: set[str] = set()
    for line in alert_text.splitlines():
        match = re.match(r"\s*-\s*alert:\s*([A-Za-z0-9_:.-]+)\s*$", line)
        if match:
            names.add(match.group(1))
    return names


def as_string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str) and item.strip()]


def required_signals(contract: dict[str, Any]) -> list[dict[str, Any]]:
    raw = contract.get("required_signals", [])
    if not isinstance(raw, list):
        raise ValueError("contract.required_signals must be a list")
    return [item for item in raw if isinstance(item, dict)]


def validate_signal(
    signal: dict[str, Any],
    *,
    alerts: set[str],
    alert_text: str,
    dashboard_text: str,
) -> SignalCheck:
    signal_id = str(signal.get("signal_id", "unknown"))
    metric_names = as_string_list(signal.get("metric_names"))
    required_alerts = as_string_list(signal.get("alert_names"))
    threshold_fragments = as_string_list(signal.get("threshold_fragments"))
    dashboard_fragments = as_string_list(
        signal.get("dashboard_query_fragments", metric_names)
    )
    missing_alerts = [name for name in required_alerts if name not in alerts]
    missing_alert_metrics = [name for name in metric_names if name not in alert_text]
    missing_dashboard_metrics = [
        fragment for fragment in dashboard_fragments if fragment not in dashboard_text
    ]
    missing_threshold_fragments = [
        fragment for fragment in threshold_fragments if fragment not in alert_text
    ]
    status = (
        "PASS"
        if not missing_alerts
        and not missing_alert_metrics
        and not missing_dashboard_metrics
        and not missing_threshold_fragments
        else "FAIL"
    )
    return SignalCheck(
        signal_id=signal_id,
        status=status,
        missing_alerts=missing_alerts,
        missing_alert_metrics=missing_alert_metrics,
        missing_dashboard_metrics=missing_dashboard_metrics,
        missing_threshold_fragments=missing_threshold_fragments,
    )


def validate_contract(
    contract: dict[str, Any],
    *,
    alert_text: str,
    dashboard_text: str,
) -> ValidationReport:
    alerts = alert_names(alert_text)
    checks = [
        validate_signal(
            signal,
            alerts=alerts,
            alert_text=alert_text,
            dashboard_text=dashboard_text,
        )
        for signal in required_signals(contract)
    ]
    passing = sum(1 for check in checks if check.status == "PASS")
    failing = len(checks) - passing
    return ValidationReport(
        schema_version=1,
        status="PASS" if failing == 0 else "FAIL",
        checked_signals=len(checks),
        passing_signals=passing,
        failing_signals=failing,
        signal_checks=checks,
    )


def report_to_json(report: ValidationReport) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def report_to_text(report: ValidationReport) -> str:
    lines = [
        f"GOAL LOOP Observe Metrics Contract: {report.status}",
        f"checked_signals: {report.checked_signals}",
        f"passing_signals: {report.passing_signals}",
        f"failing_signals: {report.failing_signals}",
    ]
    for check in report.signal_checks:
        lines.append(f"- {check.signal_id}: {check.status}")
        if check.status == "FAIL":
            if check.missing_alerts:
                lines.append(f"  missing_alerts={','.join(check.missing_alerts)}")
            if check.missing_alert_metrics:
                lines.append(
                    f"  missing_alert_metrics={','.join(check.missing_alert_metrics)}"
                )
            if check.missing_dashboard_metrics:
                lines.append(
                    "  missing_dashboard_metrics="
                    + ",".join(check.missing_dashboard_metrics)
                )
            if check.missing_threshold_fragments:
                lines.append(
                    "  missing_threshold_fragments="
                    + ",".join(check.missing_threshold_fragments)
                )
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("contract_json")
    parser.add_argument("--alerts-yml", required=True)
    parser.add_argument("--dashboard-json", required=True)
    parser.add_argument("--format", choices=("json", "text"), default="json")
    parser.add_argument("--require-complete", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = validate_contract(
        load_json_object(args.contract_json),
        alert_text=read_text(args.alerts_yml),
        dashboard_text=read_text(args.dashboard_json),
    )
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    return 1 if args.require_complete and report.status != "PASS" else 0


if __name__ == "__main__":
    raise SystemExit(main())
