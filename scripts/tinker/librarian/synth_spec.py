# pyright: strict
"""Typed specification of synthetic keeper-librarian admission requests.

Pure code: no I/O, no clock, no global random state. The caller passes a
seeded `random.Random`. `synth_generate.py` asks a model for the text and
`synth_render.py` turns the typed values into a MASC admission prompt.

Sizes follow a measurement of the retained admission requests
(`~/me/.masc/lane-addons/exact-requests`, 101 requests, 22 Keepers,
2026-11-08). Only counts and lengths were read, never the text.

A request carries labels by construction:

| candidate kind | expected outcome | memory change |
| --- | --- | --- |
| NEW_DURABLE | incorporated | a new claim, supported by the candidate |
| CORRECTION | incorporated | a new claim superseding the target; the target in `dropped` |
| COMPLEMENT | incorporated | a new claim that absorbs the target |
| PARAPHRASE | already_represented | none; `memory_claim` is the target's claim |
| TRANSIENT | not_durable | none |

A memory fact with `planted_stale=True` is a transient state that slipped into
memory; the expected answer drops it without a superseding claim. A fact with
`duplicate_of` restates another fact of its memory in other words; the expected
answer keeps one of the two and absorbs the other into it. A fact with `use_at`
is a record of something to do or pass on at that time, known only from memory.
Its use time falls on a day after every candidate's, and the expected answer
keeps it; or on a day before them, and it is planted stale. MASC takes these drops
and merges without a supporting candidate (RFC-0517 §7.1), so the expected answer
makes them in a request whose candidates are all transient too.

What a claim carries besides its meaning (a date, a time, a PR/issue/task
number) is planned from shares measured on the retained records, and
`surface_holds` checks the written text against the plan. A memory fact draws
its marks one by one with `plan_surface`, the same way stale or durable. A
record with a use time always carries the date of that time (`plan_use_surface`).
Candidates are planned for a whole split at once by `synth_candidate_plan`,
which deals each mark and the length out within each label kind. A label then
leaves no mark in those strings.
Rules: `config/prompts/librarian.md` 58-64 (relations), 143-208 (keep, drop,
correct, absorb) and 586-616 (admission).
"""

from __future__ import annotations

import datetime as dt
import itertools
import json
import random
import re
import string
from dataclasses import dataclass
from enum import Enum
from typing import Literal, assert_never, cast

# Piecewise-linear inverse CDFs: (quantile, value). Measured 2026-11-08, see the
# module docstring; the end points are chosen, the inner points are measured.
FACTS_PER_MEMORY = ((0.0, 12.0), (0.1, 27.0), (0.5, 66.0), (0.9, 96.0), (1.0, 140.0))
CATEGORIES_PER_MEMORY = ((0.0, 3.0), (0.1, 4.0), (0.5, 8.0), (0.9, 10.0), (1.0, 14.0))
CLAIM_CHARS = ((0.0, 120.0), (0.1, 214.0), (0.5, 492.0), (0.9, 1410.0), (1.0, 2400.0))
# Candidates: the 233 of the 99 E-real records, measured 2026-11-09 (p10 399, p50 737,
# p90 1,234). The 11-08 points (p50 475) matched no retained set this split is checked on.
CANDIDATE_CLAIM_CHARS = ((0.0, 150.0), (0.1, 399.0), (0.5, 737.0), (0.9, 1234.0), (1.0, 2000.0))
# Days between the earliest and the latest fact of one memory: p10 8, p50 41, p90 61.
MEMORY_SPAN_DAYS = ((0.0, 2.0), (0.1, 8.0), (0.5, 41.0), (0.9, 61.0), (1.0, 90.0))
# Measured: 1,111 of 6,743 facts cite a Board post.
BOARD_BASIS_SHARE = 0.165
# Candidates citing a Board post: 16 of 233.
CANDIDATE_BOARD_SHARE = 0.069
# Measured: no_task 65, task without goals 19, task with one goal 17 (of 101).
GoalShape = Literal["no_task", "task_without_goal", "task_with_goal"]
GOAL_WEIGHTS: tuple[tuple[GoalShape, float], ...] = (
    ("no_task", 0.64), ("task_without_goal", 0.19), ("task_with_goal", 0.17))
