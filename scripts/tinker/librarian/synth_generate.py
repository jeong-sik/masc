# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Generate synthetic Keeper memories and admission candidates with a Tinker model.

Run from the repository root:

    uv run scripts/tinker/librarian/synth_generate.py --split eval --seed 20261109 \
        --out artifacts/tinker/librarian/synth-eval --budget 6

The seed fixes the plan: which Keepers, how many memories, fact counts,
categories, claim lengths, planted stale facts, records with a use time and
which side of the candidates that time falls on, candidate kinds and targets,
and the date, time and number each claim carries (`synth_spec.py`). The
candidates of the whole split are planned before any call, with their marks
and lengths dealt out per label kind (`synth_candidate_plan.py`). A planted
stale fact or a record is written in the same call as the durable facts of its
category; the model is told a record's kind, never which side it is on.
DUPLICATE_PAIR_SHARE of the memories get a planted duplicate, dealt over the
split: after the other facts, the model restates one durable fact of the
planned category with the duplicate's own marks, near the length of that fact.
The model writes only text: role material, a world sheet, category names, a
goal, and claims; a claim whose marks differ from its plan, a claim that copies
a fact of its memory or an earlier candidate, a fact shorter than
FACT_LENGTH_FLOOR of its plan, or a candidate or duplicate whose length leaves
its band, is not kept. A facts answer whose items are not one text claim per
slot is refused whole and asked again: its claims cannot be matched to the
slots by position. summary.json counts the refused facts answers and the facts
left out, by reason. Every model call is cached in
<out>/calls.jsonl under a key derived from the request, so a rerun resumes and
pays only for calls that have no answer yet. Output: <out>/requests.jsonl (one
request per line; `synth_rows.label_of_row` reads its label) and <out>/summary.json.

A split can be made in more than one batch, each with its own seed.
`--first-memory` numbers a batch's memories from that number on, so a batch
that starts where the last one ended shares no memory key or item ID with it,
and the audited requests of the batches can go into one file.

TINKER_API_KEY comes from the environment and is never written.
"""

from __future__ import annotations

import argparse
import datetime as dt
import itertools
import json
import random
import sys
from collections import Counter
from collections.abc import Callable, Sequence, Set
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Protocol, assert_never, cast

import synth_candidate_plan as C
import synth_prompts as P
import synth_rows as RW
import synth_spec as S
from tinker_oai import Call, Caller

MODEL = "thinkingmachines/Inkling-2-Small"
ATTEMPTS = 3
# A candidate must also land in its length band. With 3 attempts, 17 of 260 training
# requests lost a candidate that way, 10 of them corrections (11-09).
CANDIDATE_ATTEMPTS = 5
WORKERS = 8
# The model writes shorter claims than asked, and shorter still when asked for many.
# 11-08 pilots, planned median 492 chars: 30 claims per call gave a median of 253;
# 8 per call at 1.3x the plan gave 391 (p90 944 for a planned 1,410), about 0.5 to
# 0.6 of the asked length. So a call asks for at most FACTS_PER_CALL claims, each
# LENGTH_ASK times the planned length.
FACTS_PER_CALL = 6
LENGTH_ASK = 1.7
# Share of a call's durable slots whose claims must come back with their marks.
DURABLE_KEEP_SHARE = 0.7
# A fact is kept only when it is at least this share of its planned length. The call logs of the
# training split (seed 20261114) and the second eval batch (seed 20261113), replayed: of 7,565
# claims written to a plan, p1 was 0.41 to 0.44 of the plan and the median 1.12 to 1.14. The
# shortest was "NaN", 3 chars for 470 (#51430); the next, a whole sentence, 0.117 (209 for 1,780).
# CANDIDATE_LENGTH_BAND would have left out 54 to 56 percent. No ceiling: the longest was 6,228
# bytes, under the 16,000 the librarian's absorb gate judges (keeper_librarian_absorb_gate.ml).
FACT_LENGTH_FLOOR = 0.1
EFFORT = {"profile": "medium", "facts": "low", "duplicate": "medium", "candidate": "medium"}
MAX_TOKENS = {"profile": 8192, "facts": 16384, "duplicate": 4096, "candidate": 4096}
# Measured role material: p10 716, p50 1,144, p90 2,684 chars.
ROLE_CHARS = ((0.0, 500.0), (0.1, 716.0), (0.5, 1144.0), (0.9, 2684.0), (1.0, 3400.0))
EXISTING_HEAD = 90
MEMORY_END = dt.datetime(2026, 11, 6, 23, 59, 59, tzinfo=dt.UTC)
CANDIDATE_TIME_START = dt.datetime(2026, 11, 7, tzinfo=dt.UTC)
# A request's candidates fall on 11-07 or, past midnight, 11-08 (`build_candidates`). A record
# still ahead is used on a later day, and one already past on a day of its memory, after it was
# written, so a claim that names only the date says which side it is on (`synth_rows.holds`).
USE_AHEAD_START = dt.datetime(2026, 11, 9, tzinfo=dt.UTC)
USE_AHEAD_DAYS = 4
USE_PAST_AFTER = dt.timedelta(hours=1)
SPLITS = {
    # split: (keepers, memories per keeper, requests)
    "eval": (tuple(k for k in S.KEEPER_SEEDS if k.key in S.EVAL_KEEPERS), 10, 150),
    # Sized on 11-09 for about 200 training examples, when the teacher kept 51 of 96 answered requests.
    "train": (tuple(k for k in S.KEEPER_SEEDS if k.key not in S.EVAL_KEEPERS), 9, 420),
}

# --- stages ------------------------------------------------------------------


class Asks(Protocol):
    """The one call the generator makes: `tinker_oai.Caller.ask`."""

    def ask(self, *, model: str, label: str, messages: Sequence[str], effort: str, max_tokens: int,
            attempt: int = 0) -> Call | None: ...


def ask(caller: Asks, stage: str, prompt: str, attempt: int) -> str | None:
    """The answer text, "" when the call failed or was cut off, None once the budget stops calls."""
    call = caller.ask(model=MODEL, label=stage, messages=[prompt], effort=EFFORT[stage],
                      max_tokens=MAX_TOKENS[stage], attempt=attempt)
    if call is None:
        return None
    return call.answer() or ""


def head(claim: str) -> str:
    return claim[:EXISTING_HEAD].replace("\n", " ")


def whole(claim: str) -> str:
    """A claim on one line of a prompt's list, all of it."""
    return claim.replace("\n", " ")


