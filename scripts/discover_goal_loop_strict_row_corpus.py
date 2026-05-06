#!/usr/bin/env python3
"""Discover candidate GOAL LOOP strict row corpus artifacts."""

from __future__ import annotations

import argparse
import json
import sys
import zipfile
from pathlib import Path
from typing import Any

from orient_goal_loop_logs import (
    load_audit_catalog_input,
    validate_strict_row_corpus,
)


DEFAULT_MARKERS = (
    "source_catalog_id",
    "corpus_id",
    "expected_findings_total",
    "strict_row",
    "strict-row",
    "goal-loop-206-audit-external-claim-2026-05-05",
)
TEXT_SUFFIXES = {
    ".css",
    ".csv",
    ".html",
    ".js",
    ".json",
    ".jsonl",
    ".md",
    ".ml",
    ".mli",
    ".py",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".yaml",
    ".yml",
}
ZIP_TEXT_SUFFIXES = TEXT_SUFFIXES | {".xml"}
ARCHIVE_SUFFIXES = {".docx", ".jar", ".ods", ".xlsx", ".zip"}


def iter_paths(roots: list[Path]) -> list[Path]:
    paths: list[Path] = []
    for root in roots:
        if root.is_dir():
            paths.extend(path for path in root.rglob("*") if path.is_file())
        elif root.is_file():
            paths.append(root)
    return sorted(paths)


def read_text_file(path: Path, max_bytes: int) -> str | None:
    try:
        with path.open("rb") as handle:
            data = handle.read(max_bytes + 1)
    except OSError:
        return None
    if len(data) > max_bytes:
        data = data[:max_bytes]
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("utf-8", errors="ignore")


def zip_member_texts(path: Path, max_bytes: int) -> list[tuple[str, str]]:
    texts: list[tuple[str, str]] = []
    try:
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if member.is_dir():
                    continue
                suffix = Path(member.filename).suffix.lower()
                if suffix not in ZIP_TEXT_SUFFIXES:
                    continue
                try:
                    with archive.open(member) as handle:
                        data = handle.read(max_bytes + 1)
                except (KeyError, RuntimeError, OSError, zipfile.BadZipFile):
                    continue
                if len(data) > max_bytes:
                    data = data[:max_bytes]
                text = data.decode("utf-8", errors="ignore")
                texts.append((member.filename, text))
    except (OSError, zipfile.BadZipFile):
        return []
    return texts


def marker_hits(text: str, markers: tuple[str, ...]) -> list[str]:
    return [marker for marker in markers if marker in text]


def maybe_json_object(text: str) -> dict[str, Any] | None:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def scan_text_unit(
    *,
    location: str,
    text: str,
    markers: tuple[str, ...],
    catalog: dict[str, Any] | None,
) -> dict[str, Any]:
    hits = marker_hits(text, markers)
    result: dict[str, Any] = {
        "location": location,
        "marker_hits": hits,
    }
    obj = maybe_json_object(text)
    if obj is None:
        return result
    findings = obj.get("findings")
    if not isinstance(findings, list):
        return result
    report = validate_strict_row_corpus(obj, catalog=catalog)
    result["candidate_corpus"] = {
        "row_count": report["row_count"],
        "expected_findings_total": report.get("expected_findings_total"),
        "source_catalog_id": report.get("source_catalog_id"),
        "validated": report["validated"],
        "errors": report["errors"],
    }
    return result


def discover(
    roots: list[Path],
    *,
    catalog: dict[str, Any] | None = None,
    markers: tuple[str, ...] = DEFAULT_MARKERS,
    max_bytes: int = 10_000_000,
) -> dict[str, Any]:
    files = iter_paths(roots)
    text_units_scanned = 0
    marker_matches: list[dict[str, Any]] = []
    candidate_corpora: list[dict[str, Any]] = []
    validated_corpora: list[dict[str, Any]] = []

    for path in files:
        suffix = path.suffix.lower()
        units: list[tuple[str, str]] = []
        if suffix in TEXT_SUFFIXES:
            text = read_text_file(path, max_bytes=max_bytes)
            if text is not None:
                units.append((str(path), text))
        elif suffix in ARCHIVE_SUFFIXES:
            units.extend(
                (f"{path}!/{member}", text)
                for member, text in zip_member_texts(path, max_bytes=max_bytes)
            )

        for location, text in units:
            text_units_scanned += 1
            scanned = scan_text_unit(
                location=location,
                text=text,
                markers=markers,
                catalog=catalog,
            )
            if scanned["marker_hits"]:
                marker_matches.append(
                    {
                        "location": location,
                        "markers": scanned["marker_hits"],
                    }
                )
            candidate = scanned.get("candidate_corpus")
            if isinstance(candidate, dict):
                candidate_with_location = {"location": location, **candidate}
                candidate_corpora.append(candidate_with_location)
                if candidate["validated"] is True:
                    validated_corpora.append(candidate_with_location)

    return {
        "roots": [str(root) for root in roots],
        "markers_checked": list(markers),
        "files_considered": len(files),
        "text_units_scanned": text_units_scanned,
        "marker_hits_total": len(marker_matches),
        "marker_matches": marker_matches,
        "candidate_corpora_total": len(candidate_corpora),
        "candidate_corpora": candidate_corpora,
        "validated_strict_corpora_total": len(validated_corpora),
        "validated_strict_corpora": validated_corpora,
    }


def report_to_text(report: dict[str, Any]) -> str:
    lines = [
        (
            "strict_row_corpus_discovery: "
            f"validated={report['validated_strict_corpora_total']} "
            f"candidates={report['candidate_corpora_total']} "
            f"marker_hits={report['marker_hits_total']} "
            f"text_units={report['text_units_scanned']} "
            f"files={report['files_considered']}"
        )
    ]
    for candidate in report["candidate_corpora"]:
        status = "VALID" if candidate["validated"] else "INVALID"
        lines.append(
            f"{status}: {candidate['location']} "
            f"rows={candidate['row_count']} "
            f"expected={candidate.get('expected_findings_total')} "
            f"errors={','.join(candidate['errors']) or '-'}"
        )
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Search files/directories for GOAL LOOP strict row corpus candidates. "
            "Discovery does not mark closeout complete; feed any valid result into "
            "orient_goal_loop_logs.py --strict-row-corpus."
        )
    )
    parser.add_argument("roots", nargs="+", help="Files or directories to scan.")
    parser.add_argument(
        "--audit-catalog",
        help="Optional audit catalog JSON used to validate candidate corpora.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="text",
        help="Output format (default: text).",
    )
    parser.add_argument(
        "--max-bytes",
        type=int,
        default=10_000_000,
        help="Maximum bytes to read per text unit (default: 10000000).",
    )
    parser.add_argument(
        "--require-found",
        action="store_true",
        help="Exit non-zero unless at least one valid strict corpus is found.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    catalog = load_audit_catalog_input(args.audit_catalog)
    report = discover(
        [Path(root) for root in args.roots],
        catalog=catalog,
        max_bytes=args.max_bytes,
    )
    if args.format == "json":
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(report_to_text(report))
    if args.require_found and report["validated_strict_corpora_total"] == 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
