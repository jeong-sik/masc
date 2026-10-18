# Selected Keeper metrics observations

Source baseline: `e760cad79b511ce47d5f386ae02f6537e4185fed`.
Scope: detail/Logs metrics reading, revalidation, activity summary and ownership.

| Boundary | Before | After |
| --- | --- | --- |
| Open detail/Logs, refresh, cadence | Four paths invoke the synchronous loader | Shared owned I/O reader; UI applies immutable results |
| Same-key poll during a read | Later UI processing waits for that handler | Current read shared |
| Detail tabs without the activity summary | Detail opening/cadence still read metrics | No metrics request while the source is not displayed |
| Explicit refresh during a read | Handler could not process it while waiting | One accumulated follow-up after success or failure |
| Read setup | Construct workspace configuration and use writer-store accessor/cache | Resolve the canonical metrics location directly; no writer directory initialization |
| Failed revalidation | New empty/error snapshot replaces previous rows | Last observed rows survive with an explicit failed refresh |
| Selection/read-scope change | Synchronous completion made async ownership unnecessary | Workspace/key/ticket/read scope required; late values/cleanup cannot borrow a successor |
| Initial activity/log display | Unread and empty records share the empty state | Unread, reading, failed, partial, stale and observed-empty are distinct |

Four synchronous call sites become scheduling sites. Per-read workspace
configuration and writer accessor calls change from one each to zero. These are
source-path counts, not measured disk operations, request counts or latency.
The existing physical row window is unchanged and centralized. Existing strict
chronology, physical damaged-row accounting and misfiled-row diagnostics remain.

The shared immutable fetched model owns values and generations. A request owns
the read scope and cancellation token; same-key source errors preserve its
previous snapshot. Explicit refresh demand settles once and can schedule one
follow-up even after failure. Suspension retires pending requests while retaining
same-workspace observations; an A-to-B-to-A authority change cannot revive an old
read. Neither metadata admission nor metrics completion claims that a Keeper
accepted input or advanced its Task.

Three authored state scenarios cover selection changes/late cleanup, refresh
coalescing with partial rows and failed revalidation, and workspace suspension
with resumed scope and missing selection. A filesystem scenario checks that a
read of a missing canonical Keeper metrics store does not initialize writer
directories. All four are unexecuted. Obsolete synchronous selection helpers and
their helper-only assertions are removed; physical storage/error cases remain.

Parser-only checks cannot establish typing, actual executor cancellation,
resource fairness, visible rendering or faster input. The TUI initializes its
executor before entering the loop; the common pool-absent inline policy is
unchanged. Measure matched first-usable-input, detail/log opening and source
waits separately. Retain failed, cancelled, interrupted and unfinished reads,
with source identity and comparable clocks. Installation, runtime continuity,
painted UI and measured speedup remain unverified.
