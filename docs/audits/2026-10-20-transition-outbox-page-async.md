# Transition outbox page without a maintenance join

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Startup/periodic page | Join discovery plus selected owner page in strict executor | Reserve server-switch worker, then continue maintenance |
| Active page | Maintenance waits for return | One active page; pulses coalesce without replacing cursor/source |
| Cursor | Commit after result logging returns | Commit actual returned next cursor before observation |
| Unobserved/cancelled page | Retry from prior cursor | Same; completed effects may already exist |
| Strict executor missing | Typed empty page, unchanged cursor | Same original primitive result |
| Owner/transfer authority | Claim, ordered shutdown fences, target projection before source retirement | Original implementation unchanged |

The supervisor binds the original maintenance base path and already validated
Keeper batch size. Each worker captures its cursor and startup/maintenance
source, yields, then calls the original complete page operation. Owner ordering
and within-page waits remain serial. New durable owners appear on a fresh page;
no directory snapshot, result or effect permission is cached. Actual returned
pages own cursor progress even if the subsequent observer fails. No page
returned means no fabricated cursor advance. Cross-process retries still use
the original durable identities and projection checks.

Active lasts through the observer and cancellation cleanup. Switch checks precede
reservation/fork; failed scheduling releases active. Structural cancellation
propagates and physical cleanup remains with the strict executor. Unexpected
exceptions leave durable recovery work and the last observed cursor available
for a later pulse, without inventing a page report. Default result logging
retains its existing outcome fields and startup/maintenance suppression policy.

Routine reservation/start/settled/interrupted/raised clocks identify this page
by original base path, source and process-local reservation time. Settled means
the page returned and cursor was committed, before observer and active release;
it is neither worker exit, physical append attribution nor useful Task work.
Three normal phase sites add optional logs; suppressed routine output still
incurs fibers, cursor capture, active bookkeeping and clock reads. Empty pages
also incur scheduling. Shared executor pressure and within-page waits remain.
There is no new executor, timer, retry interval, cap or inline fallback.

## Authored compound scenario, unexecuted

Three actual accepted-transfer source outboxes share their original target.
Hold the first owner's real intake mutex while reserving a page and committing
an independent durable queue item. The first page retains startup attribution
through a coalesced maintenance pulse. After release it projects the original
target before retiring source; an observer then raises. The next actual page
must use the advanced cursor. A real second-owner shutdown reservation retains
its outbox and exact operation ID while the third owner converges. Roll back
the reservation, complete the lexical sweep and wrap, then recover the original
second transfer. A fresh page must not duplicate original target stimuli.

This uses the actual strict executor with two fixture domains, durable stores,
intake/transfer/shutdown/ledger paths and cursor pages. No replacement projector,
invocation counter, timer, polling or screen assertion is added. Independent
delivery while a page cannot finish does not prove the exact blocked-worker
entry instant or overlap under a saturated single-worker deployment. Mid-page
cancellation, executor-unavailable recovery and OS-level stalls are unexecuted.

Four direct changed OCaml files receive parsing-only checks, interface first.
No typing/warnings/link/build/test execution, CI, native/model/controller run,
installation/restart/live write, independent approval or merge is established.
All six original axes remain open: original Ask/Task useful work; exact preparation
and frozen discovery; ordinary/nested/dynamic/effectful Composition continuity;
held-job/shared-backend continuation; cold usable input and TUI readability/
visibility; matched actual Before/After retaining failed/cancelled/interrupted/
not-started/unfinished samples. Source joins do not establish latency or throughput.
