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

## Follow the original answer into Tool result records

The opt-in named read
`GET /api/v1/keepers/asks?name=<keeper>&answer_progress_for=<ask-id>`
retains the canonical answer and source reaction clocks. Its `tool_actions`
observation now also projects committed physical Tool result rows whose original
turn input contains that exact answer. The source identity comes from the
canonical question ID and first-answer timestamp when the answer observation is
created. It passes through the per-run context and original post-Tool hooks;
concurrent runs do not share a Keeper-name context or infer membership from time.

| Surface | Before | Source implementation |
| --- | --- | --- |
| Answer follow-up | Turn entry/boundary and queue clocks | Those facts plus known committed Tool result count, first result clock and latest physical execution/trace/turn identity |
| Original source lookup | Tool association unavailable | Exact source index over authoritative Tool rows, independent of recent tails and time windows |
| Interleaved Keeper runs | No exact answer-to-Tool association | Each run retains its original answer input IDs; another answer timestamp or Keeper cannot supply a row |
| Failed observation after a positive result | Reaction clocks retained | Tool result facts also remain, with the latest read marked unavailable |

`tool_actions.state` is `observed` or `unavailable`. An observed summary has
`observed_count`, `first_recorded_at` and nullable `latest`; the latest record
names `execution_id`, `trace_id`, `keeper_turn_id`, `tool` and `recorded_at`.
The TUI shows the result count/latest Tool and turn alongside the retained
answer receipt. `tui_ask_followup` logs keep the same identity and observation
clocks without question text, answers or Tool input/output bodies. The existing
drawn feedback block determines the remaining viewport space.

These are positive result observations, including errors. They prove input
membership, not that the answer caused an action, the model used its content,
an effect succeeded or the Task finished. No result is invented from a queue
ACK, turn entry, clock overlap, or an unfinished Tool start. Uninstrumented
native actions, older rows and fresh continuations without the original answer
context remain unobserved. A zero count is no proof that no action happened.
Ambiguous duplicate physical execution IDs or an unavailable/different Tool
ledger workspace leave action evidence unavailable while retaining reaction
facts. Reads neither flush pending Tool appends nor enqueue another answer.

The source index is derived: its schema rebuilds from the canonical Tool ledger
on first read after this change, and source rows follow file replacement/shrink
through the same generation checks. Row bodies are revalidated and folded in a
blocking worker; the response retains only metadata. Cold rebuild latency is
not measured here.

The comparison baseline is #43459 at
`c5f7105b3390c38c66d06e44774fa228aa920b20`. Authored scenarios exercise real
isolated Ask/Tool stores and SQLite reads, interleaved per-run contexts, canonical
answer timestamps, other Keepers, failed results, duplicate execution evidence,
ledger shrink/rebuild, workspace mismatch, strict protocol decoding and retention
of positive state after failed reads. They are not executed in this unit.
Parser checks establish syntax only. A source-SQL storage probe passed exact
source/Keeper lookup,
primary-index use and deletion/replacement cascade checks; this verifies the SQL
structure, not the OCaml feature. A matched Before/After must retain the same
answer source, request, runtime and original Tool/Task identities and compare
answer recording, turn entry, first Tool result recording and TUI admission
separately, including failed/unfinished samples. No new native or model latency
result is claimed.
