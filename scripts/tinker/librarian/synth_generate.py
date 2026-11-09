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
categories, claim lengths, planted stale facts, candidate kinds and targets
(`synth_spec.py`). The model writes only text: role material, a world sheet,
category names, a goal, and claims. Every model call is cached in
<out>/calls.jsonl under a key derived from the request, so a rerun resumes and
pays only for calls that have no answer yet. Output: <out>/requests.jsonl (one
request with its label per line) and <out>/summary.json.

TINKER_API_KEY comes from the environment and is never written.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import random
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import assert_never, cast

import synth_prompts as P
import synth_spec as S
from tinker_oai import Caller

MODEL = "thinkingmachines/Inkling-2-Small"
ATTEMPTS = 3
WORKERS = 8
# The model writes shorter claims than asked, and shorter still when asked for many.
# 11-08 pilots, planned median 492 chars: 30 claims per call gave a median of 253;
# 8 per call at 1.3x the plan gave 391 (p90 944 for a planned 1,410), about 0.5 to
# 0.6 of the asked length. So a call asks for at most FACTS_PER_CALL claims, each
# LENGTH_ASK times the planned length.
FACTS_PER_CALL = 6
LENGTH_ASK = 1.7
EFFORT = {"profile": "medium", "facts": "low", "stale": "low", "candidate": "medium"}
MAX_TOKENS = {"profile": 8192, "facts": 16384, "stale": 4096, "candidate": 4096}
# Measured role material: p10 716, p50 1,144, p90 2,684 chars.
ROLE_CHARS = ((0.0, 500.0), (0.1, 716.0), (0.5, 1144.0), (0.9, 2684.0), (1.0, 3400.0))
EXISTING_HEAD = 90
MEMORY_END = dt.datetime(2026, 11, 6, 23, 59, 59, tzinfo=dt.UTC)
CANDIDATE_TIME_START = dt.datetime(2026, 11, 7, tzinfo=dt.UTC)
SPLITS = {
    # split: (keepers, memories per keeper, requests)
    "eval": (tuple(k for k in S.KEEPER_SEEDS if k.key in S.EVAL_KEEPERS), 10, 150),
    "train": (tuple(k for k in S.KEEPER_SEEDS if k.key not in S.EVAL_KEEPERS), 9, 260),
}

# --- stages ------------------------------------------------------------------


def ask(caller: Caller, stage: str, prompt: str, attempt: int) -> str | None:
    """The answer text, "" when the call failed or was cut off, None once the budget stops calls."""
    call = caller.ask(model=MODEL, label=stage, messages=[prompt], effort=EFFORT[stage],
                      max_tokens=MAX_TOKENS[stage], attempt=attempt)
    if call is None:
        return None
    return call.answer() or ""


def head(claim: str) -> str:
    return claim[:EXISTING_HEAD].replace("\n", " ")


def profile_of(caller: Caller, seed: S.KeeperSeed, rng: random.Random) -> S.KeeperProfile | None:
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
class MemoryPlan:
    memory_key: str
    keeper: S.KeeperProfile
    categories: tuple[tuple[str, int], ...]
    lengths: tuple[tuple[int, ...], ...]
    stale: int
    stale_lengths: tuple[int, ...]
    seed: int


def plan_memory(rng: random.Random, keeper: S.KeeperProfile, index: int) -> MemoryPlan:
    n_facts = round(S.sample_quantile(rng, S.FACTS_PER_MEMORY))
    n_cats = min(len(keeper.categories), round(S.sample_quantile(rng, S.CATEGORIES_PER_MEMORY)))
    names = rng.sample(keeper.categories, n_cats)
    counts = S.allocate_counts(rng, n_facts, n_cats)
    lengths = tuple(tuple(int(round(S.sample_quantile(rng, S.CLAIM_CHARS), -1)) for _ in range(c)) for c in counts)
    stale = S.sample_weighted(rng, S.STALE_FACTS_PER_MEMORY_WEIGHTS)
    stale_lengths = tuple(int(round(S.sample_quantile(rng, S.CANDIDATE_CLAIM_CHARS), -1)) for _ in range(stale))
    return MemoryPlan(f"{keeper.key}-{index:02d}", keeper, tuple(zip(names, counts, strict=True)), lengths,
                      stale, stale_lengths, rng.randrange(2**31))


