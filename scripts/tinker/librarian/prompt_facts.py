# pyright: strict
"""The two typed sections of an admission prompt, written and read as MASC's JSON.

- current memory: keeper_librarian.ml:186-250 `surrogate_id_of_index`,
  `basis_for_prompt` and `format_current_selection_for_prompt`
- candidates: keeper_memory_admission_judgment.ml:149-153 `prompt_suffix` with
  keeper_memory_os_types.ml:783-797 `fact_to_json`

`current_memory_of` and `candidates_of` read back only what the writers give.

Pure: no I/O.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Literal, assert_never

from yojson_wire import (
    Absent,
    Json,
    JsonError,
    JsonObject,
    member,
    read_value_at,
)

type OriginKind = Literal["authored", "injected"]


@dataclass(frozen=True, slots=True)
class Transcript:
    """Observed in the Keeper's own transcript."""


@dataclass(frozen=True, slots=True)
class Board:
    """Observed on a Board post, or on one comment of it."""

    post_id: str
    comment_id: str | None


@dataclass(frozen=True, slots=True)
class PremisePaths:
    """A derived basis as the current-memory section shows it.

    One path per derivation, deduplicated and sorted by MASC; each premise is a
    short id (`mK`) or None when the premise is not in current memory
    (keeper_librarian.ml:191-207 `basis_for_prompt`).
    """

    paths: tuple[tuple[str | None, ...], ...]


type CurrentBasis = Transcript | Board | PremisePaths


@dataclass(frozen=True, slots=True)
class CurrentFact:
    """One current-memory fact. Its short id is `m<position + 1>`.

    `first_seen` and `last_seen` are the RFC 3339 text MASC shows
    (`rfc3339_of_unix`), not seconds.
    """

    claim: str
    category: str
    origin_kind: OriginKind
    basis: CurrentBasis
    first_seen: str
    last_seen: str


@dataclass(frozen=True, slots=True)
class CurrentMemory:
    facts: tuple[CurrentFact, ...]


@dataclass(frozen=True, slots=True)
class Derivation:
    rule_id: str
    premise_ids: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Derived:
    derivations: tuple[Derivation, ...]


type ProposedBasis = Transcript | Board | Derived


@dataclass(frozen=True, slots=True)
class Origin:
    kind: OriginKind
    trace_id: str


@dataclass(frozen=True, slots=True)
class ProposedFact:
    """A candidate's fact in `fact_to_json` order (keeper_memory_os_types.ml:783-797)."""

    claim: str
    category: str
    first_seen: float
    last_seen: float
    origin: Origin
    basis: ProposedBasis

    def __post_init__(self) -> None:
        # MASC's fact_to_json refuses a non-finite time with invalid_arg, so no
        # admission prompt carries one; refusing it here keeps `render` total.
        if not (math.isfinite(self.first_seen) and math.isfinite(self.last_seen)):
            raise ValueError("first_seen and last_seen must be finite")


@dataclass(frozen=True, slots=True)
class Candidate:
    request_id: str
    sequence: int
    proposed_fact: ProposedFact


@dataclass(frozen=True, slots=True)
class ParseError:
    detail: str


def surrogate_id(index: int) -> str:
    """keeper_librarian.ml:186 `surrogate_id_of_index`."""
    return f"m{index + 1}"


def _board_json(board: Board) -> JsonObject:
    members: tuple[tuple[str, Json], ...] = (("post_id", board.post_id),)
    if board.comment_id is not None:
        members += (("comment_id", board.comment_id),)
    return JsonObject(members)


def _observed_json(basis: Transcript | Board) -> JsonObject:
    match basis:
        case Transcript():
            return JsonObject((("kind", "observed"),))
        case Board():
            return JsonObject((("kind", "observed"), ("board", _board_json(basis))))
        case _:
            assert_never(basis)


def _current_basis_json(basis: CurrentBasis) -> JsonObject:
    match basis:
        case Transcript() | Board():
            return _observed_json(basis)
        case PremisePaths(paths=paths):
            return JsonObject((("kind", "derived"), ("derivations", tuple(tuple(path) for path in paths))))
        case _:
            assert_never(basis)


