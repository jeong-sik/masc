#!/usr/bin/env python3
"""Measure where tool calls spend time and context in the tool-call ledger.

Reads the day files under `<base-path>/.masc/tool_calls/YYYY-MM/` (the live
`DD.jsonl` and its rotated `DD.NNN.jsonl` segments) for a range of UTC days and
reports five measurements. Each one names a cost a Keeper pays without getting
new information back:

- identical re-reads: a call whose tool, input and result bytes equal an earlier
  call by the same Keeper inside the window. The result carried nothing new.
- spilled results: results stored as a blob reference. The model reads them
  back with keeper_artifact_read, one page per call.
- blocked waits: Execute calls whose command text sleeps, polls or watches.
  The turn waits for the process to exit. Text matching is a reporting
  heuristic here; no runtime decision reads it.
- empty-input failures: calls with no arguments that the runtime rejected.
- same-tool bursts: one turn that calls one tool many times.

It also writes hourly and daily series so a chart can show the same numbers
over time. `--json-out` keeps the full result for a before/after comparison:
run it on a window before a change and a window after, then diff the two files.

The identical re-read window is a measurement parameter, not a runtime limit.
Nothing in the product reads it.

Usage:
    scripts/measure-tool-efficiency.py --base-path /srv/masc --from-date 2026-11-01 --to-date 2026-11-05
    MASC_BASE_PATH=/srv/masc scripts/measure-tool-efficiency.py --from-date 2026-11-01 --to-date 2026-11-05 --json-out artifacts/tool-efficiency/after.json
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))

import masc_base_path  # noqa: E402
from recorded_tool_outcome import RecordedCallOutcome, recorded_call_outcome  # noqa: E402

ARTIFACT_READ_TOOL = "keeper_artifact_read"
EXECUTE_TOOL = "Execute"
TOOL_CALL_RECORD_KIND = "tool_call"
BLOB_KEY = "_blob"
SECONDS_PER_HOUR = 3600
DEFAULT_REREAD_WINDOW_SEC = SECONDS_PER_HOUR
DEFAULT_TOP = 12

# A command that sleeps for a number of seconds, polls in a loop, or watches.
# The match only labels a call in this report.
WAIT_COMMAND = re.compile(
    r"\bsleep\s+[0-9]"
    r"|\buntil\b"
    r"|\bwhile\s+(?:true|:|\[)"
    r"|\bgh\s+run\s+watch\b"
    r"|--watch\b"
    r"|\btail\s+-f\b"
)

JsonObject = dict[str, object]


def as_object(value: object) -> JsonObject | None:
    return cast(JsonObject, value) if isinstance(value, dict) else None


def as_text(value: object) -> str | None:
    return value if isinstance(value, str) else None


def as_number(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    return float(value) if isinstance(value, (int, float)) else None


def is_blob_reference(output: object) -> bool:
    if isinstance(output, dict):
        return BLOB_KEY in output
    return isinstance(output, str) and output.startswith('{"' + BLOB_KEY + '"')


def is_empty_input(value: object) -> bool:
    return value is None or (isinstance(value, dict) and len(value) == 0)


def command_text(value: object) -> str | None:
    """The shell text of an Execute input: its `command`, or its joined `argv`."""
    fields = as_object(value)
    if fields is None:
        return None
    command = as_text(fields.get("command"))
    if command is not None:
        return command
    argv = fields.get("argv")
    if isinstance(argv, list):
        return " ".join(str(part) for part in cast(list[object], argv))
    return None


def percentile(sorted_values: list[float], fraction: float) -> float | None:
    if not sorted_values:
        return None
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * fraction))]


@dataclass(slots=True)
class ToolTotals:
    calls: int = 0
    failed: int = 0
    duration_ms: list[float] = field(default_factory=lambda: cast(list[float], []))
    result_bytes: list[float] = field(default_factory=lambda: cast(list[float], []))
    reread_calls: int = 0
    reread_bytes: int = 0
    spilled_calls: int = 0
    spilled_bytes: int = 0


@dataclass(slots=True)
class Bucket:
    calls: int = 0
    failed: int = 0
    duration_ms: float = 0.0
    result_bytes: int = 0
    spilled_bytes: int = 0
    reread_bytes: int = 0
    wait_ms: float = 0.0


@dataclass(slots=True)
class Burst:
    calls: int = 0
    first_ts: float | None = None
    last_ts: float | None = None
    result_bytes: int = 0

    def observe(self, ts: float | None, size: int) -> None:
        self.calls += 1
        self.result_bytes += size
        if ts is not None:
            self.first_ts = ts if self.first_ts is None else min(self.first_ts, ts)
            self.last_ts = ts if self.last_ts is None else max(self.last_ts, ts)

    def absorb(self, other: Burst) -> None:
        self.calls += other.calls
        self.result_bytes += other.result_bytes
        for ts in (other.first_ts, other.last_ts):
            if ts is not None:
                self.first_ts = ts if self.first_ts is None else min(self.first_ts, ts)
                self.last_ts = ts if self.last_ts is None else max(self.last_ts, ts)

    def span_s(self) -> float:
        if self.first_ts is None or self.last_ts is None:
            return 0.0
        return round(self.last_ts - self.first_ts, 1)


@dataclass(slots=True)
class DayTotals:
    rows: int = 0
    tools: dict[str, ToolTotals] = field(default_factory=lambda: cast(dict[str, ToolTotals], {}))
    hourly: dict[str, Bucket] = field(default_factory=lambda: cast(dict[str, Bucket], {}))
    outcomes: Counter[str] = field(default_factory=lambda: cast(Counter[str], Counter()))
    reread_same_turn: int = 0
    reread_later_turn: int = 0
    wait_calls: int = 0
    wait_ms: float = 0.0
    execute_calls: int = 0
    execute_ms: float = 0.0
    empty_failed_by_profile: Counter[str] = field(default_factory=lambda: cast(Counter[str], Counter()))
    empty_failed_by_tool: Counter[str] = field(default_factory=lambda: cast(Counter[str], Counter()))
    calls_by_profile: Counter[str] = field(default_factory=lambda: cast(Counter[str], Counter()))
    artifact_pages_by_sha: Counter[str] = field(default_factory=lambda: cast(Counter[str], Counter()))
    bursts: dict[tuple[str, str, str], Burst] = field(
        default_factory=lambda: cast(dict[tuple[str, str, str], Burst], {})
    )


def ledger_files(base: pathlib.Path, day: date) -> list[pathlib.Path]:
    """The day's rotated segments in order, then its live tail."""
    directory = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}"
    stem = f"{day.day:02d}"
    segments: list[tuple[int, pathlib.Path]] = []
    for candidate in directory.glob(f"{stem}.*.jsonl"):
        match = re.fullmatch(rf"{stem}\.([0-9]+)\.jsonl", candidate.name)
        if match is not None and candidate.is_file() and not candidate.is_symlink():
            segments.append((int(match[1]), candidate))
    paths = [path for _, path in sorted(segments)]
    live = directory / f"{stem}.jsonl"
    if live.is_file() and not live.is_symlink():
        paths.append(live)
    return paths


