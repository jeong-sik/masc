# Reusing exact answer-recovery evidence windows

Source change over `ddd7318ce822799e130a496d490a7e0f27cc313a`. Parsing only;
typing, scenarios, runtime latency, TUI paint and matched Before/After are unverified.

Related PR: [#44222](https://github.com/jeong-sik/masc/pull/44222).

## As-Is / To-Be

Startup and the existing maintenance tick recover canonical answered questions.
The ledger already has an append-validated per-file evidence cache; this change
does not claim that every question reparsed the full ledger. Each question did
repeat its preflight window's directory/file validation and evidence-set merge.

Recovery now builds an immutable demand index from canonical answer times, then
captures each Keeper/window on its first actual valid-source demand. The same
UTC-day window shares that immutable result in this pass, including read failure.
Different Keepers and different windows never share it. Windows appearing once
in discovered answered rows do not retain large proof snapshots; original question order remains intact and no
eager I/O barrier waits for all windows before the first answer can reach intake.
The small demand index is additional metadata preparation and allocation.
If the platform cannot convert a finite answer timestamp to a UTC calendar day,
planning leaves that row unindexed and delivery reports its original-row error;
the newly eager metadata fold cannot abort independent answer delivery for it.
This calendar-error path is source-only and unexecuted.

The opaque snapshot and single-source query now share the existing append-aware
reader and one typed proof lookup. Proofs retain decoded stimulus kinds rather
than a second string-key representation. The existing canonical decoder,
positive-proof precedence, incomplete-absence refusal, cursor invalidation and
uncached fallback remain. Snapshot coverage is aligned with the existing
single-source contract: positive times cover their UTC day and all later stored
partitions; nonpositive times cover the whole store. No current-date truncation
is used for this evidence. Snapshots retain neither raw answer nor reaction text.

This is preflight observation only. Negative preflight still reaches the queue
owner's fresh once-only delivery check and lifecycle fence; an already-present
result still receives the existing fresh check before a live wake hint. No
answer write is replayed. Later file changes do not mutate a frozen observation,
and a new pass replaces all pass-owned results. Positive observations, enqueue,
answer consumption, original Task phase and useful work remain separate facts.

## Source Before/After

Let N be valid answer-source preflight queries and W their distinct
Keeper/canonical-window pairs within discovered canonical batches.

| Boundary | Before | After |
| --- | --- | --- |
| Preflight window preparation calls | N | W; same-window lookups share the captured result |
| Already-delivered history in one window | Repeated window validation/merge | One capture and typed lookups |
| Unresolved answer's mutation authority | Fresh owner-lock check and intake fence | Same fresh checks |
| Failed old window vs later answer window | Independent current reads | Independent pass-owned captures |
| All-distinct discovered answer windows | No pass snapshot retention | No large pass snapshot retention; adds a small demand index |
| Recovery summary | Answer/delivery counts | Adds logical evidence-window capture count |

`evidence_window_reads` counts capture calls, including failures, not physical
file reads, CPU time or completed work. Existing enqueue INFO summaries include
it; idle summaries use the existing lazy routine policy, without a new timer or
knob. Formatting is deferred when routine logging is disabled. Enabled logging,
typed proof wrapping, demand indexing and retained shared snapshots all belong
in actual comparison costs. No latency, allocation, I/O-byte or speedup result
is claimed. W=N has no preparation-call reduction. Fresh intake reads remain
additional work and are deliberately not counted as eliminated reads.

## Authored scenario, unexecuted

The existing real recovery/corruption scenario now mixes two old damaged-window
answers, two same-day fresh answers and another Keeper using the same source ID
and old window. It checks exact durable pending identities, independent failures,
the second Keeper's terminal evidence, repair on a later pass, original Task
association and unchanged canonical answer logs. Existing snapshot scenarios
already cover typed-source isolation, frozen positives after mutation, fresh
evidence refusal and calendar-window isolation; they remain unexecuted here.
No invocation-count, helper-mirror, wording/layout/row-order/UI-snapshot/PTY test is
added. These source changes do not establish original Ask-to-Task useful work,
Composition/held-job continuity, usable input or any of the six-axis goal's
matched actual cohorts. Failed/cancelled/interrupted/unfinished samples remain
required when runtime measurement is authorized.
