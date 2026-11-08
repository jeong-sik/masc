# pyright: strict
"""keeper_librarian.ml `selection_of_json_result` over an admission answer's `memory`.

Claims and dropped statements (518-698), evidence (592-632), one claim per
text (806-838) and the selection (1051-1157), with the keeper_memory_os_types.ml
parsers they call: `memory_id`, `category_of_string` and `board_ref_of_ids`.

Pure: no I/O.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

from admission_request import AdmissionPrompt
from admission_result import Kind, Violation
from lane_addon_checks import Shaped
from ocaml_text import ocaml_trim
from prompt_facts import Board, surrogate_id
from yojson_wire import (
    Absent,
    Json,
    JsonObject,
    member,
)


def memory_id(claim: str) -> str:
    """keeper_memory_os_types.ml:779 `memory_id`: sha256 of the claim bytes."""
    return "sha256:" + hashlib.sha256(claim.encode("utf-8", "surrogatepass")).hexdigest()


def _first_field_error(allowed: tuple[str, ...], obj: JsonObject) -> str | None:
    """keeper_librarian.ml:460 `first_object_field_error`: the first unexpected name.

    A repeated name cannot reach here: `canonical` refuses it first.
    """
    for name, _ in obj.members:
        if name not in allowed:
            return name
    return None


def _trim_nonempty(value: Json | Absent) -> str | None:
    """`string_field`: a string member, trimmed, not empty."""
    if not isinstance(value, str):
        return None
    trimmed = ocaml_trim(value)
    return trimmed if trimmed != "" else None


_MEMORY_FIELDS = ("new_claims", "dropped", "working_contexts", "working_state")


CLAIM_FIELDS = (
    "claim",
    "category",
    "board_post_id",
    "board_comment_id",
    "supersedes",
    "absorbs",
    "evidence",
)


DROPPED_FIELDS = ("memory_id", "reason")


EVIDENCE_FIELDS = ("conversation", "tools", "counterpart", "task_contexts")


_KNOWN_CATEGORIES = frozenset(
    {"code_change", "fact", "preference", "blocker", "goal", "constraint", "validated_approach", "lesson"}
)


_CUSTOM_CATEGORY = re.compile(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*")


_POST_ID = re.compile(r"[a-zA-Z0-9_-]+")


_COMMENT_ID = re.compile(r"c-[0-9a-f]{32}")


_POST_ID_MAX_LENGTH = 64


def category_valid(name: str) -> bool:
    """keeper_memory_os_types.ml:415-438 `category_of_string`."""
    if name in _KNOWN_CATEGORIES:
        return True
    if name in ("all", "source", "dropped"):
        return False
    return _CUSTOM_CATEGORY.fullmatch(name) is not None


def _board_ref(post_id: str, comment_id: str | None) -> Board | None:
    """keeper_memory_os_types.ml:622 `board_ref_of_ids` with board_types.ml grammars."""
    post = ocaml_trim(post_id)
    if not (1 <= len(post) <= _POST_ID_MAX_LENGTH and _POST_ID.fullmatch(post)):
        return None
    if comment_id is None:
        return Board(post, None)
    comment = ocaml_trim(comment_id)
    return Board(post, comment) if _COMMENT_ID.fullmatch(comment) else None


@dataclass(frozen=True, slots=True)
class _Evidence:
    conversation: tuple[int, ...]
    tools: tuple[int, ...]
    counterpart: bool
    task_contexts: bool


_NO_EVIDENCE = _Evidence((), (), False, False)


@dataclass(frozen=True, slots=True)
class _Claim:
    claim: str
    supersedes: str | None
    absorbs: tuple[str, ...]
    evidence: _Evidence


@dataclass(frozen=True, slots=True)
class _Unbound:
    """A board member that is absent or null: the claim was read in the transcript."""


@dataclass(frozen=True, slots=True)
class _Rejected:
    """A member present with a value the claim parser refuses."""


def _board_member(value: Json | Absent) -> str | _Unbound | _Rejected:
    match value:
        case Absent() | None:
            return _Unbound()
        case str():
            trimmed = _trim_nonempty(value)
            return trimmed if trimmed is not None else _Rejected()
        case _:
            return _Rejected()


def _positions(value: Json | Absent) -> tuple[int, ...] | None:
    match value:
        case Absent() | None:
            return ()
        case tuple():
            numbers: list[int] = []
            for item in value:
                match item:
                    case bool():
                        return None
                    case int():
                        numbers.append(item)
                    case _:
                        return None
            return tuple(sorted(set(numbers)))
        case _:
            return None


def _flag(value: Json | Absent) -> bool | None:
    match value:
        case Absent() | None:
            return False
        case bool():
            return value
        case _:
            return None


def _evidence_of(value: Json) -> _Evidence | None:
    """keeper_librarian.ml:592-632 `evidence_of_json`."""
    if value is None:
        return _NO_EVIDENCE
    if not isinstance(value, JsonObject) or _first_field_error(EVIDENCE_FIELDS, value) is not None:
        return None
    conversation = _positions(member(value, "conversation"))
    tools = _positions(member(value, "tools"))
    counterpart = _flag(member(value, "counterpart"))
    task_contexts = _flag(member(value, "task_contexts"))
    if conversation is None or tools is None or counterpart is None or task_contexts is None:
        return None
    return _Evidence(conversation, tools, counterpart, task_contexts)


def _claim_of(item: Json) -> _Claim | Kind:
    """keeper_librarian.ml:518-676 `fact_of_json` and `new_claim_of_json`.

    MASC answers every failure here with `claim_schema_mismatch`; the kind
    names which member failed, checked in member order.
    """
    if not isinstance(item, JsonObject):
        return Kind.CLAIM_NOT_OBJECT
    claim = _trim_nonempty(member(item, "claim"))
    if claim is None:
        return Kind.CLAIM_TEXT_INVALID
    category = member(item, "category")
    if not (isinstance(category, str) and category_valid(category)):
        return Kind.CLAIM_CATEGORY_INVALID
    post = _board_member(member(item, "board_post_id"))
    comment = _board_member(member(item, "board_comment_id"))
    match (post, comment):
        case (_Rejected(), _) | (_, _Rejected()):
            return Kind.CLAIM_BOARD_INVALID
        case (_Unbound(), str()):
            # A comment without its post.
            return Kind.CLAIM_BOARD_INVALID
        case (str() as post_id, _Unbound()):
            if _board_ref(post_id, None) is None:
                return Kind.CLAIM_BOARD_INVALID
        case (str() as post_id, str() as comment_id):
            if _board_ref(post_id, comment_id) is None:
                return Kind.CLAIM_BOARD_INVALID
        case (_Unbound(), _Unbound()):
            pass
    supersedes_value = member(item, "supersedes")
    supersedes: str | None = None
    match supersedes_value:
        case Absent() | None:
            pass
        case str():
            supersedes = _trim_nonempty(supersedes_value)
            if supersedes is None:
                return Kind.CLAIM_SUPERSEDES_INVALID
        case _:
            return Kind.CLAIM_SUPERSEDES_INVALID
    absorbs_value = member(item, "absorbs")
    absorbs: list[str] = []
    match absorbs_value:
        case Absent() | None:
            pass
        case tuple():
            for token in absorbs_value:
                trimmed = _trim_nonempty(token)
                if trimmed is None:
                    return Kind.CLAIM_ABSORBS_INVALID
                absorbs.append(trimmed)
        case _:
            return Kind.CLAIM_ABSORBS_INVALID
    evidence_value = member(item, "evidence")
    evidence = _NO_EVIDENCE if isinstance(evidence_value, Absent) else _evidence_of(evidence_value)
    if evidence is None:
        return Kind.CLAIM_EVIDENCE_INVALID
    return _Claim(claim, supersedes, tuple(absorbs), evidence)


def _dropped_of(item: Json) -> tuple[str, str] | Kind:
    """keeper_librarian.ml:688-698 `dropped_statement_of_json`: (short id, reason), trimmed."""
    if not isinstance(item, JsonObject):
        return Kind.DROPPED_NOT_OBJECT
    token = _trim_nonempty(member(item, "memory_id"))
    if token is None:
        return Kind.DROPPED_MEMORY_ID_INVALID
    reason = _trim_nonempty(member(item, "reason"))
    if reason is None:
        return Kind.DROPPED_REASON_INVALID
    return token, reason


def _union(left: _Evidence, right: _Evidence) -> _Evidence:
    return _Evidence(
        tuple(sorted(set(left.conversation) | set(right.conversation))),
        tuple(sorted(set(left.tools) | set(right.tools))),
        left.counterpart or right.counterpart,
        left.task_contexts or right.task_contexts,
    )


def _merge_same_claims(stated: tuple[_Claim, ...]) -> tuple[_Claim, ...]:
    """keeper_librarian.ml:806-838: one claim per text; the first keeps its fields."""
    merged: list[_Claim] = []
    for claim in stated:
        at = next((index for index, kept in enumerate(merged) if kept.claim == claim.claim), None)
        if at is None:
            merged.append(claim)
            continue
        first = merged[at]
        added = tuple(token for token in claim.absorbs if token not in first.absorbs)
        merged[at] = _Claim(
            first.claim, first.supersedes, first.absorbs + added, _union(first.evidence, claim.evidence)
        )
    return tuple(merged)


def _citation(evidence: _Evidence) -> str | None:
    """keeper_librarian.ml:989-1002 with the admission input, which has no observations."""
    if evidence.conversation:
        return f"conversation {evidence.conversation[0]}"
    if evidence.tools:
        return f"tools {evidence.tools[0]}"
    if evidence.counterpart:
        return "counterpart"
    if evidence.task_contexts:
        return "task_contexts"
    return None


@dataclass(frozen=True, slots=True)
class Selection:
    added_claims: tuple[str, ...]
    dropped: tuple[str, ...]
    absorbed: tuple[tuple[str, str], ...]
    revisions: tuple[tuple[str, str], ...]
    memory_after: tuple[str, ...]


def select(prompt: AdmissionPrompt, shaped: Shaped) -> Selection | Violation:
    """keeper_librarian.ml:1051-1157 `selection_of_json_result` for an admission input."""
    unexpected = _first_field_error(_MEMORY_FIELDS, shaped.memory)
    if unexpected is not None:
        return Violation(Kind.MEMORY_UNEXPECTED_FIELD, "unexpected_field: " + unexpected)
    for item in shaped.new_claims:
        if isinstance(item, JsonObject) and (name := _first_field_error(CLAIM_FIELDS, item)) is not None:
            return Violation(Kind.CLAIM_UNEXPECTED_FIELD, "unexpected_field: " + name)
    for item in shaped.dropped:
        if isinstance(item, JsonObject) and (name := _first_field_error(DROPPED_FIELDS, item)) is not None:
            return Violation(Kind.DROPPED_UNEXPECTED_FIELD, "unexpected_field: " + name)
    stated_list: list[_Claim] = []
    for item in shaped.new_claims:
        claim = _claim_of(item)
        if isinstance(claim, Kind):
            return Violation(claim, "claim_schema_mismatch")
        stated_list.append(claim)
    stated = tuple(stated_list)
    dropped_list: list[tuple[str, str]] = []
    for item in shaped.dropped:
        statement = _dropped_of(item)
        if isinstance(statement, Kind):
            return Violation(statement, "dropped_schema_mismatch")
        dropped_list.append(statement)

    merged = _merge_same_claims(stated)
    current = prompt.current_memory.facts if prompt.current_memory is not None else ()
    current_ids = tuple(memory_id(fact.claim) for fact in current)
    by_surrogate = {surrogate_id(index): identity for index, identity in enumerate(current_ids)}

    dropped_ids: list[str] = []
    for token, _ in dropped_list:
        identity = by_surrogate.get(token)
        if identity is None:
            return Violation(Kind.UNKNOWN_DROPPED_MEMORY_ID, "unknown_dropped_memory_id: " + token)
        dropped_ids.append(identity)
    dropped_set = frozenset(dropped_ids)

    current_set = frozenset(current_ids)
    absorbed_by_another = frozenset(
        target
        for claim in merged
        for token in claim.absorbs
        if (target := by_surrogate.get(token)) is not None and target != memory_id(claim.claim)
    )
    ignored = frozenset(
        identity
        for claim in merged
        if (identity := memory_id(claim.claim)) in current_set and identity in absorbed_by_another
    )
    applied = tuple(claim for claim in merged if memory_id(claim.claim) not in ignored)

    absorbed_seen: set[str] = set()
    absorbed: list[tuple[str, str]] = []
    for claim in applied:
        into = memory_id(claim.claim)
        for token in claim.absorbs:
            target = by_surrogate.get(token)
            if target is None:
                return Violation(Kind.ABSORBS_UNKNOWN_MEMORY_ID, "absorbs_unknown_memory_id: " + token)
            if target == into:
                continue
            if target in dropped_set:
                return Violation(Kind.ABSORBS_DROPPED_MEMORY_ID, "absorbs_dropped_memory_id: " + target)
            if target in absorbed_seen:
                return Violation(Kind.ABSORBS_MEMORY_ID_TWICE, "absorbs_memory_id_twice: " + target)
            absorbed_seen.add(target)
            absorbed.append((token, claim.claim))

    seen_dropped: set[str] = set()
    for identity in dropped_ids:
        if identity in seen_dropped:
            return Violation(Kind.DUPLICATE_DROPPED_MEMORY_ID, "duplicate_dropped_memory_id: " + identity)
        seen_dropped.add(identity)
    retained = tuple(
        fact.claim
        for fact, identity in zip(current, current_ids)
        if identity not in dropped_set and identity not in absorbed_seen
    )
    added: list[str] = []
    for claim in applied:
        identity = memory_id(claim.claim)
        if identity in dropped_set:
            return Violation(Kind.DROPPED_MEMORY_ID_RECREATED, "dropped_memory_id_recreated: " + identity)
        if identity not in current_set:
            added.append(claim.claim)

    for claim in applied:
        citation = _citation(claim.evidence)
        if citation is not None:
            return Violation(Kind.EVIDENCE_NOT_IN_INPUT, "evidence_not_in_input: " + citation)

    revisions: list[tuple[str, str]] = []
    revision_ids: list[tuple[str, str]] = []
    for claim in stated:
        if claim.supersedes is None:
            continue
        superseded = by_surrogate.get(claim.supersedes)
        if superseded is None:
            return Violation(
                Kind.SUPERSEDES_UNKNOWN_MEMORY_ID, "supersedes_unknown_memory_id: " + claim.supersedes
            )
        identity = memory_id(claim.claim)
        if identity in ignored:
            continue
        if superseded not in dropped_set:
            return Violation(Kind.SUPERSEDES_NOT_DROPPED, "supersedes_not_dropped: " + superseded)
        if (superseded, identity) not in revision_ids:
            revision_ids.append((superseded, identity))
            revisions.append((claim.supersedes, claim.claim))

    return Selection(
        added_claims=tuple(added),
        dropped=tuple(token for token, _ in dropped_list),
        absorbed=tuple(absorbed),
        revisions=tuple(revisions),
        memory_after=retained + tuple(added),
    )