def listed(claims: Sequence[str], show: Callable[[str], str]) -> str:
    return "\n".join(f"- {show(c)}" for c in claims) or "(없음)"


def profile_of(caller: Asks, seed: S.KeeperSeed, rng: random.Random) -> S.KeeperProfile | None:
    role_chars = int(round(S.sample_quantile(rng, ROLE_CHARS), -2))
    prompt = P.PROFILE_PROMPT.format(seed=seed.seed, role_chars=role_chars, style=P.STYLE)
    for attempt in range(ATTEMPTS):
        answer = ask(caller, "profile", prompt, attempt)
        if answer is None:
            return None
        profile = S.parse_profile(answer, seed.key) if answer else None
        if profile is not None:
            return profile
    return None


@dataclass(frozen=True, slots=True)
class FactSlot:
    """One fact to write: its category, planned length, kind, the time it was seen, the date,
    time and number its text carries, and for a record with a use time that time."""

    category: str
    length: int
    stale: bool
    seen: dt.datetime
    surface: S.Surface
    use_at: dt.datetime | None


def planted(slot: FactSlot) -> bool:
    """A slot the plan counts on: a stale fact or a record with a use time."""
    return slot.stale or slot.use_at is not None


def text_kind(slot: FactSlot) -> P.FactText:
    return "scheduled" if slot.use_at is not None else "transient" if slot.stale else "durable"


@dataclass(frozen=True, slots=True)
class DuplicateSlot:
    """A planted duplicate: the category of the durable fact it restates, the time it was seen and
    the date, time and number its text carries."""

    category: str
    seen: dt.datetime
    surface: S.Surface


@dataclass(frozen=True, slots=True)
class MemoryPlan:
    memory_key: str
    keeper: S.KeeperProfile
    slots: tuple[FactSlot, ...]  # grouped by category, in writing order
    duplicate: DuplicateSlot | None
    seed: int


def memory_homes(keepers: Sequence[S.KeeperProfile], per_keeper: int, first: int) -> list[tuple[S.KeeperProfile, int]]:
    """Every memory of a batch: its Keeper and its number, `per_keeper` numbers from `first` on."""
    return [(keeper, first + i) for keeper in keepers for i in range(per_keeper)]


