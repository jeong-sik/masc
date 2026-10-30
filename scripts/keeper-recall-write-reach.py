#!/usr/bin/env python3
# pyright: strict
"""Measure whether what Keepers write with ``keeper_memory_write`` reaches the current Memory.

The tool answers with a receipt. ``persisted_pending_admission`` means the claim
waits in the Keeper's admission queue until the Librarian judges it, and the
receipt does not say whether the claim became a current fact. This script
follows each write after its receipt (RFC-keeper-recall-reaches-the-turn,
section 5, layer 0 item 4). It prints counts and one row per Keeper: no claim
text, no reason text and no memory id.

1. The write calls: the ``tool_execution_finished`` records of the tool in
   ``<keepers-dir>/<keeper>/raw-traces/*.jsonl``. Every call is counted once:
   a receipt that says ok (by outcome), a rejection (by ``error_kind``), a tool
   error without a receipt, a result that is not a receipt, or a native call of
   an official client, whose result text the trace does not hold. A queued
   write is matched by its ``request_id`` to what happened to it: settled by
   the Librarian, still waiting in ``<keeper>.memory-admission.json``, or no
   record of it anywhere.
2. The candidates the Librarian settled, for every runtime
   (``<keeper>.librarian-range-commit.json``). A receipt with
   ``admission_recall_binding`` settled the candidate with a target fact, and
   one with only ``explicit_candidate_id`` settled it without one. The
   librarian runtime builds a binding for ``Incorporated`` and
   ``Already_represented`` and none for ``Not_durable``
   (lib/keeper/keeper_librarian_runtime.ml:920-933); a ``Deferred`` candidate
   is not settled (lib/keeper/keeper_memory_admission_judgment.ml:104). For a
   candidate with a target:

   * The time of a journal row. For an admission pass ``recorded_at`` is the
     time the pass read the admission queue, not the time its judgment ended:
     the pass takes ``now`` before the judgment and the commit writes that value
     (lib/keeper/keeper_librarian_admission_owner.ml:128,
     lib/keeper/keeper_librarian_admission_commit.ml:221). Other Librarian
     commits stamp their commit time, and the receipt does not say which kind
     of pass wrote a row. Only rows whose
     ``source.kind`` is ``librarian`` count as passes. A receipt names a Memory
     revision, not the pass that settled it, and a pass that changes nothing
     writes another row with the revision it kept; so a revision has one or more
     distinct stamps.
   * Whether the target was added before the write: the earliest committed
     journal row (any source) whose ``change.added`` holds the target, against
     the time the Keeper wrote the candidate (``source_fact.first_seen``). A
     target first added by a row stamped at or after the write is exact: that
     pass read the queue after the write. A target added by a row stamped before
     the write is an upper bound, because a pass that started before the write
     can commit after it. The receipt does not say which pass added a target,
     so several candidates can share one, and a target that left and came back
     is dated by its first addition. A target that no row adds, or whose
     receipt has no usable write time, is counted with the upper bound: a fact
     can exist without an adding row, and the report counts how many current
     facts do.
   * Whether the target has the memory id of the Keeper's own sentence. A
     memory id is the SHA-256 of a claim, so a sentence the Librarian reworded
     has another id.
   * Where the target stands now. The records are followed as in
     keeper-recall-baseline.py: a revised record (``superseded_by``) or an
     absorbed record (``into``) leads from an id that is no longer current to
     its successor, and so on until a current fact, a retracted id or an id
     without records. A claim that was retracted and added again is current.
     For a target whose records end without a current fact or a retraction, the
     id where they end is looked up in the committed rows that removed it: whether
     the row's ``dropped`` list gives a reason (the reason text is not read out),
     whether the same row also added a fact and whether it is a Librarian pass.
     The same two shares are counted over a population of the same kind: ids
     that are not current, that no revised, absorbed or retracted record leads
     out of, and that a Librarian pass removed since the first write of the
     window. They are the shares the ends above are read against.
   * The time from the write to the journal stamp of the settling pass, as a
     range: the earliest is the first Librarian stamp of the revision at or after
     the write, the latest is the last stamp of the revision. Neither includes
     the time the judgment took.
3. The coverage of the call table. Raw traces keep only the most recent turns of
   a Keeper (about 200 files each), so a candidate written before the oldest
   trace of its Keeper has no call to match. The table says how many candidates
   have a matching call and where the rest were written. The age of a trace
   comes from its file name (``turn-<milliseconds>-...``).
4. The admission queues: every row of every queue file, and for each Keeper
   that holds any, the age of its oldest row (``fact.first_seen``) and the stamp
   of its last Librarian row in the journal. A row is counted whether or not a
   trace call names it. The queue says how many rows wait now, not how long a
   write waits before the Librarian settles it; the second is the range of
   seconds above. The journal does not record a pass that settled nothing
   (every answer deferred), so an old last row means that no pass ran or that
   every pass deferred; the report cannot tell which.

Receipts the Librarian wrote for its own reads (``range_id``,
``official_range_id``) are not candidates and are counted apart.

Read-only. Both directories are arguments; nothing is assumed about where
``<base-path>/.masc`` lives. ``--since`` bounds the write calls by their time and
the candidates by the time they were written; a receipt without a source fact is
dated by its settlement, the Librarian stamps of its revision: all before
``--since`` is older, all at or after it is inside (it may have been written
before ``--since`` and settled after it), and stamps on both sides cannot be
placed. A Keeper is read when it made a write call or has a receipt, queue,
journal or current-facts file. A missing events or absorbed file is an empty
list, because a Keeper that never revised or absorbed a fact has none; a missing
receipts, queue, journal or current file is named in the Keeper table, with a
note for a journal whose revision numbering began again (a quarantine row, or a
revision lower than the one before it), so the stamps before each restart are
dropped. Input the script cannot use (a line that is not JSON, a row without a
time, a time past the calendar such as an epoch in milliseconds) is counted in
the last line.

Usage:
    python3 -I scripts/keeper-recall-write-reach.py <base-path>/.masc/keepers \\
        --memory-dir <base-path>/.masc/config/keepers --since 2026-10-02 \\
        --exclude lab-sangsu --exclude taskmaster --exclude microvm-probe-829
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime
import enum
import glob
import hashlib
import json
import os
import re
import statistics
import sys
import time
from collections.abc import Iterator

WRITE_TOOL = "keeper_memory_write"
RECORD_STARTED = ("tool_execution_started", "native_tool_started")
RECORD_FINISHED = ("tool_execution_finished", "native_tool_finished")
NATIVE_FINISHED = "native_tool_finished"
PENDING_OUTCOME = "persisted_pending_admission"
RECEIPT_COMMITTED = "committed"
QUARANTINED = "quarantined"
LIBRARIAN_SOURCE = "librarian"
MEMORY_ID_PREFIX = "sha256:"
# A Keeper is read when it made a write call or has any of these files in the memory directory.
KEEPER_FILE_SUFFIXES = (".librarian-range-commit.json", ".memory-admission.json", ".memory-journal.jsonl", ".memory-current.json")
# Raw trace files are named turn-<epoch milliseconds>-<hash>-<sequence>.jsonl.
TRACE_NAME = re.compile(r"turn-(\d{13})-")

# What json.loads returns. Narrowing it with isinstance keeps every element type known.
type Json = dict[str, Json] | list[Json] | str | int | float | bool | None
# Input the script could not use, by reason.
type Skipped = collections.Counter[str]


def read_jsonl(path: str, skipped: Skipped, label: str, needle: str = "") -> Iterator[dict[str, Json]]:
    """Rows of a JSON-lines file; a line without ``needle`` is skipped before it is parsed.

    A missing file has no rows. Any other failure to open it, and every line that
    is not a JSON object, is counted in ``skipped``.
    """
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return
    except OSError:
        skipped[f"{label} files that could not be opened"] += 1
        return
    with handle:
        for line in handle:
            if (needle and needle not in line) or not line.strip():
                continue
            try:
                row: Json = json.loads(line)
            except ValueError:
                skipped[f"{label} lines that were not JSON"] += 1
                continue
            if isinstance(row, dict):
                yield row
            else:
                skipped[f"{label} lines that were not a JSON object"] += 1


def number_of(value: Json) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        return float(value)
    except OverflowError:  # an integer too large for a float
        return None


def int_of(value: Json) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def as_str(value: Json) -> str:
    return value if isinstance(value, str) else ""


def as_dict(value: Json) -> dict[str, Json]:
    return value if isinstance(value, dict) else {}


def as_list(value: Json) -> list[Json]:
    return value if isinstance(value, list) else []


def memory_id_of(claim: str) -> str:
    # Keeper_memory_os_types.memory_id: the SHA-256 of the claim bytes. A lone surrogate has no UTF-8
    # form; it is passed through so that one odd claim cannot stop the run, and it matches nothing.
    return MEMORY_ID_PREFIX + hashlib.sha256(claim.encode("utf-8", "surrogatepass")).hexdigest()


def quantile(sorted_values: list[float], fraction: float) -> float:
    return sorted_values[int(fraction * (len(sorted_values) - 1))] if sorted_values else 0.0


def percent(part: int, whole: int) -> str:
    return f"{100 * part / whole:.1f}%" if whole else "-"


def iso(epoch: float) -> str:
    return datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def moment_of(value: Json) -> float | None:
    """An epoch in seconds that ``iso`` can print; None for a non-number and for a number past the calendar (milliseconds, NaN, infinity)."""
    seconds = number_of(value)
    if seconds is None:
        return None
    try:
        iso(seconds)
    except (ValueError, OverflowError, OSError):
        return None
    return seconds


class Kind(enum.Enum):
    """What a write call's finished record holds."""

    RECEIPT_OK = "receipt, ok"
    REJECTED = "receipt, rejected"
    TOOL_ERROR = "tool error without a receipt"
    UNREADABLE = "result is not a receipt"
    NOT_RECORDED = "result not in the trace (native call of an official client)"


