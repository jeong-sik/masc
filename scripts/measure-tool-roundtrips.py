#!/usr/bin/env python3
"""Measure wasted tool round-trips in keeper tool-call logs.

Reads one day of `<base-path>/tool_calls/YYYY-MM/DD.jsonl` and reports, per
turn (keeper, keeper_turn_id, trace_id), how many round-trips were spent on
consecutive calls to the same tool, classified by why the repeat happened:

- fanout     — same argument shape, different values. Independent lookups sent
               one at a time; the batch executor (agent_tool_batch_plan) would
               run them concurrently if they arrived in one response.
- duplicate  — byte-identical (tool, args) repeated back to back.
- probing    — the argument key set changed between consecutive calls; the
               model is feeling for a shape the schema/error did not teach.

Two focused sub-measurements drive specific fixes:

- unchanged-recall pairs: back-to-back identical (tool, args) calls whose
  first response carried `"kind":"unchanged"`. These measure the
  keeper_tasks_list self-contradiction (row stats on a row-less response);
  the fix removes matching_count/returned_count/truncated from unchanged
  responses, so this count is expected to approach zero after deploy.
- probe pairs whose first call failed: errors that did not teach the model
  the corrective argument (e.g. enum violations rendered as "wrong type").

Falsification: if after deploying the unchanged fix this script still reports
a comparable unchanged-recall pair count over a full day, the
self-contradiction diagnosis was wrong (or another producer emits the same
shape) — re-open the investigation instead of stacking mitigations.

The classifier only groups calls inside one turn; cross-turn repeats are a
different behaviour (memory, not batching) and are deliberately out of scope.

Method-multiplexed tools (a single tool name whose `input.method` string
selects the operation, e.g. the github connector's pull-request reader) are
split into sub-tools for classification: consecutive calls that switch method
are different operations, not the model probing for an argument shape. Their
batching opportunity is visible in the batch_size distribution, not in the
same-tool run classes.

Artifact paging: keeper_artifact_read calls are additionally grouped by
(keeper, sha256) to measure page arithmetic — a blob whose total_bytes fits
one 65536-byte page should cost one call. `excess calls` counts calls beyond
ceil(total_bytes / page) per blob; `small explicit slices` counts calls that
lowered max_bytes below the default.

Every class is also split by keeper. The first post-deploy window (r2,
2026-09-02) showed the artifact excess was two keepers' behaviour — one
probing large artifacts in 650-byte slices as a search substitute, one
misreading a whole first page as a nested blob — while a third keeper on the
same lane read every blob in one call. A tool-level number cannot tell those
apart; the keeper tables can.

Usage:
    scripts/measure-tool-roundtrips.py --date 2026-09-01
    MASC_BASE_PATH=/srv/masc scripts/measure-tool-roundtrips.py --date 2026-09-01 --top 10
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import pathlib
import sys

DEFAULT_BASE = pathlib.Path(os.environ.get("MASC_BASE_PATH", pathlib.Path.home() / "me"))

# Mirrors Common.max_tool_output_bytes, the artifact_read page bound (both the
# max_bytes default/maximum and the response-envelope budget).
ARTIFACT_PAGE_BYTES = 65_536

ARTIFACT_READ_TOOL = "keeper_artifact_read"


def run_key(row: dict) -> str:
    """Classification identity of a call: the tool name, plus `input.method`
    for method-multiplexed tools so a method switch is not read as probing."""
    tool = row.get("tool") or "?"
    value = row.get("input")
    if isinstance(value, dict):
        method = value.get("method")
        if isinstance(method, str) and method:
            return f"{tool}:{method}"
    return tool


def normalized_args(value: object) -> str:
    if value is None:
        return ""
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


def key_set(value: object) -> frozenset[str]:
    if isinstance(value, dict):
        return frozenset(value.keys())
    return frozenset()


def parse_output_kind(output: object) -> str | None:
    """Return the `kind` field of a tool output when it parses as JSON."""
    if isinstance(output, dict):
        kind = output.get("kind")
        return kind if isinstance(kind, str) else None
    if isinstance(output, str):
        try:
            parsed = json.loads(output)
        except ValueError:
            return None
        if isinstance(parsed, dict):
            kind = parsed.get("kind")
            return kind if isinstance(kind, str) else None
    return None


def load_rows(path: pathlib.Path) -> list[dict]:
    rows: list[dict] = []
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("record_kind") == "tool_call":
                rows.append(row)
    rows.sort(key=lambda row: float(row.get("ts", 0.0)))
    return rows


def group_turns(rows: list[dict]) -> dict[tuple, list[dict]]:
    turns: dict[tuple, list[dict]] = collections.defaultdict(list)
    for row in rows:
        key = (row.get("keeper"), row.get("keeper_turn_id"), row.get("trace_id"))
        turns[key].append(row)
    return turns


def classify_runs(turns: dict[tuple, list[dict]]):
    """Classify each same-tool consecutive run inside a turn.

    A run of length L costs L-1 avoidable round-trips relative to sending the
    calls in one response (fanout/duplicate) or getting a teaching error
    (probing).
    """
    saved = collections.Counter()
    by_tool: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    by_keeper: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for (keeper, _turn_id, _trace_id), calls in turns.items():
        index = 0
        while index < len(calls):
            end = index
            while end + 1 < len(calls) and run_key(calls[end + 1]) == run_key(calls[index]):
                end += 1
            length = end - index + 1
            if length > 1:
                args = [calls[position].get("input") for position in range(index, end + 1)]
                serialized = [normalized_args(value) for value in args]
                tool = run_key(calls[index])
                if len(set(serialized)) == 1:
                    label = "duplicate"
                elif len({key_set(value) for value in args}) > 1:
                    label = "probing"
                else:
                    label = "fanout"
                saved[label] += length - 1
                by_tool[label][tool] += length - 1
                by_keeper[str(keeper)][tool] += length - 1
            index = end + 1
    return saved, by_tool, by_keeper


def unchanged_recall_pairs(turns: dict[tuple, list[dict]]) -> collections.Counter:
    """Back-to-back identical (tool, args) pairs whose first output was `unchanged`."""
    pairs = collections.Counter()
    for calls in turns.values():
        for first, second in zip(calls, calls[1:]):
            if run_key(first) != run_key(second):
                continue
            if normalized_args(first.get("input")) != normalized_args(second.get("input")):
                continue
            if parse_output_kind(first.get("output")) == "unchanged":
                pairs[run_key(first)] += 1
    return pairs


def probe_pairs(turns: dict[tuple, list[dict]]) -> tuple[int, int]:
    """Consecutive same-tool pairs whose argument key set changed.

    Returns (pair_count, pairs_whose_first_call_failed).
    """
    total = 0
    first_failed = 0
    for calls in turns.values():
        for first, second in zip(calls, calls[1:]):
            if run_key(first) != run_key(second):
                continue
            if key_set(first.get("input")) == key_set(second.get("input")):
                continue
            total += 1
            if first.get("success") is False:
                first_failed += 1
    return total, first_failed


def parse_output_object(output: object) -> dict | None:
    if isinstance(output, dict):
        return output
    if isinstance(output, str):
        try:
            parsed = json.loads(output)
        except ValueError:
            return None
        if isinstance(parsed, dict):
            return parsed
    return None


def artifact_paging(rows: list[dict]) -> tuple[dict[str, int], list[tuple[str, dict[str, int]]]]:
    """Per-blob call arithmetic for keeper_artifact_read.

    Groups calls by (keeper, sha256). A blob whose total_bytes fits one page
    should cost one call; anything beyond ceil(total_bytes / page) is excess.
    total_bytes and encoding come from the blob's first parseable response.

    The page arithmetic assumes one source byte per response byte. That holds
    for utf-8 pages; a base64 page carries fewer source bytes than its size,
    so ceil(total_bytes / page) undercounts the calls such a blob needs and
    would report legitimate reads as excess. Blobs whose first page names a
    non-utf-8 encoding are therefore counted but not judged. The tool writes
    the field on every page (keeper_artifact_read.ml, page_to_json); a blob
    whose logged output carries total_bytes but no encoding is judged as
    utf-8, which is the only way the arithmetic ever applied before.

    Returns the fleet summary and the same counters per keeper, ordered by
    excess calls descending so the keepers that own the waste come first.
    """
    per_blob: dict[tuple[str, str], dict[str, object]] = {}
    small_slices = 0
    small_slices_by_keeper: collections.Counter = collections.Counter()
    for row in rows:
        if row.get("tool") != ARTIFACT_READ_TOOL:
            continue
        value = row.get("input")
        if not isinstance(value, dict):
            continue
        sha = value.get("sha256")
        if not isinstance(sha, str):
            continue
        keeper = str(row.get("keeper"))
        max_bytes = value.get("max_bytes")
        if isinstance(max_bytes, int) and max_bytes < ARTIFACT_PAGE_BYTES:
            small_slices += 1
            small_slices_by_keeper[keeper] += 1
        entry = per_blob.setdefault(
            (keeper, sha), {"calls": 0, "total_bytes": None, "encoding": None}
        )
        entry["calls"] = int(entry["calls"]) + 1  # type: ignore[arg-type]
        if entry["total_bytes"] is None:
            parsed = parse_output_object(row.get("output"))
            if parsed is not None and isinstance(parsed.get("total_bytes"), int):
                entry["total_bytes"] = parsed["total_bytes"]
                encoding = parsed.get("encoding")
                entry["encoding"] = encoding if isinstance(encoding, str) else None

    def summarize(entries: list[dict[str, object]], small: int) -> dict[str, int]:
        calls_per_blob = [int(entry["calls"]) for entry in entries]  # type: ignore[arg-type]
        excess = 0
        sized_blobs = 0
        non_utf8_blobs = 0
        for entry in entries:
            total_bytes = entry["total_bytes"]
            if not isinstance(total_bytes, int):
                continue
            encoding = entry["encoding"]
            if encoding is not None and encoding != "utf-8":
                non_utf8_blobs += 1
                continue
            sized_blobs += 1
            minimal = max(1, -(-total_bytes // ARTIFACT_PAGE_BYTES))
            blob_calls = int(entry["calls"])  # type: ignore[arg-type]
            if blob_calls > minimal:
                excess += blob_calls - minimal
        return {
            "blobs": len(entries),
            "calls": sum(calls_per_blob),
            "one_call_blobs": sum(1 for count in calls_per_blob if count == 1),
            "max_calls": max(calls_per_blob, default=0),
            "excess_calls": excess,
            "sized_blobs": sized_blobs,
            "non_utf8_blobs": non_utf8_blobs,
            "small_slices": small,
        }

    entries_by_keeper: dict[str, list[dict[str, object]]] = collections.defaultdict(list)
    for (keeper, _sha), entry in per_blob.items():
        entries_by_keeper[keeper].append(entry)
    by_keeper = [
        (keeper, summarize(entries, small_slices_by_keeper[keeper]))
        for keeper, entries in entries_by_keeper.items()
    ]
    by_keeper.sort(key=lambda item: (-item[1]["excess_calls"], -item[1]["calls"], item[0]))
    return summarize(list(per_blob.values()), small_slices), by_keeper


def batch_size_histogram(rows: list[dict]) -> collections.Counter:
    histogram = collections.Counter()
    for row in rows:
        histogram[int(row.get("batch_size", 1))] += 1
    return histogram


def render(rows: list[dict], top: int) -> str:
    turns = group_turns(rows)
    saved, by_tool, by_keeper = classify_runs(turns)
    unchanged = unchanged_recall_pairs(turns)
    probes, probes_first_failed = probe_pairs(turns)
    batches = batch_size_histogram(rows)

    total_saved = sum(saved.values())
    total_calls = len(rows)
    single = batches.get(1, 0)

    lines: list[str] = []
    lines.append("# Tool round-trip waste")
    lines.append("")
    lines.append(f"- tool_call rows: {total_calls}")
    lines.append(f"- turns: {len(turns)}")
    share = (100.0 * total_saved / total_calls) if total_calls else 0.0
    lines.append(f"- avoidable round-trips (same-tool runs): {total_saved} ({share:.1f}% of calls)")
    lines.append("")
    lines.append("## Classification")
    lines.append("")
    lines.append("| class | avoidable round-trips | top tools |")
    lines.append("|---|---:|---|")
    for label in ("fanout", "duplicate", "probing"):
        tops = ", ".join(f"{tool} {count}" for tool, count in by_tool[label].most_common(3))
        lines.append(f"| {label} | {saved[label]} | {tops} |")
    lines.append("")
    lines.append("### by keeper")
    lines.append("")
    lines.append("| keeper | avoidable round-trips | top tools |")
    lines.append("|---|---:|---|")
    keeper_totals = sorted(
        ((sum(counter.values()), keeper) for keeper, counter in by_keeper.items()),
        reverse=True,
    )
    for total, keeper in keeper_totals[:top]:
        tops = ", ".join(f"{tool} {count}" for tool, count in by_keeper[keeper].most_common(3))
        lines.append(f"| {keeper} | {total} | {tops} |")
    lines.append("")
    lines.append("## unchanged-recall pairs (keeper_tasks_list self-contradiction)")
    lines.append("")
    if unchanged:
        for tool, count in unchanged.most_common(top):
            lines.append(f"- {tool}: {count}")
    else:
        lines.append("- none")
    lines.append("")
    lines.append("## probe pairs (argument shape changed between consecutive calls)")
    lines.append("")
    lines.append(f"- pairs: {probes}")
    lines.append(f"- pairs whose first call failed: {probes_first_failed}")
    lines.append("")
    paging, paging_by_keeper = artifact_paging(rows)
    lines.append("## artifact paging (keeper_artifact_read)")
    lines.append("")
    if paging["blobs"]:
        one_call_share = 100.0 * paging["one_call_blobs"] / paging["blobs"]
        lines.append(
            f"- blobs read: {paging['blobs']} (calls: {paging['calls']}, "
            f"max calls on one blob: {paging['max_calls']})"
        )
        lines.append(
            f"- blobs finished in one call: {paging['one_call_blobs']} "
            f"({one_call_share:.1f}% of blobs)"
        )
        lines.append(
            f"- excess calls beyond page arithmetic: {paging['excess_calls']} "
            f"(measured over {paging['sized_blobs']} utf-8 blobs with a parseable total_bytes; "
            f"{paging['non_utf8_blobs']} non-utf-8 blobs counted, not judged)"
        )
        lines.append(
            f"- small explicit slices (max_bytes < {ARTIFACT_PAGE_BYTES}): "
            f"{paging['small_slices']}"
        )
        lines.append("")
        lines.append("| keeper | blobs | calls | one-call blobs | excess calls | small slices |")
        lines.append("|---|---:|---:|---:|---:|---:|")
        for keeper, stats in paging_by_keeper[:top]:
            lines.append(
                f"| {keeper} | {stats['blobs']} | {stats['calls']} | {stats['one_call_blobs']} "
                f"| {stats['excess_calls']} | {stats['small_slices']} |"
            )
    else:
        lines.append("- no keeper_artifact_read calls")
    lines.append("")
    lines.append("## batch_size distribution")
    lines.append("")
    share_single = (100.0 * single / total_calls) if total_calls else 0.0
    lines.append(f"- batch_size=1: {single} ({share_single:.1f}% of calls)")
    for size, count in sorted(batches.items()):
        if size != 1:
            lines.append(f"- batch_size={size}: {count}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument(
        "--base-path",
        default=str(DEFAULT_BASE),
        help=(
            "MASC base path; logs are read from <base-path>/.masc/tool_calls "
            "(default: MASC_BASE_PATH or the home workspace)"
        ),
    )
    parser.add_argument(
        "--date",
        required=True,
        help="Day to measure, as YYYY-MM-DD (selects <dir>/YYYY-MM/DD.jsonl)",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=5,
        help="How many tools to list per section (default: 5)",
    )
    options = parser.parse_args()

    year_month, _, day = options.date.rpartition("-")
    log_path = (
        pathlib.Path(options.base_path).expanduser()
        / ".masc"
        / "tool_calls"
        / year_month
        / f"{day}.jsonl"
    )
    if not log_path.is_file():
        print(f"no such log file: {log_path}", file=sys.stderr)
        return 1

    rows = load_rows(log_path)
    print(render(rows, options.top))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
