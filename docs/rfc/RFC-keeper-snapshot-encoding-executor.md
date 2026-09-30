# Keeper snapshot encoding must not wait behind owner locks

Status: proposed implementation

Issue: https://github.com/jeong-sik/masc/issues/40077

## Problem

A durable Keeper event-queue writer holds its owner lock while serializing the
next immutable state. It previously submitted that CPU work to `Domain_pool`.
Recovery runs in `Executor_pool_ref`, whose workers acquire the same owner
locks. Both references point at the same executor. With its only worker
waiting for the writer's lock, neither side can progress. Additional workers
only change how many lock waiters are needed to exhaust the executor.

The existing worker-context marker handles a job submitting nested work to
its own pool. It does not remove this cycle between a writer on the calling
fiber and a recovery job on another domain.

## Decision

Give snapshot encoding one independent worker, owned by the server switch.
`Keeper_event_queue_snapshot_codec` accepts immutable queue state.
It does not expose arbitrary job submission, an executor handle, or an
owner-lock capability. State-to-JSON construction, UTF-8 sanitization and
pretty-printing are its complete work surface. No shared-executor submission
or owner-lock acquisition occurs in that work.

The dependency graph becomes:

```text
shared recovery worker -> owner lock -> snapshot encoding worker
```

The encoding worker has no edge back to the shared executor or owner lock.
One worker is the minimum independent CPU resource required for this design;
it is not a Keeper admission, timeout, token or turn limit. Increasing its
capacity is a separate throughput decision, not part of the correctness fix.
No additional environment variable or runtime setting is introduced.

The server installs the codec before initial owner preparation, which can
checkpoint state before ordinary Keeper lanes are active. Strict same-state
durability confirmation also passes state to the codec; it does not construct
JSON on the caller before submission.
An unprotected daemon observes cancellation of the owning switch and resolves
a shared stop promise with that cancellation exception. Each encoding races
submission against this promise in a local child scope. This matters because
the durable owner lock masks ordinary caller cancellation: workers may already
have stopped while a protected writer has not yet submitted. Waiting for the
switch's release hook would deadlock, since release waits for that writer.
The stop race cancels a blocked submission and unwinds its owner lock without
waiting for release. It also works when the caller is on another domain.

Switch release clears its published reference only if it still names that
installation. Encoding before installation or from raw non-Eio contexts
runs synchronously and never enters the shared executor. An encoding failure
or cancellation propagates once; the work is not replayed as a fallback.

Owner-lock boundaries, shutdown intake fences, atomic file replacement,
directory synchronization, WAL compaction and transition receipts retain
their existing order. The durable format is unchanged.

## Alternatives

- Running serialization on the main domain avoids the cycle but restores
  large CPU stalls during queue commits.
- Smaller job weights or more shared workers leave the cycle possible when
  all available capacity holds lock waiters.
- Moving recovery lock acquisition outside all pool work would require
  separating transfer target, intake and reaction-ledger transactions. That
  is a broader change to recovery's strict offload contract.
- Encoding after releasing the owner lock would require a new validated
  publication protocol; otherwise concurrent mutations can publish stale
  state. This change keeps the current durable transaction intact.

## Verification

The regression scenario uses real persistence calls and one shared worker.
An `update_checked_result` callback holds the owner lock, then allows a shared
worker to start `load_state_result` for the same Keeper. The writer proceeds
to snapshot encoding while that worker waits. Both calls must complete and
the subsequent durable read must retain the input. Barriers determine the
interleaving; a process watchdog only bounds failure of the test itself.

Also verify cancellation while the writer holds the lock but has not yet
encoded terminates the write without publishing uncommitted state, encoding
preserves the existing sanitized JSON bytes, and encoding after switch release
does not submit to a stopped executor. The exact-installation cleanup CAS is
reviewed separately. Source review and any
executed tests are reported separately. The issue's reduced model alone does
not establish a production deadlock or a repaired live server.

## Discussion

MASC Board: `p-9a56b92b9964ecc74df2a2d2e488450b`.
An independent Keeper review is requested for the lock graph, resource
lifetime, cancellation and the production-path regression scenario.
