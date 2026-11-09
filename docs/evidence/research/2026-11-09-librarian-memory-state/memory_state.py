# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Score E-synth answers by the memory they leave, next to the outcome word. Prints numbers only.

    cd <checkout of tinker/librarian-drop-adjudication at 365233db560b>
    PYTHONDONTWRITEBYTECODE=1 uv run <this folder>/memory_state.py

Answers: the base model's (effort low) on the pinned E-synth 119, and every
teacher attempt (effort high) on the train split. Answers MASC's checks refuse
are left out, and each line says how many are left. A candidate "adds" when its
outcome is incorporated and its claim is one the answer adds. Its memory is
right when:
- new: it adds.
- corrects: it adds, and the label's target leaves memory (dropped or absorbed).
- restates: without a new claim, the original fact survives or is absorbed into
  a final claim. A new claim it adds must absorb that original fact.
- transient: it adds nothing.
The outcome word is right when the outcome is the label's and
`eval_admission.claim_matches` holds, as G3 scores it. A planted stale fact is
counted as dropped, absorbed or kept. librarian.md 133-135 asks for a drop.
`corrects` sorts the correction candidates by whether they add and where the
label's target went.
"""

from __future__ import annotations

import json
from collections import Counter

import stored as S


def rewrite_absorbs_target(item: S.V.SynthItem, label: S.JsonObject, claim: str | None,
                           answer: S.AV.AdmissionAnswer) -> bool:
    restated = S.ids_of(item, label.get("already_claim"))
    return any(mid in restated and into == claim for mid, into in answer.absorbed)


def score(name: str, answered: list[S.Answered]) -> None:
    n: Counter[S.Kind] = Counter()
    word: Counter[S.Kind] = Counter()
    memory: Counter[S.Kind] = Counter()
    stale: Counter[str] = Counter()
    absorbs: Counter[str] = Counter()
    rewrites: Counter[str] = Counter()
    corrections: Counter[str] = Counter()
    valid = 0
    for item, answer in answered:
        if answer is None:
            continue
        valid += 1
        got = S.V.outcomes(answer)
        removed = S.V.removed(answer)
        absorbed = {mid for mid, _ in answer.absorbed}
        planted, targets = S.planted(item), S.targets(item)
        absorbs["answers_with_absorbs"] += bool(absorbed)
        absorbs["absorbed_ids"] += len(absorbed)
        absorbs["planted"] += len(absorbed & planted)
        absorbs["targets"] += len(absorbed & targets)
        absorbs["other"] += len(absorbed - planted - targets)
        for label in S.candidates(item):
            k = S.kind(label)
            outcome, claim = got[str(label["request_id"])]
            adds = outcome == "incorporated" and claim in answer.added_claims
            match k:
                case "new":
                    right = adds
                case "corrects":
                    target = label["supersedes"]
                    fate = "dropped" if target in answer.dropped else "absorbed" if target in removed else "kept"
                    corrections[f"{'adds' if adds else 'adds_nothing'}/target_{fate}"] += 1
                    right = adds and target in removed
                case "restates":
                    rewrite = claim in answer.added_claims and rewrite_absorbs_target(item, label, claim, answer)
                    rewrites["adds"] += adds
                    rewrites["absorbs_target"] += adds and rewrite
                    restated = S.ids_of(item, label.get("already_claim"))
                    kept = bool(restated - removed)
                    merged = any(mid in restated and into in answer.added_claims for mid, into in answer.absorbed)
                    right = rewrite if adds else kept or merged
                case "transient":
                    right = not adds
            n[k] += 1
            word[k] += outcome == label["outcome"] and S.V.claim_matches(label, claim, answer)
            memory[k] += right
        for mid in planted:
            stale["dropped" if mid in answer.dropped else "absorbed" if mid in absorbed else "kept"] += 1
    total = sum(n.values())
    print(json.dumps({
        "answers": name, "requests": len(answered), "valid": valid,
        "word": round(sum(word.values()) / total, 3), "memory": round(sum(memory.values()) / total, 3),
        "by_kind": {k: {"n": n[k], "word": round(word[k] / n[k], 3), "memory": round(memory[k] / n[k], 3),
                        "memory_wrong": n[k] - memory[k]} for k in S.KINDS},
        "planted_stale": {s: stale[s] for s in ("dropped", "absorbed", "kept")},
        "absorbs": {"answers": valid, **absorbs},
        "restates_that_add": {"n": rewrites["adds"], "absorb_the_restated_fact": rewrites["absorbs_target"]},
        "corrects": dict(corrections.most_common()),
    }))


def main() -> None:
    score("base effort low, pinned E-synth", S.base_synth())
    score("teacher effort high, train split attempts", [(item, chk.answer) for item, _, chk in S.teacher()])
    kept = S.accepted()
    print(json.dumps({"answers": "teacher answers kept for training", "n": len(kept),
                      "with_absorbs": sum(bool(a.absorbed) for _, a in kept)}))


main()
