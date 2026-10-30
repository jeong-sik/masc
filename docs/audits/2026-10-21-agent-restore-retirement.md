# Agent restore: preserve removals across asynchronous discovery

This is a source Before/After for an ordinary PR, not measured runtime behavior.
It responds to #44474 review 5589989183 item 2. Agent-name presence is separate
from MCP transport-session initialization and duration accounting.

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Name read, then unregister, then owner apply | Missing name recreated from old discovery | Name omitted by that restore |
| Name absent, registered and removed before apply | Endpoint absence misses the intervening removal | Processed unregister retires even an absent name |
| Overlapping admitted restores | Each may resurrect the removed name | Removal recorded in every currently open scope |
| Actor ends before external caller publishes its read | Old read can enter direct fallback or restarted actor | All unclaimed scopes invalidated; late request gets `Registry_closed` |
| Later fresh restore | Names missing in current state inserted | Same; no permanent tombstone |

Each restore admits a fresh physical token before actual host discovery. Private
immutable scope records live in one registry-local Atomic list, separate from the
actor's cached state. Processing unregister adds the name to each open scope,
including when the name is absent. Owner application atomically claims/removes
its scope and merges only names neither live nor retired. Existing live session
objects, queues, listening state and activity survive. This preserves a removal
relative to scopes admitted before it; a new restore admitted after the removal
may restore that persisted name.

A synchronous non-I/O `Fun.protect` finalizer removes an unclaimed scope on host
failure, callback failure or caller cancellation. Cancellation before owner claim
can invalidate even an already queued request; cancellation after claim cannot
undo publication. Actor release clears all unclaimed scopes before draining the
mailbox. No permanent closed flag prevents fresh direct fallback or restart.
Claim, caller cleanup and actor invalidation race through CAS/Atomic operations;
no new request mutex, wall-clock expiry, integer generation gate or policy cap.
The old timestamp is still captured on the caller before discovery. Physical
host work is not forcibly stopped, and a claimed application is not rolled back.

Host existence/directory/name discovery stays in the common host executor and
returns immutable names only. Queue allocation and registry application remain
with the actor/direct owner. Original suffix/entry order, matching directory and
symlink behavior, missing/non-directory no-op, rate trackers and bootstrap call
policy remain. The separate `McpSessionStore` is byte-identical to the base.

The new `For_testing` entrypoint shares that real pipeline. Its callback runs on
the caller after actual directory discovery, before completion cancellation check
and owner dispatch; it never runs in the host worker. Five authored resource
cases order direct removal, transient actor registration/message/removal, two
real discoveries and peer notification, post-read cooperative cancellation, and
actor release/restart with a late read. They use real paths, registry requests,
queues, switch lifetimes and Promise gates. The prior four cases remain intact.
No fake name provider, private-state query, invocation-count check, sleep, stress
cap, UI wording/layout/snapshot or PTY case. None of these scenarios was run.
They do not force removal during a kernel read, physical-I/O cancellation or the
queued-request/owner-claim race. A fresh restore demonstrates later admission
policy, not heap reclamation; cleanup is currently supported by source only.

Preparation still includes host reads, shared-worker dispatch and mailbox waits.
New costs are one token/scope admission and finalizer per restore, a no-op callback
on successful production discovery, linear active-scope claim/cleanup scans and
CAS retry allocation under contention. Processing unregister maps over R active
scopes and inserts its name into each immutable set (set cost depends on that
scope's distinct removals). Retention depends on active restore lifetimes and
removals during them; a hung inline host call can keep an active scope until its
caller returns or an actor release invalidates it. There is no constant memory
bound or measured latency/speedup claim. Unregister also executes the Atomic
update when no restore is active. No new log rows or metrics were added.

Only `session.mli`, `session.ml` and `test_session_restore.ml` passed parsing, in
that order. No type/warning/link/build/test/CI/native/controller/model/PTY/TUI
paint/input/runtime check was executed. Existing direct `masc_core`/test library
dependencies are unchanged. Publication and current-head independent review are
separate evidence; this source response is not reviewer acceptance or merge.
All six original goal axes and matched actual failed/cancelled/interrupted/
not-started/unfinished Before/After cohorts remain open.
