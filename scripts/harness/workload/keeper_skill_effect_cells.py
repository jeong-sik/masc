#!/usr/bin/env python3
"""Count a Keeper Skill proof's selection, effect, and retained state apart.

A later model-selected action proves that the Keeper chose a tool after the
Skill reached it.  It does not prove that the tool's effect landed, or that
the state the task asked for is still there.  Three cells are kept separate:

``action_selected``
    the exact activation records later actions (selecting the declared tool
    when the scenario declares one);
``external_effect_applied``
    the one selected ``keeper_memory_write`` call, joined by its call id to
    its tool-call row, returned a receipt for a write committed to the
    current Memory snapshot, and the Memory journal holds that commit (same
    revision, explicit write, same trace);
``requested_postcondition_observed``
    the memory id that receipt names is a fact of the captured current Memory
    snapshot.

``keeper_memory_write`` runs in process and never enters the Gate: the Gate
keys only its own operations (``lib/keeper/keeper_gate_types.ml``).  So the
effect authority here is the Memory store's own journal, not a Gate approval.

A scenario declaration, read by the producer before the natural message is
sent, says how far the chain must reach.  The functions here take the bytes
the caller read, so the collector and the offline verifier compute the same
cells from the same authorities.  A malformed authority raises
:class:`CellError`; a well-formed authority that shows a gap is returned as a
typed observation.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from enum import Enum
from hashlib import sha256
import json
import re
from typing import TypeAlias, Union, assert_never, cast


SCENARIO_SCHEMA = "masc.keeper-skill-proof-scenario/v1"

# lib/keeper/keeper_memory_os_current_layout.ml
MEMORY_CURRENT_SUFFIX = ".memory-current.json"
MEMORY_JOURNAL_SUFFIX = ".memory-journal.jsonl"
# lib/keeper/keeper_tool_descriptor.ml: public and internal name are the same.
MEMORY_WRITE_TOOL = "keeper_memory_write"
# lib/keeper/keeper_tool_memory_runtime.ml: the receipt outcome of a write
# committed to the current snapshot (other outcomes carry no memory_id).
MEMORY_WRITE_CURRENT_OUTCOME = "persisted_current_snapshot"
MEMORY_ID_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
# lib/keeper_tool_call_log.ml record_kind_to_string Tool_call
TOOL_CALL_RECORD_KIND = "tool_call"
# lib/types/ids.ml Turn_ref: "<trace_id>#<absolute_turn>", split on the last '#'.
TURN_REF_SEPARATOR = "#"
TURN_NUMBER_RE = re.compile(r"^[0-9]+$")

# Names of the copied authorities inside a proof directory.
EVIDENCE_TOOL_CALLS = "keeper-tool-calls.json"
EVIDENCE_MEMORY_CURRENT = "memory-current.json"
EVIDENCE_MEMORY_JOURNAL = "memory-journal.jsonl"

MEMORY_SOURCE_KINDS = frozenset({"librarian", "explicit_write", "explicit_retract"})
MEMORY_EXPLICIT_WRITE_SOURCE = "explicit_write"
MEMORY_JOURNAL_SKIPPED_OUTCOMES = frozenset({"failed", "quarantined"})


class CellError(RuntimeError):
    pass


class Cell(Enum):
    ACTION_SELECTED = "action_selected"
    EXTERNAL_EFFECT_APPLIED = "external_effect_applied"
    REQUESTED_POSTCONDITION_OBSERVED = "requested_postcondition_observed"


# ---------- scenario declaration ----------


@dataclass(frozen=True, slots=True)
class SelectionScenario:
    """The proof ends at a later model-selected action."""


@dataclass(frozen=True, slots=True)
class MemoryWriteScenario:
    """The selected ``keeper_memory_write`` must commit to current Memory."""


@dataclass(frozen=True, slots=True)
class RetainedMemoryScenario:
    """The memory that write committed must still be current Memory."""


Scenario: TypeAlias = Union[SelectionScenario, MemoryWriteScenario, RetainedMemoryScenario]

EFFECT_KIND_CURRENT_MEMORY_WRITE = "current_memory_write"
POSTCONDITION_KIND_MEMORY_RETAINED = "keeper_memory_retained"


def _object(value: object, context: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise CellError(f"{context} is not an object")
    return cast(dict[str, object], value)


def _exact(value: object, fields: set[str], context: str) -> dict[str, object]:
    record = _object(value, context)
    if set(record) != fields:
        raise CellError(
            f"{context} fields differ: expected={sorted(fields)} actual={sorted(record)}"
        )
    return record


def _list(value: object, context: str) -> list[object]:
    if not isinstance(value, list):
        raise CellError(f"{context} is not an array")
    return cast(list[object], value)


def _string(record: Mapping[str, object], field: str, context: str) -> str:
    value = record.get(field)
    if not isinstance(value, str) or value == "":
        raise CellError(f"{context}.{field} is not a nonempty string")
    return value


def _integer(record: Mapping[str, object], field: str, context: str, minimum: int) -> int:
    value = record.get(field)
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise CellError(f"{context}.{field} is not an integer >= {minimum}")
    return value


def decode_json(payload: bytes, context: str) -> object:
    def unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise CellError(f"{context} repeats field {key}")
            result[key] = value
        return result

    try:
        return json.loads(payload, object_pairs_hook=unique)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CellError(f"{context} is not valid JSON: {error}") from error


def decode_scenario(value: object) -> Scenario:
    context = "scenario"
    record = _object(value, context)
    if record.get("schema") != SCENARIO_SCHEMA:
        raise CellError(f"{context}.schema is not {SCENARIO_SCHEMA}")
    requires = record.get("requires")
    if requires == Cell.ACTION_SELECTED.value:
        _exact(record, {"schema", "requires"}, context)
        return SelectionScenario()
    if requires == Cell.EXTERNAL_EFFECT_APPLIED.value:
        _exact(record, {"schema", "requires", "effect"}, context)
        _current_memory_write(record["effect"])
        return MemoryWriteScenario()
    if requires == Cell.REQUESTED_POSTCONDITION_OBSERVED.value:
        _exact(record, {"schema", "requires", "effect", "postcondition"}, context)
        _current_memory_write(record["effect"])
        postcondition = _exact(record["postcondition"], {"kind"}, "scenario.postcondition")
        if postcondition["kind"] != POSTCONDITION_KIND_MEMORY_RETAINED:
            raise CellError("scenario.postcondition.kind is unknown")
        return RetainedMemoryScenario()
    raise CellError(f"{context}.requires is unknown")


def _current_memory_write(value: object) -> None:
    effect = _exact(value, {"kind"}, "scenario.effect")
    if effect["kind"] != EFFECT_KIND_CURRENT_MEMORY_WRITE:
        raise CellError(
            "scenario.effect.kind is unknown; this harness reads only "
            f"{EFFECT_KIND_CURRENT_MEMORY_WRITE}"
        )


def scenario_to_json(scenario: Scenario) -> dict[str, object]:
    effect = {"kind": EFFECT_KIND_CURRENT_MEMORY_WRITE}
    match scenario:
        case SelectionScenario():
            return {"schema": SCENARIO_SCHEMA, "requires": Cell.ACTION_SELECTED.value}
        case MemoryWriteScenario():
            return {
                "schema": SCENARIO_SCHEMA,
                "requires": Cell.EXTERNAL_EFFECT_APPLIED.value,
                "effect": effect,
            }
        case RetainedMemoryScenario():
            return {
                "schema": SCENARIO_SCHEMA,
                "requires": Cell.REQUESTED_POSTCONDITION_OBSERVED.value,
                "effect": effect,
                "postcondition": {"kind": POSTCONDITION_KIND_MEMORY_RETAINED},
            }
        case _:
            assert_never(scenario)


def effect_tool(scenario: Scenario) -> str | None:
    match scenario:
        case SelectionScenario():
            return None
        case MemoryWriteScenario() | RetainedMemoryScenario():
            return MEMORY_WRITE_TOOL
        case _:
            assert_never(scenario)


def required_cells(scenario: Scenario) -> tuple[Cell, ...]:
    match scenario:
        case SelectionScenario():
            return (Cell.ACTION_SELECTED,)
        case MemoryWriteScenario():
            return (Cell.ACTION_SELECTED, Cell.EXTERNAL_EFFECT_APPLIED)
        case RetainedMemoryScenario():
            return (
                Cell.ACTION_SELECTED,
                Cell.EXTERNAL_EFFECT_APPLIED,
                Cell.REQUESTED_POSTCONDITION_OBSERVED,
            )
        case _:
            assert_never(scenario)


def authority_names(scenario: Scenario) -> tuple[str, ...]:
    match scenario:
        case SelectionScenario():
            return ()
        case MemoryWriteScenario():
            return (EVIDENCE_TOOL_CALLS, EVIDENCE_MEMORY_JOURNAL)
        case RetainedMemoryScenario():
            return (EVIDENCE_TOOL_CALLS, EVIDENCE_MEMORY_JOURNAL, EVIDENCE_MEMORY_CURRENT)
        case _:
            assert_never(scenario)


def decode_turn_ref(turn_ref: str) -> tuple[str, int]:
    """``Ids.Turn_ref.of_string``: trace id and absolute Keeper turn."""
    trace_id, separator, turn = turn_ref.rpartition(TURN_REF_SEPARATOR)
    if separator == "" or trace_id == "" or TURN_NUMBER_RE.fullmatch(turn) is None:
        raise CellError(f"Turn_ref {turn_ref!r} is not <trace_id>#<turn>")
    return trace_id, int(turn)


# ---------- Memory journal ----------


def memory_id_of_claim(claim: str) -> str:
    return "sha256:" + sha256(claim.encode("utf-8")).hexdigest()


def _claim_ids(value: object, context: str) -> set[str]:
    ids: set[str] = set()
    for index, fact in enumerate(_list(value, context)):
        claim = _string(_object(fact, f"{context}[{index}]"), "claim", f"{context}[{index}]")
        ids.add(memory_id_of_claim(claim))
    return ids


@dataclass(frozen=True, slots=True)
class _Commit:
    revision: int
    source_kind: str
    trace_id: str
    added: frozenset[str]
    removed: frozenset[str]


def _journal_commits(payload: bytes | None) -> list[_Commit]:
    """Committed rows in append order; failed and quarantined rows are skipped."""
    commits: list[_Commit] = []
    for index, line in enumerate((payload or b"").split(b"\n")):
        if line.strip() == b"":
            continue
        context = f"Memory journal line {index}"
        row = _object(decode_json(line, context), context)
        outcome = row.get("outcome")
        if outcome in MEMORY_JOURNAL_SKIPPED_OUTCOMES:
            continue
        if outcome != "committed":
            raise CellError(f"{context}.outcome is unknown")
        source = _exact(row.get("source"), {"kind", "trace_id"}, f"{context}.source")
        source_kind = _string(source, "kind", f"{context}.source")
        if source_kind not in MEMORY_SOURCE_KINDS:
            raise CellError(f"{context}.source.kind is unknown")
        change = _object(row.get("change"), f"{context}.change")
        commits.append(
            _Commit(
                revision=_integer(row, "revision", context, 0),
                source_kind=source_kind,
                trace_id=_string(source, "trace_id", f"{context}.source"),
                added=frozenset(_claim_ids(change.get("added"), f"{context}.change.added")),
                removed=frozenset(
                    _claim_ids(change.get("removed"), f"{context}.change.removed")
                ),
            )
        )
    return commits


# ---------- effect cell ----------


class EffectGap(Enum):
    TOOL_NOT_SELECTED = "tool_not_selected"
    TOOL_SELECTED_MORE_THAN_ONCE = "tool_selected_more_than_once"
    SELECTION_HAS_NO_CALL_ID = "selection_has_no_call_id"
    INVOCATION_NOT_RECORDED = "invocation_not_recorded"
    INVOCATION_RECORDED_MORE_THAN_ONCE = "invocation_recorded_more_than_once"
    RECEIPT_UNREADABLE = "receipt_unreadable"
    WRITE_NOT_CURRENT = "write_not_current"
    COMMIT_NOT_JOURNALED = "commit_not_journaled"
    COMMIT_JOURNALED_MORE_THAN_ONCE = "commit_journaled_more_than_once"


@dataclass(frozen=True, slots=True)
class EffectApplied:
    call_id: str
    memory_id: str
    revision: int
    journal_index: int


@dataclass(frozen=True, slots=True)
class EffectMissing:
    gap: EffectGap
    call_id: str | None
    receipt: Mapping[str, object] | None


EffectObservation: TypeAlias = Union[EffectApplied, EffectMissing]


def _selections(actions: Sequence[object], tool_name: str) -> list[dict[str, object]]:
    selected: list[dict[str, object]] = []
    for index, value in enumerate(actions):
        context = f"activation.actions[{index}]"
        action = _object(value, context)
        if _string(action, "tool_name", context) == tool_name:
            selected.append(_object(action.get("identity"), f"{context}.identity"))
    return selected


def _invocations(payload: bytes, keeper: str, call_id: str) -> list[dict[str, object]]:
    context = "Keeper tool-calls answer"
    answer = _object(decode_json(payload, context), context)
    if answer.get("keeper") != keeper:
        raise CellError(f"{context} names another Keeper")
    rows: list[dict[str, object]] = []
    for index, value in enumerate(_list(answer.get("entries"), f"{context}.entries")):
        row = _object(value, f"{context}.entries[{index}]")
        if row.get("record_kind") == TOOL_CALL_RECORD_KIND and row.get("tool_use_id") == call_id:
            rows.append(row)
    return rows


def _receipt_summary(receipt: Mapping[str, object]) -> dict[str, object]:
    return {
        "ok": receipt.get("ok"),
        "outcome": receipt.get("outcome"),
        "error_kind": receipt.get("error_kind"),
    }


def observe_memory_write(
    *,
    keeper: str,
    turn_ref: str,
    actions: Sequence[object],
    tool_calls: bytes,
    memory_journal: bytes | None,
) -> EffectObservation:
    """Join the one selected write to its tool-call row and journal commit.

    activation -> action call id -> tool-call row with that ``tool_use_id``
    -> receipt (memory id, revision) -> the journal's explicit-write commit at
    that revision in this trace.  Two candidates at a step cannot be paired
    exactly and are reported, not guessed.
    """
    selections = _selections(actions, MEMORY_WRITE_TOOL)
    if not selections:
        return EffectMissing(EffectGap.TOOL_NOT_SELECTED, None, None)
    if len(selections) > 1:
        return EffectMissing(EffectGap.TOOL_SELECTED_MORE_THAN_ONCE, None, None)
    identity = selections[0]
    if identity.get("kind") != "call_id":
        return EffectMissing(EffectGap.SELECTION_HAS_NO_CALL_ID, None, None)
    call_id = _string(identity, "call_id", "selected action identity")
    trace_id, keeper_turn = decode_turn_ref(turn_ref)
    rows = _invocations(tool_calls, keeper, call_id)
    if not rows:
        return EffectMissing(EffectGap.INVOCATION_NOT_RECORDED, call_id, None)
    if len(rows) > 1:
        return EffectMissing(EffectGap.INVOCATION_RECORDED_MORE_THAN_ONCE, call_id, None)
    row = rows[0]
    context = f"tool-call row {call_id}"
    if (
        row.get("keeper") != keeper
        or row.get("tool") != MEMORY_WRITE_TOOL
        or row.get("trace_id") != trace_id
        or row.get("keeper_turn_id") != keeper_turn
    ):
        raise CellError(f"{context} names another Keeper, tool, trace or turn")
    output = row.get("output")
    if not isinstance(output, str):
        return EffectMissing(EffectGap.RECEIPT_UNREADABLE, call_id, None)
    try:
        receipt = _object(decode_json(output.encode("utf-8"), context), context)
    except CellError:
        return EffectMissing(EffectGap.RECEIPT_UNREADABLE, call_id, None)
    memory_id = receipt.get("memory_id")
    revision = receipt.get("revision")
    if not (
        receipt.get("ok") is True
        and receipt.get("outcome") == MEMORY_WRITE_CURRENT_OUTCOME
        and isinstance(memory_id, str)
        and MEMORY_ID_RE.fullmatch(memory_id) is not None
        and isinstance(revision, int)
        and not isinstance(revision, bool)
        and revision >= 1
    ):
        return EffectMissing(EffectGap.WRITE_NOT_CURRENT, call_id, _receipt_summary(receipt))
    commits = [
        index
        for index, commit in enumerate(_journal_commits(memory_journal))
        if commit.revision == revision
        and commit.source_kind == MEMORY_EXPLICIT_WRITE_SOURCE
        and commit.trace_id == trace_id
    ]
    if not commits:
        return EffectMissing(EffectGap.COMMIT_NOT_JOURNALED, call_id, _receipt_summary(receipt))
    if len(commits) > 1:
        return EffectMissing(
            EffectGap.COMMIT_JOURNALED_MORE_THAN_ONCE, call_id, _receipt_summary(receipt)
        )
    return EffectApplied(
        call_id=call_id, memory_id=memory_id, revision=revision, journal_index=commits[0]
    )


# ---------- postcondition cell ----------


@dataclass(frozen=True, slots=True)
class EffectNotApplied:
    pass


@dataclass(frozen=True, slots=True)
class NoCurrentSnapshot:
    memory_id: str
    written_revision: int


@dataclass(frozen=True, slots=True)
class MemoryRetained:
    memory_id: str
    written_revision: int
    snapshot_revision: int


@dataclass(frozen=True, slots=True)
class MemoryRemoved:
    memory_id: str
    written_revision: int
    snapshot_revision: int
    removed_in_revision: int
    removed_by: str


@dataclass(frozen=True, slots=True)
class MemoryAbsent:
    """Not current, and no journal commit after the write removed it.

    A store restart (quarantine, then a new snapshot from revision 1) drops
    facts without a removal row; its snapshot revision can be below the
    written one.
    """

    memory_id: str
    written_revision: int
    snapshot_revision: int


PostconditionObservation: TypeAlias = Union[
    EffectNotApplied,
    NoCurrentSnapshot,
    MemoryRetained,
    MemoryRemoved,
    MemoryAbsent,
]


def observe_retained_memory(
    *,
    effect: EffectObservation,
    memory_current: bytes | None,
    memory_journal: bytes | None,
) -> PostconditionObservation:
    """Whether the memory the write committed is still current."""
    match effect:
        case EffectMissing():
            return EffectNotApplied()
        case EffectApplied():
            pass
        case _:
            assert_never(effect)
    memory_id, written_revision = effect.memory_id, effect.revision
    if memory_current is None:
        return NoCurrentSnapshot(memory_id=memory_id, written_revision=written_revision)
    snapshot = _exact(
        decode_json(memory_current, "current Memory snapshot"),
        {"revision", "updated_at", "source", "facts", "change"},
        "current Memory snapshot",
    )
    snapshot_revision = _integer(snapshot, "revision", "current Memory snapshot", 1)
    commits = _journal_commits(memory_journal)
    if commits and commits[-1].revision > snapshot_revision:
        raise CellError("Memory journal's last commit is newer than the captured snapshot")
    if memory_id in _claim_ids(snapshot["facts"], "current Memory snapshot.facts"):
        return MemoryRetained(
            memory_id=memory_id,
            written_revision=written_revision,
            snapshot_revision=snapshot_revision,
        )
    removals = [
        commit
        for commit in commits[effect.journal_index + 1 :]
        if memory_id in commit.removed and memory_id not in commit.added
    ]
    if not removals:
        return MemoryAbsent(
            memory_id=memory_id,
            written_revision=written_revision,
            snapshot_revision=snapshot_revision,
        )
    removal = removals[-1]
    return MemoryRemoved(
        memory_id=memory_id,
        written_revision=written_revision,
        snapshot_revision=snapshot_revision,
        removed_in_revision=removal.revision,
        removed_by=removal.source_kind,
    )


# ---------- cells ----------


@dataclass(frozen=True, slots=True)
class MemoryAuthorities:
    tool_calls: bytes
    journal: bytes | None
    current: bytes | None


@dataclass(frozen=True, slots=True)
class Cells:
    scenario: Scenario
    selected_actions: int
    effect: EffectObservation | None
    postcondition: PostconditionObservation | None

    def observed(self, cell: Cell) -> int | None:
        match cell:
            case Cell.ACTION_SELECTED:
                return self.selected_actions
            case Cell.EXTERNAL_EFFECT_APPLIED:
                match self.effect:
                    case None:
                        return None
                    case EffectApplied():
                        return 1
                    case EffectMissing():
                        return 0
                    case _:
                        assert_never(self.effect)
            case Cell.REQUESTED_POSTCONDITION_OBSERVED:
                match self.postcondition:
                    case None:
                        return None
                    case MemoryRetained():
                        return 1
                    case (
                        EffectNotApplied()
                        | NoCurrentSnapshot()
                        | MemoryRemoved()
                        | MemoryAbsent()
                    ):
                        return 0
                    case _:
                        assert_never(self.postcondition)
            case _:
                assert_never(cell)

    def unmet(self) -> list[str]:
        """One line per required cell that observed nothing."""
        details: list[str] = []
        for cell in required_cells(self.scenario):
            if (self.observed(cell) or 0) >= 1:
                continue
            evidence = self.to_json()[cell.value]
            details.append(f"scenario requires {cell.value}: {json.dumps(evidence, sort_keys=True)}")
        return details

    def to_json(self) -> dict[str, object]:
        required = required_cells(self.scenario)

        def cell_json(cell: Cell, evidence: dict[str, object]) -> dict[str, object]:
            return {
                "required": cell in required,
                "observed": self.observed(cell),
                "evidence": evidence,
            }

        return {
            "scenario": scenario_to_json(self.scenario),
            Cell.ACTION_SELECTED.value: cell_json(
                Cell.ACTION_SELECTED, {"tool_name": effect_tool(self.scenario)}
            ),
            Cell.EXTERNAL_EFFECT_APPLIED.value: cell_json(
                Cell.EXTERNAL_EFFECT_APPLIED, _effect_json(self.effect)
            ),
            Cell.REQUESTED_POSTCONDITION_OBSERVED.value: cell_json(
                Cell.REQUESTED_POSTCONDITION_OBSERVED,
                _postcondition_json(self.postcondition),
            ),
        }


def _effect_json(effect: EffectObservation | None) -> dict[str, object]:
    match effect:
        case None:
            return {"status": "not_declared"}
        case EffectApplied():
            return {
                "status": "applied",
                "call_id": effect.call_id,
                "memory_id": effect.memory_id,
                "revision": effect.revision,
            }
        case EffectMissing():
            return {
                "status": effect.gap.value,
                "call_id": effect.call_id,
                "receipt": None if effect.receipt is None else dict(effect.receipt),
            }
        case _:
            assert_never(effect)


def _postcondition_json(observation: PostconditionObservation | None) -> dict[str, object]:
    match observation:
        case None:
            return {"status": "not_declared"}
        case EffectNotApplied():
            return {"status": "effect_not_applied"}
        case NoCurrentSnapshot():
            return {
                "status": "no_current_snapshot",
                "memory_id": observation.memory_id,
                "written_revision": observation.written_revision,
            }
        case MemoryRetained():
            return {
                "status": "retained",
                "memory_id": observation.memory_id,
                "written_revision": observation.written_revision,
                "snapshot_revision": observation.snapshot_revision,
            }
        case MemoryRemoved():
            return {
                "status": "removed",
                "memory_id": observation.memory_id,
                "written_revision": observation.written_revision,
                "snapshot_revision": observation.snapshot_revision,
                "removed_in_revision": observation.removed_in_revision,
                "removed_by": observation.removed_by,
            }
        case MemoryAbsent():
            return {
                "status": "absent",
                "memory_id": observation.memory_id,
                "written_revision": observation.written_revision,
                "snapshot_revision": observation.snapshot_revision,
            }
        case _:
            assert_never(observation)


def observe_cells(
    *,
    scenario: Scenario,
    keeper: str,
    turn_ref: str,
    actions: Sequence[object],
    memory: MemoryAuthorities | None,
) -> Cells:
    def write_effect() -> tuple[MemoryAuthorities, EffectObservation]:
        if memory is None:
            raise CellError("the scenario declares a Memory write but no authority was read")
        return memory, observe_memory_write(
            keeper=keeper,
            turn_ref=turn_ref,
            actions=actions,
            tool_calls=memory.tool_calls,
            memory_journal=memory.journal,
        )

    match scenario:
        case SelectionScenario():
            return Cells(scenario, len(actions), None, None)
        case MemoryWriteScenario():
            _authorities, effect = write_effect()
            return Cells(
                scenario, len(_selections(actions, MEMORY_WRITE_TOOL)), effect, None
            )
        case RetainedMemoryScenario():
            authorities, effect = write_effect()
            return Cells(
                scenario,
                len(_selections(actions, MEMORY_WRITE_TOOL)),
                effect,
                observe_retained_memory(
                    effect=effect,
                    memory_current=authorities.current,
                    memory_journal=authorities.journal,
                ),
            )
        case _:
            assert_never(scenario)
