# Start with the current Task's declared Tool schemas

A current Task's exact Composition Skill already names the work's callable and
ordinary node Tools. The bundle supplies those schemas on the first request when
the same full Skill identity and content revision are executable on the frozen
turn surface. A declaration permitting deferred loading does not require another
model exchange to rediscover that existing selection.

| Case | As-Is | To-Be implementation |
|---|---|---|
| Current Task pins an available exact composition with deferred schemas | Model loads the callable or its node Tools before using them | First request carries those schemas |
| Reference belongs only to another held Task | Ordinary deferred loading | Ordinary deferred loading |
| Skill revision differs or a node is denied on the turn surface | Unavailable composition | No schema preload from that reference |
| Unrelated deferrable Tool or attached service | Ordinary deferred loading | Ordinary deferred loading |
| Schema is provided | No Skill activation | No Skill activation; actual execution retains the original recorder |

Selection comes from the immutable Task provenance in the turn activation frame.
Executable entries come from the same frozen capability surface as dispatch.
Matching uses the complete Skill reference, not a display-name prefix, source
path or another inventory scan. The original declarations are retained; initial
delivery is derived from the current work. No Task or Skill file is reread here,
and no activation, loader receipt or Tool execution is fabricated.

The source feature scenarios construct the actual public bundle with deferred
compositions, verify initial callable schemas, execute the selected inline Skill
and inspect its exact durable activation. They also cover another current Task,
absent current Task and a denied leaf. Syntax checks are not executed-test proof;
record the focused CI result and exact head separately.

For Before/After, freeze the same Task, Skill source, provider, model, prompt and
Tool behavior. Retain actual loader calls, model POSTs, serialized request bytes,
first useful action, completion and failed/unfinished attempts. Supplying more
schemas can increase the first request's bytes while eliminating a separate
loader exchange. Several Tool loads may already share one exchange, so a lower
Tool-call count alone does not establish fewer model POSTs or lower latency.
Synthetic protocol evidence and real-model cohort measurements remain distinct.

The native preparation driver writes `<receipt>.stages.jsonl` and emits
`PREPARATION_STAGE` metadata before and after workspace/snapshot/owner setup,
Keeper registration, Task claim, bundle construction, original job start/result
collection, source admission and the actual Keeper cycle. Records carry epoch and
process-local monotonic clocks; job indices identify fixture occurrences. A
missing return record identifies an unfinished stage without inventing a timeout,
retry or completion. Cancellation preserves that unfinished evidence and propagates.
No model text, credential or request body is added to this journal.

These observer writes are synchronous evidence I/O. Matched timing comparisons
must use the same observer on both candidates and report its presence. The
synthetic scenario checks the first actual POST's Tool names and the physical
Tool-call ledger to establish that the Task's declared result Tool needed no
loader exchange; the configured real-model cohort still requires measurement.
