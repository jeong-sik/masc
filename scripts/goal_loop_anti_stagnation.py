#!/usr/bin/env python3
"""Evaluate GOAL LOOP anti-stagnation SLA state.

The input is a machine-readable finding lifecycle snapshot. The output is a
deterministic report that makes missing ACT references, stale ACT creation,
missing post-merge Verify, failed Verify repair gaps, and week-old escalation
requirements visible to status/dashboard consumers.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STILL_PRESENT_STATUSES = {"STILL_PRESENT", "PARTIALLY_FIXED"}
ACT_CREATION_DEADLINE_HOURS = 48.0
VERIFY_AFTER_MERGE_DEADLINE_HOURS = 24.0
VERIFY_FAIL_REPAIR_DEADLINE_HOURS = 4.0
WEEK_OLD_ESCALATION_HOURS = 24.0 * 7.0


@dataclass(frozen=True)
class StagnationViolation:
    finding_id: str
    rule_id: str
    severity: str
    message: str
    age_hours: float | None
    deadline_hours: float
    evidence: dict[str, Any]


@dataclass(frozen=True)
class StagnationFinding:
    finding_id: str
    status: str
    age_hours: float | None
    act_ref: str | None
    act_created_at: str | None
    act_merged_at: str | None
    verify_status: str | None
    verify_checked_at: str | None
    verify_failed_at: str | None
    escalated: bool
    violations: list[StagnationViolation]


@dataclass(frozen=True)
class StagnationReport:
    schema_version: int
    status: str
    checked_at: str
    findings_total: int
    still_present_total: int
    violations_total: int
    escalations_required: int
    findings: list[StagnationFinding]
    violations: list[StagnationViolation]


def parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def iso_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat()


def age_hours(now: datetime, timestamp: datetime | None) -> float | None:
    if timestamp is None:
        return None
    return round(max((now - timestamp).total_seconds(), 0.0) / 3600.0, 3)


def delta_hours(later: datetime | None, earlier: datetime | None) -> float | None:
    if later is None or earlier is None:
        return None
    return round((later - earlier).total_seconds() / 3600.0, 3)


def load_json(path: str) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object: {path}")
    return data


def raw_findings(snapshot: dict[str, Any]) -> list[dict[str, Any]]:
    raw = snapshot.get("findings")
    if isinstance(raw, list):
        return [item for item in raw if isinstance(item, dict)]
    raw = snapshot.get("items")
    if isinstance(raw, list):
        return [item for item in raw if isinstance(item, dict)]
    return []


def string_field(value: Any) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def bool_field(value: Any) -> bool:
    return value is True


def nested_object(raw: dict[str, Any], key: str) -> dict[str, Any]:
    value = raw.get(key)
    return value if isinstance(value, dict) else {}


def finding_id(raw: dict[str, Any]) -> str:
    for key in ("finding_id", "id"):
        value = string_field(raw.get(key))
        if value is not None:
            return value
    return "unknown"


def finding_status(raw: dict[str, Any]) -> str:
    value = string_field(raw.get("status"))
    return value.upper() if value is not None else "UNKNOWN"


def first_seen_at(raw: dict[str, Any]) -> tuple[datetime | None, str | None]:
    for key in ("first_seen_at", "detected_at", "created_at"):
        parsed = parse_timestamp(raw.get(key))
        if parsed is not None:
            return parsed, key
    return None, None


def first_seen_evidence(
    first_seen: datetime | None, first_seen_source: str | None
) -> dict[str, Any]:
    return {
        "first_seen_at": iso_utc(first_seen) if first_seen is not None else None,
        "first_seen_source": first_seen_source,
    }


def violation(
    *,
    raw: dict[str, Any],
    rule_id: str,
    severity: str,
    message: str,
    age: float | None,
    deadline_hours: float,
    evidence: dict[str, Any],
) -> StagnationViolation:
    return StagnationViolation(
        finding_id=finding_id(raw),
        rule_id=rule_id,
        severity=severity,
        message=message,
        age_hours=age,
        deadline_hours=deadline_hours,
        evidence=evidence,
    )


def evaluate_finding(raw: dict[str, Any], *, now: datetime) -> StagnationFinding:
    status = finding_status(raw)
    first_seen, first_seen_source = first_seen_at(raw)
    finding_age = age_hours(now, first_seen)
    act = nested_object(raw, "act")
    verify = nested_object(raw, "verify")
    escalation = nested_object(raw, "escalation")

    act_ref = string_field(act.get("ref") or raw.get("act_ref"))
    act_created = parse_timestamp(act.get("created_at") or raw.get("act_created_at"))
    act_merged = parse_timestamp(act.get("merged_at") or raw.get("act_merged_at"))
    repair_ref = string_field(act.get("repair_ref") or raw.get("repair_ref"))
    rollback_ref = string_field(act.get("rollback_ref") or raw.get("rollback_ref"))
    repair_created = parse_timestamp(
        act.get("repair_created_at") or raw.get("repair_created_at")
    )
    rollback_created = parse_timestamp(
        act.get("rollback_created_at") or raw.get("rollback_created_at")
    )
    verify_status = string_field(verify.get("status") or raw.get("verify_status"))
    verify_status_upper = verify_status.upper() if verify_status is not None else None
    verify_checked = parse_timestamp(
        verify.get("checked_at") or raw.get("verify_checked_at")
    )
    verify_failed = parse_timestamp(
        verify.get("failed_at") or raw.get("verify_failed_at")
    )
    escalated = (
        bool_field(raw.get("escalated"))
        or bool_field(escalation.get("recorded"))
        or bool_field(escalation.get("p0"))
        or bool_field(raw.get("p0_escalated"))
    )

    violations: list[StagnationViolation] = []
    is_still_present = status in STILL_PRESENT_STATUSES
    if is_still_present and act_ref is None:
        violations.append(
            violation(
                raw=raw,
                rule_id="still_present_requires_act",
                severity="critical",
                message="STILL_PRESENT finding has no ACT reference.",
                age=finding_age,
                deadline_hours=0.0,
                evidence={"status": status, "act_ref": act_ref},
            )
        )

    act_creation_hours = delta_hours(act_created, first_seen)
    act_creation_missing_overdue = (
        finding_age is not None
        and finding_age > ACT_CREATION_DEADLINE_HOURS
        and act_created is None
    )
    act_creation_late = (
        act_creation_hours is not None
        and act_creation_hours > ACT_CREATION_DEADLINE_HOURS
    )
    if is_still_present and (act_creation_missing_overdue or act_creation_late):
        evidence = first_seen_evidence(first_seen, first_seen_source)
        evidence.update(
            {
                "act_ref": act_ref,
                "act_created_at": iso_utc(act_created) if act_created else None,
                "act_creation_hours": act_creation_hours,
            }
        )
        violations.append(
            violation(
                raw=raw,
                rule_id="act_creation_deadline_missed",
                severity="critical",
                message="ACT was not created within 48 hours of a present finding.",
                age=act_creation_hours if act_creation_late else finding_age,
                deadline_hours=ACT_CREATION_DEADLINE_HOURS,
                evidence=evidence,
            )
        )

    merge_age = age_hours(now, act_merged)
    verify_after_merge_hours = delta_hours(verify_checked, act_merged)
    verify_after_merge_ok = verify_after_merge_hours is not None and (
        0.0 <= verify_after_merge_hours <= VERIFY_AFTER_MERGE_DEADLINE_HOURS
    )
    if (
        act_merged is not None
        and merge_age is not None
        and merge_age > VERIFY_AFTER_MERGE_DEADLINE_HOURS
        and not verify_after_merge_ok
    ):
        violations.append(
            violation(
                raw=raw,
                rule_id="verify_after_merge_deadline_missed",
                severity="critical",
                message="Merged ACT has no Verify evidence within 24 hours.",
                age=(
                    verify_after_merge_hours
                    if verify_after_merge_hours is not None
                    else merge_age
                ),
                deadline_hours=VERIFY_AFTER_MERGE_DEADLINE_HOURS,
                evidence={
                    "act_merged_at": act.get("merged_at") or raw.get("act_merged_at"),
                    "verify_checked_at": verify.get("checked_at")
                    or raw.get("verify_checked_at"),
                    "verify_after_merge_hours": verify_after_merge_hours,
                },
            )
        )

    verify_failed_age = age_hours(now, verify_failed)
    repair_after_failure_hours = delta_hours(repair_created, verify_failed)
    rollback_after_failure_hours = delta_hours(rollback_created, verify_failed)
    repair_in_deadline = repair_ref is not None and (
        repair_after_failure_hours is not None
        and 0.0 <= repair_after_failure_hours <= VERIFY_FAIL_REPAIR_DEADLINE_HOURS
    )
    rollback_in_deadline = rollback_ref is not None and (
        rollback_after_failure_hours is not None
        and 0.0 <= rollback_after_failure_hours <= VERIFY_FAIL_REPAIR_DEADLINE_HOURS
    )
    if (
        verify_status_upper == "FAIL"
        and verify_failed_age is not None
        and verify_failed_age > VERIFY_FAIL_REPAIR_DEADLINE_HOURS
        and not repair_in_deadline
        and not rollback_in_deadline
    ):
        violations.append(
            violation(
                raw=raw,
                rule_id="verify_fail_repair_deadline_missed",
                severity="critical",
                message="Failed Verify has no repair PR or rollback within 4 hours.",
                age=verify_failed_age,
                deadline_hours=VERIFY_FAIL_REPAIR_DEADLINE_HOURS,
                evidence={
                    "verify_failed_at": verify.get("failed_at")
                    or raw.get("verify_failed_at"),
                    "repair_ref": repair_ref,
                    "repair_created_at": iso_utc(repair_created)
                    if repair_created
                    else None,
                    "repair_after_failure_hours": repair_after_failure_hours,
                    "rollback_ref": rollback_ref,
                    "rollback_created_at": iso_utc(rollback_created)
                    if rollback_created
                    else None,
                    "rollback_after_failure_hours": rollback_after_failure_hours,
                },
            )
        )

    if (
        is_still_present
        and finding_age is not None
        and finding_age > WEEK_OLD_ESCALATION_HOURS
        and not escalated
    ):
        evidence = first_seen_evidence(first_seen, first_seen_source)
        evidence["escalated"] = escalated
        violations.append(
            violation(
                raw=raw,
                rule_id="week_old_escalation_required",
                severity="critical",
                message="Finding is still present for more than one week without escalation.",
                age=finding_age,
                deadline_hours=WEEK_OLD_ESCALATION_HOURS,
                evidence=evidence,
            )
        )

    return StagnationFinding(
        finding_id=finding_id(raw),
        status=status,
        age_hours=finding_age,
        act_ref=act_ref,
        act_created_at=iso_utc(act_created) if act_created else None,
        act_merged_at=iso_utc(act_merged) if act_merged else None,
        verify_status=verify_status_upper,
        verify_checked_at=iso_utc(verify_checked) if verify_checked else None,
        verify_failed_at=iso_utc(verify_failed) if verify_failed else None,
        escalated=escalated,
        violations=violations,
    )


def build_report(snapshot: dict[str, Any], *, now: datetime) -> StagnationReport:
    findings = [evaluate_finding(raw, now=now) for raw in raw_findings(snapshot)]
    violations = [violation for finding in findings for violation in finding.violations]
    critical = any(item.severity == "critical" for item in violations)
    warning = any(item.severity == "warning" for item in violations)
    status = "critical" if critical else "warning" if warning else "ok"
    return StagnationReport(
        schema_version=1,
        status=status,
        checked_at=iso_utc(now),
        findings_total=len(findings),
        still_present_total=sum(
            1 for item in findings if item.status in STILL_PRESENT_STATUSES
        ),
        violations_total=len(violations),
        escalations_required=sum(
            1 for item in violations if item.rule_id == "week_old_escalation_required"
        ),
        findings=findings,
        violations=violations,
    )


def report_to_json(report: StagnationReport) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def report_to_text(report: StagnationReport) -> str:
    lines = [
        f"GOAL LOOP Anti-Stagnation: {report.status}",
        f"checked_at: {report.checked_at}",
        f"findings_total: {report.findings_total}",
        f"still_present_total: {report.still_present_total}",
        f"violations_total: {report.violations_total}",
        f"escalations_required: {report.escalations_required}",
    ]
    for item in report.violations:
        lines.append(
            f"- {item.finding_id} {item.rule_id}: "
            f"age={item.age_hours}h deadline={item.deadline_hours}h"
        )
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("state_json", help="Anti-stagnation finding lifecycle JSON.")
    parser.add_argument(
        "--now",
        help="Override current time as ISO-8601 for deterministic checks.",
    )
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
        help="Exit non-zero when report status reaches this severity.",
    )
    return parser.parse_args(argv)


def should_fail(report: StagnationReport, mode: str) -> bool:
    rank = {"ok": 0, "warning": 1, "critical": 2}
    if mode == "none":
        return False
    return rank[report.status] >= rank[mode]


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    now = parse_timestamp(args.now) if args.now else datetime.now(timezone.utc)
    if now is None:
        raise ValueError(f"invalid --now timestamp: {args.now}")
    report = build_report(load_json(args.state_json), now=now)
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    return 1 if should_fail(report, args.fail_on) else 0


if __name__ == "__main__":
    raise SystemExit(main())
