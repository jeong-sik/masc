# Own and compose the Connector directory read

Source comparison base: `957598cb75bc34a21d1f34fb83a3844a8caa85d4`
(#43856). This unit covers the Connector status snapshot and all its directory
pages, their admission/cancellation scope, pure interpretation and projection.
Binding writes and their effect authorization remain separate operations.

## As-Is / To-Be

The original root Async_read daemon checked health, loaded status and every
directory page serially, then checked health again. Its actual JSON GETs did
not bind the expected workspace. A same-endpoint A -> B -> A replacement could
therefore answer an intermediate page from B despite the two A health reads.
The page decoder carried Connector ID and typed kind, but the loader only
checked cursor/count progress: projection silently filtered other Connector IDs
later and accepted other kinds under that Connector. Pure typed interpretation
and name projection also ran on the calling fiber.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Actual workspace admission | Health before/after aggregate | Expected-root precondition and receipt on status and every page, including 304 |
| Snapshot dependency | Status must establish Connector list | Same dependency; only its descendants become parallel |
| Directory dependency | Connectors and three kind chains serial | Independent Connector/kind chains share existing Eio resources |
| Cursor dependency | Pages within one chain sequential | Same original cursor sequence and all pages retained |
| Page ownership | Requested cursor checked; Connector/kind not checked by loader | Exact Connector ID, typed kind and requested cursor checked before accumulation |
| Read cancellation | Connector daemon tied to root switch | Existing workspace observation registry owns this structured read |
| Start failure | Source prefix and synchronous inflight release | Same source attribution/release through shared launch callback |
| Interpretation | Calling-fiber snapshot/page decode and projection | Pure traversals use the existing shared CPU helper |
| UI delivery | One aggregate after all chains | Same aggregate boundary; not an early-paint implementation |

## Actual source, scope and partial results

`handle_gate_connectors` produces the required Connector list. Its names route
reads `Keeper_connector_names.entries` for the requested Connector and scope,
returns that Connector ID/kind and filters entries after the requested cursor.
The next cursor comes from the actual last page ID. Independent chains do not
consume each other's result. Status uses the existing public-read wrapper;
names retain read authentication and the common expected-workspace guard.

`launch_connectors_load` now uses `launch_workspace_json_read`, which captures
identity, endpoint, authority and physical read epoch before launch. Both HTTP
consumers already use common `get_json`. Eio child fibers inherit the original
binding, so each concrete URL is prepared before crossing to IO and requires
the matching receipt before accepting or caching a body. Cached JSON is
partitioned by expected workspace and full request address; a 304 also requires
its receipt. Cached pages still pass the typed body ownership checks. No health
GET or unbound fallback is added. Source failure does not impersonate a global
identity observation; existing shared refresh owns identity discovery.

The new `read_map` follows the existing loader runtime policy: with an installed
Eio switch, `Eio.Fiber.List.map` joins its child fibers; without that TUI runtime,
it uses synchronous `List.map`. No daemon is spawned per page. Each Connector
maps the three existing kind variants; each chain follows its own next cursor.
Results remain paired with their original inputs independent of finish order.
The existing HTTP page default is reused instead of duplicating `500` in the
loader; it remains a page-size boundary, not a total directory cap.

A normal transport/decode/identity/cursor failure ends only that chain, keeps
its preceding pages and contributes a named error alongside valid siblings.
Existing empty-page/no-progress/next-cursor/count checks remain. A mismatched
Connector or kind is now a failure of the asking chain and is excluded before
projection. Unexpected raised exceptions follow structured sibling cancellation
and the shared outer error boundary; they are not represented as successful
partial reads. Cancellation is re-raised. A failed status snapshot retains the
previous complete UI snapshot plus error. A successful snapshot with directory
failures contains the current attempt's valid pages plus directory errors; it
does not silently borrow missing names from an earlier attempt.

Only immutable snapshot/page decoding and `connector_with_name_pages` projection
cross the existing CPU boundary. Network, credentials, cache, cursor recursion,
workspace state, UI selection and completion remain caller-owned. Historical
name provenance stays historical: the returned Slack `current_workspace_id` is
not substituted for expected filesystem roots or proof of scoped name ownership.

## Shared cancellation blast radius

The JSON launch wrapper previously registered only a full workspace job. It now
passes the already-existing `observation:true` classification to that registry,
so read-epoch withdrawal also requests cancellation. Before this change its
eight concrete callers were preparation detail; the three Tools parts; Keeper
Calls; Goal timeline; Task history; and saved browser history. All eight are
read-only JSON observations. Connector is the ninth. General request/effect
callers keep `observation:false` and their existing preflight/operation receipt.
The standalone current-turn Async_read callback is not migrated by this unit.

The shared launcher adds an optional start-failure callback; Connector uses it
to preserve its authority-guarded synchronous inflight release. Error attribution
still comes from `Masc_tui_async_read.attribute Connectors`, exactly once. The
shared launcher captures one completion envelope and creates one owned daemon;
there is no second fork around Async_read. Workspace withdrawal requests
cancellation and the existing token is removed in actual worker cleanup. A
queued old completion still has to pass authority/read-epoch admission. Neither
a cancellation request nor a UI slot reset is proof that every worker finished.

## Source quantification and observations

Let P be the total number of directory page GETs for one nominal successful
status snapshot. Explicit GETs change **P + 3 -> P + 1**: the same status GET
and P page GETs, with two redundant health GETs removed. P includes empty first
pages where applicable and is zero when there are no Connectors. Refusal,
interruption or cancellation can produce a different attempted-page count.

After status, the source dependency graph changes from serial chains to
independently eligible chains, while each chain's pages remain sequential.
An idealized critical-path comparison is the sum of chain durations versus
their maximum. This excludes resource contention, pool admission, auth refresh,
connection work, CPU/projection and UI/paint scheduling. No measured speedup,
input/Loading/paint/throughput or useful Task progress is asserted.

`connectors.snapshot.decode_wait`, `connectors.names.decode_wait` and
`connectors.names.project_wait` include pool wait, pure computation and return
scheduling. They are not pure CPU timings or evidence of UI application. All
existing pool-absence/non-Eio/already-worker inline policies remain in force.

## Compound scenario and remaining boundary

For later matched verification, hold one Connector's multi-page person chain
while another Connector's server/channel chains finish, fail a later page after
valid names, and return a wrong Connector/kind page on another chain. The result
must contain only matching original IDs and preceding valid pages plus source
errors. During the same read, queue a binding write's reread demand: completion
of the older read must start a fresh read rather than satisfy that demand.
Then withdraw identity/read authority while IO or CPU work remains, switch
same-endpoint A -> B -> A including cache/304, and retain all cancelled,
interrupted, failed and unfinished samples. Old child cleanup/results must not
clear a successor owner. Distinguish cancellation request, cleanup, transport,
decode, UI admission, input and paint.

This is a prose scenario specification, not a new test implementation or an
executed test. Only source/interface inspection, OCaml parsing, diff and
changelog checks are performed. No typing, tests, CI dispatch/watch, native,
model, PTY, controller/report execution, installation, restart, runtime timing
or visible UI proof is claimed. No helper-mirror, invocation-count, layout,
wording, row-order, snapshot or PTY tests are added.

One concrete residual is deliberately not called solved: while the normal
same-authority `Connectors_loaded` handler preserves a write's queued follow-up,
`suspend_workspace_readings` currently clears both Connector inflight and queued
reread flags. Durable ownership of that demand across transient read withdrawal
needs a separate typed state transition; cancellation registration alone does
not supply it. This unit does not add retries or claim that cross-retirement
write/read continuity, incremental UI delivery, independent source approval,
merge, deployment or the full original Ask/Task/useful-work goal is complete.
