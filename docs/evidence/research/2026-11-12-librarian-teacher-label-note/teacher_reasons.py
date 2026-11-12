# pyright: strict
"""Print the reasons of the teacher answers `sample` kept or left waiting, to read them for mentions of the label note.

    python3 teacher_reasons.py <teacher out dir> [max chars per reason] [phrase ...]

The requests are synthetic. Prints each answer's item, its Memory changes by ID and every reason, then how
many answers and reasons that was. For each phrase it prints how many of those reasons hold it and how many
of the thinking texts in calls.jsonl do.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import cast

type JsonObject = dict[str, object]


def rows(path: Path) -> list[JsonObject]:
    return [cast(JsonObject, json.loads(line)) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def main() -> int:
    out = Path(sys.argv[1])
    cut = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    phrases = sys.argv[3:]
    answers = 0
    dropped: list[str] = []
    judged_reasons: list[str] = []
    for name in ("kept.jsonl", "pending.jsonl"):
        for record in rows(out / name):
            answer = cast(JsonObject, json.loads(cast(str, record["answer"])))
            memory = cast(JsonObject, answer["memory"])
            answers += 1
            print(f"## {record['item']} attempt {record['attempt']} ({name})")
            for claim in cast(list[JsonObject], memory["new_claims"]):
                print(f"  claim len {len(cast(str, claim['claim']))} supersedes {claim['supersedes']} absorbs {claim['absorbs']}")
            for drop in cast(list[JsonObject], memory["dropped"]):
                reason = cast(str, drop["reason"])
                dropped.append(reason)
                print(f"  dropped {drop['memory_id']}: {reason[:cut]}")
            for judged in cast(list[JsonObject], answer["candidates"]):
                reason = cast(str, judged["reason"])
                judged_reasons.append(reason)
                print(f"  {cast(str, judged['request_id'])[-6:]} {judged['outcome']}: {reason[:cut]}")
            print(f"  change_support {len(cast(list[object], answer['change_support']))}")
    reasons = dropped + judged_reasons
    print(json.dumps({"answers": answers, "reasons": len(reasons), "dropped": len(dropped),
                      "candidates": len(judged_reasons)}))
    if phrases:
        thinking = [cast(str | None, call["reasoning"]) or "" for call in rows(out / "calls.jsonl")]
        print(json.dumps({"thinking_texts": len(thinking),
                          "holding": {p: {"reasons": sum(p in r for r in reasons),
                                          "thinking": sum(p in t for t in thinking)} for p in phrases}},
                         ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
