"""Fold a Keeper session's Skill activation event log into its ledger.

The server records each Keeper session's Skill activations in one append-only
JSONL file, ``<masc_root>/traces/<session_id>/skill-activation-events.jsonl``.
The first row names the workspace and the session. Every later row is one
event: an activation recorded, deliveries observed, an action observed, or a
transition rejected. Each row ends with a newline; text after the last newline
is a row the server is still appending.

The ledger the Dashboard serves under ``masc.skill-activations/v5`` is those
events applied in order. ``fold_event_log`` applies them with the rules of
``Keeper_skill_activation_ledger.apply_event`` and returns that projection, so
a reader can compare the file with what the server reports.
"""

from __future__ import annotations

from collections.abc import Mapping
import copy
from dataclasses import dataclass, field, replace
from enum import Enum
from hashlib import sha256
import json
import re
from typing import TypeAlias, Union, assert_never


EVENTS_FILENAME = "skill-activation-events.jsonl"
EVENTS_SCHEMA = "masc.skill-activation-events/v1"
LEDGER_SCHEMA = "masc.skill-activations/v5"

JsonValue: TypeAlias = Union[
    None, bool, int, float, str, list["JsonValue"], dict[str, "JsonValue"]
]
JsonObject: TypeAlias = dict[str, JsonValue]

_WORKSPACE_KEY_RE = re.compile(r"[0-9a-f]{64}")
_HEADER_FIELDS = frozenset({"schema", "kind", "workspace_key", "session_id"})


class SkillLedgerFault(Enum):
    """Why a log or ledger was refused.

    Where the server's decoder refuses the same thing, the value is its
    decode error code.
    """

    MALFORMED_ROW = "malformed_row"
    DUPLICATE_FIELD = "duplicate_field"
    BLANK_EVENT_ROW = "blank_event_row"
    UNSUPPORTED_SCHEMA = "unsupported_schema"
    MALFORMED_HEADER = "malformed_header"
    INVALID_EVENT_KIND = "invalid_event_kind"
    MALFORMED_EVENT = "malformed_event"
    DUPLICATE_SKILL_TOOL_USE_ID = "duplicate_skill_tool_use_id"
    ACTIVATION_RECORDED_WITH_EVIDENCE = "activation_recorded_with_evidence"
    UNKNOWN_EVENT_ACTIVATION = "unknown_event_activation"
    DELIVERY_ALREADY_OBSERVED = "delivery_already_observed"
    INVALID_DELIVERY_AGENT_CORE_TURN = "invalid_delivery_agent_core_turn"
    ACTION_TARGET_NOT_DELIVERED = "action_target_not_delivered"
    INVALID_ACTION_AGENT_CORE_TURN = "invalid_action_agent_core_turn"
    DUPLICATE_ACTION_IDENTITY = "duplicate_action_identity"
    ORPHAN_TRANSITION_REJECTION = "orphan_transition_rejection"
    TRANSITION_REJECTION_ACTIVATION_MISMATCH = (
        "transition_rejection_activation_mismatch"
    )
    MALFORMED_LEDGER = "malformed_ledger"


class SkillLedgerError(RuntimeError):
    """A Skill activation event log, or a ledger, that the ledger rules refuse.

    ``row`` is the 1-based line of the event log that was refused, or None
    when the refused value is a ledger rather than a log.
    """

    def __init__(
        self, fault: SkillLedgerFault, detail: str, *, row: int | None = None
    ) -> None:
        location = "" if row is None else f"row {row}: "
        super().__init__(f"{location}{fault.value}: {detail}")
        self.fault = fault
        self.row = row


class _BoundaryKind(Enum):
    MODEL_RESPONSE = "model_response"
    OFFICIAL_CLIENT_RESULT_HANDOFF = "official_client_result_handoff"


@dataclass(frozen=True, slots=True)
class _ActivationRecorded:
    skill_tool_use_id: str
    turn_ref: str
    agent_core_turn: int
    carries_evidence: bool
    activation: JsonObject
    actions: list[JsonValue]


@dataclass(frozen=True, slots=True)
class _DeliveryObserved:
    skill_tool_use_id: str
    boundary: _BoundaryKind
    boundary_turn: int
    delivery: JsonObject


