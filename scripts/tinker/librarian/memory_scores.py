# pyright: strict
"""Score one admission answer: E-real against the live answer, E-synth by the memory it leaves.

Pure code. `eval_admission.py` runs the calls, writes one row per answer from
these scores and sums the rows.

E-synth: a candidate counts as right when the memory the answer leaves is the
one its label kind needs (`state_ok`).

| kind | right when |
| --- | --- |
| new | incorporated, naming a claim the answer adds |
| corrects | as new, and the target leaves by `dropped` or absorbed |
| complements | as new, and the target is absorbed into that claim |
| restates | already_represented, or a claim the answer adds absorbs the target |
| transient | not_durable or already_represented: nothing is added for it |

The outcome with the claim it names (`claim_matches`) stays in the rows as a
record. A planted stale fact leaves by `dropped`: config/prompts/librarian.md
133-135 rules out absorbing a stale state. A duplicate pair ends as one fact:
one stays and the other is absorbed into its claim, or both go into one claim.
The drops a label asks for take out planted stale facts and correction
targets. A complement target or a fact of a duplicate pair is to be absorbed,
so dropping it goes against the label too. Any other drop is off label, and a
blind judge classifies it at verdict time (`audit_decisions`). Growth is the
claims an answer adds minus the memory IDs it takes out, beside the label's.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from types import MappingProxyType
from typing import Literal, assert_never

import admission_request as R
import admission_validator as AV
import prompt_facts as PF
import synth_spec as S

type JsonObject = dict[str, object]
type Kind = Literal["new", "corrects", "complements", "restates", "transient"]
KINDS: tuple[Kind, ...] = ("new", "corrects", "complements", "restates", "transient")


@dataclass(frozen=True, slots=True)
class RealItem:
    item_id: str
    prompt: R.AdmissionPrompt
    text: str
    live: AV.AdmissionAnswer


@dataclass(frozen=True, slots=True)
class SynthItem:
    item_id: str
    prompt: R.AdmissionPrompt
    text: str
    label: S.RequestLabel


@dataclass(frozen=True, slots=True)
class Left:
    """What an answer does to current memory: the claims it adds, the IDs it drops, each absorbed
    ID with the claim it went into, and the claims of final memory."""

    added: frozenset[str]
    dropped: frozenset[str]
    absorbed: Mapping[str, str]
    after: frozenset[str]


# A refused answer changes nothing, so no check finds what it looks for.
REFUSED = Left(frozenset(), frozenset(), MappingProxyType({}), frozenset())


def left_of(answer: AV.AdmissionAnswer) -> Left:
    return Left(frozenset(answer.added_claims), frozenset(answer.dropped), MappingProxyType(dict(answer.absorbed)),
                frozenset(answer.memory_after))


def outcomes(answer: AV.AdmissionAnswer) -> dict[str, tuple[str, str | None]]:
    return {j.request_id: (j.outcome, j.memory_claim) for j in answer.judgments}


def removed(answer: AV.AdmissionAnswer) -> set[str]:
    """Memory IDs the answer takes out of current memory: dropped, or absorbed into a new claim."""
    return set(answer.dropped) | {mid for mid, _ in answer.absorbed}


def score_real(item: RealItem, mine: AV.AdmissionAnswer | None) -> JsonObject:
    live = outcomes(item.live)
    got = outcomes(mine) if mine is not None else {}
    gone = removed(item.live)
    return {"candidates": len(live), "agree": sum(got.get(k, ("",))[0] == v[0] for k, v in live.items()),
            "outcomes": {k: [v[0], got.get(k, ("",))[0]] for k, v in live.items()},
            "dropped_not_in_live": sorted(set(mine.dropped) - gone) if mine is not None else [],
            "absorbed_not_in_live": sorted({mid for mid, _ in mine.absorbed} - gone) if mine is not None else [],
            "live_added": len(set(item.live.added_claims)), "live_removed": len(gone),
            "added": len(set(mine.added_claims)) if mine is not None else 0,
            "removed": len(removed(mine)) if mine is not None else 0}


def kind_of(label: S.CandidateLabel) -> Kind:
    match label.outcome:
        case "incorporated":
            return "corrects" if label.supersedes is not None else "complements" if label.absorbs is not None else "new"
        case "already_represented":
            return "restates"
        case "not_durable":
            return "transient"
        case _:
            assert_never(label.outcome)


def claim_matches(label: S.CandidateLabel, claim: str | None, answer: AV.AdmissionAnswer) -> bool:
    """Whether a judgment's `memory_claim` points where the label's kind needs it.
    MASC accepts any claim of final memory, so an outcome alone can name the wrong one."""
    target = label.supersedes
    match label.outcome:
        case "incorporated" if target is not None:
            supersedes = {new: old for old, new in answer.revisions}
            return claim is not None and supersedes.get(claim) == target and target in answer.dropped
        case "incorporated":
            return claim is not None and claim in answer.added_claims
        case "already_represented":
            return claim == label.already_claim
        case "not_durable":
            return True
        case _:
            assert_never(label.outcome)


def state_ok(label: S.CandidateLabel, outcome: str, claim: str | None, left: Left, ids: Mapping[str, str]) -> bool:
    """Whether the memory the answer leaves is the one the candidate's label kind needs."""
    new_claim = outcome == "incorporated" and claim is not None and claim in left.added
    match kind_of(label):
        case "new":
            return new_claim
        case "corrects":
            target = label.supersedes
            return new_claim and target is not None and (target in left.dropped or target in left.absorbed)
        case "complements":
            return new_claim and label.absorbs is not None and left.absorbed.get(label.absorbs) == claim
        case "restates":
            restated = ids.get(label.already_claim) if label.already_claim is not None else None
            return (outcome == "already_represented" and label.already_claim in left.after) or (
                new_claim and restated is not None and left.absorbed.get(restated) == claim)
        case "transient":
            return outcome in ("not_durable", "already_represented")


