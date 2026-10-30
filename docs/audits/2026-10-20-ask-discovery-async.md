# Switch-owned Ask discovery with its original result

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Maintenance `pulse` | Join complete directory/log discovery | Reserve discovery child and return |
| Return contract | Synchronous discovery/reservation result | Unit means scheduling; original typed result goes to observer |
| Whole discovery failure | Server logs returned read error | Default discovery observer logs the same read error |
| Partial unreadable logs | Report per-log error; recover healthy owners | Same original pass |
| Owner recovery | Original captured rows and independent owner workers | Same original pass under supplied server switch |
| Active discovery | Caller still waiting | Coalesce pulses through observer/cleanup; later pulse rereads |

File reads already use the existing Fs_compat systhread path. This removes
their join from maintenance; it adds no I/O executor or inline retry. The child
yields before the unchanged discovery/reservation pass. Complete discovery still
precedes owner reservations inside that child. Canonical ownership, strict log
reads, first-answer folding, row order, per-owner evidence-window reuse and fresh
queue/intake checks remain. No discovered row or result is reused across workers.
A failed discovery leaves existing owner workers alone and never proves absence.

The new observer receives only the actual pass result and original base path,
without question/answer rows. `Ok ()` means the pass returned and reservations
were considered; it does not mean every log was readable or any owner delivered.
Existing partial-log diagnostics remain. Unexpected scheduling/worker exceptions
are logged without inventing a read-error result. Structural cancellation is
re-raised. Failed discovery scheduling releases its active flag. Observer failure
cannot undo reserved owners or durable queue writes; discovery stays active
through that observer and cleanup.

Routine reservation/start/settled/interrupted/raised events identify the original
base path and process-local reservation clock. Settled includes an actual
returned/failed result and precedes the observer/active release; owner settlement
and physical worker exit are separate. The interval includes directory/log reads,
validation/fold/decode/sort, scheduling and any contention, not pure I/O time.
Suppression skips formatting/emission but not the extra child, flag or reservation
clock. Empty and failed scans also incur scheduling. New answers can wait for the
next admitted discovery. No timer, retry interval, cap, answer cache or effect
permission is added. No latency or throughput improvement is measured.

## Authored scenarios, unexecuted

The existing real blocked-owner scenario now observes actual discovery completion
before proceeding with its held intake/fresh-fence steps; it retains original
answer/Task/continuation and independent-owner checks. A test-driver yield lets
the observer's pure discovery cleanup run; it is not owner quiescence evidence.

A new compound scenario persists an actual original answer, replaces its owned
Ask directory with a regular-file blocker, then reserves discovery while an
independent durable queue item commits. It checks the actual typed directory
error and original workspace, with no original-answer admission. The error
observer raises after handing off that result; the joined scope must still
retire discovery. Restore the original directory, run fresh discovery and owner
delivery, and verify exact Ask/Task/continuation plus unchanged answer bytes.
Another fresh round must preserve one original queued source. No replacement
reader/projector, invocation counter, polling, timer or screen assertion is used.

Four changed OCaml paths receive parsing-only checks, interface first. Original
store, answer-delivery core and discovery/owner-reservation body are compared
with the parent. No typing/warnings/link/build/test execution, CI, native/model/
controller run, installation/restart/live write, independent approval or merge
is established. Cancellation/partial scheduling, slow physical discovery,
actual server-loop overlap and TUI/input remain unexecuted.

All six original axes remain open: original Ask/Task useful work; exact preparation
and frozen discovery; ordinary/nested/dynamic/effectful Composition continuity;
held-job/shared-backend continuation; cold usable input and TUI readability/
visibility; matched actual cohorts retaining failed/cancelled/interrupted/
not-started/unfinished samples. Scheduling is no delivery or useful-work proof.
