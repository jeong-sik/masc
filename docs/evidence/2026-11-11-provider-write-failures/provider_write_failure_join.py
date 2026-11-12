"""Join Keeper cycle failures that broke on a socket write with runtime manifests.

Reads, never writes:
  system log  <base-path>/.masc/logs/system_log_YYYY-MM-DD.jsonl
  manifests   <base-path>/.masc/keepers/<keeper>/runtime-manifests/trace-*.jsonl*

Usage: python3 -I provider_write_failure_join.py <system_log.jsonl> <keepers_dir>

The system log is prose, so the failure kind is read from the message text here.
That is a measurement of past logs. It is not a model for product code, which must
read a typed fact (RFC-0492 section 3.3).
"""

import collections
import datetime
import json
import pathlib
import statistics
import sys

WRITE_FAILURE_TEXT = 'Broken pipe, "writev"'
READ_RESET_TEXT = 'Connection reset by peer, "readv"'
CYCLE_FAILED_TEXT = "keeper cycle FAILED"
TOOL_AFTER_EVENT = ("context_injected", "post_tool_context_injection")
RECONNECT_EVENT = ("provider_lane_resolved", "provider_connection_reconnect")
# A turn id can hold several runs. A run-level reconnect disables the connection cache
# only inside the run that reconnected, so a run start after the reconnect ends its reach.
RUN_START_EVENT = "turn_started"
PROVIDER_ATTEMPT_EVENT = ("runtime_routed", "attempt")
FAILED_EVENT = ("runtime_failed", "failed")
# runtime_failed is stamped when the attempt ends; the cycle line is written when the
# cycle ends. Take the latest runtime_failed in the 120 s before the cycle line, with
# 2 s of clock slack after it.
MATCH_BEFORE_S = 120
MATCH_AFTER_S = 2


def parse_ts(ts: str) -> datetime.datetime:
    return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")


def runtime_family(runtime_id: str) -> str:
    return runtime_id.split(".")[0] if runtime_id else "?"


def failure_class(message: str) -> str:
    if WRITE_FAILURE_TEXT in message:
        return "write_broken_pipe"
    if READ_RESET_TEXT in message:
        return "read_reset_by_peer"
    if "dns_failure" in message:
        return "dns_failure"
    return "other"


def read_failures(log_path: pathlib.Path) -> list[tuple[str, datetime.datetime, str, str]]:
    rows = []
    for line in log_path.open(encoding="utf-8", errors="replace"):
        if CYCLE_FAILED_TEXT not in line:
            continue
        entry = json.loads(line)
        message = entry["message"]
        runtime = message.split("runtime=", 1)[1].split(" ", 1)[0] if "runtime=" in message else "?"
        rows.append((entry["keeper_name"], parse_ts(entry["ts"]), runtime, failure_class(message)))
    return rows


def read_turns(keepers_dir: pathlib.Path, keeper: str, day: str) -> dict[int, list[dict]]:
    turns: dict[int, list[dict]] = collections.defaultdict(list)
    for path in (keepers_dir / keeper / "runtime-manifests").glob("trace-*.jsonl*"):
        for line in path.open(encoding="utf-8", errors="replace"):
            if day not in line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            turn = event.get("keeper_turn_id")
            if turn is not None:
                turns[turn].append(event)
    return turns


def names(events: list[dict], upto: str | None = None) -> set[tuple[str | None, str | None]]:
    return {(e.get("event"), e.get("status")) for e in events if upto is None or e["ts"] <= upto}


