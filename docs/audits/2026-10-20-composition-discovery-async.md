# Composition completion discovery without a maintenance join

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Maintenance `pulse` | Join complete pending partition discovery | Reserve discovery child and return |
| Result | Caller handles synchronous discovery/reservation result | Scheduling-only unit; actual typed result reaches observer |
| Whole directory failure | Server logs returned outbox error | Default discovery observer logs the same error |
| Partial bad record | Original filename/error diagnostic; healthy owners proceed | Same original pass and diagnostics |
| Owner worker | Original root/recipient/request and fresh obligation read | Same original worker under supplied server switch |
| Active discovery | Caller waiting for full discovery | Coalesce through observer/cleanup; later discovery rereads |

The filesystem already uses systhreads for applicable reads. Moving the join does
not create another I/O pool. A server-switch child yields before the unchanged
`Outbox.discover` and original owner reservations. Complete discovery still
precedes owner reservation inside that child. Same-owner obligations retain
original directory order. Captured pending identities remain hints: `recover`
rereads the original obligation and rejects changed request/recipient identity
before current canonical terminal, journal/waiting proof and original durable
queue/ACK path. No replay, substitute request or new effect permission is added.
A failed discovery neither cancels existing owners nor proves absence.

`pulse` now returns scheduling-only unit. `on_discovery` receives the actual
`(unit, Outbox.error) result` and original workspace, without obligations or
result bodies. `Ok ()` means discovery/reservations returned, not all records
healthy, all owners settled or any Keeper consumed the result. Original partial
failure diagnostics remain. Unexpected scheduling/worker exceptions log without
fabricating a storage error or successful result. Structural cancellation is
re-raised. Observer failure cannot undo reserved owners or durable delivery.
Discovery stays active through observer/cleanup, and failed scheduling releases
its reservation. Owner workers retain the original supplied lifetime switch.

Routine reserved/started/settled/interrupted/raised clocks identify the original
base path at reservation and actual returned/failed outcome at settlement.
Settled precedes the observer and active release; owner settlement and physical
worker exit remain separate. The interval includes reads, validation, owner
indexing/reservation and contention, not pure file time. Costs include a child,
active flag, reservation clock and three optional normal phase events, including
for empty/failed scans. Suppressing routine logs skips formatting/emission only.
Same-owner waits, full discovery cost and shared backend pressure remain. No
latency or throughput improvement has been measured, and no timer/cache/cap is
added. New obligations can wait for a later admitted discovery.

## Authored scenarios, unexecuted

The existing real held-intake/independent-owner scenario observes actual
discovery before its next controlled step. A driver yield lets discovery's pure
observer cleanup finish; it does not prove owner quiescence. Original fresh
shutdown refusal/rollback, later obligation, original Task/output, canonical
proof and already-ACKed hint checks remain.

The new compound scenario uses the existing actual async producer, leaves its
original accepted obligation pending, and replaces the production pending
directory with a regular-file blocker. Independent durable queue work commits
before the driver joins actual discovery observation. The actual typed storage
failure retains its workspace; no completion is admitted. Its observer raises
after handing off the error, and the joined root scope includes cleanup.
Restore the exact original directory, add a real malformed obligation and
run fresh discovery/owner recovery. Verify original request/tool/terminal and
canonical output/Task/producer context, exact target dedup, original obligation
retirement and unchanged visible malformed bytes/filename/error. No replacement
reader/projector, invocation counter, polling, timer or screen assertion is used.

Four changed OCaml paths receive parsing-only checks, interface first. Compare
the original delivery/owner core and discovery/reservation body to the parent;
outbox, request/journal, queue and filesystem authority remain unchanged.
No typing/warnings/link/build/test execution, CI, native/model/controller run,
installation/restart/live write, independent approval or merge is established.
Cancellation, partial scheduling, slow physical discovery, actual maintenance
loop overlap and TUI/input behavior remain unexecuted.

All six original axes remain open: original Ask/Task useful work; exact
preparation/frozen discovery; ordinary/nested/dynamic/effectful Composition
continuity; held-job/shared-backend reactivation; cold usable input and TUI
readability/visibility; matched actual cohorts retaining failed/cancelled/
interrupted/not-started/unfinished samples. Reserving completion recovery does
not establish logical Composition progress or useful work.
