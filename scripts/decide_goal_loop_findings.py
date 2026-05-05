#!/usr/bin/env python3
"""Decide GOAL LOOP actions from oriented live-log findings.

This consumes the JSON emitted by ``orient_goal_loop_logs.py`` and maps
evidence-present findings to a small, explicit decision queue. It is deliberately
static: the output is an auditable recommendation list, not an auto-remediator.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, TextIO


@dataclass(frozen=True)
class DecisionSpec:
    decision_id: str
    priority: str
    finding_ids: tuple[str, ...]
    action: str
    owner: str
    estimated_hours: int
    impact: int
    urgency: int
    difficulty: int


@dataclass
class DecisionReport:
    decision_id: str
    priority: str
    matched_findings: list[str]
    action: str
    owner: str
    estimated_hours: int
    score: float


@dataclass
class DecideReport:
    source_findings_total: int
    evidence_present: int
    decisions_total: int
    p0_count: int
    decisions: list[DecisionReport]


DECISIONS: tuple[DecisionSpec, ...] = (
    DecisionSpec(
        decision_id="D-EMERGENCY-1",
        priority="P0",
        finding_ids=("NF-2",),
        action="Slot forced reclaim + keeper credential auto-recovery",
        owner="concurrency",
        estimated_hours=8,
        impact=10,
        urgency=10,
        difficulty=8,
    ),
    DecisionSpec(
        decision_id="D-EMERGENCY-2",
        priority="P0",
        finding_ids=("NF-1",),
        action="Run bootstrap provider health checks instead of advisory skip",
        owner="provider",
        estimated_hours=4,
        impact=10,
        urgency=10,
        difficulty=4,
    ),
    DecisionSpec(
        decision_id="D-P1-1",
        priority="P1",
        finding_ids=("NF-3", "R-FATAL-1"),
        action="Execute recovery strategy and add keeper fallback ladder",
        owner="keeper",
        estimated_hours=16,
        impact=9,
        urgency=9,
        difficulty=8,
    ),
    DecisionSpec(
        decision_id="D-P1-2",
        priority="P1",
        finding_ids=("CF-1",),
        action="Add provider discovery/pricing refresh path for catalog misses",
        owner="provider",
        estimated_hours=24,
        impact=8,
        urgency=7,
        difficulty=8,
    ),
    DecisionSpec(
        decision_id="D-P2-1",
        priority="P2",
        finding_ids=("NF-6",),
        action="Enforce keeper TOML schema for unknown keys",
        owner="config",
        estimated_hours=8,
        impact=6,
        urgency=5,
        difficulty=4,
    ),
    DecisionSpec(
        decision_id="D-P2-2",
        priority="P2",
        finding_ids=("NF-4",),
        action="Make governance judge parse failure strict and observable",
        owner="governance",
        estimated_hours=8,
        impact=6,
        urgency=5,
        difficulty=5,
    ),
)


PRIORITY_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}


def load_json_input(path: str) -> dict[str, Any]:
    if path == "-":
        return load_json_handle(sys.stdin)
    with Path(path).open("r", encoding="utf-8") as handle:
        return load_json_handle(handle)


def load_json_handle(handle: TextIO) -> dict[str, Any]:
    data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("expected Orient JSON object")
    return data


def priority_score(spec: DecisionSpec) -> float:
    return float(spec.impact * spec.urgency) / float(max(spec.difficulty, 1))


def present_finding_ids(orient: dict[str, Any]) -> set[str]:
    findings = orient.get("findings", [])
    if not isinstance(findings, list):
        return set()
    present: set[str] = set()
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        if finding.get("status") != "EVIDENCE_PRESENT":
            continue
        finding_id = finding.get("finding_id")
        if isinstance(finding_id, str):
            present.add(finding_id)
    return present


def decide_orient(orient: dict[str, Any]) -> DecideReport:
    present = present_finding_ids(orient)
    decisions: list[DecisionReport] = []
    for spec in DECISIONS:
        matched = [
            finding_id for finding_id in spec.finding_ids if finding_id in present
        ]
        if not matched:
            continue
        decisions.append(
            DecisionReport(
                decision_id=spec.decision_id,
                priority=spec.priority,
                matched_findings=matched,
                action=spec.action,
                owner=spec.owner,
                estimated_hours=spec.estimated_hours,
                score=round(priority_score(spec), 2),
            )
        )

    decisions.sort(
        key=lambda item: (
            PRIORITY_RANK.get(item.priority, 99),
            -item.score,
            item.decision_id,
        )
    )
    source_findings = orient.get("findings", [])
    source_findings_total = (
        len(source_findings) if isinstance(source_findings, list) else 0
    )
    return DecideReport(
        source_findings_total=source_findings_total,
        evidence_present=len(present),
        decisions_total=len(decisions),
        p0_count=sum(1 for decision in decisions if decision.priority == "P0"),
        decisions=decisions,
    )


def report_to_json(report: DecideReport) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def report_to_text(report: DecideReport) -> str:
    lines = [
        "GOAL LOOP Decide Queue",
        f"evidence_present: {report.evidence_present}/{report.source_findings_total}",
        f"decisions_total: {report.decisions_total}",
        f"p0_count: {report.p0_count}",
    ]
    for decision in report.decisions:
        lines.append(
            f"- {decision.decision_id} {decision.priority} score={decision.score}: "
            f"{decision.action} "
            f"(owner={decision.owner}, findings={','.join(decision.matched_findings)}, "
            f"eta={decision.estimated_hours}h)"
        )
    return "\n".join(lines)


def should_fail(report: DecideReport, mode: str) -> bool:
    if mode == "none":
        return False
    if mode == "any":
        return report.decisions_total > 0
    if mode == "p0":
        return report.p0_count > 0
    raise ValueError(f"unknown fail mode: {mode}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "orient_json",
        nargs="?",
        default="-",
        help="Orient JSON path, or '-' for stdin (default).",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format (default: json).",
    )
    parser.add_argument(
        "--fail-on",
        choices=("none", "any", "p0"),
        default="none",
        help="Exit non-zero when decisions match this condition.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = decide_orient(load_json_input(args.orient_json))
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    return 1 if should_fail(report, args.fail_on) else 0


if __name__ == "__main__":
    raise SystemExit(main())