def current_memory_json(memory: CurrentMemory | None) -> Json:
    """keeper_librarian.ml:216-250 `format_current_selection_for_prompt`."""
    if memory is None:
        return None
    return JsonObject(
        (
            (
                "facts",
                tuple(
                    JsonObject(
                        (
                            ("memory_id", surrogate_id(index)),
                            (
                                "fact",
                                JsonObject(
                                    (
                                        ("claim", fact.claim),
                                        ("category", fact.category),
                                        ("origin", JsonObject((("kind", fact.origin_kind),))),
                                        ("basis", _current_basis_json(fact.basis)),
                                        ("first_seen", fact.first_seen),
                                        ("last_seen", fact.last_seen),
                                    )
                                ),
                            ),
                        )
                    )
                    for index, fact in enumerate(memory.facts)
                ),
            ),
        )
    )


def _proposed_basis_json(basis: ProposedBasis) -> JsonObject:
    match basis:
        case Transcript() | Board():
            return _observed_json(basis)
        case Derived(derivations=derivations):
            return JsonObject(
                (
                    ("kind", "derived"),
                    (
                        "derivations",
                        tuple(
                            JsonObject((("rule_id", item.rule_id), ("premise_ids", item.premise_ids)))
                            for item in derivations
                        ),
                    ),
                )
            )
        case _:
            assert_never(basis)


def proposed_fact_json(fact: ProposedFact) -> JsonObject:
    """keeper_memory_os_types.ml:783-797 `fact_to_json`.

    The times are `Float, so an int a caller passes still writes as `1762588800.0`.
    """
    return JsonObject(
        (
            ("claim", fact.claim),
            ("category", fact.category),
            ("first_seen", float(fact.first_seen)),
            ("last_seen", float(fact.last_seen)),
            ("origin", JsonObject((("kind", fact.origin.kind), ("trace_id", fact.origin.trace_id)))),
            ("basis", _proposed_basis_json(fact.basis)),
        )
    )


def candidates_json(candidates: tuple[Candidate, ...]) -> Json:
    return tuple(
        JsonObject(
            (
                ("request_id", candidate.request_id),
                ("sequence", candidate.sequence),
                ("proposed_fact", proposed_fact_json(candidate.proposed_fact)),
            )
        )
        for candidate in candidates
    )


def _string(value: Json | Absent) -> str | None:
    return value if isinstance(value, str) else None


def _int(value: Json | Absent) -> int | None:
    match value:
        case bool():
            return None
        case int():
            return value
        case _:
            return None


def _float(value: Json | Absent) -> float | None:
    return value if isinstance(value, float) and math.isfinite(value) else None


def _object(value: Json | Absent) -> JsonObject | None:
    return value if isinstance(value, JsonObject) else None


def _origin_kind(value: Json | Absent) -> OriginKind | None:
    match value:
        case "authored":
            return "authored"
        case "injected":
            return "injected"
        case _:
            return None


def _board_of(value: Json | Absent) -> Board | None:
    board = _object(value)
    if board is None:
        return None
    post_id = _string(member(board, "post_id"))
    comment = member(board, "comment_id")
    comment_id = None if isinstance(comment, Absent) else _string(comment)
    if post_id is None or (not isinstance(comment, Absent) and comment_id is None):
        return None
    return Board(post_id, comment_id)


def _observed_of(basis: JsonObject) -> Transcript | Board | None:
    board = member(basis, "board")
    return Transcript() if isinstance(board, Absent) else _board_of(board)


def _current_basis_of(value: Json | Absent) -> CurrentBasis | None:
    basis = _object(value)
    if basis is None:
        return None
    match member(basis, "kind"):
        case "observed":
            return _observed_of(basis)
        case "derived":
            derivations = member(basis, "derivations")
            if not isinstance(derivations, tuple):
                return None
            paths: list[tuple[str | None, ...]] = []
            for path in derivations:
                if not isinstance(path, tuple):
                    return None
                premises: list[str | None] = []
                for premise in path:
                    if premise is not None and not isinstance(premise, str):
                        return None
                    premises.append(premise)
                paths.append(tuple(premises))
            return PremisePaths(tuple(paths))
        case _:
            return None


