#!/usr/bin/env python3
"""Orient GOAL LOOP live-log findings from Observe scanner JSON.

This consumes the JSON emitted by ``observe_goal_loop_logs.py`` and turns raw
pattern counts into a small finding-oriented report. It does not mark anything
as fixed; absence of log evidence is only reported as ``EVIDENCE_ABSENT``.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, TextIO


@dataclass(frozen=True)
class FindingSpec:
    finding_id: str
    title: str
    severity: str
    patterns: tuple[str, ...]


@dataclass
class FindingReport:
    finding_id: str
    title: str
    severity: str
    status: str
    count: int
    patterns: list[str]
    samples: list[dict[str, Any]]


@dataclass
class OrientReport:
    source_files: list[str]
    total_lines: int
    matched_lines: int
    summary: dict[str, int]
    findings: list[FindingReport]


FINDINGS: tuple[FindingSpec, ...] = (
    FindingSpec(
        "R-FATAL-1",
        "keeper_semaphore_wait_no_fallback",
        "critical",
        ("keeper_skipping_turn",),
    ),
    FindingSpec(
        "CF-1",
        "pricing_catalog_miss",
        "critical",
        ("pricing_catalog_miss",),
    ),
    FindingSpec(
        "NF-1",
        "provider_health_skipped_all_models",
        "critical",
        ("provider_health_skipped",),
    ),
    FindingSpec(
        "NF-2",
        "credential_archived_all_keepers",
        "critical",
        ("credential_archived_starvation",),
    ),
    FindingSpec(
        "NF-3",
        "alive_but_stuck_no_recovery",
        "critical",
        ("alive_but_stuck",),
    ),
    FindingSpec(
        "NF-4",
        "governance_judge_unparseable_fallback",
        "warning",
        ("governance_unparseable", "lenient_json_fallback"),
    ),
    FindingSpec(
        "NF-5",
        "autoboot_warmup_delay",
        "warning",
        ("autoboot_warmup",),
    ),
    FindingSpec(
        "NF-6",
        "config_unknown_keys_ignored",
        "warning",
        ("config_unknown_key",),
    ),
    FindingSpec(
        "NF-7",
        "tool_policy_unknown_tools",
        "warning",
        ("tool_policy_unknown_tools",),
    ),
    FindingSpec(
        "NF-8",
        "keeper_checkpoint_migration_data_loss",
        "critical",
        ("keeper_checkpoint_migration_data_loss",),
    ),
)


def load_json_input(path: str) -> dict[str, Any]:
    if path == "-":
        return load_json_handle(sys.stdin)
    with Path(path).open("r", encoding="utf-8") as handle:
        return load_json_handle(handle)


def load_json_handle(handle: TextIO) -> dict[str, Any]:
    data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("expected Observe scanner JSON object")
    return data


def pattern_count(patterns: dict[str, Any], name: str) -> int:
    raw = patterns.get(name)
    if not isinstance(raw, dict):
        return 0
    count = raw.get("count", 0)
    return count if isinstance(count, int) else 0


def pattern_samples(patterns: dict[str, Any], name: str) -> list[dict[str, Any]]:
    raw = patterns.get(name)
    if not isinstance(raw, dict):
        return []
    samples = raw.get("samples", [])
    if not isinstance(samples, list):
        return []
    return [sample for sample in samples if isinstance(sample, dict)]


def orient_scan(scan: dict[str, Any]) -> OrientReport:
    patterns_raw = scan.get("patterns", {})
    patterns = patterns_raw if isinstance(patterns_raw, dict) else {}
    files_raw = scan.get("files", [])
    source_files = (
        [item for item in files_raw if isinstance(item, str)]
        if isinstance(files_raw, list)
        else []
    )

    findings: list[FindingReport] = []
    for spec in FINDINGS:
        count = sum(pattern_count(patterns, name) for name in spec.patterns)
        samples: list[dict[str, Any]] = []
        for name in spec.patterns:
            samples.extend(pattern_samples(patterns, name))
        findings.append(
            FindingReport(
                finding_id=spec.finding_id,
                title=spec.title,
                severity=spec.severity,
                status="EVIDENCE_PRESENT" if count > 0 else "EVIDENCE_ABSENT",
                count=count,
                patterns=list(spec.patterns),
                samples=samples[:3],
            )
        )

    present = sum(1 for finding in findings if finding.status == "EVIDENCE_PRESENT")
    critical_present = sum(
        1
        for finding in findings
        if finding.status == "EVIDENCE_PRESENT" and finding.severity == "critical"
    )
    return OrientReport(
        source_files=source_files,
        total_lines=int(scan.get("total_lines", 0) or 0),
        matched_lines=int(scan.get("matched_lines", 0) or 0),
        summary={
            "evidence_present": present,
            "evidence_absent": len(findings) - present,
            "critical_present": critical_present,
            "findings_total": len(findings),
        },
        findings=findings,
    )


def report_to_json(report: OrientReport) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def report_to_text(report: OrientReport) -> str:
    lines = [
        "GOAL LOOP Orient Log Findings",
        f"source_files: {', '.join(report.source_files) if report.source_files else '<none>'}",
        f"total_lines: {report.total_lines}",
        f"matched_lines: {report.matched_lines}",
        (
            "summary: "
            f"{report.summary['evidence_present']} present / "
            f"{report.summary['findings_total']} total; "
            f"{report.summary['critical_present']} critical present"
        ),
    ]
    for finding in report.findings:
        if finding.status == "EVIDENCE_ABSENT":
            continue
        lines.append(
            f"- {finding.finding_id} {finding.title}: "
            f"{finding.status} count={finding.count} severity={finding.severity}"
        )
    return "\n".join(lines)


def should_fail(report: OrientReport, mode: str) -> bool:
    if mode == "none":
        return False
    if mode == "present":
        return report.summary["evidence_present"] > 0
    if mode == "critical":
        return report.summary["critical_present"] > 0
    raise ValueError(f"unknown fail mode: {mode}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "scan_json",
        nargs="?",
        default="-",
        help="Observe scanner JSON path, or '-' for stdin (default).",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format (default: json).",
    )
    parser.add_argument(
        "--fail-on",
        choices=("none", "present", "critical"),
        default="none",
        help="Exit non-zero when oriented findings match this condition.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = orient_scan(load_json_input(args.scan_json))
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    return 1 if should_fail(report, args.fail_on) else 0


if __name__ == "__main__":
    raise SystemExit(main())
