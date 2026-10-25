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
