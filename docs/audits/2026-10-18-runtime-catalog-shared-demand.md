# Runtime catalogue: shared read demand and retained observations

Source baseline: `5cc776264fc1960b9f1dbbc7596674aeac77d3e2` (#43700).

## As-Is / To-Be / Before and After

| Boundary | Baseline | This layer |
| --- | --- | --- |
| Key-handler HTTP waits | Zero; already asynchronous | Zero |
| N catalogue-consumer demands before the first request settles | N logical GETs; later generation discards earlier results | One owned catalogue GET |
| R refresh/post-save demands during that first request | Each starts another overlapping GET | One fresh follow-up after settlement covers the accumulated demand |
| Refresh after a successful observation | Marks catalogue loading; some consumers hide prior metadata | Explicit refreshing state keeps last observed rows |
| Failed refresh | Failed status can hide prior metadata | Stale observation retains rows and the failure; retry preserves that failure |
| Successful empty Keeper catalogue | Empty-note helper always says loading | Completed empty observation is distinct from loading |
| Withdrawal with nested demand | Generation retirement; only some visible surfaces reissue | Original read retires; retained demand resumes under a fresh verified owner |
| Observation clocks | No catalogue-specific correlation | Request/source revision, start, worker completion/interruption and UI admission logs |

Counts are source-derived, not measured speedups. N refers to consumers of
`launch_runtime_catalog_load` within one unchanged workspace/read authority while
the first read is pending. For R requests all arriving before that first settlement,
the combined chain becomes two logical catalogue GETs. Refreshes during the
follow-up can require another read. No wall-clock cap, timeout or request budget
is introduced. Authentication refresh may add physical requests.

## Existing cache and scope

`Masc_tui_kept_reads` already reuses ETag-tagged JSON on 304. It releases its mutex
before `send`/`decode`, so it does not coalesce in-flight requests. The catalogue
launcher previously incremented its generation and started a worker every time;
discarding a superseded response did not avoid the request or interpretation work.

This layer reuses the existing effect-free `Local_read_order` demand/revision engine
for the in-process catalogue source. It adds no second ordering implementation.
Consumer/poll requests share an active owner. Explicit refresh, Runtime form save,
account activation and assignment outcomes demand a newer read after the current
one settles. A response for the earlier demand cannot make that later demand fresh.

Overview quota and the Runtime operator surface also read runtime/resolved through
their own loaders. They remain separate in this layer; this is not global endpoint
deduplication. Runtime snapshot interpretation is unchanged, including its current
repeated snapshot decode in the catalogue loader. No extra health GET is added.

## Ownership, failure and product visibility

The request captures workspace authority, read token, expected workspace, source
ticket/revision and start clock. Only its current response can settle the source.
The worker uses workspace-owned observation cancellation and checks captured local
authority before dispatch. This does not introduce atomic server workspace binding.

Refresh keeps the last good catalogue with explicit refreshing status; failure
settles as stale while retaining rows. Retry retains the prior refresh failure
until its own result. A valid empty success is a successful observation, including
when no default route is configured. The Keeper picker summary and empty state,
slot metadata, lane picker summary and recent-context details reflect those states.
The existing exact slot replacement freshness condition remains: stale/refreshing
catalogues do not supply replacement choices. No new screen-word or layout tests
are added; the obsolete test expecting empty/unread wording is removed.

Workspace read withdrawal invalidates the old ticket and retains active or nested
demand. Reconfirmation starts a new read that absorbs both the retired request and
its queued refresh. A workspace change clears rows, default route and demand while
retiring the ticket without reusing its number. Navigation alone does not cancel
the source shared by another consumer.

## Evidence boundaries and next comparison

Three feature scenarios are authored, unexecuted: shared consumer demand and a
fresh follow-up; retained observation/failure/retry and successful empty response;
and withdrawal/reconfirmation without obsolete or redundant completion. The existing
nested-read retirement scenario is adapted from generation to source-ticket ownership.
They inspect request/state decisions, not terminal phrases, placement or row order.

Parsing-only checks, diff hygiene and changelog metadata are recorded separately.
No local Dune/typecheck/tests, CI dispatch/watch, native/model execution, install,
restart or live runtime/config write is part of this unit. Independent approval,
merge, typing, behavior, painted frames and latency remain unverified.

Future matched observation must pin source and installed binary and use the same
workspace, consumer overlap and mutation timing. Count catalogue dispatches apart
from Overview/surface readers and authentication calls. Keep failures, interrupted,
cancelled and unfinished samples. Start, worker observation, UI admission, actual
paint, first usable input and useful Keeper work are separate measurements.
The full objective still includes preparation/discovery attribution, cold-start
input, Ask-to-original-Task/useful work, resource-owned Composition and held-job/shared
backend reuse; this source unit does not establish their runtime completion.
