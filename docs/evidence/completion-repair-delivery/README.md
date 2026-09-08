# Internal completion repair delivery

This change implements one boundary of the reliable-change product loop:
**committed review rejection → durable producer input**, including server restart
and delivery failure. It does not claim successful autonomous repair or whole
G5 acceptance.

Previously the Task verdict committed first, and system/HITL callers then
attempted to wake the producer. A crash between those operations, or a queue
write failure, left an InProgress task outside the awaiting-verification boot
scan. No internal worker retried the missing delivery.

The authoritative backlog now stores `pending_completion_rejections` in the same
write as the rejected verdict. Each obligation pins task, verification, producer,
reason, authority and commit time. The common commit hook wakes a separate
delivery scan inside the completion-authority daemon. Boot starts that scan too.
A failed delivery uses the existing maintenance interval to retry the obligation;
it does not call a model or repeat verification. System and HITL commits share
this path.

The consumer reuses the existing typed Keeper rejection queue. Only durable
queue admission allows exact task+verification acknowledgment of the backlog
obligation. A live wake failure can leave the Keeper inactive while its input
remains durable; logs distinguish that outcome. Paused or unregistered Keepers
are not forcibly started. New submissions, release, cancellation and terminal
transitions retire superseded obligations. A stale acknowledgment cannot erase
a newer verification's pending repair.

Delivery is **at least once**, not exactly once: if the queue input is consumed
and the process dies before acknowledging its source, recovery can deliver the
same verification-keyed information again. The input grants no mutation or
completion authority. Current Task ownership and lifecycle remain authoritative.
An already-read pending snapshot can race a task transition; the queued reason
can therefore be historical. This change does not claim stale-input suppression
or automatic takeover from an unavailable producer.

`test/test_completion_repair_delivery.ml` exercises real workspace commits and
persisted queues. Cases include system/HITL commit without a consumer, native
daemon boot and commit-hook delivery with zero model invocations, corrupted
queue retention/retry, enqueue-before-ack pending deduplication, approved verdict,
resubmission/stale verdict/stale acknowledgment, and corrupt outbox decoding.
These behavioral tests are submitted to CI; they have not been run locally.
Syntax and diff checks are not behavior proof.

The backlog contains a new optional persisted field. Every upgraded writer
preserves it; older binaries with a strict old decoder must not be run as
concurrent writers over a backlog containing pending obligations.

The end-to-end G5 probe must let MASC carry the rejection into a real Keeper
turn, repair and resubmit without external repair instructions. That real-model
product proof and operating-binary deployment remain acceptance work.
