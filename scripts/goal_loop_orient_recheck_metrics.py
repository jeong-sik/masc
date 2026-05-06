#!/usr/bin/env python3
"""Derive GOAL LOOP Orient recheck metrics from an Orient JSON report."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load_json_object(path: str) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object: {path}")
    return data


def redact_path(path: str, redactions: list[tuple[str, str]]) -> str:
    for source, replacement in redactions:
        if path == source:
            return replacement
        prefix = source.rstrip("/") + "/"
        if path.startswith(prefix):
            return replacement.rstrip("/") + "/" + path[len(prefix) :]
    return path


def parse_redaction(raw: str) -> tuple[str, str]:
    if "=" not in raw:
        raise ValueError(f"expected FROM=TO redaction, got {raw!r}")
    source, replacement = raw.split("=", 1)
    if not source:
        raise ValueError(f"empty redaction source in {raw!r}")
    return source, replacement


def findings(orient_json: dict[str, Any]) -> list[dict[str, Any]]:
    raw = orient_json.get("findings")
    if not isinstance(raw, list):
        return []
    return [item for item in raw if isinstance(item, dict)]


def present_findings(orient_json: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        item
        for item in findings(orient_json)
        if item.get("status") == "EVIDENCE_PRESENT"
    ]


def finding_id(item: dict[str, Any]) -> str:
    raw = item.get("finding_id")
    return raw if isinstance(raw, str) else ""


def is_new_finding(finding_id: str, prefixes: list[str]) -> bool:
    return any(finding_id.startswith(prefix) for prefix in prefixes)


def source_files(
    orient_json: dict[str, Any], redactions: list[tuple[str, str]]
) -> list[str]:
    raw = orient_json.get("source_files")
    if not isinstance(raw, list):
        return []
    return [redact_path(path, redactions) for path in raw if isinstance(path, str)]


def summary_value(orient_json: dict[str, Any], key: str) -> int | None:
    summary = orient_json.get("summary")
    if not isinstance(summary, dict):
        return None
    raw = summary.get(key)
    if isinstance(raw, bool):
        return int(raw)
    if isinstance(raw, int):
        return raw
    return None


def build_metrics_report(
    orient_json: dict[str, Any],
    *,
    checked_at: str | None,
    redactions: list[tuple[str, str]],
    new_finding_prefixes: list[str],
) -> dict[str, Any]:
    present = present_findings(orient_json)
    present_ids = sorted(finding_id(item) for item in present if finding_id(item))
    present_new_ids = sorted(
        item_id
        for item_id in present_ids
        if is_new_finding(item_id, new_finding_prefixes)
    )
    checked_files = source_files(orient_json, redactions)
    evidence_common: dict[str, Any] = {
        "kind": "orient_recheck_report",
        "script": "scripts/goal_loop_orient_recheck_metrics.py",
        "checked_files": checked_files,
        "raw_log_lines_committed": False,
        "total_lines": orient_json.get("total_lines"),
        "matched_lines": orient_json.get("matched_lines"),
        "findings_total": summary_value(orient_json, "findings_total"),
        "evidence_present": summary_value(orient_json, "evidence_present"),
        "critical_present": summary_value(orient_json, "critical_present"),
        "not_evaluated": summary_value(orient_json, "not_evaluated"),
    }
    if checked_at is not None:
        evidence_common["checked_at"] = checked_at
    return {
        "schema_version": 1,
        "snapshot_kind": "goal_loop_orient_recheck_metrics",
        "metrics": {
            "orient_recheck_still_present": float(len(present_ids)),
            "orient_recheck_new_finding": float(len(present_new_ids)),
        },
        "metric_evidence": {
            "orient_recheck_still_present": {
                **evidence_common,
                "present_finding_ids": present_ids,
                "metric_value_semantics": (
                    "count of Orient findings with status EVIDENCE_PRESENT"
                ),
            },
            "orient_recheck_new_finding": {
                **evidence_common,
                "new_finding_prefixes": new_finding_prefixes,
                "present_new_finding_ids": present_new_ids,
                "metric_value_semantics": (
                    "count of EVIDENCE_PRESENT Orient findings whose finding_id "
                    "starts with a configured new-finding prefix"
                ),
            },
        },
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("orient_json", help="Orient JSON report path.")
    parser.add_argument(
        "--checked-at",
        help="Timestamp to record in metric evidence.",
    )
    parser.add_argument(
        "--redact-prefix",
        action="append",
        default=[],
        metavar="FROM=TO",
        help="Replace a path prefix in source_files. Repeat as needed.",
    )
    parser.add_argument(
        "--new-finding-prefix",
        action="append",
        default=["NEW"],
        help="finding_id prefix counted by orient_recheck_new_finding.",
    )
    parser.add_argument("--pretty", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = build_metrics_report(
        load_json_object(args.orient_json),
        checked_at=args.checked_at,
        redactions=[parse_redaction(raw) for raw in args.redact_prefix],
        new_finding_prefixes=list(args.new_finding_prefix),
    )
    print(
        json.dumps(
            report,
            ensure_ascii=False,
            sort_keys=True,
            indent=2 if args.pretty else None,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
