# Board post-list availability and continuity

Source baseline: `d9718e066deaabe3543af8db8f151a38c799e0db` (#43736).

## As-Is / To-Be / Before and After

| Aspect | Baseline | This layer |
| --- | --- | --- |
| Rendered list data/status | Raw posts, read marker and error in three fields | One Fetched observation contains rows and availability |
| First owned post read | Same unread page as never requested | Loading from the actual posts slot |
| Posts settled while census pending | Logical Board pending; post page lacks an independent pending model | Posts received, census pending; distinct slot projections |
| Received empty / initial failure | Read marker plus separate error | Ready empty / Failed, with no invented rows |
| Reread/failure with existing rows | Rows retained; refresh not identified on list/sidebar/palette | Retained rows and failure with last-observed qualification |
| Detail response | Matching row enriched, no rerank | Same row semantics; also preserves list failure and pending ownership |
| Terminal reserves but cannot apply posts | No list result-specific missing observation | Unavailable with retained rows until actual application |
| Selected identity and compose input | Existing identity reconciliation/input lifecycle | Same reconciler and draft retained across list results |
| Existing Board GET readers / added HTTP | 2 / 0 | 2 / 0 |
| Added screen rows / request generations / clocks | 0 / 0 / 0 | 0 / 0 / 0 |

This is a source-derived state and decision comparison, not a timing measurement.
No retry, timeout, action cap, configuration knob or IO concurrency policy changes.
The generic empty-page enum remains for other surfaces; Board directly projects
the existing Fetched view categories plus its original dataset pending status.

## One observation and its direct consumers

`board_listing` replaces the raw posts/read-marker/error combination. All list,
sidebar, related-post, search, palette, selection and input consumers read its
same available rows. Failure retains a successful empty or nonempty observation
as Stale; failure without a value is Failed. Pending comes from the original
Board_posts slot, so census arrival/latency does not impersonate a post result.

The list and detail sidebar use an existing heading for pending/retained status;
existing failure rows keep the actual diagnostic. Palette candidates retain their
post IDs while qualifying previous observations. No wording/layout/row-order
test is added and no extra screen row is introduced. Visible behavior is not
verified by these source projections.

The existing pure selection reconciler is reused from the state transition; its
direct library dependency is declared. Successful lists retain identity-based
cursor/detail behavior. Detail receipt maps one matching row in a Ready or Stale
observation, keeping failure, rank and pending source ownership. It cannot establish
whole-list availability or remove an exact-ID detail omitted by a filtered page.
Compose input/reply/attachments are not changed by list transitions.

## Missing results, withdrawal and notification ownership

Terminal dataset reservation and all production collector-completion paths now
cover posts as well as census. Only still-owned missing data is marked unavailable;
new opaque owners protect successor observations. Actual admitted application
replaces that missing-result state. Refresh/workspace/read-proof admission remains
outside these state transitions. Workspace withdrawal clears observations and
candidates together. Missing result is not proven worker cancellation or exit.

The last emitted list-error notice is separate output metadata. Synthetic terminal
unavailability does not reset it or repeat an unchanged actual error notice.
Success and workspace withdrawal reset it, preserving the prior notification
policy. UI availability never reads this notification record.

## Evidence and remaining scope

Three former simple page cases are replaced with three authored, unexecuted
feature/state scenarios: initial loading/empty/failure and independent census;
retained rows through retry/detail enrichment plus selection and compose continuity;
and missing terminal data, old cleanup and workspace withdrawal. Existing palette
and key fixtures use the canonical observation. Assertions cover stored data,
owner decisions and selection, not UI text/layout/order/snapshot output or PTY.
Eleven changed OCaml files passed parsing-only checks; exact-head hashes and diff/
changelog metadata are recorded separately. No Dune/typecheck/tests, CI dispatch/
watch, native/model run, install/restart, live config write or own merge is run.

Query-origin provenance for retained rows after changing sort/hearth remains a
separate inspection: this layer does not claim each retained row matches the
newly requested query. The full preparation/discovery, cold-start input/readability/
observability, Ask-to-original-Task/useful-work, resource-owned Composition,
held-job/shared-backend and matched Before/After objective remains active. Retain
failed/cancelled/interrupted/unfinished samples. No measured speedup, independent
approval, merge, installed/runtime/paint proof or whole-goal completion is claimed.