@dataclasses.dataclass(frozen=True)
class WriteCall:
    keeper: str
    ts: float
    kind: Kind
    outcome: str  # RECEIPT_OK: the receipt's outcome
    error_kind: str  # REJECTED: the receipt's error_kind
    request_id: str  # RECEIPT_OK with the pending outcome: the admission request


def receipt_of(text: Json) -> dict[str, Json] | None:
    """The receipt is the first line of the result; a rejection appends prose lines after it."""
    if not isinstance(text, str):
        return None
    try:
        value: Json = json.loads(text.split("\n", 1)[0])
    except ValueError:
        return None
    return value if isinstance(value, dict) and isinstance(value.get("ok"), bool) else None


def call_of(keeper: str, record: dict[str, Json], ts: float) -> WriteCall:
    if record.get("record_type") == NATIVE_FINISHED:
        return WriteCall(keeper, ts, Kind.NOT_RECORDED, "", "", "")
    receipt = receipt_of(record.get("tool_result"))
    if receipt is None:
        kind = Kind.TOOL_ERROR if record.get("tool_error") is True else Kind.UNREADABLE
        return WriteCall(keeper, ts, kind, "", "", "")
    if not receipt["ok"]:
        return WriteCall(keeper, ts, Kind.REJECTED, "", as_str(receipt.get("error_kind")), "")
    outcome, request_id = as_str(receipt.get("outcome")), as_str(receipt.get("request_id"))
    if outcome == PENDING_OUTCOME and not request_id:
        return WriteCall(keeper, ts, Kind.UNREADABLE, "", "", "")
    return WriteCall(keeper, ts, Kind.RECEIPT_OK, outcome, "", request_id)


def call_key(keeper: str, record: dict[str, Json]) -> tuple[str, str, str] | None:
    """What pairs a started record with its finished record; None when the record names no call."""
    identity = record.get("tool_use_id")
    if not isinstance(identity, str) or not identity:
        native = record.get("native_tool_identity")
        if native is None:
            return None
        identity = json.dumps(native, sort_keys=True)
    return (keeper, as_str(record.get("worker_run_id")), identity)


