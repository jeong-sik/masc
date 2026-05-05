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
    decision_id: str | None = None
    actionability: str = "actionable"
    source: dict[str, Any] | None = None


@dataclass
class FindingReport:
    finding_id: str
    title: str
    severity: str
    status: str
    count: int
    patterns: list[str]
    samples: list[dict[str, Any]]
    decision_id: str | None
    actionability: str
    source: dict[str, Any] | None


@dataclass
class OrientReport:
    source_files: list[str]
    total_lines: int
    matched_lines: int
    summary: dict[str, int]
    findings: list[FindingReport]
    audit_catalog: dict[str, Any] | None = None


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


def load_audit_catalog_input(path: str | None) -> dict[str, Any] | None:
    if path is None:
        return None
    with Path(path).open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("expected audit catalog JSON object")
    return data


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


def catalog_specs(catalog: dict[str, Any] | None) -> list[FindingSpec]:
    if catalog is None:
        return []
    findings_raw = catalog.get("findings", [])
    if not isinstance(findings_raw, list):
        raise ValueError("audit catalog findings must be a list")

    specs: list[FindingSpec] = []
    for index, raw in enumerate(findings_raw):
        if not isinstance(raw, dict):
            raise ValueError(
                f"audit catalog finding at index {index} must be an object"
            )
        finding_id = raw.get("finding_id")
        title = raw.get("title")
        severity = raw.get("severity")
        if not isinstance(finding_id, str) or not finding_id:
            raise ValueError(
                f"audit catalog finding at index {index} missing finding_id"
            )
        if not isinstance(title, str) or not title:
            raise ValueError(f"audit catalog finding {finding_id} missing title")
        if severity not in ("critical", "warning", "info"):
            raise ValueError(f"audit catalog finding {finding_id} has invalid severity")

        patterns_raw = raw.get("patterns", [])
        if not isinstance(patterns_raw, list):
            raise ValueError(
                f"audit catalog finding {finding_id} patterns must be a list"
            )
        patterns = tuple(item for item in patterns_raw if isinstance(item, str))
        if len(patterns) != len(patterns_raw):
            raise ValueError(
                f"audit catalog finding {finding_id} has non-string pattern"
            )

        decision_id = raw.get("decision_id")
        if decision_id is not None and not isinstance(decision_id, str):
            raise ValueError(
                f"audit catalog finding {finding_id} decision_id must be string"
            )
        actionability = raw.get("actionability", "actionable")
        if not isinstance(actionability, str) or not actionability:
            raise ValueError(
                f"audit catalog finding {finding_id} actionability missing"
            )
        source = raw.get("source")
        if source is not None and not isinstance(source, dict):
            raise ValueError(
                f"audit catalog finding {finding_id} source must be object"
            )

        specs.append(
            FindingSpec(
                finding_id=finding_id,
                title=title,
                severity=severity,
                patterns=patterns,
                decision_id=decision_id,
                actionability=actionability,
                source=source,
            )
        )
    return specs


def merged_specs(catalog: dict[str, Any] | None) -> list[FindingSpec]:
    merged: dict[str, FindingSpec] = {spec.finding_id: spec for spec in FINDINGS}
    ordered_ids = [spec.finding_id for spec in FINDINGS]
    for spec in catalog_specs(catalog):
        if spec.finding_id not in merged:
            ordered_ids.append(spec.finding_id)
        merged[spec.finding_id] = spec
    return [merged[finding_id] for finding_id in ordered_ids]


