# pyright: strict
"""Plans for the candidates of one synthetic split, made before any model call.

A label must leave no mark in what a candidate carries besides its meaning.
Drawing each candidate's traits on its own left that to chance: the 11-09
training split gave paraphrases a PR/issue/task number 53 times in 84
(planned share 0.403, binomial tail 2e-5) while the other kinds stayed at
0.37 to 0.44. So `plan_candidates` first draws every request's kinds, then
deals each trait out within each kind: a date, a time given a date, a number,
a Board post, the date and number formats, and the planned length. Every kind
then carries each trait at the measured share, off by less than one candidate,
and its planned lengths follow `CANDIDATE_CLAIM_CHARS` band by band.

The model's own lengths depended on the kind: asked for the same lengths,
it wrote new facts at a median of 489 chars and paraphrases at 717, because
a paraphrase follows its target (correlation 0.50). The live candidates do
not differ that way: already_represented 679, incorporated 741, not_durable
738. So a written candidate counts only when its length stays within
CANDIDATE_LENGTH_BAND of its plan, and a correction or a paraphrase targets
a fact that can be restated at its planned length.

Pure code: no I/O, no clock, no global random state.
"""

from __future__ import annotations

import datetime as dt
import math
import random
from dataclasses import dataclass

import synth_spec as S

# A written candidate is kept when its length is within these factors of the plan.
CANDIDATE_LENGTH_BAND = (0.75, 1.33)


@dataclass(frozen=True, slots=True)
class DatePlan:
    form: S.DateFormat
    timed: bool


@dataclass(frozen=True, slots=True)
class CandidatePlan:
    """What one candidate carries before the model writes it."""

    kind: S.CandidateKind
    length: int
    date: DatePlan | None
    reference: S.ReferenceFormat | None
    board: bool


def deck[T](rng: random.Random, n: int, weights: tuple[tuple[T, float], ...]) -> list[T]:
    """n values in random order, each as near its share of n as whole counts allow.

    Whole counts come from rounding down; the remaining places go to the
    largest remainders, the first value winning a tie.
    """
    total = sum(w for _, w in weights)
    exact = [n * w / total for _, w in weights]
    counts = [math.floor(x) for x in exact]
    by_remainder = sorted(range(len(weights)), key=lambda i: counts[i] - exact[i])
    for i in by_remainder[: n - sum(counts)]:
        counts[i] += 1
    values = [value for (value, _), count in zip(weights, counts, strict=True) for _ in range(count)]
    rng.shuffle(values)
    return values


def flags(rng: random.Random, n: int, share: float) -> list[bool]:
    return deck(rng, n, ((True, share), (False, 1 - share)))


def dealt_lengths(rng: random.Random, n: int) -> list[int]:
    """n planned lengths in random order, the i-th smallest drawn inside the i-th of n equal quantile bands."""
    lengths = [int(round(S.value_at(S.CANDIDATE_CLAIM_CHARS, (i + rng.random()) / n), -1)) for i in range(n)]
    rng.shuffle(lengths)
    return lengths


def plans_of_kind(rng: random.Random, kind: S.CandidateKind, n: int) -> list[CandidatePlan]:
    shares = S.CANDIDATE_SURFACE
    dated = flags(rng, n, shares.date)
    n_dated = sum(dated)
    timed = iter(flags(rng, n_dated, shares.time_given_date))
    form_deck: list[S.DateFormat] = deck(rng, n_dated, S.DATE_FORMAT_WEIGHTS)
    forms = iter(form_deck)
    cited = flags(rng, n, shares.reference)
    number_deck: list[S.ReferenceFormat] = deck(rng, sum(cited), S.REFERENCE_FORMAT_WEIGHTS)
    numbers = iter(number_deck)
    board = flags(rng, n, S.CANDIDATE_BOARD_SHARE)
    return [CandidatePlan(kind, length, DatePlan(next(forms), next(timed)) if has_date else None,
                          next(numbers) if has_number else None, on_board)
            for length, has_date, has_number, on_board in zip(dealt_lengths(rng, n), dated, cited, board, strict=True)]


def plan_candidates(rng: random.Random, n_requests: int) -> tuple[tuple[CandidatePlan, ...], ...]:
    """Each request's candidate plans, in order. Kinds are drawn per candidate; the traits are dealt per kind."""
    kinds = [[S.sample_weighted(rng, S.CANDIDATE_KIND_WEIGHTS)
              for _ in range(S.sample_weighted(rng, S.CANDIDATES_PER_REQUEST_WEIGHTS))]
             for _ in range(n_requests)]
    dealt = {kind: iter(plans_of_kind(rng, kind, sum(row.count(kind) for row in kinds))) for kind in S.CandidateKind}
    return tuple(tuple(next(dealt[kind]) for kind in row) for row in kinds)


def candidate_surface(rng: random.Random, plan: CandidatePlan, when: dt.datetime) -> S.Surface:
    """The exact marks of a candidate seen at `when`."""
    number = S.reference_text(rng, plan.reference) if plan.reference is not None else None
    if plan.date is None:
        return S.Surface(None, None, number)
    return S.Surface(S.date_text(when, plan.date.form), when.strftime("%H:%M") if plan.date.timed else None, number)


def length_holds(claim: str, planned: int) -> bool:
    low, high = CANDIDATE_LENGTH_BAND
    return low * planned <= len(claim) <= high * planned


def target_near(rng: random.Random, facts: list[S.MemoryFact], planned: int) -> S.MemoryFact:
    """A fact to correct or restate in about `planned` chars: one whose own length fits the band, else the nearest."""
    near = [f for f in facts if length_holds(f.claim, planned)]
    if near:
        return rng.choice(near)
    return min(facts, key=lambda f: abs(math.log(len(f.claim) / planned)))
