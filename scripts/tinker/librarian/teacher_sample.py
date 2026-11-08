# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Sample teacher answers for synthetic training requests and keep those that match the labels.

    uv run scripts/tinker/librarian/teacher_sample.py \
        --requests artifacts/tinker/librarian/synth-train/requests.jsonl \
        --out artifacts/tinker/librarian/teacher --budget 30

The teacher is the base model on the 256K training ID at reasoning_effort
"high", asked exactly as MASC's exact lane asks. Each request gets up to
ATTEMPTS answers. The first answer is kept when MASC's checks accept it, every
candidate outcome matches the label (a correction also supersedes its target),
every planted stale fact is dropped, and nothing else is dropped. Answers from
other providers are never used for training. An HTTP error or a missing
response is not an attempt: it stops that request, and a rerun with the same
--out sends it again.

Output: <out>/calls.jsonl (with the teacher's reasoning), <out>/accepted.jsonl
(item, attempt, answer, reasoning) and <out>/summary.json.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import cast

import eval_admission as V
from tinker_oai import HTTP_OK, Caller

TEACHER = "thinkingmachines/Inkling-2-Small:peft:262144"
EFFORT = "high"
MAX_TOKENS = 32768
ATTEMPTS = 4
WORKERS = 8

type JsonObject = dict[str, object]


def rejection(item: V.SynthItem, check: V.Check) -> str | None:
    """Why the answer cannot be a training target, or None when it can."""
    if check.answer is None:
        return "invalid:" + check.problems[0]
    score = V.score_synth(item, check.answer)
    if score["correct"] != score["candidates"]:
        return "outcome"
    if score["planted_dropped"] != score["planted"]:
        return "stale_kept"
    if score["dropped"] != score["dropped_expected"]:
        return "unexpected_drop"
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--requests", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--budget", type=float, required=True)
    args = ap.parse_args()
    out = Path(cast(str, args.out))
    out.mkdir(parents=True, exist_ok=True)
    instruction = V.schema_instruction()
    items = V.synth_items(Path(cast(str, args.requests)))
    caller = Caller(out / "calls.jsonl", cast(float, args.budget))
    reasons: Counter[str] = Counter()
    errors: Counter[int] = Counter()

    def one(item: V.SynthItem) -> JsonObject | None:
        for attempt in range(ATTEMPTS):
            call = caller.ask(model=TEACHER, label=f"teacher:{item.item_id}", messages=[item.text, instruction],
                              effort=EFFORT, max_tokens=MAX_TOKENS, attempt=attempt)
            if call is None:
                return None
            if call.status != HTTP_OK:
                errors[call.status] += 1
                return None
            why = rejection(item, V.check(item.prompt, call.answer()))
            if why is None:
                return {"item": item.item_id, "attempt": attempt, "answer": call.answer(), "reasoning": call.reasoning}
            reasons[why] += 1
        return None

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        kept = [k for k in pool.map(one, items) if k is not None]
    with (out / "accepted.jsonl").open("w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(k, ensure_ascii=False) + "\n" for k in kept)
    summary = {"teacher": TEACHER, "effort": EFFORT, "requests": len(items), "accepted": len(kept),
               "by_attempt": Counter(cast(int, k["attempt"]) for k in kept), "rejections": reasons,
               "http_errors": errors,
               "spent_usd": round(caller.spent, 4), "stopped": caller.stopped}
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 2 if caller.stopped is not None else 0


if __name__ == "__main__":
    sys.exit(main())
