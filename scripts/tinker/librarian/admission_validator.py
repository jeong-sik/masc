# pyright: strict
"""MASC's acceptance checks for a keeper-librarian admission answer.

`validate(prompt, answer_text)` follows the path an exact-lane admission answer
takes in MASC (main d2bc93109055) and stops at the first refusal, as MASC does,
so `Invalid` carries exactly one violation:

1. exact_output_plan.ml:641-647 `normalize_json`: `Yojson.Safe.from_string`
   (yojson_wire.py)
2. lane_addon_action.ml:23-58 `canonical`: duplicate members, non-finite numbers
   (lane_addon_checks.py)
3. lane_addon_action.ml:204-207 `validate_input` with
   addons/keeper-librarian/schemas/admission.json: the answer is an object
4. lane_addon_exact.ml:106-116 with lane_addon_exact_shape.ml:7-54 `issue`
   against the admission output schema (keeper_memory_admission_judgment.ml:132-147)
   (lane_addon_checks.py)
5. keeper_librarian_runtime.ml:1037-1085 `validate_admission_proposal`, read by
   server_librarian_addon_validation.ml:137 as the lane's `validate_output`:
   keeper_memory_admission_judgment.ml:22-90 `unwrap` (admission_judgment.py),
   keeper_librarian.ml:1051-1157 `selection_of_json_result` (librarian_selection.py),
   keeper_memory_admission_judgment.ml:92-130 `verify` and `verify_support`
   (admission_judgment.py). Since RFC-0517 §7.1, `verify_support` checks only the
   new claims `validate_admission_proposal` picks as additions
   (`admission_judgment.additions`)

The result types and rule kinds are in admission_result.py.

Only what MASC code enforces is here. Rules the prompt states but no code
checks are listed in PROMPT_ONLY_RULES and are not checked.

Pure: no I/O.
"""

from __future__ import annotations

import admission_judgment
import lane_addon_checks
import librarian_selection
from admission_request import AdmissionPrompt
from admission_result import (
    PROMPT_ONLY_RULES,
    AdmissionAnswer,
    Invalid,
    Judgment,
    Kind,
    Outcome,
    Valid,
    Violation,
    masc_rule,
)
from librarian_selection import category_valid, memory_id
from yojson_wire import Json, JsonError, JsonObject
from yojson_wire import parse as parse_json

__all__ = [
    "PROMPT_ONLY_RULES",
    "AdmissionAnswer",
    "Invalid",
    "Judgment",
    "Kind",
    "Outcome",
    "Valid",
    "Violation",
    "admission_output_schema",
    "category_valid",
    "masc_rule",
    "memory_id",
    "validate",
]


def _refuse(violation: Violation) -> Invalid:
    return Invalid((violation,))


def validate(prompt: AdmissionPrompt, answer_text: str) -> Valid | Invalid:
    """Accept or refuse `answer_text` as MASC does for this prompt."""
    parsed = parse_json(answer_text)
    if isinstance(parsed, JsonError):
        return _refuse(
            Violation(Kind.INVALID_JSON, f"invalid JSON at offset {parsed.offset}: {parsed.detail}")
        )
    canonical = lane_addon_checks.canonical(parsed)
    if isinstance(canonical, Violation):
        return _refuse(canonical)
    if not isinstance(canonical, JsonObject):
        return _refuse(Violation(Kind.NOT_AN_OBJECT, "the answer is not a JSON object"))
    shaped = lane_addon_checks.shape(canonical)
    if isinstance(shaped, Violation):
        return _refuse(shaped)
    unwrapped = admission_judgment.unwrap(prompt, shaped)
    if isinstance(unwrapped, Violation):
        return _refuse(unwrapped)
    judgments, support = unwrapped
    selection = librarian_selection.select(prompt, shaped)
    if isinstance(selection, Violation):
        return _refuse(selection)
    refusal = admission_judgment.verify(judgments, selection) or admission_judgment.verify_support(
        judgments, support, admission_judgment.additions(selection)
    )
    if refusal is not None:
        return _refuse(refusal)
    settled = any(judgment.outcome != "deferred" for judgment in judgments)
    return Valid(
        AdmissionAnswer(
            judgments=judgments,
            change_support=support,
            deferred=not settled,
            added_claims=selection.added_claims,
            dropped=selection.dropped,
            absorbed=selection.absorbed,
            revisions=selection.revisions,
            memory_after=selection.memory_after,
        )
    )


