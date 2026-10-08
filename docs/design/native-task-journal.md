# Native task observations: private producer to receiver journal

This source unit adds disk persistence for observations that already crossed the
runtime's task admission and Keeper's private task/input binding. It captures the
original input, native call and dispatch identity instead of inferring ownership
from the current root stream. It does not add public events, an HTTP reader, task
UI, or a long-lived provider receiver.

## Authority and data

`Keeper_native_task_journal.prepare` is the only constructor of the abstract
publication accepted by `append`. It requires a private
`Keeper_claude_task_binding.bound` plus the dispatch-captured
`Runtime_native_tasks.attempt`. Decoded public task DTOs and journal rows cannot
mint that capability. The collector supplies its authenticated workspace,
Keeper and typed source; neither a provider frame nor a member request chooses
that source. Direct chat uses `Owner_operation.operation_id`; autonomous turns
use their actual `Ids.Turn_ref.t`.

The converter preserves the original input ticket's receiver generation,
session and client UUID, native envelope UUID/ordinal/call, task/run/event UUIDs,
frozen routing attempt, optional flags, signed provider clocks and terminal
boundary. `Runtime_native_tasks.make` validates the complete transport value,
including invocation/native session equality. The existing `redact` function
changes only supplied `subagent_type` and `last_tool_name` leaves. Raw prompt,
description, summary and output path are absent from the admitted vocabulary.
No current stream scope, tool block index, latest input or root phase participates.

A receiver is the canonical Keeper registry base path plus exact Keeper,
receiver generation and session. The file is under
`<base>/.masc/native-task-journals/v1/<hex keeper>/<hex generation>/<hex session>.jsonl`.
Whole-byte hexadecimal is injective, with no ID normalization or lossy sanitizing.
Filesystem component/path limits can still produce explicit persistence errors;
there is no application count, age or length cutoff. Every closed, versioned row
stores the full expected scope, one positive JSON-safe sequence, a finite local
observation timestamp and the canonical task DTO. Ordering authority is the
commit sequence; wall clocks are never compared to choose ownership or order.

## Commit and failure contract

Existing `Keeper_fs_durable_directory.ensure` prepares and syncs the directory
chain below the authenticated workspace. Append and recovery use only
`Fs_compat.recover_and_update_private_jsonl_durable_locked_result`; readers use
its fd-lock family's `read_private_jsonl_rows_locked_result`. There is no sibling
lock/CAS retry or rename/compaction path.

Inside the one locked, pure decision, all complete rows are decoded and checked
for exact scope, DTO scope consistency, contiguous sequence and unique UUIDs.
An exact observation replay returns the original receipt and timestamp. A
same-UUID disagreement returns `Conflicting_uuid` without appending. A complete
malformed row or foreign scope blocks both replay acknowledgement and new
writes. Only bytes after the last newline are uncommitted and recoverable;
readers exclude that tail and append recovery truncates/fsyncs it before deciding.

Append/rollback, directory preparation, read and other I/O failures remain typed.
A descriptor-close warning accompanies the primary result: a durable append
with cleanup failure remains `Ok (Appended record)`, so it cannot accidentally be
retried as an uncommitted event. `observe` retains failures/warnings in collector
health; later success does not erase them. There is no automatic retry policy.
Ordinary cleanup behavior is inherited from the existing Fs transaction, not a
new task-specific exception/finalizer implementation.

The direct callback reports task persistence issues separately and still returns
`Ok ()` to its tool-mapping match. Autonomous callbacks persist even after their
root event bus is closed. Neither path publishes task metadata into root events,
flushes model text/Thinking, reopens native progress, records a native execution
receipt, nor changes native effects, model usage or root outcome. Cancellation
continues to propagate rather than being swallowed as an ordinary disk error.

## Cost and unfinished boundaries

Each append validates the full receiver history under the file lock, with time
and memory proportional to that history. This deliberate first implementation
has no arbitrary cap, caching authority, compaction or retention policy. Files
and directory chains use existing private-file infrastructure; concurrent
external replacement/renaming of journal files is not a supported writer.

The current runtime still stops receiving at its first root result. Retaining a
journal capability after root closure does not retain a provider process or
observe later provider events. A future session pump needs its own captured
receiver sink, exact input attribution and cancellation/resume policy. The next
transport/UI unit also needs an authenticated task read/cursor contract, strict
OCaml/TS event consumers, separate background task projection and measured
settled-answer/background-task/new-input PTY frames. None exists in this patch.

## Authored checks and evidence limits

Four cases in `test_keeper_claude_code_runtime` obtain private values through
actual fake-CLI runtime/adapter/driver callbacks with scoped Native_full/Yolo
admission; no JSON-to-private-owner fixture shortcut is used:

- Commit/replay/source conflict, canonical root alias, different roots/Keeper
  partitions, copied foreign-scope corruption, metadata redaction, signed
  duration and excluded raw fields.
- Concurrent duplicate writers, torn-tail recovery versus complete corruption,
  contiguous commit sequence and explicit filesystem failure health.
- Persistence failure inside the actual driver callback preserves the original
  final root answer and all three typed failure results.
- Actual autonomous observation entrypoint after root closure writes all task
  rows with its turn reference while leaving the root journal bytes/current
  turn identity unchanged.

The direct HTTP route's full execution path is source-reviewed here; these new
cases do not execute that whole route. Cleanup-warning forwarding follows the
existing Fs outcome contract and its existing fault-injection tests; no new
cleanup-fault execution is claimed. New cases are authored, **not executed**.
Only OCaml parsing and diff whitespace checks are run locally. No build, type
check, provider call, PTY, CI, screenshot, merge or deployed behavior is claimed.
