#!/usr/bin/env python3
# pyright: strict
"""Measure whether what Keepers write with ``keeper_memory_write`` reaches the current Memory.

The tool answers with a receipt. ``persisted_pending_admission`` means the claim
waits in the Keeper's admission queue until the Librarian judges it, and the
receipt does not say whether the claim became a current fact. This script
follows each write after its receipt (RFC-keeper-recall-reaches-the-turn,
section 5, layer 0 item 4). It prints two tables of counts and one table per
Keeper. No claim text is printed.

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
   ``admission_recall_binding`` settled with a target fact, and one with only
   ``explicit_candidate_id`` settled without one. The librarian runtime builds
   a binding for ``Incorporated`` and ``Already_represented`` and none for
   ``Not_durable`` (lib/keeper/keeper_librarian_runtime.ml:920-933); a
   ``Deferred`` candidate is not settled
   (lib/keeper/keeper_memory_admission_judgment.ml:104). The journal row of the
   receipt's ``snapshot_revision`` gives the time of the commit and the facts it
   added: a target the commit added is a claim the Librarian wrote for the
   candidate, and a target it did not add already existed. Then: whether the
   target has the same memory id as the Keeper's own sentence, whether it is a
   current fact now, and how long the candidate took from the write to the
   commit.

A memory id is the SHA-256 of a claim, so a sentence the Librarian reworded has
another id. Receipts the Librarian wrote for its own reads (``range_id``,
``official_range_id``) are not candidates and are counted apart.

Read-only. Both directories are arguments; nothing is assumed about where
``<base-path>/.masc`` lives. Raw traces rotate, so ``--since`` only bounds the
earliest record read.

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
import sys
import time
from collections.abc import Iterator

WRITE_TOOL = "keeper_memory_write"
RECORD_STARTED = ("tool_execution_started", "native_tool_started")
RECORD_FINISHED = ("tool_execution_finished", "native_tool_finished")
NATIVE_FINISHED = "native_tool_finished"
PENDING_OUTCOME = "persisted_pending_admission"
RECEIPT_COMMITTED = "committed"
MEMORY_ID_PREFIX = "sha256:"

# What json.loads returns. Narrowing it with isinstance keeps every element type known.
type Json = dict[str, Json] | list[Json] | str | int | float | bool | None


def read_jsonl(path: str, needle: str = "") -> Iterator[dict[str, Json]]:
    """Rows of a JSON-lines file; a line without ``needle`` is skipped before it is parsed."""
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with handle:
        for line in handle:
            if needle and needle not in line:
                continue
            try:
                row: Json = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict):
                yield row


def as_float(value: Json) -> float:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0.0


def as_str(value: Json) -> str:
    return value if isinstance(value, str) else ""


def as_dict(value: Json) -> dict[str, Json]:
    return value if isinstance(value, dict) else {}


def as_list(value: Json) -> list[Json]:
    return value if isinstance(value, list) else []


def memory_id_of(claim: str) -> str:
    # Keeper_memory_os_types.memory_id: the SHA-256 of the claim bytes.
    return MEMORY_ID_PREFIX + hashlib.sha256(claim.encode("utf-8")).hexdigest()


def quantile(sorted_values: list[float], fraction: float) -> float:
    return sorted_values[int(fraction * (len(sorted_values) - 1))] if sorted_values else 0.0


def percent(part: int, whole: int) -> str:
    return f"{100 * part / whole:.1f}%" if whole else "-"


def iso(epoch: float) -> str:
    return datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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


def call_of(keeper: str, record: dict[str, Json]) -> WriteCall:
    ts = as_float(record.get("ts"))
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
    if not isinstance(identity, str):
        native = record.get("native_tool_identity")
        if native is None:
            return None
        identity = json.dumps(native, sort_keys=True)
    return (keeper, as_str(record.get("worker_run_id")), identity)


@dataclasses.dataclass(frozen=True)
class TraceScan:
    calls: list[WriteCall]
    started_without_finished: int
    finished_twice: int


def scan_traces(keepers_dir: str, only: set[str], excluded: set[str], since: float) -> TraceScan:
    calls: list[WriteCall] = []
    started: set[tuple[str, str, str]] = set()
    finished: set[tuple[str, str, str]] = set()
    finished_twice = 0
    for path in sorted(glob.glob(os.path.join(keepers_dir, "*", "raw-traces", "*.jsonl"))):
        keeper = path.split(os.sep)[-3]
        if keeper in excluded or (only and keeper not in only):
            continue
        for record in read_jsonl(path, WRITE_TOOL):
            if not as_str(record.get("tool_name")).endswith(WRITE_TOOL) or as_float(record.get("ts")) < since:
                continue
            record_type = record.get("record_type")
            key = call_key(keeper, record)
            if record_type in RECORD_STARTED and key is not None:
                started.add(key)
            elif record_type in RECORD_FINISHED:
                if key is not None:
                    if key in finished:
                        finished_twice += 1
                        continue
                    finished.add(key)
                calls.append(call_of(keeper, record))
    return TraceScan(calls, len(started - finished), finished_twice)


@dataclasses.dataclass(frozen=True)
class Settled:
    """A candidate the Librarian settled, from one committed receipt."""

    revision: int  # the Memory revision of the commit that settled it
    target: str  # the memory id it was settled with; empty when it was settled without one
    first_seen: float  # when the Keeper wrote it; 0.0 when the receipt holds no source fact
    own_sentence: bool  # the target has the memory id of the Keeper's own claim


@dataclasses.dataclass(frozen=True)
class Commit:
    recorded_at: float
    added: frozenset[str]  # memory ids of the facts the commit added


class Standing(enum.Enum):
    CURRENT = "a current fact"
    REVISED = "left by a revised event"
    RETRACTED = "retracted"
    ABSORBED = "absorbed into another fact"
    GONE = "gone, no revised, retracted or absorbed record"


@dataclasses.dataclass(frozen=True)
class Standings:
    current: frozenset[str]
    revised: frozenset[str]
    retracted: frozenset[str]
    absorbed: frozenset[str]

    def of(self, memory_id: str) -> Standing:
        if memory_id in self.current:
            return Standing.CURRENT
        if memory_id in self.revised:
            return Standing.REVISED
        if memory_id in self.retracted:
            return Standing.RETRACTED
        if memory_id in self.absorbed:
            return Standing.ABSORBED
        return Standing.GONE


@dataclasses.dataclass(frozen=True)
class KeeperState:
    settled: dict[str, Settled]  # request id -> settlement
    waiting: frozenset[str]  # request ids still in the admission queue
    commits: dict[int, Commit]  # Memory revision -> committed journal row
    standings: Standings
    not_candidates: int  # receipts that are not a committed candidate: range reads, other states, repeated ids
    problems: tuple[str, ...]  # files that were missing or unreadable

    def commit_of(self, settled: Settled) -> Commit | None:
        return self.commits.get(settled.revision)

    def oldest_receipt(self) -> float | None:
        times = [commit.recorded_at for commit in map(self.commit_of, self.settled.values()) if commit is not None]
        return min(times) if times else None


def load_json(path: str) -> tuple[Json, str]:
    """The parsed file and "", or None and what was wrong with it."""
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle), ""
    except FileNotFoundError:
        return None, f"missing {os.path.basename(path)}"
    except (OSError, ValueError):
        return None, f"unreadable {os.path.basename(path)}"


def settlement_of(receipt: dict[str, Json]) -> tuple[str, Settled] | None:
    revision = receipt.get("snapshot_revision")
    if receipt.get("state") != RECEIPT_COMMITTED or not isinstance(revision, int):
        return None
    binding = as_dict(receipt.get("admission_recall_binding"))
    if binding:
        request_id = as_str(as_dict(binding.get("candidate_id")).get("request_id"))
        target = as_str(binding.get("target_memory_id"))
        source = as_dict(binding.get("source_fact"))
        own = memory_id_of(as_str(source.get("claim"))) == target
        return (request_id, Settled(revision, target, as_float(source.get("first_seen")), own)) if request_id and target else None
    request_id = as_str(as_dict(receipt.get("explicit_candidate_id")).get("request_id"))
    return (request_id, Settled(revision, "", 0.0, False)) if request_id else None


def load_state(memory_dir: str, keeper: str) -> KeeperState:
    def path(suffix: str) -> str:
        return os.path.join(memory_dir, f"{keeper}{suffix}")

    problems: list[str] = []
    settled: dict[str, Settled] = {}
    not_candidates = 0
    receipts, problem = load_json(path(".librarian-range-commit.json"))
    if problem:
        problems.append(problem)
    for receipt in as_list(as_dict(receipts).get("receipts")):
        found = settlement_of(as_dict(receipt))
        if found is None or found[0] in settled:
            not_candidates += 1
        else:
            settled[found[0]] = found[1]

    queue, problem = load_json(path(".memory-admission.json"))
    if problem:
        problems.append(problem)
    waiting = frozenset(as_str(as_dict(row).get("request_id")) for row in as_list(as_dict(queue).get("pending")))

    commits: dict[int, Commit] = {}
    for row in read_jsonl(path(".memory-journal.jsonl")):
        revision = row.get("revision")
        if row.get("outcome") != RECEIPT_COMMITTED or not isinstance(revision, int):
            continue
        added = frozenset(memory_id_of(as_str(as_dict(fact).get("claim"))) for fact in as_list(as_dict(row.get("change")).get("added")))
        commits[revision] = Commit(as_float(row.get("recorded_at")), added)

    snapshot, problem = load_json(path(".memory-current.json"))
    if problem:
        problems.append(problem)
    current = frozenset(memory_id_of(as_str(as_dict(fact).get("claim"))) for fact in as_list(as_dict(snapshot).get("facts")))
    events = list(read_jsonl(path(".memory-events.jsonl")))
    standings = Standings(
        current,
        frozenset(as_str(row.get("memory_id")) for row in events if row.get("kind") == "revised"),
        frozenset(as_str(row.get("memory_id")) for row in events if row.get("kind") == "retracted"),
        frozenset(as_str(row.get("memory_id")) for row in read_jsonl(path(".memory-absorbed.jsonl"))),
    )
    return KeeperState(settled, waiting, commits, standings, not_candidates, tuple(problems))


class Fate(enum.Enum):
    """What became of one queued write."""

    ADDED = "settled with a target the commit added"
    EXISTING = "settled with a target that already existed"
    UNDATED = "settled with a target, its commit row is not in the journal"
    WITHOUT_TARGET = "settled without a target"
    WAITING = "still waiting in the admission queue"
    NO_RECORD_OLDER = "no record, written before the oldest receipt of the Keeper"
    NO_RECORD_NEWER = "no record, written after the oldest receipt of the Keeper"
    NO_RECEIPTS = "no record, the Keeper has no receipt at all"


def fate_of(call: WriteCall, state: KeeperState) -> Fate:
    # A receipt is the authority for consumption; a row may still sit in the queue until it is acknowledged.
    settled = state.settled.get(call.request_id)
    if settled is not None:
        if not settled.target:
            return Fate.WITHOUT_TARGET
        commit = state.commit_of(settled)
        if commit is None:
            return Fate.UNDATED
        return Fate.ADDED if settled.target in commit.added else Fate.EXISTING
    if call.request_id in state.waiting:
        return Fate.WAITING
    oldest = state.oldest_receipt()
    if oldest is None:
        return Fate.NO_RECEIPTS
    return Fate.NO_RECORD_OLDER if call.ts < oldest else Fate.NO_RECORD_NEWER


def table_calls(scan: TraceScan, since: float) -> None:
    calls = scan.calls
    print(f"write calls: {len(calls)} in {len({call.keeper for call in calls})} Keepers")
    if calls:
        print(f"  first {iso(min(call.ts for call in calls))}, last {iso(max(call.ts for call in calls))}; --since {iso(since) if since else 'not set'}")
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


def table_queued(fates: list[tuple[WriteCall, Fate]]) -> None:
    print(f"\nqueued writes ({PENDING_OUTCOME}): {len(fates)}")
    counts = collections.Counter(fate for _, fate in fates)
    for fate in Fate:
        print(f"  {fate.value}: {counts[fate]} ({percent(counts[fate], len(fates))})")


def table_settled(states: dict[str, KeeperState], since: float, now: float) -> None:
    """Every candidate the Librarian settled with a dated commit at or after ``since``."""
    classes: collections.Counter[str] = collections.Counter()
    standing: collections.Counter[Standing] = collections.Counter()
    seconds: list[float] = []
    undated = not_candidates = own = 0
    for state in states.values():
        not_candidates += state.not_candidates
        for settled in state.settled.values():
            commit = state.commit_of(settled)
            if commit is None:
                undated += 1
                continue
            if commit.recorded_at < since:
                continue
            if not settled.target:
                classes["settled without a target"] += 1
                continue
            classes["settled with a target the commit added" if settled.target in commit.added else "settled with a target that already existed"] += 1
            own += int(settled.own_sentence)
            standing[state.standings.of(settled.target)] += 1
            if settled.first_seen:
                seconds.append(commit.recorded_at - settled.first_seen)
    total = sum(classes.values())
    with_target = total - classes["settled without a target"]
    print(f"\ncandidates the Librarian settled, commit at or after --since: {total} in {len(states)} Keepers (read at {iso(now)})")
    for label, count in sorted(classes.items()):
        print(f"  {label}: {count} ({percent(count, total)})")
    print(f"  not counted: {undated} settled with a target whose commit row is not in the journal, {not_candidates} receipts that are not a committed candidate")
    print(f"settled with a target: {with_target}")
    print(f"  the target has the memory id of the Keeper's own sentence: {own} ({percent(own, with_target)})")
    for item in Standing:
        print(f"  target now, {item.value}: {standing[item]} ({percent(standing[item], with_target)})")
    print(f"settled and the target is a current fact now: {standing[Standing.CURRENT]} of {total} ({percent(standing[Standing.CURRENT], total)})")
    seconds.sort()
    if seconds:
        print(
            f"seconds from the write to the commit ({len(seconds)} receipts with a source fact): "
            f"p50 {quantile(seconds, 0.5):.0f}, p90 {quantile(seconds, 0.9):.0f}, max {seconds[-1]:.0f}"
        )


def table_keepers(calls: list[WriteCall], fates: list[tuple[WriteCall, Fate]], states: dict[str, KeeperState]) -> None:
    per_keeper_calls = collections.Counter(call.keeper for call in calls)
    rejected = collections.Counter(call.keeper for call in calls if call.kind is Kind.REJECTED)
    queued: dict[str, collections.Counter[Fate]] = collections.defaultdict(collections.Counter)
    for call, fate in fates:
        queued[call.keeper][fate] += 1
    print("\nKeeper | write calls | rejected | queued | with a target | without a target | waiting | no record | files missing or unreadable")
    for keeper, count in per_keeper_calls.most_common():
        fate_counts = queued[keeper]
        with_target = fate_counts[Fate.ADDED] + fate_counts[Fate.EXISTING] + fate_counts[Fate.UNDATED]
        no_record = fate_counts[Fate.NO_RECORD_OLDER] + fate_counts[Fate.NO_RECORD_NEWER] + fate_counts[Fate.NO_RECEIPTS]
        problems = "; ".join(states[keeper].problems) if keeper in states else ""
        print(
            f"{keeper} | {count} | {rejected[keeper]} | {sum(fate_counts.values())} | {with_target} | "
            f"{fate_counts[Fate.WITHOUT_TARGET]} | {fate_counts[Fate.WAITING]} | {no_record} | {problems or '-'}"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("keepers_dir", help="the <base-path>/.masc/keepers directory (raw traces)")
    parser.add_argument("--memory-dir", required=True, help="the <base-path>/.masc/config/keepers directory")
    parser.add_argument("--since", help="earliest UTC date to read, YYYY-MM-DD")
    parser.add_argument("--now", help="UTC time printed as the read time, ISO 8601; default is the current time")
    parser.add_argument("--only", action="append", default=[], help="read only this Keeper; repeatable")
    parser.add_argument("--exclude", action="append", default=[], help="Keeper name to skip; repeatable")
    args = parser.parse_args(argv)
    for directory in (args.keepers_dir, args.memory_dir):
        if not os.path.isdir(directory):
            print(f"not a directory: {directory}", file=sys.stderr)
            return 2
    since = 0.0
    if args.since:
        since = datetime.datetime.fromisoformat(args.since).replace(tzinfo=datetime.timezone.utc).timestamp()
    now = time.time()
    if args.now:
        now = datetime.datetime.fromisoformat(args.now.replace("Z", "+00:00")).timestamp()
    only, excluded = set(args.only), set(args.exclude)

    scan = scan_traces(args.keepers_dir, only, excluded, since)
    receipt_keepers = {
        os.path.basename(path).split(".librarian-range-commit")[0]
        for path in glob.glob(os.path.join(args.memory_dir, "*.librarian-range-commit.json"))
    }
    keepers = {call.keeper for call in scan.calls} | {keeper for keeper in receipt_keepers if keeper not in excluded and (not only or keeper in only)}
    states = {keeper: load_state(args.memory_dir, keeper) for keeper in sorted(keepers)}
    queued = [call for call in scan.calls if call.kind is Kind.RECEIPT_OK and call.outcome == PENDING_OUTCOME]
    fates = [(call, fate_of(call, states[call.keeper])) for call in queued]

    table_calls(scan, since)
    table_queued(fates)
    table_settled(states, since, now)
    table_keepers(scan.calls, fates, states)
    return 0


if __name__ == "__main__":
    sys.exit(main())
