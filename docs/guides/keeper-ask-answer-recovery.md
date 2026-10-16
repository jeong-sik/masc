# Recover recorded Ask answers

An Ask question does not suspend its Keeper lane. The question log owns the
answer; the event queue carries its question ID and original continuation
channel. A durable wake is evidence of delivery admission, not proof that the
Keeper completed the requested work.

After an answer append, the store rereads the canonical first winner. Concurrent
submissions can append different answers, but only the first terminal answer is
canonical. A losing submission remains a conflict; its choice labels must not be
displayed as the recorded decision. When an append succeeds and the canonical
read fails, the response preserves the append evidence and explicitly leaves the
winner unconfirmed.

The answer route reports recording and delivery separately:

| HTTP response | Recorded fact | Operator action |
| --- | --- | --- |
| 200, `recorded: true`, `delivered: true` | This submission is canonical; the wake was accepted or already delivered | Continue working |
| 500, `recorded: true`, `delivered: false` | This submission is canonical; durable delivery is pending | Automatic recovery retries delivery |
| 409, `state: answered`, `recorded: true` | A canonical answer already exists | Do not claim submitted choices won; retain the delivery outcome |
| 500, `state: recording_unconfirmed` | The append succeeded; its first winner could not be confirmed | Reread the question; do not attribute submitted choices to the winner |
| No response or invalid receipt | Recording is unconfirmed | Retain the draft and reread authoritative state |
| Other 4xx refusal | The server refused this request | Correct the request or credential |

Every recording receipt names the exact requested `ask_id`. The TUI rejects a
different ID, missing recording evidence, and contradictory HTTP/delivery
states. It preserves a structured partial receipt through HTTP and the async
completion mailbox rather than replacing it with a generic error string.

Startup and the existing maintenance pulse reconcile canonical answered logs.
Recovery does not submit another answer, rebuild a missing continuation, replay
a tool effect, or add a new timer. The wake uses the canonical answer time and
the original question's continuation. Queue admission retains the existing
Keeper lifecycle and intake ownership boundaries.

One immutable strict reaction snapshot per Keeper shares the journal read across
answered questions. Exact positive delivery evidence is keyed by question source
ID and typed stimulus kind. Unrelated malformed rows do not erase an exact
positive; without a positive, incomplete evidence cannot authorize absence. A
snapshot is an observation: the queue owner rechecks fresh once-only evidence
before admitting unresolved delivery. Already delivered sources receive no new
wake hint merely because maintenance runs again.

The consumer also reads canonical Ask state strictly. If the answer log is
unreadable, missing, or lacks the referenced answer, that exact queue selection
stays pending. It is excluded from admitted sources, turn-entry delivery proof
and acknowledgement. Other readable sources may proceed in the same turn. A
source-read retry does not count as a crashed Keeper cycle.

Direct verification targets are the Ask store, Ask answer wake, reaction ledger,
heartbeat source intake and TUI answer projection suites. Scenarios use actual
isolated persistence for failed wake writes, recovery, duplicate/consumed
delivery, corrupt evidence, canonical first-winner races, and unreadable answer
intake followed by repair. Projection checks inspect receipt decisions and
identities; they do not test screen wording or row order. Parser checks alone do
not establish execution. A fresh running TUI screen remains separate evidence
from these source and API contracts.