@dataclass(frozen=True, slots=True)
class _DeliveriesObserved:
    deliveries: tuple[_DeliveryObserved, ...]


@dataclass(frozen=True, slots=True)
class _ActionObserved:
    skill_tool_use_ids: tuple[str, ...]
    identity: JsonObject
    agent_core_turn: int
    action: JsonObject


@dataclass(frozen=True, slots=True)
class _TransitionRejected:
    skill_tool_use_id: str
    activation_turn_ref: str
    rejection: JsonObject


_Event: TypeAlias = Union[
    _ActivationRecorded, _DeliveriesObserved, _ActionObserved, _TransitionRejected
]


@dataclass(frozen=True, slots=True)
class _Cell:
    """One recorded activation while the log is applied.

    ``activation`` is the object the folded ledger holds; a delivery replaces
    its ``delivery`` value and an action is appended to ``actions``, the list
    that object holds, so its fields keep the order of the recorded row.
    """

    activation: JsonObject
    actions: list[JsonValue]
    turn_ref: str
    agent_core_turn: int
    delivery_turn: int | None
    action_identities: tuple[JsonObject, ...]


@dataclass(frozen=True, slots=True)
class _Fold:
    activations: list[JsonValue] = field(default_factory=list)
    cells: dict[str, _Cell] = field(default_factory=dict)
    rejections: list[JsonValue] = field(default_factory=list)


class _RepeatedField(Exception):
    def __init__(self, name: str) -> None:
        super().__init__(name)
        self.name = name


def _unique_fields(pairs: list[tuple[str, JsonValue]]) -> JsonObject:
    fields: JsonObject = {}
    for name, value in pairs:
        if name in fields:
            raise _RepeatedField(name)
        fields[name] = value
    return fields


def _complete_rows(raw: bytes) -> list[bytes]:
    *rows, _being_appended = raw.split(b"\n")
    for number, row in enumerate(rows, start=1):
        if row == b"":
            raise SkillLedgerError(
                SkillLedgerFault.BLANK_EVENT_ROW,
                "an empty row sits between rows",
                row=number,
            )
    return rows


def _parse_row(row: bytes, number: int) -> JsonValue:
    try:
        value: JsonValue = json.loads(
            row.decode("utf-8"), object_pairs_hook=_unique_fields
        )
    except _RepeatedField as repeated:
        raise SkillLedgerError(
            SkillLedgerFault.DUPLICATE_FIELD,
            f"an object repeats field {repeated.name}",
            row=number,
        ) from repeated
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_ROW,
            f"the row is not one UTF-8 JSON value: {error}",
            row=number,
        ) from error
    return value


def _malformed(detail: str, row: int) -> SkillLedgerError:
    return SkillLedgerError(SkillLedgerFault.MALFORMED_EVENT, detail, row=row)


def _object(value: JsonValue, what: str, row: int) -> JsonObject:
    if isinstance(value, dict):
        return value
    raise _malformed(f"{what} is not an object", row)


def _exact_object(
    value: JsonValue, fields: frozenset[str], what: str, row: int
) -> JsonObject:
    candidate = _object(value, what, row)
    if candidate.keys() != fields:
        raise _malformed(
            f"{what} holds fields {sorted(candidate)}, not {sorted(fields)}", row
        )
    return candidate


def _string(value: JsonObject, name: str, what: str, row: int) -> str:
    child = value.get(name)
    if isinstance(child, str) and child != "":
        return child
    raise _malformed(f"{what}.{name} is not a non-empty string", row)


def _integer(value: JsonObject, name: str, what: str, row: int) -> int:
    child = value.get(name)
    if isinstance(child, int) and not isinstance(child, bool):
        return child
    raise _malformed(f"{what}.{name} is not an integer", row)


def _reference(value: JsonValue, what: str, row: int) -> str:
    if isinstance(value, str):
        return value
    raise _malformed(f"{what} is not a string", row)