def main() -> None:
    log_path, keepers_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    day = log_path.stem.removeprefix("system_log_")
    failures = read_failures(log_path)
    write_failures = [f for f in failures if f[3] == "write_broken_pipe"]

    print(f"log {log_path.name}  failed cycles {len(failures)}  write failures {len(write_failures)}")
    if not write_failures:
        return
    stamps = sorted(f[1] for f in write_failures)
    print(f"window of write failures {stamps[0]}Z .. {stamps[-1]}Z (UTC)")

    by_runtime: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    for _, _, runtime, kind in failures:
        by_runtime[runtime_family(runtime)][kind] += 1
    print("failed cycles by runtime family and kind:")
    for family, counts in sorted(by_runtime.items(), key=lambda kv: -sum(kv[1].values())):
        print(f"  {family:28s} {dict(counts)}")

    keepers = sorted({f[0] for f in write_failures})
    turns_by_keeper = {k: read_turns(keepers_dir, k, day) for k in keepers}

    table: collections.Counter[tuple[str, bool]] = collections.Counter()
    gaps: list[float] = []
    reconnects: list[tuple[float, int, bool]] = []
    unmatched = 0
    for keeper, ts, _, _ in write_failures:
        best = None
        for turn_events in turns_by_keeper[keeper].values():
            for event in turn_events:
                if (event.get("event"), event.get("status")) != FAILED_EVENT:
                    continue
                gap = (ts - parse_ts(event["ts"])).total_seconds()
                if -MATCH_AFTER_S <= gap <= MATCH_BEFORE_S and (best is None or gap < best[0]):
                    best = (gap, turn_events, event)
        if best is None:
            unmatched += 1
            continue
        _, events, failed = best
        before = names(events, upto=failed["ts"])
        tool_stamps = [
            parse_ts(e["ts"])
            for e in events
            if (e.get("event"), e.get("status")) == TOOL_AFTER_EVENT and e["ts"] <= failed["ts"]
        ]
        if tool_stamps:
            gaps.append((parse_ts(failed["ts"]) - max(tool_stamps)).total_seconds())
        table[(runtime_family(failed.get("runtime_id") or ""), TOOL_AFTER_EVENT in before)] += 1
        reconnect_stamps = [
            parse_ts(e["ts"])
            for e in events
            if (e.get("event"), e.get("status")) == RECONNECT_EVENT and e["ts"] <= failed["ts"]
        ]
        if reconnect_stamps:
            last_reconnect = max(reconnect_stamps)
            injections_after = sum(1 for stamp in tool_stamps if stamp > last_reconnect)
            new_run_after = any(
                parse_ts(e["ts"]) > last_reconnect
                for e in events
                if e.get("event") == RUN_START_EVENT and e["ts"] <= failed["ts"]
            )
            reconnects.append(((parse_ts(failed["ts"]) - last_reconnect).total_seconds(), injections_after, new_run_after))

    print(f"write failures matched to a manifest turn {len(write_failures) - unmatched}, unmatched {unmatched}")
    print("runtime family | tool result injected before failure -> turns")
    for (family, tool), count in sorted(table.items(), key=lambda kv: -kv[1]):
        print(f"  {family:28s} | {str(tool):5s} -> {count}")

    in_failing_run = sum(1 for _, _, new_run_after in reconnects if not new_run_after)
    print(f"turn ids with a run-level reconnect event before the failure: {len(reconnects)}")
    print(f"  of these, the failing run is the reconnect run (no {RUN_START_EVENT} after the reconnect): {in_failing_run}")
    for seconds, injections, new_run_after in sorted(reconnects):
        print(
            f"  last reconnect -> runtime_failed {seconds:.0f} s, tool-result injections in between {injections}, "
            f"new run started after the reconnect {new_run_after}"
        )

    span_s = (stamps[-1] - stamps[0]).total_seconds()
    print("write failures with another keeper's write failure nearby (expected if failures were spread evenly over the window):")
    for window_s in (30, 120):
        near = sum(
            1
            for keeper, ts, _, _ in write_failures
            if any(other != keeper and abs((ts - other_ts).total_seconds()) <= window_s for other, other_ts, _, _ in write_failures)
        )
        expected = 1 - (1 - 2 * window_s / span_s) ** (len(write_failures) - 1)
        print(f"  within {window_s:3d} s: {near} of {len(write_failures)} (expected {100 * expected:.0f}%)")

    ordered = sorted(gaps)
    if not ordered:
        return
    buckets = collections.Counter(
        "<5s" if g < 5 else "5-15s" if g < 15 else "15-25s" if g < 25 else "25-60s" if g < 60 else ">=60s"
        for g in ordered
    )
    print(f"seconds from last tool-result injection to runtime_failed (n={len(ordered)}, median {statistics.median(ordered):.0f}):")
    print("  " + str({k: buckets[k] for k in ["<5s", "5-15s", "15-25s", "25-60s", ">=60s"]}))

    # Baseline: every turn of the same keepers that reached a provider attempt.
    outcome: collections.Counter[str] = collections.Counter()
    with_tool: collections.Counter[str] = collections.Counter()
    for turns in turns_by_keeper.values():
        for events in turns.values():
            present = names(events)
            if PROVIDER_ATTEMPT_EVENT not in present:
                continue
            key = "failed" if FAILED_EVENT in present else "not_failed"
            outcome[key] += 1
            if TOOL_AFTER_EVENT in present:
                with_tool[key] += 1
    print("baseline, same keepers, turns that reached a provider attempt:")
    for key in ("not_failed", "failed"):
        share = 100 * with_tool[key] / outcome[key] if outcome[key] else 0
        print(f"  {key:10s} turns {outcome[key]:5d}  with tool-result injection {with_tool[key]:5d} ({share:.0f}%)")


if __name__ == "__main__":
    main()
