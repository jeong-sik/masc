# pyright: strict
"""Draw a seeded sample of synthetic requests, for a teacher pilot.

    python3 pilot_subset.py <requests.jsonl> <n> <seed> <out.jsonl>

Writes the drawn rows as they are, in file order, and prints what the sample and the whole file
hold: candidates by kind, requests a candidate can support a Memory change on, and on those
requests the planted stale facts, the planted duplicate pairs and the records still ahead.
"""

from __future__ import annotations

import json
import random
import sys
from collections import Counter
from pathlib import Path
from typing import cast

type JsonObject = dict[str, object]


def holds(requests: list[JsonObject]) -> JsonObject:
    kinds: Counter[str] = Counter()
    supported = stale = pairs = ahead = 0
    for request in requests:
        candidates = cast(list[JsonObject], request["candidates"])
        facts = cast(list[JsonObject], request["facts"])
        kinds.update(cast(str, c["kind"]) for c in candidates)
        if any(c["kind"] != "transient" for c in candidates):
            supported += 1
            stale += sum(bool(f["planted_stale"]) for f in facts)
            pairs += sum(f["duplicate_of"] is not None for f in facts)
            ahead += sum(f["use_at"] is not None and not f["planted_stale"] for f in facts)
    memories = {cast(str, r["item_id"]).rsplit("-", 1)[0] for r in requests}
    return {"requests": len(requests), "supported": supported, "kinds": dict(sorted(kinds.items())),
            "stale_asked": stale, "pairs_asked": pairs, "ahead": ahead, "memories": len(memories)}


def main() -> int:
    source, n, seed, out = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4])
    lines = [line for line in source.read_text(encoding="utf-8").splitlines() if line.strip()]
    requests = [cast(JsonObject, cast(JsonObject, json.loads(line))["request"]) for line in lines]
    drawn = sorted(random.Random(seed).sample(range(len(lines)), n))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("".join(lines[i] + "\n" for i in drawn), encoding="utf-8")
    print(json.dumps({"all": holds(requests), "sample": holds([requests[i] for i in drawn])}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