def turn_start_of(path: str) -> float | None:
    """The start of the turn a raw trace file belongs to, from its name."""
    match = TRACE_NAME.match(os.path.basename(path))
    return int(match.group(1)) / 1000 if match else None


@dataclasses.dataclass(frozen=True)
class TraceWindow:
    files: int
    oldest: float | None  # the start of the oldest retained turn; None when no file name carries one


@dataclasses.dataclass(frozen=True)
class TraceScan:
    calls: list[WriteCall]
    started_without_finished: int
    finished_twice: int
    windows: dict[str, TraceWindow]


def scan_traces(keepers_dir: str, only: set[str], excluded: set[str], since: float | None, skipped: Skipped) -> TraceScan:
    calls: list[WriteCall] = []
    started: set[tuple[str, str, str]] = set()
    finished: set[tuple[str, str, str]] = set()
    finished_twice = 0
    files: collections.Counter[str] = collections.Counter()
    turn_starts: dict[str, list[float]] = collections.defaultdict(list)
    for path in sorted(glob.glob(os.path.join(keepers_dir, "*", "raw-traces", "*.jsonl"))):
        keeper = path.split(os.sep)[-3]
        if keeper in excluded or (only and keeper not in only):
            continue
        files[keeper] += 1
        turn_start = turn_start_of(path)
        if turn_start is None:
            skipped["raw trace files whose name has no turn start"] += 1
        else:
            turn_starts[keeper].append(turn_start)
        for record in read_jsonl(path, skipped, "trace", WRITE_TOOL):
            if not as_str(record.get("tool_name")).endswith(WRITE_TOOL):
                continue
            ts = moment_of(record.get("ts"))
            if ts is None:
                skipped["write records whose ts is not a usable time"] += 1
                continue
            if since is not None and ts < since:
                continue
            record_type = record.get("record_type")
            key = call_key(keeper, record)
            if key is None and record_type in (RECORD_STARTED + RECORD_FINISHED):
                skipped["write records that name no call (not paired)"] += 1
            if record_type in RECORD_STARTED and key is not None:
                started.add(key)
            elif record_type in RECORD_FINISHED:
                if key is not None:
                    if key in finished:
                        finished_twice += 1
                        continue
                    finished.add(key)
                calls.append(call_of(keeper, record, ts))
    windows = {keeper: TraceWindow(count, min(turn_starts[keeper]) if turn_starts[keeper] else None) for keeper, count in files.items()}
    return TraceScan(calls, len(started - finished), finished_twice, windows)


@dataclasses.dataclass(frozen=True)
class Settled:
    """A candidate the Librarian settled, from one committed receipt."""

    revision: int  # the Memory revision the settlement names
    target: str  # the memory id it was settled with; empty when it was settled without one
    first_seen: float | None  # when the Keeper wrote it; None when the receipt holds no source fact
    own_sentence: bool  # the target has the memory id of the Keeper's own claim


class Skip(enum.Enum):
    """Why a receipt is not a settled candidate."""

    NOT_COMMITTED = "state is not committed"
    RANGE = "a Librarian read range (range_id)"
    OFFICIAL_RANGE = "a Librarian official-client read range (official_range_id)"
    OTHER_SHAPE = "another shape"
    REPEATED = "a request id that an earlier receipt already settled"


def settlement_of(receipt: dict[str, Json], skipped: Skipped) -> tuple[str, Settled] | Skip:
    revision = int_of(receipt.get("snapshot_revision"))
    if receipt.get("state") != RECEIPT_COMMITTED or revision is None:
        return Skip.NOT_COMMITTED
    binding = as_dict(receipt.get("admission_recall_binding"))
    if binding:
        request_id = as_str(as_dict(binding.get("candidate_id")).get("request_id"))
        target = as_str(binding.get("target_memory_id"))
        if not request_id or not target:
            return Skip.OTHER_SHAPE
        source = as_dict(binding.get("source_fact"))
        first_seen = moment_of(source.get("first_seen"))
        if first_seen is None:
            skipped["settled receipts whose source fact has no usable first_seen (read as having no write time)"] += 1
        own = memory_id_of(as_str(source.get("claim"))) == target
        return request_id, Settled(revision, target, first_seen, own)
    request_id = as_str(as_dict(receipt.get("explicit_candidate_id")).get("request_id"))
    if request_id:
        return request_id, Settled(revision, "", None, False)
    if "range_id" in receipt:
        return Skip.RANGE
    if "official_range_id" in receipt:
        return Skip.OFFICIAL_RANGE
    return Skip.OTHER_SHAPE


@dataclasses.dataclass(frozen=True)
class Removal:
    """The last committed row that took a fact out of the current set."""

    reasoned: bool  # the row's dropped list names the fact with a written reason
    replaced: bool  # the same row also added a fact
    recorded_at: float  # the stamp of the row
    librarian: bool  # the row is a Librarian pass (source.kind is librarian)


@dataclasses.dataclass(frozen=True)
class Journal:
    revision_times: dict[int, tuple[float, ...]]  # revision -> distinct stamps of its Librarian rows, ascending
    first_added: dict[str, float]  # memory id -> the earliest committed row (any source) that added it
    removals: dict[str, Removal]  # memory id -> the last committed row that removed it
    restarts: int  # times the revision numbering began again: a quarantine row, or a revision that went back
    last_librarian: float | None  # the stamp of the latest committed Librarian row, also before a restart


