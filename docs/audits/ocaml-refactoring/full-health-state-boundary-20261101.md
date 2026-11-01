# S5: full-health observation and refresh ownership

Source baseline: `61b4d5531d44cb780dff64158fdbf7d641f1658f`.
Read on 2026-11-01. This is a source/design investigation, not an implementation
or runtime verification receipt. The campaign remains open.

## Current boundary

[`server_routes_http_runtime.ml`](../../../lib/server/server_routes_http_runtime.ml)
owns the cached snapshot, shared refresh worker and ten global refs under
`full_health_snapshot_mu`. Each worker retains its id, completion promise,
freshness and whether its waiter failure was already reported.

| Event | Current transition and effects |
| --- | --- |
| Cached read needs refresh | Sets the request flag; does not directly wake the loop. |
| Direct synchronous refresh begins | Sets in-flight and start time and clears the request flag, without creating a shared worker. |
| Shared worker admission | Joins the existing worker's promise and increments joins, or creates a worker/promise/id, increments submissions, records start time and clears the request flag. |
| Invalidation | Increments the observation generation, preserves the first stale time on snapshot and worker, and requests refresh. Wakes outside the state lock, protected from cancellation, only in Eio. |
| Waiter failure | Reports once per active worker, preserving worker ownership and start time. Retains prior measured fields/time, records degradation and increments failure evidence. |
| Current worker succeeds | Publishes the measured snapshot, clears stale/failure/request state and resets consecutive failures. |
| Invalidated worker succeeds | Publishes newer measured fields as stale; preserves the earliest prior stale/invalidation time, resets consecutive failures, requests a successor and wakes the loop. |
| Worker fails before a waiter failure was reported | Preserves the prior payload and measurement time, records failure/degradation once and emits the configured critical metric only at its crossing. Dirty work still requests a successor. |
| Worker fails after its waiter failure was reported | Retains the earlier timeout evidence and avoids duplicate failure counting/degradation. Clears in-flight state; dirty work still requests a successor. |
| A different worker finishes | Ignores the outcome. |
| Test reset | Clears state but leaves the capacity-one wake mailbox intact. |

The completion promise is resolved after worker settlement and any successor
wake. The worker belongs to the enclosing switch, so cancellation of one waiter
does not cancel the shared compute.

## Corrections to the earlier candidate

- An invalidated success is not discarded. It supplies a newer measured
  observation with `last_good_available = true`, its real completion time and
  stale metadata. Only an uninvalidated success certifies freshness and ends
  the continuous stale period.
- `invalidation_generation` is an observation counter. Worker freshness is
  represented by `Current_generation | Invalidated_during_refresh`; introducing
  a generation-number admission gate would change the current contract.
- Success/failure publication also updates `fleet_stream_hub`. These effects
  occur under the snapshot lock and must remain ordered with cache publication.
- `Idle | Worker_running` alone does not represent the direct synchronous
  refresh used by test helpers: that path is in-flight without an active worker.
- Cold failure placeholder construction reads current runtime state, including
  `Server_auxiliary_startup.global`. It cannot move into a pure reducer as-is.

## Smallest coherent next implementation

Extract a private observation reducer before changing worker ownership:

1. Move the snapshot type and immutable `{ snapshot; consecutive_failures }`
   state into a private observation module.
2. Give current success, dirty success, newly reported failure and already
   reported worker failure explicit transitions. Supply time, invalidation
   evidence and any cold fallback snapshot from the shell.
3. Return the new state with explicit fleet-reading, degradation and critical
   metric effects. Preserve the earliest stale time and distinguish the latest
   measured time from failure time.
4. Keep state replacement and publication ordered under the existing mutex.
   Keep clocks, cold placeholder acquisition, Eio promises/fibers, wakeups,
   logging and metrics in the shell.

A later layer can consolidate coordinator refs into explicit direct/shared
refresh phases and replace positional reader tuples with a named immutable
view. First settle the test-only direct/shared overlap contract; do not silently
turn existing flag combinations into a new product concurrency policy.

## Direct verification targets

The existing public-consumer scenarios in
[`test_server_runtime_bootstrap.ml`](../../../test/test_server_runtime_bootstrap.ml)
are the primary targets:

- `test_full_health_refresh_worker_survives_waiter_cancellation`
- `test_full_health_refresh_worker_publishes_dirty_observation`
  (both cold and last-good variants)
- `test_full_health_returned_failure_preserves_observation`
  (cold/last-good and current/dirty combinations)
- `test_full_health_returned_failure_after_wait_timeout`
- `test_full_health_dirty_success_after_wait_timeout`
- `test_full_health_refresh_timeout_preserves_last_snapshot`
- `test_full_health_cold_refresh_timeout_is_timeout_not_error`
- `test_a_last_good_snapshot_says_it_is_stale`
- `test_a_rebuilding_snapshot_has_no_fleet_reading`
- `test_full_health_invalidation_outside_eio_keeps_the_wakeup`

These scenarios were read, not executed in this investigation. No direct test
of the critical metric crossing or a nonmatching worker finish was identified
in the inspected test file. This is a coverage observation, not a reproduced
defect. There is no build, typecheck, CI, installed-binary, live endpoint, fleet
stream or UI result attached to this report.
