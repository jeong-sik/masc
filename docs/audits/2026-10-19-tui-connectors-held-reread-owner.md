# Preserve the original Connector reread demand

Source comparison base: `6869ba3f24c` (merged main; full SHA in the PR identity).
The preceding 53-member stack, ending at #43862, was merged externally at
`9cc3f56eb452ff183aba2dddd2a436d5a2deae4f`. The subsequent main build repairs and
Tools status changes are retained. This unit starts a new local `gh stack` from
main and rebases that whole active stack with the official CLI; it does
not push the merged branches. Merge does not prove installation or runtime.

## As-Is / To-Be

A binding write can finish while an older Connector read is active. The old
two booleans correctly queued another read on normal completion, but transient
workspace uncertainty cleared both booleans. The required post-write observation
then disappeared. Retaining only the queued bit would also lose demand when
the replacement read itself was withdrawn, and retrying on every failure would
risk an immediate launch/failure loop. Responses carried only shared detail
authority, rather than the particular read request that still owned the slot.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Original request | Shared authority plus two mutable booleans | Opaque request with authority, physical owner and initiating cause; one immutable control state |
| Write during read | Normal completion queues one fresh read | Same coalescing; older result cannot satisfy the later write |
| Temporary withdrawal | Both flags cleared | Retire the request and retain both initiating and later write demand |
| Same-workspace recovery | Depends on another visible read | Existing recovery transition starts held demand even with its surface hidden |
| Start failure | Authority-guarded inflight reset | Exact request releases active status synchronously; its own failure remains admissible |
| Failed reread | No retained initiating cause | Hold demand for an explicit/existing read; no immediate failure retry |
| Late completion/callback | Shared authority check | Exact current owner and authority required before changing state or applying a result |
| Confirmed other root | Clear old presentation | Also clear old demand; A -> B -> A does not revive an old request |
| Visible state | Generic loading/error or last snapshot | Reading, queued recheck, held recheck and failed start distinguished from last observation |

`Connector_read` has an interface before its implementation inside the existing
Types library, like the nearby immutable read controls. The UI edge supplies
fresh physical owner tokens. No extra generation counter, executor, timer,
cache, concurrency cap or configurable retry limit is introduced. Its new
variants are internal OCaml control states, not a shared JSON/dashboard/TLA+
domain enum. The existing in-process `Connectors_loaded` payload now carries
the opaque request; its constructor arity and wire endpoints do not change.

## Original request through completion

`begin_connectors_read` uses the existing server-readiness policy, including
the intentional ability to read a confirmed remote workspace differing from
the checkout. An active same-authority request is shared. Writes record demand
before attempting launch, so an unavailable authority cannot erase the write.

Withdrawal drops the request's slot but preserves owed demand. A same-workspace
reconfirmation changes read authority and reaches the existing recovery hook.
The hook first performs normal visible reads, then starts a still-held Connector
read. A read already started, or one synchronously unable to start, is not
launched again there. This runs on authority recovery, not every identity poll.
Confirmed root withdrawal uses the actual existing reset boundaries and clears
the demand. The private Main identity classifier is source-inspected, not run.

Completion must own the exact current request before touching snapshot, error,
selection or unbind offers. A write after an active read began requires one
fresh read regardless of that older result. Failure of an after-write read
without a later write holds its original demand without immediately launching
another attempt. A not-started request admits only its own error, likewise
without an immediate retry. Delayed callbacks cannot release a successor.

The preceding workspace GET/cache receipts, parallel independent name chains,
sequential cursor pages, observation cancellation registry and shared CPU
projection are retained. Cancelling an observation, releasing a UI slot,
receiving a result and actual worker cleanup remain different events.

## Visibility and quantitative comparison

Connectors and Keeper Channels display the same notice derived from typed
control state. A current read can explicitly show that the table is the last
observation. Held write demand shows whether workspace confirmation is pending
or a retry is available. The Connector scroll chrome includes the extra row;
Keeper Channels uses its existing rendered row budget. These are source changes,
not terminal capture, paint proof or evidence of useful Task progress.

Nominal explicit GETs remain **P + 1 -> P + 1 per attempt**, where P is all
directory page GETs. This unit repairs missing/redundant ownership transitions;
it does not claim a reduction in HTTP work or a measured latency improvement.
Multiple writes before a fresh read starts coalesce into one owed read; a write
after it starts requires a subsequent read. No throughput or Loading duration
has been measured, and no improvement percentage is asserted.

## Authored scenarios and evidence limits

Two compound scenarios extend the existing temporary sidecar binding-store
fixture. They use real `bind`, conditional unbind, persisted membership and
`connector_json`, together with the production TUI begin/suspend/complete/reset
functions. Request owners are produced by those functions, rather than invented
expected generations or mirrored transition helpers.

1. Remove an original member while a read is active, preserve another member,
   withdraw/reconfirm twice, reject both retired results, then change the
   surviving member after a fresh read began. Only the later owned observation
   may settle the second write's demand.
2. Receive a real write during uncertainty, fail its read to start, retain
   demand without immediate retry, reject a late start-failure callback, fail
   the explicit reread, and finally observe the real persisted write. Reset
   into another temporary root with the same member ID but different value,
   then return to the first root while rejecting both retired owners.

These scenarios are **authored, not executed**. Identity records are fixtures;
they do not exercise actual health transport, private Main recovery routing,
HTTP/cache receipts, snapshot application, worker cleanup or the terminal.
No wording, layout, row-order, snapshot, PTY, invocation-count or mirror tests
are added. Parsing and whitespace checks are the available narrow evidence;
they are not typechecking, test success, independent approval or runtime proof.

Later matched Before/After must retain failed, cancelled, interrupted and
unfinished attempts, including original request owner, write order, authority,
queued/held demand, received membership and worker cleanup. Compare the same
roots and data; do not exclude a failed sample because a later retry worked.
The previous aggregate-page/cancellation scenario remains separately needed.

The broader six-part goal remains open: original Ask/Task/useful work,
preparation attribution and discovery reuse, Composition resource continuity,
held/shared-backend batches, cold-start input and TUI visibility, and matched
Before/After evidence. This Connector repair is one bounded part of it.