def left_one(a: str, b: str, claims: Mapping[str, str], left: Left) -> bool:
    """Whether a duplicate pair ends as one fact: one stays and the other went into its claim, or
    both went into one claim."""
    into_a, into_b = left.absorbed.get(a), left.absorbed.get(b)
    return ((claims[a] in left.after and into_b == claims[a]) or (claims[b] in left.after and into_a == claims[b])
            or (into_a is not None and into_a == into_b))


def fact_claims(prompt: R.AdmissionPrompt) -> dict[str, str]:
    """Current memory by the short IDs the prompt shows."""
    facts = prompt.current_memory.facts if prompt.current_memory is not None else ()
    return {PF.surrogate_id(i): f.claim for i, f in enumerate(facts)}


def score_synth(item: SynthItem, mine: AV.AdmissionAnswer | None) -> JsonObject:
    label = item.label
    claims = fact_claims(item.prompt)
    ids = {claim: mid for mid, claim in claims.items()}
    planted = set(label.planted_stale)
    corrected = {c.supersedes for c in label.candidates if c.supersedes is not None}
    complemented = {c.absorbs for c in label.candidates if c.absorbs is not None}
    paired = {mid for pair in label.duplicates for mid in pair}
    restated = {ids[c.already_claim] for c in label.candidates if c.already_claim is not None and c.already_claim in ids}
    left = left_of(mine) if mine is not None else REFUSED
    got = outcomes(mine) if mine is not None else {}
    word: dict[str, bool] = {}
    by_kind: dict[Kind, list[int]] = {kind: [0, 0] for kind in KINDS}
    for c in label.candidates:
        outcome, claim = got.get(c.request_id, ("", None))
        word[c.request_id] = mine is not None and outcome == c.outcome and claim_matches(c, claim, mine)
        tally = by_kind[kind_of(c)]
        tally[0] += 1
        tally[1] += mine is not None and state_ok(c, outcome, claim, left, ids)
    # The class of each absorbed ID, for the merge judge: what the label says of that fact.
    labeled = ({m: "correction" for m in corrected} | {m: "paraphrase" for m in restated}
               | {m: "complement" for m in complemented} | {m: "duplicate" for m in paired}
               | {m: "stale" for m in planted})
    asked, merged = planted | corrected, complemented | paired
    pairs_merged = sum(left_one(a, b, claims, left) for a, b in label.duplicates)
    return {"candidates": len(label.candidates), "correct": sum(word.values()), "per_candidate": word,
            "state_correct": sum(ok for _, ok in by_kind.values()),
            "state_by_kind": {kind: tally for kind, tally in by_kind.items() if tally[0]},
            "dropped": len(left.dropped), "dropped_expected": len(left.dropped & asked),
            "dropped_unmerged": sorted(left.dropped & merged), "dropped_off_label": sorted(left.dropped - asked - merged),
            "absorbed": len(left.absorbed), "absorbs": {mid: labeled.get(mid, "other") for mid in sorted(left.absorbed)},
            "planted": len(planted), "planted_dropped": len(left.dropped & planted),
            "planted_absorbed": len(planted & left.absorbed.keys()),
            "pairs": len(label.duplicates), "pairs_merged": pairs_merged,
            "merges": len(complemented) + len(label.duplicates), "merges_done": by_kind["complements"][1] + pairs_merged,
            "added": len(left.added), "removed": len(left.dropped | left.absorbed.keys()),
            "expected_added": sum(c.outcome == "incorporated" for c in label.candidates),
            "expected_removed": len(corrected) + len(complemented) + len(planted) + len(label.duplicates)}
