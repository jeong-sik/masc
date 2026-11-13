# pyright: strict
"""keeper_memory_admission_judgment.ml: the judgments wrapper and the support checks.

- `unwrap`: 17-90 `nonblank`, `wrapper_of_json` and `unwrap`, with the
  keeper_memory_os_types.ml:153 `field_set_rejection` reason text
- `verify` and `verify_support`: 92-128
- `additions`: keeper_librarian_runtime.ml:1103-1113, the new claims
  `validate_admission_proposal` passes to `verify_support`

Pure: no I/O.
"""

from __future__ import annotations

from admission_request import AdmissionPrompt
from admission_result import Judgment, Kind, Violation
from lane_addon_checks import Shaped
from librarian_selection import Selection
from ocaml_text import ocaml_quoted, ocaml_trim
from yojson_wire import (
    Absent,
    Json,
    JsonObject,
    member,
)


def _field_set_mismatch(missing: list[str], unexpected: list[str]) -> str:
    return "field set mismatch (missing: {}) (unexpected: {})".format(
        ",".join(missing) if missing else "none",
        ",".join(unexpected) if unexpected else "none",
    )


def _exact_fields(allowed: tuple[str, ...], obj: JsonObject) -> str | None:
    """keeper_memory_os_types.ml:153 `field_set_rejection`, as reason text."""
    seen: set[str] = set()
    for name, _ in obj.members:
        if name in seen:
            return f"field {ocaml_quoted(name)} appears more than once"
        seen.add(name)
    missing = sorted(set(allowed) - seen)
    unexpected = sorted(seen - set(allowed))
    if missing or unexpected:
        return _field_set_mismatch(missing, unexpected)
    return None


JUDGMENT_FIELDS = ("request_id", "outcome", "memory_claim", "reason")


WRAPPER_FIELDS = ("memory", "candidates", "change_support")


def _admission_invalid(kind: Kind, detail: str) -> Violation:
    return Violation(kind, "admission_invalid: " + detail)


def _nonblank(kind: Kind, path: str, value: Json | Absent) -> str | Violation:
    """keeper_memory_admission_judgment.ml:17 `nonblank`: the value is kept untrimmed."""
    if not isinstance(value, str):
        return _admission_invalid(kind, f"{path}: expected a JSON string")
    if ocaml_trim(value) == "":
        return _admission_invalid(kind, f"{path}: expected a non-blank string")
    return value


def _judgment_of(index: int, item: Json) -> Judgment | Violation:
    path = f"candidates[{index}]"
    if not isinstance(item, JsonObject):
        return _admission_invalid(Kind.JUDGMENT_NOT_OBJECT, f"{path}: expected a JSON object")
    mismatch = _exact_fields(JUDGMENT_FIELDS, item)
    if mismatch is not None:
        return _admission_invalid(Kind.JUDGMENT_FIELDS, f"{path}: {mismatch}")
    request_id = _nonblank(Kind.JUDGMENT_REQUEST_ID_INVALID, path + ".request_id", member(item, "request_id"))
    if isinstance(request_id, Violation):
        return request_id
    reason = _nonblank(Kind.JUDGMENT_REASON_INVALID, path + ".reason", member(item, "reason"))
    if isinstance(reason, Violation):
        return reason
    label = member(item, "outcome")
    if not isinstance(label, str):
        return _admission_invalid(Kind.JUDGMENT_OUTCOME_INVALID, f"{path}.outcome: expected a JSON string")
    claim_path = path + ".memory_claim"
    claim = member(item, "memory_claim")
    match label:
        case "incorporated" | "already_represented":
            text = _nonblank(Kind.JUDGMENT_CLAIM_REQUIRED, claim_path, claim)
            if isinstance(text, Violation):
                return text
            return Judgment(request_id, label, text, reason)
        case "not_durable" | "deferred":
            if claim is not None:
                token = ocaml_quoted("expected null for not_durable or deferred")
                return _admission_invalid(
                    Kind.JUDGMENT_CLAIM_NOT_NULL, f"{claim_path}: this build does not know the token {token}"
                )
            return Judgment(request_id, label, None, reason)
        case _:
            return _admission_invalid(
                Kind.JUDGMENT_OUTCOME_INVALID,
                f"{path}.outcome: this build does not know the token {ocaml_quoted(label)}",
            )