def read_journal(path: str, skipped: Skipped) -> Journal:
    stamps: dict[int, set[float]] = collections.defaultdict(set)
    first_added: dict[str, float] = {}
    removals: dict[str, Removal] = {}
    restarts = 0
    previous_revision: int | None = None
    last_librarian: float | None = None
    for row in read_jsonl(path, skipped, "journal"):
        if row.get("outcome") == QUARANTINED:
            # The numbering begins again after a quarantine, so the stamps before it name other snapshots. A fact id is
            # a hash of its claim and stays comparable across the restart.
            stamps.clear()
            restarts += 1
            previous_revision = None
            continue
        if row.get("outcome") != RECEIPT_COMMITTED:
            continue
        revision, recorded_at = int_of(row.get("revision")), moment_of(row.get("recorded_at"))
        if revision is None or recorded_at is None:
            skipped["committed journal rows without a revision or a usable recorded_at"] += 1
            continue
        if previous_revision is not None and revision < previous_revision:
            # A revision that goes back is a restart as well: with no snapshot to follow, the numbering begins at 1
            # (keeper_memory_os_support_core.ml:210), and the quarantine row that would say so is appended unchecked.
            # A restart that lands on the same number as the row before it cannot be seen.
            stamps.clear()
            restarts += 1
        previous_revision = revision
        librarian = as_str(as_dict(row.get("source")).get("kind")) == LIBRARIAN_SOURCE
        if librarian:
            stamps[revision].add(recorded_at)
            last_librarian = recorded_at if last_librarian is None else max(last_librarian, recorded_at)
        change = as_dict(row.get("change"))
        added = as_list(change.get("added"))
        for fact in added:
            memory_id = memory_id_of(as_str(as_dict(fact).get("claim")))
            first_added[memory_id] = min(first_added.get(memory_id, recorded_at), recorded_at)
        reasoned = {
            as_str(as_dict(dropped).get("memory_id"))
            for dropped in as_list(row.get("dropped"))
            if as_str(as_dict(dropped).get("reason")).strip()
        }
        for fact in as_list(change.get("removed")):
            memory_id = memory_id_of(as_str(as_dict(fact).get("claim")))
            removals[memory_id] = Removal(memory_id in reasoned, bool(added), recorded_at, librarian)
    return Journal({revision: tuple(sorted(rows)) for revision, rows in stamps.items()}, first_added, removals, restarts, last_librarian)


class Standing(enum.Enum):
    CURRENT = "a current fact"
    BY_REWRITE = "not current; revised records alone lead to a current fact"
    BY_ABSORPTION = "not current; the records cross an absorption and lead to a current fact"
    DEAD_END = "not current; the records lead to an id that is gone"
    RETRACTED = "retracted"
    REMOVED = "not current, no revised, absorbed or retracted record; a committed journal row removed it"
    NO_RECORD = "not current and no file mentions it"

    @property
    def reaches_current(self) -> bool:
        return self in (Standing.CURRENT, Standing.BY_REWRITE, Standing.BY_ABSORPTION)

    @property
    def ends_nowhere(self) -> bool:
        """The records end without a current fact or a retraction."""
        return self in (Standing.DEAD_END, Standing.REMOVED, Standing.NO_RECORD)


@dataclasses.dataclass(frozen=True)
class Lineage:
    current: frozenset[str]
    revised: dict[str, str]  # memory id -> superseded_by
    absorbed: dict[str, str]  # memory id -> into
    retracted: frozenset[str]


@dataclasses.dataclass(frozen=True)
class Followed:
    standing: Standing
    last_id: str  # the id where the records end; the target itself when no record leaves it


def follow(memory_id: str, lineage: Lineage, removals: dict[str, Removal]) -> Followed:
    """Follow one memory id through its revised and absorbed records (keeper-recall-baseline.py does the same)."""
    seen: set[str] = set()
    followed = False
    absorbed_hop = False
    node = memory_id
    while True:
        if node in lineage.current:
            if not followed:
                return Followed(Standing.CURRENT, node)
            return Followed(Standing.BY_ABSORPTION if absorbed_hop else Standing.BY_REWRITE, node)
        if node in seen:
            return Followed(Standing.DEAD_END, node)
        seen.add(node)
        if node in lineage.revised:
            node = lineage.revised[node]
        elif node in lineage.absorbed:
            node = lineage.absorbed[node]
            absorbed_hop = True
        elif node in lineage.retracted:
            return Followed(Standing.RETRACTED, node)
        else:
            if followed:
                return Followed(Standing.DEAD_END, node)
            return Followed(Standing.REMOVED if node in removals else Standing.NO_RECORD, node)
        followed = True


class Origin(enum.Enum):
    """When a settled target was first added, against the time the Keeper wrote the candidate."""

    AFTER = "first added by a row stamped at or after the write"
    BEFORE = "added by a row stamped before the write"
    UNKNOWN = "that no commit row adds, or whose receipt has no usable write time"


@dataclasses.dataclass(frozen=True)
class KeeperState:
    settled: dict[str, Settled]  # request id -> settlement
    waiting: frozenset[str]  # request ids still in the admission queue
    waiting_rows: int  # every row in the admission queue, whether or not it names a request id
    oldest_waiting: float | None  # the earliest usable fact.first_seen among those rows
    journal: Journal
    has_journal: bool  # the journal file exists; without it, "no Librarian row" says nothing
    lineage: Lineage
    not_candidates: collections.Counter[Skip]
    problems: tuple[str, ...]  # files that were missing or unreadable

    def revision_time(self, settled: Settled) -> float | None:
        """The first Librarian stamp of the revision a receipt names."""
        times = self.journal.revision_times.get(settled.revision)
        return times[0] if times else None

    def last_commit(self) -> float | None:
        """The latest Librarian stamp of the journal: the last pass that committed."""
        return self.journal.last_librarian

    def oldest_receipt(self) -> float | None:
        times = [when for when in map(self.revision_time, self.settled.values()) if when is not None]
        return min(times) if times else None

    def origin_of(self, settled: Settled) -> Origin:
        added = self.journal.first_added.get(settled.target)
        if added is None or settled.first_seen is None:
            return Origin.UNKNOWN
        return Origin.AFTER if added >= settled.first_seen else Origin.BEFORE

    def settle_bounds(self, settled: Settled) -> tuple[float, float] | None:
        """Seconds from the write to the earliest and to the latest Librarian stamp that could belong to the settling pass."""
        times = self.journal.revision_times.get(settled.revision, ())
        written = settled.first_seen
        after = [when for when in times if written is not None and when >= written]
        if written is None or not after:
            return None
        return after[0] - written, times[-1] - written