def measure_day(base: pathlib.Path, day: date, reread_window_sec: float) -> DayTotals:
    totals = DayTotals()
    last_seen: dict[tuple[str, str, str], tuple[float, str, str]] = {}
    for path in ledger_files(base, day):
        with path.open("rb") as handle:
            for line in handle:
                try:
                    parsed: object = json.loads(line)
                except json.JSONDecodeError:
                    continue
                row = as_object(parsed)
                if row is None or row.get("record_kind") != TOOL_CALL_RECORD_KIND:
                    continue
                observe_row(totals, row, last_seen, reread_window_sec)
    return totals


def observe_row(
    totals: DayTotals,
    row: JsonObject,
    last_seen: dict[tuple[str, str, str], tuple[float, str, str]],
    reread_window_sec: float,
) -> None:
    tool = as_text(row.get("tool")) or "?"
    keeper = as_text(row.get("keeper")) or "?"
    profile = as_text(row.get("runtime_profile")) or "unrecorded"
    turn = f"{as_text(row.get('trace_id')) or '?'}#{row.get('keeper_turn_id')}"
    ts = as_number(row.get("ts"))
    duration = as_number(row.get("duration_ms")) or 0.0
    size = int(as_number(row.get("result_bytes")) or 0)
    outcome = recorded_call_outcome(row)
    failed = outcome is RecordedCallOutcome.FAILED

    totals.rows += 1
    totals.outcomes[outcome.value] += 1
    totals.calls_by_profile[profile] += 1
    stat = totals.tools.setdefault(tool, ToolTotals())
    stat.calls += 1
    stat.duration_ms.append(duration)
    stat.result_bytes.append(float(size))
    if failed:
        stat.failed += 1

    spilled = is_blob_reference(row.get("output"))
    if spilled:
        stat.spilled_calls += 1
        stat.spilled_bytes += size

    bucket = None
    if ts is not None:
        hour = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H")
        bucket = totals.hourly.setdefault(hour, Bucket())
        bucket.calls += 1
        bucket.duration_ms += duration
        bucket.result_bytes += size
        if failed:
            bucket.failed += 1
        if spilled:
            bucket.spilled_bytes += size

    observe_reread(totals, stat, bucket, row, tool, keeper, turn, ts, size, last_seen, reread_window_sec)
    if failed and is_empty_input(row.get("input")):
        totals.empty_failed_by_profile[profile] += 1
        totals.empty_failed_by_tool[tool] += 1

    if tool == ARTIFACT_READ_TOOL:
        sha = as_text((as_object(row.get("input")) or {}).get("sha256"))
        if sha is not None:
            totals.artifact_pages_by_sha[sha] += 1
    if tool == EXECUTE_TOOL:
        totals.execute_calls += 1
        totals.execute_ms += duration
        text = command_text(row.get("input"))
        if text is not None and WAIT_COMMAND.search(text) is not None:
            totals.wait_calls += 1
            totals.wait_ms += duration
            if bucket is not None:
                bucket.wait_ms += duration

    totals.bursts.setdefault((tool, keeper, turn), Burst()).observe(ts, size)


