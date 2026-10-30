#!/usr/bin/env python3
"""Summarize selected Keeper records without emitting their private contents."""

import argparse
import collections
import datetime as dt
import hashlib
import json
import math
import os
import statistics
from pathlib import Path

PROMPT_BLOCKS = frozenset({
    "active_goals", "admitted_scheduled_input", "completion_authority", "dynamic_context",
    "keeper_instructions", "librarian_working_context", "memory_os_recall",
    "operator_note", "recalled_memory", "recalled_memory_status", "skill_compositions", "temporal_summary",
})
RECALL_STATUSES = frozenset({"started", "response_received", "judgment_completed", "provider_failed", "cancelled"})
RECALL_KINDS = frozenset({"turn", "candidates", "time"})


def stamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def time_string(value):
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat()


def digest(value):
    encoded = json.dumps(value, sort_keys=True, ensure_ascii=False).encode()
    return hashlib.sha256(encoded).digest()


def rows(path, invalid):
    try:
        with path.open("rb") as source:
            for line in source:
                try:
                    item = json.loads(line)
                    if not isinstance(item, dict):
                        invalid["invalid_lines"] += 1
                        continue
                    yield item, len(line)
                except (ValueError, UnicodeDecodeError):
                    invalid["invalid_lines"] += 1
    except OSError:
        invalid["unreadable_files"] += 1


def keeper_directories(path, invalid):
    try:
        with os.scandir(path) as entries:
            keepers = []
            for entry in entries:
                try:
                    if entry.is_dir():
                        keepers.append((entry.name, Path(entry.path)))
                except OSError:
                    invalid["unreadable_keeper_entries"] += 1
            return keepers
    except OSError:
        raise SystemExit("Keeper runtime directory is missing or unreadable") from None


