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
import calendar
from datetime import date
from dataclasses import dataclass, field, replace
from enum import Enum
from hashlib import sha256
import json
import re
import unicodedata
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
    UNTERMINATED_HEADER_ROW = "unterminated_header_row"


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
        self.detail = detail
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
    that object holds, so its validated fields keep the server serializer order.
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
    value: JsonValue, fields: tuple[str, ...], what: str, row: int
) -> JsonObject:
    candidate = _object(value, what, row)
    if candidate.keys() != frozenset(fields):
        raise _malformed(
            f"{what} holds fields {sorted(candidate)}, not {sorted(fields)}", row
        )
    # The typed server serializers have a fixed field order. Rebuild only
    # validated objects in that order; never reorder events or array values.
    ordered = [(key, candidate[key]) for key in fields]
    candidate.clear()
    candidate.update(ordered)
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
    if not (isinstance(session_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", session_id) is not None):
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_HEADER,
            "the header session_id is not a valid Trace_id",
            row=1,
        )
    return workspace_key, session_id


# Wire validation mirrors Keeper_skill_activation_ledger.decode_* and the
# referenced identifier/path contracts. Validate before applying any evidence.
_OCAML_INT_MAX = (1 << 62) - 1
_TRIM = " \t\r\n\f"


def _nonblank(value: JsonObject, name: str, what: str, row: int) -> str:
    text = _string(value, name, what, row)
    if not text.strip(_TRIM):
        raise _malformed(f"{what}.{name} is blank", row)
    return text


def _natural(value: JsonObject, name: str, what: str, row: int) -> int:
    number = _integer(value, name, what, row)
    if not 0 <= number <= _OCAML_INT_MAX:
        raise _malformed(f"{what}.{name} is not a nonnegative OCaml integer", row)
    return number


def _digest(value: JsonObject, name: str, what: str, row: int) -> None:
    if _WORKSPACE_KEY_RE.fullmatch(_string(value, name, what, row)) is None:
        raise _malformed(f"{what}.{name} is not a lowercase SHA-256 digest", row)


def _portable(value: JsonObject, name: str, what: str, row: int) -> None:
    text = _string(value, name, what, row)
    if text in (".", "..") or re.fullmatch(r"[A-Za-z0-9._-]+", text) is None:
        raise _malformed(f"{what}.{name} is not a portable name", row)


def _timestamp(value: JsonObject, name: str, what: str, row: int) -> None:
    text = _string(value, name, what, row)
    match = re.fullmatch(
        r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):"
        r"([0-9]{2})(?:\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})", text
    )
    if match is None:
        raise _malformed(f"{what}.{name} is not strict RFC3339", row)
    year, month, day, hour, minute, second = map(int, match.groups()[:6])
    zone = match[7]
    zh, zm = (0, 0) if zone == "Z" else (int(zone[1:3]), int(zone[4:6]))
    # Ptime accepts year zero and leap seconds, and bounds the UTC result to
    # years 0000..9999. datetime.fromisoformat alone has a different contract.
    if (not 1 <= month <= 12 or not 1 <= day <= calendar.monthrange(year, month)[1]
            or hour > 23 or minute > 59 or second > 60 or zh > 23 or zm > 59):
        raise _malformed(f"{what}.{name} is not a valid RFC3339 date/time", row)
    ordinal = (date(year, month, day).toordinal() if year else
               date(400, month, day).toordinal() - date(400, 1, 1).toordinal() - 365)
    offset = (zh * 60 + zm) * 60 * (-1 if zone.startswith("-") else 1)
    utc = ordinal * 86400 + hour * 3600 + minute * 60 + second - offset
    if not -365 * 86400 <= utc < (date.max.toordinal() + 1) * 86400:
        raise _malformed(f"{what}.{name} is outside the RFC3339 timestamp range", row)


def _turn_ref(value: JsonObject, name: str, session: str, row: int,
              *, positive: bool = False) -> None:
    text = _string(value, name, "turn reference", row)
    trace, separator, suffix = text.rpartition("#")
    # Ids.Turn_ref uses OCaml int_of_string, including base prefixes and '_'.
    match = re.fullmatch(r"([+-]?)([0-9][0-9_]*|0[xX][0-9a-fA-F][0-9a-fA-F_]*|"
                         r"0[oO][0-7][0-7_]*|0[bB][01][01_]*)", suffix)
    if not separator or not trace or match is None:
        raise _malformed(f"{name} is not a turn reference", row)
    digits = match[2].replace("_", "")
    try:
        number = int(digits, 0 if len(digits) > 1 and digits[1] in "xXoObB" else 10)
    except ValueError as error:
        raise _malformed(f"{name} has an invalid absolute turn", row) from error
    if match[1] == "-":
        number = -number
    if not -(1 << 62) <= number <= _OCAML_INT_MAX or (positive and number <= 0):
        raise _malformed(f"{name} has an invalid absolute turn", row)
    if trace != session:
        raise _malformed(f"{name} belongs to another session", row)
    value[name] = f"{trace}#{number}"


