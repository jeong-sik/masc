# pyright: strict
"""Print what a teacher run's call log holds: statuses, finishes, tokens, wall time and cost.

    python3 call_stats.py <teacher out dir>

Reads <out>/calls.jsonl. Prints counts and numbers only: min, median and max of the answer tokens, the
prompt tokens and the wall seconds, the share of prompt tokens read from the cache, and the cost at the
public prices `tinker_oai.py` uses.
"""

from __future__ import annotations

import json
import statistics
import sys
from collections import Counter
from collections.abc import Sequence
from pathlib import Path
from typing import cast

type JsonObject = dict[str, object]

PRICE = {"prefill": 0.30, "cached": 0.03, "sample": 1.00}  # USD per million tokens, as in tinker_oai.py


def spread(values: Sequence[float]) -> list[float]:
    return [min(values), round(statistics.median(values), 2), max(values)]


def main() -> int:
    lines = (Path(sys.argv[1]) / "calls.jsonl").read_text(encoding="utf-8").splitlines()
    calls = [cast(JsonObject, json.loads(line)) for line in lines if line.strip()]
    prompt = [cast(int, c["prompt_tokens"]) for c in calls]
    cached = sum(cast(int, c["cached_tokens"]) for c in calls)
    sampled = [cast(int, c["completion_tokens"]) for c in calls]
    cost = ((sum(prompt) - cached) * PRICE["prefill"] + cached * PRICE["cached"] + sum(sampled) * PRICE["sample"]) / 1e6
    print(json.dumps({
        "calls": len(calls),
        "status": dict(Counter(str(c["status"]) for c in calls)),
        "finish": dict(Counter(str(c["finish"]) for c in calls)),
        "completion_tokens": spread(sampled),
        "prompt_tokens": spread(prompt),
        "wall_s": spread([round(cast(float, c["wall_s"]), 2) for c in calls]),
        "cached_share": round(cached / sum(prompt), 3),
        "cost_usd": round(cost, 4)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
