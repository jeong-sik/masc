"""Show whether one provider account's admission permits are saturated.

Reads one day of `agent-core-events/<YYYY-MM>/<DD>.jsonl`.
`Streaming_first_chunk.requested_at` is taken inside the admission permit
(Complete.complete_stream runs its dispatch under Provider_admission), so it
is the instant a permit was granted. `Streaming_summary` arrives when a stream
ends and carries `total_ms`.

A dispatch counts as "released by another caller" when a stream of a
different keeper_turn_id on the same provider ended within --window seconds
before it. The same count with every dispatch shifted by --shift seconds is
the chance baseline. Only streaming calls are visible here, so the in-flight
share is a lower bound.

    python3 account_admission.py ~/.masc/agent-core-events/2026-10/06.jsonl --provider glm
"""
import argparse
import bisect
import json
import statistics
import time
from collections import Counter, defaultdict


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("events")
    parser.add_argument("--provider", default="glm")
    parser.add_argument("--window", type=float, default=0.3)
    parser.add_argument("--shift", type=float, default=3.0)
    parser.add_argument("--slots", type=int, default=4)
    args = parser.parse_args()
    ends, dispatches, intervals = [], [], []
    call_seconds = defaultdict(list)
    with open(args.events) as events:
        for line in events:
            if "Streaming_" not in line:
                continue
            event = json.loads(line)
            kind, payload = event["payload"]
            if payload.get("provider") != args.provider:
                continue
            turn = event.get("keeper_turn_id")
            if kind == "Streaming_summary" and payload.get("total_ms") is not None:
                end = event["ts_unix"]
                start = end - payload["total_ms"] / 1000
                ends.append((end, turn))
                intervals.append((start, end))
                call_seconds[time.strftime("%H", time.localtime(start))].append(payload["total_ms"] / 1000)
            elif kind == "Streaming_first_chunk" and payload.get("requested_at"):
                dispatches.append((payload["requested_at"], turn))
    ends.sort()
    end_times = [t for t, _ in ends]

    def released_by_other(at, turn):
        index = bisect.bisect_right(end_times, at) - 1
        while index >= 0 and at - end_times[index] < args.window:
            if ends[index][1] != turn:
                return True
            index -= 1
        return False

    by_hour = defaultdict(Counter)
    for at, turn in dispatches:
        hour = time.strftime("%H", time.localtime(at))
        by_hour[hour]["dispatches"] += 1
        by_hour[hour]["released_by_other"] += released_by_other(at, turn)
    chance = sum(released_by_other(at + args.shift, turn) for at, turn in dispatches)
    edges = sorted([(s, 1) for s, _ in intervals] + [(e, -1) for _, e in intervals])
    in_flight, last, saturated = 0, None, defaultdict(Counter)
    for at, delta in edges:
        if last is not None and at > last:
            hour = time.strftime("%H", time.localtime(last))
            saturated[hour]["total"] += at - last
            if in_flight >= args.slots:
                saturated[hour]["full"] += at - last
        in_flight += delta
        last = at
    total = len(dispatches)
    report = {
        "provider": args.provider,
        "dispatches": total,
        "released_by_other_share": round(sum(h["released_by_other"] for h in by_hour.values()) / total, 3) if total else None,
        "chance_baseline_share": round(chance / total, 3) if total else None,
        "by_local_hour": {
            hour: {
                "dispatches": by_hour[hour]["dispatches"],
                "released_by_other_share": round(by_hour[hour]["released_by_other"] / by_hour[hour]["dispatches"], 3),
                "full_share_lower_bound": round(saturated[hour]["full"] / saturated[hour]["total"], 3) if saturated[hour]["total"] else None,
                "call_seconds_p50": round(statistics.median(call_seconds[hour]), 1) if call_seconds[hour] else None,
            } for hour in sorted(by_hour)},
    }
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
