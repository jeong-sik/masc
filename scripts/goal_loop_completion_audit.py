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


POST_ACT_EVIDENCE_KINDS = {
    "live_runtime_http",
    "live_runtime_logs",
    "live_runtime_status",
}
STRICT_ROW_CORPUS_SOURCE_PREFIX = "prompt_corpus/GOAL_LOOP/"
STRICT_ROW_CORPUS_SEVERITIES = {"critical", "warning", "info"}
STRICT_ROW_CORPUS_ERROR_LIMIT = 20


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


def load_optional_json_file(path: str | None) -> dict[str, Any] | None:
    if path is None:
        return None
    with Path(path).open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object: {path}")
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


def as_nonempty_str(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped if stripped else None


def contains_user_local_path(value: Any) -> bool:
    if isinstance(value, str):
        return "/Users/" in value
    if isinstance(value, list):
        return any(contains_user_local_path(item) for item in value)
    if isinstance(value, dict):
        return any(contains_user_local_path(item) for item in value.values())
    return False


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


def structured_triage_evidence(
    structured_evidence: dict[str, Any],
    structured_id_triage: dict[str, Any] | None,
) -> tuple[bool, bool, dict[str, Any]]:
    structured_uncataloged = as_int(
        structured_evidence["source_structured_item_ids_uncataloged"]
    )
    structured_occurrences = as_int(
        structured_evidence.get("source_structured_item_ids_uncataloged_occurrences")
    )
    structured_families = structured_evidence["source_structured_item_id_families"]
    if structured_uncataloged == 0:
        return True, False, {"triage_status": "NOT_REQUIRED"}
    if not isinstance(structured_families, list):
        return False, True, {"triage_status": "MISSING_FAMILY_SUMMARY"}
    if structured_id_triage is None:
        return False, True, {"triage_status": "MISSING_TRIAGE_MANIFEST"}

    required_families = {
        family["family"]: as_int(family.get("uncataloged"))
        for family in structured_families
        if isinstance(family, dict)
        and isinstance(family.get("family"), str)
        and as_int(family.get("uncataloged")) > 0
    }
    raw_entries = structured_id_triage.get("families", [])
    entries = raw_entries if isinstance(raw_entries, list) else []
    coverage: dict[str, int] = {}
    incomplete: list[str] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        family = entry.get("family")
        if not isinstance(family, str):
            continue
        coverage[family] = as_int(entry.get("uncataloged"))
        if not isinstance(entry.get("owner_catalog"), str) or not entry.get(
            "owner_catalog"
        ):
            incomplete.append(family)
        if not isinstance(entry.get("disposition"), str) or not entry.get(
            "disposition"
        ):
            incomplete.append(family)

    missing_families = sorted(set(required_families) - set(coverage))
    extra_families = sorted(set(coverage) - set(required_families))
    count_mismatches = [
        {
            "family": family,
            "expected": required_count,
            "actual": coverage.get(family),
        }
        for family, required_count in sorted(required_families.items())
        if coverage.get(family) != required_count
    ]
    expected_ids_total = structured_id_triage.get("expected_uncataloged_ids_total")
    expected_occurrences = structured_id_triage.get("expected_uncataloged_occurrences")
    total_matches = (
        as_int(expected_ids_total) == structured_uncataloged
        if expected_ids_total is not None
        else False
    )
    occurrence_matches = (
        as_int(expected_occurrences) == structured_occurrences
        if expected_occurrences is not None
        else False
    )
    triage_status = structured_id_triage.get("status")
    passed = (
        triage_status == "TRIAGED"
        and total_matches
        and occurrence_matches
        and not missing_families
        and not extra_families
        and not count_mismatches
        and not incomplete
    )
    evidence = {
        "triage_status": triage_status,
        "triage_id": structured_id_triage.get("triage_id"),
        "triage_families_total": len(entries),
        "missing_families": missing_families,
        "extra_families": extra_families,
        "count_mismatches": count_mismatches,
        "incomplete_families": sorted(set(incomplete)),
        "expected_uncataloged_ids_total": expected_ids_total,
        "expected_uncataloged_occurrences": expected_occurrences,
        "total_matches": total_matches,
        "occurrence_matches": occurrence_matches,
    }
    return passed, not passed, evidence


def row_corpus_discovery_evidence(
    row_catalog_evidence: dict[str, Any],
    row_corpus_discovery: dict[str, Any] | None,
) -> dict[str, Any]:
    if row_catalog_evidence["status"] == "COMPLETE":
        return {"discovery_status": "NOT_REQUIRED", "recorded": False}
    if row_corpus_discovery is None:
        return {"discovery_status": "MISSING", "recorded": False}

    sources_raw = row_corpus_discovery.get("prompt_sources_checked", [])
    sources = sources_raw if isinstance(sources_raw, list) else []
    artifacts_raw = row_corpus_discovery.get("candidate_artifacts_checked", [])
    artifacts = artifacts_raw if isinstance(artifacts_raw, list) else []
    strict_ids_raw = row_corpus_discovery.get("strict_catalog_itemized_ids", [])
    strict_ids = strict_ids_raw if isinstance(strict_ids_raw, list) else []
    broader_triage = row_corpus_discovery.get("broader_structured_id_triage")
    broader_triage = broader_triage if isinstance(broader_triage, dict) else {}

    expected_matches = (
        row_corpus_discovery.get("expected_findings_total")
        == row_catalog_evidence["expected_findings_total"]
    )
    itemized_matches = (
        row_corpus_discovery.get("strict_itemized_findings")
        == row_catalog_evidence["itemized_findings_total"]
    )
    missing_matches = (
        row_corpus_discovery.get("missing_itemized_findings")
        == row_catalog_evidence["missing_itemized_findings"]
    )
    strict_ids_match = len(strict_ids) == as_int(
        row_catalog_evidence["itemized_findings_total"]
    )
    path_policy_valid = (
        row_corpus_discovery.get("checked_path_policy")
        == "logical_paths_only_no_user_local_paths"
    )
    local_path_leaks = contains_user_local_path(row_corpus_discovery)
    recorded = (
        row_corpus_discovery.get("status") == "RECORDED"
        and row_corpus_discovery.get("result") == "FULL_ROW_CORPUS_NOT_FOUND"
        and expected_matches
        and itemized_matches
        and missing_matches
        and strict_ids_match
        and path_policy_valid
        and len(sources) >= 12
        and len(artifacts) > 0
        and not local_path_leaks
    )
    return {
        "discovery_status": row_corpus_discovery.get("status"),
        "discovery_id": row_corpus_discovery.get("discovery_id"),
        "result": row_corpus_discovery.get("result"),
        "recorded": recorded,
        "expected_matches": expected_matches,
        "itemized_matches": itemized_matches,
        "missing_matches": missing_matches,
        "strict_ids_match": strict_ids_match,
        "path_policy_valid": path_policy_valid,
        "prompt_sources_checked": len(sources),
        "candidate_artifacts_checked": len(artifacts),
        "broader_uncataloged_ids_total": broader_triage.get("uncataloged_ids_total"),
        "broader_uncataloged_occurrences": broader_triage.get(
            "uncataloged_occurrences"
        ),
        "local_path_leaks": local_path_leaks,
        "next_required_artifact": row_corpus_discovery.get("next_required_artifact"),
    }


def row_label(index: int, raw: dict[str, Any]) -> str:
    finding_id = raw.get("finding_id")
    return (
        finding_id if isinstance(finding_id, str) and finding_id else f"index:{index}"
    )


def strict_row_corpus_evidence(
    row_catalog_evidence: dict[str, Any],
    strict_row_corpus: dict[str, Any] | None,
) -> dict[str, Any]:
    if strict_row_corpus is None:
        return {
            "corpus_status": "MISSING",
            "provided": False,
            "validated": False,
        }

    errors: list[str] = []
    duplicate_ids: list[str] = []
    invalid_rows: list[str] = []
    invalid_source_paths: list[str] = []
    invalid_line_refs: list[str] = []
    invalid_replay_expectations: list[str] = []

    schema_version = strict_row_corpus.get("schema_version")
    corpus_id = as_nonempty_str(strict_row_corpus.get("corpus_id"))
    source_catalog_id = as_nonempty_str(strict_row_corpus.get("source_catalog_id"))
    corpus_status = strict_row_corpus.get("status")
    expected_total = strict_row_corpus.get("expected_findings_total")
    findings_raw = strict_row_corpus.get("findings")
    findings = findings_raw if isinstance(findings_raw, list) else []

    if schema_version != 1:
        errors.append("schema_version_must_be_1")
    if corpus_id is None:
        errors.append("corpus_id_missing")
    if source_catalog_id is None:
        errors.append("source_catalog_id_missing")
    if corpus_status != "COMPLETE":
        errors.append("status_must_be_COMPLETE")
    if expected_total != row_catalog_evidence["expected_findings_total"]:
        errors.append("expected_findings_total_mismatch")
    if not isinstance(findings_raw, list):
        errors.append("findings_must_be_list")
    if isinstance(expected_total, int) and len(findings) != expected_total:
        errors.append("findings_count_mismatch")

    seen_ids: set[str] = set()
    for index, raw in enumerate(findings):
        if not isinstance(raw, dict):
            invalid_rows.append(f"index:{index}")
            continue

        label = row_label(index, raw)
        finding_id = as_nonempty_str(raw.get("finding_id"))
        title = as_nonempty_str(raw.get("title"))
        severity = raw.get("severity")
        actionability = as_nonempty_str(raw.get("actionability"))
        decision_id = raw.get("decision_id")
        patterns_raw = raw.get("patterns", [])
        source = raw.get("source")
        replay_expectation = raw.get("replay_expectation")

        if finding_id is None or title is None or actionability is None:
            invalid_rows.append(label)
        elif finding_id in seen_ids:
            duplicate_ids.append(finding_id)
        else:
            seen_ids.add(finding_id)

        if severity not in STRICT_ROW_CORPUS_SEVERITIES:
            invalid_rows.append(label)
        if decision_id is not None and not isinstance(decision_id, str):
            invalid_rows.append(label)
        if not isinstance(patterns_raw, list) or any(
            not isinstance(item, str) for item in patterns_raw
        ):
            invalid_rows.append(label)

        if not isinstance(source, dict):
            invalid_source_paths.append(label)
            invalid_line_refs.append(label)
        else:
            source_path = source.get("path")
            line_refs = source.get("line_refs")
            if not isinstance(source_path, str) or not source_path.startswith(
                STRICT_ROW_CORPUS_SOURCE_PREFIX
            ):
                invalid_source_paths.append(label)
            if (
                not isinstance(line_refs, list)
                or len(line_refs) == 0
                or any(not isinstance(item, int) or item <= 0 for item in line_refs)
            ):
                invalid_line_refs.append(label)

        if not isinstance(replay_expectation, dict):
            invalid_replay_expectations.append(label)
        else:
            phase = as_nonempty_str(replay_expectation.get("phase"))
            expected_status = as_nonempty_str(replay_expectation.get("expected_status"))
            if phase is None or expected_status is None:
                invalid_replay_expectations.append(label)

    if duplicate_ids:
        errors.append("finding_ids_must_be_unique")
    if invalid_rows:
        errors.append("finding_rows_invalid")
    if invalid_source_paths:
        errors.append("source_paths_must_be_logical_prompt_corpus_paths")
    if invalid_line_refs:
        errors.append("source_line_refs_must_be_positive_ints")
    if invalid_replay_expectations:
        errors.append("replay_expectation_missing_or_invalid")

    local_path_leaks = contains_user_local_path(strict_row_corpus)
    if local_path_leaks:
        errors.append("contains_user_local_path")

    errors = sorted(set(errors))
    row_count = len(findings)
    return {
        "corpus_status": corpus_status,
        "corpus_id": corpus_id,
        "source_catalog_id": source_catalog_id,
        "provided": True,
        "validated": not errors,
        "errors_total": len(errors),
        "errors": errors[:STRICT_ROW_CORPUS_ERROR_LIMIT],
        "expected_findings_total": expected_total,
        "expected_matches_catalog": expected_total
        == row_catalog_evidence["expected_findings_total"],
        "row_count": row_count,
        "row_count_matches_expected": isinstance(expected_total, int)
        and row_count == expected_total,
        "orient_itemized_matches_corpus": row_count
        == row_catalog_evidence["itemized_findings_total"],
        "unique_finding_ids": len(seen_ids),
        "duplicate_finding_ids": sorted(set(duplicate_ids))[
            :STRICT_ROW_CORPUS_ERROR_LIMIT
        ],
        "invalid_rows": sorted(set(invalid_rows))[:STRICT_ROW_CORPUS_ERROR_LIMIT],
        "invalid_source_paths": sorted(set(invalid_source_paths))[
            :STRICT_ROW_CORPUS_ERROR_LIMIT
        ],
        "invalid_line_refs": sorted(set(invalid_line_refs))[
            :STRICT_ROW_CORPUS_ERROR_LIMIT
        ],
        "invalid_replay_expectations": sorted(set(invalid_replay_expectations))[
            :STRICT_ROW_CORPUS_ERROR_LIMIT
        ],
        "path_policy_valid": not local_path_leaks and not invalid_source_paths,
        "local_path_leaks": local_path_leaks,
        "required_source_prefix": STRICT_ROW_CORPUS_SOURCE_PREFIX,
    }


def build_completion_audit(
    status: dict[str, Any],
    *,
    structured_id_triage: dict[str, Any] | None = None,
    row_corpus_discovery: dict[str, Any] | None = None,
    strict_row_corpus: dict[str, Any] | None = None,
) -> CompletionAudit:
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
    row_catalog_evidence["row_corpus_discovery"] = row_corpus_discovery_evidence(
        row_catalog_evidence,
        row_corpus_discovery,
    )
    row_catalog_evidence["strict_row_corpus"] = strict_row_corpus_evidence(
        row_catalog_evidence,
        strict_row_corpus,
    )
    strict_row_corpus_passed = (
        row_catalog_evidence["strict_row_corpus"]["validated"]
        if strict_row_corpus is not None
        else True
    )
    row_catalog_passed = (
        row_catalog_evidence["status"] == "COMPLETE"
        and as_int(row_catalog_evidence["expected_findings_total"]) >= 206
        and row_catalog_evidence["itemized_findings_total"]
        == row_catalog_evidence["expected_findings_total"]
        and as_int(row_catalog_evidence["missing_itemized_findings"]) == 0
        and strict_row_corpus_passed
    )

    consistency_evidence = {
        "consistency_findings_total": audit_catalog.get("consistency_findings_total"),
        "consistency_findings_open": audit_catalog.get("consistency_findings_open"),
        "source_aggregate_reconciliation_status": audit_catalog.get(
            "source_aggregate_reconciliation_status"
        ),
        "source_aggregate_reconciliations_verified": audit_catalog.get(
            "source_aggregate_reconciliations_verified"
        ),
        "source_aggregate_reconciliations_failed": audit_catalog.get(
            "source_aggregate_reconciliations_failed"
        ),
    }
    consistency_passed = (
        as_int(consistency_evidence["consistency_findings_total"]) > 0
        and as_int(consistency_evidence["consistency_findings_open"]) == 0
        and consistency_evidence["source_aggregate_reconciliation_status"] == "COMPLETE"
        and as_int(consistency_evidence["source_aggregate_reconciliations_verified"])
        >= 1
        and as_int(consistency_evidence["source_aggregate_reconciliations_failed"]) == 0
    )

    structured_evidence = {
        "source_structured_item_ids_total": audit_catalog.get(
            "source_structured_item_ids_total"
        ),
        "source_structured_item_ids_uncataloged": audit_catalog.get(
            "source_structured_item_ids_uncataloged"
        ),
        "source_structured_item_ids_uncataloged_occurrences": audit_catalog.get(
            "source_structured_item_ids_uncataloged_occurrences"
        ),
        "source_structured_item_id_families": audit_catalog.get(
            "source_structured_item_id_families",
            [],
        ),
    }
    structured_passed, structured_warning, structured_triage = (
        structured_triage_evidence(structured_evidence, structured_id_triage)
    )
    structured_evidence["structured_id_triage"] = structured_triage

    violation_kinds_raw = verify_summary.get("violation_kinds", [])
    violation_kinds = (
        violation_kinds_raw if isinstance(violation_kinds_raw, list) else []
    )
    verify_evidence = {
        "verify_status": verify_summary.get("verify_status"),
        "violations": verify_summary.get("violations"),
        "violation_kinds": violation_kinds,
        "post_act_verify": verify_summary.get("post_act_verify")
        if isinstance(verify_summary.get("post_act_verify"), bool)
        else False,
        "evidence_kind": as_nonempty_str(verify_summary.get("evidence_kind")),
        "evidence_source": as_nonempty_str(verify_summary.get("evidence_source")),
        "evidence_window_start": as_nonempty_str(
            verify_summary.get("evidence_window_start")
        ),
        "evidence_window_end": as_nonempty_str(
            verify_summary.get("evidence_window_end")
        ),
        "checked_at": as_nonempty_str(verify_summary.get("checked_at")),
        "accepted_evidence_kinds": sorted(POST_ACT_EVIDENCE_KINDS),
    }
    evidence_kind_valid = verify_evidence["evidence_kind"] in POST_ACT_EVIDENCE_KINDS
    verify_passed = (
        verify_evidence["verify_status"] == "PASS"
        and as_int(verify_evidence["violations"]) == 0
        and "post_act_verify_pending" not in violation_kinds
        and verify_evidence["post_act_verify"] is True
        and evidence_kind_valid
        and verify_evidence["evidence_source"] is not None
        and verify_evidence["evidence_window_start"] is not None
        and verify_evidence["evidence_window_end"] is not None
        and verify_evidence["checked_at"] is not None
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
            "broader_structured_ids_triaged",
            structured_passed,
            "Broader structured source IDs are either absent from the backlog or covered by an ownership triage manifest.",
            structured_evidence,
            warning=structured_warning,
        ),
        criterion(
            "post_act_verify_complete",
            verify_passed,
            "Post-ACT Verify is passing with explicit post-ACT evidence metadata.",
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
        "--structured-id-triage",
        help="Optional triage manifest for broader uncataloged structured IDs.",
    )
    parser.add_argument(
        "--row-corpus-discovery",
        help="Optional discovery manifest for unsuccessful 206-row corpus searches.",
    )
    parser.add_argument(
        "--strict-row-corpus",
        help="Optional strict 206-row corpus artifact to validate against the closeout contract.",
    )
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="Exit non-zero unless every completion criterion passes.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    audit = build_completion_audit(
        load_json_input(args.status_json),
        structured_id_triage=load_optional_json_file(args.structured_id_triage),
        row_corpus_discovery=load_optional_json_file(args.row_corpus_discovery),
        strict_row_corpus=load_optional_json_file(args.strict_row_corpus),
    )
    if args.format == "json":
        print(audit_to_json(audit))
    else:
        print(audit_to_text(audit))
    if args.require_complete and audit.status != "COMPLETE":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