def _identity(value: JsonValue, row: int) -> None:
    identity = _exact_object(value, ("source_id", "package_id", "name",),
                             "identity", row)
    _portable(identity, "source_id", "identity", row)
    package = _string(identity, "package_id", "identity", row)
    if package in (".", "..") or any(c in package for c in "/\\\0"):
        raise _malformed("identity.package_id is not a directory component", row)
    name = _string(identity, "name", "identity", row)
    if (unicodedata.normalize("NFKC", name.strip()) != name or len(name) > 64
            or name.lower() != name or name.startswith("-") or name.endswith("-")
            or "--" in name or any(c != "-" and unicodedata.category(c)[0] not in "LN"
                                    for c in name)):
        raise _malformed("identity.name is not a canonical Skill name", row)


def _invocation(value: JsonValue, row: int) -> None:
    invocation = _object(value, "invocation", row)
    kind = invocation.get("kind")
    if kind not in ("instruction", "composition"):
        raise _malformed("unknown invocation kind", row)
    payload = "served_content" if kind == "instruction" else "tool_name"
    _exact_object(invocation, ("kind", "origin", payload,), "invocation", row)
    origin = _object(invocation["origin"], "origin", row)
    if origin.get("kind") == f"session_{kind}":
        _exact_object(origin, ("kind",), "origin", row)
    elif origin.get("kind") == f"task_{kind}":
        _exact_object(origin, ("kind", "task_ids",), "origin", row)
        ids = origin["task_ids"]
        if (not isinstance(ids, list) or not ids
                or any(not isinstance(task, str) or len(task) > 128
                       or re.fullmatch(r"[A-Za-z0-9_:-]+", task) is None for task in ids)
                or len(set(ids)) != len(ids)):
            raise _malformed("origin.task_ids is not a nonempty unique Task id set", row)
    else:
        raise _malformed("origin kind does not match invocation", row)
    if kind == "composition":
        _portable(invocation, "tool_name", "invocation", row)
        return
    served = _object(invocation["served_content"], "served_content", row)
    match served.get("kind"):
        case "skill_body":
            fields = ("kind", "bytes", "sha256")
        case "skill_resource":
            fields = ("kind", "relative_path", "bytes", "sha256")
            path = _string(served, "relative_path", "served_content", row)
            if ("\\" in path or "\0" in path
                    or any(part in ("", ".", "..") for part in path.split("/"))):
                raise _malformed("served_content.relative_path is not a Skill resource path", row)
        case _:
            raise _malformed("unknown served_content kind", row)
    _exact_object(served, fields, "served_content", row)
    _natural(served, "bytes", "served_content", row)
    _digest(served, "sha256", "served_content", row)


def _delivery(value: JsonValue, row: int) -> tuple[JsonObject, _BoundaryKind, int]:
    delivery = _exact_object(value, ("boundary", "runtime_id", "delivered_at", "content_bytes", "content_sha256",), "delivery", row)
    boundary = _exact_object(delivery["boundary"], ("kind", "agent_core_turn",),
                             "delivery.boundary", row)
    try:
        kind = _BoundaryKind(boundary["kind"])
    except (ValueError, TypeError) as error:
        raise _malformed("unknown delivery boundary", row) from error
    turn = _natural(boundary, "agent_core_turn", "delivery.boundary", row)
    _nonblank(delivery, "runtime_id", "delivery", row)
    _timestamp(delivery, "delivered_at", "delivery", row)
    _natural(delivery, "content_bytes", "delivery", row)
    _digest(delivery, "content_sha256", "delivery", row)
    return delivery, kind, turn


