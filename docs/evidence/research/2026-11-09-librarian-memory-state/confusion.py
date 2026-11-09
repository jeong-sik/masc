# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""What answers give each kind of candidate, and what the teacher filter keeps. Prints numbers only.

    cd <checkout of tinker/librarian-drop-adjudication at 365233db560b>
    PYTHONDONTWRITEBYTECODE=1 uv run <this folder>/confusion.py

`confusion`: per label kind, the outcomes valid answers gave. `<outcome>/wrong_claim`
is the label's outcome naming another claim than `eval_admission.claim_matches`
wants. Answers are the base model's (effort low) on the pinned E-synth 119 and
every teacher attempt (effort high) on the train split.

`transient_answered_already_represented`: a transient candidate answered
already_represented names a claim of final memory. It is a planted stale fact,
another current fact, or a claim the answer adds; for a planted stale fact,
whether the answer keeps it.

`teacher_filter`: the train split's 404 requests next to the requests of the
185 answers teacher_sample.py kept: planted stale facts per request, the share
of requests with one, the share whose planted facts no candidate can support
taking out, and the share of each candidate kind.
"""

from __future__ import annotations

import json
from collections import Counter

import stored as S


def confusion(name: str, answered: list[S.Answered]) -> None:
    got_by_kind: dict[S.Kind, Counter[str]] = {k: Counter() for k in S.KINDS}
    pointed: Counter[str] = Counter()
    for item, answer in answered:
        if answer is None:
            continue
        got = S.V.outcomes(answer)
        stale = S.planted(item)
        for label in S.candidates(item):
            outcome, claim = got[str(label["request_id"])]
            right_word = outcome == label["outcome"]
            wrong_claim = right_word and not S.V.claim_matches(label, claim, answer)
            got_by_kind[S.kind(label)][outcome + ("/wrong_claim" if wrong_claim else "")] += 1
            if S.kind(label) == "transient" and outcome == "already_represented":
                ids = S.ids_of(item, claim)
                if ids & stale:
                    pointed["planted_stale_kept" if not ids & S.V.removed(answer) else "planted_stale_removed"] += 1
                elif ids:
                    pointed["other_current_fact"] += 1
                else:
                    pointed["claim_the_answer_adds"] += 1
    print(json.dumps({
        "answers": name, "valid": sum(a is not None for _, a in answered),
        "confusion": {k: dict(sorted(c.items())) for k, c in got_by_kind.items()},
        "transient_answered_already_represented": dict(sorted(pointed.items())),
    }))


def shares(items: list[S.V.SynthItem]) -> S.JsonObject:
    kinds = Counter(S.kind(c) for item in items for c in S.candidates(item))
    total = sum(kinds.values())
    with_planted = [item for item in items if S.planted(item)]
    return {
        "requests": len(items),
        "planted_per_request": round(sum(len(S.planted(i)) for i in items) / len(items), 2),
        "with_planted": round(len(with_planted) / len(items), 2),
        "planted_without_support": round(sum(not S.supported(i) for i in with_planted) / len(items), 2),
        "candidate_kinds": {k: round(kinds[k] / total, 2) for k in S.KINDS},
    }


def main() -> None:
    confusion("base effort low, pinned E-synth", S.base_synth())
    confusion("teacher effort high, train split attempts", [(item, chk.answer) for item, _, chk in S.teacher()])
    train = S.synth(S.TRAIN)
    kept = sorted({item.item_id for item, _ in S.accepted()})
    print(json.dumps({"teacher_filter": {"train_split": shares(list(train.values())),
                                         "kept_for_training": shares([train[i] for i in kept])}}))


main()