def admission_output_schema() -> Json:
    """The schema MASC sends with every admission request, in its stored canonical form.

    keeper_memory_admission_judgment.ml:132-147 with
    keeper_structured_output_schema.ml librarian_current_output_schema, keys
    sorted by `canonical`. `lane_addon_checks.shape` is written against this schema; the store
    check compares it with each retained request.
    """
    nullable = JsonObject((("type", ("string", "null")),))
    text = JsonObject((("type", "string"),))

    def obj(fields: tuple[tuple[str, Json], ...], required: tuple[str, ...]) -> JsonObject:
        ordered = tuple(sorted(fields, key=lambda pair: pair[0]))
        return JsonObject(
            (
                ("additionalProperties", False),
                ("properties", JsonObject(ordered)),
                ("required", required),
                ("type", "object"),
            )
        )

    def array(items: Json, *extra: tuple[str, Json]) -> JsonObject:
        return JsonObject(
            tuple(sorted((("items", items), ("type", "array"), *extra), key=lambda pair: pair[0]))
        )

    def described(kind: Json, description: str) -> JsonObject:
        return JsonObject((("description", description), ("type", kind)))

    positions = (
        "turn=N numbers of the conversation messages this claim relies on. Use [] when none.",
        "index numbers of the tool observations this claim relies on. Use [] when none.",
    )
    evidence = obj(
        (
            ("conversation", array(JsonObject((("type", "integer"),)), ("description", positions[0]))),
            ("tools", array(JsonObject((("type", "integer"),)), ("description", positions[1]))),
            (
                "counterpart",
                described("boolean", "true when this claim relies on the counterpart observations."),
            ),
            (
                "task_contexts",
                described("boolean", "true when this claim relies on the past Task/Goal contexts."),
            ),
        ),
        librarian_selection.EVIDENCE_FIELDS,
    )
    claim = obj(
        (
            ("claim", text),
            (
                "category",
                described(
                    "string",
                    "A lowercase snake_case category. Reuse a current category for the same topic; "
                    "create a new descriptive name when needed. Start with a letter, use letters/digits "
                    "and single underscores between nonempty words.",
                ),
            ),
            ("board_post_id", nullable),
            ("board_comment_id", nullable),
            (
                "supersedes",
                described(
                    ("string", "null"),
                    "Correction of a current memory: copy its short ID here and also into dropped. "
                    "Use null when this claim does not correct a memory. Do not put this ID in absorbs.",
                ),
            ),
            (
                "absorbs",
                array(
                    text,
                    (
                        "description",
                        (
                            "Short IDs of current memories whose still-valid knowledge this claim consolidates. "
                            "Do not request separate deletion: never also list these IDs in dropped or supersedes. "
                            "Each ID belongs to only one new claim. Use [] when consolidating none."
                        ),
                    ),
                ),
            ),
            ("evidence", evidence),
        ),
        librarian_selection.CLAIM_FIELDS,
    )
    dropped = obj(
        (
            (
                "memory_id",
                described(
                    "string",
                    "Short ID of a current memory to delete or correct. Corrected IDs also appear in a new "
                    "claim's supersedes. IDs consolidated through absorbs must not appear here.",
                ),
            ),
            ("reason", text),
        ),
        librarian_selection.DROPPED_FIELDS,
    )
    string_list = array(text)
    context = obj(
        (
            ("merge_contexts", string_list),
            ("sources", array(text, ("minItems", 1))),
            ("context", text),
            ("next_steps", string_list),
        ),
        ("merge_contexts", "sources", "context", "next_steps"),
    )
    memory = obj(
        (
            ("new_claims", array(claim)),
            ("dropped", array(dropped)),
            ("working_state", nullable),
            ("working_contexts", array(context)),
        ),
        ("new_claims", "dropped", "working_state", "working_contexts"),
    )
    nonblank = JsonObject((("minLength", 1), ("type", "string")))
    outcome = JsonObject(
        (
            ("enum", ("incorporated", "already_represented", "not_durable", "deferred")),
            ("type", "string"),
        )
    )
    candidate = obj(
        (
            ("request_id", nonblank),
            ("outcome", outcome),
            ("memory_claim", nullable),
            ("reason", nonblank),
        ),
        admission_judgment.JUDGMENT_FIELDS,
    )
    return obj(
        (("memory", memory), ("candidates", array(candidate)), ("change_support", array(nonblank))),
        admission_judgment.WRAPPER_FIELDS,
    )