# Measured candidates per request: p50 1, p90 3 (the 515-candidate outlier is
# an oversized part, #49910, and is left out).
CANDIDATES_PER_REQUEST_WEIGHTS = ((1, 0.6), (2, 0.25), (3, 0.15))
STALE_FACTS_PER_MEMORY_WEIGHTS = ((0, 0.3), (1, 0.4), (2, 0.3))
# Share of a split's memories that hold one planted duplicate pair. In expectation 0.16 of
# planned requests merge a pair (it needs a supporting candidate) and 0.195 hold a COMPLEMENT,
# so 0.32 expect an absorb. Of the 99 live E-real records, 30 absorb: 5 into a kept current
# claim and 27 into a candidate's new claim. Pairs are planted more often than live so E-synth
# holds enough to measure. Complements match live per candidate (below), and are fewer per
# request because a planned request carries 1.55 candidates on average and these records 2.35.
DUPLICATE_PAIR_SHARE = 0.2
# Records with a use time per memory, and the share whose day is still ahead. No live share was
# measured. On 11-11 an answer under the #51190 prompt dropped, on a live record, a note on the day
# it was written while the next morning still needed it. The records are planted, as the pairs
# are, so E-synth holds enough of both sides to measure.
SCHEDULED_FACTS_PER_MEMORY_WEIGHTS = ((0, 0.4), (1, 0.4), (2, 0.2))
SCHEDULED_AHEAD_SHARE = 0.5


@dataclass(frozen=True, slots=True)
class SurfaceShares:
    date: float
    time_given_date: float
    reference: float


# Measured 2026-11-09 on the 99 E-real records (counts only, no text kept):
# distinct current facts (1,621) carry a date 0.349, a time given a date 0.18 and a
# PR/issue/task number 0.389; candidates (233) carry a date 0.691, a time given a date
# 0.379 and a number 0.403. Over both, dates are ISO 0.63, MM-DD 0.19, MM/DD 0.16 and
# Korean 0.01; numbers are #N 0.75 and task-N 0.25; times are almost all HH:MM.
FACT_SURFACE = SurfaceShares(date=0.349, time_given_date=0.18, reference=0.389)
CANDIDATE_SURFACE = SurfaceShares(date=0.691, time_given_date=0.379, reference=0.403)
DateFormat = Literal["iso", "month_day_dash", "month_day_slash", "korean"]
DATE_FORMAT_WEIGHTS: tuple[tuple[DateFormat, float], ...] = (
    ("iso", 0.63), ("month_day_dash", 0.19), ("month_day_slash", 0.16), ("korean", 0.02))
ReferenceFormat = Literal["hash", "task"]
REFERENCE_FORMAT_WEIGHTS: tuple[tuple[ReferenceFormat, float], ...] = (("hash", 0.75), ("task", 0.25))
# What counts as a date, a time and a number in a claim. A range like 3-5 or a ratio like
# 1/3 reads as a date, so the generator never keeps one.
DATE_PATTERN = re.compile(r"(?<!\d)20\d\d-\d\d-\d\d(?!\d)|(?<![\d-])\d{1,2}-\d{1,2}(?![\d-])"
                          r"|(?<!\d)\d{1,2}/\d{1,2}(?!\d)|\d{1,2}월\s*\d{1,2}일")
TIME_PATTERN = re.compile(r"(?<!\d)\d{1,2}:\d{2}(?!\d)|\d{1,2}시(?!간)")
REFERENCE_PATTERN = re.compile(r"#\d+|\btask-\d+|\bPR\s*\d+")


@dataclass(frozen=True, slots=True)
class Surface:
    """The exact date, time and number text one claim carries; None carries none of that kind."""

    date: str | None
    time: str | None  # only with a date
    reference: str | None
# Operator caps in every measured request (`keeper_memory_limits.ml`).
CATEGORY_CAP = 30
FACTS_PER_CATEGORY_CAP = 30
RESERVED_CATEGORIES = frozenset({"all", "source", "dropped"})
HEX = "0123456789abcdef"


