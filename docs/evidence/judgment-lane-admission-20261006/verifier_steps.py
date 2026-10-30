"""Split verifier runs into tool time and model-step time.

Reads a live `verification-runs.jsonl` (register/complete rows). A model step
is the gap between consecutive tool `finished_at` values (parallel calls that
finish within one second count as one step). Prints one JSON object.

    python3 verifier_steps.py ~/.masc/verification-runs.jsonl --hours 24
"""
import argparse
import json
import statistics
import time
from collections import defaultdict


def quantiles(values):
    if not values:
        return None
    ordered = sorted(values)
    return {"n": len(values), "p50": round(statistics.median(ordered), 1),
            "p90": round(ordered[int(len(ordered) * 0.9)], 1)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ledger")
    parser.add_argument("--hours", type=float, default=24.0)
    parser.add_argument("--until", type=float, default=None,
                        help="unix time the window ends at (default: now)")
    args = parser.parse_args()
    until = args.until if args.until is not None else time.time()
    since = until - args.hours * 3600
    registered, completed = {}, {}
    with open(args.ledger) as ledger:
        for line in ledger:
            row = json.loads(line)
            if row.get("event") == "register":
                registered[row["id"]] = row
            elif row.get("event") == "complete":
                completed[row["id"]] = row
    by_runtime = defaultdict(lambda: defaultdict(list))
    outcomes = defaultdict(int)
    for run_id, row in registered.items():
        if not since <= row["started_at"] < until or run_id not in completed:
            continue
        completion = completed[run_id]["completion"]
        outcomes[completion.get("outcome")] += 1
        runtime = str(completion.get("evaluator_runtime"))
        tools = completion.get("tools") or []
        finished = sorted(t["finished_at"] for t in tools if t.get("finished_at"))
        series = by_runtime[runtime]
        series["elapsed_s"].append(completion["elapsed_s"])
        series["tool_s"].append(sum(t.get("duration_ms") or 0 for t in tools) / 1000)
        if not finished:
            continue
        points = [row["started_at"]] + finished
        steps = [b - a for a, b in zip(points, points[1:]) if b - a > 1]
        series["first_tool_s"].append(finished[0] - row["started_at"])
        series["model_steps"].append(len(steps))
        series["step_gap_s"].extend(steps[1:])
    report = {"window": {"since": since, "until": until}, "outcomes": dict(outcomes),
              "by_runtime": {runtime: {key: quantiles(values) for key, values in series.items()}
                             for runtime, series in by_runtime.items()}}
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