def source_artifact_summary(
    catalog: dict[str, Any],
    source_root: Path | None,
) -> dict[str, Any] | None:
    if source_root is None:
        return None

    refs: dict[str, list[int]] = {}

    def add_ref(path_raw: Any, line_refs_raw: Any = None) -> None:
        if not isinstance(path_raw, str) or not path_raw:
            return
        line_refs = refs.setdefault(path_raw, [])
        if isinstance(line_refs_raw, list):
            line_refs.extend(item for item in line_refs_raw if isinstance(item, int))

    external_sources = catalog.get("external_sources", [])
    if isinstance(external_sources, list):
        for source in external_sources:
            if isinstance(source, dict):
                add_ref(source.get("path"), source.get("line_refs"))

    aggregate_claims = catalog.get("aggregate_claims", [])
    if isinstance(aggregate_claims, list):
        for claim in aggregate_claims:
            if not isinstance(claim, dict):
                continue
            source_paths = claim.get("source_paths", [])
            if isinstance(source_paths, list):
                for path_raw in source_paths:
                    add_ref(path_raw)

    consistency_findings = catalog.get("consistency_findings", [])
    if isinstance(consistency_findings, list):
        for finding in consistency_findings:
            if not isinstance(finding, dict):
                continue
            source_paths = finding.get("source_paths", [])
            if isinstance(source_paths, list):
                for path_raw in source_paths:
                    add_ref(path_raw)

    findings = catalog.get("findings", [])
    if isinstance(findings, list):
        for finding in findings:
            if not isinstance(finding, dict):
                continue
            source = finding.get("source")
            if isinstance(source, dict):
                add_ref(source.get("path"), source.get("line_refs"))

    missing_paths: list[str] = []
    line_ref_errors: list[dict[str, Any]] = []
    resolved = 0
    for path_text, line_refs in sorted(refs.items()):
        path = Path(path_text)
        candidate = path if path.is_absolute() else source_root / path
        if not candidate.is_file():
            missing_paths.append(path_text)
            continue
        resolved += 1
        if not line_refs:
            continue
        with candidate.open("r", encoding="utf-8") as handle:
            line_count = sum(1 for _ in handle)
        bad_refs = sorted({line_ref for line_ref in line_refs if line_ref > line_count})
        if bad_refs:
            line_ref_errors.append(
                {
                    "path": path_text,
                    "line_count": line_count,
                    "line_refs": bad_refs,
                }
            )

    status = "COMPLETE" if not missing_paths and not line_ref_errors else "INCOMPLETE"
    return {
        "status": status,
        "source_root": str(source_root),
        "source_artifacts_total": len(refs),
        "source_artifacts_resolved": resolved,
        "source_artifacts_missing": len(missing_paths),
        "line_ref_errors": len(line_ref_errors),
        "missing_paths": missing_paths[:10],
        "line_ref_error_samples": line_ref_errors[:10],
    }


def audit_catalog_summary(
    catalog: dict[str, Any] | None,
    *,
    source_root: Path | None = None,
) -> dict[str, Any] | None:
    if catalog is None:
        return None
    specs = catalog_specs(catalog)
    expected_raw = catalog.get("expected_findings_total")
    expected = expected_raw if isinstance(expected_raw, int) else None
    external_sources_raw = catalog.get("external_sources", [])
    external_sources = (
        external_sources_raw if isinstance(external_sources_raw, list) else []
    )
    source_expected_raw = catalog.get("source_documents_expected")
    source_expected = (
        source_expected_raw if isinstance(source_expected_raw, int) else None
    )
    source_covered = len(external_sources)
    if source_expected is None:
        source_status = "UNBOUNDED"
    elif source_covered == source_expected:
        source_status = "COMPLETE"
    else:
        source_status = "INCOMPLETE"
    itemized = len(specs)
    missing = max(expected - itemized, 0) if expected is not None else None
    if expected is None:
        status = "UNBOUNDED"
    elif itemized == expected:
        status = "COMPLETE"
    else:
        status = "INCOMPLETE"
    summary = {
        "catalog_id": catalog.get("catalog_id", "unknown"),
        "source_status": catalog.get("source_status", "unknown"),
        "status": status,
        "expected_findings_total": expected,
        "itemized_findings_total": itemized,
        "missing_itemized_findings": missing,
        "external_sources_total": source_covered,
        "source_documents_expected": source_expected,
        "source_documents_covered": source_covered,
        "source_documents_status": source_status,
        "external_sources": external_sources,
        "aggregate_claims": catalog.get("aggregate_claims", []),
        "consistency_findings": catalog.get("consistency_findings", []),
    }
    artifacts = source_artifact_summary(catalog, source_root)
    if artifacts is not None:
        summary["source_artifacts"] = artifacts
    return summary