class CandidateKind(Enum):
    NEW_DURABLE = "new_durable"
    CORRECTION = "correction"
    COMPLEMENT = "complement"
    PARAPHRASE = "paraphrase"
    TRANSIENT = "transient"


# Live outcomes of the 233 judged candidates of the 99 E-real records (11-09): incorporated
# 121, not_durable 68, already_represented 43, deferred 1 (not generated). By what an
# incorporated candidate's final claim does: 81 add a claim, 31 absorb current facts (2 of
# them also supersede one), 9 only supersede. CORRECTION keeps 0.15, above the live 9 of 233,
# so E-synth holds enough corrections to measure; NEW_DURABLE takes the rest of incorporated.
# Kinds are drawn per candidate, so in expectation 0.20 of planned requests have only transient
# candidates; 11 of the 99 live records judge every candidate not_durable or deferred.
CANDIDATE_KIND_WEIGHTS: tuple[tuple[CandidateKind, float], ...] = (
    (CandidateKind.NEW_DURABLE, 0.236),
    (CandidateKind.CORRECTION, 0.15),
    (CandidateKind.COMPLEMENT, 0.133),
    (CandidateKind.PARAPHRASE, 0.185),
    (CandidateKind.TRANSIENT, 0.292),
)

Outcome = Literal["incorporated", "already_represented", "not_durable"]


def expected_outcome(kind: CandidateKind) -> Outcome:
    match kind:
        case CandidateKind.NEW_DURABLE | CandidateKind.CORRECTION | CandidateKind.COMPLEMENT:
            return "incorporated"
        case CandidateKind.PARAPHRASE:
            return "already_represented"
        case CandidateKind.TRANSIENT:
            return "not_durable"
        case _:
            assert_never(kind)


@dataclass(frozen=True, slots=True)
class KeeperSeed:
    key: str
    seed: str


# Invented roles. None of them describes a real Keeper.
KEEPER_SEEDS: tuple[KeeperSeed, ...] = (
    KeeperSeed("release-steward", "모바일 앱과 웹 프런트엔드의 주간 릴리스 일정을 맞추고 배포 체크리스트를 지키게 돕는 Keeper"),
    KeeperSeed("ci-triage", "monorepo CI 실패를 분류하고 flaky test 와 실제 회귀를 가려 담당자에게 넘기는 Keeper"),
    KeeperSeed("pr-reviewer", "백엔드 Go 서비스 PR 을 먼저 읽고 위험한 변경과 빠진 테스트를 짚는 리뷰 Keeper"),
    KeeperSeed("docs-gardener", "개발자 문서 사이트의 낡은 안내와 깨진 링크를 찾아 고치는 문서 Keeper"),
    KeeperSeed("data-pipeline-ops", "야간 배치 ETL 과 데이터 웨어하우스 적재 작업을 지켜보는 데이터 운영 Keeper"),
    KeeperSeed("support-triage", "고객 문의 티켓을 읽고 버그 보고와 사용법 질문을 나눠 개발팀에 넘기는 Keeper"),
    KeeperSeed("security-review", "의존성 취약점 알림과 권한 변경 요청을 검토하는 보안 Keeper"),
    KeeperSeed("infra-cost-watch", "클라우드 비용 이상치와 남는 리소스를 찾아 정리를 제안하는 인프라 Keeper"),
    KeeperSeed("research-assistant", "논문과 기술 블로그를 읽고 팀이 실험할 아이디어를 정리하는 리서치 Keeper"),
    KeeperSeed("qa-coordinator", "릴리스 전 회귀 테스트 계획을 세우고 수동 QA 결과를 모으는 QA Keeper"),
    KeeperSeed("onboarding-mentor", "새로 온 개발자의 개발 환경 설정과 첫 작업을 돕는 온보딩 Keeper"),
    KeeperSeed("schedule-coordinator", "여러 팀의 회의와 마감 일정을 맞추고 충돌을 알려 주는 일정 Keeper"),
)
# Keepers whose memories only appear in the evaluation split (E-synth).
EVAL_KEEPERS = frozenset({"docs-gardener", "support-triage", "infra-cost-watch", "qa-coordinator"})


