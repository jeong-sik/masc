# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""How many planted stale facts a right answer can drop at all. Prints numbers only.

    cd <checkout of tinker/librarian-drop-adjudication at 365233db560b>
    PYTHONDONTWRITEBYTECODE=1 uv run <this folder>/reachable_recall.py

MASC accepts a memory change only when an incorporated or already_represented
candidate supports it (`verify_support`, keeper_memory_admission_judgment.ml:109-130).
A request whose label candidates are all not_durable has no such candidate, so
an answer that follows the label must leave its memory as it is. `reachable`
counts the planted stale facts on the other requests: the best stale drop
recall a right answer can reach.

`base_on_requests_with_planted` sorts the base model's answers (effort low) on
the pinned E-synth requests that hold a planted stale fact: by whether a label
candidate can support a change, then not valid, valid and dropping one or more
planted facts, or valid and keeping them all. `base_planted_facts` counts the
planted facts of the valid answers the same way, one by one.
"""

from __future__ import annotations

import json
from collections import Counter

import stored as S


def reach(name: str, items: list[S.V.SynthItem]) -> None:
    planted = sum(len(S.planted(i)) for i in items)
    reachable = sum(len(S.planted(i)) for i in items if S.supported(i))
    with_planted = [i for i in items if S.planted(i)]
    print(json.dumps({"set": name, "requests": len(items), "planted": planted, "reachable": reachable,
                      "best_recall": round(reachable / planted, 3),
                      "requests_with_planted": {"supported": sum(S.supported(i) for i in with_planted),
                                                "not_supported": sum(not S.supported(i) for i in with_planted)}}))


def main() -> None:
    reach("pinned E-synth", list(S.synth(S.E_SYNTH).values()))
    reach("train split", list(S.synth(S.TRAIN).values()))
    sorted_answers: dict[str, Counter[str]] = {"supported": Counter(), "not_supported": Counter()}
    facts: dict[str, Counter[str]] = {"supported": Counter(), "not_supported": Counter()}
    for item, answer in S.base_synth():
        if not S.planted(item):
            continue
        side = "supported" if S.supported(item) else "not_supported"
        state = ("not_valid" if answer is None
                 else "dropped" if S.planted(item) & set(answer.dropped) else "kept")
        sorted_answers[side][state] += 1
        if answer is not None:
            absorbed = {mid for mid, _ in answer.absorbed}
            for mid in S.planted(item):
                facts[side]["dropped" if mid in answer.dropped else "absorbed" if mid in absorbed else "kept"] += 1
    print(json.dumps({"base_on_requests_with_planted": {k: dict(sorted(c.items())) for k, c in sorted_answers.items()},
                      "base_planted_facts": {k: dict(sorted(c.items())) for k, c in facts.items()}}))


main()