def _action_identity(value: JsonValue, row: int) -> JsonObject:
    identity = _object(value, "action.identity", row)
    match identity.get("kind"):
        case "call_id":
            _exact_object(identity, ("kind", "call_id",), "action.identity", row)
            _nonblank(identity, "call_id", "action.identity", row)
        case "provider_step":
            _exact_object(identity, ("kind", "conversation_id", "step_index",),
                          "action.identity", row)
            _nonblank(identity, "conversation_id", "action.identity", row)
            _natural(identity, "step_index", "action.identity", row)
        case _:
            raise _malformed("unknown action identity", row)
    return identity


def _action(value: JsonValue, row: int) -> JsonObject:
    action = _exact_object(value, ("identity", "tool_name", "runtime_id", "agent_core_turn", "observed_at",), "action", row)
    _action_identity(action["identity"], row)
    _portable(action, "tool_name", "action", row)
    _nonblank(action, "runtime_id", "action", row)
    _natural(action, "agent_core_turn", "action", row)
    _timestamp(action, "observed_at", "action", row)
    return action


def _parse_activation(event: JsonObject, row: int, session: str) -> _ActivationRecorded:
    activation = _exact_object(event["activation"], ("identity", "content_revision", "snapshot_revision", "turn_ref", "runtime_id", "skill_tool_use_id", "agent_core_turn", "invocation", "delivery", "actions", "activated_at",), "activation", row)
    _identity(activation["identity"], row)
    _digest(activation, "content_revision", "activation", row)
    _digest(activation, "snapshot_revision", "activation", row)
    _turn_ref(activation, "turn_ref", session, row, positive=True)
    _nonblank(activation, "runtime_id", "activation", row)
    tool_id = _nonblank(activation, "skill_tool_use_id", "activation", row)
    turn = _natural(activation, "agent_core_turn", "activation", row)
    _invocation(activation["invocation"], row)
    _timestamp(activation, "activated_at", "activation", row)
    actions = activation["actions"]
    if not isinstance(actions, list):
        raise _malformed("activation.actions is not an array", row)
    identities = []
    for value in actions:
        identity = _action(value, row)["identity"]
        if identity in identities:
            raise SkillLedgerError(SkillLedgerFault.DUPLICATE_ACTION_IDENTITY,
                                   "activation repeats an action identity", row=row)
        identities.append(identity)
    if activation["delivery"] is not None:
        _, boundary, delivery_turn = _delivery(activation["delivery"], row)
        if _delivery_precedes_activation(boundary, delivery_turn, turn):
            raise SkillLedgerError(SkillLedgerFault.INVALID_DELIVERY_AGENT_CORE_TURN,
                                   "delivery precedes activation", row=row)
        if any(action["agent_core_turn"] < delivery_turn for action in actions):
            raise SkillLedgerError(SkillLedgerFault.INVALID_ACTION_AGENT_CORE_TURN,
                                   "action precedes delivery", row=row)
    elif actions:
        raise SkillLedgerError(SkillLedgerFault.INVALID_DELIVERY_AGENT_CORE_TURN,
                               "actions have no delivery", row=row)
    return _ActivationRecorded(tool_id, activation["turn_ref"], turn,
                               activation["delivery"] is not None or actions != [],
                               activation, actions)


def _parse_delivery(value: JsonValue, row: int) -> _DeliveryObserved:
    entry = _exact_object(value, ("skill_tool_use_id", "delivery",),
                          "delivery observation", row)
    delivery, boundary, turn = _delivery(entry["delivery"], row)
    return _DeliveryObserved(
        _reference(entry["skill_tool_use_id"], "delivery observation.skill_tool_use_id", row),
        boundary, turn, delivery)


def _parse_action(event: JsonObject, row: int) -> _ActionObserved:
    targets = event["skill_tool_use_ids"]
    if not isinstance(targets, list):
        raise _malformed("action_observed.skill_tool_use_ids is not an array", row)
    action = _action(event["action"], row)
    return _ActionObserved(
        tuple(_reference(target, "action_observed.skill_tool_use_ids[]", row) for target in targets),
        action["identity"], action["agent_core_turn"], action)