def plan_memory(rng: random.Random, keeper: S.KeeperProfile, index: int, duplicate: bool) -> MemoryPlan:
    """A planted stale fact lands in a category in proportion to its size, at a random place among
    the durable facts there, and draws its length, time and surface as a durable fact does. A
    record with a use time lands the same way; SCHEDULED_AHEAD_SHARE of them are used on a day
    after the candidates' and stay durable, the rest on a day of the memory after they were
    written and are planted stale. A record's text always carries its use date. A planted
    duplicate picks its category the same way and draws its own time and surface. A category's
    planted facts take the places of durable ones, so it never holds more than
    FACTS_PER_CATEGORY_CAP facts: the prompt prints a count over the cap (`memory_variables`), and
    only a planted fact would put one there."""
    n_facts = round(S.sample_quantile(rng, S.FACTS_PER_MEMORY))
    n_cats = min(len(keeper.categories), round(S.sample_quantile(rng, S.CATEGORIES_PER_MEMORY)))
    names = rng.sample(keeper.categories, n_cats)
    counts = S.allocate_counts(rng, n_facts, n_cats)
    names = names[: len(counts)]  # fewer facts than categories leaves the last categories empty
    stale_in = Counter(rng.choices(names, weights=counts, k=S.sample_weighted(rng, S.STALE_FACTS_PER_MEMORY_WEIGHTS)))
    scheduled_in = Counter(rng.choices(names, weights=counts,
                                       k=S.sample_weighted(rng, S.SCHEDULED_FACTS_PER_MEMORY_WEIGHTS)))
    pair_category = rng.choices(names, weights=counts)[0] if duplicate else None
    end = MEMORY_END - dt.timedelta(seconds=rng.randrange(86400))
    start = end - dt.timedelta(days=S.sample_quantile(rng, S.MEMORY_SPAN_DAYS))
    slots: list[FactSlot] = []
    for name, count in zip(names, counts, strict=True):
        plants = stale_in[name] + scheduled_in[name] + (name == pair_category)
        per_kind: tuple[tuple[P.FactText, int], ...] = (
            ("durable", min(count, S.FACTS_PER_CATEGORY_CAP - plants)), ("transient", stale_in[name]),
            ("scheduled", scheduled_in[name]))
        kinds: list[P.FactText] = [kind for kind, n in per_kind for _ in range(n)]
        rng.shuffle(kinds)
        for kind in kinds:
            match kind:
                case "durable" | "transient":
                    seen = between(rng, start, end)
                    length = int(round(S.sample_quantile(rng, S.CLAIM_CHARS), -1))
                    slots.append(FactSlot(name, length, kind == "transient", seen,
                                          S.plan_surface(rng, S.FACT_SURFACE, seen), None))
                case "scheduled":
                    ahead = rng.random() < S.SCHEDULED_AHEAD_SHARE
                    seen = between(rng, start, end if ahead else end - USE_PAST_AFTER)
                    use_at = (between(rng, USE_AHEAD_START, USE_AHEAD_START + dt.timedelta(days=USE_AHEAD_DAYS))
                              if ahead else between(rng, seen + USE_PAST_AFTER, end))
                    length = int(round(S.sample_quantile(rng, S.CLAIM_CHARS), -1))
                    slots.append(FactSlot(name, length, not ahead, seen,
                                          S.plan_use_surface(rng, S.FACT_SURFACE, use_at), use_at))
    pair: DuplicateSlot | None = None
    if pair_category is not None:
        seen = between(rng, start, end)
        pair = DuplicateSlot(pair_category, seen, S.plan_surface(rng, S.FACT_SURFACE, seen))
    return MemoryPlan(f"{keeper.key}-{index:02d}", keeper, tuple(slots), pair, rng.randrange(2**31))


def iso(t: dt.datetime) -> str:
    return t.strftime(RW.TIME_FORMAT)


def between(rng: random.Random, start: dt.datetime, end: dt.datetime) -> dt.datetime:
    return start + dt.timedelta(seconds=rng.randrange(int((end - start).total_seconds())))


class AnswerFault(Enum):
    """Why a facts answer is refused whole: its claims cannot be matched to the slots by position."""

    NOT_FACTS = "not_facts"  # not a JSON object holding a list under "facts"
    COUNT = "count"  # the list holds another number of items than the slots asked for
    CLAIM_NOT_TEXT = "claim_not_text"  # an item is not an object whose "claim" is a non-blank string