def unwrap(
    prompt: AdmissionPrompt, shaped: Shaped
) -> tuple[tuple[Judgment, ...], tuple[str, ...]] | Violation:
    """keeper_memory_admission_judgment.ml:47-90 `wrapper_of_json` then `unwrap`."""
    mismatch = _exact_fields(WRAPPER_FIELDS, shaped.top)
    if mismatch is not None:
        return _admission_invalid(Kind.WRAPPER_FIELDS, f"<root>: {mismatch}")
    judgments: list[Judgment] = []
    for index, item in enumerate(shaped.candidates):
        judgment = _judgment_of(index, item)
        if isinstance(judgment, Violation):
            return judgment
        judgments.append(judgment)
    support: list[str] = []
    for index, item in enumerate(shaped.change_support):
        if not isinstance(item, str) or ocaml_trim(item) == "":
            token = ocaml_quoted("expected nonblank request ID")
            return _admission_invalid(
                Kind.CHANGE_SUPPORT_ITEM_INVALID,
                f"change_support[{index}]: this build does not know the token {token}",
            )
        support.append(item)
    expected = frozenset(candidate.request_id for candidate in prompt.candidates)
    by_id: dict[str, Judgment] = {}
    for judgment in judgments:
        if judgment.request_id not in expected:
            return _admission_invalid(
                Kind.UNKNOWN_REQUEST_ID, "unknown admission request_id: " + judgment.request_id
            )
        if judgment.request_id in by_id:
            return _admission_invalid(
                Kind.DUPLICATE_REQUEST_ID, "duplicate admission request_id: " + judgment.request_id
            )
        by_id[judgment.request_id] = judgment
    ordered: list[Judgment] = []
    for candidate in prompt.candidates:
        found = by_id.get(candidate.request_id)
        if found is None:
            return _admission_invalid(
                Kind.MISSING_REQUEST_ID, "missing admission request_id: " + candidate.request_id
            )
        ordered.append(found)
    return tuple(ordered), tuple(support)


def verify(judgments: tuple[Judgment, ...], selection: Selection) -> Violation | None:
    """keeper_memory_admission_judgment.ml:92-102 `verify`."""
    claims = frozenset(selection.memory_after)
    for judgment in judgments:
        if judgment.memory_claim is not None and judgment.memory_claim not in claims:
            return _admission_invalid(
                Kind.MEMORY_CLAIM_ABSENT,
                "admission memory_claim is absent from final Memory for request_id: " + judgment.request_id,
            )
    return None


def additions(selection: Selection) -> tuple[str, ...]:
    """keeper_librarian_runtime.ml:1103-1113: the new claims a supporting candidate has to carry. A
    claim that absorbs current memories, and revises no dropped one, merges what admission already
    read; drops need no candidate either (RFC-0517 §7.1)."""
    merges = frozenset(claim for _, claim in selection.absorbed)
    revises = frozenset(claim for _, claim in selection.revisions)
    return tuple(claim for claim in selection.added_claims if claim in revises or claim not in merges)


def verify_support(
    judgments: tuple[Judgment, ...], support: tuple[str, ...], added: tuple[str, ...]
) -> Violation | None:
    """keeper_memory_admission_judgment.ml:109-128 `verify_support`, given `additions`."""
    by_id = {judgment.request_id: judgment for judgment in judgments}
    supported: set[str] = set()
    for request_id in support:
        if request_id in supported:
            return _admission_invalid(
                Kind.DUPLICATE_CHANGE_SUPPORT, "duplicate change support: " + request_id
            )
        judgment = by_id.get(request_id)
        if judgment is None:
            return _admission_invalid(Kind.UNKNOWN_CHANGE_SUPPORT, "unknown change support: " + request_id)
        if judgment.outcome in ("not_durable", "deferred"):
            return _admission_invalid(
                Kind.UNSETTLED_CHANGE_SUPPORT,
                "change depends on unsettled or nondurable candidate: " + request_id,
            )
        supported.add(request_id)
    for claim in added:
        if not any(
            judgment.request_id in supported
            and judgment.outcome == "incorporated"
            and judgment.memory_claim == claim
            for judgment in judgments
        ):
            return _admission_invalid(
                Kind.NEW_CLAIM_WITHOUT_SUPPORT, "new Memory claim has no incorporated supporting candidate"
            )
    return None
