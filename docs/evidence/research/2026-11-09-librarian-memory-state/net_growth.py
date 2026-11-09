# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""How much one admission grows memory: claims added minus facts taken out. Prints numbers only.

    cd <checkout of tinker/librarian-drop-adjudication at 365233db560b>
    MASC_BASE_PATH=<base> PYTHONDONTWRITEBYTECODE=1 uv run <this folder>/net_growth.py

E-real records are read in place from the store under MASC_BASE_PATH, as
`eval_admission.real_items` reads them. Nothing from them is printed but counts.

- added: distinct claims an answer adds. taken_out: distinct memory IDs it drops
  or absorbs (`eval_admission.removed`). net: (added - taken_out) per answer.
- live: the answer MASC committed for the record. base: the base model (effort
  low) on the same prompt, valid answers only; `live_on_the_same` is the live
  answer on the records where the base model answered validly.
- E-synth label: what the label asks for, per request. It adds a claim for each
  incorporated candidate and takes out the planted stale facts and correction
  targets, also the planted facts no candidate can support taking out.
- live_without_support: live answers with no incorporated or already_represented
  judgment. MASC keeps memory as it is on them (`verify_support`).
"""

from __future__ import annotations

import json
from typing import cast

import stored as S


def growth(answers: list[S.AV.AdmissionAnswer]) -> S.JsonObject:
    added = sum(len(set(a.added_claims)) for a in answers)
    out = sum(len(S.V.removed(a)) for a in answers)
    return {"answers": len(answers), "added": added, "taken_out": out,
            "net_per_answer": round((added - out) / len(answers), 2)}


def absorbs(answers: list[S.AV.AdmissionAnswer]) -> S.JsonObject:
    return {"answers_with_absorbs": sum(bool(a.absorbed) for a in answers),
            "absorbed_ids": sum(len({mid for mid, _ in a.absorbed}) for a in answers),
            "dropped_ids": sum(len(set(a.dropped)) for a in answers)}


def unsupported(answers: list[S.AV.AdmissionAnswer]) -> int:
    """Answers with no judgment that can support a memory change, so MASC kept memory as it was."""
    return sum(not any(j.outcome in S.SUPPORTING for j in a.judgments) for a in answers)


def main() -> None:
    real = S.real()
    live = [item.live for item in real.values()]
    print(json.dumps({"set": "E-real", "live": growth(live), "live_absorbs": absorbs(live),
                      "live_without_support": unsupported(live),
                      "live_changed_memory": sum(bool(a.added_claims or a.dropped or a.absorbed) for a in live)}))
    base_real: list[tuple[S.V.RealItem, S.AV.AdmissionAnswer]] = []
    for item_id, call in sorted(S.measured(S.BASE_REAL, "real", "base").items()):
        answer = S.V.check(real[item_id].prompt, call.answer()).answer
        if answer is not None:
            base_real.append((real[item_id], answer))
    scores = [S.V.score_real(item, answer) for item, answer in base_real]
    print(json.dumps({"set": "E-real", "base": growth([a for _, a in base_real]),
                      "live_on_the_same": growth([item.live for item, _ in base_real]),
                      "base_absorbs": absorbs([a for _, a in base_real]),
                      "base_dropped_not_in_live": sum(len(cast(list[str], s["dropped_not_in_live"])) for s in scores),
                      "base_absorbed_not_in_live": sum(len(cast(list[str], s["absorbed_not_in_live"]))
                                                       for s in scores)}))
    synth = list(S.synth(S.E_SYNTH).values())
    asked_add = sum(c["outcome"] == "incorporated" for item in synth for c in S.candidates(item))
    asked_out = sum(len(S.planted(item) | S.targets(item)) for item in synth)
    base_synth = [a for _, a in S.base_synth() if a is not None]
    print(json.dumps({"set": "pinned E-synth", "label": {"requests": len(synth), "added": asked_add,
                                                         "taken_out": asked_out,
                                                         "net_per_request": round((asked_add - asked_out) / len(synth), 2)},
                      "base": growth(base_synth)}))


main()