def load_json(path: str) -> tuple[Json, str]:
    """The parsed file and "", or None and what was wrong with it."""
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle), ""
    except FileNotFoundError:
        return None, f"missing {os.path.basename(path)}"
    except (OSError, ValueError):
        return None, f"unreadable {os.path.basename(path)}"


def load_state(memory_dir: str, keeper: str, skipped: Skipped) -> KeeperState:
    def path(suffix: str) -> str:
        return os.path.join(memory_dir, f"{keeper}{suffix}")

    problems: list[str] = []
    settled: dict[str, Settled] = {}
    not_candidates: collections.Counter[Skip] = collections.Counter()
    receipts, problem = load_json(path(".librarian-range-commit.json"))
    if problem:
        problems.append(problem)
    for receipt in as_list(as_dict(receipts).get("receipts")):
        found = settlement_of(as_dict(receipt), skipped)
        if isinstance(found, Skip):
            not_candidates[found] += 1
        elif found[0] in settled:
            not_candidates[Skip.REPEATED] += 1
        else:
            settled[found[0]] = found[1]

    queue, problem = load_json(path(".memory-admission.json"))
    if problem:
        problems.append(problem)
    pending = [as_dict(row) for row in as_list(as_dict(queue).get("pending"))]
    waiting = frozenset(request_id for request_id in (as_str(row.get("request_id")) for row in pending) if request_id)
    written: list[float] = []
    for row in pending:
        first_seen = moment_of(as_dict(row.get("fact")).get("first_seen"))
        if first_seen is None:
            skipped["admission queue rows whose fact.first_seen is not a usable time (left out of the oldest age)"] += 1
        else:
            written.append(first_seen)

    has_journal = os.path.exists(path(".memory-journal.jsonl"))
    if not has_journal:
        problems.append(f"missing {keeper}.memory-journal.jsonl")
    journal = read_journal(path(".memory-journal.jsonl"), skipped)
    if journal.restarts:
        problems.append(
            f"{keeper}.memory-journal.jsonl holds {journal.restarts} revision restarts (a quarantine row, or a revision that went back); "
            "the stamps before each are dropped"
        )

    snapshot, problem = load_json(path(".memory-current.json"))
    if problem:
        problems.append(problem)
    current = frozenset(memory_id_of(as_str(as_dict(fact).get("claim"))) for fact in as_list(as_dict(snapshot).get("facts")))
    revised: dict[str, str] = {}
    retracted: set[str] = set()
    for event in read_jsonl(path(".memory-events.jsonl"), skipped, "events"):
        if event.get("kind") == "revised":
            revised[as_str(event.get("memory_id"))] = as_str(event.get("superseded_by"))
        elif event.get("kind") == "retracted":
            retracted.add(as_str(event.get("memory_id")))
    absorbed = {
        as_str(row.get("memory_id")): as_str(row.get("into")) for row in read_jsonl(path(".memory-absorbed.jsonl"), skipped, "absorbed")
    }
    lineage = Lineage(current, revised, absorbed, frozenset(retracted))
    return KeeperState(settled, waiting, len(pending), min(written) if written else None, journal, has_journal, lineage, not_candidates, tuple(problems))


class Fate(enum.Enum):
    """What became of one queued write."""

    TARGET_AFTER = "settled with a target " + Origin.AFTER.value
    TARGET_BEFORE = "settled with a target " + Origin.BEFORE.value
    TARGET_UNKNOWN = "settled with a target " + Origin.UNKNOWN.value
    WITHOUT_TARGET = "settled without a target"
    WAITING = "still waiting in the admission queue"
    NO_RECORD_OLDER = "no record, written before the oldest receipt of the Keeper"
    NO_RECORD_NEWER = "no record, written after the oldest receipt of the Keeper"
    NO_RECEIPTS = "no record, the Keeper has no dated receipt"


TARGET_FATES = {Origin.AFTER: Fate.TARGET_AFTER, Origin.BEFORE: Fate.TARGET_BEFORE, Origin.UNKNOWN: Fate.TARGET_UNKNOWN}


def fate_of(call: WriteCall, state: KeeperState) -> Fate:
    # A receipt is the authority for consumption; a row may still sit in the queue until it is acknowledged.
    settled = state.settled.get(call.request_id)
    if settled is not None:
        return TARGET_FATES[state.origin_of(settled)] if settled.target else Fate.WITHOUT_TARGET
    if call.request_id in state.waiting:
        return Fate.WAITING
    oldest = state.oldest_receipt()
    if oldest is None:
        return Fate.NO_RECEIPTS
    return Fate.NO_RECORD_OLDER if call.ts < oldest else Fate.NO_RECORD_NEWER


@dataclasses.dataclass(frozen=True)
class Window:
    """The settled candidates written at or after --since. A receipt without a write time is dated by its settlement."""

    counted: dict[str, list[tuple[str, Settled]]]  # Keeper -> (request id, candidate)
    unplaced: int  # no source fact, and its revision has no Librarian stamp or has stamps on both sides of --since
    older: int
    first_written: float | None  # over the counted receipts that hold a source fact
    last_written: float | None


def window_of(states: dict[str, KeeperState], since: float | None) -> Window:
    counted: dict[str, list[tuple[str, Settled]]] = {}
    unplaced = older = 0
    written: list[float] = []
    for keeper, state in states.items():
        for request_id, settled in state.settled.items():
            if settled.first_seen is not None:
                if since is not None and settled.first_seen < since:
                    older += 1
                    continue
                written.append(settled.first_seen)
            elif since is not None:
                # No write time: the settlement cannot be older than the write, so a revision whose last Librarian
                # stamp is before --since was written before it. A revision without any stamp, and one with stamps
                # on both sides of --since (the receipt does not say which pass settled it), cannot be placed. A
                # revision whose stamps all lie at or after --since counts as inside, although the write may have
                # come before --since and the settlement after it.
                stamps = state.journal.revision_times.get(settled.revision)
                if not stamps:
                    unplaced += 1
                    continue
                if stamps[-1] < since:
                    older += 1
                    continue
                if stamps[0] < since:
                    unplaced += 1
                    continue
            counted.setdefault(keeper, []).append((request_id, settled))
    return Window(counted, unplaced, older, min(written) if written else None, max(written) if written else None)


