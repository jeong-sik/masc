# Owned-job discovery outside the maintenance caller

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Server startup/maintenance | Calls owned-job marker discovery before proceeding to prepared Composition and Ask recovery | Reserves a discovery child on the original server switch and proceeds |
| Pulse return | Actual typed discovery/worker-reservation result | Scheduling only; actual result goes to `on_discovery` with the original base path |
| Discovery lifetime | Each direct caller runs its scan | One admitted scan remains active through observation and cleanup; active pulses coalesce |
| Markers, jobs and held hints | Validated markers reserve independent original jobs; successful full scans prune absent hints | Same original discovery body, marker order, job reservations and complete-scan-only pruning |
| Failed scan | Caller receives the original `Store.error` | Observer receives that same error; durable owners and existing workers remain |

The source boundary was the direct call in `server_bootstrap_maintenance.ml`:
later prepared-continuation and Ask recovery was sequenced after the complete
owned-job pending-marker pass. Prior job-child entry yields did not remove the
caller's scan. This change moves that pass into its own switch-owned child,
yielding before discovery. It uses no new switch, pool, timer, limit or runtime
knob. The controller owns one process-local discovery scheduling flag in
addition to its existing per-job reservations and held hints.

`pulse` now returns `unit`; it does not synthesize successful discovery. The
actual `(unit, Store.error) result` is delivered through `on_discovery` with the
original config's base path. Its default observer logs whole-pass errors.
Original per-marker diagnostics still coexist with a successful whole-pass
return; that return is not an assertion that every marker was readable. No
job result, Task progress or logical Composition completion is inferred from
discovery. All direct pulse consumers are migrated; the synchronous `reconcile`
entrypoint and its actual round report remain independent and unchanged.

The original discovery/job-reservation body is preserved after renaming it
`discover_and_schedule`. Canonical marker validation, original callback order,
per-job child entry yield, exact owner recovery, backend authority, typed partial
failures, queue deduplication, ACK and later resource cleanup remain. A late
discovery error does not cancel earlier admitted jobs or prune held hints from
an incomplete scan. Shared backend presence still belongs to the original
discovery round; no hint or ready result becomes effect authority. Jobs can run
during discovery I/O; the change promises no all-candidates-before-work barrier.

Discovery is reserved before fork, checks the supplied switch before scheduling
and again before fork, and remains active through its observer and original
`Fun.protect` cleanup. Failed scheduling releases the flag. Cancellation stays
structural and does not become a storage error or a success callback. Ordinary
observer failures are logged without discarding the actual pass result or
canceling original job workers. Unexpected worker exceptions are recorded as
raised, without inventing a typed return. Active pulses coalesce; a newly added
marker can wait for the next maintenance pulse rather than receiving an
immediate follow-up scan. Protected physical I/O can still delay shutdown.

Typed internal phases record reserved, started, actual settled result,
interrupted or raised, with original base path and monotonic timestamps. A
settled pass and a later interrupted observer can both be recorded; they describe
different boundaries. These observations do not certify job-worker physical
exit or visible TUI paint/input. Added costs are the admission flag, child
allocation, entry suspension/cancellation check, monotonic/log formatting and
the result observer. Original discovery/validation/I/O costs remain. No measured
milliseconds, throughput or speedup are inferred.

A new unexecuted protocol/resource scenario accepts a real fixture job and
collects its complete output, then replaces the actual pending directory with a
regular file while saving the original marker bytes. It schedules recovery,
commits independent durable queue work before joining the discovery observer,
checks the original typed error and original owner/marker preservation, and
exercises observer failure. Restoring the directory beside one malformed marker
allows the same controller to deliver exactly one original notification, keep
the original Task/turn/conversation/output, clean its original resources and
retire its marker while preserving partial damage and independent queued work.
The CLI peer is synthetic, not real Docker isolation proof.

Existing cancelled-round, blocked-backend and shared-presence scenarios await an actual
discovery receipt where they require admitted original jobs or a completed scan
before subsequent work. Selected switch scopes still join their actual children;
notification-driven continuation scenarios await their original continuation
results. Existing shared-presence, held-reactivation and nested-DAG scenarios
remain unexecuted. No new invocation-count, helper, UI wording/layout/snapshot
or PTY test is added.

Verification is parsing only for the implementation/interface, server consumer
and changed scenario file, whitespace checking and source-preservation comparison.
The existing owning library already directly declares Eio and monotonic clock
dependencies. No typing, warnings, linking, local build/test execution, CI,
controller/native/model/TUI run, live installation/restart, independent approval
or merge is established. Preparation latency, useful work, worker quiescence and
visible loading/input remain unverified.

All six original axes remain open: original Ask/Task useful work, exact
preparation/frozen discovery, ordinary/nested/dynamic/effectful Composition
continuity, held-job/shared-backend reactivation, cold usable input/TUI
readability/visibility, and matched actual cohorts retaining failed/cancelled/
interrupted/not-started/unfinished attempts. Prepared-continuation direct
discovery still runs synchronously and must be considered together with its
existing coalesced result-notification drain in the next implementation unit.
