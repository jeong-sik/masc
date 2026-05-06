#!/usr/bin/env python3
"""Build the strict GOAL LOOP Verify pipeline result.

This maps the prompt-level ``verify.yml`` gates into a repo-owned JSON contract.
It does not claim that missing production evidence is green: absent metric,
TLA, log, or orient inputs become explicit BLOCKED/SKIPPED gate records.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

try:
    from scripts.verify_goal_loop_logs import verify_log_contract
except ModuleNotFoundError:  # pragma: no cover - direct script execution path
    from verify_goal_loop_logs import verify_log_contract


PROMPT_TLA_SPECS = ("TierRouting.tla", "Validation.tla", "Liveness.tla")
REQUIRED_VERIFY_GATE_IDS = (
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
)
PROMETHEUS_METRIC_SOURCES = {
    "keeper_turn_success_rate": ["masc_keeper_turns_total"],
    "keeper_skipping_turn_rate_5m": ["masc_keeper_semaphore_wait_timeout_total"],
    "pricing_catalog_miss_total": ["masc_pricing_catalog_miss_total"],
    "persistence_utf8_repair_total": ["masc_persistence_utf8_repair_total"],
    "dashboard_snapshot_latency_p99": [
        "masc_dashboard_snapshot_latency_seconds_bucket"
    ],
    "admission_queue_depth": ["masc_inference_queue_depth"],
    "admission_queue_wait_ms": ["masc_inference_queue_wait_seconds"],
}

DEFAULT_MUST_CONTAIN = (
    "recovery_strategy_executed",
    "provider_health_probe_completed",
    "fallback_ladder_activated",
)
DEFAULT_MUST_NOT_CONTAIN = (
    "skipping turn.*semaphore wait",
    "pricing_catalog_miss",
    "persistence UTF-8 repaired",
    "alive-but-stuck detected",
    "Lenient_json fallback hit",
    "archived credential.*starvation",
)


@dataclass(frozen=True)
class VerifyGate:
    gate_id: str
    category: str
    status: str
    summary: str
    command: list[str] | None
    reason: str | None
    evidence: dict[str, Any]


@dataclass(frozen=True)
class VerifyPipelineReport:
    schema_version: int
    status: str
    gates_total: int
    gates_passed: int
    gates_failed: int
    gates_blocked: int
    gates_skipped: int
    gates: list[VerifyGate]


def load_json_file(path: str | None) -> dict[str, Any] | None:
    if path is None:
        return None
    with Path(path).open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object: {path}")
    return data


def gate(
    gate_id: str,
    category: str,
    status: str,
    summary: str,
    *,
    command: list[str] | None = None,
    reason: str | None = None,
    evidence: dict[str, Any] | None = None,
) -> VerifyGate:
    return VerifyGate(
        gate_id=gate_id,
        category=category,
        status=status,
        summary=summary,
        command=command,
        reason=reason,
        evidence=evidence or {},
    )


def metrics_root(metrics_json: dict[str, Any] | None) -> dict[str, Any] | None:
    if metrics_json is None:
        return None
    nested = metrics_json.get("metrics")
    return nested if isinstance(nested, dict) else metrics_json


def metric_value(metrics: dict[str, Any] | None, key: str) -> float | None:
    if metrics is None or key not in metrics:
        return None
    raw = metrics[key]
    if isinstance(raw, dict):
        raw = raw.get("value")
    if isinstance(raw, bool):
        return 1.0 if raw else 0.0
    if isinstance(raw, (int, float)):
        return float(raw)
    return None


def metric_value_provenance(
    metrics_json: dict[str, Any] | None, key: str
) -> Any | None:
    if metrics_json is None:
        return None
    metric_evidence = metrics_json.get("metric_evidence")
    if isinstance(metric_evidence, dict) and key in metric_evidence:
        return metric_evidence[key]
    source = metrics_json.get("source")
    if not isinstance(source, dict):
        return None
    manual_overrides = source.get("manual_overrides")
    if not isinstance(manual_overrides, dict) or key not in manual_overrides:
        return None
    return {"kind": "manual_override", "detail": manual_overrides[key]}


def metric_gate(
    metrics: dict[str, Any] | None,
    *,
    gate_id: str,
    metric_name: str,
    category: str,
    predicate: str,
    command: list[str],
    value_provenance: Any | None = None,
) -> VerifyGate:
    value = metric_value(metrics, metric_name)
    evidence = {
        "metric_name": metric_name,
        "metric_snapshot_key": metric_name,
        "metric_source": "GOAL_LOOP_METRICS_JSON (--metrics-json)",
        "prometheus_sources": PROMETHEUS_METRIC_SOURCES.get(metric_name, []),
        "value": value,
        "predicate": predicate,
    }
    if value_provenance is not None:
        evidence["value_provenance"] = value_provenance
    if metrics is None:
        return gate(
            gate_id,
            category,
            "BLOCKED",
            f"{metric_name} cannot be evaluated without a production metric snapshot.",
            command=command,
            reason="missing_metric_snapshot",
            evidence=evidence,
        )
    if value is None:
        return gate(
            gate_id,
            category,
            "BLOCKED",
            f"{metric_name} is absent from the production metric snapshot.",
            command=command,
            reason="missing_metric",
            evidence=evidence,
        )

    passed = {
        "== 0": value == 0.0,
        "> 0": value > 0.0,
        "> 0.95": value > 0.95,
        "< 5.0": value < 5.0,
    }[predicate]
    return gate(
        gate_id,
        category,
        "PASS" if passed else "FAIL",
        f"{metric_name} {predicate}",
        command=command,
        reason=None if passed else "predicate_failed",
        evidence=evidence,
    )


def metric_snapshot_command(metric_name: str) -> list[str]:
    return [
        "sh",
        "-c",
        (
            f"jq '(.metrics // .).{metric_name}' "
            '"${GOAL_LOOP_METRICS_JSON:?set GOAL_LOOP_METRICS_JSON to production metric snapshot JSON}"'
        ),
    ]


def orient_recheck_metric_command(metric_name: str) -> list[str]:
    return [
        "sh",
        "-c",
        (
            "python3 scripts/goal_loop_orient_recheck_metrics.py "
            '"${GOAL_LOOP_ORIENT_RECHECK_JSON:?set GOAL_LOOP_ORIENT_RECHECK_JSON to Orient JSON report}" '
            "--pretty | "
            f"jq '.metrics.{metric_name}'"
        ),
    ]


def admission_backpressure_gate(
    metrics: dict[str, Any] | None,
    *,
    queue_depth_provenance: Any | None = None,
    wait_ms_provenance: Any | None = None,
) -> VerifyGate:
    queue_depth = metric_value(metrics, "admission_queue_depth")
    wait_ms = metric_value(metrics, "admission_queue_wait_ms")
    evidence = {
        "admission_queue_depth": queue_depth,
        "admission_queue_wait_ms": wait_ms,
        "metric_source": "GOAL_LOOP_METRICS_JSON (--metrics-json)",
        "prometheus_sources": {
            "admission_queue_depth": PROMETHEUS_METRIC_SOURCES["admission_queue_depth"],
            "admission_queue_wait_ms": PROMETHEUS_METRIC_SOURCES[
                "admission_queue_wait_ms"
            ],
        },
        "predicate": "admission_queue_depth > 0 || admission_queue_wait_ms > 0",
    }
    value_provenance: dict[str, Any] = {}
    if queue_depth_provenance is not None:
        value_provenance["admission_queue_depth"] = queue_depth_provenance
    if wait_ms_provenance is not None:
        value_provenance["admission_queue_wait_ms"] = wait_ms_provenance
    if value_provenance:
        evidence["value_provenance"] = value_provenance
    command = [
        "sh",
        "-c",
        (
            "jq '(.metrics // .) | {admission_queue_depth, admission_queue_wait_ms}' "
            '"${GOAL_LOOP_METRICS_JSON:?set GOAL_LOOP_METRICS_JSON to production metric snapshot JSON}"'
        ),
    ]
    if metrics is None:
        return gate(
            "admission_backpressure_observed",
            "regression_metric",
            "BLOCKED",
            "Admission backpressure cannot be evaluated without a metric snapshot.",
            command=command,
            reason="missing_metric_snapshot",
            evidence=evidence,
        )
    if queue_depth is None and wait_ms is None:
        return gate(
            "admission_backpressure_observed",
            "regression_metric",
            "BLOCKED",
            "Admission backpressure metrics are absent from the snapshot.",
            command=command,
            reason="missing_metric",
            evidence=evidence,
        )
    passed = (queue_depth or 0.0) > 0.0 or (wait_ms or 0.0) > 0.0
    return gate(
        "admission_backpressure_observed",
        "regression_metric",
        "PASS" if passed else "FAIL",
        "Admission queue must show real backpressure instead of 100% passthrough.",
        command=command,
        reason=None if passed else "predicate_failed",
        evidence=evidence,
    )


def build_metric_gates(metrics_json: dict[str, Any] | None) -> list[VerifyGate]:
    metrics = metrics_root(metrics_json)
    return [
        metric_gate(
            metrics,
            gate_id="keeper_turn_success_rate_healthy",
            metric_name="keeper_turn_success_rate",
            category="metric_verification",
            predicate="> 0.95",
            command=metric_snapshot_command("keeper_turn_success_rate"),
            value_provenance=metric_value_provenance(
                metrics_json, "keeper_turn_success_rate"
            ),
        ),
        metric_gate(
            metrics,
            gate_id="no_semaphore_skip",
            metric_name="keeper_skipping_turn_rate_5m",
            category="regression_metric",
            predicate="== 0",
            command=metric_snapshot_command("keeper_skipping_turn_rate_5m"),
            value_provenance=metric_value_provenance(
                metrics_json, "keeper_skipping_turn_rate_5m"
            ),
        ),
        metric_gate(
            metrics,
            gate_id="no_pricing_miss",
            metric_name="pricing_catalog_miss_total",
            category="regression_metric",
            predicate="== 0",
            command=metric_snapshot_command("pricing_catalog_miss_total"),
            value_provenance=metric_value_provenance(
                metrics_json, "pricing_catalog_miss_total"
            ),
        ),
        metric_gate(
            metrics,
            gate_id="no_utf8_repair",
            metric_name="persistence_utf8_repair_total",
            category="regression_metric",
            predicate="== 0",
            command=metric_snapshot_command("persistence_utf8_repair_total"),
            value_provenance=metric_value_provenance(
                metrics_json, "persistence_utf8_repair_total"
            ),
        ),
        metric_gate(
            metrics,
            gate_id="recovery_executed",
            metric_name="recovery_strategy_executed_total_1h",
            category="regression_metric",
            predicate="> 0",
            command=metric_snapshot_command("recovery_strategy_executed_total_1h"),
            value_provenance=metric_value_provenance(
                metrics_json, "recovery_strategy_executed_total_1h"
            ),
        ),
        admission_backpressure_gate(
            metrics,
            queue_depth_provenance=metric_value_provenance(
                metrics_json, "admission_queue_depth"
            ),
            wait_ms_provenance=metric_value_provenance(
                metrics_json, "admission_queue_wait_ms"
            ),
        ),
        metric_gate(
            metrics,
            gate_id="dashboard_snapshot_latency_p99",
            metric_name="dashboard_snapshot_latency_p99",
            category="metric_verification",
            predicate="< 5.0",
            command=metric_snapshot_command("dashboard_snapshot_latency_p99"),
            value_provenance=metric_value_provenance(
                metrics_json, "dashboard_snapshot_latency_p99"
            ),
        ),
        metric_gate(
            metrics,
            gate_id="orient_recheck_no_still_present",
            metric_name="orient_recheck_still_present",
            category="orient_recheck",
            predicate="== 0",
            command=orient_recheck_metric_command("orient_recheck_still_present"),
            value_provenance=metric_value_provenance(
                metrics_json, "orient_recheck_still_present"
            ),
        ),
        metric_gate(
            metrics,
            gate_id="orient_recheck_no_new_finding",
            metric_name="orient_recheck_new_finding",
            category="orient_recheck",
            predicate="== 0",
            command=orient_recheck_metric_command("orient_recheck_new_finding"),
            value_provenance=metric_value_provenance(
                metrics_json, "orient_recheck_new_finding"
            ),
        ),
    ]


def find_tla_spec(repo_root: Path, spec_name: str) -> str | None:
    for path in repo_root.joinpath("specs").rglob(spec_name):
        return path.relative_to(repo_root).as_posix()
    return None


def tla_result_for(tla_results: dict[str, Any] | None, spec_name: str) -> str | None:
    if tla_results is None:
        return None
    raw = tla_results.get(spec_name)
    if isinstance(raw, dict):
        raw = raw.get("status")
    if isinstance(raw, str):
        return raw
    specs = tla_results.get("specs")
    if isinstance(specs, dict):
        raw = specs.get(spec_name)
        if isinstance(raw, dict):
            raw = raw.get("status")
        return raw if isinstance(raw, str) else None
    if isinstance(specs, list):
        for entry in specs:
            if not isinstance(entry, dict):
                continue
            if entry.get("spec") == spec_name or entry.get("name") == spec_name:
                status = entry.get("status")
                return status if isinstance(status, str) else None
    return None


def build_tla_gates(
    *,
    repo_root: Path,
    tla_results: dict[str, Any] | None,
) -> list[VerifyGate]:
    gates: list[VerifyGate] = []
    for spec_name in PROMPT_TLA_SPECS:
        found_path = find_tla_spec(repo_root, spec_name)
        result = tla_result_for(tla_results, spec_name)
        evidence = {
            "prompt_spec": spec_name,
            "resolved_path": found_path,
            "result_status": result,
        }
        if found_path is None:
            gates.append(
                gate(
                    f"tla_prompt_spec_{spec_name.removesuffix('.tla').lower()}",
                    "tla_check",
                    "BLOCKED",
                    f"Prompt TLA spec {spec_name} is not present in specs/.",
                    command=["scripts/tla-check.sh"],
                    reason="prompt_tla_spec_missing",
                    evidence=evidence,
                )
            )
            continue
        if result is None:
            gates.append(
                gate(
                    f"tla_prompt_spec_{spec_name.removesuffix('.tla').lower()}",
                    "tla_check",
                    "SKIPPED",
                    f"Prompt TLA spec {spec_name} exists but no TLC result was supplied.",
                    command=["scripts/tla-check.sh"],
                    reason="tla_result_not_supplied",
                    evidence=evidence,
                )
            )
            continue
        passed = result.upper() == "PASS"
        gates.append(
            gate(
                f"tla_prompt_spec_{spec_name.removesuffix('.tla').lower()}",
                "tla_check",
                "PASS" if passed else "FAIL",
                f"Prompt TLA spec {spec_name} TLC result is {result}.",
                command=["scripts/tla-check.sh"],
                reason=None if passed else "tla_check_failed",
                evidence=evidence,
            )
        )
    return gates


def build_log_gate(
    log_paths: list[str],
    *,
    log_contract_json: dict[str, Any] | None = None,
) -> VerifyGate:
    command = [
        "scripts/verify_goal_loop_logs.py",
        "--mode",
        "log-contract",
        "--must-contain",
        "...",
        "--must-not-contain",
        "...",
    ]
    if log_contract_json is not None:
        status = log_contract_json.get("status")
        if status not in {"PASS", "FAIL"}:
            raise ValueError("log contract JSON status must be PASS or FAIL")
        return gate(
            "post_act_log_contract",
            "log_verification",
            status,
            "Post-ACT production log contract was evaluated from supplied report JSON.",
            command=command,
            reason=None if status == "PASS" else "log_contract_failed",
            evidence=log_contract_json,
        )

    if not log_paths:
        return gate(
            "post_act_log_contract",
            "log_verification",
            "BLOCKED",
            "Post-ACT production log contract was not evaluated.",
            command=command,
            reason="missing_post_act_logs",
            evidence={
                "must_contain": list(DEFAULT_MUST_CONTAIN),
                "must_not_contain": list(DEFAULT_MUST_NOT_CONTAIN),
            },
        )

    report = verify_log_contract(
        log_paths,
        must_contain=list(DEFAULT_MUST_CONTAIN),
        must_not_contain=list(DEFAULT_MUST_NOT_CONTAIN),
        max_samples=3,
    )
    return gate(
        "post_act_log_contract",
        "log_verification",
        report.status,
        "Post-ACT production logs satisfy the required/forbidden pattern contract.",
        command=command,
        reason=None if report.status == "PASS" else "log_contract_failed",
        evidence=asdict(report),
    )


def build_unit_gate(unit_tests_passed: bool, unit_tests_failed: bool) -> VerifyGate:
    command = ["dune", "runtest", "test/"]
    if unit_tests_passed and unit_tests_failed:
        return gate(
            "unit_tests",
            "unit_tests",
            "FAIL",
            "Unit test gate received conflicting pass/fail evidence.",
            command=command,
            reason="conflicting_unit_test_evidence",
        )
    if unit_tests_passed:
        return gate(
            "unit_tests",
            "unit_tests",
            "PASS",
            "Unit tests were reported as passing.",
            command=command,
            evidence={"reported": "passed"},
        )
    if unit_tests_failed:
        return gate(
            "unit_tests",
            "unit_tests",
            "FAIL",
            "Unit tests were reported as failing.",
            command=command,
            reason="unit_tests_failed",
            evidence={"reported": "failed"},
        )
    return gate(
        "unit_tests",
        "unit_tests",
        "SKIPPED",
        "Unit test command is mapped but no run evidence was supplied.",
        command=command,
        reason="unit_tests_not_run",
        evidence={"reported": "not_supplied"},
    )


def _assert_emitted_gate_ids_match_required(gates: list[VerifyGate]) -> None:
    """Refuse to build a pipeline report whose gate IDs drift from the
    declared contract in ``REQUIRED_VERIFY_GATE_IDS``.

    Without this check, a future edit to gate construction (renaming,
    accidental duplication, dropped gate) could silently change the
    pipeline contract: callers that key off specific gate_ids would
    fail downstream instead of at the script boundary. Raising here
    surfaces the drift at the producing site.
    """
    emitted = [gate.gate_id for gate in gates]
    counts: dict[str, int] = {}
    for gate_id in emitted:
        counts[gate_id] = counts.get(gate_id, 0) + 1
    duplicates = sorted(gate_id for gate_id, freq in counts.items() if freq > 1)
    required = set(REQUIRED_VERIFY_GATE_IDS)
    emitted_set = set(emitted)
    missing = sorted(required - emitted_set)
    extra = sorted(emitted_set - required)
    problems: list[str] = []
    if missing:
        problems.append(f"missing={missing}")
    if extra:
        problems.append(f"extra={extra}")
    if duplicates:
        problems.append(f"duplicates={duplicates}")
    if problems:
        raise AssertionError(
            "Verify pipeline gate-id contract drift: " + "; ".join(problems)
        )


def build_pipeline_report(
    *,
    repo_root: Path,
    metrics_json: dict[str, Any] | None,
    tla_results: dict[str, Any] | None,
    log_paths: list[str],
    unit_tests_passed: bool,
    unit_tests_failed: bool,
    log_contract_json: dict[str, Any] | None = None,
) -> VerifyPipelineReport:
    gates = [
        build_unit_gate(unit_tests_passed, unit_tests_failed),
        *build_metric_gates(metrics_json),
        *build_tla_gates(repo_root=repo_root, tla_results=tla_results),
        build_log_gate(log_paths, log_contract_json=log_contract_json),
    ]
    _assert_emitted_gate_ids_match_required(gates)
    counts = {
        status: sum(1 for item in gates if item.status == status)
        for status in (
            "PASS",
            "FAIL",
            "BLOCKED",
            "SKIPPED",
        )
    }
    if counts["FAIL"] > 0:
        status = "FAIL"
    elif counts["BLOCKED"] > 0 or counts["SKIPPED"] > 0:
        status = "BLOCKED"
    else:
        status = "PASS"
    return VerifyPipelineReport(
        schema_version=1,
        status=status,
        gates_total=len(gates),
        gates_passed=counts["PASS"],
        gates_failed=counts["FAIL"],
        gates_blocked=counts["BLOCKED"],
        gates_skipped=counts["SKIPPED"],
        gates=gates,
    )


def report_to_json(report: VerifyPipelineReport) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def report_to_text(report: VerifyPipelineReport) -> str:
    lines = [f"GOAL LOOP Verify Pipeline: {report.status}"]
    lines.append(
        "gates: "
        f"pass={report.gates_passed} fail={report.gates_failed} "
        f"blocked={report.gates_blocked} skipped={report.gates_skipped}"
    )
    for item in report.gates:
        suffix = f" ({item.reason})" if item.reason else ""
        lines.append(f"- {item.gate_id}: {item.status}{suffix}")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--metrics-json",
        help=(
            "Production metric snapshot JSON using the gate metric_name fields. "
            "Accepts top-level metrics or {'metrics': {...}}."
        ),
    )
    parser.add_argument(
        "--tla-results-json",
        help=(
            "Optional TLC result JSON. Accepts top-level spec keys "
            "or {'specs': {...}} / {'specs': [{'spec'|'name', 'status'}]}."
        ),
    )
    parser.add_argument(
        "--log",
        action="append",
        default=[],
        help="Post-ACT production log path. Repeat for multiple files.",
    )
    parser.add_argument(
        "--log-contract-json",
        help=(
            "Optional precomputed log-contract report JSON from "
            "verify_goal_loop_logs.py --mode log-contract."
        ),
    )
    parser.add_argument(
        "--unit-tests-passed",
        action="store_true",
        help="Record the unit test gate as PASS.",
    )
    parser.add_argument(
        "--unit-tests-failed",
        action="store_true",
        help="Record the unit test gate as FAIL.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format (default: json).",
    )
    parser.add_argument(
        "--require-pass",
        action="store_true",
        help="Exit non-zero unless every gate passes.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    repo_root = Path(__file__).resolve().parents[1]
    report = build_pipeline_report(
        repo_root=repo_root,
        metrics_json=load_json_file(args.metrics_json),
        tla_results=load_json_file(args.tla_results_json),
        log_paths=list(args.log),
        log_contract_json=load_json_file(args.log_contract_json),
        unit_tests_passed=args.unit_tests_passed,
        unit_tests_failed=args.unit_tests_failed,
    )
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    if args.require_pass and report.status != "PASS":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