def current_memory_of(text: str) -> CurrentMemory | None | ParseError:
    read = read_value_at(text, 0)
    if isinstance(read, JsonError):
        return ParseError("current_memory is not JSON")
    value = read[0]
    if value is None:
        return None
    memory = _object(value)
    facts = member(memory, "facts") if memory is not None else None
    if not isinstance(facts, tuple):
        return ParseError("current_memory has no facts list")
    typed: list[CurrentFact] = []
    for item in facts:
        row = _object(item)
        fact = _object(member(row, "fact")) if row is not None else None
        if fact is None:
            return ParseError("current_memory fact is not an object")
        claim = _string(member(fact, "claim"))
        category = _string(member(fact, "category"))
        origin = _object(member(fact, "origin"))
        kind = _origin_kind(member(origin, "kind")) if origin is not None else None
        basis = _current_basis_of(member(fact, "basis"))
        first_seen = _string(member(fact, "first_seen"))
        last_seen = _string(member(fact, "last_seen"))
        if (
            claim is None
            or category is None
            or kind is None
            or basis is None
            or first_seen is None
            or last_seen is None
        ):
            return ParseError("current_memory fact lacks a field")
        typed.append(CurrentFact(claim, category, kind, basis, first_seen, last_seen))
    return CurrentMemory(tuple(typed))


def _proposed_basis_of(value: Json | Absent) -> ProposedBasis | None:
    basis = _object(value)
    if basis is None:
        return None
    match member(basis, "kind"):
        case "observed":
            return _observed_of(basis)
        case "derived":
            derivations = member(basis, "derivations")
            if not isinstance(derivations, tuple):
                return None
            typed: list[Derivation] = []
            for item in derivations:
                derivation = _object(item)
                rule_id = _string(member(derivation, "rule_id")) if derivation is not None else None
                premises = member(derivation, "premise_ids") if derivation is not None else None
                if rule_id is None or not isinstance(premises, tuple):
                    return None
                premise_ids = tuple(premise for premise in premises if isinstance(premise, str))
                if len(premise_ids) != len(premises):
                    return None
                typed.append(Derivation(rule_id, premise_ids))
            return Derived(tuple(typed))
        case _:
            return None


def candidates_of(text: str) -> tuple[Candidate, ...] | ParseError:
    read = read_value_at(text, 0)
    if isinstance(read, JsonError) or not isinstance(read[0], tuple):
        return ParseError("candidate data is not a JSON array")
    typed: list[Candidate] = []
    for item in read[0]:
        row = _object(item)
        if row is None:
            return ParseError("candidate is not an object")
        request_id = _string(member(row, "request_id"))
        sequence = _int(member(row, "sequence"))
        fact = _object(member(row, "proposed_fact"))
        if request_id is None or sequence is None or fact is None:
            return ParseError("candidate lacks request_id, sequence or proposed_fact")
        claim = _string(member(fact, "claim"))
        category = _string(member(fact, "category"))
        first_seen = _float(member(fact, "first_seen"))
        last_seen = _float(member(fact, "last_seen"))
        origin = _object(member(fact, "origin"))
        kind = _origin_kind(member(origin, "kind")) if origin is not None else None
        trace_id = _string(member(origin, "trace_id")) if origin is not None else None
        basis = _proposed_basis_of(member(fact, "basis"))
        if (
            claim is None
            or category is None
            or first_seen is None
            or last_seen is None
            or kind is None
            or trace_id is None
            or basis is None
        ):
            return ParseError("proposed fact lacks a field")
        fact_value = ProposedFact(claim, category, first_seen, last_seen, Origin(kind, trace_id), basis)
        typed.append(Candidate(request_id, sequence, fact_value))
    return tuple(typed)