class ClaimMiss(Enum):
    """Why a claim of a readable facts answer is left out of its slot."""

    COPY = "copy"  # the text of a fact already written, or of an earlier claim of the answer
    MARKS = "marks"  # its date, time or number differs from its slot's surface
    SHORT = "short"  # under FACT_LENGTH_FLOOR of its slot's planned length


type Refusal = AnswerFault | ClaimMiss
type FactClaims = tuple[str, ...] | AnswerFault


@dataclass(frozen=True, slots=True)
class Asked[T]:
    """What a stage got: its value, None when no attempt was kept or calls stopped, and why each
    refused answer and each claim left out was not kept."""

    value: T | None
    refused: tuple[Refusal, ...]


def answer_object(text: str) -> dict[str, object] | None:
    """The JSON object of an answer, inside a code fence or not."""
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[1] if "\n" in stripped else ""
        stripped = stripped.rsplit("```", 1)[0]
    try:
        value: object = json.loads(stripped)
    except json.JSONDecodeError:
        return None
    return cast(dict[str, object], value) if isinstance(value, dict) else None


def parse_facts(answer: str, n: int) -> FactClaims:
    """The n claims of a facts answer in slot order, each stripped, or why the answer does not read
    as one text claim per slot. An item left out or not text would shift every later claim onto
    the slot before its own."""
    obj = answer_object(answer)
    raw = obj.get("facts") if obj is not None else None
    if not isinstance(raw, list):
        return AnswerFault.NOT_FACTS
    items = cast(list[object], raw)
    if len(items) != n:
        return AnswerFault.COUNT
    claims: list[str] = []
    for item in items:
        claim = cast(dict[str, object], item).get("claim") if isinstance(item, dict) else None
        if not isinstance(claim, str) or not claim.strip():
            return AnswerFault.CLAIM_NOT_TEXT
        claims.append(claim.strip())
    return tuple(claims)


def claim_miss(claim: str, slot: FactSlot, texts: Set[str]) -> ClaimMiss | None:
    """Why `claim` cannot fill `slot`, given the texts already written; None when it can."""
    if claim in texts:
        return ClaimMiss.COPY
    if not S.surface_holds(claim, slot.surface):
        return ClaimMiss.MARKS
    if len(claim) < FACT_LENGTH_FLOOR * slot.length:
        return ClaimMiss.SHORT
    return None


def claims_for(caller: Asks, plan: MemoryPlan, category: str, slots: tuple[FactSlot, ...],
               same: Sequence[str], others: Sequence[str]) -> Asked[tuple[tuple[FactSlot, str], ...]]:
    """Claims for `slots`, matched by position. The prompt shows the facts already written in
    `category` whole and those of other categories by their first EXISTING_HEAD chars: a category
    takes several calls, and a later call that saw only the head of a long fact wrote its lesson
    again as a short fact (27 of the 29 unplanted repeats the 11-10 dev label audit found).
    An answer counts only when it holds one text claim per slot (`parse_facts`), and a claim only
    when `claim_miss` finds nothing. An attempt is kept when every planted slot (stale, or with a
    use time) and DURABLE_KEEP_SHARE of the durable ones came back: a planted fact that failed its
    marks would leave the kept planted facts with other marks than the kept durable ones."""
    items = "\n".join(P.fact_item(i + 1, text_kind(slot), int(round(slot.length * LENGTH_ASK, -1)), slot.surface)
                      for i, slot in enumerate(slots))
    prompt = P.FACTS_PROMPT.format(role=plan.keeper.role_material, world=plan.keeper.world, category=category,
                                   n=len(slots), marks=P.MARKS, items=items, same=listed(same, whole),
                                   others=listed(others, head), style=P.STYLE)
    durable = sum(not planted(s) for s in slots)
    plants = len(slots) - durable
    refused: list[Refusal] = []
    for attempt in range(ATTEMPTS):
        answer = ask(caller, "facts", prompt, attempt)
        if answer is None:
            return Asked(None, tuple(refused))
        if not answer:
            continue
        parsed = parse_facts(answer, len(slots))
        match parsed:
            case AnswerFault():
                refused.append(parsed)
                continue
            case tuple():
                claims = parsed
            case _:
                assert_never(parsed)
        texts = {c.strip() for c in (*same, *others)}
        kept: list[tuple[FactSlot, str]] = []
        for slot, claim in zip(slots, claims, strict=True):
            miss = claim_miss(claim, slot, texts)
            if miss is None:
                texts.add(claim)
                kept.append((slot, claim))
            else:
                refused.append(miss)
        kept_plants = sum(planted(s) for s, _ in kept)
        if kept_plants == plants and len(kept) - kept_plants >= round(DURABLE_KEEP_SHARE * durable):
            return Asked(tuple(kept), tuple(refused))
    return Asked(None, tuple(refused))


