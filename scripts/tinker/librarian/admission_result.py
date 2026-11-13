# pyright: strict
"""What `admission_validator.validate` returns: the accepted answer or one refusal.

`Kind` names each rule MASC enforces, in the order MASC checks them, and
`masc_rule` gives the OCaml line that enforces it. `PROMPT_ONLY_RULES` lists
what the prompt asks for and no MASC code checks.

Pure: no I/O.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Literal, assert_never


class Kind(Enum):
    """Why MASC refuses an answer. One kind per enforced rule, in check order."""

    INVALID_JSON = "invalid_json"
    DUPLICATE_MEMBER = "duplicate_member"
    NON_FINITE_NUMBER = "non_finite_number"
    NOT_AN_OBJECT = "not_an_object"
    MISSING_REQUIRED_KEY = "missing_required_key"
    INCOMPATIBLE_SHAPE = "incompatible_shape"
    WRAPPER_FIELDS = "wrapper_fields"
    JUDGMENT_NOT_OBJECT = "judgment_not_object"
    JUDGMENT_FIELDS = "judgment_fields"
    JUDGMENT_REQUEST_ID_INVALID = "judgment_request_id_invalid"
    JUDGMENT_REASON_INVALID = "judgment_reason_invalid"
    JUDGMENT_OUTCOME_INVALID = "judgment_outcome_invalid"
    JUDGMENT_CLAIM_REQUIRED = "judgment_claim_required"
    JUDGMENT_CLAIM_NOT_NULL = "judgment_claim_not_null"
    CHANGE_SUPPORT_ITEM_INVALID = "change_support_item_invalid"
    UNKNOWN_REQUEST_ID = "unknown_request_id"
    DUPLICATE_REQUEST_ID = "duplicate_request_id"
    MISSING_REQUEST_ID = "missing_request_id"
    MEMORY_UNEXPECTED_FIELD = "memory_unexpected_field"
    CLAIM_UNEXPECTED_FIELD = "claim_unexpected_field"
    DROPPED_UNEXPECTED_FIELD = "dropped_unexpected_field"
    CLAIM_NOT_OBJECT = "claim_not_object"
    CLAIM_TEXT_INVALID = "claim_text_invalid"
    CLAIM_CATEGORY_INVALID = "claim_category_invalid"
    CLAIM_BOARD_INVALID = "claim_board_invalid"
    CLAIM_SUPERSEDES_INVALID = "claim_supersedes_invalid"
    CLAIM_ABSORBS_INVALID = "claim_absorbs_invalid"
    CLAIM_EVIDENCE_INVALID = "claim_evidence_invalid"
    DROPPED_NOT_OBJECT = "dropped_not_object"
    DROPPED_MEMORY_ID_INVALID = "dropped_memory_id_invalid"
    DROPPED_REASON_INVALID = "dropped_reason_invalid"
    UNKNOWN_DROPPED_MEMORY_ID = "unknown_dropped_memory_id"
    ABSORBS_UNKNOWN_MEMORY_ID = "absorbs_unknown_memory_id"
    ABSORBS_DROPPED_MEMORY_ID = "absorbs_dropped_memory_id"
    ABSORBS_MEMORY_ID_TWICE = "absorbs_memory_id_twice"
    DUPLICATE_DROPPED_MEMORY_ID = "duplicate_dropped_memory_id"
    DROPPED_MEMORY_ID_RECREATED = "dropped_memory_id_recreated"
    EVIDENCE_NOT_IN_INPUT = "evidence_not_in_input"
    SUPERSEDES_UNKNOWN_MEMORY_ID = "supersedes_unknown_memory_id"
    SUPERSEDES_NOT_DROPPED = "supersedes_not_dropped"
    MEMORY_CLAIM_ABSENT = "memory_claim_absent"
    DUPLICATE_CHANGE_SUPPORT = "duplicate_change_support"
    UNKNOWN_CHANGE_SUPPORT = "unknown_change_support"
    UNSETTLED_CHANGE_SUPPORT = "unsettled_change_support"
    NEW_CLAIM_WITHOUT_SUPPORT = "new_claim_without_support"


def masc_rule(kind: Kind) -> str:
    """Where MASC enforces the rule (main d2bc93109055)."""
    match kind:
        case Kind.INVALID_JSON:
            return "exact_output_plan.ml:641 normalize_json"
        case Kind.DUPLICATE_MEMBER:
            return "lane_addon_action.ml:23 unique"
        case Kind.NON_FINITE_NUMBER:
            return "lane_addon_action.ml:49 canonical"
        case Kind.NOT_AN_OBJECT:
            return "lane_addon_action.ml:204 validate_input"
        case Kind.MISSING_REQUIRED_KEY | Kind.INCOMPATIBLE_SHAPE:
            return "lane_addon_exact_shape.ml:7 issue"
        case Kind.WRAPPER_FIELDS | Kind.CHANGE_SUPPORT_ITEM_INVALID:
            return "keeper_memory_admission_judgment.ml:47 wrapper_of_json"
        case (
            Kind.JUDGMENT_NOT_OBJECT
            | Kind.JUDGMENT_FIELDS
            | Kind.JUDGMENT_REQUEST_ID_INVALID
            | Kind.JUDGMENT_REASON_INVALID
            | Kind.JUDGMENT_OUTCOME_INVALID
            | Kind.JUDGMENT_CLAIM_REQUIRED
            | Kind.JUDGMENT_CLAIM_NOT_NULL
        ):
            return "keeper_memory_admission_judgment.ml:22 judgment_of_json"
        case Kind.UNKNOWN_REQUEST_ID | Kind.DUPLICATE_REQUEST_ID | Kind.MISSING_REQUEST_ID:
            return "keeper_memory_admission_judgment.ml:71 unwrap"
        case Kind.MEMORY_UNEXPECTED_FIELD | Kind.CLAIM_UNEXPECTED_FIELD | Kind.DROPPED_UNEXPECTED_FIELD:
            return "keeper_librarian.ml:460 first_object_field_error"
        case (
            Kind.CLAIM_NOT_OBJECT
            | Kind.CLAIM_TEXT_INVALID
            | Kind.CLAIM_CATEGORY_INVALID
            | Kind.CLAIM_BOARD_INVALID
        ):
            return "keeper_librarian.ml:518 fact_of_json"
        case Kind.CLAIM_SUPERSEDES_INVALID | Kind.CLAIM_ABSORBS_INVALID:
            return "keeper_librarian.ml:641 new_claim_of_json"
        case Kind.CLAIM_EVIDENCE_INVALID:
            return "keeper_librarian.ml:592 evidence_of_json"
        case Kind.DROPPED_NOT_OBJECT | Kind.DROPPED_MEMORY_ID_INVALID | Kind.DROPPED_REASON_INVALID:
            return "keeper_librarian.ml:688 dropped_statement_of_json"
        case Kind.UNKNOWN_DROPPED_MEMORY_ID:
            return "keeper_librarian.ml:714 translate_dropped_ids"
        case Kind.ABSORBS_UNKNOWN_MEMORY_ID | Kind.ABSORBS_DROPPED_MEMORY_ID | Kind.ABSORBS_MEMORY_ID_TWICE:
            return "keeper_librarian.ml:877 translate_absorbs"
        case Kind.DUPLICATE_DROPPED_MEMORY_ID | Kind.DROPPED_MEMORY_ID_RECREATED:
            return "keeper_librarian.ml:926 materialize_facts"
        case Kind.EVIDENCE_NOT_IN_INPUT:
            return "keeper_librarian.ml:989 citation_not_in_input"
        case Kind.SUPERSEDES_UNKNOWN_MEMORY_ID | Kind.SUPERSEDES_NOT_DROPPED:
            return "keeper_librarian.ml:731 translate_revisions"
        case Kind.MEMORY_CLAIM_ABSENT:
            return "keeper_memory_admission_judgment.ml:92 verify"
        case (
            Kind.DUPLICATE_CHANGE_SUPPORT
            | Kind.UNKNOWN_CHANGE_SUPPORT
            | Kind.UNSETTLED_CHANGE_SUPPORT
            | Kind.NEW_CLAIM_WITHOUT_SUPPORT
        ):
            return "keeper_memory_admission_judgment.ml:109 verify_support"
        case _:
            assert_never(kind)


# Rules the prompt or the schema description states and no MASC code checks
# when it accepts an admission answer.
PROMPT_ONLY_RULES: tuple[str, ...] = (
    (
        "working_contexts content (Keeper_librarian_context.select failure is kept as "
        "Working_contexts_invalid and does not refuse the answer)"
    ),
    "working_state value (only its presence is required; type is a list type the shape check skips)",
    (
        "schema additionalProperties=false, enum, minLength, minItems and array items "
        "(the shape check reads type, required and properties only)"
    ),
    "category reuse and naming advice beyond the category grammar",
    "keep, drop and correct judgment quality, durability of what is incorporated",
    (
        "category caps and facts budget in memory_limits/facts_budget (advisory in the prompt; "
        "the budget is checked at commit, not here)"
    ),
    "evidence meaning beyond positions and flags; Board id existence",
    "dropped reason and judgment reason content beyond being non-blank",
)


@dataclass(frozen=True, slots=True)
class Violation:
    """One refusal. `detail` is MASC's reason text where this port rebuilds it."""

    kind: Kind
    detail: str


type Outcome = Literal["incorporated", "already_represented", "not_durable", "deferred"]


@dataclass(frozen=True, slots=True)
class Judgment:
    request_id: str
    outcome: Outcome
    memory_claim: str | None
    reason: str


@dataclass(frozen=True, slots=True)
class AdmissionAnswer:
    """What MASC reads from an accepted answer.

    Memory ids are the short ids the prompt shows (`m1`...), as the answer
    wrote them after trimming. `deferred` is MASC's `Deferred` proposal: no
    candidate is settled, so nothing commits.
    """

    judgments: tuple[Judgment, ...]
    change_support: tuple[str, ...]
    deferred: bool
    added_claims: tuple[str, ...]
    dropped: tuple[str, ...]
    absorbed: tuple[tuple[str, str], ...]
    revisions: tuple[tuple[str, str], ...]
    memory_after: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Valid:
    answer: AdmissionAnswer


@dataclass(frozen=True, slots=True)
class Invalid:
    violations: tuple[Violation, ...]