def observe_reread(
    totals: DayTotals,
    stat: ToolTotals,
    bucket: Bucket | None,
    row: JsonObject,
    tool: str,
    keeper: str,
    turn: str,
    ts: float | None,
    size: int,
    last_seen: dict[tuple[str, str, str], tuple[float, str, str]],
    reread_window_sec: float,
) -> None:
    input_fp = as_text(row.get("input_fingerprint"))
    output_fp = as_text(row.get("output_fingerprint"))
    if input_fp is None or output_fp is None or ts is None:
        return
    key = (keeper, tool, input_fp)
    previous = last_seen.get(key)
    if previous is not None and previous[1] == output_fp and ts - previous[0] <= reread_window_sec:
        stat.reread_calls += 1
        stat.reread_bytes += size
        if previous[2] == turn:
            totals.reread_same_turn += 1
        else:
            totals.reread_later_turn += 1
        if bucket is not None:
            bucket.reread_bytes += size
    last_seen[key] = (ts, output_fp, turn)


def merge(parts: list[DayTotals]) -> DayTotals:
    merged = DayTotals()
    for part in parts:
        merged.rows += part.rows
        merged.outcomes.update(part.outcomes)
        merged.reread_same_turn += part.reread_same_turn
        merged.reread_later_turn += part.reread_later_turn
        merged.wait_calls += part.wait_calls
        merged.wait_ms += part.wait_ms
        merged.execute_calls += part.execute_calls
        merged.execute_ms += part.execute_ms
        merged.empty_failed_by_profile.update(part.empty_failed_by_profile)
        merged.empty_failed_by_tool.update(part.empty_failed_by_tool)
        merged.calls_by_profile.update(part.calls_by_profile)
        merged.artifact_pages_by_sha.update(part.artifact_pages_by_sha)
        for tool, stat in part.tools.items():
            into = merged.tools.setdefault(tool, ToolTotals())
            into.calls += stat.calls
            into.failed += stat.failed
            into.duration_ms.extend(stat.duration_ms)
            into.result_bytes.extend(stat.result_bytes)
            into.reread_calls += stat.reread_calls
            into.reread_bytes += stat.reread_bytes
            into.spilled_calls += stat.spilled_calls
            into.spilled_bytes += stat.spilled_bytes
        for hour, bucket in part.hourly.items():
            into_bucket = merged.hourly.setdefault(hour, Bucket())
            into_bucket.calls += bucket.calls
            into_bucket.failed += bucket.failed
            into_bucket.duration_ms += bucket.duration_ms
            into_bucket.result_bytes += bucket.result_bytes
            into_bucket.spilled_bytes += bucket.spilled_bytes
            into_bucket.reread_bytes += bucket.reread_bytes
            into_bucket.wait_ms += bucket.wait_ms
        for key, burst in part.bursts.items():
            merged.bursts.setdefault(key, Burst()).absorb(burst)
    return merged


def days_between(first: date, last: date) -> list[date]:
    return [first + timedelta(days=offset) for offset in range((last - first).days + 1)]


def measure_range(base: pathlib.Path, first: date, last: date, reread_window_sec: float, jobs: int) -> DayTotals:
    days = days_between(first, last)
    if jobs <= 1:
        return merge([measure_day(base, day, reread_window_sec) for day in days])
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(measure_day, base, day, reread_window_sec) for day in days]
        return merge([future.result() for future in futures])


def share(part: float, whole: float) -> float:
    return 100.0 * part / whole if whole else 0.0