@dataclass(frozen=True, slots=True)
class Written:
    """A written fact before it gets its memory ID. `restates` is the claim a planted duplicate
    restates, and `use_at` the use time of a record."""

    seen: dt.datetime
    category: str
    stale: bool
    claim: str
    restates: str | None
    use_at: dt.datetime | None


def facts_of(rng: random.Random, written: list[Written]) -> tuple[S.MemoryFact, ...]:
    """The memory in the order its facts were seen, as m1, m2, …; a duplicate names its fact's ID."""
    timed = sorted(written, key=lambda w: w.seen)
    ids = {w.claim: f"m{i + 1}" for i, w in enumerate(timed)}
    return tuple(
        S.MemoryFact(ids[w.claim], w.claim, w.category,
                     S.board_ref(rng) if rng.random() < S.BOARD_BASIS_SHARE else None, iso(w.seen), w.stale,
                     ids[w.restates] if w.restates is not None else None,
                     iso(w.use_at) if w.use_at is not None else None)
        for w in timed)


def duplicate_for(caller: Asks, rng: random.Random, plan: MemoryPlan, slot: DuplicateSlot,
                  written: list[Written]) -> Written | None:
    """A restatement of one durable fact of the slot's category. It counts only when it carries the
    slot's marks and stays within the candidate length band of that fact. None when the category
    holds no durable fact or no attempt fits."""
    originals = [w.claim for w in written if w.category == slot.category and not w.stale and w.use_at is None]
    if not originals:
        return None
    original = rng.choice(originals)
    texts = {w.claim.strip() for w in written}
    prompt = P.DUPLICATE_PROMPT.format(role=plan.keeper.role_material, world=plan.keeper.world,
                                       category=slot.category, target=original, length=len(original),
                                       surface="표기: " + P.surface_line(slot.surface), marks=P.MARKS,
                                       style=P.STYLE)
    for attempt in range(CANDIDATE_ATTEMPTS):
        answer = ask(caller, "duplicate", prompt, attempt)
        if answer is None:
            return None
        claim = S.parse_single_claim(answer) if answer else None
        if (claim is not None and claim.strip() not in texts and S.surface_holds(claim, slot.surface)
                and C.length_holds(claim, len(original))):
            return Written(slot.seen, slot.category, False, claim, original, None)
    return None


def build_memory(caller: Asks, plan: MemoryPlan) -> Asked[tuple[S.MemoryFact, ...]]:
    rng = random.Random(plan.seed)
    written: list[Written] = []
    refused: list[Refusal] = []
    for category, group in itertools.groupby(plan.slots, key=lambda slot: slot.category):
        slots = tuple(group)
        for start in range(0, len(slots), FACTS_PER_CALL):
            got = claims_for(caller, plan, category, slots[start:start + FACTS_PER_CALL],
                             [w.claim for w in written if w.category == category],
                             [w.claim for w in written if w.category != category])
            refused.extend(got.refused)
            if got.value is None:
                return Asked(None, tuple(refused))
            written.extend(Written(slot.seen, slot.category, slot.stale, claim, None, slot.use_at)
                           for slot, claim in got.value)
    if plan.duplicate is not None:
        restated = duplicate_for(caller, rng, plan, plan.duplicate, written)
        if restated is None:
            return Asked(None, tuple(refused))
        written.append(restated)
    return Asked(facts_of(rng, written), tuple(refused))


def target_choices(facts: tuple[S.MemoryFact, ...]) -> list[S.MemoryFact]:
    """The facts a candidate may correct, complement or restate: durable facts outside a planted
    pair, so that a candidate never targets a fact the label also expects to merge, and never a
    record with a use time, whose label does not depend on the candidates."""
    paired = {f.memory_id for f in facts if f.duplicate_of is not None} | {
        f.duplicate_of for f in facts if f.duplicate_of is not None}
    return [f for f in facts if not f.planted_stale and f.use_at is None and f.memory_id not in paired]


