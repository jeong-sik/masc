# Request admission notices

`KEEPER_CHAT_OPERATION_ACCEPTED` is a receipt for the submitted request. It has
no journal sequence and does not establish that the Keeper consumed the input.
The stream route sends it before draining buffered execution events. Since the
owner can start execution before the route stamps this receipt, the receipt's
server timestamp can be later than the answer's timestamp. Copying its notice
to client-clock session history therefore loses causal order even without
server/client clock skew.

The TUI log now retains the first and latest acceptance as scalar metadata,
separate from execution entries and the replay cursor. The first receipt owns
the historical notice; later receipts update the admission/queue snapshot.
Replayed receipts cannot move or duplicate the original notice. A local priority
intent that receives Running/Settled admission retains its existing “no other
turn was interrupted” feedback in a separate scalar flag. This flag records the
callback decision, not a fabricated server event or an execution result.

The transcript projects this metadata as an `Admission_of_request` status
prelude. The renderer labels it `RECEIPT` and prefixes its status body with
`접수 당시: `, distinguishing the historical receipt from current queue/control
state even when a narrow gutter or continued heading hides its label. Other
execution statuses retain `STATUS`. The original transcript notice is preserved.
The prelude has the receipt's source timestamp, no execution rail, and no effect
on authored USER/keeper text, execution phase, or continuation/retry segments.
Pending input remains in the pending region until execution or persisted input
provides the existing consumption evidence.

When a batch chooses one sibling log to draw the shared execution, the renderer
collects the receipt preludes from all logs with the same Keeper and typed
execution source. Full request identity deduplicates them; submission order
orders them. They precede execution content in the existing monotone timeline
frontier. That frontier keeps later content at or after the prelude's placement,
so the downstream time/slot merge cannot put an earlier-clock answer before its
receipt, including when an unrelated history row lies between their timestamps.
Changing an unselected sibling receipt invalidates the projection memo.

`of_log` restores the initial receipt, execution entries, latest snapshot, and
priority flag. When a complete journal replaces a partial direct log, or the
direct log settles behind an already complete journal, the retained source
inherits missing receipt metadata for the exact Keeper/request. No HTTP notice
is added to durable journal storage. Opening an unrelated session from journal
history alone cannot reconstruct an unobserved receipt and does not invent one.
The direct watcher reuses its request log across checkpoint and transport
reconnects; only its wire decoder is recreated. Journal recovery creates a log
only when no held exact source exists, and receives no HTTP acceptance. Thus
current callers do not replace an original receipt with a distinct recovery log
whose first observation is Replayed; no clock-based receipt election is needed.

Regression cases use the AG-UI producer serializer and execution projector,
`Live.feed`, real state transitions, and the shared renderer. They cover receipt
time 200 after execution times 110–114, an unrelated row at 150, all three origin
modes at 80/140 columns, pending-to-USER promotion with exact bodies, reconnect
and `of_log`, batch source swaps, continuation, both journal takeover directions,
and preserved priority feedback. These are source fixtures; this change does
not claim local build, fixture execution, PTY screenshot, or live-provider proof.

Control-token updates, run-next selection/removal, queue refresh, and terminal
callbacks stay at their existing effect boundaries. Only display ownership of
their admission feedback changes. Independent operations still merge by the
existing timeline policy; this change does not introduce a global causal clock.