def summarize(totals: DayTotals, top: int) -> JsonObject:
    tool_rows: list[JsonObject] = []
    for name, stat in totals.tools.items():
        durations = sorted(stat.duration_ms)
        sizes = sorted(stat.result_bytes)
        tool_rows.append(
            {
                "tool": name,
                "calls": stat.calls,
                "failed": stat.failed,
                "time_s": round(sum(durations) / 1000, 1),
                "p50_ms": percentile(durations, 0.5),
                "p99_ms": percentile(durations, 0.99),
                "result_bytes": int(sum(sizes)),
                "p99_result_bytes": percentile(sizes, 0.99),
                "reread_calls": stat.reread_calls,
                "reread_bytes": stat.reread_bytes,
                "spilled_calls": stat.spilled_calls,
                "spilled_bytes": stat.spilled_bytes,
            }
        )
    tool_rows.sort(key=lambda item: -cast(float, item["time_s"]))
    total_bytes = sum(int(cast(int, item["result_bytes"])) for item in tool_rows)
    total_ms = sum(sum(stat.duration_ms) for stat in totals.tools.values())
    reread_bytes = sum(stat.reread_bytes for stat in totals.tools.values())
    reread_calls = sum(stat.reread_calls for stat in totals.tools.values())
    spilled_bytes = sum(stat.spilled_bytes for stat in totals.tools.values())
    spilled_calls = sum(stat.spilled_calls for stat in totals.tools.values())
    read_back = totals.tools.get(ARTIFACT_READ_TOOL, ToolTotals())
    bursts = sorted(totals.bursts.items(), key=lambda item: -item[1].calls)[:top]
    daily: dict[str, Bucket] = {}
    for hour, bucket in totals.hourly.items():
        into = daily.setdefault(hour[:10], Bucket())
        into.calls += bucket.calls
        into.failed += bucket.failed
        into.duration_ms += bucket.duration_ms
        into.result_bytes += bucket.result_bytes
        into.spilled_bytes += bucket.spilled_bytes
        into.reread_bytes += bucket.reread_bytes
        into.wait_ms += bucket.wait_ms
    return {
        "rows": totals.rows,
        "outcomes": dict(totals.outcomes),
        "tool_time_s": round(total_ms / 1000, 1),
        "result_bytes": total_bytes,
        "identical_rereads": {
            "calls": reread_calls,
            "calls_pct": round(share(reread_calls, totals.rows), 2),
            "bytes": reread_bytes,
            "bytes_pct": round(share(reread_bytes, total_bytes), 2),
            "same_turn": totals.reread_same_turn,
            "later_turn": totals.reread_later_turn,
        },
        "spilled_results": {
            "calls": spilled_calls,
            "bytes": spilled_bytes,
            "bytes_pct": round(share(spilled_bytes, total_bytes), 2),
            "read_back_calls": read_back.calls,
            "read_back_bytes": int(sum(read_back.result_bytes)),
            "distinct_artifacts_read": len(totals.artifact_pages_by_sha),
            "most_paged_artifacts": totals.artifact_pages_by_sha.most_common(3),
        },
        "blocked_waits": {
            "execute_calls": totals.execute_calls,
            "execute_time_s": round(totals.execute_ms / 1000, 1),
            "wait_calls": totals.wait_calls,
            "wait_time_s": round(totals.wait_ms / 1000, 1),
            "wait_time_pct_of_execute": round(share(totals.wait_ms, totals.execute_ms), 2),
        },
        "empty_input_failures": {
            "total": sum(totals.empty_failed_by_profile.values()),
            "by_profile": [
                {
                    "profile": profile,
                    "failed": count,
                    "calls": totals.calls_by_profile[profile],
                    "rate_pct": round(share(count, totals.calls_by_profile[profile]), 2),
                }
                for profile, count in totals.empty_failed_by_profile.most_common(top)
            ],
            "by_tool": totals.empty_failed_by_tool.most_common(top),
        },
        "same_tool_bursts": [
            {
                "tool": key[0],
                "keeper": key[1],
                "turn": key[2],
                "calls": burst.calls,
                "span_s": burst.span_s(),
                "result_bytes": burst.result_bytes,
            }
            for key, burst in bursts
        ],
        "tools": tool_rows,
        "daily": {day: bucket_json(bucket) for day, bucket in sorted(daily.items())},
        "hourly": {hour: bucket_json(bucket) for hour, bucket in sorted(totals.hourly.items())},
    }


def bucket_json(bucket: Bucket) -> JsonObject:
    return {
        "calls": bucket.calls,
        "failed": bucket.failed,
        "time_s": round(bucket.duration_ms / 1000, 1),
        "result_bytes": bucket.result_bytes,
        "spilled_bytes": bucket.spilled_bytes,
        "reread_bytes": bucket.reread_bytes,
        "wait_s": round(bucket.wait_ms / 1000, 1),
    }