def untargeted_category(rng: random.Random, targets: list[S.MemoryFact], planned: int) -> str | None:
    """The category of a new or transient candidate: that of a fact drawn the way a targeted
    candidate draws its target (`synth_candidate_plan.target_near`). The prompt prints each
    category's size, and a category drawn evenly instead would make a large one mark a targeted
    candidate. None when no fact could be a target."""
    return C.target_near(rng, targets, planned).category if targets else None


def build_candidates(caller: Asks, rng: random.Random, keeper: S.KeeperProfile, facts: tuple[S.MemoryFact, ...],
                     plans: tuple[C.CandidatePlan, ...]) -> tuple[S.Candidate, ...] | None:
    durable = [f for f in facts if not f.planted_stale]
    targets = target_choices(facts)
    used: set[str] = set()
    # A candidate that copies a fact or an earlier candidate would make its claim name both.
    texts = {f.claim.strip() for f in facts}
    out: list[S.Candidate] = []
    clock = between(rng, CANDIDATE_TIME_START, CANDIDATE_TIME_START + dt.timedelta(days=1))
    first_sequence = rng.randrange(1, 150)
    for sequence, plan in enumerate(plans, start=first_sequence):
        clock += dt.timedelta(seconds=rng.randrange(5, 600), microseconds=rng.randrange(10**6))
        surface = C.candidate_surface(rng, plan, clock)
        target: S.MemoryFact | None = None
        match plan.kind:
            case S.CandidateKind.CORRECTION | S.CandidateKind.COMPLEMENT | S.CandidateKind.PARAPHRASE:
                choices = [f for f in targets if f.memory_id not in used]
                if not choices:
                    return None
                target = C.target_near(rng, choices, plan.length)
                used.add(target.memory_id)
                category = target.category
                task = P.targeted_task(plan.kind, target.claim)
            case S.CandidateKind.NEW_DURABLE:
                category = untargeted_category(rng, targets, plan.length)
                if category is None:
                    return None
                same = [f.claim for f in durable if f.category == category]
                task = P.TASK_NEW.format(category=category, existing=listed(same, whole))
            case S.CandidateKind.TRANSIENT:
                category = untargeted_category(rng, targets, plan.length)
                if category is None:
                    return None
                task = P.TASK_TRANSIENT.format(category=category)
        prompt = P.CANDIDATE_PROMPT.format(role=keeper.role_material, world=keeper.world, task=task,
                                         length=plan.length, surface="표기: " + P.surface_line(surface),
                                         marks=P.MARKS, style=P.STYLE)
        claim: str | None = None
        for attempt in range(CANDIDATE_ATTEMPTS):
            answer = ask(caller, "candidate", prompt, attempt)
            if answer is None:
                return None
            parsed = S.parse_single_claim(answer) if answer else None
            if (parsed is not None and parsed.strip() not in texts and S.surface_holds(parsed, surface)
                    and C.length_holds(parsed, plan.length)):
                claim = parsed
                break
        if claim is None:
            return None
        texts.add(claim.strip())
        seen = round(clock.timestamp(), 6)
        board = S.board_ref(rng) if plan.board else None
        out.append(S.Candidate(S.candidate_request_id(rng), sequence, claim, category, seen, board,
                               S.trace_id(rng, int(seen * 1000)), plan.kind,
                               target.memory_id if target is not None else None))
    return tuple(out)


def goal_for(rng: random.Random, keeper: S.KeeperProfile) -> S.GoalContext:
    shape: S.GoalShape = S.sample_weighted(rng, S.GOAL_WEIGHTS)
    match shape:
        case "no_task":
            return S.NoTask()
        case "task_without_goal":
            return S.TaskWithoutGoal(S.task_id(rng))
        case "task_with_goal":
            return S.TaskWithGoal(S.task_id(rng), S.goal_id(rng, keeper.key), S.hex_string(rng, 32), keeper.goal)
        case _:
            assert_never(shape)


def request_json(request: S.SynthRequest) -> str:
    """One line of requests.jsonl: the request as `synth_rows.row_of` writes it."""
    return json.dumps({"request": RW.row_of(request)}, ensure_ascii=False)


