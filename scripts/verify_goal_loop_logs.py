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
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, TextIO


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
    post_act_verify: bool = False
    evidence_kind: str | None = None
    evidence_source: str | None = None
    evidence_window_start: str | None = None
    evidence_window_end: str | None = None
    checked_at: str | None = None


@dataclass
class LogMatchSample:
    path: str
    line: int
    text: str


@dataclass
class LogContractViolation:
    pattern: str
    kind: str
    count: int
    samples: list[LogMatchSample]


@dataclass
class LogContractReport:
    status: str
    checked_files: list[str]
    total_lines: int
    required_patterns: int
    forbidden_patterns: int
    violations: list[LogContractViolation]


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


def verify_orient(
    orient: dict[str, Any],
    *,
    policy: str,
    post_act_verify: bool = False,
    evidence_kind: str | None = None,
    evidence_source: str | None = None,
    evidence_window_start: str | None = None,
    evidence_window_end: str | None = None,
    checked_at: str | None = None,
) -> VerificationReport:
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
        post_act_verify=post_act_verify,
        evidence_kind=evidence_kind,
        evidence_source=evidence_source,
        evidence_window_start=evidence_window_start,
        evidence_window_end=evidence_window_end,
        checked_at=checked_at,
    )


def iter_log_lines(paths: list[str]) -> Iterable[tuple[str, int, str]]:
    if not paths:
        yield from iter_log_handle("<stdin>", sys.stdin)
        return

    for raw_path in paths:
        if raw_path == "-":
            yield from iter_log_handle("<stdin>", sys.stdin)
            continue
        path = Path(raw_path)
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            yield from iter_log_handle(str(path), handle)


def iter_log_handle(path: str, handle: TextIO) -> Iterable[tuple[str, int, str]]:
    for line_no, line in enumerate(handle, start=1):
        yield path, line_no, line.rstrip("\n")


def verify_log_contract(
    paths: list[str],
    *,
    must_contain: list[str],
    must_not_contain: list[str],
    max_samples: int,
) -> LogContractReport:
    required = [(pattern, re.compile(pattern)) for pattern in must_contain]
    forbidden = [(pattern, re.compile(pattern)) for pattern in must_not_contain]
    required_counts = {pattern: 0 for pattern, _ in required}
    forbidden_counts = {pattern: 0 for pattern, _ in forbidden}
    required_samples: dict[str, list[LogMatchSample]] = {
        pattern: [] for pattern, _ in required
    }
    forbidden_samples: dict[str, list[LogMatchSample]] = {
        pattern: [] for pattern, _ in forbidden
    }
    checked_files: list[str] = []
    checked_files_seen: set[str] = set()
    total_lines = 0

    for path, line_no, line in iter_log_lines(paths):
        total_lines += 1
        if path not in checked_files_seen:
            checked_files.append(path)
            checked_files_seen.add(path)
        for pattern, regex in required:
            if not regex.search(line):
                continue
            required_counts[pattern] += 1
            if len(required_samples[pattern]) < max_samples:
                required_samples[pattern].append(
                    LogMatchSample(path=path, line=line_no, text=line)
                )
        for pattern, regex in forbidden:
            if not regex.search(line):
                continue
            forbidden_counts[pattern] += 1
            if len(forbidden_samples[pattern]) < max_samples:
                forbidden_samples[pattern].append(
                    LogMatchSample(path=path, line=line_no, text=line)
                )

    violations: list[LogContractViolation] = []
    for pattern in must_not_contain:
        count = forbidden_counts[pattern]
        if count == 0:
            continue
        violations.append(
            LogContractViolation(
                pattern=pattern,
                kind="forbidden_present",
                count=count,
                samples=forbidden_samples[pattern],
            )
        )
    for pattern in must_contain:
        count = required_counts[pattern]
        if count > 0:
            continue
        violations.append(
            LogContractViolation(
                pattern=pattern,
                kind="required_missing",
                count=0,
                samples=[],
            )
        )

    return LogContractReport(
        status="PASS" if not violations else "FAIL",
        checked_files=checked_files,
        total_lines=total_lines,
        required_patterns=len(required),
        forbidden_patterns=len(forbidden),
        violations=violations,
    )