def table_calls(scan: TraceScan, since: float | None) -> None:
    calls = scan.calls
    print(f"write calls: {len(calls)} in {len({call.keeper for call in calls})} Keepers")
    if calls:
        print(f"  first {iso(min(call.ts for call in calls))}, last {iso(max(call.ts for call in calls))}; --since {iso(since) if since is not None else 'not set'}")
    by_kind = collections.Counter(call.kind for call in calls)
    for kind in Kind:
        print(f"  {kind.value}: {by_kind[kind]} ({percent(by_kind[kind], len(calls))})")
        if kind is Kind.RECEIPT_OK:
            for outcome, count in collections.Counter(call.outcome for call in calls if call.kind is kind).most_common():
                print(f"    {outcome or '(no outcome)'}: {count}")
        elif kind is Kind.REJECTED:
            for error_kind, count in collections.Counter(call.error_kind for call in calls if call.kind is kind).most_common():
                print(f"    {error_kind or '(no error_kind)'}: {count}")
    print(f"started calls without a finished record: {scan.started_without_finished}; finished records seen twice: {scan.finished_twice}")


def moment_ago(stamp: float | None, now: float, absent: str) -> str:
    return f"{iso(stamp)} ({now - stamp:.0f} s before the read)" if stamp is not None else absent


def table_queued(fates: list[tuple[WriteCall, Fate]], states: dict[str, KeeperState], now: float) -> None:
    print(f"\nqueued writes ({PENDING_OUTCOME}): {len(fates)}")
    counts = collections.Counter(fate for _, fate in fates)
    for fate in Fate:
        print(f"  {fate.value}: {counts[fate]} ({percent(counts[fate], len(fates))})")
    rows = sum(state.waiting_rows for state in states.values())
    print(f"  rows in the admission queues of the {len(states)} Keepers read, whatever their age and whether or not the trace holds their call: {rows}")
    holding = sorted((name for name, state in states.items() if state.waiting_rows), key=lambda name: (-states[name].waiting_rows, name))
    for keeper in holding:
        state = states[keeper]
        no_commit = "none in the journal" if state.has_journal else "unknown, no journal file"
        print(
            f"    {keeper}: {state.waiting_rows} rows; oldest written {moment_ago(state.oldest_waiting, now, 'unknown')}; "
            f"last Librarian commit {moment_ago(state.last_commit(), now, no_commit)}"
        )