def selected_paths(directory, names, invalid, error_key):
    """Read one source directory; a missing selected name is normal."""
    try:
        with os.scandir(directory) as entries:
            return {entry.name: Path(entry.path) for entry in entries if entry.name in names}
    except OSError:
        invalid[error_key] += 1
        return {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-path", type=Path, required=True)
    parser.add_argument("--from-time", required=True)
    parser.add_argument("--until-time", required=True)
    args = parser.parse_args()
    start, end = stamp(args.from_time), stamp(args.until_time)
    if end < start:
        parser.error("until-time precedes from-time")
    invalid = collections.Counter()
    keepers = keeper_directories(args.base_path / ".masc" / "keepers", invalid)

    snapshots = []
    snapshot_keepers = set()
    day = dt.datetime.fromtimestamp(start, dt.timezone.utc).date()
    last_day = dt.datetime.fromtimestamp(end, dt.timezone.utc).date()
    days_by_month = collections.defaultdict(set)
    while day <= last_day:
        days_by_month[f"{day:%Y-%m}"].add(f"{day:%d}.jsonl")
        day += dt.timedelta(days=1)
    snapshot_paths = []
    prompt_paths = []
    recall_files = []
    for keeper, directory in keepers:
        sources = selected_paths(
            directory,
            {"provider-inputs", "last-prompt.json", "memory-recall-evaluations.jsonl",
             "memory-recall-evaluations.jsonl.1"},
            invalid,
            "unreadable_keeper_directories",
        )
        prompt = sources.get("last-prompt.json")
        if prompt is not None:
            prompt_paths.append(prompt)
        for name in ("memory-recall-evaluations.jsonl", "memory-recall-evaluations.jsonl.1"):
            if name in sources:
                recall_files.append(sources[name])
        provider_dir = sources.get("provider-inputs")
        if provider_dir is None:
            continue
        months = selected_paths(
            provider_dir, days_by_month, invalid, "unreadable_provider_input_directories"
        )
        for month, directory in months.items():
            files = selected_paths(
                directory, days_by_month[month], invalid, "unreadable_provider_month_directories"
            )
            snapshot_paths.extend((keeper, path) for path in files.values())
    for keeper, path in snapshot_paths:
        for item, _ in rows(path, invalid):
            captured = item.get("captured_at")
            wire = item.get("wire")
            if (not isinstance(captured, (int, float)) or isinstance(captured, bool)
                    or not math.isfinite(captured)
                    or not isinstance(wire, dict) or type(wire.get("body_bytes")) is not int
                    or wire["body_bytes"] < 0
                    or not isinstance(item.get("messages"), list)
                    or not isinstance(item.get("tool_schemas"), list)):
                invalid["invalid_provider_records"] += 1
                continue
            schemas = item["tool_schemas"]
            if any(not isinstance(schema, dict) or not isinstance(schema.get("artifact"), dict)
                   or type(schema["artifact"].get("bytes")) is not int
                   or schema["artifact"]["bytes"] < 0 for schema in schemas):
                invalid["invalid_provider_records"] += 1
                continue
            if start <= captured <= end:
                snapshots.append(item)
                snapshot_keepers.add(keeper)
    bodies = sorted(item["wire"]["body_bytes"] for item in snapshots)
    message_counts = [len(item.get("messages") or []) for item in snapshots]
    schema_counts = [len(item.get("tool_schemas") or []) for item in snapshots]
    schema_bytes = [sum((schema.get("artifact") or {}).get("bytes", 0)
                        for schema in item.get("tool_schemas") or [])
                    for item in snapshots]
    prompt_blocks = collections.defaultdict(list)
    for path in prompt_paths:
        try:
            with path.open("r", encoding="utf-8") as source:
                item = json.load(source)
            if not isinstance(item, dict) or not isinstance(item.get("blocks"), list):
                invalid["invalid_prompt_files"] += 1
                continue
            for block in item.get("blocks", []):
                if (isinstance(block, dict) and isinstance(block.get("id"), str)
                        and type(block.get("bytes")) is int and block["bytes"] >= 0):
                    if block["id"] in PROMPT_BLOCKS:
                        prompt_blocks[block["id"]].append(block["bytes"])
                    else:
                        invalid["unknown_prompt_blocks"] += 1
                else:
                    invalid["invalid_prompt_blocks"] += 1
        except (OSError, ValueError, UnicodeDecodeError):
            invalid["unreadable_prompt_files"] += 1

    counts = collections.Counter()
    usage = collections.Counter()
    started_bytes = []
    times = []
    candidate_keys = collections.Counter()
    request_keys = collections.Counter()
    for path in recall_files:
        keeper = path.parent.name
        for item, line_bytes in rows(path, invalid):
            status = item.get("status")
            if not isinstance(status, str) or status not in RECALL_STATUSES:
                invalid["unknown_recall_statuses"] += 1
                continue
            counts[status] += 1
            recorded = item.get("recorded_at")
            if isinstance(recorded, (int, float)) and not isinstance(recorded, bool) and math.isfinite(recorded):
                times.append(recorded)
            if status == "started":
                started_bytes.append(line_bytes)
                kind = item.get("kind")
                if not isinstance(kind, str) or kind not in RECALL_KINDS:
                    invalid["unknown_recall_kinds"] += 1
                    continue
                counts[f"started_{kind}"] += 1
                if kind == "time":
                    state = item.get("state")
                    if not isinstance(state, dict) or not isinstance(state.get("candidates"), list):
                        invalid["invalid_recall_records"] += 1
                        continue
                    for candidate in state.get("candidates", []):
                        candidate_keys[(keeper, digest(candidate))] += 1
                    request = [item.get("destinations"), state, item.get("questions")]
                    request_keys[(keeper, digest(request))] += 1
            elif status == "response_received":
                response = item.get("response")
                if not isinstance(response, dict):
                    invalid["invalid_recall_records"] += 1
                    continue
                reported = response.get("usage")
                if isinstance(reported, dict):
                    fields = ("input_tokens", "output_tokens")
                    if all(type(reported.get(field)) is int and reported[field] >= 0 for field in fields):
                        counts["responses_with_usage"] += 1
                        for field in fields:
                            usage[field] += reported[field]
                    else:
                        invalid["invalid_recall_usage"] += 1

    result = {
        "captured_at_utc": time_string(dt.datetime.now(dt.timezone.utc).timestamp()),
        "provider_inputs": {
            "window_start_utc": time_string(start),
            "window_end_utc": time_string(end),
            "records": len(snapshots),
            "keepers": len(snapshot_keepers),
            "body_bytes_min": min(bodies) if bodies else None,
            "body_bytes_median": statistics.median(bodies) if bodies else None,
            "body_bytes_max": max(bodies) if bodies else None,
            "message_count_min": min(message_counts) if message_counts else None,
            "message_count_max": max(message_counts) if message_counts else None,
            "tool_schema_count_min": min(schema_counts) if schema_counts else None,
            "tool_schema_count_max": max(schema_counts) if schema_counts else None,
            "tool_schema_artifact_bytes_median": statistics.median(schema_bytes) if schema_bytes else None,
            "tool_schema_artifact_bytes_max": max(schema_bytes) if schema_bytes else None,
        },
        "last_prompt_block_sizes": {
            name: {"count": len(values), "median_bytes": statistics.median(values),
                   "max_bytes": max(values)}
            for name, values in sorted(prompt_blocks.items())
        },
        "memory_recall_retained_logs": {
            "files": len(recall_files),
            "keepers": len({path.parent.name for path in recall_files}),
            "first_recorded_at_utc": time_string(min(times)) if times else None,
            "last_recorded_at_utc": time_string(max(times)) if times else None,
            "counts": dict(counts),
            "started_line_bytes_sum": sum(started_bytes),
            "started_line_bytes_median": statistics.median(started_bytes) if started_bytes else None,
            "reported_usage": dict(usage),
            "time_candidate_occurrences": sum(candidate_keys.values()),
            "time_candidate_distinct_within_keeper": len(candidate_keys),
            "time_request_occurrences": sum(request_keys.values()),
            "time_request_distinct_within_keeper": len(request_keys),
        },
        "read_errors": dict(invalid),
    }
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
