#!/usr/bin/env python3
"""Audit whether a GOAL LOOP status snapshot is closeable.

This is intentionally stricter than the compact status summary. It turns the
current Goal closeout rules into explicit criteria, so a green test or a partial
manifest cannot be mistaken for objective completion.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, TextIO


@dataclass(frozen=True)
class CompletionCriterion:
    criterion_id: str
    status: str
    summary: str
    evidence: dict[str, Any]


@dataclass(frozen=True)
class CompletionAudit:
    schema_version: int
    status: str
    criteria: list[CompletionCriterion]
    blockers: list[str]


def load_json_input(path: str, *, stdin: TextIO = sys.stdin) -> dict[str, Any]:
    if path == "-":
        data = json.load(stdin)
    else:
        with Path(path).open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("expected GOAL LOOP status JSON object")
    return data


def nested_dict(value: Any, *keys: str) -> dict[str, Any]:
    current = value
    for key in keys:
        if not isinstance(current, dict):
            return {}
        current = current.get(key)
    return current if isinstance(current, dict) else {}


def as_int(value: Any) -> int:
    return value if isinstance(value, int) else 0


def criterion(
    criterion_id: str,
    passed: bool,
    summary: str,
    evidence: dict[str, Any],
    *,
    warning: bool = False,
) -> CompletionCriterion:
    if passed:
        status = "PASS"
    elif warning:
        status = "WARN"
    else:
        status = "FAIL"
    return CompletionCriterion(
        criterion_id=criterion_id,
        status=status,
        summary=summary,
        evidence=evidence,
    )


def build_completion_audit(status: dict[str, Any]) -> CompletionAudit:
    audit_catalog = nested_dict(status, "phases", "orient", "summary", "audit_catalog")
    verify_summary = nested_dict(status, "phases", "verify", "summary")

    source_documents_evidence = {
        "source_documents_status": audit_catalog.get("source_documents_status"),
        "source_documents_covered": audit_catalog.get("source_documents_covered"),
        "source_documents_expected": audit_catalog.get("source_documents_expected"),
    }
    source_documents_passed = (
        source_documents_evidence["source_documents_status"] == "COMPLETE"
        and as_int(source_documents_evidence["source_documents_expected"]) >= 12
        and source_documents_evidence["source_documents_covered"]
        == source_documents_evidence["source_documents_expected"]
    )

    source_artifacts_evidence = {
        "source_artifacts_status": audit_catalog.get("source_artifacts_status"),
        "source_artifacts_total": audit_catalog.get("source_artifacts_total"),
        "source_artifacts_resolved": audit_catalog.get("source_artifacts_resolved"),
        "source_artifacts_missing": audit_catalog.get("source_artifacts_missing"),
        "source_line_ref_errors": audit_catalog.get("source_line_ref_errors"),
    }
    source_artifacts_passed = (
        source_artifacts_evidence["source_artifacts_status"] == "COMPLETE"
        and as_int(source_artifacts_evidence["source_artifacts_total"]) >= 12
        and as_int(source_artifacts_evidence["source_artifacts_missing"]) == 0
        and as_int(source_artifacts_evidence["source_line_ref_errors"]) == 0
        and source_artifacts_evidence["source_artifacts_resolved"]
        == source_artifacts_evidence["source_artifacts_total"]
    )

    source_identity_evidence = {
        "source_identity_status": audit_catalog.get("source_identity_status"),
        "source_identity_checks_verified": audit_catalog.get(
            "source_identity_checks_verified"
        ),
        "source_identity_checks_failed": audit_catalog.get(
            "source_identity_checks_failed"
        ),
    }
    source_identity_passed = (
        source_identity_evidence["source_identity_status"] == "COMPLETE"
        and as_int(source_identity_evidence["source_identity_checks_verified"]) >= 12
        and as_int(source_identity_evidence["source_identity_checks_failed"]) == 0
    )

    aggregate_sources_evidence = {
        "source_aggregate_claim_status": audit_catalog.get(
            "source_aggregate_claim_status"
        ),
        "source_aggregate_claim_sources_verified": audit_catalog.get(
            "source_aggregate_claim_sources_verified"
        ),
        "source_aggregate_claim_sources_missing": audit_catalog.get(
            "source_aggregate_claim_sources_missing"
        ),
    }
    aggregate_sources_passed = (
        aggregate_sources_evidence["source_aggregate_claim_status"] == "COMPLETE"
        and as_int(
            aggregate_sources_evidence["source_aggregate_claim_sources_verified"]
        )
        >= 5
        and as_int(aggregate_sources_evidence["source_aggregate_claim_sources_missing"])
        == 0
    )

    id_sync_evidence = {
        "source_itemized_id_status": audit_catalog.get("source_itemized_id_status"),
        "source_ids_missing_from_catalog": audit_catalog.get(
            "source_ids_missing_from_catalog"
        ),
        "catalog_ids_missing_from_source": audit_catalog.get(
            "catalog_ids_missing_from_source"
        ),
    }
    id_sync_passed = (
        id_sync_evidence["source_itemized_id_status"] == "COMPLETE"
        and as_int(id_sync_evidence["source_ids_missing_from_catalog"]) == 0
        and as_int(id_sync_evidence["catalog_ids_missing_from_source"]) == 0
    )

    row_catalog_evidence = {
        "status": audit_catalog.get("status"),
        "expected_findings_total": audit_catalog.get("expected_findings_total"),
        "itemized_findings_total": audit_catalog.get("itemized_findings_total"),
        "missing_itemized_findings": audit_catalog.get("missing_itemized_findings"),
    }
    row_catalog_passed = (
        row_catalog_evidence["status"] == "COMPLETE"
        and as_int(row_catalog_evidence["expected_findings_total"]) >= 206
        and row_catalog_evidence["itemized_findings_total"]
        == row_catalog_evidence["expected_findings_total"]
        and as_int(row_catalog_evidence["missing_itemized_findings"]) == 0
    )

    consistency_evidence = {
        "consistency_findings_total": audit_catalog.get("consistency_findings_total"),
        "consistency_findings_open": audit_catalog.get("consistency_findings_open"),
    }
    consistency_passed = (
        as_int(consistency_evidence["consistency_findings_total"]) > 0
        and as_int(consistency_evidence["consistency_findings_open"]) == 0
    )

    structured_evidence = {
        "source_structured_item_ids_total": audit_catalog.get(
            "source_structured_item_ids_total"
        ),
        "source_structured_item_ids_uncataloged": audit_catalog.get(
            "source_structured_item_ids_uncataloged"
        ),
        "source_structured_item_id_families": audit_catalog.get(
            "source_structured_item_id_families",
            [],
        ),
    }
    structured_uncataloged = as_int(
        structured_evidence["source_structured_item_ids_uncataloged"]
    )
    structured_families = structured_evidence["source_structured_item_id_families"]
    structured_passed = structured_uncataloged == 0
    structured_warning = (
        structured_uncataloged > 0
        and isinstance(structured_families, list)
        and len(structured_families) > 0
    )

    violation_kinds_raw = verify_summary.get("violation_kinds", [])
    violation_kinds = (
        violation_kinds_raw if isinstance(violation_kinds_raw, list) else []
    )
    verify_evidence = {
        "verify_status": verify_summary.get("verify_status"),
        "violations": verify_summary.get("violations"),
        "violation_kinds": violation_kinds,
    }
    verify_passed = (
        verify_evidence["verify_status"] == "PASS"
        and as_int(verify_evidence["violations"]) == 0
        and "post_act_verify_pending" not in violation_kinds
    )

    criteria = [
        criterion(
            "source_documents_manifest_complete",
            source_documents_passed,
            "All prompt-supplied source documents are represented in the manifest.",
            source_documents_evidence,
        ),
        criterion(
            "source_artifacts_verified",
            source_artifacts_passed,
            "Manifest source paths resolve and line references are valid.",
            source_artifacts_evidence,
        ),
        criterion(
            "source_identity_verified",
            source_identity_passed,
            "Resolved source files match checked SHA-256 and line-count identity.",
            source_identity_evidence,
        ),
        criterion(
            "aggregate_claim_sources_verified",
            aggregate_sources_passed,
            "Aggregate claims are found in the resolved source documents.",
            aggregate_sources_evidence,
        ),
        criterion(
            "strict_source_catalog_id_sync",
            id_sync_passed,
            "Strict source-extracted audit IDs match catalog finding IDs.",
            id_sync_evidence,
        ),
        criterion(
            "strict_row_level_catalog_complete",
            row_catalog_passed,
            "The strict row-level audit corpus is complete against the claimed total.",
            row_catalog_evidence,
        ),
        criterion(
            "aggregate_consistency_resolved",
            consistency_passed,
            "Conflicting aggregate audit totals are reconciled.",
            consistency_evidence,
        ),
        criterion(
            "broader_structured_ids_cataloged",
            structured_passed,
            "Broader structured source IDs are cataloged; uncataloged groups remain follow-up work.",
            structured_evidence,
            warning=structured_warning,
        ),
        criterion(
            "post_act_verify_complete",
            verify_passed,
            "Post-ACT Verify is passing with no pending verification violation.",
            verify_evidence,
        ),
    ]
    blockers = [
        item.criterion_id for item in criteria if item.status in {"FAIL", "WARN"}
    ]
    status_text = "COMPLETE" if not blockers else "BLOCKED"
    return CompletionAudit(
        schema_version=1,
        status=status_text,
        criteria=criteria,
        blockers=blockers,
    )


def audit_to_json(audit: CompletionAudit) -> str:
    return json.dumps(asdict(audit), ensure_ascii=False, indent=2, sort_keys=True)


def audit_to_text(audit: CompletionAudit) -> str:
    lines = [f"GOAL LOOP Completion Audit: {audit.status}"]
    if audit.blockers:
        lines.append("blockers: " + ", ".join(audit.blockers))
    for item in audit.criteria:
        lines.append(f"- {item.criterion_id}: {item.status} {item.summary}")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "status_json",
        nargs="?",
        default="-",
        help="GOAL LOOP status JSON path, or '-' for stdin.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format (default: json).",
    )
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="Exit non-zero unless every completion criterion passes.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    audit = build_completion_audit(load_json_input(args.status_json))
    if args.format == "json":
        print(audit_to_json(audit))
    else:
        print(audit_to_text(audit))
    if args.require_complete and audit.status != "COMPLETE":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