BYTES_PER_MEGABYTE = 1_000_000


def megabytes(value: object) -> str:
    return f"{(as_number(value) or 0.0) / BYTES_PER_MEGABYTE:.1f}"


def render(summary: JsonObject, first: date, last: date, top: int) -> str:
    rereads = cast(JsonObject, summary["identical_rereads"])
    spilled = cast(JsonObject, summary["spilled_results"])
    waits = cast(JsonObject, summary["blocked_waits"])
    empty = cast(JsonObject, summary["empty_input_failures"])
    lines = [
        f"# Tool efficiency {first} .. {last} (UTC days)",
        "",
        f"- tool calls: {summary['rows']}, recorded tool time: {summary['tool_time_s']} s, "
        f"result bytes: {megabytes(summary['result_bytes'])} MB",
        f"- outcomes: {summary['outcomes']}",
        f"- identical re-reads: {rereads['calls']} calls ({rereads['calls_pct']}%), "
        f"{megabytes(rereads['bytes'])} MB ({rereads['bytes_pct']}% of result bytes); "
        f"same turn {rereads['same_turn']}, later turn {rereads['later_turn']}",
        f"- spilled results: {spilled['calls']} calls, {megabytes(spilled['bytes'])} MB "
        f"({spilled['bytes_pct']}% of result bytes); read back by {ARTIFACT_READ_TOOL}: "
        f"{spilled['read_back_calls']} calls, {megabytes(spilled['read_back_bytes'])} MB, "
        f"{spilled['distinct_artifacts_read']} artifacts",
        f"- Execute blocked waits: {waits['wait_calls']} of {waits['execute_calls']} calls, "
        f"{waits['wait_time_s']} s of {waits['execute_time_s']} s ({waits['wait_time_pct_of_execute']}%)",
        f"- empty-input failures: {empty['total']}",
        "",
        "## Tools by recorded time",
        "",
        "| tool | calls | failed | time s | p50 ms | p99 ms | MB | re-read MB | spilled MB |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for item in cast(list[JsonObject], summary["tools"])[:top]:
        lines.append(
            f"| {item['tool']} | {item['calls']} | {item['failed']} | "
            f"{item['time_s']} | {item['p50_ms'] and round(cast(float, item['p50_ms']))} | "
            f"{item['p99_ms'] and round(cast(float, item['p99_ms']))} | {megabytes(item['result_bytes'])} | "
            f"{megabytes(item['reread_bytes'])} | {megabytes(item['spilled_bytes'])} |"
        )
    lines += ["", "## Empty-input failures by runtime profile", ""]
    for item in cast(list[JsonObject], empty["by_profile"]):
        lines.append(f"- {item['profile']}: {item['failed']} of {item['calls']} calls ({item['rate_pct']}%)")
    lines += ["", "## Same-tool bursts inside one turn", ""]
    for item in cast(list[JsonObject], summary["same_tool_bursts"]):
        lines.append(
            f"- {item['tool']} by {item['keeper']}: {item['calls']} calls over {item['span_s']} s, "
            f"{megabytes(item['result_bytes'])} MB ({item['turn']})"
        )
    return "\n".join(lines) + "\n"


def parse_day(raw: str) -> date:
    try:
        return date.fromisoformat(raw)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{raw!r} is not a YYYY-MM-DD day") from error


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", default=None, help="directory that contains .masc; MASC_BASE_PATH when omitted")
    parser.add_argument("--from-date", type=parse_day, required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--to-date", type=parse_day, required=True, help="last UTC day, YYYY-MM-DD")
    parser.add_argument(
        "--reread-window-sec",
        type=float,
        default=DEFAULT_REREAD_WINDOW_SEC,
        help="how far back an equal call counts as an identical re-read",
    )
    parser.add_argument("--top", type=int, default=DEFAULT_TOP, help="rows per table")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1, help="worker processes, one day each")
    parser.add_argument("--json-out", default=None, help="write the full summary to this file")
    args = parser.parse_args(argv)
    if args.to_date < args.from_date:
        parser.error("--to-date is before --from-date")
    base = masc_base_path.require(parser, args.base_path, "--base-path")
    totals = measure_range(base, args.from_date, args.to_date, args.reread_window_sec, args.jobs)
    summary = summarize(totals, args.top)
    if args.json_out is not None:
        destination = pathlib.Path(args.json_out)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    sys.stdout.write(render(summary, args.from_date, args.to_date, args.top))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
