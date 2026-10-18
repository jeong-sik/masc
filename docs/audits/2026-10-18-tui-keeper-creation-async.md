# Asynchronous Keeper creation

Source baseline: `5c92fcff9bde6181349facf8db9a30f238416a30`.
Scope: Keeper creation after the external editor returns, its HTTP outcome,
original declaration/focus ownership and metadata/input continuation.

| Boundary | Before | After |
| --- | --- | --- |
| UI input handler | Identity preflight and creation POST execute before returning | Both HTTP call sites execute in an owned fiber |
| Post-dispatch transport failure | Generic string failure | Explicit outcome unconfirmed, no automatic resend |
| Workspace withdrawal | Synchronous handler prevented ordinary navigation interleaving | Original receipt/declaration retained; new authority cannot borrow it |
| New declaration while an earlier creation finishes | UI could not process the next edit while HTTP waited | Independent form owners; earlier success cannot clear a new draft |
| Input while creation finishes | HTTP blocked the input path | Next input or already-queued input detaches automatic chat opening |
| Confirmed creation | Synchronous result launches metadata refresh | Original current-origin receipt launches metadata refresh; existing name/coverage barrier still gates input |

The two blocking HTTP call sites leave the UI handler. This is a source dependency
comparison, not a measured request count or latency reduction. Network requests,
server work and metadata discovery still take time. The external editor remains
an intentional terminal handoff.

The HTTP helper uses the existing typed mutation result: 4xx refusals differ from
unanswered/5xx/malformed success responses. The canonical creation receipt still
must name the exact Keeper. Only confirmed creation clears its own form. The
attempt ledger retains unresolved declarations and uncertainty; successful
explicit create-only retry can release that target's retry bodies while leaving
the original receipt unchanged. Nothing retries automatically. Session-local
retention is not durable crash recovery or a status query proving an unknown
server effect.

Authored, unexecuted feature-state cases cover interleaved creation/editing,
duplicate target admission, late progress/receipt rejection, a full notification
queue cancelled after terminal publication, withdrawn read
epochs, A-to-B-to-A authority changes, retained uncertainty and explicit retry.
They check saved state and decisions, not TUI text or row layout. The queue scenario is authored, not an executed
cancellation result. A request-owned atomic terminal slot avoids protecting a
blocking write to the shared 32-item queue during shutdown. The existing drain
can recover that receipt under its own deadline; admission retires the pending
slot. Existing
create-only/envelope and metadata-coverage scenarios remain separate evidence.

Parser checks cannot establish typing, real fiber/HTTP cancellation, executor
fairness, process-restart continuity or rendered input responsiveness. Measure
matched editor-return-to-first-usable-input and creation-to-metadata observations
with original request identity and comparable clocks. Keep refused, unanswered,
interrupted, cancelled and unfinished attempts in the cohort. No installed,
runtime, painted UI or measured speedup result is claimed by this unit.
