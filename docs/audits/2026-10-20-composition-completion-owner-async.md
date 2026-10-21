# Independent original Composition completion recovery

## As-Is / To-Be

Server startup/maintenance awaited the whole Composition completion outbox
before owned-job, prepared-continuation and Ask recovery. Each request could
wait for terminal proof, its Keeper's lifecycle-intake/queue lock or durable ACK.
One yielding recipient wait therefore delayed independent recipients and the
remaining maintenance work.

| Boundary | Before | After |
| --- | --- | --- |
| Server recovery call | Joined complete outbox delivery | Join validated identity discovery, reserve workers, continue without delivery join |
| Independent Keepers | One serial outbox fold | Independent original-owner batches |
| Same Keeper | Directory discovery order | Same relative discovery order in its worker |
| Original ownership | Read obligation then terminal proof in one fold | Discover original root/request/recipient, reread obligation before proof and reject changes |
| Terminal/journal/waiting proof, queue and ACK | Existing canonical checks | Same extracted core; no execution replay |
| Repeated pulse while active | Original maintenance still waiting | Do not replace active batch; later pulse discovers new obligations |
| Summary | Joined report over directory names | Per-owner settled candidate report; discovery failures reported separately |

The synchronous `flush`/`reconcile` APIs remain one-round operations with their
original report semantics. Their existing terminal, journal, released-waiting,
delivery and ACK code is shared with the new worker path. Canonically released
waiting attempts still retire their attempt notification without announcing a
logical Composition terminal. No original DAG, node, output or source Task is
reconstructed from current state.

## Resource continuity and costs

The discovered pending value is private and binds its canonical root, original
request and recipient. It is a scheduling hint. Actual recovery rereads that
obligation and rejects a changed identity before entering the original canonical
terminal path. A removed/ACKed obligation is retired without borrowing the old
hint's result. Producer checks, ambiguous/unavailable proof refusal, journal
completion disposition, waiting acknowledgement under the request transition
lock, fresh queue-owner evidence/lifecycle checks and durable ACK remain.

One server-lifetime supervisor uses the existing server switch. A worker yields
before recovery, preserves its owner's original order and remains active through
observer and cancellation cleanup. No same-owner replacement is admitted while
it waits. Malformed discovery records remain visible without hiding valid other
recipients; a later failed discovery leaves existing workers alone. Scheduling
callbacks occur outside storage-error conversion. Switch checks precede discovery,
reservation and scheduling; cancellation is re-raised and can still wait for
protected physical I/O. Unexpected worker exceptions leave durable obligations
for a later pulse without a fabricated report. Observer failure does not undo a
committed notification.

Discovery still reads the complete pending partition before reservation. A
normal scheduled obligation is read once for identity discovery and again for
fresh worker validation, compared with one read in the joined path. Active-owner
discovery also still reads identities. Private pending records, owner grouping,
active entries, child fibers, clocks and optional logs add work and memory.
Shared CPU/I/O/pool/logging pressure may prevent useful overlap; no physical
parallelism or speedup is established. Same-owner waits remain. There is no new
pool, timer, retry interval, concurrency cap, cache, launch or replacement request.
The direct `on_worker_settled` producer callback is unchanged and can still await
its own notification; this unit changes server recovery only.

## Observation

The canonical Keeper and reservation clock connect routine/lazy reserved,
started, settled, interrupted and raised events. A normal scheduled owner has
three detail sites. The reservation clock excludes discovery. The worker
interval includes obligation rereads, canonical/journal checks, queue waits,
delivery and ACK; it is not pure disk time. Settled marks fold return before
observer/active cleanup, not worker exit, logical execution completion or useful
work. Reports keep existing outcome meanings: delivered can acknowledge an
already accepted source and does not count only new queue entries. Owner report
inspection covers valid captured candidates; discovery failures are separate.
Discovery failures identify pending filenames; worker failures identify original
validated request IDs. An unreadable record is not assigned an inferred owner.
Default routine suppression avoids formatting/emission but not fibers/clocks or
discovery costs. Missing final events remain unfinished, never zero-duration
success. No result body, question/answer text or Task contents are logged.

## Authored compound scenario, unexecuted

Real asynchronous producers durably prepare outbox obligations and publish
canonical outputs/provenance. Their switches join before recovery. Holding
alpha's actual lifecycle-intake mutex must allow beta's original completion to
commit and ACK. A later alpha request discovered while active cannot replace
the first batch. A real shutdown fence installed before unlocking must refuse
the first original notification; after rollback, a fresh pulse must deliver both
original requests and retain their canonical output/Task provenance. A retained
beta hint after ACK must return retired and leave beta's exact queue unchanged.

This uses actual async/store/intake/queue APIs, without a replacement recovery
callback or invocation counter. It does not execute prepared/nested/dynamic DAGs,
an OS file-lock stall, server maintenance, Task consumption, TUI paint or input.
Recipient mutation refusal and inherited prepared-waiting behavior are
source-inspected, not newly executed. Six direct OCaml files receive parsing-only
checks. No typing, warnings/linking, build/tests, CI, native/model/audio/controller/
report run, installation/restart/live writes, independent approval or merge.

## Full goal remains open

Original Ask → original Task → useful work; exact preparation attribution and
frozen discovery reuse; ordinary/nested/dynamic/effectful Composition resource
continuity; held-job/shared-backend continuation; cold usable input and TUI
readability/visibility; matched actual Before/After all remain open.

Actual cohorts must separate discovery, proof/queue/ACK waits, notification,
original resumed execution and original Task progress; include added rereads and
contention. Retain failed, cancelled, interrupted, refused, not-started and
unfinished samples. No elapsed-time result or whole-axis completion is inferred
from this source dependency change, authored scenario or owner summary.
