"""Summarise provider admission waits by account and admission class.

Reads `agent-core-events/<YYYY-MM>/<DD>.jsonl` files and keeps the
`masc:provider_admission:waited` rows. Each row is one request that found
every permit of its account held and queued, so the waits here are the
waits of requests that met a full account; a request granted a permit at
once writes no row.

Read-only: prints one line per (provider_id, admission_class, outcome).

    python3 admission_waits.py ~/.masc/agent-core-events/2026-10/07.jsonl
    python3 admission_waits.py day1.jsonl day2.jsonl --provider glm-coding
"""

import argparse
import json
import math
from collections import defaultdict

EVENT_TYPE = "masc:provider_admission:waited"


def percentile(sorted_values, fraction):
    """Nearest-rank percentile of an already sorted, non-empty list."""
    rank = max(1, math.ceil(fraction * len(sorted_values)))
    return sorted_values[rank - 1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("events", nargs="+")
    parser.add_argument("--provider", help="keep one provider_id")
    args = parser.parse_args()

    waits = defaultdict(list)
    unmeasured = defaultdict(int)
    for path in args.events:
        with open(path) as events:
            for line in events:
                line = line.strip()
                if not line:
                    continue
                event = json.loads(line)
                if event.get("event_type") != EVENT_TYPE:
                    continue
                payload = event["payload"]
                provider = payload.get("provider_id")
                if args.provider is not None and provider != args.provider:
                    continue
                key = (provider, payload["admission_class"], payload["outcome"])
                if payload.get("waited_ms") is None:
                    unmeasured[key] += 1
                else:
                    waits[key].append(payload["waited_ms"])

    print("provider_id\tclass\toutcome\tcount\tp50_ms\tp90_ms\tmax_ms\tunmeasured")
    for key in sorted(set(waits) | set(unmeasured), key=lambda k: tuple(map(str, k))):
        values = sorted(waits.get(key, []))
        stats = (
            [len(values), percentile(values, 0.5), percentile(values, 0.9), values[-1]]
            if values
            else [0, None, None, None]
        )
        print("\t".join(map(str, [*key, *stats, unmeasured.get(key, 0)])))


if __name__ == "__main__":
    main()
