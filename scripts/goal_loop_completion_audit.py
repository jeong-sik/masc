#!/usr/bin/env python3
"""Audit whether a GOAL LOOP status snapshot is closeable.

This is intentionally stricter than the compact status summary. It turns the
current Goal closeout rules into explicit criteria, so a green test or a partial
manifest cannot be mistaken for objective completion.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, TextIO

try:
    from scripts.orient_goal_loop_logs import (
        contains_user_local_path,
        validate_strict_row_corpus,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution path
    from orient_goal_loop_logs import (
        contains_user_local_path,
        validate_strict_row_corpus,
    )


POST_ACT_EVIDENCE_KINDS = {
    "live_runtime_http",
    "live_runtime_logs",
    "live_runtime_status",
}
PROMPT_CHECKLIST_STATUSES = {"PASS", "PARTIAL", "BLOCKED"}
PROMPT_CHECKLIST_ISSUE_REF_RE = re.compile(
    r"^https://github\.com/jeong-sik/masc-mcp/issues/\d+$"
)
PROMPT_CHECKLIST_PR_REF_RE = re.compile(
    r"^https://github\.com/jeong-sik/masc-mcp/pull/\d+$"
)
AUTOBOOT_WARMUP_FAIRNESS_ALGORITHM = "int32_djb2_bounded_jitter"
AUTOBOOT_WARMUP_REQUIRED_KEEPERS = (
    "analyst",
    "executor",
    "glm-coding-plan",
    "issue_king",
    "janitor",
    "masc-improver",
    "nick0cave",
    "qa-king",
    "ramarama",
    "sangsu",
    "scholar",
    "taskmaster",
    "velvet-hammer",
    "verifier",
)
PROMPT_SOURCE_PATH_PREFIX = "prompt_corpus/GOAL_LOOP/"
REPO_ROOT = Path(__file__).resolve().parents[1]
REQUIRED_VERIFY_GATE_IDS = frozenset(
    {
        "unit_tests",
        "keeper_turn_success_rate_healthy",
        "no_semaphore_skip",
        "no_pricing_miss",
        "no_utf8_repair",
        "recovery_executed",
        "admission_backpressure_observed",
        "dashboard_snapshot_latency_p99",
        "orient_recheck_no_still_present",
        "orient_recheck_no_new_finding",
        "tla_prompt_spec_tierrouting",
        "tla_prompt_spec_validation",
        "tla_prompt_spec_liveness",
        "post_act_log_contract",
    }
)


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


def as_strict_int(value: Any) -> int | None:
    return value if type(value) is int else None


def as_nonempty_str(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped if stripped else None


def string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [
        stripped for item in value if (stripped := as_nonempty_str(item)) is not None
    ]


def stable_keeper_name_hash(name: str) -> int:
    acc = 5381
    for byte in name.encode("utf-8"):
        acc = ((acc << 5) + acc + byte) & 0x3FFF_FFFF
    return acc


def prompt_source_list(value: Any) -> tuple[list[str], dict[str, Any]]:
    if not isinstance(value, list):
        return [], {
            "prompt_sources_is_list": False,
            "invalid_prompt_sources_checked": 1,
            "duplicate_prompt_sources_checked": [],
            "invalid_prompt_source_prefixes": [],
            "prompt_sources_unique": True,
            "prompt_sources_have_expected_prefix": True,
            "prompt_sources_valid": False,
        }

    sources = string_list(value)
    invalid_count = len(value) - len(sources)
    seen: set[str] = set()
    duplicates: set[str] = set()
    for source in sources:
        if source in seen:
            duplicates.add(source)
        seen.add(source)
    invalid_prefixes = sorted(
        source
        for source in set(sources)
        if not source.startswith(PROMPT_SOURCE_PATH_PREFIX)
    )
    prompt_sources_unique = not duplicates
    prompt_sources_have_expected_prefix = not invalid_prefixes
    return sources, {
        "prompt_sources_is_list": True,
        "invalid_prompt_sources_checked": invalid_count,
        "duplicate_prompt_sources_checked": sorted(duplicates),
        "invalid_prompt_source_prefixes": invalid_prefixes,
        "prompt_sources_unique": prompt_sources_unique,
        "prompt_sources_have_expected_prefix": prompt_sources_have_expected_prefix,
        "prompt_sources_valid": (
            invalid_count == 0
            and prompt_sources_unique
            and prompt_sources_have_expected_prefix
        ),
    }


def repo_artifact_path(value: Any) -> str | None:
    artifact_ref = as_nonempty_str(value)
    if artifact_ref is None or contains_user_local_path(artifact_ref):
        return None
    artifact_path = artifact_ref.split("#", 1)[0].strip()
    if not artifact_path:
        return None
    parsed = Path(artifact_path)
    if parsed.is_absolute() or ".." in parsed.parts:
        return None
    return artifact_path


def repo_artifact_anchor(value: Any) -> str | None:
    artifact_ref = as_nonempty_str(value)
    if artifact_ref is None or "#" not in artifact_ref:
        return None
    anchor = artifact_ref.split("#", 1)[1].strip()
    return anchor or None


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
    else:
        status = "FAIL"
    if warning and not passed:
        evidence = {**evidence, "severity": "warning"}
    return CompletionCriterion(
        criterion_id=criterion_id,
        status=status,
        summary=summary,
        evidence=evidence,
    )


def structured_triage_evidence(
    structured_evidence: dict[str, Any],
    structured_id_triage: dict[str, Any] | None,
    *,
    source_catalog_id: Any,
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
    triage_catalog_id = structured_id_triage.get("source_catalog_id")
    source_catalog_id_matches = (
        isinstance(source_catalog_id, str)
        and isinstance(triage_catalog_id, str)
        and triage_catalog_id == source_catalog_id
    )
    passed = (
        triage_status == "TRIAGED"
        and source_catalog_id_matches
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
        "source_catalog_id": source_catalog_id,
        "triage_source_catalog_id": triage_catalog_id,
        "source_catalog_id_matches": source_catalog_id_matches,
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
    discovery_catalog_id = row_corpus_discovery.get("source_catalog_id")
    row_catalog_id = row_catalog_evidence.get("catalog_id")
    source_catalog_id_matches = (
        isinstance(row_catalog_id, str)
        and isinstance(discovery_catalog_id, str)
        and discovery_catalog_id == row_catalog_id
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
        and source_catalog_id_matches
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
        "source_catalog_id": row_catalog_id,
        "discovery_source_catalog_id": discovery_catalog_id,
        "source_catalog_id_matches": source_catalog_id_matches,
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


def sum_unique_candidate_rows(value: Any) -> int | None:
    if not isinstance(value, list):
        return None
    total = 0
    for item in value:
        if not isinstance(item, dict):
            return None
        rows = item.get("unique_candidate_rows")
        if not isinstance(rows, int):
            return None
        total += rows
    return total


def source_candidate_row_details(
    *,
    candidate_rows_raw: Any,
    expected_count: Any,
    prompt_sources: set[str],
    expected_by_file: dict[str, int],
    expected_by_rule: dict[str, int],
    text_redacted: bool,
) -> dict[str, Any]:
    if candidate_rows_raw is None:
        # The inventory generator only emits [candidate_text_redacted] when
        # [candidate_rows] are included. A truthy redaction flag with no rows
        # is an inconsistent artifact shape; surface it as a validation error
        # instead of silently treating the missing rows as "fully valid".
        text_redaction_valid = not text_redacted
        invalid_rows: list[str] = []
        if not text_redaction_valid:
            invalid_rows.append("redaction_flag_without_candidate_rows")
        # The rows array was not recorded, so the array count cannot be said to
        # match a real expected count. Keep the omitted-rows shape valid when
        # no redaction flag is present, but report the count-match field as
        # false so evidence consumers do not read "0 rows" as matching the
        # inventory's expected row total.
        count_matches = not isinstance(expected_count, int)
        return {
            "candidate_rows_recorded": False,
            "candidate_rows_count": 0,
            "candidate_rows_valid": text_redaction_valid,
            "candidate_rows_count_matches": count_matches,
            "candidate_row_ids_unique": True,
            "candidate_row_paths_match_summary": True,
            "candidate_row_rules_match_summary": True,
            "candidate_text_redacted": text_redacted,
            "candidate_text_redaction_valid": text_redaction_valid,
            "invalid_candidate_rows": invalid_rows,
            "duplicate_candidate_row_ids": [],
        }
    if not isinstance(candidate_rows_raw, list):
        return {
            "candidate_rows_recorded": False,
            "candidate_rows_count": 0,
            "candidate_rows_valid": False,
            "candidate_rows_count_matches": False,
            "candidate_row_ids_unique": False,
            "candidate_row_paths_match_summary": False,
            "candidate_row_rules_match_summary": False,
            "candidate_text_redacted": text_redacted,
            "candidate_text_redaction_valid": False,
            "invalid_candidate_rows": ["candidate_rows_not_list"],
            "duplicate_candidate_row_ids": [],
        }

    invalid_rows: list[str] = []
    row_ids: list[str] = []
    path_counts: dict[str, int] = {}
    rule_counts: dict[str, int] = {}
    text_redaction_valid = True
    for index, item in enumerate(candidate_rows_raw):
        label = f"row[{index}]"
        if not isinstance(item, dict):
            invalid_rows.append(f"{label}: not_object")
            continue
        candidate_id = as_nonempty_str(item.get("candidate_id"))
        if candidate_id is None:
            invalid_rows.append(f"{label}: missing_candidate_id")
        else:
            label = candidate_id
            row_ids.append(candidate_id)
        extraction_rule = as_nonempty_str(item.get("extraction_rule"))
        if extraction_rule is None:
            invalid_rows.append(f"{label}: missing_extraction_rule")
        else:
            rule_counts[extraction_rule] = rule_counts.get(extraction_rule, 0) + 1
        source = item.get("source")
        if not isinstance(source, dict):
            invalid_rows.append(f"{label}: missing_source")
        else:
            source_path = as_nonempty_str(source.get("path"))
            line_refs = source.get("line_refs")
            if source_path is None or source_path not in prompt_sources:
                invalid_rows.append(f"{label}: invalid_source_path")
            else:
                path_counts[source_path] = path_counts.get(source_path, 0) + 1
            if (
                not isinstance(line_refs, list)
                or not line_refs
                or not all(
                    isinstance(line_ref, int) and line_ref > 0 for line_ref in line_refs
                )
            ):
                invalid_rows.append(f"{label}: invalid_line_refs")
        if text_redacted and any(
            key in item for key in ("title", "snippet", "severity_hint")
        ):
            text_redaction_valid = False
            invalid_rows.append(f"{label}: unredacted_candidate_text")

    # Single-pass O(n) duplicate detection. The previous comprehension called
    # row_ids.count() per element, making this O(n^2) — fine at today's
    # ~132–206 rows but a footgun if the inventory ever grows.
    duplicate_ids = sorted(
        candidate_id for candidate_id, freq in Counter(row_ids).items() if freq > 1
    )
    candidate_rows_count = len(candidate_rows_raw)
    candidate_rows_count_matches = (
        isinstance(expected_count, int) and candidate_rows_count == expected_count
    )
    row_ids_unique = len(duplicate_ids) == 0 and len(row_ids) == candidate_rows_count
    paths_match_summary = path_counts == expected_by_file
    rules_match_summary = rule_counts == expected_by_rule
    candidate_rows_valid = (
        candidate_rows_count_matches
        and row_ids_unique
        and paths_match_summary
        and rules_match_summary
        and text_redaction_valid
        and not invalid_rows
    )
    return {
        "candidate_rows_recorded": True,
        "candidate_rows_count": candidate_rows_count,
        "candidate_rows_valid": candidate_rows_valid,
        "candidate_rows_count_matches": candidate_rows_count_matches,
        "candidate_row_ids_unique": row_ids_unique,
        "candidate_row_paths_match_summary": paths_match_summary,
        "candidate_row_rules_match_summary": rules_match_summary,
        "candidate_text_redacted": text_redacted,
        "candidate_text_redaction_valid": text_redaction_valid,
        "invalid_candidate_rows": invalid_rows,
        "duplicate_candidate_row_ids": duplicate_ids,
    }


def source_row_candidate_inventory_evidence(
    row_catalog_evidence: dict[str, Any],
    source_row_candidate_inventory: dict[str, Any] | None,
) -> dict[str, Any]:
    if (
        row_catalog_evidence["status"] == "COMPLETE"
        and source_row_candidate_inventory is None
    ):
        return {"inventory_status": "NOT_REQUIRED", "recorded": False}
    if source_row_candidate_inventory is None:
        return {"inventory_status": "MISSING", "recorded": False}

    sources_raw = source_row_candidate_inventory.get("prompt_sources_checked", [])
    sources, prompt_source_validation = prompt_source_list(sources_raw)
    source_errors_raw = source_row_candidate_inventory.get("source_errors", [])
    source_errors = source_errors_raw if isinstance(source_errors_raw, list) else []
    expected_total = source_row_candidate_inventory.get("expected_findings_total")
    candidate_rows = source_row_candidate_inventory.get("unique_candidate_rows")
    missing_candidate_rows = source_row_candidate_inventory.get(
        "missing_candidate_rows"
    )
    expected_matches = expected_total == row_catalog_evidence["expected_findings_total"]
    missing_candidate_rows_matches = (
        isinstance(expected_total, int)
        and isinstance(candidate_rows, int)
        and missing_candidate_rows == max(expected_total - candidate_rows, 0)
    )
    inventory_catalog_id = source_row_candidate_inventory.get("source_catalog_id")
    row_catalog_id = row_catalog_evidence.get("catalog_id")
    source_catalog_id_matches = (
        isinstance(row_catalog_id, str)
        and isinstance(inventory_catalog_id, str)
        and inventory_catalog_id == row_catalog_id
    )
    incomplete_against_expected = (
        isinstance(candidate_rows, int)
        and isinstance(expected_total, int)
        and candidate_rows < expected_total
    )
    complete_against_expected = (
        isinstance(candidate_rows, int)
        and isinstance(expected_total, int)
        and candidate_rows == expected_total
        and missing_candidate_rows == 0
    )
    candidates_by_file_total = sum_unique_candidate_rows(
        source_row_candidate_inventory.get("candidates_by_file")
    )
    candidates_by_rule_total = sum_unique_candidate_rows(
        source_row_candidate_inventory.get("candidates_by_rule")
    )
    candidates_by_file_total_matches = candidates_by_file_total == candidate_rows
    candidates_by_rule_total_matches = candidates_by_rule_total == candidate_rows
    candidates_by_file_raw = source_row_candidate_inventory.get("candidates_by_file")
    candidates_by_file = (
        candidates_by_file_raw if isinstance(candidates_by_file_raw, list) else []
    )
    candidates_by_rule_raw = source_row_candidate_inventory.get("candidates_by_rule")
    candidates_by_rule = (
        candidates_by_rule_raw if isinstance(candidates_by_rule_raw, list) else []
    )
    source_paths_with_candidates = {
        item.get("path")
        for item in candidates_by_file
        if isinstance(item, dict) and isinstance(item.get("path"), str)
    }
    sources_without_candidates_raw = source_row_candidate_inventory.get(
        "sources_without_candidates"
    )
    sources_without_candidates = (
        sources_without_candidates_raw
        if isinstance(sources_without_candidates_raw, list)
        else []
    )
    source_paths_without_candidates = {
        item for item in sources_without_candidates if isinstance(item, str)
    }
    source_candidate_coverage_raw = source_row_candidate_inventory.get(
        "source_candidate_coverage"
    )
    source_candidate_coverage = (
        source_candidate_coverage_raw
        if isinstance(source_candidate_coverage_raw, dict)
        else {}
    )
    no_candidate_details_raw = source_row_candidate_inventory.get(
        "sources_without_candidate_details"
    )
    no_candidate_details = (
        no_candidate_details_raw if isinstance(no_candidate_details_raw, list) else []
    )
    source_currentness_raw = source_row_candidate_inventory.get("source_currentness")
    source_currentness = (
        source_currentness_raw if isinstance(source_currentness_raw, dict) else {}
    )
    future_date_claims_raw = source_currentness.get("future_date_claims", [])
    future_date_claims = (
        future_date_claims_raw if isinstance(future_date_claims_raw, list) else []
    )
    invalid_future_date_claims = []
    future_date_claim_paths = set()
    blocking_future_date_claim_paths = set()
    for item in future_date_claims:
        if not isinstance(item, dict):
            invalid_future_date_claims.append("not_object")
            continue
        path = item.get("path")
        line_ref = item.get("line_ref")
        date_claim = item.get("date")
        if not isinstance(path, str):
            invalid_future_date_claims.append("missing_path")
            continue
        future_date_claim_paths.add(path)
        if not isinstance(line_ref, int) or line_ref <= 0:
            invalid_future_date_claims.append(path)
        if not isinstance(date_claim, str) or not date_claim:
            invalid_future_date_claims.append(path)
        if not isinstance(item.get("claim_kind"), str) or not item.get("claim_kind"):
            invalid_future_date_claims.append(path)
        currentness_blocking = item.get("currentness_blocking")
        if not isinstance(currentness_blocking, bool):
            invalid_future_date_claims.append(path)
        elif currentness_blocking:
            blocking_future_date_claim_paths.add(path)
    source_currentness_evaluated = source_currentness.get("evaluated") is True
    future_date_claims_total_matches = source_currentness.get(
        "future_date_claims_total"
    ) == len(future_date_claims)
    sources_with_future_date_claims_raw = source_currentness.get(
        "sources_with_future_date_claims"
    )
    sources_with_future_date_claims = (
        sources_with_future_date_claims_raw
        if isinstance(sources_with_future_date_claims_raw, list)
        else []
    )
    future_date_sources_match = (
        set(item for item in sources_with_future_date_claims if isinstance(item, str))
        == future_date_claim_paths
    )
    future_date_sources_count_matches = source_currentness.get(
        "sources_with_future_date_claims_total"
    ) == len(future_date_claim_paths)
    blocking_future_date_claims_total = sum(
        1
        for item in future_date_claims
        if isinstance(item, dict) and item.get("currentness_blocking") is True
    )
    blocking_future_date_claims_total_matches = (
        source_currentness.get("blocking_future_date_claims_total")
        == blocking_future_date_claims_total
    )
    sources_with_blocking_future_date_claims_raw = source_currentness.get(
        "sources_with_blocking_future_date_claims"
    )
    sources_with_blocking_future_date_claims = (
        sources_with_blocking_future_date_claims_raw
        if isinstance(sources_with_blocking_future_date_claims_raw, list)
        else []
    )
    blocking_future_date_sources_match = (
        set(
            item
            for item in sources_with_blocking_future_date_claims
            if isinstance(item, str)
        )
        == blocking_future_date_claim_paths
    )
    blocking_future_date_sources_count_matches = source_currentness.get(
        "sources_with_blocking_future_date_claims_total"
    ) == len(blocking_future_date_claim_paths)
    source_currentness_consistent = (
        source_currentness.get("evaluated") is False
        and source_currentness.get("checked_at") is None
        and source_currentness.get("future_date_claims_total") == 0
        and source_currentness.get("sources_with_future_date_claims_total") == 0
        and source_currentness.get("blocking_future_date_claims_total") == 0
        and source_currentness.get("sources_with_blocking_future_date_claims_total")
        == 0
        and source_currentness.get("current") is True
        and len(future_date_claims) == 0
    ) or (
        source_currentness_evaluated
        and isinstance(source_currentness.get("checked_at"), str)
        and future_date_claims_total_matches
        and future_date_sources_match
        and future_date_sources_count_matches
        and blocking_future_date_claims_total_matches
        and blocking_future_date_sources_match
        and blocking_future_date_sources_count_matches
        and source_currentness.get("current")
        == (blocking_future_date_claims_total == 0)
        and not invalid_future_date_claims
    )
    no_candidate_detail_paths = {
        item.get("path")
        for item in no_candidate_details
        if isinstance(item, dict) and isinstance(item.get("path"), str)
    }
    invalid_no_candidate_details = []
    unstructured_markers_without_candidates = 0
    no_candidate_sources_with_tracking_issue_refs = 0
    no_candidate_tracking_issue_refs: set[str] = set()
    missing_no_candidate_tracking_issue_refs: list[str] = []
    invalid_no_candidate_tracking_issue_refs: list[str] = []
    for item in no_candidate_details:
        if not isinstance(item, dict):
            invalid_no_candidate_details.append("not_object")
            continue
        path = item.get("path")
        if not isinstance(path, str):
            invalid_no_candidate_details.append("missing_path")
            continue
        marker_values_raw = [
            item.get("markdown_headings"),
            item.get("markdown_table_rows"),
            item.get("numbered_items"),
            item.get("bullet_items"),
        ]
        marker_values: list[int] = []
        for value in marker_values_raw:
            if not isinstance(value, int) or value < 0:
                invalid_no_candidate_details.append(path)
                break
            marker_values.append(value)
        if len(marker_values) != len(marker_values_raw):
            continue
        expected_marker_total = sum(marker_values)
        marker_total = item.get("unstructured_marker_total")
        if marker_total != expected_marker_total:
            invalid_no_candidate_details.append(path)
            continue
        unstructured_markers_without_candidates += expected_marker_total
        tracking_refs_raw = item.get("tracking_issue_refs", [])
        tracking_refs = tracking_refs_raw if isinstance(tracking_refs_raw, list) else []
        valid_tracking_refs = [
            ref
            for ref in tracking_refs
            if isinstance(ref, str)
            and PROMPT_CHECKLIST_ISSUE_REF_RE.fullmatch(ref) is not None
        ]
        no_candidate_tracking_issue_refs.update(valid_tracking_refs)
        if expected_marker_total > 0:
            if valid_tracking_refs:
                no_candidate_sources_with_tracking_issue_refs += 1
            else:
                missing_no_candidate_tracking_issue_refs.append(path)
                invalid_no_candidate_details.append(path)
            if not isinstance(tracking_refs_raw, list) or len(
                valid_tracking_refs
            ) != len(tracking_refs):
                invalid_no_candidate_tracking_issue_refs.append(path)
                invalid_no_candidate_details.append(path)
    sources_accounted = set(sources) == (
        source_paths_with_candidates | source_paths_without_candidates
    )
    no_candidate_details_accounted = (
        no_candidate_detail_paths == source_paths_without_candidates
        and len(no_candidate_details) == len(source_paths_without_candidates)
        and not invalid_no_candidate_details
    )
    zero_source_count_matches = source_candidate_coverage.get(
        "sources_without_candidates"
    ) == len(source_paths_without_candidates)
    candidate_source_count_matches = source_candidate_coverage.get(
        "sources_with_candidates"
    ) == len(source_paths_with_candidates)
    source_count_matches = source_candidate_coverage.get("sources_checked") == len(
        sources
    )
    unstructured_source_count_matches = source_candidate_coverage.get(
        "unstructured_sources_without_candidates"
    ) == sum(
        1
        for item in no_candidate_details
        if isinstance(item, dict) and as_int(item.get("unstructured_marker_total")) > 0
    )
    unstructured_marker_count_matches = (
        source_candidate_coverage.get("unstructured_markers_without_candidates")
        == unstructured_markers_without_candidates
    )
    no_candidate_tracking_source_count_matches = (
        source_candidate_coverage.get("no_candidate_sources_with_tracking_issue_refs")
        == no_candidate_sources_with_tracking_issue_refs
    )
    no_candidate_source_overlap = (
        len(source_paths_with_candidates & source_paths_without_candidates) == 0
    )
    local_path_leaks = contains_user_local_path(source_row_candidate_inventory)
    expected_by_file = {
        item["path"]: item["unique_candidate_rows"]
        for item in candidates_by_file
        if isinstance(item, dict)
        and isinstance(item.get("path"), str)
        and isinstance(item.get("unique_candidate_rows"), int)
    }
    expected_by_rule = {
        item["rule"]: item["unique_candidate_rows"]
        for item in candidates_by_rule
        if isinstance(item, dict)
        and isinstance(item.get("rule"), str)
        and isinstance(item.get("unique_candidate_rows"), int)
    }
    candidate_row_details = source_candidate_row_details(
        candidate_rows_raw=source_row_candidate_inventory.get("candidate_rows"),
        expected_count=candidate_rows,
        prompt_sources=set(sources),
        expected_by_file=expected_by_file,
        expected_by_rule=expected_by_rule,
        text_redacted=source_row_candidate_inventory.get("candidate_text_redacted")
        is True,
    )
    inventory_result_consistent = (
        source_row_candidate_inventory.get("status") == "INCOMPLETE"
        and source_row_candidate_inventory.get("result")
        == "EXPLICIT_SOURCE_ROWS_INSUFFICIENT"
        and incomplete_against_expected
    ) or (
        source_row_candidate_inventory.get("status") == "COMPLETE"
        and source_row_candidate_inventory.get("result")
        == "EXPLICIT_SOURCE_ROWS_MATCH_EXPECTED"
        and complete_against_expected
    )
    recorded = (
        source_row_candidate_inventory.get("schema_version") == 1
        and inventory_result_consistent
        and source_catalog_id_matches
        and expected_matches
        and missing_candidate_rows_matches
        and candidates_by_file_total_matches
        and candidates_by_rule_total_matches
        and sources_accounted
        and no_candidate_details_accounted
        and source_count_matches
        and candidate_source_count_matches
        and zero_source_count_matches
        and unstructured_source_count_matches
        and unstructured_marker_count_matches
        and no_candidate_tracking_source_count_matches
        and source_currentness_consistent
        and no_candidate_source_overlap
        and len(sources) >= 12
        and source_row_candidate_inventory.get("source_errors_total") == 0
        and len(source_errors) == 0
        and prompt_source_validation["prompt_sources_valid"]
        and candidate_row_details["candidate_rows_valid"]
        and not local_path_leaks
    )
    return {
        "inventory_status": source_row_candidate_inventory.get("status"),
        "inventory_id": source_row_candidate_inventory.get("inventory_id"),
        "result": source_row_candidate_inventory.get("result"),
        "recorded": recorded,
        "source_catalog_id": row_catalog_id,
        "inventory_source_catalog_id": inventory_catalog_id,
        "source_catalog_id_matches": source_catalog_id_matches,
        "expected_findings_total": expected_total,
        "expected_matches": expected_matches,
        "unique_candidate_rows": candidate_rows,
        "missing_candidate_rows": missing_candidate_rows,
        "missing_candidate_rows_matches": missing_candidate_rows_matches,
        "incomplete_against_expected": incomplete_against_expected,
        "complete_against_expected": complete_against_expected,
        "inventory_result_consistent": inventory_result_consistent,
        "candidates_by_file_total": candidates_by_file_total,
        "candidates_by_file_total_matches": candidates_by_file_total_matches,
        "candidates_by_rule_total": candidates_by_rule_total,
        "candidates_by_rule_total_matches": candidates_by_rule_total_matches,
        **candidate_row_details,
        "prompt_sources_checked": len(sources),
        **prompt_source_validation,
        "sources_with_candidates": len(source_paths_with_candidates),
        "sources_without_candidates": len(source_paths_without_candidates),
        "sources_accounted": sources_accounted,
        "sources_without_candidate_details": len(no_candidate_details),
        "no_candidate_details_accounted": no_candidate_details_accounted,
        "invalid_no_candidate_details": invalid_no_candidate_details,
        "unstructured_markers_without_candidates": (
            unstructured_markers_without_candidates
        ),
        "no_candidate_sources_with_tracking_issue_refs": (
            no_candidate_sources_with_tracking_issue_refs
        ),
        "no_candidate_tracking_issue_refs_total": len(no_candidate_tracking_issue_refs),
        "missing_no_candidate_tracking_issue_refs": (
            missing_no_candidate_tracking_issue_refs
        ),
        "invalid_no_candidate_tracking_issue_refs": (
            invalid_no_candidate_tracking_issue_refs
        ),
        "source_count_matches": source_count_matches,
        "candidate_source_count_matches": candidate_source_count_matches,
        "zero_source_count_matches": zero_source_count_matches,
        "unstructured_source_count_matches": unstructured_source_count_matches,
        "unstructured_marker_count_matches": unstructured_marker_count_matches,
        "no_candidate_tracking_source_count_matches": (
            no_candidate_tracking_source_count_matches
        ),
        "source_currentness_evaluated": source_currentness_evaluated,
        "source_currentness_checked_at": source_currentness.get("checked_at"),
        "source_currentness_current": source_currentness.get("current"),
        "source_currentness_consistent": source_currentness_consistent,
        "future_date_claims_total": source_currentness.get("future_date_claims_total"),
        "future_date_claims_count": len(future_date_claims),
        "future_date_claims_total_matches": future_date_claims_total_matches,
        "sources_with_future_date_claims_total": source_currentness.get(
            "sources_with_future_date_claims_total"
        ),
        "future_date_sources_count_matches": future_date_sources_count_matches,
        "future_date_sources_match": future_date_sources_match,
        "blocking_future_date_claims_total": source_currentness.get(
            "blocking_future_date_claims_total"
        ),
        "blocking_future_date_claims_count": blocking_future_date_claims_total,
        "blocking_future_date_claims_total_matches": (
            blocking_future_date_claims_total_matches
        ),
        "sources_with_blocking_future_date_claims_total": source_currentness.get(
            "sources_with_blocking_future_date_claims_total"
        ),
        "blocking_future_date_sources_count_matches": (
            blocking_future_date_sources_count_matches
        ),
        "blocking_future_date_sources_match": blocking_future_date_sources_match,
        "invalid_future_date_claims": invalid_future_date_claims,
        "no_candidate_source_overlap": no_candidate_source_overlap,
        "source_errors_total": source_row_candidate_inventory.get(
            "source_errors_total"
        ),
        "source_errors_count": len(source_errors),
        "local_path_leaks": local_path_leaks,
    }


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

    catalog: dict[str, Any] = {
        "expected_findings_total": row_catalog_evidence.get("expected_findings_total")
    }
    catalog_id = row_catalog_evidence.get("catalog_id")
    if isinstance(catalog_id, str) and catalog_id:
        catalog["catalog_id"] = catalog_id
    external_sources = row_catalog_evidence.get("external_sources")
    require_catalog_sources = isinstance(external_sources, list)
    if require_catalog_sources:
        catalog["external_sources"] = external_sources

    report = validate_strict_row_corpus(
        strict_row_corpus,
        catalog=catalog,
        require_catalog_sources=require_catalog_sources,
    )
    report["expected_matches_catalog"] = (
        report.get("expected_findings_total")
        == row_catalog_evidence["expected_findings_total"]
    )
    report["orient_itemized_matches_corpus"] = (
        report.get("row_count") == row_catalog_evidence["itemized_findings_total"]
    )
    return report


def prompt_closeout_checklist_evidence(
    audit_catalog: dict[str, Any],
    prompt_closeout_checklist: dict[str, Any],
) -> tuple[bool, dict[str, Any]]:
    source_catalog_id = audit_catalog.get("catalog_id")
    checklist_catalog_id = prompt_closeout_checklist.get("source_catalog_id")
    source_catalog_id_matches = (
        isinstance(source_catalog_id, str)
        and isinstance(checklist_catalog_id, str)
        and checklist_catalog_id == source_catalog_id
    )

    source_docs_raw = prompt_closeout_checklist.get("prompt_sources_checked", [])
    source_docs, prompt_source_validation = prompt_source_list(source_docs_raw)
    requirements_raw = prompt_closeout_checklist.get("requirements", [])
    requirements = requirements_raw if isinstance(requirements_raw, list) else []

    invalid_requirements: list[str] = []
    status_counts = {"PASS": 0, "PARTIAL": 0, "BLOCKED": 0}
    blocked_criteria: set[str] = set()
    requirement_ids: set[str] = set()
    duplicate_requirement_ids: list[str] = []
    non_pass_requirements = 0
    requirements_with_tracking_issue_refs = 0
    tracking_issue_refs: set[str] = set()
    missing_tracking_issue_refs: list[str] = []
    invalid_tracking_issue_refs: list[str] = []
    requirements_with_implementation_pr_refs = 0
    implementation_pr_refs: set[str] = set()
    invalid_implementation_pr_refs: list[str] = []
    artifact_refs_total = 0
    artifact_refs_resolved = 0
    artifact_ref_anchors_total = 0
    artifact_ref_anchors_resolved = 0
    missing_artifact_refs: list[str] = []
    missing_artifact_ref_anchors: list[str] = []
    artifact_ref_read_errors: list[str] = []
    invalid_artifact_refs: list[str] = []
    for index, requirement in enumerate(requirements):
        if not isinstance(requirement, dict):
            invalid_requirements.append(f"#{index}: not_object")
            continue
        requirement_id = requirement.get("requirement_id")
        if isinstance(requirement_id, str) and requirement_id:
            if requirement_id in requirement_ids:
                duplicate_requirement_ids.append(requirement_id)
                invalid_requirements.append(
                    f"{requirement_id}: duplicate_requirement_id"
                )
            else:
                requirement_ids.add(requirement_id)
        else:
            invalid_requirements.append(f"#{index}: missing_requirement_id")
        if not as_nonempty_str(requirement.get("prompt_requirement")):
            invalid_requirements.append(f"{requirement_id or index}: missing_prompt")
        artifacts = requirement.get("artifact_refs")
        if not isinstance(artifacts, list) or len(artifacts) == 0:
            invalid_requirements.append(f"{requirement_id or index}: missing_artifacts")
        else:
            requirement_label = str(requirement_id or f"#{index}")
            artifact_refs_total += len(artifacts)
            for artifact in artifacts:
                artifact_path = repo_artifact_path(artifact)
                if artifact_path is None:
                    invalid_artifact_refs.append(requirement_label)
                    invalid_requirements.append(
                        f"{requirement_label}: invalid_artifact_ref"
                    )
                    continue
                full_artifact_path = REPO_ROOT / artifact_path
                if full_artifact_path.is_file():
                    anchor = repo_artifact_anchor(artifact)
                    if anchor is not None:
                        artifact_ref_anchors_total += 1
                        try:
                            artifact_text = full_artifact_path.read_text(
                                encoding="utf-8", errors="replace"
                            )
                        except OSError as exc:
                            artifact_ref_read_errors.append(
                                f"{requirement_label}: {artifact_path}: "
                                f"{type(exc).__name__}"
                            )
                            invalid_requirements.append(
                                f"{requirement_label}: artifact_ref_read_error"
                            )
                            continue
                        if anchor not in artifact_text:
                            missing_artifact_ref_anchors.append(
                                f"{requirement_label}: {artifact_path}#{anchor}"
                            )
                            invalid_requirements.append(
                                f"{requirement_label}: missing_artifact_ref_anchor"
                            )
                            continue
                        artifact_ref_anchors_resolved += 1
                    artifact_refs_resolved += 1
                else:
                    missing_artifact_refs.append(
                        f"{requirement_label}: {artifact_path}"
                    )
                    invalid_requirements.append(
                        f"{requirement_label}: missing_artifact_ref"
                    )
        status = requirement.get("status")
        if status in PROMPT_CHECKLIST_STATUSES:
            status_counts[status] += 1
        else:
            invalid_requirements.append(f"{requirement_id or index}: invalid_status")
        criterion_id = requirement.get("criterion_id")
        if status == "BLOCKED" and isinstance(criterion_id, str):
            blocked_criteria.add(criterion_id)
        tracking_refs_raw = requirement.get("tracking_issue_refs", [])
        tracking_refs = tracking_refs_raw if isinstance(tracking_refs_raw, list) else []
        valid_tracking_refs = [
            item
            for item in tracking_refs
            if isinstance(item, str)
            and PROMPT_CHECKLIST_ISSUE_REF_RE.fullmatch(item) is not None
        ]
        tracking_issue_refs.update(valid_tracking_refs)
        if status in {"PARTIAL", "BLOCKED"}:
            requirement_label = str(requirement_id or f"#{index}")
            non_pass_requirements += 1
            if not valid_tracking_refs:
                missing_tracking_issue_refs.append(requirement_label)
                invalid_requirements.append(
                    f"{requirement_label}: missing_tracking_issue_refs"
                )
            else:
                requirements_with_tracking_issue_refs += 1
            if not isinstance(tracking_refs_raw, list) or len(
                valid_tracking_refs
            ) != len(tracking_refs):
                invalid_tracking_issue_refs.append(requirement_label)
                invalid_requirements.append(
                    f"{requirement_label}: invalid_tracking_issue_refs"
                )
        implementation_pr_refs_raw = requirement.get("implementation_pr_refs", [])
        implementation_refs = (
            implementation_pr_refs_raw
            if isinstance(implementation_pr_refs_raw, list)
            else []
        )
        valid_implementation_refs = [
            item
            for item in implementation_refs
            if isinstance(item, str)
            and PROMPT_CHECKLIST_PR_REF_RE.fullmatch(item) is not None
        ]
        implementation_pr_refs.update(valid_implementation_refs)
        if valid_implementation_refs:
            requirements_with_implementation_pr_refs += 1
        if not isinstance(implementation_pr_refs_raw, list) or len(
            valid_implementation_refs
        ) != len(implementation_refs):
            requirement_label = str(requirement_id or f"#{index}")
            invalid_implementation_pr_refs.append(requirement_label)
            invalid_requirements.append(
                f"{requirement_label}: invalid_implementation_pr_refs"
            )

    expected_source_docs = as_int(audit_catalog.get("source_documents_expected"))
    source_docs_complete = (
        expected_source_docs >= 12
        and len(source_docs) == expected_source_docs
        and prompt_source_validation["prompt_sources_valid"]
    )
    has_strict_corpus_blocker = "strict_row_level_catalog_complete" in blocked_criteria
    local_path_leaks = contains_user_local_path(prompt_closeout_checklist)
    status = prompt_closeout_checklist.get("status")
    recorded = (
        prompt_closeout_checklist.get("schema_version") == 1
        and status == "RECORDED"
        and source_catalog_id_matches
        and source_docs_complete
        and len(requirements) > 0
        and not invalid_requirements
        and not local_path_leaks
    )
    return recorded, {
        "checklist_status": status,
        "checklist_id": prompt_closeout_checklist.get("checklist_id"),
        "source_catalog_id": source_catalog_id,
        "checklist_source_catalog_id": checklist_catalog_id,
        "source_catalog_id_matches": source_catalog_id_matches,
        "prompt_sources_checked": len(source_docs),
        **prompt_source_validation,
        "prompt_sources_expected": expected_source_docs,
        "source_docs_complete": source_docs_complete,
        "requirements_total": len(requirements),
        "requirement_ids_total": len(requirement_ids),
        "duplicate_requirement_ids": sorted(set(duplicate_requirement_ids)),
        "status_counts": status_counts,
        "blocked_criteria": sorted(blocked_criteria),
        "has_strict_corpus_blocker": has_strict_corpus_blocker,
        "non_pass_requirements": non_pass_requirements,
        "requirements_with_tracking_issue_refs": (
            requirements_with_tracking_issue_refs
        ),
        "tracking_issue_refs_total": len(tracking_issue_refs),
        "missing_tracking_issue_refs": missing_tracking_issue_refs,
        "invalid_tracking_issue_refs": invalid_tracking_issue_refs,
        "requirements_with_implementation_pr_refs": (
            requirements_with_implementation_pr_refs
        ),
        "implementation_pr_refs_total": len(implementation_pr_refs),
        "invalid_implementation_pr_refs": invalid_implementation_pr_refs,
        "artifact_refs_total": artifact_refs_total,
        "artifact_refs_resolved": artifact_refs_resolved,
        "artifact_ref_anchors_total": artifact_ref_anchors_total,
        "artifact_ref_anchors_resolved": artifact_ref_anchors_resolved,
        "artifact_refs_all_resolved": (
            artifact_refs_total > 0
            and artifact_refs_resolved == artifact_refs_total
            and not missing_artifact_refs
            and not missing_artifact_ref_anchors
            and not artifact_ref_read_errors
            and not invalid_artifact_refs
        ),
        "missing_artifact_refs": missing_artifact_refs,
        "missing_artifact_ref_anchors": missing_artifact_ref_anchors,
        "artifact_ref_read_errors": artifact_ref_read_errors,
        "invalid_artifact_refs": sorted(set(invalid_artifact_refs)),
        "invalid_requirements": invalid_requirements,
        "local_path_leaks": local_path_leaks,
        "recorded": recorded,
    }


def verify_pipeline_evidence(
    verify_summary: dict[str, Any],
    verify_pipeline: dict[str, Any] | None,
) -> tuple[bool, dict[str, Any]]:
    raw_pipeline = verify_pipeline
    if raw_pipeline is None:
        embedded = verify_summary.get("verify_pipeline")
        raw_pipeline = embedded if isinstance(embedded, dict) else None
    if raw_pipeline is None:
        return True, {"pipeline_status": "NOT_PROVIDED", "provided": False}

    raw_gates = raw_pipeline.get("gates", [])
    gates = raw_gates if isinstance(raw_gates, list) else []
    gate_ids: list[str] = []
    for gate in gates:
        if not isinstance(gate, dict):
            continue
        gate_id = gate.get("gate_id")
        if isinstance(gate_id, str):
            gate_ids.append(gate_id)
    gate_id_set = set(gate_ids)
    missing_gate_ids = sorted(REQUIRED_VERIFY_GATE_IDS - gate_id_set)
    unexpected_gate_ids = sorted(gate_id_set - REQUIRED_VERIFY_GATE_IDS)
    duplicate_gate_ids = sorted(
        {gate_id for gate_id in gate_ids if gate_ids.count(gate_id) > 1}
    )
    non_pass_gate_ids = [
        gate.get("gate_id")
        for gate in gates
        if isinstance(gate, dict) and gate.get("status") != "PASS"
    ]
    non_pass_gate_ids = [
        gate_id for gate_id in non_pass_gate_ids if isinstance(gate_id, str)
    ]
    status_counts = {
        status: sum(
            1
            for gate in gates
            if isinstance(gate, dict) and gate.get("status") == status
        )
        for status in ("PASS", "FAIL", "BLOCKED", "SKIPPED")
    }
    reported_total = as_int(raw_pipeline.get("gates_total"))
    counts_match = (
        reported_total == len(gates)
        and as_int(raw_pipeline.get("gates_passed")) == status_counts["PASS"]
        and as_int(raw_pipeline.get("gates_failed")) == status_counts["FAIL"]
        and as_int(raw_pipeline.get("gates_blocked")) == status_counts["BLOCKED"]
        and as_int(raw_pipeline.get("gates_skipped")) == status_counts["SKIPPED"]
    )
    schema_version = as_int(raw_pipeline.get("schema_version"))
    status = raw_pipeline.get("status")
    passed = (
        schema_version == 1
        and status == "PASS"
        and bool(gates)
        and counts_match
        and not missing_gate_ids
        and not unexpected_gate_ids
        and not duplicate_gate_ids
        and len(gate_ids) == len(REQUIRED_VERIFY_GATE_IDS)
        and not non_pass_gate_ids
    )
    return passed, {
        "schema_version": schema_version,
        "pipeline_status": status,
        "provided": True,
        "gates_total": reported_total,
        "gates_passed": as_int(raw_pipeline.get("gates_passed")),
        "gates_failed": as_int(raw_pipeline.get("gates_failed")),
        "gates_blocked": as_int(raw_pipeline.get("gates_blocked")),
        "gates_skipped": as_int(raw_pipeline.get("gates_skipped")),
        "counts_match": counts_match,
        "missing_gate_ids": missing_gate_ids,
        "unexpected_gate_ids": unexpected_gate_ids,
        "duplicate_gate_ids": duplicate_gate_ids,
        "non_pass_gate_ids": non_pass_gate_ids,
    }


def autoboot_warmup_fairness_evidence(
    audit_catalog: dict[str, Any],
    warmup_fairness: dict[str, Any],
) -> tuple[bool, dict[str, Any]]:
    scheduler_raw = warmup_fairness.get("scheduler_decision")
    scheduler = scheduler_raw if isinstance(scheduler_raw, dict) else {}
    source_catalog_id = audit_catalog.get("catalog_id")
    evidence_catalog_id = warmup_fairness.get("source_catalog_id")
    base_warmup = as_strict_int(scheduler.get("base_warmup_sec"))
    stagger_window = as_strict_int(scheduler.get("stagger_window_sec"))
    max_delay = as_strict_int(scheduler.get("max_delay_sec"))
    algorithm = as_nonempty_str(scheduler.get("algorithm"))
    rows_raw = warmup_fairness.get("keeper_rows", [])
    rows = rows_raw if isinstance(rows_raw, list) else []

    invalid_reasons: list[str] = []

    def require(condition: bool, reason: str) -> None:
        if not condition:
            invalid_reasons.append(reason)

    require(warmup_fairness.get("schema_version") == 1, "schema_version")
    require(warmup_fairness.get("status") == "PASS", "status")
    require(
        isinstance(source_catalog_id, str) and evidence_catalog_id == source_catalog_id,
        "source_catalog_id",
    )
    require(
        algorithm == AUTOBOOT_WARMUP_FAIRNESS_ALGORITHM,
        "scheduler_decision.algorithm",
    )
    require(base_warmup is not None and base_warmup >= 0, "base_warmup_sec")
    require(
        stagger_window is not None and stagger_window >= 0,
        "stagger_window_sec",
    )
    if base_warmup is not None and stagger_window is not None:
        require(max_delay == base_warmup + stagger_window, "max_delay_sec")
    else:
        require(max_delay is not None, "max_delay_sec")
    require(scheduler.get("position_independent") is True, "position_independent")

    by_name: dict[str, dict[str, Any]] = {}
    duplicate_keeper_names: set[str] = set()
    row_errors: list[str] = []
    warmups: list[int] = []
    boot_positions: list[int] = []
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            row_errors.append(f"#{index}: not_object")
            continue
        keeper_name = as_nonempty_str(row.get("keeper_name"))
        if keeper_name is None:
            row_errors.append(f"#{index}: keeper_name")
            continue
        if keeper_name in by_name:
            duplicate_keeper_names.add(keeper_name)
        by_name[keeper_name] = row
        name_hash = as_strict_int(row.get("name_hash"))
        jitter_bucket = as_strict_int(row.get("jitter_bucket"))
        warmup_sec = as_strict_int(row.get("warmup_sec"))
        boot_position = as_strict_int(row.get("boot_position"))
        if boot_position is not None:
            boot_positions.append(boot_position)
        if warmup_sec is not None:
            warmups.append(warmup_sec)
        if base_warmup is None or stagger_window is None or stagger_window < 0:
            continue
        expected_hash = stable_keeper_name_hash(keeper_name)
        expected_jitter = (
            0 if stagger_window == 0 else expected_hash % (stagger_window + 1)
        )
        expected_warmup = base_warmup + expected_jitter
        if name_hash != expected_hash:
            row_errors.append(f"{keeper_name}: name_hash")
        if jitter_bucket != expected_jitter:
            row_errors.append(f"{keeper_name}: jitter_bucket")
        if warmup_sec != expected_warmup:
            row_errors.append(f"{keeper_name}: warmup_sec")
        if warmup_sec is None or max_delay is None:
            row_errors.append(f"{keeper_name}: warmup_bound")
        elif not (base_warmup <= warmup_sec <= max_delay):
            row_errors.append(f"{keeper_name}: warmup_bound")
        if row.get("within_bound") is not True:
            row_errors.append(f"{keeper_name}: within_bound")

    required_names = set(AUTOBOOT_WARMUP_REQUIRED_KEEPERS)
    present_names = set(by_name)
    missing_keeper_names = sorted(required_names - present_names)
    unexpected_keeper_names = sorted(present_names - required_names)
    require(not duplicate_keeper_names, "duplicate_keeper_names")
    require(not missing_keeper_names, "missing_keeper_names")
    require(not unexpected_keeper_names, "unexpected_keeper_names")
    require(len(rows) == len(AUTOBOOT_WARMUP_REQUIRED_KEEPERS), "keeper_rows_total")
    require(not row_errors, "keeper_rows")
    require(
        sorted(boot_positions) == list(range(len(AUTOBOOT_WARMUP_REQUIRED_KEEPERS))),
        "boot_positions",
    )

    max_observed_warmup = max(warmups) if warmups else None
    distinct_warmups = len(set(warmups))
    if max_delay is not None:
        require(
            max_observed_warmup is not None and max_observed_warmup <= max_delay,
            "max_observed_warmup_sec",
        )
    ordered_rows = [
        row
        for row in rows
        if isinstance(row, dict) and as_strict_int(row.get("boot_position")) is not None
    ]
    ordered_rows.sort(key=lambda row: as_strict_int(row.get("boot_position")) or 0)
    observed_by_position = [
        as_strict_int(row.get("warmup_sec"))
        for row in ordered_rows
        if as_strict_int(row.get("warmup_sec")) is not None
    ]
    linear_sequence_detected = False
    if (
        base_warmup is not None
        and stagger_window is not None
        and len(observed_by_position) == len(AUTOBOOT_WARMUP_REQUIRED_KEEPERS)
    ):
        linear_sequence_detected = observed_by_position == [
            base_warmup + (index * stagger_window)
            for index in range(len(AUTOBOOT_WARMUP_REQUIRED_KEEPERS))
        ]
    require(not linear_sequence_detected, "linear_sequence_detected")

    late_raw = warmup_fairness.get("late_keeper_check")
    late = late_raw if isinstance(late_raw, dict) else {}
    late_keeper_name = as_nonempty_str(late.get("keeper_name"))
    late_row = by_name.get(late_keeper_name or "")
    late_warmup = (
        as_strict_int(late_row.get("warmup_sec"))
        if isinstance(late_row, dict)
        else None
    )
    claimed_linear_warmup = as_strict_int(late.get("claimed_linear_warmup_sec"))
    expected_linear_warmup = (
        base_warmup + 13 * stagger_window
        if base_warmup is not None and stagger_window is not None
        else None
    )
    require(late_keeper_name == "verifier", "late_keeper_check.keeper_name")
    require(as_strict_int(late.get("boot_position")) == 13, "late_keeper_position")
    require(
        as_strict_int(late.get("warmup_sec")) == late_warmup,
        "late_keeper_warmup_sec",
    )
    require(
        expected_linear_warmup is not None
        and claimed_linear_warmup == expected_linear_warmup,
        "late_keeper_claimed_linear_warmup_sec",
    )
    if max_delay is not None:
        require(
            late_warmup is not None and late_warmup <= max_delay,
            "late_keeper_bounded",
        )
    require(late.get("bounded_by_max_delay") is True, "bounded_by_max_delay")
    require(late.get("not_position_delay") is True, "not_position_delay")

    ordering_raw = warmup_fairness.get("ordering_replay")
    ordering = ordering_raw if isinstance(ordering_raw, dict) else {}
    require(ordering.get("status") == "PASS", "ordering_replay.status")
    require(
        ordering.get("forward_reverse_stable") is True,
        "ordering_replay.forward_reverse_stable",
    )
    require(
        as_strict_int(ordering.get("distinct_warmups_min")) is not None
        and (as_strict_int(ordering.get("distinct_warmups_min")) or 0) >= 3,
        "ordering_replay.distinct_warmups_min",
    )
    require(
        as_nonempty_str(ordering.get("evidence_ref")) is not None,
        "ordering_replay.evidence_ref",
    )

    turn_raw = warmup_fairness.get("post_warmup_turn_outcome")
    turn = turn_raw if isinstance(turn_raw, dict) else {}
    require(turn.get("status") == "PASS", "post_warmup_turn_outcome.status")
    require(
        turn.get("board_cursor_blocked_until_warmup") is True,
        "post_warmup_turn_outcome.board_cursor_blocked_until_warmup",
    )
    require(
        turn.get("turn_dispatch_receives_proactive_warmup_elapsed") is True,
        "post_warmup_turn_outcome.turn_dispatch_receives_proactive_warmup_elapsed",
    )
    require(
        as_nonempty_str(turn.get("evidence_ref")) is not None,
        "post_warmup_turn_outcome.evidence_ref",
    )

    implementation_refs = [
        item
        for item in string_list(warmup_fairness.get("implementation_pr_refs"))
        if PROMPT_CHECKLIST_PR_REF_RE.fullmatch(item) is not None
    ]
    require(len(implementation_refs) >= 3, "implementation_pr_refs")
    local_path_leaks = contains_user_local_path(warmup_fairness)
    require(not local_path_leaks, "local_path_leaks")

    return not invalid_reasons, {
        "evidence_id": warmup_fairness.get("evidence_id"),
        "source_catalog_id": source_catalog_id,
        "evidence_source_catalog_id": evidence_catalog_id,
        "source_catalog_id_matches": evidence_catalog_id == source_catalog_id,
        "schema_version": warmup_fairness.get("schema_version"),
        "status": warmup_fairness.get("status"),
        "algorithm": algorithm,
        "base_warmup_sec": base_warmup,
        "stagger_window_sec": stagger_window,
        "max_delay_sec": max_delay,
        "keeper_rows_total": len(rows),
        "required_keeper_rows_total": len(AUTOBOOT_WARMUP_REQUIRED_KEEPERS),
        "missing_keeper_names": missing_keeper_names,
        "unexpected_keeper_names": unexpected_keeper_names,
        "duplicate_keeper_names": sorted(duplicate_keeper_names),
        "row_errors": row_errors,
        "boot_positions": sorted(boot_positions),
        "max_observed_warmup_sec": max_observed_warmup,
        "distinct_warmups": distinct_warmups,
        "linear_sequence_detected": linear_sequence_detected,
        "late_keeper_name": late_keeper_name,
        "late_keeper_warmup_sec": late_warmup,
        "late_keeper_claimed_linear_warmup_sec": claimed_linear_warmup,
        "ordering_replay_status": ordering.get("status"),
        "post_warmup_turn_outcome_status": turn.get("status"),
        "implementation_pr_refs_total": len(implementation_refs),
        "local_path_leaks": local_path_leaks,
        "invalid_reasons": invalid_reasons,
        "recorded": not invalid_reasons,
    }


def build_completion_audit(
    status: dict[str, Any],
    *,
    structured_id_triage: dict[str, Any] | None = None,
    row_corpus_discovery: dict[str, Any] | None = None,
    strict_row_corpus: dict[str, Any] | None = None,
    prompt_closeout_checklist: dict[str, Any] | None = None,
    source_row_candidate_inventory: dict[str, Any] | None = None,
    verify_pipeline: dict[str, Any] | None = None,
    autoboot_warmup_fairness: dict[str, Any] | None = None,
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
        "source_read_errors": audit_catalog.get("source_read_errors"),
        "source_decode_errors": audit_catalog.get("source_decode_errors"),
        "source_line_ref_errors": audit_catalog.get("source_line_ref_errors"),
    }
    source_artifacts_passed = (
        source_artifacts_evidence["source_artifacts_status"] == "COMPLETE"
        and as_int(source_artifacts_evidence["source_artifacts_total"]) >= 12
        and as_int(source_artifacts_evidence["source_artifacts_missing"]) == 0
        and as_int(source_artifacts_evidence["source_read_errors"]) == 0
        and as_int(source_artifacts_evidence["source_decode_errors"]) == 0
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
        "source_itemized_id_basis": audit_catalog.get("source_itemized_id_basis"),
        "source_document_itemized_finding_ids_total": audit_catalog.get(
            "source_document_itemized_finding_ids_total"
        ),
        "source_itemized_finding_ids_total": audit_catalog.get(
            "source_itemized_finding_ids_total"
        ),
        "catalog_itemized_finding_ids_total": audit_catalog.get(
            "catalog_itemized_finding_ids_total"
        ),
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
        "catalog_id": audit_catalog.get("catalog_id"),
        "status": audit_catalog.get("status"),
        "expected_findings_total": audit_catalog.get("expected_findings_total"),
        "itemized_findings_total": audit_catalog.get("itemized_findings_total"),
        "missing_itemized_findings": audit_catalog.get("missing_itemized_findings"),
        "extra_itemized_findings": audit_catalog.get("extra_itemized_findings"),
    }
    external_sources = audit_catalog.get("external_sources")
    if isinstance(external_sources, list):
        row_catalog_evidence["external_sources"] = external_sources
    row_catalog_evidence["row_corpus_discovery"] = row_corpus_discovery_evidence(
        row_catalog_evidence,
        row_corpus_discovery,
    )
    row_catalog_evidence["source_row_candidate_inventory"] = (
        source_row_candidate_inventory_evidence(
            row_catalog_evidence,
            source_row_candidate_inventory,
        )
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
        and as_int(row_catalog_evidence["extra_itemized_findings"]) == 0
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
        structured_triage_evidence(
            structured_evidence,
            structured_id_triage,
            source_catalog_id=audit_catalog.get("catalog_id"),
        )
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
    pipeline_passed, pipeline_evidence = verify_pipeline_evidence(
        verify_summary,
        verify_pipeline,
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
            "Strict source or row-corpus audit IDs match catalog finding IDs.",
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
    if autoboot_warmup_fairness is not None:
        warmup_passed, warmup_evidence = autoboot_warmup_fairness_evidence(
            audit_catalog,
            autoboot_warmup_fairness,
        )
        criteria.append(
            criterion(
                "autoboot_warmup_fairness_complete",
                warmup_passed,
                "Autoboot warmup scheduling is bounded, order-independent, and verified for late keepers.",
                warmup_evidence,
            )
        )
    if prompt_closeout_checklist is not None:
        checklist_passed, checklist_evidence = prompt_closeout_checklist_evidence(
            audit_catalog,
            prompt_closeout_checklist,
        )
        checklist_status_counts = checklist_evidence.get("status_counts", {})
        checklist_status_counts = (
            checklist_status_counts if isinstance(checklist_status_counts, dict) else {}
        )
        requirements_total = as_int(checklist_evidence.get("requirements_total"))
        prompt_requirements_passed = (
            checklist_passed
            and requirements_total > 0
            and as_int(checklist_status_counts.get("PASS")) == requirements_total
            and as_int(checklist_status_counts.get("PARTIAL")) == 0
            and as_int(checklist_status_counts.get("BLOCKED")) == 0
        )
        criteria.append(
            criterion(
                "prompt_to_artifact_checklist_recorded",
                checklist_passed,
                "Prompt requirements are mapped to concrete artifacts and blockers.",
                checklist_evidence,
            )
        )
        criteria.append(
            criterion(
                "prompt_requirements_closeout_complete",
                prompt_requirements_passed,
                "Every prompt-mapped requirement is fully satisfied.",
                {
                    "checklist_id": checklist_evidence.get("checklist_id"),
                    "checklist_recorded": checklist_passed,
                    "requirements_total": requirements_total,
                    "status_counts": checklist_status_counts,
                    "incomplete_requirements": as_int(
                        checklist_status_counts.get("PARTIAL")
                    )
                    + as_int(checklist_status_counts.get("BLOCKED")),
                    "non_pass_requirements": checklist_evidence.get(
                        "non_pass_requirements"
                    ),
                    "requirements_with_tracking_issue_refs": checklist_evidence.get(
                        "requirements_with_tracking_issue_refs"
                    ),
                    "tracking_issue_refs_total": checklist_evidence.get(
                        "tracking_issue_refs_total"
                    ),
                    "requirements_with_implementation_pr_refs": (
                        checklist_evidence.get(
                            "requirements_with_implementation_pr_refs"
                        )
                    ),
                    "implementation_pr_refs_total": checklist_evidence.get(
                        "implementation_pr_refs_total"
                    ),
                    "invalid_implementation_pr_refs": checklist_evidence.get(
                        "invalid_implementation_pr_refs"
                    ),
                    "missing_tracking_issue_refs": checklist_evidence.get(
                        "missing_tracking_issue_refs"
                    ),
                    "has_strict_corpus_blocker": checklist_evidence.get(
                        "has_strict_corpus_blocker"
                    ),
                },
            )
        )
    if pipeline_evidence["provided"]:
        criteria.append(
            criterion(
                "verify_pipeline_complete",
                pipeline_passed,
                "Full Verify pipeline gates are present and all required gates pass.",
                pipeline_evidence,
            )
        )
    blockers = [item.criterion_id for item in criteria if item.status == "FAIL"]
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
        "--prompt-closeout-checklist",
        help="Optional prompt-to-artifact closeout checklist manifest.",
    )
    parser.add_argument(
        "--source-row-candidate-inventory",
        help="Optional explicit source-row candidate inventory manifest.",
    )
    parser.add_argument(
        "--verify-pipeline",
        help="Optional GOAL LOOP Verify pipeline result JSON to require for closeout.",
    )
    parser.add_argument(
        "--autoboot-warmup-fairness",
        help="Optional bounded autoboot warmup fairness evidence JSON.",
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
        prompt_closeout_checklist=load_optional_json_file(
            args.prompt_closeout_checklist
        ),
        source_row_candidate_inventory=load_optional_json_file(
            args.source_row_candidate_inventory
        ),
        verify_pipeline=load_optional_json_file(args.verify_pipeline),
        autoboot_warmup_fairness=load_optional_json_file(args.autoboot_warmup_fairness),
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
