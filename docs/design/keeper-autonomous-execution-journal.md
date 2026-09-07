# Autonomous execution journal and recovery boundary

The owner journal is the semantic authority for an autonomous invocation. Queue
entries are delivery projections; checkpoint files are payload snapshots. Neither
queue emptiness nor checkpoint presence proves that an invocation is new or done.

This change implements the journal domain, storage, and restart classification.
It does **not** yet connect autonomous admission, automatic rechecks, provider
session ownership, or effect reconciliation to the heartbeat runner. Those are
required before claiming that the runtime repetition problem is fixed.

## Identity and atomic admission

A producer supplies an autonomous UUID. One SQLite transaction writes that UUID,
an initialized empty repetition frame, the exact source memberships, and the
Preparing phase. Retrying the same identity returns the recorded invocation;
it never clears observations or invents a replacement scope.

Operation IDs and immutable repetition snapshots live below both the journal and
runtime adapters. The Context adapter owns restoration and tool-call conversion;
it is not a second implementation of the snapshot codec.

The existing Owner database gains a validated v1-to-v2 migration. Existing chat
rows, terminal immutability, and sequence are preserved. Read-only inspection can
still validate v1 without migrating an ownerless store. Unknown schemas and
corrupt records are retained and rejected before changing journaling settings.

The database uses DELETE journaling and `synchronous=EXTRA`. SQLite documents that
EXTRA also synchronizes the directory after removing a rollback journal; FULL in
rollback mode can otherwise lose the last committed transaction after power
loss. This is the selected SQLite durability contract, not a measured hardware
power-loss test. See [SQLite synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous).

## Work must not get trapped by recovery

| State | Holds the running slot? | Next evidence or action |
| --- | --- | --- |
| Preparing | No | Confirm exact queue binding, or recheck a failed projection |
| Ready | No | Enter execution after normal dispatch validation |
| Running | Yes | Record observations, suspend at an exact checkpoint, or settle |
| Suspended | No | Resume the same execution using its exact checkpoint reference |
| Recovering | No | Recheck according to the preserved origin |
| Settled | No | Immutable terminal fact; a subsequent invocation gets its own frame |

Several waiting operations can coexist. Only Running is unique. A waiting
operation reserves its own exact source incarnations, including verified newer
queue projections, rather than blocking unrelated work. A duplicate diagnostic
is a no-op. Old CAS writers cannot overwrite newer evidence.

Recovery preserves one of these origins:

- Unconfirmed sources: revalidate the bound source projection and return to Preparing.
- Confirmed but undispatched: revalidate the projection and return to Ready.
- Checkpointed: revalidate the exact recorded checkpoint and resume the same scope.
- Interrupted execution: retain uncertainty until actual session/effect evidence exists.

Reprioritization can change a queue entry's revision and snapshot hash. A typed
projection relates the initial member to its observed member and bound scope;
it does not substitute a timestamp or post-ID heuristic for execution identity.

A checkpointed invocation already owns its accepted input. Resuming it must not
require queue rows that a successful checkpoint ACK legitimately removed.
Cancellation must settle the operation authority before removing its delivery
projection in the later runtime integration.

Startup moves interrupted Running records to Recovering without clearing their
frames. This frees the execution slot for unrelated work. An empty frame is not
proof that a partially transmitted request or tool had no effect. No arbitrary
hash or checkpoint-presence escape hatch authorizes replay of Interrupted execution.

## Evidence and remaining integration

The 20 SQLite tests cover atomic and uncertain commits, exact CAS, independent
work during waits, rechecks across queue generations, same-scope checkpoint
resumption after another operation completes, immutable terminal records,
validated migration, read-only old-schema inspection, and corrupt-evidence
retention. They exercise the journal API, not a full provider turn.

The heartbeat integration still must:

1. Choose runnable work fairly instead of repeatedly selecting the first waiting row.
2. Persist journal admission before queue projection and model dispatch.
3. Validate current bound sources and checkpoint bytes before the corresponding recheck.
4. Keep observations durable before another provider request; account for in-flight effects.
5. Associate official sessions and child/HITL requests with explicit execution identity.
6. Project checkpoint and terminal ACKs from journal authority with restart-safe retries.
7. Supply an adapter-owned interrupted-execution witness from real session/effect evidence.

No fixed turn budget, retry-count limit, or waiting-operation-wide lock is added.
Scan cost over terminal journal history and full scheduler recovery latency have
not been measured. An authoritative database integrity failure remains an
explicit storage failure; it is never replaced with a fabricated empty journal.