def _read_header(value: JsonValue) -> tuple[str, str]:
    if not isinstance(value, dict):
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_HEADER, "the header is not an object", row=1
        )
    schema = value.get("schema")
    if schema != EVENTS_SCHEMA:
        raise SkillLedgerError(
            SkillLedgerFault.UNSUPPORTED_SCHEMA,
            f"the header schema is {schema!r}, not {EVENTS_SCHEMA}",
            row=1,
        )
    if value.keys() != _HEADER_FIELDS:
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_HEADER,
            f"the header holds fields {sorted(value)}, not {sorted(_HEADER_FIELDS)}",
            row=1,
        )
    kind = value["kind"]
    if kind != "opened":
        raise SkillLedgerError(
            SkillLedgerFault.INVALID_EVENT_KIND,
            f"the header kind is {kind!r}, not 'opened'",
            row=1,
        )
    workspace_key = value["workspace_key"]
    if not (
        isinstance(workspace_key, str)
        and _WORKSPACE_KEY_RE.fullmatch(workspace_key) is not None
    ):
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_HEADER,
            "the header workspace_key is not a lowercase SHA-256 hex digest",
            row=1,
        )
    session_id = value["session_id"]
    if not (isinstance(session_id, str) and session_id != ""):
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_HEADER,
            "the header session_id is not a non-empty string",
            row=1,
        )
    return workspace_key, session_id


def _parse_activation(event: JsonObject, row: int) -> _ActivationRecorded:
    activation = _object(event["activation"], "activation", row)
    if "delivery" not in activation:
        raise _malformed("activation has no delivery field", row)
    actions = activation.get("actions")
    if not isinstance(actions, list):
        raise _malformed("activation.actions is not an array", row)
    return _ActivationRecorded(
        skill_tool_use_id=_string(activation, "skill_tool_use_id", "activation", row),
        turn_ref=_string(activation, "turn_ref", "activation", row),
        agent_core_turn=_integer(activation, "agent_core_turn", "activation", row),
        carries_evidence=activation["delivery"] is not None or actions != [],
        activation=activation,
        actions=actions,
    )


def _parse_delivery(value: JsonValue, row: int) -> _DeliveryObserved:
    entry = _exact_object(
        value,
        frozenset({"skill_tool_use_id", "delivery"}),
        "delivery observation",
        row,
    )
    delivery = _object(entry["delivery"], "delivery", row)
    boundary = _object(delivery.get("boundary"), "delivery.boundary", row)
    kind = boundary.get("kind")
    if not isinstance(kind, str):
        raise _malformed("delivery.boundary.kind is not a string", row)
    try:
        boundary_kind = _BoundaryKind(kind)
    except ValueError as error:
        raise _malformed(f"delivery boundary kind {kind!r} is unknown", row) from error
    return _DeliveryObserved(
        skill_tool_use_id=_reference(
            entry["skill_tool_use_id"], "delivery observation.skill_tool_use_id", row
        ),
        boundary=boundary_kind,
        boundary_turn=_integer(boundary, "agent_core_turn", "delivery.boundary", row),
        delivery=delivery,
    )


def _parse_action(event: JsonObject, row: int) -> _ActionObserved:
    targets = event["skill_tool_use_ids"]
    if not isinstance(targets, list):
        raise _malformed("action_observed.skill_tool_use_ids is not an array", row)
    action = _object(event["action"], "action", row)
    return _ActionObserved(
        skill_tool_use_ids=tuple(
            _reference(target, "action_observed.skill_tool_use_ids[]", row)
            for target in targets
        ),
        identity=_object(action.get("identity"), "action.identity", row),
        agent_core_turn=_integer(action, "agent_core_turn", "action", row),
        action=action,
    )


def _parse_rejection(event: JsonObject, row: int) -> _TransitionRejected:
    rejection = _object(event["rejection"], "rejection", row)
    return _TransitionRejected(
        skill_tool_use_id=_string(rejection, "skill_tool_use_id", "rejection", row),
        activation_turn_ref=_string(rejection, "activation_turn_ref", "rejection", row),
        rejection=rejection,
    )


def _parse_event(value: JsonValue, row: int) -> _Event:
    """The event one row after the header records."""
    event = _object(value, "event", row)
    kind = event.get("kind")
    match kind:
        case "activation_recorded":
            fields = frozenset({"kind", "activation"})
            return _parse_activation(_exact_object(event, fields, kind, row), row)
        case "deliveries_observed":
            fields = frozenset({"kind", "deliveries"})
            entries = _exact_object(event, fields, kind, row)["deliveries"]
            if not isinstance(entries, list):
                raise _malformed("deliveries_observed.deliveries is not an array", row)
            return _DeliveriesObserved(
                tuple(_parse_delivery(entry, row) for entry in entries)
            )
        case "action_observed":
            fields = frozenset({"kind", "skill_tool_use_ids", "action"})
            return _parse_action(_exact_object(event, fields, kind, row), row)
        case "transition_rejected":
            fields = frozenset({"kind", "rejection"})
            return _parse_rejection(_exact_object(event, fields, kind, row), row)
        case _:
            raise SkillLedgerError(
                SkillLedgerFault.INVALID_EVENT_KIND,
                f"event kind {kind!r} is not one the log records",
                row=row,
            )