def report_to_json(report: VerificationReport | LogContractReport) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def report_to_text(report: VerificationReport) -> str:
    lines = [
        f"GOAL LOOP Verify: {report.status}",
        f"policy: {report.policy}",
        f"checked_findings: {report.checked_findings}",
        f"failing_findings: {len(report.failing_findings)}",
        f"post_act_verify: {str(report.post_act_verify).lower()}",
    ]
    if report.evidence_kind:
        lines.append(f"evidence_kind: {report.evidence_kind}")
    if report.evidence_source:
        lines.append(f"evidence_source: {report.evidence_source}")
    if report.evidence_window_start:
        lines.append(f"evidence_window_start: {report.evidence_window_start}")
    if report.evidence_window_end:
        lines.append(f"evidence_window_end: {report.evidence_window_end}")
    if report.checked_at:
        lines.append(f"checked_at: {report.checked_at}")
    for finding in report.failing_findings:
        lines.append(
            f"- {finding.finding_id} {finding.title}: "
            f"count={finding.count} severity={finding.severity}"
        )
    return "\n".join(lines)


def log_contract_report_to_text(report: LogContractReport) -> str:
    lines = [
        f"GOAL LOOP Log Contract Verify: {report.status}",
        (
            "checked_files: "
            f"{', '.join(report.checked_files) if report.checked_files else '<stdin>'}"
        ),
        f"total_lines: {report.total_lines}",
        f"required_patterns: {report.required_patterns}",
        f"forbidden_patterns: {report.forbidden_patterns}",
        f"violations: {len(report.violations)}",
    ]
    for violation in report.violations:
        lines.append(f"- {violation.kind} {violation.pattern}: count={violation.count}")
        for sample in violation.samples:
            lines.append(f"  {sample.path}:{sample.line}: {sample.text}")
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
        "--mode",
        choices=("orient", "log-contract"),
        default="orient",
        help="Verify Orient JSON findings or raw log contract gates.",
    )
    parser.add_argument(
        "--log",
        action="append",
        default=[],
        help="Raw log path for --mode log-contract. Repeat for multiple files.",
    )
    parser.add_argument(
        "--must-contain",
        action="append",
        default=[],
        help="Regex that must appear at least once in --mode log-contract.",
    )
    parser.add_argument(
        "--must-not-contain",
        action="append",
        default=[],
        help="Regex that must be absent in --mode log-contract.",
    )
    parser.add_argument(
        "--max-samples",
        type=int,
        default=3,
        help="Maximum sample lines per log-contract violation.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format (default: json).",
    )
    parser.add_argument(
        "--post-act-verify",
        action="store_true",
        help="Mark this report as evidence collected after the relevant ACT artifacts.",
    )
    parser.add_argument(
        "--evidence-kind",
        help="Post-ACT evidence kind, for example live_runtime_logs.",
    )
    parser.add_argument(
        "--evidence-source",
        help="Concrete post-ACT source path, URL, run id, or endpoint.",
    )
    parser.add_argument(
        "--evidence-window-start",
        help="Inclusive timestamp for the post-ACT evidence window.",
    )
    parser.add_argument(
        "--evidence-window-end",
        help="Exclusive timestamp for the post-ACT evidence window.",
    )
    parser.add_argument(
        "--checked-at",
        help="Timestamp for when the post-ACT evidence was collected.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.mode == "log-contract":
        paths = list(args.log)
        if not paths and args.orient_json != "-":
            paths.append(args.orient_json)
        report = verify_log_contract(
            paths,
            must_contain=list(args.must_contain),
            must_not_contain=list(args.must_not_contain),
            max_samples=args.max_samples,
        )
        if args.format == "json":
            print(report_to_json(report))
        else:
            print(log_contract_report_to_text(report))
        return 0 if report.status == "PASS" else 1

    report = verify_orient(
        load_json_input(args.orient_json),
        policy=args.policy,
        post_act_verify=args.post_act_verify,
        evidence_kind=args.evidence_kind,
        evidence_source=args.evidence_source,
        evidence_window_start=args.evidence_window_start,
        evidence_window_end=args.evidence_window_end,
        checked_at=args.checked_at,
    )
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    return 0 if report.status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