@dataclass(frozen=True, slots=True)
class GoalDraft:
    title: str
    metric: str
    target_value: str


@dataclass(frozen=True, slots=True)
class KeeperProfile:
    key: str
    keeper_id: str
    role_material: str
    world: str
    categories: tuple[str, ...]
    goal: GoalDraft


@dataclass(frozen=True, slots=True)
class BoardRef:
    post_id: str
    comment_id: str | None


@dataclass(frozen=True, slots=True)
class MemoryFact:
    memory_id: str
    claim: str
    category: str
    board: BoardRef | None
    seen_at: str  # MASC writes first_seen and last_seen equal; both render from this
    planted_stale: bool
    duplicate_of: str | None  # a planted duplicate: the memory ID of the fact it restates
    use_at: str | None  # a planted record: when it is to be used, written as seen_at is


@dataclass(frozen=True, slots=True)
class Candidate:
    request_id: str
    sequence: int
    claim: str
    category: str
    seen_at: float  # epoch seconds; first_seen and last_seen render from this
    board: BoardRef | None
    trace_id: str
    kind: CandidateKind
    target_memory_id: str | None


@dataclass(frozen=True, slots=True)
class NoTask:
    pass


@dataclass(frozen=True, slots=True)
class TaskWithoutGoal:
    task_id: str


@dataclass(frozen=True, slots=True)
class TaskWithGoal:
    task_id: str
    goal_id: str
    revision: str
    goal: GoalDraft


GoalContext = NoTask | TaskWithoutGoal | TaskWithGoal


@dataclass(frozen=True, slots=True)
class SynthRequest:
    item_id: str
    keeper: KeeperProfile
    facts: tuple[MemoryFact, ...]
    goal: GoalContext
    candidates: tuple[Candidate, ...]


@dataclass(frozen=True, slots=True)
class CandidateLabel:
    """The candidate's outcome and its target, if it has one: the fact a correction supersedes,
    the fact a complement's claim absorbs, or the claim of the fact a paraphrase restates."""

    request_id: str
    outcome: Outcome
    supersedes: str | None
    absorbs: str | None
    already_claim: str | None


@dataclass(frozen=True, slots=True)
class RequestLabel:
    """`planted_stale` are the planted stale facts and `duplicates` pairs a fact with its planted
    duplicate. The answer drops the stale facts and keeps one fact of each pair, absorbing the other
    into it, whatever the candidates: MASC takes drops and merges without a supporting candidate
    (RFC-0517 §7.1). `scheduled_ahead` are the records whose use is still ahead, which the answer
    keeps, and `scheduled_past` the records whose use has passed, which are among the stale facts."""

    candidates: tuple[CandidateLabel, ...]
    planted_stale: frozenset[str]
    duplicates: tuple[tuple[str, str], ...]
    scheduled_ahead: frozenset[str]
    scheduled_past: frozenset[str]


def candidate_label(candidate: Candidate, by_id: dict[str, MemoryFact]) -> CandidateLabel:
    rid, target = candidate.request_id, candidate.target_memory_id
    match candidate.kind:
        case CandidateKind.CORRECTION:
            return CandidateLabel(rid, "incorporated", target, None, None)
        case CandidateKind.COMPLEMENT:
            return CandidateLabel(rid, "incorporated", None, target, None)
        case CandidateKind.PARAPHRASE:
            return CandidateLabel(rid, "already_represented", None, None,
                                  by_id[target].claim if target is not None else None)
        case CandidateKind.NEW_DURABLE | CandidateKind.TRANSIENT:
            return CandidateLabel(rid, expected_outcome(candidate.kind), None, None, None)
        case _:
            assert_never(candidate.kind)


def labeled(facts: tuple[MemoryFact, ...], candidates: tuple[Candidate, ...]) -> RequestLabel:
    by_id = {f.memory_id: f for f in facts}
    labels = tuple(candidate_label(c, by_id) for c in candidates)
    stale = frozenset(f.memory_id for f in facts if f.planted_stale)
    pairs = tuple((f.duplicate_of, f.memory_id) for f in facts if f.duplicate_of is not None)
    scheduled = frozenset(f.memory_id for f in facts if f.use_at is not None)
    return RequestLabel(labels, stale, pairs, scheduled - stale, scheduled & stale)