# One request to build: its index, its memory, its random seed and its candidate plans.
type Job = tuple[int, tuple[MemoryPlan, tuple[S.MemoryFact, ...]], int, tuple[C.CandidatePlan, ...]]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", choices=sorted(SPLITS), required=True)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--budget", type=float, required=True)
    ap.add_argument("--first-memory", type=int, default=0,
                    help="number of each Keeper's first memory; a later batch of a split starts where the last ended")
    args = ap.parse_args()
    split, seed, budget = cast(str, args.split), cast(int, args.seed), cast(float, args.budget)
    first_memory = cast(int, args.first_memory)
    out = Path(cast(str, args.out))
    out.mkdir(parents=True, exist_ok=True)
    keepers_seeds, memories_per_keeper, n_requests = SPLITS[split]
    rng = random.Random(seed)
    caller = Caller(out / "calls.jsonl", budget)
    status: dict[str, int] = {"profiles_failed": 0, "memories_failed": 0, "requests_failed": 0}
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        profile_rngs = [random.Random(rng.randrange(2**31)) for _ in keepers_seeds]
        def profile_task(pair: tuple[S.KeeperSeed, random.Random]) -> S.KeeperProfile | None:
            return profile_of(caller, pair[0], pair[1])

        def memory_task(plan: MemoryPlan) -> Asked[tuple[S.MemoryFact, ...]]:
            return build_memory(caller, plan)

        profiles = list(pool.map(profile_task, zip(keepers_seeds, profile_rngs, strict=True)))
        keepers = [p for p in profiles if p is not None]
        status["profiles_failed"] = len(profiles) - len(keepers)
        homes = memory_homes(keepers, memories_per_keeper, first_memory)
        paired = C.flags(rng, len(homes), S.DUPLICATE_PAIR_SHARE)
        plans = [plan_memory(rng, keeper, i, pair) for (keeper, i), pair in zip(homes, paired, strict=True)]
        memories = list(pool.map(memory_task, plans))
        built = [(plan, got.value) for plan, got in zip(plans, memories, strict=True) if got.value is not None]
        status["memories_failed"] = len(plans) - len(built)
        refusals = Counter(r for got in memories for r in got.refused)
        if not built:
            print("no memory was built", caller.stopped or "", file=sys.stderr)
            return 2
        slots = [built[i % len(built)] for i in range(n_requests)]
        slot_seeds = [rng.randrange(2**31) for _ in slots]
        candidate_plans = C.plan_candidates(rng, len(slots))

        def one(job: Job) -> S.SynthRequest | None:
            index, (plan, facts), seed, wanted = job
            local = random.Random(seed)
            candidates = build_candidates(caller, local, plan.keeper, facts, wanted)
            if candidates is None:
                return None
            return S.SynthRequest(f"{split}-{plan.memory_key}-{index:03d}", plan.keeper, facts,
                                  goal_for(local, plan.keeper), candidates)

        jobs = zip(slots, slot_seeds, candidate_plans, strict=True)
        requests = list(pool.map(one, [(i, s, z, c) for i, (s, z, c) in enumerate(jobs)]))
    done = [r for r in requests if r is not None]
    status["requests_failed"] = len(requests) - len(done)
    with (out / "requests.jsonl").open("w", encoding="utf-8") as fh:
        for request in sorted(done, key=lambda r: r.item_id):
            fh.write(request_json(request) + "\n")
    kinds = Counter(c.kind.value for r in done for c in r.candidates)
    summary = {"split": split, "seed": seed, "first_memory": first_memory, "model": MODEL, "requests": len(done),
               "memories": len({r.item_id.rsplit("-", 1)[0] for r in done}), **status,
               "candidates_by_kind": dict(sorted(kinds.items())),
               "memories_with_duplicate": sum(any(f.duplicate_of is not None for f in facts) for _, facts in built),
               "records_by_side": dict(Counter("past" if f.planted_stale else "ahead"
                                               for _, facts in built for f in facts if f.use_at is not None)),
               "fact_answers_refused": {fault.value: refusals[fault] for fault in AnswerFault},
               "facts_left_out": {miss.value: refusals[miss] for miss in ClaimMiss},
               "spent_usd": round(caller.spent, 4), "budget_usd": budget, "stopped": caller.stopped}
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("SUMMARY", json.dumps(summary))
    return 2 if caller.stopped is not None else 0


if __name__ == "__main__":
    sys.exit(main())