def _delivery_precedes_activation(
    boundary: _BoundaryKind, delivery_turn: int, activation_turn: int
) -> bool:
    # A model-response delivery comes in a later Agent Core turn than its
    # activation; an official-client handoff may come in the same turn.
    match boundary:
        case _BoundaryKind.MODEL_RESPONSE:
            return delivery_turn <= activation_turn
        case _BoundaryKind.OFFICIAL_CLIENT_RESULT_HANDOFF:
            return delivery_turn < activation_turn
        case _:
            assert_never(boundary)


def _recorded_cell(fold: _Fold, skill_tool_use_id: str, row: int) -> _Cell:
    cell = fold.cells.get(skill_tool_use_id)
    if cell is None:
        raise SkillLedgerError(
            SkillLedgerFault.UNKNOWN_EVENT_ACTIVATION,
            f"no earlier row records activation {skill_tool_use_id!r}",
            row=row,
        )
    return cell


def _apply(fold: _Fold, event: _Event, row: int) -> None:
    match event:
        case _ActivationRecorded():
            if event.skill_tool_use_id in fold.cells:
                raise SkillLedgerError(
                    SkillLedgerFault.DUPLICATE_SKILL_TOOL_USE_ID,
                    f"activation {event.skill_tool_use_id!r} is already recorded",
                    row=row,
                )
            if event.carries_evidence:
                raise SkillLedgerError(
                    SkillLedgerFault.ACTIVATION_RECORDED_WITH_EVIDENCE,
                    f"activation {event.skill_tool_use_id!r} is recorded with a"
                    " delivery or actions",
                    row=row,
                )
            fold.cells[event.skill_tool_use_id] = _Cell(
                activation=event.activation,
                actions=event.actions,
                turn_ref=event.turn_ref,
                agent_core_turn=event.agent_core_turn,
                delivery_turn=None,
                action_identities=(),
            )
            fold.activations.append(event.activation)
        case _DeliveriesObserved():
            for observation in event.deliveries:
                cell = _recorded_cell(fold, observation.skill_tool_use_id, row)
                if cell.delivery_turn is not None:
                    raise SkillLedgerError(
                        SkillLedgerFault.DELIVERY_ALREADY_OBSERVED,
                        f"activation {observation.skill_tool_use_id!r} already has"
                        " a delivery",
                        row=row,
                    )
                if _delivery_precedes_activation(
                    observation.boundary,
                    observation.boundary_turn,
                    cell.agent_core_turn,
                ):
                    raise SkillLedgerError(
                        SkillLedgerFault.INVALID_DELIVERY_AGENT_CORE_TURN,
                        f"a {observation.boundary.value} delivery at turn"
                        f" {observation.boundary_turn} precedes activation"
                        f" {observation.skill_tool_use_id!r} at turn"
                        f" {cell.agent_core_turn}",
                        row=row,
                    )
                cell.activation["delivery"] = observation.delivery
                fold.cells[observation.skill_tool_use_id] = replace(
                    cell, delivery_turn=observation.boundary_turn
                )
        case _ActionObserved():
            for skill_tool_use_id in event.skill_tool_use_ids:
                cell = _recorded_cell(fold, skill_tool_use_id, row)
                if cell.delivery_turn is None:
                    raise SkillLedgerError(
                        SkillLedgerFault.ACTION_TARGET_NOT_DELIVERED,
                        f"activation {skill_tool_use_id!r} has no delivery yet",
                        row=row,
                    )
                if event.agent_core_turn < cell.delivery_turn:
                    raise SkillLedgerError(
                        SkillLedgerFault.INVALID_ACTION_AGENT_CORE_TURN,
                        f"an action at turn {event.agent_core_turn} precedes the"
                        f" delivery of {skill_tool_use_id!r} at turn"
                        f" {cell.delivery_turn}",
                        row=row,
                    )
                if event.identity in cell.action_identities:
                    raise SkillLedgerError(
                        SkillLedgerFault.DUPLICATE_ACTION_IDENTITY,
                        f"activation {skill_tool_use_id!r} already holds this action",
                        row=row,
                    )
                cell.actions.append(copy.deepcopy(event.action))
                fold.cells[skill_tool_use_id] = replace(
                    cell, action_identities=(*cell.action_identities, event.identity)
                )
        case _TransitionRejected():
            cell = fold.cells.get(event.skill_tool_use_id)
            if cell is None:
                raise SkillLedgerError(
                    SkillLedgerFault.ORPHAN_TRANSITION_REJECTION,
                    f"no earlier row records activation {event.skill_tool_use_id!r}",
                    row=row,
                )
            if cell.turn_ref != event.activation_turn_ref:
                raise SkillLedgerError(
                    SkillLedgerFault.TRANSITION_REJECTION_ACTIVATION_MISMATCH,
                    f"the rejection names turn {event.activation_turn_ref!r}, but"
                    f" activation {event.skill_tool_use_id!r} is from turn"
                    f" {cell.turn_ref!r}",
                    row=row,
                )
            fold.rejections.append(event.rejection)
        case _:
            assert_never(event)


