#!/usr/bin/env python3
"""Derive a GOAL LOOP metric value from a timestamp-bounded log window."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, TextIO


def parse_timestamp(raw: str) -> datetime:
    parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def json_object(line: str) -> dict[str, Any] | None:
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def line_timestamp(line: str) -> datetime | None:
    data = json_object(line)
    if data is None:
        return None
    raw = data.get("ts")
    if not isinstance(raw, str):
        raw = data.get("timestamp")
    if not isinstance(raw, str):
        return None
    try:
        return parse_timestamp(raw)
    except ValueError:
        return None


def count_window_matches(
    handle: TextIO,
    *,
    pattern: re.Pattern[str],
    window_start: datetime,
    window_end: datetime,
) -> tuple[int, int, int]:
    total_lines = 0
    window_lines = 0
    matching_lines = 0
    for line in handle:
        total_lines += 1
        timestamp = line_timestamp(line)
        if timestamp is None or timestamp < window_start or timestamp >= window_end:
            continue
        window_lines += 1
        if pattern.search(line):
            matching_lines += 1
    return total_lines, window_lines, matching_lines


def build_metric_report(
    paths: list[str],
    *,
    metric_name: str,
    pattern: str,
    window_start: str,
    window_end: str,
    display_paths: list[str],
) -> dict[str, Any]:
    start = parse_timestamp(window_start)
    end = parse_timestamp(window_end)
    if end <= start:
        raise ValueError("window_end must be after window_start")

    regex = re.compile(pattern)
    total_lines = 0
    window_lines = 0
    matching_lines = 0
    for path in paths:
        with Path(path).open("r", encoding="utf-8", errors="replace") as handle:
            path_total, path_window, path_matching = count_window_matches(
                handle,
                pattern=regex,
                window_start=start,
                window_end=end,
            )
        total_lines += path_total
        window_lines += path_window
        matching_lines += path_matching

    redacted_paths = display_paths if display_paths else paths
    return {
        "schema_version": 1,
        "snapshot_kind": "goal_loop_log_window_metric",
        "metric_name": metric_name,
        "metrics": {metric_name: float(matching_lines)},
        "pattern": pattern,
        "checked_files": redacted_paths,
        "window_start": start.isoformat().replace("+00:00", "Z"),
        "window_end": end.isoformat().replace("+00:00", "Z"),
        "window_seconds": (end - start).total_seconds(),
        "total_lines": total_lines,
        "window_lines": window_lines,
        "matching_lines": matching_lines,
        "metric_value_semantics": (
            "matching log lines in the window; zero satisfies a zero-rate gate"
        ),
        "raw_log_lines_committed": False,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", help="JSONL log path(s) to scan.")
    parser.add_argument("--metric-name", required=True)
    parser.add_argument(
        "--pattern", required=True, help="Regex to count in the window."
    )
    parser.add_argument("--window-start", required=True)
    parser.add_argument("--window-end", required=True)
    parser.add_argument(
        "--display-path",
        action="append",
        default=[],
        help="Redacted path to record in output. Repeat to match multiple logs.",
    )
    parser.add_argument("--pretty", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = build_metric_report(
        list(args.logs),
        metric_name=args.metric_name,
        pattern=args.pattern,
        window_start=args.window_start,
        window_end=args.window_end,
        display_paths=list(args.display_path),
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
