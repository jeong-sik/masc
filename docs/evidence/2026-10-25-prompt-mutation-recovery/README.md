# Prompt mutation recovery

Issue: #25891, specifically the absorbed #24025 coordination-lock failure.
Source baseline: main `3cce9a517b25863c00b48cfb3dd79b994ebc1044`.

The override mutation mutex uses Eio_guard.with_mutex, which delegates to
Eio.Mutex.use_rw with protect:true once Eio is enabled. A callback exception
therefore poisons coordination and prevents later overrides, clears or restores.
Restore also invokes its failure observer while holding that mutex: a callback
that persists a repair reenters the same lock and cannot complete.

The repair captures the callback outcome and original exception/backtrace inside
the coordination guard and rethrows only after normal unlock. Acquisition stays
cancellable, and the acquired transaction retains its cancellation protection.
The separate state mutex retains its consistency policy. This is not rollback
of a callback's effects. Restore commits the candidate and quarantine, captures
default-moved diagnostic facts, unlocks, and then invokes observers and logs.

The focused fixture enables the real Eio guard and defines four scenarios:

- A malformed persisted override commits fallback even when its observer raises;
  the original exception propagates, and subsequent persisted set/reload/clear
  operations complete and survive rereading the file.
- A restore observer reads committed fallback and persists a repair through the
  public API; that repair stays live and survives reload.
- Callback exceptions and explicit cancellation retain their original identity
  and throwing frames, and the coordination lock remains usable.
- A waiter cancelled while another transaction owns the lock never enters, and
  a later transaction can enter after the owner releases it.

Synchronization uses promises and the actual mutex; no sleeps or latency gates.
OCaml parsing and whitespace checks passed locally. No local Dune build,
typecheck or test execution was performed; executed behavior remains unverified
until the focused run succeeds. Independent source review caught missing direct
Eio/Unix test dependencies, which were added before publication.

This does not complete #25891. Approval queue writes still share a global
Cross_context_mutex; cross-owner progress under slow durable I/O needs separate
evidence and design. Filesystem stat/absence classification and remaining state
mutex I/O are separate scope. No installed runtime or live Keeper proof is claimed.
