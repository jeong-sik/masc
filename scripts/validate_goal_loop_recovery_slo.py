#!/usr/bin/env python3
"""Validate GOAL LOOP startup recovery SLO proof artifacts.

The prompt closeout checklist can only mark startup recovery rows PASS when the
artifact records the affected keeper, the recovery action/timing, and useful
turn throughput after recovery.  This checker keeps that proof shape explicit
instead of relying on prose links alone.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, TextIO


EXPECTED_SOURCE_CATALOG_ID = "goal-loop-206-audit-external-claim-2026-05-05"
REQUIRED_PROOF_REQUIREMENT_IDS = (
    "startup-credential-starvation",
    "startup-alive-but-stuck",
)
VALID_EVIDENCE_KINDS = {
    "unit_replay",
    "live_runtime_http",
    "live_runtime_logs",
    "live_runtime_metrics",
    "live_runtime_status",
}
EXPECTED_TRIGGER_TYPES = {
    "startup-credential-starvation": "credential_archived_starvation",
    "startup-alive-but-stuck": "alive_but_stuck",
}


@dataclass(frozen=True)
class RecoverySloReport:
    schema_version: int
    status: str
    source_catalog_id: str | None
    proofs_total: int
    requirements_checked: list[str]
    missing_requirements: list[str]
    errors: list[str]


def load_json_input(path: str, *, stdin: TextIO = sys.stdin) -> dict[str, Any]:
    if path == "-":
        data = json.load(stdin)
    else:
        with Path(path).open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("expected recovery SLO proof JSON object")
    return data


def as_nonempty_str(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped if stripped else None


def as_finite_number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if number == number and abs(number) != float("inf") else None


def as_int_at_least(value: Any, minimum: int) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if value >= minimum else None


def nested_object(parent: dict[str, Any], key: str) -> dict[str, Any] | None:
    value = parent.get(key)
    return value if isinstance(value, dict) else None


def validate_credential_trigger(
    requirement_id: str, trigger: dict[str, Any], errors: list[str]
) -> None:
    if as_int_at_least(trigger.get("archived_credential_count"), 1) is None:
        errors.append(
            f"{requirement_id}: trigger.archived_credential_count must be >= 1"
        )
    if trigger.get("archived_credentials_replaced") is not True:
        errors.append(
            f"{requirement_id}: trigger.archived_credentials_replaced must be true"
        )


def validate_alive_but_stuck_trigger(
    requirement_id: str, trigger: dict[str, Any], errors: list[str]
) -> None:
    elapsed = as_finite_number(trigger.get("elapsed_sec"))
    threshold = as_finite_number(trigger.get("threshold_sec"))
    if elapsed is None or elapsed <= 0.0:
        errors.append(f"{requirement_id}: trigger.elapsed_sec must be > 0")
    if threshold is None or threshold <= 0.0:
        errors.append(f"{requirement_id}: trigger.threshold_sec must be > 0")
    if elapsed is not None and threshold is not None and elapsed <= threshold:
        errors.append(
            f"{requirement_id}: trigger.elapsed_sec must exceed threshold_sec"
        )


def validate_recovery_block(
    requirement_id: str, recovery: dict[str, Any], errors: list[str]
) -> None:
    if recovery.get("executed") is not True:
        errors.append(f"{requirement_id}: recovery.executed must be true")
    if as_nonempty_str(recovery.get("action")) is None:
        errors.append(f"{requirement_id}: recovery.action is required")
    if as_nonempty_str(recovery.get("outcome")) is None:
        errors.append(f"{requirement_id}: recovery.outcome is required")
    if as_nonempty_str(recovery.get("executed_at")) is None:
        errors.append(f"{requirement_id}: recovery.executed_at is required")
    elapsed = as_finite_number(recovery.get("elapsed_to_action_sec"))
    slo = as_finite_number(recovery.get("slo_sec"))
    if elapsed is None or elapsed < 0.0:
        errors.append(f"{requirement_id}: recovery.elapsed_to_action_sec must be >= 0")
    if slo is None or slo <= 0.0:
        errors.append(f"{requirement_id}: recovery.slo_sec must be > 0")
    if elapsed is not None and slo is not None and elapsed > slo:
        errors.append(f"{requirement_id}: recovery elapsed exceeds slo_sec")


def validate_post_recovery_turn(
    requirement_id: str, post_turn: dict[str, Any], errors: list[str]
) -> None:
    if as_nonempty_str(post_turn.get("observed_at")) is None:
        errors.append(f"{requirement_id}: post_recovery_turn.observed_at is required")
    if as_int_at_least(post_turn.get("successful_turns_after"), 1) is None:
        errors.append(
            f"{requirement_id}: post_recovery_turn.successful_turns_after must be >= 1"
        )
    if as_int_at_least(post_turn.get("autonomous_turns_delta"), 1) is None:
        errors.append(
            f"{requirement_id}: post_recovery_turn.autonomous_turns_delta must be >= 1"
        )
    throughput = as_finite_number(post_turn.get("turn_throughput_1h"))
    if throughput is None or throughput <= 0.0:
        errors.append(
            f"{requirement_id}: post_recovery_turn.turn_throughput_1h must be > 0"
        )


def validate_proof_item(
    proof: dict[str, Any],
    *,
    required_requirements: set[str],
    errors: list[str],
) -> str | None:
    requirement_id = as_nonempty_str(proof.get("requirement_id"))
    if requirement_id is None:
        errors.append("proof item missing requirement_id")
        return None
    if requirement_id not in required_requirements:
        return requirement_id
    if as_nonempty_str(proof.get("keeper_name")) is None:
        errors.append(f"{requirement_id}: keeper_name is required")
    evidence_kind = as_nonempty_str(proof.get("evidence_kind"))
    if evidence_kind not in VALID_EVIDENCE_KINDS:
        errors.append(f"{requirement_id}: evidence_kind is invalid")

    trigger = nested_object(proof, "trigger")
    if trigger is None:
        errors.append(f"{requirement_id}: trigger object is required")
    else:
        expected_trigger = EXPECTED_TRIGGER_TYPES[requirement_id]
        if trigger.get("type") != expected_trigger:
            errors.append(f"{requirement_id}: trigger.type must be {expected_trigger}")
        if as_nonempty_str(trigger.get("observed_at")) is None:
            errors.append(f"{requirement_id}: trigger.observed_at is required")
        if requirement_id == "startup-credential-starvation":
            validate_credential_trigger(requirement_id, trigger, errors)
        elif requirement_id == "startup-alive-but-stuck":
            validate_alive_but_stuck_trigger(requirement_id, trigger, errors)

    recovery = nested_object(proof, "recovery")
    if recovery is None:
        errors.append(f"{requirement_id}: recovery object is required")
    else:
        validate_recovery_block(requirement_id, recovery, errors)

    post_turn = nested_object(proof, "post_recovery_turn")
    if post_turn is None:
        errors.append(f"{requirement_id}: post_recovery_turn object is required")
    else:
        validate_post_recovery_turn(requirement_id, post_turn, errors)

    return requirement_id


def validate_recovery_slo_proof(
    proof_json: dict[str, Any],
    *,
    required_requirements: list[str] | None = None,
) -> RecoverySloReport:
    required = set(required_requirements or REQUIRED_PROOF_REQUIREMENT_IDS)
    errors: list[str] = []
    if proof_json.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    source_catalog_id = proof_json.get("source_catalog_id")
    if source_catalog_id != EXPECTED_SOURCE_CATALOG_ID:
        errors.append("source_catalog_id does not match GOAL LOOP audit catalog")
    if as_nonempty_str(proof_json.get("proof_id")) is None:
        errors.append("proof_id is required")
    if as_nonempty_str(proof_json.get("captured_at")) is None:
        errors.append("captured_at is required")

    proofs_raw = proof_json.get("proofs")
    proofs = proofs_raw if isinstance(proofs_raw, list) else []
    if not isinstance(proofs_raw, list):
        errors.append("proofs must be a list")
    seen: set[str] = set()
    for index, proof in enumerate(proofs):
        if not isinstance(proof, dict):
            errors.append(f"proofs[{index}] must be an object")
            continue
        requirement_id = validate_proof_item(
            proof, required_requirements=required, errors=errors
        )
        if requirement_id in required:
            if requirement_id in seen:
                errors.append(f"{requirement_id}: duplicate proof")
            seen.add(requirement_id)

    missing = sorted(required - seen)
    for requirement_id in missing:
        errors.append(f"{requirement_id}: missing required proof")

    return RecoverySloReport(
        schema_version=1,
        status="PASS" if not errors else "FAIL",
        source_catalog_id=source_catalog_id
        if isinstance(source_catalog_id, str)
        else None,
        proofs_total=len(proofs),
        requirements_checked=sorted(seen),
        missing_requirements=missing,
        errors=errors,
    )


def report_to_json(report: RecoverySloReport) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def report_to_text(report: RecoverySloReport) -> str:
    lines = [
        f"GOAL LOOP Recovery SLO Proof: {report.status}",
        f"proofs_total: {report.proofs_total}",
        "requirements_checked: " + ", ".join(report.requirements_checked),
    ]
    if report.missing_requirements:
        lines.append("missing_requirements: " + ", ".join(report.missing_requirements))
    for error in report.errors:
        lines.append(f"- {error}")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("proof_json", help="Recovery SLO proof JSON path, or '-'")
    parser.add_argument(
        "--require",
        action="append",
        default=[],
        help="Requirement id that must have a proof. Repeatable.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format.",
    )
    parser.add_argument(
        "--require-pass",
        action="store_true",
        help="Exit non-zero unless the proof validates.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    payload = load_json_input(args.proof_json)
    report = validate_recovery_slo_proof(
        payload, required_requirements=args.require or None
    )
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    return 1 if args.require_pass and report.status != "PASS" else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
