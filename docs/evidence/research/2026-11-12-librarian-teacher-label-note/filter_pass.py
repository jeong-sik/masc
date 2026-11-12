# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""How many answers of a harness run on synthetic requests would pass the teacher filter.

    cd <checkout>
    uv run <this folder>/filter_pass.py <requests.jsonl> <run dir> [target]

Runs from the root of the checkout, whose `scripts/tinker/librarian/` holds the harness imported
here. Reads the run's call log, checks each answered call as MASC does and asks
`teacher_sample.rejection` why it could not be a training target. Requests whose label a candidate
can support are also counted by how many planted stale facts and duplicate pairs the label asks to
take out, and the requests no candidate supports are counted apart. Prints counts only, each as
[passed, asked].
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path("scripts") / "tinker" / "librarian"))

import e_synth_audit as A
import eval_admission as V
import teacher_sample as T


def main() -> int:
    requests, run = Path(sys.argv[1]), Path(sys.argv[2])
    target = sys.argv[3] if len(sys.argv) > 3 else "base"
    calls = A.answers(run, target)
    why: Counter[str] = Counter()
    asked: Counter[str] = Counter()
    passed: Counter[str] = Counter()
    items = V.synth_items(requests)
    for item in items:
        call = calls.get(item.item_id)
        got = T.rejection(item, V.check(item.prompt, call.answer() if call is not None else None))
        why["pass" if got is None else got.split(":")[0]] += 1
        n = len(item.label.planted_stale) + len(item.label.duplicates)
        bucket = "unsupported" if not item.label.supports_change else "2+" if n > 1 else str(n)
        asked[bucket] += 1
        passed[bucket] += got is None
    unsupported = [passed.pop("unsupported", 0), asked.pop("unsupported", 0)]
    print(json.dumps({"requests": len(items), "why": dict(sorted(why.items())),
                      "supported_by_planted": {b: [passed[b], asked[b]] for b in sorted(asked)},
                      "unsupported": unsupported}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
