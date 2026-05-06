#!/usr/bin/env python3
"""Build a compact GOAL LOOP status report from Observe/Orient/Decide/Verify JSON.

The phase-specific tools intentionally stay small and focused. This script is
the glue layer for operators: it accepts any subset of their JSON outputs and
emits one machine-readable snapshot with phase status, next action, and the raw
counts that drove the decision.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATUS_RANK = {"ok": 0, "unknown": 1, "warning": 2, "critical": 3}


@dataclass
class PhaseStatus:
    status: str
    summary: dict[str, Any]


@dataclass
class GoalLoopStatus:
    schema_version: int
    generated_at: str
    loop_iteration: str
    overall_status: str
    phases: dict[str, PhaseStatus]
    next_action: dict[str, Any] | None
    system_health_signals: dict[str, Any]


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def load_json_file(path: str | None) -> dict[str, Any] | None:
    if not path:
        return None
    with Path(path).open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object: {path}")
    return data


def as_int(value: Any, default: int = 0) -> int:
    return value if isinstance(value, int) else default


def as_nonempty_str(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped if stripped else None


def status_max(statuses: list[str]) -> str:
    if not statuses:
        return "unknown"
    return max(statuses, key=lambda item: STATUS_RANK.get(item, 0))


def consistency_finding_is_open(finding: Any) -> bool:
    if not isinstance(finding, dict):
        return True
    status = finding.get("status")
    if not isinstance(status, str):
        return True
    return status.upper() not in {"CLOSED", "COMPLETE", "DONE", "RESOLVED"}


def pattern_count(observe: dict[str, Any] | None, name: str) -> int:
    if observe is None:
        return 0
    patterns = observe.get("patterns", {})
    if not isinstance(patterns, dict):
        return 0
    raw = patterns.get(name)
    if not isinstance(raw, dict):
        return 0
    return as_int(raw.get("count"))


def summarize_observe(observe: dict[str, Any] | None) -> PhaseStatus:
    if observe is None:
        return PhaseStatus(status="unknown", summary={"reason": "observe_json_missing"})

    patterns = observe.get("patterns", {})
    pattern_items = patterns if isinstance(patterns, dict) else {}
    critical_matches = 0
    warning_matches = 0
    active_patterns: list[dict[str, Any]] = []

    for name, raw in pattern_items.items():
        if not isinstance(name, str) or not isinstance(raw, dict):
            continue
        count = as_int(raw.get("count"))
        if count <= 0:
            continue
        severity = raw.get("severity")
        severity_text = severity if isinstance(severity, str) else "unknown"
        if severity_text == "critical":
            critical_matches += count
        elif severity_text == "warning":
            warning_matches += count
        active_patterns.append(
            {"name": name, "count": count, "severity": severity_text}
        )

    status = (
        "critical"
        if critical_matches > 0
        else "warning"
        if warning_matches > 0
        else "ok"
    )
    return PhaseStatus(
        status=status,
        summary={
            "files": observe.get("files", []),
            "total_lines": as_int(observe.get("total_lines")),
            "matched_lines": as_int(observe.get("matched_lines")),
            "critical_matches": critical_matches,
            "warning_matches": warning_matches,
            "active_patterns": sorted(
                active_patterns,
                key=lambda item: (
                    -as_int(item.get("count")),
                    str(item.get("name", "")),
                ),
            ),
        },
    )


def summarize_orient(orient: dict[str, Any] | None) -> PhaseStatus:
    if orient is None:
        return PhaseStatus(status="unknown", summary={"reason": "orient_json_missing"})

    summary_raw = orient.get("summary", {})
    summary = summary_raw if isinstance(summary_raw, dict) else {}
    audit_catalog_raw = orient.get("audit_catalog")
    audit_catalog = audit_catalog_raw if isinstance(audit_catalog_raw, dict) else None
    audit_catalog_error = None
    if (
        "audit_catalog" in orient
        and audit_catalog_raw is not None
        and audit_catalog is None
    ):
        audit_catalog_error = f"expected_object_got_{type(audit_catalog_raw).__name__}"
    critical_present = as_int(summary.get("critical_present"))
    evidence_present = as_int(summary.get("evidence_present"))
    findings_total = as_int(summary.get("findings_total"))
    audit_catalog_summary: dict[str, Any] | None = None
    audit_catalog_warning = audit_catalog_error is not None
    if audit_catalog_error is not None:
        audit_catalog_summary = {"audit_catalog_error": audit_catalog_error}
    if audit_catalog is not None:
        consistency_raw = audit_catalog.get("consistency_findings", [])
        consistency_findings = (
            consistency_raw if isinstance(consistency_raw, list) else []
        )
        open_consistency_findings = [
            finding
            for finding in consistency_findings
            if consistency_finding_is_open(finding)
        ]
        source_artifacts_raw = audit_catalog.get("source_artifacts")
        source_artifacts = (
            source_artifacts_raw if isinstance(source_artifacts_raw, dict) else None
        )
        strict_row_corpus_raw = audit_catalog.get("strict_row_corpus")
        strict_row_corpus = (
            strict_row_corpus_raw if isinstance(strict_row_corpus_raw, dict) else None
        )
        audit_catalog_summary = {
            "catalog_id": audit_catalog.get("catalog_id"),
            "status": audit_catalog.get("status", "unknown"),
            "expected_findings_total": audit_catalog.get("expected_findings_total"),
            "itemized_findings_total": audit_catalog.get("itemized_findings_total"),
            "missing_itemized_findings": audit_catalog.get("missing_itemized_findings"),
            "extra_itemized_findings": audit_catalog.get("extra_itemized_findings"),
            "source_documents_status": audit_catalog.get(
                "source_documents_status", "unknown"
            ),
            "source_documents_covered": audit_catalog.get("source_documents_covered"),
            "source_documents_expected": audit_catalog.get("source_documents_expected"),
            "aggregate_claims_total": len(audit_catalog.get("aggregate_claims", []))
            if isinstance(audit_catalog.get("aggregate_claims"), list)
            else 0,
            "aggregate_reconciliations_total": len(
                audit_catalog.get("aggregate_reconciliations", [])
            )
            if isinstance(audit_catalog.get("aggregate_reconciliations"), list)
            else 0,
            "consistency_findings_total": len(consistency_findings),
            "consistency_findings_open": len(open_consistency_findings),
        }
        if strict_row_corpus is not None:
            audit_catalog_summary["strict_row_corpus_provided"] = (
                strict_row_corpus.get("provided") is True
            )
            audit_catalog_summary["strict_row_corpus_validated"] = (
                strict_row_corpus.get("validated") is True
            )
            audit_catalog_summary["strict_row_corpus_row_count"] = (
                strict_row_corpus.get("row_count")
            )
            audit_catalog_summary["strict_row_corpus_errors_total"] = (
                strict_row_corpus.get("errors_total")
            )
        if source_artifacts is not None:
            audit_catalog_summary["source_artifacts_status"] = source_artifacts.get(
                "status",
                "unknown",
            )
            audit_catalog_summary["source_artifacts_total"] = source_artifacts.get(
                "source_artifacts_total"
            )
            audit_catalog_summary["source_artifacts_resolved"] = source_artifacts.get(
                "source_artifacts_resolved"
            )
            audit_catalog_summary["source_artifacts_missing"] = source_artifacts.get(
                "source_artifacts_missing"
            )
            audit_catalog_summary["source_decode_errors"] = source_artifacts.get(
                "source_decode_errors"
            )
            audit_catalog_summary["source_line_ref_errors"] = source_artifacts.get(
                "line_ref_errors"
            )
            audit_catalog_summary["source_itemized_id_status"] = source_artifacts.get(
                "source_itemized_id_status",
                "unknown",
            )
            audit_catalog_summary["source_itemized_id_basis"] = source_artifacts.get(
                "source_itemized_id_basis",
                "source_documents",
            )
            audit_catalog_summary["source_itemized_finding_ids_total"] = (
                source_artifacts.get("source_itemized_finding_ids_total")
            )
            audit_catalog_summary["source_document_itemized_finding_ids_total"] = (
                source_artifacts.get("source_document_itemized_finding_ids_total")
            )
            audit_catalog_summary["catalog_itemized_finding_ids_total"] = (
                source_artifacts.get("catalog_itemized_finding_ids_total")
            )
            audit_catalog_summary["source_ids_missing_from_catalog"] = (
                source_artifacts.get("source_ids_missing_from_catalog")
            )
            audit_catalog_summary["catalog_ids_missing_from_source"] = (
                source_artifacts.get("catalog_ids_missing_from_source")
            )
            audit_catalog_summary["source_structured_item_ids_total"] = (
                source_artifacts.get("source_structured_item_ids_total")
            )
            audit_catalog_summary["source_structured_item_ids_uncataloged"] = (
                source_artifacts.get("source_structured_item_ids_uncataloged")
            )
            audit_catalog_summary[
                "source_structured_item_ids_uncataloged_occurrences"
            ] = source_artifacts.get(
                "source_structured_item_ids_uncataloged_occurrences"
            )
            audit_catalog_summary["source_structured_item_id_families"] = (
                source_artifacts.get("source_structured_item_id_families", [])
            )
            audit_catalog_summary["source_aggregate_claim_status"] = (
                source_artifacts.get("source_aggregate_claim_status", "unknown")
            )
            audit_catalog_summary["source_aggregate_claim_sources_verified"] = (
                source_artifacts.get("source_aggregate_claim_sources_verified")
            )
            audit_catalog_summary["source_aggregate_claim_sources_missing"] = (
                source_artifacts.get("source_aggregate_claim_sources_missing")
            )
            audit_catalog_summary["source_aggregate_reconciliation_status"] = (
                source_artifacts.get(
                    "source_aggregate_reconciliation_status", "unknown"
                )
            )
            audit_catalog_summary["source_aggregate_reconciliations_verified"] = (
                source_artifacts.get("source_aggregate_reconciliations_verified")
            )
            audit_catalog_summary["source_aggregate_reconciliations_failed"] = (
                source_artifacts.get("source_aggregate_reconciliations_failed")
            )
            audit_catalog_summary["source_identity_status"] = source_artifacts.get(
                "source_identity_status",
                "unknown",
            )
            audit_catalog_summary["source_identity_checks_verified"] = (
                source_artifacts.get("source_identity_checks_verified")
            )
            audit_catalog_summary["source_identity_checks_failed"] = (
                source_artifacts.get("source_identity_checks_failed")
            )
        else:
            audit_catalog_summary["source_artifacts_status"] = "NOT_CHECKED"
        audit_catalog_warning = (
            audit_catalog_summary["status"] != "COMPLETE"
            or audit_catalog_summary["source_documents_status"] != "COMPLETE"
            or audit_catalog_summary["consistency_findings_open"] > 0
            or audit_catalog_summary.get("source_artifacts_status") != "COMPLETE"
            or audit_catalog_summary.get("strict_row_corpus_validated") is False
        )
    status = (
        "critical"
        if critical_present > 0
        else "warning"
        if evidence_present > 0 or audit_catalog_warning
        else "ok"
    )
    present_findings = []
    findings = orient.get("findings", [])
    if isinstance(findings, list):
        for raw in findings:
            if not isinstance(raw, dict):
                continue
            if raw.get("status") != "EVIDENCE_PRESENT":
                continue
            present_findings.append(
                {
                    "finding_id": raw.get("finding_id", "unknown"),
                    "title": raw.get("title", "unknown"),
                    "severity": raw.get("severity", "unknown"),
                    "count": as_int(raw.get("count")),
                }
            )
    phase_summary: dict[str, Any] = {
        "evidence_present": evidence_present,
        "critical_present": critical_present,
        "findings_total": findings_total,
        "present_findings": present_findings[:10],
    }
    if audit_catalog_summary is not None:
        phase_summary["audit_catalog"] = audit_catalog_summary
    return PhaseStatus(status=status, summary=phase_summary)


def decide_next_action(decide: dict[str, Any] | None) -> dict[str, Any] | None:
    if decide is None:
        return None
    decisions = decide.get("decisions", [])
    if not isinstance(decisions, list) or not decisions:
        return None
    typed_decisions = [decision for decision in decisions if isinstance(decision, dict)]
    for status in ("ACT_MISSING", "ACT_UNMAPPED"):
        for decision in typed_decisions:
            if decision.get("act_status") == status:
                return decision
    return typed_decisions[0] if typed_decisions else None


def summarize_decide(decide: dict[str, Any] | None) -> PhaseStatus:
    if decide is None:
        return PhaseStatus(status="unknown", summary={"reason": "decide_json_missing"})

    decisions_total = as_int(decide.get("decisions_total"))
    p0_count = as_int(decide.get("p0_count"))
    act_missing_count = as_int(decide.get("act_missing_count"), default=-1)
    act_linked_count = as_int(decide.get("act_linked_count"), default=-1)
    status = "critical" if p0_count > 0 else "warning" if decisions_total > 0 else "ok"
    summary: dict[str, Any] = {
        "decisions_total": decisions_total,
        "p0_count": p0_count,
        "next_action": decide_next_action(decide),
    }
    if act_missing_count >= 0:
        summary["act_missing_count"] = act_missing_count
    if act_linked_count >= 0:
        summary["act_linked_count"] = act_linked_count
    return PhaseStatus(status=status, summary=summary)


def summarize_act(decide: dict[str, Any] | None) -> PhaseStatus:
    if decide is None:
        return PhaseStatus(status="unknown", summary={"reason": "decide_json_missing"})

    decisions_total = as_int(decide.get("decisions_total"))
    act_missing_count = as_int(decide.get("act_missing_count"), default=-1)
    act_linked_count = as_int(decide.get("act_linked_count"), default=-1)
    if act_missing_count >= 0:
        status = (
            "critical"
            if act_missing_count > 0
            else "ok"
            if decisions_total == 0 or act_linked_count > 0
            else "warning"
        )
        return PhaseStatus(
            status=status,
            summary={
                "decisions_total": decisions_total,
                "act_linked_count": max(act_linked_count, 0),
                "act_missing_count": act_missing_count,
            },
        )
    if decisions_total > 0:
        return PhaseStatus(
            status="unknown",
            summary={
                "decisions_total": decisions_total,
                "reason": "act_map_not_evaluated",
            },
        )
    return PhaseStatus(status="ok", summary={"decisions_total": 0})


def summarize_verify(verify: dict[str, Any] | None) -> PhaseStatus:
    if verify is None:
        return PhaseStatus(status="unknown", summary={"reason": "verify_json_missing"})

    raw_status = verify.get("status")
    verify_status = raw_status if isinstance(raw_status, str) else "UNKNOWN"
    failing_findings = verify.get("failing_findings", [])
    violations = verify.get("violations", [])
    failing_count = len(failing_findings) if isinstance(failing_findings, list) else 0
    typed_violations = (
        [violation for violation in violations if isinstance(violation, dict)]
        if isinstance(violations, list)
        else []
    )
    violation_count = len(typed_violations)
    violation_kinds = sorted(
        {
            str(kind)
            for violation in typed_violations
            for kind in [violation.get("kind")]
            if isinstance(kind, str)
        }
    )
    post_act_verify = verify.get("post_act_verify")
    summary: dict[str, Any] = {
        "verify_status": verify_status,
        "failing_findings": failing_count,
        "violations": violation_count,
        "violation_kinds": violation_kinds,
        "post_act_verify": post_act_verify
        if isinstance(post_act_verify, bool)
        else False,
    }
    for key in (
        "evidence_kind",
        "evidence_source",
        "evidence_window_start",
        "evidence_window_end",
        "checked_at",
    ):
        value = as_nonempty_str(verify.get(key))
        if value is not None:
            summary[key] = value
    status = "ok" if verify_status == "PASS" else "critical"
    return PhaseStatus(
        status=status,
        summary=summary,
    )


def system_health_signals(observe: dict[str, Any] | None) -> dict[str, Any]:
    signals = {
        "keeper_failure_patterns": {
            "keeper_skipping_turn": pattern_count(observe, "keeper_skipping_turn"),
            "credential_archived_starvation": pattern_count(
                observe, "credential_archived_starvation"
            ),
            "alive_but_stuck": pattern_count(observe, "alive_but_stuck"),
        },
        "provider_failure_patterns": {
            "provider_health_skipped": pattern_count(
                observe, "provider_health_skipped"
            ),
            "pricing_catalog_miss": pattern_count(observe, "pricing_catalog_miss"),
        },
        "data_integrity_patterns": {
            "utf8_repair": pattern_count(observe, "utf8_repair"),
            "cas_retry": pattern_count(observe, "cas_retry"),
        },
        "governance_patterns": {
            "governance_unparseable": pattern_count(observe, "governance_unparseable"),
            "lenient_json_fallback": pattern_count(observe, "lenient_json_fallback"),
        },
    }
    return signals


def build_status_report(
    *,
    observe: dict[str, Any] | None,
    orient: dict[str, Any] | None,
    decide: dict[str, Any] | None,
    verify: dict[str, Any] | None,
    generated_at: str | None = None,
    loop_iteration: str = "unknown",
) -> GoalLoopStatus:
    phases = {
        "observe": summarize_observe(observe),
        "orient": summarize_orient(orient),
        "decide": summarize_decide(decide),
        "act": summarize_act(decide),
        "verify": summarize_verify(verify),
    }
    overall = status_max([phase.status for phase in phases.values()])
    return GoalLoopStatus(
        schema_version=1,
        generated_at=generated_at or utc_now_iso(),
        loop_iteration=loop_iteration,
        overall_status=overall,
        phases=phases,
        next_action=decide_next_action(decide),
        system_health_signals=system_health_signals(observe),
    )


def report_to_json(report: GoalLoopStatus) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def report_to_text(report: GoalLoopStatus) -> str:
    lines = [
        f"GOAL LOOP Status: {report.overall_status}",
        f"loop_iteration: {report.loop_iteration}",
        f"generated_at: {report.generated_at}",
    ]
    for name in ("observe", "orient", "decide", "act", "verify"):
        phase = report.phases[name]
        lines.append(
            f"- {name}: {phase.status} {json.dumps(phase.summary, sort_keys=True)}"
        )
    if report.next_action:
        decision_id = report.next_action.get("decision_id", "unknown")
        action = report.next_action.get("action", "unknown")
        lines.append(f"next_action: {decision_id} {action}")
    return "\n".join(lines)


def should_fail(report: GoalLoopStatus, mode: str) -> bool:
    if mode == "none":
        return False
    rank = STATUS_RANK.get(report.overall_status, 0)
    if mode == "warning":
        return rank >= STATUS_RANK["warning"]
    if mode == "critical":
        return rank >= STATUS_RANK["critical"]
    raise ValueError(f"unknown fail mode: {mode}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--observe-json", help="JSON from observe_goal_loop_logs.py")
    parser.add_argument("--orient-json", help="JSON from orient_goal_loop_logs.py")
    parser.add_argument("--decide-json", help="JSON from decide_goal_loop_findings.py")
    parser.add_argument("--verify-json", help="JSON from verify_goal_loop_logs.py")
    parser.add_argument("--loop-iteration", default="unknown")
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format (default: json).",
    )
    parser.add_argument(
        "--fail-on",
        choices=("none", "warning", "critical"),
        default="none",
        help="Exit non-zero when the aggregate status reaches this severity.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = build_status_report(
        observe=load_json_file(args.observe_json),
        orient=load_json_file(args.orient_json),
        decide=load_json_file(args.decide_json),
        verify=load_json_file(args.verify_json),
        loop_iteration=args.loop_iteration,
    )
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    return 1 if should_fail(report, args.fail_on) else 0


if __name__ == "__main__":
    raise SystemExit(main())
