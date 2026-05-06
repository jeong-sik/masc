#!/usr/bin/env python3
"""Inventory explicit GOAL LOOP row candidates from prompt source docs."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_CATALOG_ID = "goal-loop-206-audit-external-claim-2026-05-05"
DEFAULT_SOURCE_PREFIX = "prompt_corpus/GOAL_LOOP/"
DEFAULT_EXPECTED_TOTAL = 206

EXACT_ID_RE = re.compile(
    r"\b(?P<id>(?:R-FATAL|CD|CC|CE|CF|NF)-\d+|P-[A-Z]+-\d{2}|[SF]\d{2})\b"
)
MARKDOWN_TABLE_ROW_RE = re.compile(r"^\|\s*(?P<id>[^|]+?)\s*\|(?P<rest>.*)$")
CODE_SWITCH_ID_RE = re.compile(
    r'^\s*\|\s*"(?P<id>(?:R-FATAL|CD|CC|CE|CF|NF)-\d+)"\s*'
    r"(?:\(\*\s*(?P<title>.*?)\s*\*\))?"
)
COLON_ID_RE = re.compile(
    r"^\s*[│|> -]*\s*(?P<id>(?:R-FATAL|CD|CC|CE|CF|NF)-\d+|P-[A-Z]+-\d{2}|[SF]\d{2})"
    r"\s*:\s*(?P<title>.+?)\s*(?:[🔴🟡🟢]|$)"
)
AUDIT_DERIVED_HEADING_RE = re.compile(
    r"^#{2,6}\s+#(?P<num>\d+)\s+\[(?P<severity>[^\]]+)\]\s+(?P<title>.+)"
)
DEEP_AUDIT_HEADING_RE = re.compile(r"^#{2,6}\s+(?P<num>\d+(?:\.\d+)+)\s+(?P<title>.+)")


@dataclass(frozen=True)
class Candidate:
    candidate_id: str
    title: str
    extraction_rule: str
    priority: int
    source_path: str
    line_ref: int
    snippet: str
    severity_hint: str | None = None

    def to_json(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "candidate_id": self.candidate_id,
            "title": self.title,
            "extraction_rule": self.extraction_rule,
            "source": {"path": self.source_path, "line_refs": [self.line_ref]},
            "snippet": self.snippet,
        }
        if self.severity_hint:
            payload["severity_hint"] = self.severity_hint
        return payload


def clean_title(value: str) -> str:
    cleaned = value.strip()
    cleaned = cleaned.strip("` ")
    cleaned = re.sub(r"\s+", " ", cleaned)
    return cleaned


def logical_source_path(path: Path, source_prefix: str) -> str:
    return f"{source_prefix.rstrip('/')}/{path.name}"


def table_cells(line: str) -> list[str]:
    stripped = line.strip()
    if not stripped.startswith("|") or not stripped.endswith("|"):
        return []
    return [cell.strip() for cell in stripped.strip("|").split("|")]


def severity_from_cells(cells: list[str]) -> str | None:
    for cell in cells:
        normalized = cell.strip("* ").lower()
        if normalized in {"critical", "high", "medium", "low", "warning", "info"}:
            return normalized
    return None


def candidate_from_table_row(
    *,
    line: str,
    source_path: str,
    line_ref: int,
) -> Candidate | None:
    cells = table_cells(line)
    if len(cells) < 2:
        return None
    first = cells[0]
    match = EXACT_ID_RE.fullmatch(first)
    if match is None:
        return None
    title = next((cell for cell in cells[1:] if cell and set(cell) != {"-"}), line)
    return Candidate(
        candidate_id=match.group("id"),
        title=clean_title(title),
        extraction_rule="markdown_table_id_row",
        priority=100,
        source_path=source_path,
        line_ref=line_ref,
        snippet=line.strip(),
        severity_hint=severity_from_cells(cells),
    )


def candidate_from_code_switch(
    *,
    line: str,
    source_path: str,
    line_ref: int,
) -> Candidate | None:
    match = CODE_SWITCH_ID_RE.match(line)
    if match is None:
        return None
    title = match.group("title") or match.group("id")
    return Candidate(
        candidate_id=match.group("id"),
        title=clean_title(title),
        extraction_rule="ocaml_switch_finding_id",
        priority=80,
        source_path=source_path,
        line_ref=line_ref,
        snippet=line.strip(),
    )


def candidate_from_colon_line(
    *,
    line: str,
    source_path: str,
    line_ref: int,
) -> Candidate | None:
    match = COLON_ID_RE.match(line)
    if match is None:
        return None
    return Candidate(
        candidate_id=match.group("id"),
        title=clean_title(match.group("title")),
        extraction_rule="colon_finding_id_line",
        priority=70,
        source_path=source_path,
        line_ref=line_ref,
        snippet=line.strip(),
    )


def candidate_from_audit_heading(
    *,
    path: Path,
    line: str,
    source_path: str,
    line_ref: int,
) -> Candidate | None:
    if path.name != "audit_derived_state.md":
        return None
    match = AUDIT_DERIVED_HEADING_RE.match(line)
    if match is None:
        return None
    candidate_id = f"AUDIT-DERIVED-{int(match.group('num')):03d}"
    return Candidate(
        candidate_id=candidate_id,
        title=clean_title(match.group("title")),
        extraction_rule="audit_derived_numbered_heading",
        priority=90,
        source_path=source_path,
        line_ref=line_ref,
        snippet=line.strip(),
        severity_hint=match.group("severity").lower(),
    )


def candidate_from_deep_audit_heading(
    *,
    path: Path,
    line: str,
    source_path: str,
    line_ref: int,
) -> Candidate | None:
    if path.name != "deep_audit_dashboard_heuristic.md":
        return None
    match = DEEP_AUDIT_HEADING_RE.match(line)
    if match is None:
        return None
    title = clean_title(match.group("title"))
    if "Table of Contents" in title:
        return None
    candidate_id = f"DEEP-AUDIT-{match.group('num').replace('.', '-')}"
    return Candidate(
        candidate_id=candidate_id,
        title=title,
        extraction_rule="deep_audit_decimal_heading",
        priority=90,
        source_path=source_path,
        line_ref=line_ref,
        snippet=line.strip(),
    )


def generic_id_candidates(
    *,
    line: str,
    source_path: str,
    line_ref: int,
) -> list[Candidate]:
    candidates: list[Candidate] = []
    for match in EXACT_ID_RE.finditer(line):
        if match.end() < len(line) and line[match.end()] == "~":
            continue
        candidate_id = match.group("id")
        candidates.append(
            Candidate(
                candidate_id=candidate_id,
                title=clean_title(line) or candidate_id,
                extraction_rule="generic_explicit_id_mention",
                priority=10,
                source_path=source_path,
                line_ref=line_ref,
                snippet=line.strip(),
            )
        )
    return candidates


def choose_candidate(
    existing: Candidate | None,
    candidate: Candidate,
) -> Candidate:
    if existing is None:
        return candidate
    if candidate.priority > existing.priority:
        return candidate
    if (
        candidate.priority == existing.priority
        and candidate.line_ref < existing.line_ref
    ):
        return candidate
    return existing


def inventory_sources(
    paths: list[Path],
    *,
    source_catalog_id: str = DEFAULT_CATALOG_ID,
    expected_total: int = DEFAULT_EXPECTED_TOTAL,
    source_prefix: str = DEFAULT_SOURCE_PREFIX,
    include_candidates: bool = True,
) -> dict[str, Any]:
    candidates_by_id: dict[str, Candidate] = {}
    source_errors: list[dict[str, str]] = []
    sources_checked: list[str] = []

    for path in paths:
        source_path = logical_source_path(path, source_prefix)
        sources_checked.append(source_path)
        try:
            lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError as exc:
            source_errors.append(
                {"path": source_path, "error": f"{type(exc).__name__}: {exc}"}
            )
            continue

        for line_ref, line in enumerate(lines, start=1):
            line_candidates = [
                candidate_from_table_row(
                    line=line,
                    source_path=source_path,
                    line_ref=line_ref,
                ),
                candidate_from_code_switch(
                    line=line,
                    source_path=source_path,
                    line_ref=line_ref,
                ),
                candidate_from_colon_line(
                    line=line,
                    source_path=source_path,
                    line_ref=line_ref,
                ),
                candidate_from_audit_heading(
                    path=path,
                    line=line,
                    source_path=source_path,
                    line_ref=line_ref,
                ),
                candidate_from_deep_audit_heading(
                    path=path,
                    line=line,
                    source_path=source_path,
                    line_ref=line_ref,
                ),
                *generic_id_candidates(
                    line=line,
                    source_path=source_path,
                    line_ref=line_ref,
                ),
            ]
            for candidate in line_candidates:
                if candidate is None:
                    continue
                candidates_by_id[candidate.candidate_id] = choose_candidate(
                    candidates_by_id.get(candidate.candidate_id),
                    candidate,
                )

    candidates = sorted(candidates_by_id.values(), key=lambda item: item.candidate_id)
    by_file: dict[str, int] = {}
    by_rule: dict[str, int] = {}
    for candidate in candidates:
        by_file[candidate.source_path] = by_file.get(candidate.source_path, 0) + 1
        by_rule[candidate.extraction_rule] = (
            by_rule.get(candidate.extraction_rule, 0) + 1
        )

    row_count = len(candidates)
    status = (
        "COMPLETE"
        if row_count == expected_total and not source_errors
        else "INCOMPLETE"
    )
    result = (
        "EXPLICIT_SOURCE_ROWS_MATCH_EXPECTED"
        if status == "COMPLETE"
        else "EXPLICIT_SOURCE_ROWS_INSUFFICIENT"
    )
    payload: dict[str, Any] = {
        "schema_version": 1,
        "inventory_id": "goal-loop-explicit-source-row-candidates-v1",
        "source_catalog_id": source_catalog_id,
        "status": status,
        "result": result,
        "extraction_policy": (
            "Conservative explicit rows only: exact finding IDs, exact S/F "
            "anti-pattern IDs, markdown table ID rows, and numbered audit "
            "section headings in the two audit reports. Ranges and roadmap "
            "phase bullets are not expanded into invented rows."
        ),
        "expected_findings_total": expected_total,
        "unique_candidate_rows": row_count,
        "missing_candidate_rows": max(expected_total - row_count, 0),
        "prompt_sources_checked": sorted(sources_checked),
        "source_errors_total": len(source_errors),
        "source_errors": source_errors,
        "candidates_by_file": [
            {"path": path, "unique_candidate_rows": count}
            for path, count in sorted(by_file.items())
        ],
        "candidates_by_rule": [
            {"rule": rule, "unique_candidate_rows": count}
            for rule, count in sorted(by_rule.items())
        ],
    }
    if include_candidates:
        payload["candidate_rows"] = [candidate.to_json() for candidate in candidates]
    return payload


def report_to_text(report: dict[str, Any]) -> str:
    lines = [
        (
            "goal_loop_source_row_candidates: "
            f"status={report['status']} "
            f"result={report['result']} "
            f"rows={report['unique_candidate_rows']} "
            f"expected={report['expected_findings_total']} "
            f"missing={report['missing_candidate_rows']} "
            f"sources={len(report['prompt_sources_checked'])} "
            f"errors={report['source_errors_total']}"
        )
    ]
    for item in report["candidates_by_file"]:
        lines.append(f"FILE: {item['path']} rows={item['unique_candidate_rows']}")
    for error in report["source_errors"]:
        lines.append(f"ERROR: {error['path']} {error['error']}")
    return "\n".join(lines)


def positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be > 0")
    return parsed


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Inventory explicit row-like GOAL LOOP candidates in source Markdown. "
            "This does not synthesize a strict corpus and does not expand ranges."
        )
    )
    parser.add_argument("sources", nargs="+", help="Prompt source Markdown files.")
    parser.add_argument(
        "--source-catalog-id",
        default=DEFAULT_CATALOG_ID,
        help=f"Catalog id to bind the inventory to (default: {DEFAULT_CATALOG_ID}).",
    )
    parser.add_argument(
        "--expected-total",
        type=positive_int,
        default=DEFAULT_EXPECTED_TOTAL,
        help=f"Expected row count (default: {DEFAULT_EXPECTED_TOTAL}).",
    )
    parser.add_argument(
        "--source-prefix",
        default=DEFAULT_SOURCE_PREFIX,
        help=f"Logical source prefix (default: {DEFAULT_SOURCE_PREFIX}).",
    )
    parser.add_argument(
        "--summary-only",
        action="store_true",
        help="Omit candidate_rows from JSON output.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="text",
        help="Output format (default: text).",
    )
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="Exit non-zero unless the inventory has exactly the expected rows.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = inventory_sources(
        [Path(source) for source in args.sources],
        source_catalog_id=args.source_catalog_id,
        expected_total=args.expected_total,
        source_prefix=args.source_prefix,
        include_candidates=not args.summary_only,
    )
    if args.format == "json":
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(report_to_text(report))
    if args.require_complete and report["status"] != "COMPLETE":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
