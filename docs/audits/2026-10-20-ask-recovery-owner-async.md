# Independent canonical Ask recovery owners

## Source finding

Server startup and each maintenance tick called `Keeper_ask_answer_wake.reconcile`
to completion. Its deterministic discovered-log fold recovered one Keeper after
another. An unresolved answer reaches that Keeper's real lifecycle-intake mutex
and durable queue file lock. A yielding wait there therefore delayed recovery of
other independent Keepers and the remainder of this maintenance pass.

The source improvement is independent delivery scheduling. It does not prove
that the original answer was consumed, the linked Task progressed, or the live
TUI Loading incident is resolved.

## As-Is / To-Be

| Boundary | Before | After |
| --- | --- | --- |
| Server maintenance | Await every discovered answer delivery | Discover logs, reserve independent Keeper workers, return without joining delivery |
| Alpha's intake wait vs beta | Beta starts after alpha's batch returns | Beta's original batch can run while alpha waits |
| Answers within one Keeper | Original canonical row order | Same row order in that worker |
| Repeated maintenance while active | Previous synchronous call still blocks this loop | Active owner is not reserved again; later pulse rereads after settlement |
| Evidence-window reuse | One immutable Keeper/window observation in one recovery pass | Same helper and pass-local reuse in each original owner batch |
| Mutation authority | Fresh owner-lock evidence and lifecycle fence | Same authority; captured rows never replace those checks |
| Report | One joined fleet summary | Per-owner settled summary and reserved/started/settled/interrupted/raised diagnostics |

The one-round `reconcile` API remains synchronous with its original report order
and counts. Both entrypoints use the same extracted row-recovery implementation.
The server uses one supervisor and its existing lifetime switch at startup and
maintenance, not one new controller per tick.

This removes the cross-Keeper delivery dependency from the server call path.
It does not reduce directory reads, canonical log decoding, window captures,
queue checks or file writes. Shared filesystem, CPU, logging and pool pressure can
still delay independent workers; a cooperative fiber is not physical parallelism.
No latency, throughput, allocation or speedup percentage is measured here.

## Ownership, failure and remaining waits

Canonical discovery still completes before reservation. The canonical owner is
read and validated by the original strict store, never inferred from its
sanitized filename. Each owner worker receives those original rows. The actual
queue commit retains its independent latest evidence/lifecycle checks and once-only
source identity. No question is answered again and no current Task is substituted.
Per-Keeper row order is retained; cross-Keeper completion order may now differ.

An active owner remains reserved through worker/cancellation cleanup. A worker
yields before recovery so inline filesystem work cannot enter the producer's
reservation path. New answers discovered while that owner is active wait for a
later existing pulse; they do not mutate the captured batch. A failed or changed
later discovery leaves existing workers alone. There is no pending-row cache,
follow-up timer, new retry interval, arbitrary concurrency cap or replacement job.
Per-owner active entries and retained row batches add memory; new child fibers,
clock reads, diagnostics and overlapping I/O add work. Existing resource owners
remain responsible for admission. There is no new pool.

Typed row failures remain in the original owner's report. Unexpected worker
exceptions are logged without a fabricated report and leave the canonical source
for a later pulse; observer errors do not undo committed deliveries. Cancellation
is re-raised and the owning switch still joins protected physical I/O. A cancelled
switch is rejected before discovery and again at reservation/scheduling. No
bounded cancellation or shutdown is claimed. Same-Keeper intake waits and complete
discovery remain possible indefinite waits.

The diagnostics identify the original canonical owner and monotonic reservation
clock. Reservation, worker start and batch settlement are distinct. Settlement
may include refusal/failure and never means answer consumption or useful work.
The reservation clock excludes discovery; the worker interval includes evidence,
intake waits, queue I/O and wake-hint work, rather than pure disk or lock duration.
A normal scheduled batch has three routine event sites, replacing the old idle
fleet summary with owner detail. Formatting/emission follows the existing lazy
routine policy; active checks, fibers, clocks and captured rows still cost work
when detail is suppressed. Enqueued summaries and row failures remain visible.
The settled event marks the row fold's return before the report observer and
active-entry cleanup; it is not worker-exit or physical-cleanup proof.
No answer/question body, responder data or Task contents are added to these logs.
Missing final events remain unfinished; no zero duration is supplied.

## Authored compound scenario, unexecuted

The actual persistent Ask/queue scenario holds alpha's real lifecycle-intake
mutex using the production intake API. A server-style pulse must allow beta's
original Ask source to commit while alpha is still blocked. It then records a
later alpha answer and pulses again while the first batch remains active. A
real shutdown fence installed before releasing the mutex must refuse only the
original captured batch. After rollback, another pulse must read both original
alpha answers afresh and deliver their exact continuations, preserve the original
Task association, keep beta's already committed source once, and leave canonical
answer logs unchanged.

This scenario uses no replacement recovery callback, synthetic store, invocation
counter, UI wording/layout/row-order/screen snapshot or PTY. It does not execute
an OS-level file-lock stall, the server maintenance loop or Task consumption.
It is authored only. Source inspection and four direct OCaml parsing checks are
the permitted evidence; no typing, warning check, build, test execution, CI,
native/model/audio/controller/report run, installation/restart/live write,
independent approval or merge is performed.

## Whole goal and actual comparison

All six original axes remain open: original Ask → original Task → useful work;
exact preparation attribution/frozen discovery reuse; ordinary/nested/dynamic/
effectful Composition resource continuity; held-job/shared-backend continuation;
cold usable input and TUI readability/visibility; matched actual Before/After.
This unit removes one server recovery dependency and adds owner-phase observation.
It is not evidence of completion of any whole axis.

Actual comparison must separate discovery, per-owner intake/queue wait, committed
delivery, original turn/Tool activity and original linked Task progress. Retain
failed, cancelled, interrupted, refused, not-started and unfinished attempts;
include the added work and shared contention in matched source/runtime/config
cohorts. A batch completion or new summary must not become a useful-work latency
sample. Those executions remain unverified under the current code-only scope.
