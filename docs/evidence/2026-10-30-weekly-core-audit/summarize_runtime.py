#!/usr/bin/env python3
"""Summarize selected Keeper records without emitting their private contents."""

import argparse
import collections
import datetime as dt
import hashlib
import json
import statistics
from pathlib import Path


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-path", type=Path, required=True)
    parser.add_argument("--from-time", required=True)
    parser.add_argument("--until-time", required=True)
    args = parser.parse_args()
    start, end = stamp(args.from_time), stamp(args.until_time)
    if end < start:
        parser.error("until-time precedes from-time")
    keepers = args.base_path / ".masc" / "keepers"
    invalid = collections.Counter()

    snapshots = []
    snapshot_keepers = set()
    day = dt.datetime.fromtimestamp(start, dt.timezone.utc).date()
    last_day = dt.datetime.fromtimestamp(end, dt.timezone.utc).date()
    snapshot_paths = []
    while day <= last_day:
        snapshot_paths.extend(keepers.glob(f"*/provider-inputs/{day:%Y-%m}/{day:%d}.jsonl"))
        day += dt.timedelta(days=1)
    for path in snapshot_paths:
        for item, _ in rows(path, invalid):
            captured = item.get("captured_at")
            wire = item.get("wire") or {}
            if (isinstance(captured, (int, float)) and start <= captured <= end
                    and isinstance(wire.get("body_bytes"), int)):
                snapshots.append(item)
                snapshot_keepers.add(path.parts[-4])
    bodies = sorted(item["wire"]["body_bytes"] for item in snapshots)
    message_counts = [len(item.get("messages") or []) for item in snapshots]
    schema_counts = [len(item.get("tool_schemas") or []) for item in snapshots]
    schema_bytes = [sum((schema.get("artifact") or {}).get("bytes", 0)
                        for schema in item.get("tool_schemas") or [])
                    for item in snapshots]
    prompt_blocks = collections.defaultdict(list)
    for path in keepers.glob("*/last-prompt.json"):
        try:
            with path.open("r", encoding="utf-8") as source:
                item = json.load(source)
            for block in item.get("blocks", []):
                if (isinstance(block, dict) and isinstance(block.get("id"), str)
                        and isinstance(block.get("bytes"), int)):
                    prompt_blocks[block["id"]].append(block["bytes"])
        except (OSError, ValueError, UnicodeDecodeError):
            invalid["unreadable_prompt_files"] += 1

    recall_files = list(keepers.glob("*/memory-recall-evaluations.jsonl"))
    recall_files += list(keepers.glob("*/memory-recall-evaluations.jsonl.1"))
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
            counts[str(status)] += 1
            recorded = item.get("recorded_at")
            if isinstance(recorded, (int, float)):
                times.append(recorded)
            if status == "started":
                started_bytes.append(line_bytes)
                kind = item.get("kind")
                counts[f"started_{kind}"] += 1
                if kind == "time":
                    state = item.get("state") or {}
                    for candidate in state.get("candidates", []):
                        candidate_keys[(keeper, digest(candidate))] += 1
                    request = [item.get("destinations"), state, item.get("questions")]
                    request_keys[(keeper, digest(request))] += 1
            elif status == "response_received":
                reported = (item.get("response") or {}).get("usage")
                if isinstance(reported, dict):
                    counts["responses_with_usage"] += 1
                    for field in ("input_tokens", "output_tokens"):
                        if isinstance(reported.get(field), int):
                            usage[field] += reported[field]

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