def table_settled(states: dict[str, KeeperState], window: Window, now: float, since: float | None) -> None:
    candidates = [(states[keeper], settled) for keeper, rows in window.counted.items() for _, settled in rows]
    total = len(candidates)
    print(f"\ncandidates the Librarian settled, in the --since window: {total} in {len(window.counted)} Keepers (read at {iso(now)})")
    print(
        "  window: written at or after --since; a receipt without a source fact is dated by its settlement, the Librarian stamps of its revision "
        "(all before --since: older, all at or after it: inside, on both sides: not placed)"
    )
    if window.first_written is not None and window.last_written is not None:
        print(f"  receipts with a source fact were written from {iso(window.first_written)} to {iso(window.last_written)}")
    with_target = [(state, settled) for state, settled in candidates if settled.target]
    origins = collections.Counter(state.origin_of(settled) for state, settled in with_target)
    for origin in Origin:
        print(f"  settled with a target {origin.value}: {origins[origin]} ({percent(origins[origin], total)})")
    print(f"  settled without a target: {total - len(with_target)} ({percent(total - len(with_target), total)})")
    # A target that no commit row adds is counted with the ones stamped before the write: a fact can exist without an adding
    # row (the line after this one counts them among the current facts), so it may have been there before the Keeper wrote.
    already = origins[Origin.BEFORE] + origins[Origin.UNKNOWN]
    print(
        f"  targets that may have existed before the write (stamped before it, added by no row, or without a usable write time): {already} of {len(with_target)} "
        f"with a target ({percent(already, len(with_target))}); the other {origins[Origin.AFTER]} are exact"
    )
    current_facts = sum(len(state.lineage.current) for state in states.values())
    unadded = sum(1 for state in states.values() for memory_id in state.lineage.current if memory_id not in state.journal.first_added)
    print(f"  for comparison, current facts that no committed journal row added: {unadded} of {current_facts} ({percent(unadded, current_facts)})")
    reasons: collections.Counter[Skip] = collections.Counter()
    for state in states.values():
        reasons.update(state.not_candidates)
    print(f"  not counted: {window.unplaced} that cannot be placed in the window, {window.older} written before --since")
    print(f"  receipts that are not a settled candidate (--since does not apply): {sum(reasons.values())}")
    for reason in Skip:
        print(f"    {reason.value}: {reasons[reason]}")
    own = sum(1 for _, settled in with_target if settled.own_sentence)
    print(f"settled with a target: {len(with_target)}")
    print(f"  the target has the memory id of the Keeper's own sentence: {own} ({percent(own, len(with_target))})")
    followed = [(state, follow(settled.target, state.lineage, state.journal.removals)) for state, settled in with_target]
    standings = collections.Counter(result.standing for _, result in followed)
    for standing in Standing:
        print(f"  target now, {standing.value}: {standings[standing]} ({percent(standings[standing], len(with_target))})")
    reached = sum(count for standing, count in standings.items() if standing.reaches_current)
    print(f"the target is a current fact now or the records lead to one: {reached} of {len(with_target)} with a target ({percent(reached, len(with_target))}), {reached} of {total} settled ({percent(reached, total)})")
    ends = [(state, result) for state, result in followed if result.standing.ends_nowhere]
    removals = [state.journal.removals.get(result.last_id) for state, result in ends]
    reasoned = sum(1 for removal in removals if removal is not None and removal.reasoned)
    unreasoned = sum(1 for removal in removals if removal is not None and not removal.reasoned)
    unremoved = sum(1 for removal in removals if removal is None)
    replaced = sum(1 for removal in removals if removal is not None and removal.replaced)
    print(f"targets whose records end without a current fact or a retraction: {len(ends)}")
    print(f"  the id where the records end was removed by a committed row with a written reason: {reasoned} ({percent(reasoned, len(ends))})")
    print(f"  the id where the records end was removed by a committed row with no written reason: {unreasoned} ({percent(unreasoned, len(ends))})")
    print(f"  the id where the records end was removed by no committed row: {unremoved} ({percent(unremoved, len(ends))})")
    print(f"  the removing commit also added a fact: {replaced} of {reasoned + unreasoned}")
    librarian_ends = sum(1 for removal in removals if removal is not None and removal.librarian)
    print(f"  the removing commit was a Librarian pass: {librarian_ends} of {reasoned + unreasoned}")
    # The same two counts over a population of the same kind, to read the shares above against: the ids that no revised,
    # absorbed or retracted record leads out of, that are not current, and whose last removing row is a Librarian pass
    # stamped no earlier than the first write of the window. An end above can fall outside it (a loop of revised
    # records ends on an id that has a revised record), so the line after the comparison counts how many do not.
    lower = window.first_written if window.first_written is not None else since

    def of_the_same_kind(state: KeeperState, memory_id: str, removal: Removal) -> bool:
        return (
            removal.librarian
            and (lower is None or removal.recorded_at >= lower)
            and memory_id not in state.lineage.current
            and memory_id not in state.lineage.revised
            and memory_id not in state.lineage.absorbed
            and memory_id not in state.lineage.retracted
        )

    similar = [
        removal
        for state in states.values()
        for memory_id, removal in state.journal.removals.items()
        if of_the_same_kind(state, memory_id, removal)
    ]
    similar_reasoned = sum(1 for removal in similar if removal.reasoned)
    similar_replaced = sum(1 for removal in similar if removal.replaced)
    print(
        f"  for comparison, {len(similar)} ids that are not current, that no revised, absorbed or retracted record leads out of "
        f"and that a Librarian commit removed since {iso(lower) if lower is not None else 'the start of the journal'}: "
        f"a written reason {similar_reasoned} ({percent(similar_reasoned, len(similar))}), "
        f"also added a fact {similar_replaced} ({percent(similar_replaced, len(similar))})"
    )
    like_ends = sum(
        1
        for state, result in ends
        if (removal := state.journal.removals.get(result.last_id)) is not None and of_the_same_kind(state, result.last_id, removal)
    )
    print(f"  the ends above that are of that kind: {like_ends} of {len(ends)}")
    several = sum(1 for state, settled in with_target if len(state.journal.revision_times.get(settled.revision, ())) > 1)
    print(f"  settled with a target whose revision has more than one Librarian stamp: {several} of {len(with_target)}")
    bounds = [bound for bound in (state.settle_bounds(settled) for state, settled in with_target) if bound is not None]
    print(
        f"seconds from the write to the journal stamp of the settling pass ({len(bounds)} of {len(with_target)} receipts have a source fact "
        "and a Librarian stamp at or after the write; the stamp is when the pass read the queue):"
    )
    for label, index in (("earliest possible", 0), ("latest possible", 1)):
        values = sorted(bound[index] for bound in bounds)
        if values:
            print(f"  {label}: p50 {quantile(values, 0.5):.0f}, p90 {quantile(values, 0.9):.0f}, max {values[-1]:.0f}")


class Cover(enum.Enum):
    """Where a settled candidate stands against the call table and the raw traces of its Keeper."""

    MATCHED = "a source fact and a matching write call"
    BEFORE = "a source fact, no call, written before the oldest raw trace of the Keeper"
    INSIDE = "a source fact, no call, written inside the raw traces"
    NO_TRACE = "a source fact, no call, the Keeper has no raw trace with a turn start"
    PLAIN_MATCHED = "no source fact, a matching write call"
    PLAIN_UNMATCHED = "no source fact, no matching write call"


def coverage_of(scan: TraceScan, window: Window, calls_by_keeper: dict[str, set[str]]) -> dict[str, collections.Counter[Cover]]:
    covers: dict[str, collections.Counter[Cover]] = collections.defaultdict(collections.Counter)
    for keeper, rows in window.counted.items():
        trace = scan.windows.get(keeper)
        for request_id, settled in rows:
            hit = request_id in calls_by_keeper.get(keeper, set())
            if settled.first_seen is None:
                covers[keeper][Cover.PLAIN_MATCHED if hit else Cover.PLAIN_UNMATCHED] += 1
            elif hit:
                covers[keeper][Cover.MATCHED] += 1
            elif trace is None or trace.oldest is None:
                covers[keeper][Cover.NO_TRACE] += 1
            elif settled.first_seen < trace.oldest:
                covers[keeper][Cover.BEFORE] += 1
            else:
                covers[keeper][Cover.INSIDE] += 1
    return dict(covers)


def table_coverage(scan: TraceScan, covers: dict[str, collections.Counter[Cover]]) -> None:
    print("\ncoverage of the call table: raw traces keep only the most recent turns of a Keeper")
    files = [trace.files for trace in scan.windows.values()]
    if files:
        print(f"  raw trace files per Keeper: min {min(files)}, median {statistics.median(files):g}, max {max(files)} ({len(files)} Keepers)")
    else:
        print("  no raw trace files")
    totals: collections.Counter[Cover] = collections.Counter()
    for counts in covers.values():
        totals.update(counts)
    matched = totals[Cover.MATCHED]
    with_fact = matched + totals[Cover.BEFORE] + totals[Cover.INSIDE] + totals[Cover.NO_TRACE]
    plain = totals[Cover.PLAIN_MATCHED] + totals[Cover.PLAIN_UNMATCHED]
    print(f"  candidates with a source fact: {with_fact}")
    print(f"    with a matching write call: {matched} ({percent(matched, with_fact)})")
    print(f"    without one: {with_fact - matched} ({percent(with_fact - matched, with_fact)})")
    print(f"      written before the oldest raw trace of the Keeper: {totals[Cover.BEFORE]}")
    print(f"      written inside the raw traces: {totals[Cover.INSIDE]}")
    print(f"      the Keeper has no raw trace with a turn start: {totals[Cover.NO_TRACE]}")
    print(f"  candidates without a source fact (the write time is not known): {plain}, with a matching write call: {totals[Cover.PLAIN_MATCHED]}")


