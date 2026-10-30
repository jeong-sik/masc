# Event-queue cancellation and fresh-process recovery

Relates to #25860 and its consolidated #26014 scope. Base:
`f44c6660d3a3fb400110956745a6a5375e04d446`.

The current durable owner lock permits cancellation while acquiring the lock,
then protects the whole transaction. A committed result returns before pending
parent cancellation surfaces at the caller's next cancellation point. No lease
model or previous cancellation contract is restored.

Two call-scoped test boundaries pause after snapshot encoding/before actual
atomic publication and after new transition WAL encoding/before the real
append. They cannot supply state, encoded bytes, a writer or a durability
outcome. The existing writers and durability flags are unchanged; normal callers
use a no-op boundary. In particular raw ACK remains on its existing non-strict
snapshot writer. This is not a new fsync policy.

Three controls are added:

1. Cancel the parent while an ordinary ACK is paused inside its durable lock.
   Release publication, require the committed result and pending projection,
   then require the original cancellation at the caller's next check. A fresh
   exec of the test binary must retain only the unrelated source and exactly
   the new revision, with no invented outbox.
2. Cancel the parent at the source-terminal ACK's WAL boundary. Require the
   commit result before cancellation, then exec a fresh reader. It must replay
   the committed WAL against the prior snapshot and retain the exact transition
   identity, full source/incarnation/operation receipt and unprojected outbox.
   A second fresh process runs the real reaction-ledger projector, verifies ACK
   evidence and retires the outbox. A third projection in another fresh process
   cannot append another reaction or requeue the completed source.
3. Hold the owner lock through an existing read boundary and cancel a waiting
   ACK before admission. Its write boundary must never run. A fresh process
   must see both original sources and the unchanged revision.

The parent asserts each reader's actual spawned PID and that it differs from
its own. Cache reset only prepares the lock-holder read barrier, and is not
used as a substitute for restart evidence. These are normal separate-process
reads, not abrupt crash, host restart, power-loss or storage-failure proofs.
Cancellation is explicit; fixture timeouts only detect a stuck boundary.

Source parsing and whitespace checks passed. Selected execution and independent
source reviews are pending at record creation. No local Dune build/typecheck,
full regression, live Keeper/fleet, installation or deployment is claimed.

Initial dispatch [40231124770](https://github.com/jeong-sik/masc/actions/runs/40231124770)
selected the two queue suites at `361bca5570df5aa2a96f6503a35444582a991c9e`.
Author source review then found that the new callback argument had not been
threaded into the private non-strict save wrapper. That wiring is corrected
here, preserving the same writer and flags. The initial run's actual outcome
has not yet been read; it is not executable proof for this corrected source.

Corrected dispatch [40231173957](https://github.com/jeong-sik/masc/actions/runs/40231173957)
at `cb254b0d1ec2a6aec6005862b5b4f3353a30bfbd` failed before running tests:
`Fs_compat` was unavailable to the new executable because its Dune stanza omitted
the direct dependency. This repository disables implicit transitive dependencies.
The stanza now explicitly names `masc.fs_compat`, `masc.masc_eio_context` and `eio`,
matching the modules actually used. This compile failure does not establish any
behavioral result; corrected execution and fresh-head source review are pending.

Dispatch [40231799995](https://github.com/jeong-sik/masc/actions/runs/40231799995)
at `dc0650043c9b03e1f1af5c9108e4e5315ae9d8da` also failed before tests:
the test used a nonexistent `pending_selection.source_incarnation` field.
The current contract stores that authority as `admitted_revision`; existing
source-terminal callers use that field. The fixture now uses the same field.
Prior source reviews missed this typing error; executable behavior remains
unverified. Changelog section/citation validation is also corrected.
