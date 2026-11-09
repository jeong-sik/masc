# pyright: strict
"""The lane add-on steps an exact-lane answer passes before the admission rules.

- `canonical`: lane_addon_action.ml:23-58, duplicate members and non-finite numbers
- `shape`: lane_addon_exact_shape.ml:7-54 `issue` on the admission output
  schema, called from lane_addon_exact.ml:106-116

Pure: no I/O.
"""

from __future__ import annotations

import itertools
import math
from dataclasses import dataclass

from admission_result import Kind, Violation
from yojson_wire import (
    OCAML_INT_MAX,
    OCAML_INT_MIN,
    Absent,
    IntLit,
    Json,
    JsonObject,
    member,
)


@dataclass(slots=True)
class _Open:
    """A container whose children are being made canonical, in source order."""

    names: tuple[str, ...] | None  # None for an array
    values: tuple[Json, ...]
    ordered: bool  # an object whose names already increase keeps its order
    done: list[Json]


def _enter(value: Json) -> Json | Violation | _Open:
    """A canonical leaf or empty container, the refusal, or a container to descend into.

    An object's members are checked for duplicates here, before any child.
    """
    match value:
        case JsonObject(members=members):
            names = tuple(name for name, _ in members)
            ordered = all(left < right for left, right in itertools.pairwise(names))
            if not ordered and len(set(names)) != len(names):
                return Violation(Kind.DUPLICATE_MEMBER, "duplicate object member")
            return _Open(names, tuple(item for _, item in members), ordered, []) if members else value
        case tuple():
            return _Open(None, value, True, []) if value else value
        case bool() | int() | str() | IntLit() | None:
            return value
        case float():
            if not math.isfinite(value):
                return Violation(Kind.NON_FINITE_NUMBER, "non-finite JSON number")
            if not value.is_integer():
                return value
            # JSON 1 and 1.0 are one value; "%.0f" also covers the Intlit range.
            text = f"{value:.0f}"
            number = int(text)
            return number if OCAML_INT_MIN <= number <= OCAML_INT_MAX else IntLit(text)


def _close(container: _Open) -> Json:
    if container.names is None:
        return tuple(container.done)
    members = list(zip(container.names, container.done, strict=True))
    if not container.ordered:
        members.sort(key=lambda pair: pair[0])
    return JsonObject(tuple(members))


def canonical(value: Json) -> Json | Violation:
    """lane_addon_action.ml:39-58: sort members, refuse duplicates and non-finite numbers.

    Depth first in source order, so the refusal is the first one the OCaml
    recursion meets. Open containers wait on a list instead of the Python call
    stack, so any depth the reader returns is checked.
    """
    open_: list[_Open] = []
    pending = value
    while True:
        entered = _enter(pending)
        if isinstance(entered, Violation):
            return entered
        if isinstance(entered, _Open):
            open_.append(entered)
            pending = entered.values[0]
            continue
        finished: Json = entered
        while True:
            if not open_:
                return finished
            container = open_[-1]
            container.done.append(finished)
            if len(container.done) < len(container.values):
                pending = container.values[len(container.done)]
                break
            open_.pop()
            finished = _close(container)


@dataclass(frozen=True, slots=True)
class Shaped:
    top: JsonObject
    candidates: tuple[Json, ...]
    change_support: tuple[Json, ...]
    memory: JsonObject
    new_claims: tuple[Json, ...]
    dropped: tuple[Json, ...]


def shape(top: JsonObject) -> Shaped | Violation:
    """lane_addon_exact_shape.ml `issue` on the admission schema.

    The schema is stored canonical, so properties are checked in key order;
    required keys in their list order. `working_state` has a list type, which
    `issue` does not check.
    """
    for key in ("memory", "candidates", "change_support"):
        if isinstance(member(top, key), Absent):
            return Violation(Kind.MISSING_REQUIRED_KEY, f"missing required key $.{key}")
    candidates = member(top, "candidates")
    if not isinstance(candidates, tuple):
        return Violation(Kind.INCOMPATIBLE_SHAPE, "incompatible required shape at $.candidates")
    change_support = member(top, "change_support")
    if not isinstance(change_support, tuple):
        return Violation(Kind.INCOMPATIBLE_SHAPE, "incompatible required shape at $.change_support")
    memory = member(top, "memory")
    if not isinstance(memory, JsonObject):
        return Violation(Kind.INCOMPATIBLE_SHAPE, "incompatible required shape at $.memory")
    for key in ("new_claims", "dropped", "working_state", "working_contexts"):
        if isinstance(member(memory, key), Absent):
            return Violation(Kind.MISSING_REQUIRED_KEY, f"missing required key $.memory.{key}")
    dropped = member(memory, "dropped")
    if not isinstance(dropped, tuple):
        return Violation(Kind.INCOMPATIBLE_SHAPE, "incompatible required shape at $.memory.dropped")
    new_claims = member(memory, "new_claims")
    if not isinstance(new_claims, tuple):
        return Violation(Kind.INCOMPATIBLE_SHAPE, "incompatible required shape at $.memory.new_claims")
    if not isinstance(member(memory, "working_contexts"), tuple):
        return Violation(Kind.INCOMPATIBLE_SHAPE, "incompatible required shape at $.memory.working_contexts")
    return Shaped(top, candidates, change_support, memory, new_claims, dropped)
