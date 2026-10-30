# Ask receipt publication independent of mailbox capacity

Source comparison base: `9830f1c429007537858c971c3c32b11389ae3d93` (#43779).
These are source boundaries, not executed runtime or latency measurements.

## As-Is / To-Be

After obtaining the answer POST Result, the worker used the shared
`Eio.Stream.add` before starting canonical question reread. The installed Eio
Stream interface states that add waits when full. A saturated mailbox could
therefore delay reread, and worker cancellation at that publication boundary
could leave no early Result for the UI to recover.

The original submission now owns a once-only atomic receipt cell. Actual POST
return publishes its Result and monotonic timestamp immediately, even before
the call observer logs. The outer operation also publishes actual pre-POST
errors; a later attempt cannot replace the first Result. Canonical reread then
continues with no early queue publication. Synchronous worker cleanup closes an
empty cell without inventing a receipt; returned facts remain intact. The same
closure handles withdrawal before worker entry.

| Source boundary | Before | After |
| --- | --- | --- |
| Queue adds after POST return and before canonical reread | 1 | 0 |
| Early result messages placed in the shared queue | 1 | 0 |
| Final completion message | 1 | 1 |
| Actual POST Result independent of queue delivery | No owned cell | One original-request cell |
| Worker cancellation after actual Result | Early delivery may not occur | Original fact remains in session state |
| Worker closure without observed Result | No receipt | Still no fabricated Result |
| Answer POST and canonical GET effects | Existing sequence | Same sequence |
| UI identity-withdrawal ordering and final admission | Queue first | Queue first |

UI drain recovers returned pending cells after queued messages. Final completion
also recovers its original cell before its usual receipt fallback and reread
admission. Recovery reads the registered owner, not a substituted request payload;
it consumes pending delivery once. Ordinary receipt/feedback ownership and
original Ask follow-up stay separate from fact retention. Old-workspace facts
gain no current feedback or read authority. All request owners remain in session
state while completed/closed owners leave the pending scan; old completed history
is not rescanned for every UI receipt poll.

`Ask_answer_receipt_ready` is a UI recovery signal carrying its owner, not a
producer message carrying another copy of the Result. The old early-result
constructor is removed. The receipt log includes actual `result_observed_ns`
when available. Generic result-wait logging describes time before UI application,
since a recovered result was not necessarily waiting inside the shared mailbox.

This does not guarantee instant feedback while that mailbox remains full.
Queued identity withdrawals still precede recovery; the original frame drain
budget and shared capacity are unchanged. Final completion may still wait for
queue space. The change removes its predecessor as a condition for starting
canonical reread and preserves actual receipt facts before cancellation. It
does not make process-local state restart-durable or prove useful Keeper work.

No extra HTTP/model calls, Tool effects, publication fibers, protected queue
waits, request generations, cache, timeout, retry, configuration or screen row.
The only finalizer operation added is synchronous atomic closure. Original
workspace checks, mutation/draft gates and exception/cancellation propagation
remain. There is no automatically replayed answer.

## Authored scenario and evidence limits

A compound request/state/protocol scenario uses a real full Eio stream. Its
fixture producer publishes through the production receipt cell, advances a
downstream fixture step, then blocks on notification. Cancellation must retain
the Result; workspace withdrawal must leave it recoverable without current
feedback. The scenario also covers once-only recovery, canonical owner vs
substituted cell, closure without a fabricated Result, retained session history
and a replacement request's independent unknown outcome. It does not call a
real answer endpoint or canonical HTTP reread. Existing three submission
fixtures carry the owned cell. No wording/layout/row-order/snapshot/PTY test.

The scenario is authored, unexecuted. Author checks are parsing-only and
diff/changelog hygiene. Typing, assertion execution, actual queue saturation,
HTTP/cancellation behavior, independent review, CI, native/model runs,
installation/restart, UI paint and matched speed remain unverified.