def _parse_rejection(event: JsonObject, row: int, session: str) -> _TransitionRejected:
    rejection = _object(event["rejection"], "rejection", row)
    fields = ("kind", "skill_tool_use_id", "activation_turn_ref", "observed_turn_ref")
    match rejection.get("kind"):
        case "delivery_order":
            fields += ("activation_agent_core_turn",)
            _natural(rejection, "activation_agent_core_turn", "rejection", row)
        case "delivery_conflict":
            pass
        case "action_before_delivery":
            fields += ("action_identity", "tool_name")
            _action_identity(rejection.get("action_identity"), row)
            _portable(rejection, "tool_name", "rejection", row)
        case _:
            raise _malformed("unknown rejection kind", row)
    fields += ("observed_agent_core_turn", "observed_at")
    _exact_object(rejection, fields, "rejection", row)
    tool_id = _nonblank(rejection, "skill_tool_use_id", "rejection", row)
    _turn_ref(rejection, "activation_turn_ref", session, row)
    _turn_ref(rejection, "observed_turn_ref", session, row)
    _natural(rejection, "observed_agent_core_turn", "rejection", row)
    _timestamp(rejection, "observed_at", "rejection", row)
    return _TransitionRejected(tool_id, rejection["activation_turn_ref"], rejection)


def _parse_event(value: JsonValue, row: int, session: str) -> _Event:
    """The event one row after the header records."""
    event = _object(value, "event", row)
    kind = event.get("kind")
    match kind:
        case "activation_recorded":
            fields = ("kind", "activation",)
            return _parse_activation(_exact_object(event, fields, kind, row), row, session)
        case "deliveries_observed":
            fields = ("kind", "deliveries",)
            entries = _exact_object(event, fields, kind, row)["deliveries"]
            if not isinstance(entries, list):
                raise _malformed("deliveries_observed.deliveries is not an array", row)
            return _DeliveriesObserved(
                tuple(_parse_delivery(entry, row) for entry in entries)
            )
        case "action_observed":
            fields = ("kind", "skill_tool_use_ids", "action",)
            return _parse_action(_exact_object(event, fields, kind, row), row)
        case "transition_rejected":
            fields = ("kind", "rejection",)
            return _parse_rejection(_exact_object(event, fields, kind, row), row, session)
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
    # Projection callers also supply decoded JSON, potentially in any object
    # order. Validate and canonicalize copies just like the event reader.
    activations = copy.deepcopy(activations)
    transition_rejections = copy.deepcopy(transition_rejections)
    try:
        for activation in activations:
            _parse_activation({"activation": activation}, 0, session_id)
        for rejection in transition_rejections:
            _parse_rejection({"rejection": rejection}, 0, session_id)
    except SkillLedgerError as error:
        # These values come from a projection, with no event-log row.
        # Shape refusals are ledger faults; specific invariant codes remain.
        fault = (SkillLedgerFault.MALFORMED_LEDGER
                 if error.fault is SkillLedgerFault.MALFORMED_EVENT else error.fault)
        raise SkillLedgerError(fault, error.detail) from error
    canonical: JsonObject = {
        "workspace_key": workspace_key,
        "session_id": session_id,
        "activations": activations,
        "transition_rejections": transition_rejections,
    }
    # Yojson escapes U+007F as it escapes the C0 controls; json.dumps writes
    # it as is. A DEL can only sit inside a string here, so the swap is exact.
    payload = json.dumps(canonical, ensure_ascii=False, separators=(",", ":")).replace(
        "\x7f", "\\u007f"
    )
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
    Yojson's compact printer writes for these values once U+007F is escaped
    the way Yojson escapes it.
    """
    workspace_key = ledger.get("workspace_key")
    session_id = ledger.get("session_id")
    activations = ledger.get("activations")
    transition_rejections = ledger.get("transition_rejections")
    if not (isinstance(workspace_key, str) and workspace_key != ""):
        raise SkillLedgerError(
            SkillLedgerFault.MALFORMED_LEDGER, "skill ledger.workspace_key is empty"
        )
    if not (isinstance(session_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", session_id) is not None):
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

    Returns None when the log is empty: the session has recorded nothing.
    Bytes with no newline at all are refused: the server creates a log with
    its header and first event in one atomic step, so its first row is always
    complete. Activations keep the order they were recorded in; object fields use
    the typed server serializer order. Raises SkillLedgerError for a row the
    server's rules refuse, and for a ledger whose strings are not Unicode text.
    """
    if raw != b"" and b"\n" not in raw:
        raise SkillLedgerError(
            SkillLedgerFault.UNTERMINATED_HEADER_ROW,
            "the log's first row has no newline",
        )
    rows = _complete_rows(raw)
    if rows == []:
        return None
    workspace_key, session_id = _read_header(_parse_row(rows[0], 1))
    fold = _Fold()
    for number, row in enumerate(rows[1:], start=2):
        _apply(fold, _parse_event(_parse_row(row, number), number, session_id), number)
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
