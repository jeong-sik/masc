# pyright: strict
"""Score one admission answer: E-real against the live answer, E-synth by the memory it leaves.

Pure code. `eval_admission.py` runs the calls, writes one row per answer from
these scores and sums the rows.

E-synth: a candidate counts as right when the memory the answer leaves is the
one its label kind needs (`state_ok`). A candidate adds a claim when it is
judged incorporated and names a claim the answer adds that is not another
candidate's text: a claim that copies a candidate word for word carries that
candidate's knowledge (`synth_rows` gives every candidate its own text). A
candidate whose own text the answer adds under another judgment is right for
no kind: its knowledge sits where its judgment does not say.

| kind | right when |
| --- | --- |
| new | it adds a claim |
| corrects | it adds a claim, and the target is dropped or absorbed into that claim |
| complements | it adds a claim, and the target is absorbed into that claim |
| restates | it adds a claim that absorbs the restated fact; or it adds none, and the fact stays or is absorbed into a claim the answer adds |
| transient | it adds no claim |

A candidate the answer leaves unjudged or defers is right for no kind: nothing
about it is settled. A claim already in memory keeps its text when it absorbs
a fact, so only a fact that says the same can go into it. A duplicate pair
ends as one fact: one fact goes into the other's claim, or both go into one
claim the answer adds. A planted stale fact leaves by `dropped`:
config/prompts/librarian.md 133-135 rules out absorbing a stale state. The
outcome with the claim it names (`claim_matches`) stays in the rows as a record.

A drop of a planted stale fact or a correction target is right. A complement
target or a fact of a duplicate pair is to be absorbed, so dropping it goes
against the label. Any other drop is off label, and a blind judge classifies it
at verdict time (`audit_decisions`). These follow what each fact is. Stale
drop recall, pair merges, the label's growth and the records with a use time
count on every request: MASC takes drops and merges without a supporting
candidate (RFC-0517 §7.1). Growth is the claims an answer adds minus the memory
IDs it takes out, beside the label's. A record still ahead is to stay, so its
drop is the loss this counts on its own besides the off-label drop it also is,
and a record already past is one of the planted stale facts, counted on its own
as well.

Text comparison cannot tell whether a merge keeps the knowledge it absorbs.
A row names, for each merge the label expects and the answer made, the memory
IDs it absorbed, and the class of each absorbed ID; a blind judge classifies
the absorbs at verdict time (`merge_decisions`).
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
    ID with the claim it went into, each superseded ID with the claim that supersedes it, and the
    claims of final memory."""

    added: frozenset[str]
    dropped: frozenset[str]
    absorbed: Mapping[str, str]
    revisions: frozenset[tuple[str, str]]
    after: frozenset[str]


# A refused answer changes nothing and judges no candidate, so no check finds what it looks for.
REFUSED = Left(frozenset(), frozenset(), MappingProxyType({}), frozenset(), frozenset())


def left_of(answer: AV.AdmissionAnswer) -> Left:
    return Left(frozenset(answer.added_claims), frozenset(answer.dropped), MappingProxyType(dict(answer.absorbed)),
                frozenset(answer.revisions), frozenset(answer.memory_after))


def judgments_of(answer: AV.AdmissionAnswer | None) -> dict[str, AV.Judgment]:
    """Each judgment by its request ID. A refused answer judges nothing."""
    return {j.request_id: j for j in answer.judgments} if answer is not None else {}


def removed(answer: AV.AdmissionAnswer) -> set[str]:
    """Memory IDs the answer takes out of current memory: dropped, or absorbed into a new claim."""
    return set(answer.dropped) | {mid for mid, _ in answer.absorbed}


