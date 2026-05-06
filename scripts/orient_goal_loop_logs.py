#!/usr/bin/env python3
"""Orient GOAL LOOP live-log findings from Observe scanner JSON.

This consumes the JSON emitted by ``observe_goal_loop_logs.py`` and turns raw
pattern counts into a small finding-oriented report. It does not mark anything
as fixed; absence of log evidence is only reported as ``EVIDENCE_ABSENT``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, TextIO


AUDIT_FINDING_ID_RE = re.compile(r"\b(?:R-FATAL|CC|CD|CE|CF|NF)-[0-9]+\b")
SOURCE_STRUCTURED_ITEM_ID_RE = re.compile(
    r"\b(?:R-FATAL|CC|CD|CE|CF|NF|NEW|P-[A-Z]+)-[0-9]+\b|\b[SF][0-9]{2}\b"
)
SHA256_RE = re.compile(r"\A[0-9a-f]{64}\Z")
USER_LOCAL_PATH_RE = re.compile(
    r"(?i)(?:^|[\s\"'=(:,])(?:/(?:Users|home)/[^/\s,]+|[A-Z]:[\\/]+Users[\\/]+[^\\/,\s]+|[\\/]+Users[\\/]+[^\\/,\s]+)"
)
STRICT_ROW_CORPUS_SOURCE_PREFIX = "prompt_corpus/GOAL_LOOP/"
STRICT_ROW_CORPUS_SEVERITIES = {"critical", "warning", "info"}
STRICT_ROW_CORPUS_ERROR_LIMIT = 20


def structured_item_id_family(item_id: str) -> str:
    if item_id.startswith("R-FATAL-"):
        return "R-FATAL"
    if item_id.startswith("P-"):
        parts = item_id.split("-")
        if len(parts) >= 2:
            return "-".join(parts[:2])
        return "P"
    if re.fullmatch(r"[SF][0-9]+", item_id):
        return item_id[0]
    return item_id.split("-", 1)[0]


def structured_item_id_family_summary(
    structured_item_ids: set[str],
    catalog_finding_ids: set[str],
) -> list[dict[str, Any]]:
    families: dict[str, dict[str, Any]] = {}
    for item_id in sorted(structured_item_ids):
        family = structured_item_id_family(item_id)
        entry = families.setdefault(
            family,
            {
                "family": family,
                "total": 0,
                "uncataloged": 0,
                "uncataloged_samples": [],
            },
        )
        entry["total"] += 1
        if item_id in catalog_finding_ids:
            continue
        entry["uncataloged"] += 1
        samples = entry["uncataloged_samples"]
        if len(samples) < 10:
            samples.append(item_id)
    return [families[family] for family in sorted(families)]


def exact_number_pattern(value: int) -> str:
    return rf"(?<!\d){value}(?!\d)"


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


def load_strict_row_corpus_input(path: str | None) -> dict[str, Any] | None:
    if path is None:
        return None
    with Path(path).open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("expected strict row corpus JSON object")
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


def consistency_finding_is_open(finding: Any) -> bool:
    if not isinstance(finding, dict):
        return True
    status = finding.get("status")
    if not isinstance(status, str):
        return True
    return status.upper() not in {"CLOSED", "COMPLETE", "DONE", "RESOLVED"}


def row_label(index: int, raw: dict[str, Any]) -> str:
    finding_id = raw.get("finding_id")
    return (
        finding_id if isinstance(finding_id, str) and finding_id else f"index:{index}"
    )


def validate_strict_row_corpus(
    strict_row_corpus: dict[str, Any],
    *,
    catalog: dict[str, Any] | None = None,
) -> dict[str, Any]:
    errors: list[str] = []
    duplicate_ids: list[str] = []
    invalid_rows: list[str] = []
    invalid_source_paths: list[str] = []
    invalid_line_refs: list[str] = []
    invalid_replay_expectations: list[str] = []

    schema_version = strict_row_corpus.get("schema_version")
    corpus_id = strict_row_corpus.get("corpus_id")
    source_catalog_id = strict_row_corpus.get("source_catalog_id")
    corpus_status = strict_row_corpus.get("status")
    expected_total = strict_row_corpus.get("expected_findings_total")
    findings_raw = strict_row_corpus.get("findings")
    findings = findings_raw if isinstance(findings_raw, list) else []
    catalog_id = catalog.get("catalog_id") if isinstance(catalog, dict) else None

    if schema_version != 1:
        errors.append("schema_version_must_be_1")
    if not isinstance(corpus_id, str) or not corpus_id:
        errors.append("corpus_id_missing")
    if not isinstance(source_catalog_id, str) or not source_catalog_id:
        errors.append("source_catalog_id_missing")
    if isinstance(catalog_id, str) and source_catalog_id != catalog_id:
        errors.append("source_catalog_id_mismatch")
    if corpus_status != "COMPLETE":
        errors.append("status_must_be_COMPLETE")
    if catalog is not None and expected_total != catalog.get("expected_findings_total"):
        errors.append("expected_findings_total_mismatch")
    if not isinstance(expected_total, int):
        errors.append("expected_findings_total_must_be_int")
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
        finding_id = raw.get("finding_id")
        title = raw.get("title")
        severity = raw.get("severity")
        actionability = raw.get("actionability")
        decision_id = raw.get("decision_id")
        patterns_raw = raw.get("patterns", [])
        source = raw.get("source")
        replay_expectation = raw.get("replay_expectation")

        if not isinstance(finding_id, str) or not finding_id:
            invalid_rows.append(label)
        elif finding_id in seen_ids:
            duplicate_ids.append(finding_id)
        else:
            seen_ids.add(finding_id)
        if not isinstance(title, str) or not title:
            invalid_rows.append(label)
        if severity not in STRICT_ROW_CORPUS_SEVERITIES:
            invalid_rows.append(label)
        if not isinstance(actionability, str) or not actionability:
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
            phase = replay_expectation.get("phase")
            expected_status = replay_expectation.get("expected_status")
            if (
                not isinstance(phase, str)
                or not phase
                or not isinstance(expected_status, str)
                or not expected_status
            ):
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
    return {
        "corpus_status": corpus_status,
        "corpus_id": corpus_id if isinstance(corpus_id, str) else None,
        "source_catalog_id": source_catalog_id
        if isinstance(source_catalog_id, str)
        else None,
        "provided": True,
        "validated": not errors,
        "errors_total": len(errors),
        "errors": errors[:STRICT_ROW_CORPUS_ERROR_LIMIT],
        "expected_findings_total": expected_total,
        "row_count": len(findings),
        "row_count_matches_expected": isinstance(expected_total, int)
        and len(findings) == expected_total,
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


def contains_user_local_path(value: Any) -> bool:
    if isinstance(value, str):
        return USER_LOCAL_PATH_RE.search(value) is not None
    if isinstance(value, list):
        return any(contains_user_local_path(item) for item in value)
    if isinstance(value, dict):
        return any(contains_user_local_path(item) for item in value.values())
    return False


def catalog_with_strict_row_corpus(
    catalog: dict[str, Any] | None,
    strict_row_corpus: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if strict_row_corpus is None:
        return catalog
    merged = dict(catalog or {})
    summary = validate_strict_row_corpus(strict_row_corpus, catalog=merged)
    merged["strict_row_corpus"] = summary
    if summary["validated"]:
        findings_raw = strict_row_corpus.get("findings")
        merged["findings"] = (
            list(findings_raw) if isinstance(findings_raw, list) else []
        )
        expected_total = strict_row_corpus.get("expected_findings_total")
        if isinstance(expected_total, int):
            merged["expected_findings_total"] = expected_total
        merged["source_status"] = "strict_row_corpus_complete"
    return merged


def valid_external_source(source: Any) -> dict[str, Any] | None:
    if not isinstance(source, dict):
        return None
    path = source.get("path")
    if not isinstance(path, str) or not path:
        return None
    line_refs = source.get("line_refs", [])
    if line_refs is not None and not isinstance(line_refs, list):
        return None
    if isinstance(line_refs, list) and any(
        not isinstance(item, int) for item in line_refs
    ):
        return None
    sha256 = source.get("sha256")
    if sha256 is not None and (
        not isinstance(sha256, str) or SHA256_RE.fullmatch(sha256) is None
    ):
        return None
    line_count = source.get("line_count")
    if line_count is not None and (not isinstance(line_count, int) or line_count < 0):
        return None
    return source


def catalog_specs(catalog: dict[str, Any] | None) -> list[FindingSpec]:
    if catalog is None:
        return []
    findings_raw = catalog.get("findings", [])
    if not isinstance(findings_raw, list):
        raise ValueError("audit catalog findings must be a list")

    specs: list[FindingSpec] = []
    builtin_by_id = {spec.finding_id: spec for spec in FINDINGS}
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
        base = builtin_by_id.get(finding_id)
        if title is None and base is not None:
            title = base.title
        if severity is None and base is not None:
            severity = base.severity
        if not isinstance(title, str) or not title:
            raise ValueError(f"audit catalog finding {finding_id} missing title")
        if severity not in ("critical", "warning", "info"):
            raise ValueError(f"audit catalog finding {finding_id} has invalid severity")

        patterns_raw = raw.get(
            "patterns", list(base.patterns) if base is not None else []
        )
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
        if decision_id is None and base is not None:
            decision_id = base.decision_id
        if decision_id is not None and not isinstance(decision_id, str):
            raise ValueError(
                f"audit catalog finding {finding_id} decision_id must be string"
            )
        actionability = raw.get(
            "actionability",
            base.actionability if base is not None else "actionable",
        )
        if not isinstance(actionability, str) or not actionability:
            raise ValueError(
                f"audit catalog finding {finding_id} actionability missing"
            )
        source = raw.get("source", base.source if base is not None else None)
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
    strict_row_corpus = (
        catalog.get("strict_row_corpus") if catalog is not None else None
    )
    if (
        isinstance(strict_row_corpus, dict)
        and strict_row_corpus.get("validated") is True
    ):
        return catalog_specs(catalog)
    merged: dict[str, FindingSpec] = {spec.finding_id: spec for spec in FINDINGS}
    ordered_ids = [spec.finding_id for spec in FINDINGS]
    for spec in catalog_specs(catalog):
        if spec.finding_id not in merged:
            ordered_ids.append(spec.finding_id)
        merged[spec.finding_id] = spec
    return [merged[finding_id] for finding_id in ordered_ids]


def aggregate_claim_patterns(claim: dict[str, Any]) -> list[re.Pattern[str]]:
    claimed_total = claim.get("claimed_total")
    if not isinstance(claimed_total, int):
        return []
    number = exact_number_pattern(claimed_total)
    claim_id = claim.get("claim_id")
    claim_id_text = claim_id if isinstance(claim_id, str) else ""
    if claim_id_text.startswith("audit_total"):
        return [
            re.compile(rf"{number}[^\n]{{0,40}}(?:건\s*)?감사", re.IGNORECASE),
            re.compile(rf"{number}[^\n]{{0,40}}findings?", re.IGNORECASE),
            re.compile(rf"(?:감사|findings?)[^\n]{{0,40}}{number}", re.IGNORECASE),
        ]
    if "new_findings" in claim_id_text.lower():
        return [
            re.compile(
                rf"(?:NEW_FINDING|NEW|new patterns)[^\n]{{0,80}}{number}",
                re.IGNORECASE,
            ),
            re.compile(
                rf"{number}[^\n]{{0,80}}"
                r"(?:NEW_FINDING|NEW|new patterns|from live logs)",
                re.IGNORECASE,
            ),
        ]
    if "keeper" in claim_id_text.lower():
        return [
            re.compile(rf"{number}[^\n]{{0,60}}keepers?", re.IGNORECASE),
            re.compile(rf"(?:GOAL|목표)[^\n]{{0,100}}{number}", re.IGNORECASE),
        ]
    return [re.compile(number)]


def aggregate_claim_source_summary(
    catalog: dict[str, Any],
    resolved_contents: dict[str, str],
) -> dict[str, Any]:
    aggregate_claims_raw = catalog.get("aggregate_claims", [])
    aggregate_claims = (
        aggregate_claims_raw if isinstance(aggregate_claims_raw, list) else []
    )
    missing_samples: list[dict[str, Any]] = []
    checked_sources = 0
    verified_sources = 0

    for claim in aggregate_claims:
        if not isinstance(claim, dict):
            continue
        source_paths_raw = claim.get("source_paths", [])
        source_paths = source_paths_raw if isinstance(source_paths_raw, list) else []
        patterns = aggregate_claim_patterns(claim)
        for path_raw in source_paths:
            if not isinstance(path_raw, str) or not path_raw:
                continue
            checked_sources += 1
            content = resolved_contents.get(path_raw)
            claim_found = content is not None and any(
                pattern.search(content) for pattern in patterns
            )
            if claim_found:
                verified_sources += 1
                continue
            missing_samples.append(
                {
                    "claim_id": claim.get("claim_id", "unknown"),
                    "claimed_total": claim.get("claimed_total"),
                    "path": path_raw,
                }
            )

    missing_sources = checked_sources - verified_sources
    if checked_sources == 0:
        status = "NOT_APPLICABLE"
    elif missing_sources == 0:
        status = "COMPLETE"
    else:
        status = "INCOMPLETE"
    return {
        "source_aggregate_claim_status": status,
        "source_aggregate_claims_total": len(
            [claim for claim in aggregate_claims if isinstance(claim, dict)]
        ),
        "source_aggregate_claim_sources_total": checked_sources,
        "source_aggregate_claim_sources_verified": verified_sources,
        "source_aggregate_claim_sources_missing": missing_sources,
        "source_aggregate_claim_missing_samples": missing_samples[:10],
    }


def aggregate_claim_totals(catalog: dict[str, Any]) -> dict[str, int]:
    aggregate_claims_raw = catalog.get("aggregate_claims", [])
    aggregate_claims = (
        aggregate_claims_raw if isinstance(aggregate_claims_raw, list) else []
    )
    totals: dict[str, int] = {}
    for claim in aggregate_claims:
        if not isinstance(claim, dict):
            continue
        claim_id = claim.get("claim_id")
        claimed_total = claim.get("claimed_total")
        if isinstance(claim_id, str) and isinstance(claimed_total, int):
            totals[claim_id] = claimed_total
    return totals


def aggregate_reconciliation_summary(catalog: dict[str, Any]) -> dict[str, Any]:
    reconciliations_raw = catalog.get("aggregate_reconciliations", [])
    reconciliations = (
        reconciliations_raw if isinstance(reconciliations_raw, list) else []
    )
    claim_totals = aggregate_claim_totals(catalog)
    verified = 0
    failed_samples: list[dict[str, Any]] = []

    for reconciliation in reconciliations:
        if not isinstance(reconciliation, dict):
            failed_samples.append(
                {"reconciliation_id": "unknown", "error": "malformed"}
            )
            continue
        reconciliation_id = reconciliation.get("reconciliation_id")
        target_claim_id = reconciliation.get("target_claim_id")
        operation = reconciliation.get("operation")
        terms_raw = reconciliation.get("terms", [])
        terms = terms_raw if isinstance(terms_raw, list) else []
        sample: dict[str, Any] = {
            "reconciliation_id": reconciliation_id
            if isinstance(reconciliation_id, str)
            else "unknown",
            "target_claim_id": target_claim_id,
        }
        if not isinstance(target_claim_id, str) or not target_claim_id:
            sample["error"] = "missing_target_claim_id"
            failed_samples.append(sample)
            continue
        if operation != "sum":
            sample["error"] = "unsupported_operation"
            sample["operation"] = operation
            failed_samples.append(sample)
            continue
        target_total = claim_totals.get(target_claim_id)
        if target_total is None:
            sample["error"] = "unknown_target_claim"
            failed_samples.append(sample)
            continue
        term_ids: list[str] = []
        missing_terms: list[str] = []
        term_total = 0
        malformed_term = False
        for term in terms:
            if not isinstance(term, dict):
                malformed_term = True
                continue
            claim_id = term.get("claim_id")
            if not isinstance(claim_id, str) or not claim_id:
                malformed_term = True
                continue
            term_ids.append(claim_id)
            claim_total = claim_totals.get(claim_id)
            if claim_total is None:
                missing_terms.append(claim_id)
                continue
            term_total += claim_total
        if malformed_term:
            sample["error"] = "malformed_term"
            sample["terms"] = term_ids
            failed_samples.append(sample)
            continue
        if missing_terms:
            sample["error"] = "unknown_term_claim"
            sample["missing_terms"] = missing_terms
            failed_samples.append(sample)
            continue
        if not term_ids:
            sample["error"] = "missing_terms"
            failed_samples.append(sample)
            continue
        if term_total != target_total:
            sample["error"] = "arithmetic_mismatch"
            sample["claimed_total"] = target_total
            sample["computed_total"] = term_total
            sample["terms"] = term_ids
            failed_samples.append(sample)
            continue
        verified += 1

    total = len(reconciliations)
    failed = total - verified
    if total == 0:
        status = "NOT_APPLICABLE"
    elif failed == 0:
        status = "COMPLETE"
    else:
        status = "INCOMPLETE"
    return {
        "source_aggregate_reconciliation_status": status,
        "source_aggregate_reconciliations_total": total,
        "source_aggregate_reconciliations_verified": verified,
        "source_aggregate_reconciliations_failed": failed,
        "source_aggregate_reconciliation_error_samples": failed_samples[:10],
    }


def has_source_identity_expectation(source: dict[str, Any]) -> bool:
    return isinstance(source.get("sha256"), str) or isinstance(
        source.get("line_count"), int
    )


def source_artifact_summary(
    catalog: dict[str, Any],
    source_root: Path | None,
    source_strip_prefix: str | None = None,
) -> dict[str, Any] | None:
    if source_root is None:
        return None

    refs: dict[str, list[int]] = {}
    source_expectations: dict[str, dict[str, Any]] = {}

    def add_ref(
        path_raw: Any,
        line_refs_raw: Any = None,
        source_raw: dict[str, Any] | None = None,
    ) -> None:
        if not isinstance(path_raw, str) or not path_raw:
            return
        line_refs = refs.setdefault(path_raw, [])
        if isinstance(line_refs_raw, list):
            line_refs.extend(item for item in line_refs_raw if isinstance(item, int))
        if source_raw is not None:
            source_expectations[path_raw] = source_raw

    external_sources = catalog.get("external_sources", [])
    if isinstance(external_sources, list):
        for source in external_sources:
            if isinstance(source, dict):
                add_ref(source.get("path"), source.get("line_refs"), source)

    aggregate_claims = catalog.get("aggregate_claims", [])
    if isinstance(aggregate_claims, list):
        for claim in aggregate_claims:
            if not isinstance(claim, dict):
                continue
            source_paths = claim.get("source_paths", [])
            if isinstance(source_paths, list):
                for path_raw in source_paths:
                    add_ref(path_raw)

    aggregate_reconciliations = catalog.get("aggregate_reconciliations", [])
    if isinstance(aggregate_reconciliations, list):
        for reconciliation in aggregate_reconciliations:
            if not isinstance(reconciliation, dict):
                continue
            source_paths = reconciliation.get("source_paths", [])
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
    invalid_paths: list[str] = []
    line_ref_errors: list[dict[str, Any]] = []
    resolved = 0
    source_finding_ids: set[str] = set()
    source_structured_item_ids: set[str] = set()
    source_structured_item_occurrences: dict[str, list[dict[str, Any]]] = {}
    catalog_finding_ids = {spec.finding_id for spec in catalog_specs(catalog)}
    strict_row_corpus_raw = catalog.get("strict_row_corpus")
    strict_row_corpus = (
        strict_row_corpus_raw if isinstance(strict_row_corpus_raw, dict) else {}
    )
    strict_row_corpus_validated = strict_row_corpus.get("validated") is True
    resolved_contents: dict[str, str] = {}
    source_identity_errors: list[dict[str, Any]] = []
    source_identity_checked_paths: set[str] = set()
    source_identity_checks_total = 0
    source_identity_checks_verified = 0

    source_root_resolved = source_root.resolve(strict=False)

    def resolve_candidate(path_text: str) -> Path | None:
        path = Path(path_text)
        if path.is_absolute():
            return None
        if source_strip_prefix is None:
            candidate = source_root / path
        else:
            normalized_prefix = source_strip_prefix.strip("/")
            normalized_path = path_text.strip("/")
            prefix = f"{normalized_prefix}/"
            if normalized_path.startswith(prefix):
                candidate = source_root / normalized_path[len(prefix) :]
            else:
                candidate = source_root / path
        candidate_resolved = candidate.resolve(strict=False)
        if not candidate_resolved.is_relative_to(source_root_resolved):
            return None
        return candidate

    for path_text, line_refs in sorted(refs.items()):
        candidate = resolve_candidate(path_text)
        if candidate is None:
            invalid_paths.append(path_text)
            continue
        if not candidate.is_file():
            missing_paths.append(path_text)
            continue
        resolved += 1
        content_bytes = candidate.read_bytes()
        content = content_bytes.decode("utf-8")
        resolved_contents[path_text] = content
        source_finding_ids.update(AUDIT_FINDING_ID_RE.findall(content))
        for line_number, line in enumerate(content.splitlines(), start=1):
            for match in SOURCE_STRUCTURED_ITEM_ID_RE.finditer(line):
                item_id = match.group(0)
                source_structured_item_ids.add(item_id)
                source_structured_item_occurrences.setdefault(item_id, []).append(
                    {
                        "item_id": item_id,
                        "family": structured_item_id_family(item_id),
                        "path": path_text,
                        "line": line_number,
                    }
                )
        source_expectation = source_expectations.get(path_text)
        if source_expectation is not None and has_source_identity_expectation(
            source_expectation
        ):
            source_identity_checked_paths.add(path_text)
            source_identity_checks_total += 1
            identity_errors: dict[str, Any] = {"path": path_text}
            expected_sha256 = source_expectation.get("sha256")
            if isinstance(expected_sha256, str):
                actual_sha256 = hashlib.sha256(content_bytes).hexdigest()
                if actual_sha256 != expected_sha256:
                    identity_errors["sha256"] = {
                        "expected": expected_sha256,
                        "actual": actual_sha256,
                    }
            expected_line_count = source_expectation.get("line_count")
            line_count = len(content.splitlines())
            if (
                isinstance(expected_line_count, int)
                and line_count != expected_line_count
            ):
                identity_errors["line_count"] = {
                    "expected": expected_line_count,
                    "actual": line_count,
                }
            if len(identity_errors) == 1:
                source_identity_checks_verified += 1
            else:
                source_identity_errors.append(identity_errors)
        if not line_refs:
            continue
        line_count = len(content.splitlines())
        bad_refs = sorted(
            {
                line_ref
                for line_ref in line_refs
                if line_ref < 1 or line_ref > line_count
            }
        )
        if bad_refs:
            line_ref_errors.append(
                {
                    "path": path_text,
                    "line_count": line_count,
                    "line_refs": bad_refs,
                }
            )

    source_ids_missing_from_catalog = sorted(source_finding_ids - catalog_finding_ids)
    if strict_row_corpus_validated:
        catalog_ids_missing_from_source: list[str] = []
        source_itemized_finding_ids_total = len(catalog_finding_ids)
        source_itemized_id_basis = "strict_row_corpus"
    else:
        catalog_ids_missing_from_source = sorted(
            catalog_finding_ids - source_finding_ids
        )
        source_itemized_finding_ids_total = len(source_finding_ids)
        source_itemized_id_basis = "source_documents"
    source_structured_ids_uncataloged = sorted(
        source_structured_item_ids - catalog_finding_ids
    )
    source_structured_uncataloged_occurrences = [
        occurrence
        for item_id in source_structured_ids_uncataloged
        for occurrence in source_structured_item_occurrences.get(item_id, [])
    ]
    source_structured_item_id_families = structured_item_id_family_summary(
        source_structured_item_ids,
        catalog_finding_ids,
    )
    source_itemized_id_status = (
        "COMPLETE"
        if not source_ids_missing_from_catalog and not catalog_ids_missing_from_source
        else "INCOMPLETE"
    )
    aggregate_claims = aggregate_claim_source_summary(catalog, resolved_contents)
    source_aggregate_claim_status = aggregate_claims["source_aggregate_claim_status"]
    aggregate_reconciliations = aggregate_reconciliation_summary(catalog)
    source_aggregate_reconciliation_status = aggregate_reconciliations[
        "source_aggregate_reconciliation_status"
    ]
    for path_text, source_expectation in sorted(source_expectations.items()):
        if path_text in source_identity_checked_paths:
            continue
        if not has_source_identity_expectation(source_expectation):
            continue
        source_identity_checks_total += 1
        source_identity_errors.append({"path": path_text, "error": "not_resolved"})
    source_identity_checks_failed = (
        source_identity_checks_total - source_identity_checks_verified
    )
    if source_identity_checks_total == 0:
        source_identity_status = "NOT_APPLICABLE"
    elif source_identity_checks_failed == 0:
        source_identity_status = "COMPLETE"
    else:
        source_identity_status = "INCOMPLETE"
    status = (
        "COMPLETE"
        if not invalid_paths
        and not missing_paths
        and not line_ref_errors
        and source_itemized_id_status == "COMPLETE"
        and source_aggregate_claim_status in {"COMPLETE", "NOT_APPLICABLE"}
        and source_aggregate_reconciliation_status in {"COMPLETE", "NOT_APPLICABLE"}
        and source_identity_status in {"COMPLETE", "NOT_APPLICABLE"}
        else "INCOMPLETE"
    )
    return {
        "status": status,
        "source_root": str(source_root),
        "source_strip_prefix": source_strip_prefix,
        "source_artifacts_total": len(refs),
        "source_artifacts_resolved": resolved,
        "source_artifacts_missing": len(missing_paths),
        "source_artifacts_invalid_paths": len(invalid_paths),
        "line_ref_errors": len(line_ref_errors),
        "source_itemized_id_status": source_itemized_id_status,
        "source_itemized_id_basis": source_itemized_id_basis,
        "source_itemized_finding_ids_total": source_itemized_finding_ids_total,
        "source_document_itemized_finding_ids_total": len(source_finding_ids),
        "catalog_itemized_finding_ids_total": len(catalog_finding_ids),
        "source_ids_missing_from_catalog": len(source_ids_missing_from_catalog),
        "catalog_ids_missing_from_source": len(catalog_ids_missing_from_source),
        "source_structured_item_ids_total": len(source_structured_item_ids),
        "source_structured_item_ids_uncataloged": len(
            source_structured_ids_uncataloged
        ),
        "source_structured_item_ids_uncataloged_occurrences": len(
            source_structured_uncataloged_occurrences
        ),
        "source_structured_item_id_families": source_structured_item_id_families,
        **aggregate_claims,
        **aggregate_reconciliations,
        "source_identity_status": source_identity_status,
        "source_identity_checks_total": source_identity_checks_total,
        "source_identity_checks_verified": source_identity_checks_verified,
        "source_identity_checks_failed": source_identity_checks_failed,
        "source_identity_error_samples": source_identity_errors[:10],
        "invalid_paths": invalid_paths[:10],
        "missing_paths": missing_paths[:10],
        "line_ref_error_samples": line_ref_errors[:10],
        "source_ids_missing_from_catalog_samples": source_ids_missing_from_catalog[:10],
        "catalog_ids_missing_from_source_samples": catalog_ids_missing_from_source[:10],
        "source_structured_item_ids_uncataloged_samples": (
            source_structured_ids_uncataloged[:20]
        ),
        "source_structured_item_ids_uncataloged_occurrence_samples": (
            source_structured_uncataloged_occurrences[:30]
        ),
    }


def audit_catalog_summary(
    catalog: dict[str, Any] | None,
    *,
    source_root: Path | None = None,
    source_strip_prefix: str | None = None,
) -> dict[str, Any] | None:
    if catalog is None:
        return None
    specs = catalog_specs(catalog)
    expected_raw = catalog.get("expected_findings_total")
    expected = expected_raw if isinstance(expected_raw, int) else None
    external_sources_raw = catalog.get("external_sources", [])
    external_sources_list = (
        external_sources_raw if isinstance(external_sources_raw, list) else []
    )
    external_sources = [
        source
        for source in (
            valid_external_source(source) for source in external_sources_list
        )
        if source is not None
    ]
    invalid_external_sources = len(external_sources_list) - len(external_sources)
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
    consistency_raw = catalog.get("consistency_findings", [])
    consistency_findings = consistency_raw if isinstance(consistency_raw, list) else []
    open_consistency_findings = [
        finding
        for finding in consistency_findings
        if consistency_finding_is_open(finding)
    ]
    summary = {
        "catalog_id": catalog.get("catalog_id", "unknown"),
        "source_status": catalog.get("source_status", "unknown"),
        "status": status,
        "expected_findings_total": expected,
        "itemized_findings_total": itemized,
        "missing_itemized_findings": missing,
        "external_sources_total": source_covered,
        "external_sources_invalid": invalid_external_sources,
        "source_documents_expected": source_expected,
        "source_documents_covered": source_covered,
        "source_documents_status": source_status,
        "external_sources": external_sources,
        "aggregate_claims": catalog.get("aggregate_claims", []),
        "aggregate_reconciliations": catalog.get("aggregate_reconciliations", []),
        "consistency_findings": consistency_findings,
        "consistency_findings_total": len(consistency_findings),
        "consistency_findings_open": len(open_consistency_findings),
        "strict_row_corpus": catalog.get("strict_row_corpus"),
    }
    artifacts = source_artifact_summary(
        catalog,
        source_root,
        source_strip_prefix=source_strip_prefix,
    )
    if artifacts is not None:
        summary["source_artifacts"] = artifacts
    return summary


def orient_scan(
    scan: dict[str, Any],
    *,
    audit_catalog: dict[str, Any] | None = None,
    strict_row_corpus: dict[str, Any] | None = None,
    audit_source_root: Path | None = None,
    audit_source_strip_prefix: str | None = None,
) -> OrientReport:
    audit_catalog = catalog_with_strict_row_corpus(audit_catalog, strict_row_corpus)
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
            source_strip_prefix=audit_source_strip_prefix,
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
        strict_row_corpus = report.audit_catalog.get("strict_row_corpus")
        if isinstance(strict_row_corpus, dict) and strict_row_corpus.get("provided"):
            lines.append(
                "strict_row_corpus: "
                f"validated={strict_row_corpus['validated']} "
                f"rows={strict_row_corpus['row_count']} "
                f"errors={strict_row_corpus['errors_total']}"
            )
        source_artifacts = report.audit_catalog.get("source_artifacts")
        if isinstance(source_artifacts, dict):
            lines.append(
                "source_artifacts: "
                f"{source_artifacts['status']} "
                f"resolved={source_artifacts['source_artifacts_resolved']} "
                f"missing={source_artifacts['source_artifacts_missing']} "
                f"line_ref_errors={source_artifacts['line_ref_errors']} "
                f"source_ids={source_artifacts['source_itemized_finding_ids_total']} "
                f"basis={source_artifacts['source_itemized_id_basis']}"
            )
            lines.append(
                "aggregate_claim_sources: "
                f"{source_artifacts['source_aggregate_claim_status']} "
                f"verified={source_artifacts['source_aggregate_claim_sources_verified']} "
                f"missing={source_artifacts['source_aggregate_claim_sources_missing']}"
            )
            lines.append(
                "aggregate_reconciliations: "
                f"{source_artifacts['source_aggregate_reconciliation_status']} "
                f"verified={source_artifacts['source_aggregate_reconciliations_verified']} "
                f"failed={source_artifacts['source_aggregate_reconciliations_failed']}"
            )
            lines.append(
                "source_identity: "
                f"{source_artifacts['source_identity_status']} "
                f"verified={source_artifacts['source_identity_checks_verified']} "
                f"failed={source_artifacts['source_identity_checks_failed']}"
            )
            lines.append(
                "structured_source_ids: "
                f"total={source_artifacts['source_structured_item_ids_total']} "
                f"uncataloged={source_artifacts['source_structured_item_ids_uncataloged']}"
            )
            structured_families = source_artifacts.get(
                "source_structured_item_id_families",
                [],
            )
            if isinstance(structured_families, list):
                uncataloged_families = [
                    f"{family['family']}:{family['uncataloged']}"
                    for family in structured_families
                    if isinstance(family, dict)
                    and isinstance(family.get("family"), str)
                    and isinstance(family.get("uncataloged"), int)
                    and family["uncataloged"] > 0
                ]
                if uncataloged_families:
                    lines.append(
                        "structured_source_id_families: "
                        + ", ".join(uncataloged_families)
                    )
        consistency_findings = report.audit_catalog.get("consistency_findings", [])
        if isinstance(consistency_findings, list) and consistency_findings:
            lines.append(
                "consistency_findings: "
                f"{report.audit_catalog['consistency_findings_total']} "
                f"open={report.audit_catalog['consistency_findings_open']}"
            )
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
        "--strict-row-corpus",
        help=(
            "Optional strict row-level corpus JSON. When valid, its findings "
            "replace audit-catalog findings for strict catalog completeness."
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
        "--audit-source-strip-prefix",
        help=(
            "Optional logical source path prefix to strip before resolving "
            "paths under --audit-source-root."
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
    parser.add_argument(
        "--require-consistency-resolved",
        action="store_true",
        help="Exit non-zero when the audit catalog has open consistency findings.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = orient_scan(
        load_json_input(args.scan_json),
        audit_catalog=load_audit_catalog_input(args.audit_catalog),
        strict_row_corpus=load_strict_row_corpus_input(args.strict_row_corpus),
        audit_source_root=Path(args.audit_source_root)
        if args.audit_source_root is not None
        else None,
        audit_source_strip_prefix=args.audit_source_strip_prefix,
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
    if args.require_consistency_resolved:
        if report.audit_catalog is None:
            return 1
        if report.audit_catalog.get("consistency_findings_open") != 0:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