def orient_scan(
    scan: dict[str, Any],
    *,
    audit_catalog: dict[str, Any] | None = None,
    audit_source_root: Path | None = None,
) -> OrientReport:
    patterns_raw = scan.get("patterns", {})
    patterns = patterns_raw if isinstance(patterns_raw, dict) else {}
    files_raw = scan.get("files", [])
    source_files = (
        [item for item in files_raw if isinstance(item, str)]
        if isinstance(files_raw, list)
        else []
    )

    findings: list[FindingReport] = []
    for spec in merged_specs(audit_catalog):
        count = sum(pattern_count(patterns, name) for name in spec.patterns)
        samples: list[dict[str, Any]] = []
        for name in spec.patterns:
            samples.extend(pattern_samples(patterns, name))
        status = "EVIDENCE_PRESENT" if count > 0 else "EVIDENCE_ABSENT"
        if not spec.patterns:
            status = "NOT_EVALUATED"
        findings.append(
            FindingReport(
                finding_id=spec.finding_id,
                title=spec.title,
                severity=spec.severity,
                status=status,
                count=count,
                patterns=list(spec.patterns),
                samples=samples[:3],
                decision_id=spec.decision_id,
                actionability=spec.actionability,
                source=spec.source,
            )
        )

    present = sum(1 for finding in findings if finding.status == "EVIDENCE_PRESENT")
    not_evaluated = sum(1 for finding in findings if finding.status == "NOT_EVALUATED")
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
            "evidence_absent": len(findings) - present - not_evaluated,
            "critical_present": critical_present,
            "not_evaluated": not_evaluated,
            "findings_total": len(findings),
        },
        findings=findings,
        audit_catalog=audit_catalog_summary(
            audit_catalog,
            source_root=audit_source_root,
        ),
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
    if report.audit_catalog is not None:
        lines.append(
            "audit_catalog: "
            f"{report.audit_catalog['status']} "
            f"itemized={report.audit_catalog['itemized_findings_total']} "
            f"expected={report.audit_catalog['expected_findings_total']}"
        )
        lines.append(
            "source_documents: "
            f"{report.audit_catalog['source_documents_status']} "
            f"covered={report.audit_catalog['source_documents_covered']} "
            f"expected={report.audit_catalog['source_documents_expected']}"
        )
        source_artifacts = report.audit_catalog.get("source_artifacts")
        if isinstance(source_artifacts, dict):
            lines.append(
                "source_artifacts: "
                f"{source_artifacts['status']} "
                f"resolved={source_artifacts['source_artifacts_resolved']} "
                f"missing={source_artifacts['source_artifacts_missing']} "
                f"line_ref_errors={source_artifacts['line_ref_errors']}"
            )
        consistency_findings = report.audit_catalog.get("consistency_findings", [])
        if isinstance(consistency_findings, list) and consistency_findings:
            lines.append(f"consistency_findings: {len(consistency_findings)}")
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
    parser.add_argument(
        "--audit-catalog",
        help=(
            "Optional audit corpus catalog JSON. Catalog findings are merged "
            "with the built-in startup findings and reported in audit_catalog."
        ),
    )
    parser.add_argument(
        "--audit-source-root",
        help=(
            "Optional root used to validate audit catalog source paths and "
            "line references."
        ),
    )
    parser.add_argument(
        "--require-complete-catalog",
        action="store_true",
        help="Exit non-zero when --audit-catalog is absent or incomplete.",
    )
    parser.add_argument(
        "--require-source-artifacts",
        action="store_true",
        help=(
            "Exit non-zero when --audit-source-root is absent or source paths "
            "and line references are incomplete."
        ),
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = orient_scan(
        load_json_input(args.scan_json),
        audit_catalog=load_audit_catalog_input(args.audit_catalog),
        audit_source_root=Path(args.audit_source_root)
        if args.audit_source_root is not None
        else None,
    )
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    if should_fail(report, args.fail_on):
        return 1
    if args.require_complete_catalog:
        if report.audit_catalog is None:
            return 1
        if report.audit_catalog.get("status") != "COMPLETE":
            return 1
    if args.require_source_artifacts:
        if report.audit_catalog is None:
            return 1
        source_artifacts = report.audit_catalog.get("source_artifacts")
        if not isinstance(source_artifacts, dict):
            return 1
        if source_artifacts.get("status") != "COMPLETE":
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
