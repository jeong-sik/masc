#!/usr/bin/env python3
"""Verify GOAL LOOP log findings after an Act step.

This consumes the JSON emitted by ``orient_goal_loop_logs.py`` and reports
whether post-fix logs still contain evidence for selected finding severities.
It treats absence of log evidence as a verification signal, not as proof that
the underlying bug is permanently impossible.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, TextIO


@dataclass
class VerificationFinding:
    finding_id: str
    title: str
    severity: str
    count: int


@dataclass
class VerificationReport:
    status: str
    policy: str
    checked_findings: int
    failing_findings: list[VerificationFinding]


def load_json_input(path: str) -> dict[str, Any]:
    if path == "-":
        return load_json_handle(sys.stdin)
    with Path(path).open("r", encoding="utf-8") as handle:
        return load_json_handle(handle)


def load_json_handle(handle: TextIO) -> dict[str, Any]:
    data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("expected Orient JSON object")
    return data


def finding_fails(finding: dict[str, Any], policy: str) -> bool:
    if finding.get("status") != "EVIDENCE_PRESENT":
        return False
    if policy == "present":
        return True
    if policy == "critical":
        return finding.get("severity") == "critical"
    raise ValueError(f"unknown policy: {policy}")


def verify_orient(orient: dict[str, Any], *, policy: str) -> VerificationReport:
    findings_raw = orient.get("findings", [])
    findings = findings_raw if isinstance(findings_raw, list) else []
    failing: list[VerificationFinding] = []
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        if not finding_fails(finding, policy):
            continue
        finding_id = finding.get("finding_id")
        title = finding.get("title")
        severity = finding.get("severity")
        count = finding.get("count", 0)
        failing.append(
            VerificationFinding(
                finding_id=finding_id if isinstance(finding_id, str) else "unknown",
                title=title if isinstance(title, str) else "unknown",
                severity=severity if isinstance(severity, str) else "unknown",
                count=count if isinstance(count, int) else 0,
            )
        )
    return VerificationReport(
        status="PASS" if not failing else "FAIL",
        policy=policy,
        checked_findings=len(findings),
        failing_findings=failing,
    )


def report_to_json(report: VerificationReport) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def report_to_text(report: VerificationReport) -> str:
    lines = [
        f"GOAL LOOP Verify: {report.status}",
        f"policy: {report.policy}",
        f"checked_findings: {report.checked_findings}",
        f"failing_findings: {len(report.failing_findings)}",
    ]
    for finding in report.failing_findings:
        lines.append(
            f"- {finding.finding_id} {finding.title}: "
            f"count={finding.count} severity={finding.severity}"
        )
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "orient_json",
        nargs="?",
        default="-",
        help="Orient JSON path, or '-' for stdin (default).",
    )
    parser.add_argument(
        "--policy",
        choices=("critical", "present"),
        default="critical",
        help="Verification policy: fail on critical evidence or any evidence.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format (default: json).",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = verify_orient(load_json_input(args.orient_json), policy=args.policy)
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    return 0 if report.status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