def table_keepers(
    calls: list[WriteCall],
    fates: list[tuple[WriteCall, Fate]],
    states: dict[str, KeeperState],
    window: Window,
    scan: TraceScan,
    covers: dict[str, collections.Counter[Cover]],
) -> None:
    per_keeper_calls = collections.Counter(call.keeper for call in calls)
    rejected = collections.Counter(call.keeper for call in calls if call.kind is Kind.REJECTED)
    no_result = collections.Counter(call.keeper for call in calls if call.kind is Kind.NOT_RECORDED)
    queued: dict[str, collections.Counter[Fate]] = collections.defaultdict(collections.Counter)
    for call, fate in fates:
        queued[call.keeper][fate] += 1
    print(
        "\nKeeper | write calls | rejected | result not in the trace | queued | target first added at or after the write | "
        "target added before it or unknown | without a target | waiting | no record | settled candidates in the window | "
        "of those, with a source fact, written inside the raw traces, no matching call | raw trace files | oldest raw trace | "
        "files missing or unreadable, notes"
    )
    for keeper in sorted(states, key=lambda name: (-per_keeper_calls[name], name)):
        counts = queued[keeper]
        before = counts[Fate.TARGET_BEFORE] + counts[Fate.TARGET_UNKNOWN]
        no_record = counts[Fate.NO_RECORD_OLDER] + counts[Fate.NO_RECORD_NEWER] + counts[Fate.NO_RECEIPTS]
        inside = covers.get(keeper, collections.Counter())[Cover.INSIDE]
        problems = "; ".join(states[keeper].problems)
        trace = scan.windows.get(keeper)
        trace_files = trace.files if trace else 0
        oldest = iso(trace.oldest) if trace and trace.oldest is not None else "-"
        print(
            f"{keeper} | {per_keeper_calls[keeper]} | {rejected[keeper]} | {no_result[keeper]} | {sum(counts.values())} | "
            f"{counts[Fate.TARGET_AFTER]} | {before} | {counts[Fate.WITHOUT_TARGET]} | {counts[Fate.WAITING]} | {no_record} | "
            f"{len(window.counted.get(keeper, []))} | {inside} | {trace_files} | {oldest} | {problems or '-'}"
        )


def keepers_with(memory_dir: str, suffix: str) -> set[str]:
    """The Keepers that have a file named ``<keeper><suffix>`` in the memory directory."""
    return {os.path.basename(path)[: -len(suffix)] for path in glob.glob(os.path.join(memory_dir, "*" + suffix))}


def parse_utc_date(text: str) -> float:
    return datetime.datetime.combine(datetime.date.fromisoformat(text), datetime.time(), tzinfo=datetime.timezone.utc).timestamp()


def parse_utc_time(text: str) -> float:
    moment = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    return (moment if moment.tzinfo else moment.replace(tzinfo=datetime.timezone.utc)).timestamp()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("keepers_dir", help="the <base-path>/.masc/keepers directory (raw traces)")
    parser.add_argument("--memory-dir", required=True, help="the <base-path>/.masc/config/keepers directory")
    parser.add_argument("--since", help="earliest UTC date to read, YYYY-MM-DD")
    parser.add_argument("--now", help="the read time printed in the settled table, ISO 8601 (UTC when it has no offset); default is the current time")
    parser.add_argument("--only", action="append", default=[], help="read only this Keeper; repeatable")
    parser.add_argument("--exclude", action="append", default=[], help="Keeper name to skip; repeatable")
    args = parser.parse_args(argv)
    for directory in (args.keepers_dir, args.memory_dir):
        if not os.path.isdir(directory):
            print(f"not a directory: {directory}", file=sys.stderr)
            return 2
    try:
        since = parse_utc_date(args.since) if args.since else None
        now = parse_utc_time(args.now) if args.now else time.time()
    except ValueError as error:
        parser.error(str(error))
    # --since is a date from year 1 to 9999, which the calendar prints; --now can leave it through its offset.
    if moment_of(now) is None:
        parser.error("--now is outside the calendar")
    only, excluded = set(args.only), set(args.exclude)

    skipped: Skipped = collections.Counter()
    scan = scan_traces(args.keepers_dir, only, excluded, since, skipped)
    # A Keeper is read when it made a write call or has a receipt, queue, journal or current-facts file.
    named: set[str] = set()
    for suffix in KEEPER_FILE_SUFFIXES:
        named |= keepers_with(args.memory_dir, suffix)
    keepers = {call.keeper for call in scan.calls} | {keeper for keeper in named if keeper not in excluded and (not only or keeper in only)}
    states = {keeper: load_state(args.memory_dir, keeper, skipped) for keeper in sorted(keepers)}
    queued = [call for call in scan.calls if call.kind is Kind.RECEIPT_OK and call.outcome == PENDING_OUTCOME]
    fates = [(call, fate_of(call, states[call.keeper])) for call in queued]
    calls_by_keeper: dict[str, set[str]] = collections.defaultdict(set)
    for call in queued:
        calls_by_keeper[call.keeper].add(call.request_id)
    window = window_of(states, since)
    covers = coverage_of(scan, window, calls_by_keeper)

    table_calls(scan, since)
    table_queued(fates, states, now)
    table_settled(states, window, now, since)
    table_coverage(scan, covers)
    table_keepers(scan.calls, fates, states, window, scan, covers)
    print("\nskipped input: " + ("; ".join(f"{label} {count}" for label, count in sorted(skipped.items())) or "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
