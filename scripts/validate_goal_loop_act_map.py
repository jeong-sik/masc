#!/usr/bin/env python3
"""Validate GOAL LOOP ACT map artifact references.

The Decide phase only knows that a decision points at an ACT artifact string.
This guard checks that PR-shaped artifact refs, such as ``PR#13123``, are
present in an explicit known-PR snapshot.  The snapshot can be a deterministic
test fixture or a JSON file captured from ``gh pr list/view``.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


PR_REF_RE = re.compile(r"\bPR#(?P<number>[0-9]+)\b")


@dataclass(frozen=True)
class ArtifactRef:
    decision_id: str
    artifact: str
    pr_number: int | None


@dataclass(frozen=True)
class MissingPrRef:
    decision_id: str
    artifact: str
    pr_number: int


@dataclass(frozen=True)
class ActMapValidationReport:
    artifact_count: int
    known_pr_count: int
    pr_ref_count: int
    missing_pr_count: int
    malformed_artifact_count: int
    missing_prs: list[MissingPrRef]
    malformed_artifacts: list[ArtifactRef]


def load_json(path: str) -> Any:
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def normalize_act_map(raw: Any) -> dict[str, list[str]]:
    if not isinstance(raw, dict):
        raise ValueError("expected ACT map JSON object")
    act_map: dict[str, list[str]] = {}
    for decision_id, value in raw.items():
        if not isinstance(decision_id, str):
            continue
        if isinstance(value, str):
            act_map[decision_id] = [value]
        elif isinstance(value, list):
            act_map[decision_id] = [item for item in value if isinstance(item, str)]
    return act_map


def artifact_refs(act_map: dict[str, list[str]]) -> list[ArtifactRef]:
    refs: list[ArtifactRef] = []
    for decision_id, artifacts in sorted(act_map.items()):
        for artifact in artifacts:
            match = PR_REF_RE.search(artifact)
            refs.append(
                ArtifactRef(
                    decision_id=decision_id,
                    artifact=artifact,
                    pr_number=int(match.group("number")) if match else None,
                )
            )
    return refs


def known_pr_numbers(raw: Any) -> set[int]:
    if raw is None:
        return set()
    if isinstance(raw, dict):
        if isinstance(raw.get("prs"), list):
            return known_pr_numbers(raw["prs"])
        numbers: set[int] = set()
        for key, value in raw.items():
            if isinstance(key, str) and key.isdigit():
                numbers.add(int(key))
            if isinstance(value, dict):
                number = value.get("number")
                if isinstance(number, int):
                    numbers.add(number)
        return numbers
    if isinstance(raw, list):
        numbers = set()
        for item in raw:
            if isinstance(item, int):
                numbers.add(item)
            elif isinstance(item, dict):
                number = item.get("number")
                if isinstance(number, int):
                    numbers.add(number)
        return numbers
    raise ValueError("expected known PR JSON object or array")


def validate_act_map(
    act_map: dict[str, list[str]],
    *,
    known_prs: set[int],
    require_pr_ref: bool,
) -> ActMapValidationReport:
    refs = artifact_refs(act_map)
    missing = [
        MissingPrRef(
            decision_id=ref.decision_id,
            artifact=ref.artifact,
            pr_number=ref.pr_number,
        )
        for ref in refs
        if ref.pr_number is not None and ref.pr_number not in known_prs
    ]
    malformed = [ref for ref in refs if require_pr_ref and ref.pr_number is None]
    return ActMapValidationReport(
        artifact_count=len(refs),
        known_pr_count=len(known_prs),
        pr_ref_count=sum(1 for ref in refs if ref.pr_number is not None),
        missing_pr_count=len(missing),
        malformed_artifact_count=len(malformed),
        missing_prs=missing,
        malformed_artifacts=malformed,
    )


def report_to_json(report: ActMapValidationReport) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def should_fail(report: ActMapValidationReport, mode: str) -> bool:
    if mode == "none":
        return False
    if mode == "missing":
        return report.missing_pr_count > 0
    if mode == "malformed":
        return report.malformed_artifact_count > 0
    if mode == "any":
        return report.missing_pr_count > 0 or report.malformed_artifact_count > 0
    raise ValueError(f"unknown fail mode: {mode}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("act_map_json", help="ACT map JSON file.")
    parser.add_argument(
        "--known-prs-json",
        required=True,
        help="Known PR JSON object/array. Accepts gh-style objects with number fields.",
    )
    parser.add_argument(
        "--require-pr-ref",
        action="store_true",
        help="Treat artifacts without a PR#number token as malformed.",
    )
    parser.add_argument(
        "--fail-on",
        choices=("none", "missing", "malformed", "any"),
        default="missing",
        help="Exit non-zero for this validation class (default: missing).",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = validate_act_map(
        normalize_act_map(load_json(args.act_map_json)),
        known_prs=known_pr_numbers(load_json(args.known_prs_json)),
        require_pr_ref=args.require_pr_ref,
    )
    print(report_to_json(report))
    return 1 if should_fail(report, args.fail_on) else 0


if __name__ == "__main__":
    raise SystemExit(main())