def label_of(request: SynthRequest) -> RequestLabel:
    return labeled(request.facts, request.candidates)


# --- sampling ---------------------------------------------------------------


def value_at(points: tuple[tuple[float, float], ...], u: float) -> float:
    """The piecewise-linear inverse CDF `points` at quantile u."""
    for (q0, v0), (q1, v1) in itertools.pairwise(points):
        if u <= q1:
            return v0 + (v1 - v0) * (u - q0) / (q1 - q0)
    return points[-1][1]


def sample_quantile(rng: random.Random, points: tuple[tuple[float, float], ...]) -> float:
    return value_at(points, rng.random())


def sample_weighted[T](rng: random.Random, weights: tuple[tuple[T, float], ...]) -> T:
    total = sum(w for _, w in weights)
    u = rng.random() * total
    for value, w in weights:
        if u < w:
            return value
        u -= w
    return weights[-1][0]


def allocate_counts(rng: random.Random, n_facts: int, n_categories: int) -> tuple[int, ...]:
    """Split n_facts over categories: a few large, many small, each in [1, cap]."""
    k = max(1, min(n_categories, n_facts))
    weights = sorted((rng.paretovariate(1.3) for _ in range(k)), reverse=True)
    total = sum(weights)
    counts = [max(1, min(FACTS_PER_CATEGORY_CAP, round(n_facts * w / total))) for w in weights]
    i = 0
    while sum(counts) != n_facts and i < 10 * n_facts:
        j = i % k
        if sum(counts) < n_facts and counts[j] < FACTS_PER_CATEGORY_CAP:
            counts[j] += 1
        elif sum(counts) > n_facts and counts[j] > 1:
            counts[j] -= 1
        i += 1
    return tuple(counts)


def date_text(when: dt.datetime, form: DateFormat) -> str:
    match form:
        case "iso":
            return when.strftime("%Y-%m-%d")
        case "month_day_dash":
            return f"{when.month:02d}-{when.day:02d}"
        case "month_day_slash":
            return f"{when.month}/{when.day}"
        case "korean":
            return f"{when.month}월 {when.day}일"
        case _:
            assert_never(form)


def reference_text(rng: random.Random, form: ReferenceFormat) -> str:
    match form:
        case "hash":
            return f"#{rng.randrange(120, 52000)}"
        case "task":
            return f"task-{rng.randrange(10, 9999)}"
        case _:
            assert_never(form)


def surface_of(rng: random.Random, shares: SurfaceShares, when: dt.datetime, dated: bool) -> Surface:
    timed = dated and rng.random() < shares.time_given_date
    cited = rng.random() < shares.reference
    return Surface(date_text(when, sample_weighted(rng, DATE_FORMAT_WEIGHTS)) if dated else None,
                   when.strftime("%H:%M") if timed else None,
                   reference_text(rng, sample_weighted(rng, REFERENCE_FORMAT_WEIGHTS)) if cited else None)


def plan_surface(rng: random.Random, shares: SurfaceShares, when: dt.datetime) -> Surface:
    """Surface traits for one claim written about `when`. The caller passes no label."""
    return surface_of(rng, shares, when, rng.random() < shares.date)


def plan_use_surface(rng: random.Random, shares: SurfaceShares, use_at: dt.datetime) -> Surface:
    """Surface traits for a record to be used at `use_at`: always the date of that time, and a time
    and a number as often as any claim of `shares` carries them. Ahead or past alike."""
    return surface_of(rng, shares, use_at, True)


def mark_holds(claim: str, pattern: re.Pattern[str], planned: str | None) -> bool:
    found = {m.group(0) for m in pattern.finditer(claim)}
    return not found if planned is None else found == {planned}


def surface_holds(claim: str, surface: Surface) -> bool:
    """The claim carries exactly the planned date, time and number text, and no other of each kind."""
    return (mark_holds(claim, DATE_PATTERN, surface.date) and mark_holds(claim, TIME_PATTERN, surface.time)
            and mark_holds(claim, REFERENCE_PATTERN, surface.reference))


