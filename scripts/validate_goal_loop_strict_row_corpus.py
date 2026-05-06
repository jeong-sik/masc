#!/usr/bin/env python3
"""Validate a supplied GOAL LOOP strict row corpus artifact."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from orient_goal_loop_logs import (
    load_audit_catalog_input,
    load_strict_row_corpus_input,
    validate_strict_row_corpus,
)


def report_to_text(report: dict[str, Any]) -> str:
    status = "VALID" if report["validated"] else "INVALID"
    lines = [
        (
            "strict_row_corpus: "
            f"{status} rows={report['row_count']} "
            f"expected={report.get('expected_findings_total')} "
            f"errors={report['errors_total']}"
        ),
        f"source_catalog_id: {report.get('source_catalog_id') or '<missing>'}",
        f"path_policy_valid: {report['path_policy_valid']}",
    ]
    if report["errors"]:
        lines.append("errors: " + ", ".join(report["errors"]))
    if report["duplicate_finding_ids"]:
        lines.append(
            "duplicate_finding_ids: " + ", ".join(report["duplicate_finding_ids"])
        )
    if report["invalid_source_paths"]:
        lines.append(
            "invalid_source_paths: " + ", ".join(report["invalid_source_paths"])
        )
    if report["invalid_line_refs"]:
        lines.append("invalid_line_refs: " + ", ".join(report["invalid_line_refs"]))
    if report["invalid_replay_expectations"]:
        lines.append(
            "invalid_replay_expectations: "
            + ", ".join(report["invalid_replay_expectations"])
        )
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate a candidate GOAL LOOP strict 206-row corpus before full "
            "Orient replay. This checks shape, row count, source path policy, "
            "line refs, severity/actionability, unique IDs, and replay "
            "expectations."
        )
    )
    parser.add_argument("strict_row_corpus", help="Strict row corpus JSON path.")
    parser.add_argument(
        "--audit-catalog",
        help=(
            "Optional audit catalog JSON. When provided, the corpus "
            "source_catalog_id and expected_findings_total must match it."
        ),
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="text",
        help="Output format (default: text).",
    )
    parser.add_argument(
        "--require-valid",
        action="store_true",
        help="Exit non-zero unless the corpus validates.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        corpus = load_strict_row_corpus_input(args.strict_row_corpus)
        catalog = load_audit_catalog_input(args.audit_catalog)
        report = validate_strict_row_corpus(corpus, catalog=catalog)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.format == "json":
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(report_to_text(report))

    if args.require_valid and not report["validated"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