def iso(t: dt.datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def between(rng: random.Random, start: dt.datetime, end: dt.datetime) -> dt.datetime:
    return start + dt.timedelta(seconds=rng.randrange(int((end - start).total_seconds())))


def claims_for(caller: Caller, template: str, stage: str, plan: MemoryPlan, category: str,
               lengths: tuple[int, ...], existing: list[str]) -> tuple[str, ...] | None:
    prompt = template.format(role=plan.keeper.role_material, world=plan.keeper.world, category=category,
                             n=len(lengths), lengths=", ".join(str(int(round(n * LENGTH_ASK, -1))) for n in lengths),
                             existing="\n".join(f"- {head(c)}" for c in existing) or "(없음)", style=P.STYLE)
    for attempt in range(ATTEMPTS):
        answer = ask(caller, stage, prompt, attempt)
        if answer is None:
            return None
        claims = S.parse_claims(answer) if answer else None
        if claims is not None and len(claims) >= max(1, round(0.7 * len(lengths))):
            seen = {c.strip() for c in existing}
            fresh = tuple(dict.fromkeys(c for c in claims if c.strip() not in seen))
            return fresh[: len(lengths)]
    return None


def build_memory(caller: Caller, plan: MemoryPlan) -> tuple[S.MemoryFact, ...] | None:
    rng = random.Random(plan.seed)
    drafts: list[tuple[str, str, bool]] = []
    for (category, _count), lengths in zip(plan.categories, plan.lengths, strict=True):
        for start in range(0, len(lengths), FACTS_PER_CALL):
            claims = claims_for(caller, P.FACTS_PROMPT, "facts", plan, category, lengths[start:start + FACTS_PER_CALL],
                                [d[1] for d in drafts])
            if claims is None:
                return None
            drafts.extend((category, c, False) for c in claims)
    if plan.stale:
        category = rng.choice([c for c, _ in plan.categories])
        stale = claims_for(caller, P.STALE_PROMPT, "stale", plan, category, plan.stale_lengths, [])
        if stale is None:
            return None
        drafts.extend((category, c, True) for c in stale)
    end = MEMORY_END - dt.timedelta(seconds=rng.randrange(86400))
    start = end - dt.timedelta(days=S.sample_quantile(rng, S.MEMORY_SPAN_DAYS))
    timed = sorted(((between(rng, start, end), category, claim, stale_flag) for category, claim, stale_flag in drafts),
                   key=lambda t: t[0])
    return tuple(
        S.MemoryFact(f"m{i + 1}", claim, category, S.board_ref(rng) if rng.random() < S.BOARD_BASIS_SHARE else None,
                     iso(seen), stale_flag)
        for i, (seen, category, claim, stale_flag) in enumerate(timed))


def build_candidates(caller: Caller, rng: random.Random, keeper: S.KeeperProfile,
                     facts: tuple[S.MemoryFact, ...]) -> tuple[S.Candidate, ...] | None:
    k = S.sample_weighted(rng, S.CANDIDATES_PER_REQUEST_WEIGHTS)
    durable = [f for f in facts if not f.planted_stale]
    categories = sorted({f.category for f in facts}, key=lambda s: s.encode())
    used: set[str] = set()
    out: list[S.Candidate] = []
    clock = between(rng, CANDIDATE_TIME_START, CANDIDATE_TIME_START + dt.timedelta(days=1))
    first_sequence = rng.randrange(1, 150)
    for sequence in range(first_sequence, first_sequence + k):
        kind = S.sample_weighted(rng, S.CANDIDATE_KIND_WEIGHTS)
        length = int(round(S.sample_quantile(rng, S.CANDIDATE_CLAIM_CHARS), -1))
        target: S.MemoryFact | None = None
        match kind:
            case S.CandidateKind.CORRECTION | S.CandidateKind.PARAPHRASE:
                choices = [f for f in durable if f.memory_id not in used]
                if not choices:
                    return None
                target = rng.choice(choices)
                used.add(target.memory_id)
                category = target.category
                task = (P.TASK_CORRECTION if kind is S.CandidateKind.CORRECTION else P.TASK_PARAPHRASE).format(
                    target=target.claim)
            case S.CandidateKind.NEW_DURABLE:
                category = rng.choice(categories)
                same = [f.claim for f in durable if f.category == category]
                task = P.TASK_NEW.format(category=category,
                                       existing="\n".join(f"- {head(c)}" for c in same) or "(없음)")
            case S.CandidateKind.TRANSIENT:
                category = rng.choice(categories)
                task = P.TASK_TRANSIENT.format(category=category)
        prompt = P.CANDIDATE_PROMPT.format(role=keeper.role_material, world=keeper.world, task=task,
                                         length=length, style=P.STYLE)
        claim: str | None = None
        for attempt in range(ATTEMPTS):
            answer = ask(caller, "candidate", prompt, attempt)
            if answer is None:
                return None
            claim = S.parse_single_claim(answer) if answer else None
            if claim is not None:
                break
        if claim is None:
            return None
        clock += dt.timedelta(seconds=rng.randrange(5, 600), microseconds=rng.randrange(10**6))
        seen = round(clock.timestamp(), 6)
        board = S.board_ref(rng) if rng.random() < S.CANDIDATE_BOARD_SHARE else None
        out.append(S.Candidate(S.candidate_request_id(rng), sequence, claim, category, seen, board,
                               S.trace_id(rng, int(seen * 1000)), kind,
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


def enum_value(value: object) -> str:
    if isinstance(value, S.CandidateKind):
        return value.value
    raise TypeError(f"not JSON serializable: {type(value).__name__}")


def request_json(request: S.SynthRequest) -> str:
    """One line of requests.jsonl. The goal is stored as the goal_context text MASC shows."""
    label = S.label_of(request)
    body = asdict(request)
    del body["goal"]
    body["goal_context"] = S.goal_json(request.goal)
    return json.dumps({"request": body, "label": {
        "candidates": [asdict(c) for c in label.candidates], "planted_stale": sorted(label.planted_stale)}},
        ensure_ascii=False, default=enum_value)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", choices=sorted(SPLITS), required=True)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--budget", type=float, required=True)
    args = ap.parse_args()
    split, seed, budget = cast(str, args.split), cast(int, args.seed), cast(float, args.budget)
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

        def memory_task(plan: MemoryPlan) -> tuple[S.MemoryFact, ...] | None:
            return build_memory(caller, plan)

        profiles = list(pool.map(profile_task, zip(keepers_seeds, profile_rngs, strict=True)))
        keepers = [p for p in profiles if p is not None]
        status["profiles_failed"] = len(profiles) - len(keepers)
        plans = [plan_memory(rng, keeper, i) for keeper in keepers for i in range(memories_per_keeper)]
        memories = list(pool.map(memory_task, plans))
        built = [(plan, facts) for plan, facts in zip(plans, memories, strict=True) if facts is not None]
        status["memories_failed"] = len(plans) - len(built)
        if not built:
            print("no memory was built", caller.stopped or "", file=sys.stderr)
            return 2
        slots = [built[i % len(built)] for i in range(n_requests)]
        slot_seeds = [rng.randrange(2**31) for _ in slots]

        def one(args_: tuple[int, tuple[MemoryPlan, tuple[S.MemoryFact, ...]], int]) -> S.SynthRequest | None:
            index, (plan, facts), seed = args_
            local = random.Random(seed)
            candidates = build_candidates(caller, local, plan.keeper, facts)
            if candidates is None:
                return None
            return S.SynthRequest(f"{split}-{plan.memory_key}-{index:03d}", plan.keeper, facts,
                                  goal_for(local, plan.keeper), candidates)

        requests = list(pool.map(one, [(i, s, z) for i, (s, z) in enumerate(zip(slots, slot_seeds, strict=True))]))
    done = [r for r in requests if r is not None]
    status["requests_failed"] = len(requests) - len(done)
    with (out / "requests.jsonl").open("w", encoding="utf-8") as fh:
        for request in sorted(done, key=lambda r: r.item_id):
            fh.write(request_json(request) + "\n")
    summary = {"split": split, "seed": seed, "model": MODEL, "requests": len(done),
               "memories": len({r.item_id.rsplit("-", 1)[0] for r in done}), **status,
               "spent_usd": round(caller.spent, 4), "budget_usd": budget, "stopped": caller.stopped}
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("SUMMARY", json.dumps(summary))
    return 2 if caller.stopped is not None else 0


if __name__ == "__main__":
    sys.exit(main())
