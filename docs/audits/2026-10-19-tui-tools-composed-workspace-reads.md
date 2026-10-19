# Compose the Tools reads within their original workspace

Source comparison base: `14d8898411b587e30c26a722095b62f54663a41c`
(#43853). This unit changes the Tools inventory, Skills catalog and async-request
observation reads as one user-visible load. It does not change tool execution,
Skill activation, Composition effect admission or Keeper scheduling.

## As-Is / To-Be

The Skills catalog and inventory started separately, each after a compact
identity GET. Inventory's delivery callback then started async observation,
with another identity GET, before returning the inventory completion message.
All three data readers already used common `get_json`, but these callers did
not bind the expected workspace to their actual GET. Each typed decoder ran
directly on its calling fiber after common JSON parsing.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Initial dispatch | Catalog and inventory; async waits for inventory completion | Three independent asynchronous launches in the original dispatch |
| Workspace proof | Separate health preflight per part; no bound data GET | Existing captured local owner check and expected-root admission on each actual data GET |
| Completion callback | Inventory callback starts another workspace request | Message construction only; no deferred sibling launch |
| Nominal explicit GETs | Three identity plus three data GETs | Three bound data GETs |
| Typed interpretation | Three calling-fiber traversals | Three pure traversals through existing shared CPU helper |
| Partial completion | Named pending parts with independent values/errors | Same member ledger, generation checks, last-good values and errors |
| Async visibility | Dispatch waits for inventory outcome | Independent dispatch; its own transport/decode may still wait or fail |

Independence follows the actual producers, rather than an assumption about
parallelism. `Server_dashboard_snapshot_select.select_tools_response` selects
the existing global snapshot or exact Keeper projection. The Skills route in
`server_routes_http_routes_activity.ml` reads the published workspace snapshot
and activation ledgers. `Server_async_request_observability.project` reads the
durable active inventory and runtime ownership. None consumes another of these
three HTTP results. Their data are observations at their respective read times,
not an atomic cross-endpoint snapshot. Existing public-read/admin authentication
and the exact optional Keeper selector remain in force.

All three launches use existing `launch_workspace_json_read`. It captures the
expected identity, endpoint, workspace authority and physical read epoch, checks
them on the existing child, and binds the actual GET through
`Masc_tui_workspace_read`. Common JSON/cache handling requires the server's
matching receipt, including on 304, and partitions cached data by expected root.
There is no unbound fallback. General request/effect preflight and shared
identity refresh remain unchanged. Original workspace envelopes still reject
retired completions; the Tools generation and selected Keeper checks still
govern application. A completion can no longer start a sibling request later.

The existing named member ledger is unchanged. An unavailable switch delivers
each part's failure through the shared launcher; each corresponding UI handler
settles that part. A failed part retains its last successful value and records
its own error. Warming inventory, uninitialized catalog and unavailable async
observation retain their typed meanings. A source failure is not a new global
identity observation or permission to retry an effect. Cancellation is still
re-raised and workspace suspension retires the pending reading.

Only immutable JSON-to-typed-value interpretation crosses the CPU boundary:
`decode_tool_snapshot`, `decode_skills_catalog`, and
`decode_async_request_observation`. HTTP, credentials, cache, UI state, member
settlement and selection stay with their original owners. Existing pool absence,
non-Eio and already-worker inline policies remain authoritative; no executor,
cache, timeout, concurrency cap or retry loop is added.

## Quantification and observation

The source-level nominal successful group changes **6 -> 3 explicit GETs**:
three redundant preflight GETs disappear while the three data reads remain.
This count excludes authentication refresh, shared world refresh, connection
work, retries and server-internal work. It is a 50% reduction in that explicit
request count, not a measured latency or useful-work improvement. Local or
server refusal can stop a part before its data read completes.

Async observation loses one explicit dispatch dependency on inventory. All
three data requests become eligible independently, subject to existing IO/CPU
pool scheduling and server resources. They are not guaranteed to run physically
at once. Concurrent eligibility can change resource contention; no throughput
or input responsiveness gain is asserted from source alone.

`tools.inventory.decode_wait`, `skills.catalog.decode_wait`, and
`tools.async_observation.decode_wait` name the established shared CPU path.
Each interval includes pool waiting, interpretation and return scheduling; it
is not pure CPU duration, UI application, paint or successful Task execution.

## Compound review scenario and Before/After evidence boundary

The following scenario is specified for later matched runtime verification;
it is **not an executed test or a new test implementation**. This implementation
reuses the existing workspace/HTTP/cache/CPU and member-settlement mechanisms;
no helper-mirror, invocation-count, layout, wording, row-order, snapshot or PTY
test is introduced.

1. Load an exact Keeper's Tools surface in workspace A while its inventory is
   delayed. Preserve the original group generation and read epoch. Catalog and
   async observation should be independently eligible; retain all three actual
   outcomes rather than dropping the delayed inventory from the cohort.
2. Fail catalog after async observation succeeds. The async value should remain
   available, catalog should retain its last good value plus failure, and the
   inventory member should remain pending until its own outcome. An unavailable
   switch is a separate failed group, not a successful empty response.
3. Explicitly refresh or select another Keeper while the old group is pending.
   Release the old results in different orders; they must neither settle the new
   group's pending members nor replace its values. A normal automatic poll for
   the same pending Keeper still shares its existing group.
4. Replace A with same-endpoint B and later return to A. The actual expected-root
   precondition and receipt/cache checks must refuse B's data for A, while the
   retired completion envelope must not borrow the successor read epoch. Include
   cache-hit/304, failure, cancellation, interruption and unfinished outcomes.

The Before/After comparison must match Keeper, workspace, data/cache state,
request order and resource conditions. Record dispatch, transport admission,
decode, UI admission, input and paint separately. Three independent results
must not be relabeled one simultaneous snapshot. Loading/query completion is
not original Ask-to-Task-to-useful-work completion.

Performed evidence is limited to source/interface inspection, OCaml parsing,
diff and changelog checks. No typing, test, CI, native/model/PTY/controller/report,
installation, restart or live configuration execution is claimed. Current-head
independent source approval, merge, installed binary and runtime/UI evidence
remain separate boundaries.