def hex_string(rng: random.Random, n: int) -> str:
    return "".join(rng.choice(HEX) for _ in range(n))


def candidate_request_id(rng: random.Random) -> str:
    return "memory-admission-" + hex_string(rng, 32)


def trace_id(rng: random.Random, epoch_ms: int) -> str:
    return f"trace-{epoch_ms:013d}-{rng.randrange(100000):05d}"


def board_ref(rng: random.Random) -> BoardRef:
    comment = "c-" + hex_string(rng, 32) if rng.random() < 0.7 else None
    return BoardRef("p-" + hex_string(rng, 32), comment)


def task_id(rng: random.Random) -> str:
    return f"task-{rng.randrange(1000, 9999)}"


def goal_id(rng: random.Random, keeper_key: str) -> str:
    return f"goal-{keeper_key}-{hex_string(rng, 4)}"


def keeper_slug(key: str) -> str:
    return "synth-" + key


def is_category_name(value: str) -> bool:
    """`[a-z][a-z0-9]*(_[a-z0-9]+)*`, not reserved (keeper_memory_os_types.ml)."""
    if not value or value[0] not in string.ascii_lowercase or value in RESERVED_CATEGORIES:
        return False
    return all(part and all(ch in string.ascii_lowercase + string.digits for ch in part)
               for part in value.split("_"))


# --- JSON the prompt carries ------------------------------------------------


def compact(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def goal_json(goal: GoalContext) -> str:
    """`Keeper_librarian.goal_context_to_json` key order, compact."""
    match goal:
        case NoTask():
            return compact({"status": "no_task"})
        case TaskWithoutGoal(task_id=tid):
            return compact({"task_id": tid, "status": "available", "goals": []})
        case TaskWithGoal(task_id=tid, goal_id=gid, revision=rev, goal=g):
            return compact({"task_id": tid, "status": "available", "goals": [{
                "goal_id": gid, "phase": "executing",
                "criterion": {"revision": rev, "title": g.title, "metric": g.metric,
                              "target_value": g.target_value}}]})
        case _:
            assert_never(goal)


# --- model output parsing ---------------------------------------------------


def _object(text: str) -> dict[str, object] | None:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[1] if "\n" in stripped else ""
        stripped = stripped.rsplit("```", 1)[0]
    try:
        value: object = json.loads(stripped)
    except json.JSONDecodeError:
        return None
    if not isinstance(value, dict):
        return None
    return cast(dict[str, object], value)


def _string(obj: dict[str, object], key: str) -> str | None:
    value = obj.get(key)
    return value.strip() if isinstance(value, str) and value.strip() else None


def parse_profile(text: str, key: str) -> KeeperProfile | None:
    obj = _object(text)
    if obj is None:
        return None
    role, world = _string(obj, "role_material"), _string(obj, "world")
    raw_categories, raw_goal = obj.get("categories"), obj.get("goal")
    if role is None or world is None or not isinstance(raw_categories, list) or not isinstance(raw_goal, dict):
        return None
    categories = tuple(dict.fromkeys(c for c in cast(list[object], raw_categories)
                                     if isinstance(c, str) and is_category_name(c)))
    goal_obj = cast(dict[str, object], raw_goal)
    title, metric, target = _string(goal_obj, "title"), _string(goal_obj, "metric"), _string(goal_obj, "target_value")
    if len(categories) < 6 or title is None or metric is None or target is None:
        return None
    return KeeperProfile(key, keeper_slug(key), role, world, categories, GoalDraft(title, metric, target))


def parse_claims(text: str) -> tuple[str, ...] | None:
    obj = _object(text)
    raw = obj.get("facts") if obj is not None else None
    if not isinstance(raw, list):
        return None
    claims: list[str] = []
    for item in cast(list[object], raw):
        if isinstance(item, dict):
            claim = _string(cast(dict[str, object], item), "claim")
            if claim is not None:
                claims.append(claim)
    return tuple(claims) if claims else None


def parse_single_claim(text: str) -> str | None:
    obj = _object(text)
    return _string(obj, "claim") if obj is not None else None