def _revision(
    workspace_key: str,
    session_id: str,
    activations: list[JsonValue],
    transition_rejections: list[JsonValue],
) -> str:
    canonical: JsonObject = {
        "workspace_key": workspace_key,
        "session_id": session_id,
        "activations": activations,
        "transition_rejections": transition_rejections,
    }
    payload = json.dumps(canonical, ensure_ascii=False, separators=(",", ":"))
    try:
        encoded = payload.encode()
    except UnicodeEncodeError as error:
        # json.loads turns an escaped unpaired surrogate such as "\udc00" into
        # a str that has no UTF-8 form.
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_LEDGER,
            f"a string in the ledger is not Unicode text: {error}",
        ) from error
    return sha256(encoded).hexdigest()


def ledger_revision(ledger: Mapping[str, JsonValue]) -> str:
    """The revision the server derives from a ledger's content.

    It is the SHA-256 of the compact JSON object of the ledger's workspace
    key, session id, activations and transition rejections, in that order.
    ``json.dumps`` with ``ensure_ascii=False`` and no spaces writes what
    Yojson's compact printer writes for these values, except U+007F, which
    Yojson escapes and ``json.dumps`` writes as is.
    """
    workspace_key = ledger.get("workspace_key")
    session_id = ledger.get("session_id")
    activations = ledger.get("activations")
    transition_rejections = ledger.get("transition_rejections")
    if not (isinstance(workspace_key, str) and workspace_key != ""):
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_LEDGER, "skill ledger.workspace_key is empty"
        )
    if not (isinstance(session_id, str) and session_id != ""):
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_LEDGER, "skill ledger.session_id is empty"
        )
    if not isinstance(activations, list):
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_LEDGER,
            "skill ledger.activations is not an array",
        )
    if not isinstance(transition_rejections, list):
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_LEDGER,
            "skill ledger.transition_rejections is not an array",
        )
    return _revision(workspace_key, session_id, activations, transition_rejections)


def fold_event_log(raw: bytes) -> JsonObject | None:
    """The ledger an event log records, in the Dashboard's v5 shape.

    Returns None when the log has no complete row: the session has recorded
    nothing. Activations keep the order they were recorded in and each keeps
    the field order of its recorded row. Raises SkillLedgerError for a row the
    server's rules refuse, and for a ledger whose strings are not Unicode text.
    """
    rows = _complete_rows(raw)
    if rows == []:
        return None
    workspace_key, session_id = _read_header(_parse_row(rows[0], 1))
    fold = _Fold()
    for number, row in enumerate(rows[1:], start=2):
        _apply(fold, _parse_event(_parse_row(row, number), number), number)
    return {
        "schema": LEDGER_SCHEMA,
        "workspace_key": workspace_key,
        "session_id": session_id,
        "revision": _revision(
            workspace_key, session_id, fold.activations, fold.rejections
        ),
        "activations": fold.activations,
        "transition_rejections": fold.rejections,
    }
