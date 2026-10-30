#!/usr/bin/env python3
"""Board attention volume, value, redundancy and latency, read from the live ledgers.

Usage: python3 measure.py [<masc-base>/.masc] [<unix-now>]
       (default base: ~/me/.masc, default now: the current time)

Reads only. Every candidate is counted once, at its last ledger row. Partitions
are counted at their last row per partition id. Prints the numbers the RFC
`RFC-board-attention-asks-jev-once-per-event.md` cites, so the same script measures
before and after each stage. Pass the same <unix-now> to reproduce a run.
"""

import collections
import glob
import json
import os
import sys
import time

DAY_S = 86400
HOUR_S = 3600
EXECUTABLE = ("pending", "requeued")
OPERATOR_HELD = ("quarantined", "requeue_requested")
LLM_SOURCES = ("exact_attempt", "cli_lane_slot")


def last_rows(path, key):
    last = {}
    skipped = 0
    with open(path) as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            if key in row:
                last[row[key]] = row
    return last, skipped


def percentile(sorted_values, fraction):
    if not sorted_values:
        return 0.0
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * fraction))]


def group_key(keeper, row):
    context = row.get("keeper_context") or {}
    return (
        keeper,
        context.get("lane_keeper_name"),
        tuple(context.get("board_interests") or ()),
        row["signal"]["post_id"],
    )


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/me/.masc")
    now = float(sys.argv[2]) if len(sys.argv) > 2 else time.time()
    skipped = 0
    arrivals = 0
    events = set()
    groups_day = set()
    groups_hour = set()
    decisions = collections.Counter()
    sources_24h = collections.Counter()
    llm_calls_24h = collections.Counter()
    latency_h = []
    executable = 0
    executable_groups = set()
    operator_held = 0
    llm_thread_verdicts = collections.defaultdict(list)

    for path in sorted(glob.glob(os.path.join(base, "board_attention_candidates", "*.jsonl"))):
        keeper = os.path.basename(path)[: -len(".jsonl")]
        rows, bad = last_rows(path, "candidate_id")
        skipped += bad
        for row in rows.values():
            signal = row["signal"]
            status = row["status"]
            group = group_key(keeper, row)
            if now - row["recorded_at"] < DAY_S:
                arrivals += 1
                events.add((signal["kind"], signal["post_id"], signal.get("comment_id"), signal.get("updated_at")))
                groups_day.add(group)
                groups_hour.add(group + (int(row["recorded_at"] // HOUR_S),))
            if status["kind"] in EXECUTABLE:
                executable += 1
                executable_groups.add(group)
            elif status["kind"] in OPERATOR_HELD:
                operator_held += 1
            if status["kind"] != "consumed":
                continue
            judgment = status.get("judgment") or {}
            source = judgment.get("source") or {}
            decision = (judgment.get("verdict") or {}).get("decision") or status.get("delivery")
            decisions[decision] += 1
            if source.get("kind") in LLM_SOURCES:
                llm_thread_verdicts[group].append((row["recorded_at"], decision))
            if now - status["consumed_at"] < DAY_S:
                sources_24h[source.get("kind")] += 1
                if source.get("kind") in LLM_SOURCES:
                    llm_calls_24h[source.get("call_id")] += 1
                latency_h.append((status["consumed_at"] - row["recorded_at"]) / HOUR_S)

    partitions = collections.Counter()
    for path in sorted(glob.glob(os.path.join(base, "board_attention_partitions", "*.jsonl"))):
        rows, bad = last_rows(path, "partition_id")
        skipped += bad
        for row in rows.values():
            state = row.get("state")
            if isinstance(state, dict):
                kind = state["kind"]
                if kind == "running":
                    kind = "running_" + state.get("progress", {}).get("kind", "?")
                partitions[kind] += 1

    judged = sum(decisions.values())
    latency_h.sort()
    print(f"now={now:.0f} skipped_malformed_lines={skipped}")
    print(f"arrivals_24h={arrivals} distinct_events_24h={len(events)}")
    print(f"distinct_groups_24h={len(groups_day)} distinct_groups_by_hour_24h={len(groups_hour)}")
    print(f"settled_24h_by_source={dict(sources_24h)}")
    print(f"llm_calls_24h={len(llm_calls_24h)} candidates_per_llm_call={dict(collections.Counter(llm_calls_24h.values()))}")
    if judged:
        print(f"not_relevant_share_all_time={decisions['not_relevant'] / judged:.3f} over {judged}")
    print(
        f"settled_latency_h_24h p50={percentile(latency_h, 0.5):.1f} p90={percentile(latency_h, 0.9):.1f}"
        " (settled candidates only; waiting ones are not in it)"
    )
    print(f"executable_waiting={executable} executable_groups={len(executable_groups)} operator_held={operator_held}")
    print(f"partitions_by_state={dict(partitions)}")
    flips = transitions = 0
    for verdicts in llm_thread_verdicts.values():
        ordered = [decision for _, decision in sorted(verdicts)]
        flips += sum(1 for left, right in zip(ordered, ordered[1:]) if left != right)
        transitions += max(0, len(ordered) - 1)
    if transitions:
        print(
            f"llm_same_group_adjacent_change_rate_all_time={flips / transitions:.3f} over {transitions}"
            " (adjacent verdicts are on different signals, so this is not a consistency score)"
        )


if __name__ == "__main__":
    main()
