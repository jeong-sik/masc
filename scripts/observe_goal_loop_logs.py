#!/usr/bin/env python3
"""Scan MASC logs for GOAL LOOP Observe failure signatures.

This is a lightweight bridge between raw production logs and the GOAL LOOP
Observe phase. It intentionally does not infer recovery or root cause; it only
counts concrete line-level signatures so operators can compare live evidence
with audit findings without hand-grepping logs.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, TextIO


@dataclass(frozen=True)
class PatternSpec:
    name: str
    regex: str
    severity: str
    description: str


@dataclass
class MatchSample:
    path: str
    line: int
    text: str


@dataclass
class PatternReport:
    count: int
    severity: str
    description: str
    samples: list[MatchSample]


@dataclass
class ScanReport:
    files: list[str]
    total_lines: int
    matched_lines: int
    patterns: dict[str, PatternReport]


PATTERNS: tuple[PatternSpec, ...] = (
    PatternSpec(
        "keeper_keepalive_only",
        r"keepalive turn scheduled",
        "warning",
        "Keepalive turn scheduled marker; line-level evidence only.",
    ),
    PatternSpec(
        "pricing_catalog_miss",
        r"pricing_catalog_miss model=",
        "critical",
        "Pricing catalog missed a model.",
    ),
    PatternSpec(
        "provider_health_skipped",
        r"status.*skipped.*bootstrap skips",
        "warning",
        "Provider health probe skipped as advisory during bootstrap.",
    ),
    PatternSpec(
        "credential_archived_starvation",
        r"archived credential.*starvation",
        "critical",
        "Keeper credential archived because of starvation recovery.",
    ),
    PatternSpec(
        "governance_unparseable",
        r"Governance judge returned unparseable",
        "warning",
        "Governance judge response was unparseable.",
    ),
    PatternSpec(
        "strict_json_parse_reject",
        r"strict JSON parse rejected",
        "warning",
        "Strict JSON parsing rejected an invalid judge response.",
    ),
    PatternSpec(
        "utf8_repair",
        r"persistence UTF-8 repaired",
        "critical",
        "Persistence layer repaired invalid UTF-8.",
    ),
    PatternSpec(
        "cas_retry",
        r"write_meta CAS retry",
        "warning",
        "Metadata write hit a CAS retry.",
    ),
    PatternSpec(
        "config_unknown_key",
        r"has unknown keys",
        "warning",
        "Configuration parser ignored unknown keys after warning.",
    ),
    PatternSpec(
        "autoboot_warmup",
        r"warmup=\s*\d+s",
        "warning",
        "Keeper autoboot warmup delay marker.",
    ),
    PatternSpec(
        "tool_policy_unknown_tools",
        r"(tool[_ -]?policy.*unknown tools|unknown tools.*tool[_ -]?policy)",
        "warning",
        "Tool policy reported unknown tools.",
    ),
    PatternSpec(
        "keeper_oas_checkpoint_sanitize_data_loss",
        r"(OAS checkpoint sanitize.*data loss|data loss.*OAS checkpoint sanitize)",
        "critical",
        "Keeper OAS checkpoint sanitize reported data loss.",
    ),
    PatternSpec(
        "metric_all_zero",
        r"ka=0ms.*audit=0ms.*profile=0ms",
        "warning",
        "Dashboard keeper sub-operation metrics are all zero.",
    ),
)


def iter_input_lines(paths: list[str]) -> Iterable[tuple[str, int, str]]:
    if not paths:
        yield from iter_handle("<stdin>", sys.stdin)
        return

    for raw_path in paths:
        if raw_path == "-":
            yield from iter_handle("<stdin>", sys.stdin)
            continue
        path = Path(raw_path)
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            yield from iter_handle(str(path), handle)


def iter_handle(path: str, handle: TextIO) -> Iterable[tuple[str, int, str]]:
    for line_no, line in enumerate(handle, start=1):
        yield path, line_no, line.rstrip("\n")


def scan_logs(paths: list[str], *, max_samples: int) -> ScanReport:
    compiled = [(spec, re.compile(spec.regex)) for spec in PATTERNS]
    reports = {
        spec.name: PatternReport(
            count=0,
            severity=spec.severity,
            description=spec.description,
            samples=[],
        )
        for spec in PATTERNS
    }
    files_seen: list[str] = []
    files_seen_set: set[str] = set()
    total_lines = 0
    matched_lines = 0

    for path, line_no, line in iter_input_lines(paths):
        total_lines += 1
        if path not in files_seen_set:
            files_seen.append(path)
            files_seen_set.add(path)

        line_matched = False
        for spec, regex in compiled:
            if not regex.search(line):
                continue
            report = reports[spec.name]
            report.count += 1
            line_matched = True
            if len(report.samples) < max_samples:
                report.samples.append(MatchSample(path=path, line=line_no, text=line))
        if line_matched:
            matched_lines += 1

    return ScanReport(
        files=files_seen,
        total_lines=total_lines,
        matched_lines=matched_lines,
        patterns=reports,
    )


def report_to_json(report: ScanReport) -> str:
    return json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True)


def report_to_text(report: ScanReport) -> str:
    lines = [
        "GOAL LOOP Observe Log Scan",
        f"files: {', '.join(report.files) if report.files else '<none>'}",
        f"total_lines: {report.total_lines}",
        f"matched_lines: {report.matched_lines}",
    ]
    for name in sorted(report.patterns):
        item = report.patterns[name]
        if item.count == 0:
            continue
        lines.append(f"- {name}: {item.count} ({item.severity})")
        for sample in item.samples:
            lines.append(f"  {sample.path}:{sample.line}: {sample.text}")
    return "\n".join(lines)


def should_fail(report: ScanReport, mode: str) -> bool:
    if mode == "none":
        return False
    for item in report.patterns.values():
        if item.count == 0:
            continue
        if mode == "any":
            return True
        if mode == "warning" and item.severity in {"warning", "critical"}:
            return True
        if mode == "critical" and item.severity == "critical":
            return True
    return False


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        help="Log files to scan. Use '-' or omit paths to read stdin.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format (default: json).",
    )
    parser.add_argument(
        "--max-samples",
        type=int,
        default=3,
        help="Maximum sample lines to retain per pattern (default: 3).",
    )
    parser.add_argument(
        "--fail-on",
        choices=("none", "critical", "warning", "any"),
        default="none",
        help="Exit non-zero when matching patterns meet this severity.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = scan_logs(args.paths, max_samples=max(args.max_samples, 0))
    if args.format == "json":
        print(report_to_json(report))
    else:
        print(report_to_text(report))
    return 1 if should_fail(report, args.fail_on) else 0


if __name__ == "__main__":
    raise SystemExit(main())