def score_real(item: RealItem, mine: AV.AdmissionAnswer | None) -> JsonObject:
    live = judgments_of(item.live)
    said = {k: j.outcome for k, j in judgments_of(mine).items()}
    gone = removed(item.live)
    return {"candidates": len(live), "agree": sum(said.get(k) == j.outcome for k, j in live.items()),
            "outcomes": {k: [j.outcome, said.get(k)] for k, j in live.items()},
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


def claim_matches(label: S.CandidateLabel, claim: str | None, left: Left, others: frozenset[str]) -> bool:
    """Whether a judgment's `memory_claim` points where the label's kind needs it.
    MASC accepts any claim of final memory, so an outcome alone can name the wrong one. An
    incorporated candidate names a claim the answer adds that is not another candidate's text
    (`others`); a correction's claim also supersedes its target. MASC refuses a `supersedes` whose
    target is not dropped."""
    match label.outcome:
        case "incorporated" if label.supersedes is not None:
            return (label.supersedes, claim) in left.revisions and claim in left.added and claim not in others
        case "incorporated":
            return claim in left.added and claim not in others
        case "already_represented":
            return claim == label.already_claim
        case "not_durable":
            return True
        case _:
            assert_never(label.outcome)


def state_ok(label: S.CandidateLabel, judgment: AV.Judgment | None, left: Left, ids: Mapping[str, str],
             own: str, others: frozenset[str]) -> bool:
    """Whether the memory the answer leaves is the one the candidate's label kind needs. `own` is the
    candidate's text and `others` the texts of the request's other candidates."""
    if judgment is None or judgment.outcome == "deferred":
        return False
    claim = judgment.memory_claim
    added = judgment.outcome == "incorporated" and claim in left.added and claim not in others
    if own in left.added and not (added and claim == own):
        return False
    match kind_of(label):
        case "new":
            return added
        case "corrects":
            target = label.supersedes
            return added and target is not None and (target in left.dropped or left.absorbed.get(target) == claim)
        case "complements":
            return added and label.absorbs is not None and left.absorbed.get(label.absorbs) == claim
        case "restates":
            restated = ids.get(label.already_claim) if label.already_claim is not None else None
            if restated is None:
                return False
            into = left.absorbed.get(restated)
            return into == claim if added else label.already_claim in left.after or into in left.added
        case "transient":
            return not added


def left_one(a: str, b: str, claims: Mapping[str, str], left: Left) -> bool:
    """Whether a duplicate pair ends as one fact: one went into the other's claim, or both went
    into one claim the answer adds. MASC keeps a fact whose claim another fact went into."""
    into_a, into_b = left.absorbed.get(a), left.absorbed.get(b)
    return (into_b == claims[a] or into_a == claims[b]
            or (into_a is not None and into_a == into_b and into_a in left.added))


def fact_claims(prompt: R.AdmissionPrompt) -> dict[str, str]:
    """Current memory by the short IDs the prompt shows."""
    facts = prompt.current_memory.facts if prompt.current_memory is not None else ()
    return {PF.surrogate_id(i): f.claim for i, f in enumerate(facts)}


def score_synth(item: SynthItem, mine: AV.AdmissionAnswer | None) -> JsonObject:
    label = item.label
    claims = fact_claims(item.prompt)
    ids = {claim: mid for mid, claim in claims.items()}
    texts = {c.request_id: c.proposed_fact.claim for c in item.prompt.candidates}
    stale = set(label.planted_stale)
    pairs, ahead, past = label.duplicates, label.scheduled_ahead, label.scheduled_past
    corrected = {c.supersedes for c in label.candidates if c.supersedes is not None}
    complemented = {c.absorbs for c in label.candidates if c.absorbs is not None}
    paired = {mid for pair in label.duplicates for mid in pair}
    restated = {ids[c.already_claim] for c in label.candidates if c.already_claim is not None and c.already_claim in ids}
    left = left_of(mine) if mine is not None else REFUSED
    got = judgments_of(mine)
    word: dict[str, bool] = {}
    by_kind: dict[Kind, list[int]] = {kind: [0, 0] for kind in KINDS}
    # For each merge the label expects and the answer made, the memory IDs it absorbed.
    complements_done: list[list[str]] = []
    for c in label.candidates:
        judgment = got.get(c.request_id)
        own = texts[c.request_id]
        others = frozenset(texts.values()) - {own}
        word[c.request_id] = (judgment is not None and judgment.outcome == c.outcome
                              and claim_matches(c, judgment.memory_claim, left, others))
        tally = by_kind[kind_of(c)]
        tally[0] += 1
        ok = state_ok(c, judgment, left, ids, own, others)
        tally[1] += ok
        if ok and kind_of(c) == "complements" and c.absorbs is not None:
            complements_done.append([c.absorbs])
    pairs_done = [sorted({a, b} & left.absorbed.keys()) for a, b in pairs if left_one(a, b, claims, left)]
    # The class of each absorbed ID, for the merge judge: what the label says of that fact.
    labeled = ({m: "correction" for m in corrected} | {m: "paraphrase" for m in restated}
               | {m: "complement" for m in complemented} | {m: "duplicate" for m in paired}
               | {m: "stale" for m in stale})
    asked, merged = stale | corrected, complemented | paired
    return {"candidates": len(label.candidates), "correct": sum(word.values()), "per_candidate": word,
            "state_correct": sum(ok for _, ok in by_kind.values()),
            "state_by_kind": {kind: tally for kind, tally in by_kind.items() if tally[0]},
            "dropped": len(left.dropped), "dropped_expected": len(left.dropped & asked),
            "dropped_unmerged": sorted(left.dropped & merged), "dropped_off_label": sorted(left.dropped - asked - merged),
            "absorbed": len(left.absorbed), "absorbs": {mid: labeled.get(mid, "other") for mid in sorted(left.absorbed)},
            "planted": len(stale), "planted_dropped": len(left.dropped & stale),
            "planted_absorbed": len(stale & left.absorbed.keys()),
            "scheduled_ahead": len(ahead), "scheduled_ahead_dropped": len(left.dropped & ahead),
            "scheduled_past": len(past), "scheduled_past_dropped": len(left.dropped & past),
            "pairs": len(pairs), "pairs_merged": len(pairs_done),
            "merges": len(complemented) + len(pairs), "merges_done": len(complements_done) + len(pairs_done),
            "merges_absorbed": complements_done + pairs_done,
            "added": len(left.added), "removed": len(left.dropped | left.absorbed.keys()),
            "expected_added": sum(c.outcome == "incorporated" for c in label.candidates),
            "expected_removed": len(corrected) + len(complemented) + len(stale) + len(pairs)}
