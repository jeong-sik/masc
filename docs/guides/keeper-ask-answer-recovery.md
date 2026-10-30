# Recover recorded Ask answers

An Ask question does not suspend its Keeper lane. The question log owns the
answer; the event queue carries its question ID and original continuation
channel. A durable wake is evidence of delivery admission, not proof that the
Keeper completed the requested work.

The exact-answer follow-up also observes the `task_id` recorded on the original
question. It does not substitute the Keeper's current Task or infer a binding
from Tool results. `linked_task` distinguishes `unlinked`, `missing`,
`unavailable` and `observed`; an observed reading includes `task_id`, `location`
(`backlog` or `archive`), `observed_at` and canonical status metadata. Task title,
description, completion notes and cancellation reason are excluded. The shared
status codec validates required metadata and lifecycle clocks without changing
Task transition or completion authority.

The lookup reads the strict primary backlog first, then the archive. A recovery
copy cannot replace an unreadable primary. If both lookups miss, it rechecks
the primary to cover restoration; the stores still are not one atomic snapshot,
so `missing` means unobserved, not deleted. The archive keeps an immutable index
under the existing file-version cache policy, invalidated by archive writes;
only the requested row is decoded as a Task. Duplicate requested identities and
unidentified rows that prevent establishing absence leave the reading
unavailable. An unrelated known-id malformed row does not erase a valid exact
positive. Memory backends bypass the filesystem index cache. Read work uses the
existing shared I/O pool when installed, retaining Eio handlers for backend
operations, with the existing no-pool and nested-worker behavior. In an Eio
request the independent Tool and Task observations run as sibling fibers;
non-Eio callers read them sequentially. They retain their own result states and
do not add another HTTP request or timer.

The TUI displays the original Task's actual phase alongside answer, reaction and
Tool evidence. A newer valid reading replaces the old phase, even if the phase
moves back. Failed or missing rereads retain a prior phase as last observed,
explicitly unconfirmed by the latest read. A changed answer source or Task
binding is refused; a newer submission or workspace retires old observations.
`tui_ask_followup` records Task identity, phase, location, clock and freshness
without free text. These observations grant no claim or resume authority, and a
Task phase does not establish answer causation or completion of the whole Goal.

Before this change, follow-up covered exact reaction and Tool results but no
original Task status. After this source change, original Task status is a
separate observation, including archived terminal Tasks and explicit stale or
unavailable evidence. Persistence, HTTP/decoder and state scenarios are authored
but unexecuted; parser checks do not establish typing, behavior, painted UI,
installed inclusion or any latency improvement.

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

## Preserve the execution that created a question

The Keeper Tool handler freezes its per-run source context at invocation entry,
before argument preparation can yield or change the carrier. The shared misc
adapter now passes the exact `(trace_id, absolute Keeper turn)` through the
host-only `source_turn_ref` argument into the canonical question. The logical
Agent Core turn, provider call ID, later metadata and current Task are not
substitutes. Related `task_id` and `goal_id` retain their separate decision
meaning and are never overwritten by execution ownership.

The question log, creation response, operator HTTP projection and durable
answered input preserve this typed `Ids.Turn_ref`. The source is JSON `null`
when unobserved. Legacy Ask records that carried only an unattributed integer
`turn_id` load with `source_turn_ref = None` (and therefore appear in operator
views as having unobserved provenance, `Original asking turn: not recorded`),
while malformed `turn_id` or `source_turn_ref` values are rejected by the
canonical decoder. External MCP callers have no new argument requirement and
cannot establish host provenance by adding a JSON field. This field provides
attribution; it does not grant a Task claim, Gate approval or permission to
replay an effect.

Resumed Composition leaves use the original journal's source observation.
Missing trace, session or absolute Keeper turn stays absent instead of borrowing
it from the current run (and logs the resuming run's `resuming_trace_id` for
operator correlation). This also prevents a nested composition from freezing a
mixture of current and original coordinates as a new producer observation. The
current operational environment still comes from the resumed run. Note that the
journal `source_observation` event is one-way across versions (older binaries
reject `source_observation` as an unknown journal event), and pre-upgrade
tool-call ledger rows recorded before `physical_execution_id` are excluded from
`observed_count`. A source-bound Tool may require original identity; missing
evidence is not synthesized to make that effect executable. Asking itself
remains available without provenance.

| Path | Before | After in source |
| --- | --- | --- |
| Ordinary Keeper Ask | Shared adapter dropped producer execution | Frozen source reaches canonical storage and answered input |
| Resumed Ask | No saved Ask execution; partial source restoration could borrow current coordinates | Original captured pair, or explicit unobserved source |
| External caller | No host source | Still unobserved; raw arguments cannot supply proof |
| Related Task/Goal | Explicit decision references | Preserved independently of execution source |
| Operator observation | No original execution in question HTTP row | `source_turn_ref` string or `null`; TUI preserves it in question and answer state |

Authored, unexecuted scenarios exercise the real SDK handler with a carrier
change during preparation, actual persistence and answer projection, forged
client provenance, partial source evidence, malformed stored references,
workspace-bound HTTP and prepared async resume with complete/partial/absent
original observations. An existing durable job-completion scenario now asks a
new question after resuming under another Task and trace. No model, backend
Docker process, TUI frame, installed binary, latency or token improvement is
proved by this source change. Parser-only checks do not establish typing or
behavior.

## Independent follow-up sources

An exact named follow-up request may opt into `answer_progress_stream=true`.
It emits one canonical start, each source as it settles, then matching read
completion over SSE. Every frame retains workspace, Keeper, Ask, answer time and
stimulus identity. A missing/duplicate source or EOF without completion is not
a successful full read. Source frames contain no placeholders for pending peers.
The Questions pane uses this stream and admits each exact-answer source before
its peers finish. Pending sources have separate state rather than invented empty
or unavailable values. See the [stream source audit](../audits/2026-10-18-ask-followup-source-stream.md)
and [TUI integration audit](../audits/2026-10-18-tui-ask-partial-followup.md) for
source scope and unexecuted behavior limits.

The opt-in `answer_progress` response keeps canonical answer identity outside
three independent source branches. `reaction_evidence` is either unavailable or
observed with turn/queue clocks and evidence completeness; `tool_actions` and
`linked_task` have their own outcomes. Reaction storage failure cannot suppress
the Tool ledger or the original Task lookup. Reads use the common executor
policy and join their outcomes; this does not prove physical concurrency or
lower latency in an installed server.

The TUI retains same-answer positive observations when a source becomes
unavailable and identifies them as last observed. Beginning another read retains
prior facts as earlier observations until each source arrives. Transport failure
after partial delivery leaves received sources admitted; only unfinished sources
become unconfirmed. A failure before any source leaves all prior observations
stale. New answer submission and workspace/read-authority withdrawal cancel the
owned worker and reject its late events without settling a successor request. A fresh original Task phase can still
be displayed while wake/turn evidence is unavailable. Neither this independence
nor Task phase proves answer consumption, causation or whole-work completion.
Server and OCaml consumer use the nested reaction shape together; removed flat
reaction clocks are not decoded as an empty source.

Before/After and source-only limits:
[independent evidence audit](../audits/2026-10-18-ask-followup-independent-evidence.md).

## Inspect the original question source in TUI

The TUI decodes the operator row's canonical `source_turn_ref` into a typed
optional reference. A string identifies the original trace and absolute Keeper
turn; explicit `null` means unobserved. A missing, duplicated or malformed field
refuses the read rather than silently assigning current Keeper activity or
converting an ambiguous response into an unobserved source. The existing failed
read handling retains previous question state and reports the read error.

In Questions, `o` opens or closes the selected question's recorded source. With
no open question, it can inspect the last answer's original source. This is an
explicit diagnostic: Keeper, question ID and original Turn_ref are shown there,
with normal terminal escaping and wrapping. Browsing and the scrollable answer
reader share the same diagnostic renderer; viewport and scroll limits include
its measured content. It performs no HTTP request, opens
no latest-turn inspector and grants no work/effect authority. A missing source
is readable and does not prevent answering. The regular question/choice body
and the free-text editor keep their existing meaning; `o` remains text while
typing an answer. Moving the question selection or leaving answer mode closes
the source detail. Workspace authority owns visible diagnostics so a previous
workspace cannot supply them after a switch.

A source detail is an immutable observation of its named question, not the
current roster or selected Keeper's work. A background reread cannot silently
rename an already opened source. The answer submission freezes the same source
reference before the POST; later list changes and reread failures cannot change
it in retained receipt state. The receipt display distinguishes the original
asking turn from the later answer-reaction and Tool evidence.

`tui_ask_source` records the opened source and monotonic opening time;
`tui_ask_answer_receipt` retains the question source in its receipt metadata;
`tui_ask_answer_lifecycle` separates original submission, check/POST/reread call
boundaries and admitted reread outcome without duplicating that receipt;
`tui_ask_followup` names it as `question_source_turn_ref`, separate from actual
reaction/Tool observations. Question/choice/answer text and server error details
are excluded from these source fields. This supports joining original and later
observations; it is not proof that a model used the answer or completed the work.

| Path | Before | After in source |
| --- | --- | --- |
| Operator HTTP to TUI | Original source dropped by row decoder | Typed original source or explicit unobserved value |
| Selected question | No original-turn diagnostic | `o` shows the named recorded question source without a read |
| Answer submission/receipt | Source unavailable to retained answer state | Original reference frozen at submission and retained after reread failure |
| Observation | Receipt/follow-up lacked asking-turn coordinate | Original source accompanies recording/delivery and later independent work facts |
| Workspace change | Existing request ownership | Same ownership also covers source diagnostics |

HTTP-to-decoder, canonical producer-to-draft/receipt, malformed/ambiguous source,
and source retention across a later question, failed reread and workspace change
scenarios are authored but unexecuted. No TUI wording/layout/row-order/PTY test
was added. Parser checks do not prove typing, painted frames, input latency,
installed behavior or performance. Exact original-turn inspection/navigation is
not implemented here; the existing latest-turn Context Inspector is not labeled
as the original question source.

## Keep the original question in conversation input

The admitted answer row retains the canonical original `Keeper_ask.ask`, exact
per-question answers and first-answer time as typed data. The question already
owns its prompt, complete choices/descriptions, response mode, writing hint,
purpose, optional related Task/Goal IDs and the host-observed original execution. Intake reuses the strict Ask
snapshot it already read; it performs no extra Task, Goal, Ask-status or model
request. An absent original binding stays JSON `null`, even if the Keeper's
current Task changed. Non-finite historical clocks are also `null` rather than a
fabricated timestamp; the remaining question and answer data stay available.

The durable user input contains `ask_origin`, `questions` and `answers` quoted
data fields. Questions and answers use the same read-only codecs as the Ask
event log, preserving stable question/choice IDs, full text, free-text answers
and skipped answers. These fields replace the joined display preview and its
short excerpt in model input. Display surfaces retain their existing previews.
Source identity and speaker attribution remain independent of display text.
Original Task/Goal IDs are historical context; current ownership, Gate and
Composition authority continue to decide what can run.

Ask rows remain reactive activity for intake/decision classification, while the
prompt partition renders their content only in the ordinary durable user turn.
They are excluded from transient Board context, which retains actual Board and
other existing world observations. Board affordance observations use the same
partition, so an Ask answer alone supplies no Board post/comment/curation marker.
Later wakes do not reinsert consumed answers;
normal context/checkpoint persistence carries the original question with its
answer. Existing checkpoint history is not rewritten or backfilled. Reading
answer speakers selects typed metadata without rendering the full answer again.

| Surface | Before this source change | After |
| --- | --- | --- |
| Original question | Short header and joined answer labels/text | Complete questions, choices/descriptions, writing hints and exact per-question answers |
| Original work context | Original purpose and work bindings missing from model input | Recorded purpose, related Task/Goal and original execution; absent stays `null` |
| Answer placement | Full answer in transient Board context and durable user input | Canonical answer data only in durable user input |
| Speaker extraction | Renders complete input before discarding its text | Selects typed speaker metadata |
| Display identity | Exact original answer source | Same source; preview changes do not create another input |

Authored scenarios cover a real canonical Ask log with a refused later answer,
duplicate short question headers, multi-choice order and descriptions, long
prompt tails, written/skipped answers, changed current Task, unlinked questions,
and actual prompt/context/checkpoint serialization across later wakes. They are
unexecuted under the code-only work scope. Parser checks do not establish types,
runtime continuation, model use, installed inclusion or performance. Richer
original-question data and JSON quoting add input bytes; removal of duplicate
copies does not establish a net byte, token or latency saving for every Ask.

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
`observed_count`, `outcomes`, `first_recorded_at` and nullable `latest`; the latest record
names `execution_id`, `physical_execution_id`, `trace_id`, `keeper_turn_id`,
`tool`, `recorded_at` and `outcome`. The first ID retains the original logical node;
the second names the actual invocation that supplied this result.
`outcomes` contains five required nonnegative counts: `succeeded`, `deferred`,
`failed`, `unsettled` and `malformed`. Their sum must equal `observed_count`;
the latest `outcome` uses one of those tags and must have a nonempty bucket.
All five counts are present even when zero. The existing recorded-call classifier
reads typed execution `disposition` first, then `wire_outcome` only if no typed
disposition exists. Thus typed completion with failed response delivery remains
`succeeded`, and a typed deferral with failed delivery remains `deferred`.
Missing/unknown wire outcome stays `unsettled`; an invalid outcome field stays
`malformed`. These rows remain in the physical observation count. Invalid or
ambiguous physical identity still makes the Tool source unavailable.

The TUI shows the result count/outcome distribution and latest outcome/Tool/turn alongside the retained
answer receipt. `tui_ask_followup` logs keep the same identity and observation
clocks and outcome counts without question text, answers or Tool input/output bodies.
Failed, unsettled, malformed and retained earlier observations are distinguished
from current known results. The existing
drawn feedback block determines the remaining viewport space.

These are positive result observations, including errors. They prove input
membership, not that the answer caused an action, the model used its content,
an effect succeeded or the Task finished. No result is invented from a queue
ACK, turn entry, clock overlap, or an unfinished Tool start. Uninstrumented
native actions and rows without a captured physical invocation remain
unobserved. A zero count is no proof that no action happened.
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

## Preserve the answer through async Composition continuation

The original producer captures trace, session, Keeper turn and answer-input
membership once, in the same durable write as the execution-journal source.
Reopening the source retains that first observation, including its absence.
Continuation cannot fill it from the current Keeper, Task or a later answer.
This metadata does not grant replay authority: the original journal owner,
artifacts, node admission and effect-replay rules still decide execution.

| Surface | As-Is at #43462 | To-Be in this source change |
| --- | --- | --- |
| Internal inline leaf | Answer-input membership omitted from its Tool row | The leaf logs its own captured run input |
| Fresh async continuation | Original Task restored, original answer frame not retained | Original answer, trace, session and Keeper turn restored from the producer journal |
| New job after a saved result wait | Current trace can conflict with the original launch frame | The worker restores its original trace before the unchanged identity checks |
| Result recheck | Stable logical ID can look like ambiguous duplicate execution | New physical invocation IDs distinguish fresh rechecks from duplicate rows |
| Compiled pure operand | A logical Tool row can be mistaken for a physical call | No physical call is counted without a dispatched invocation |

An opaque SDK invocation owns one physical ID. Repeated provider IDs on
different invocations remain distinct; repeated callbacks on one invocation
share one ID. A result recheck keeps its logical `execution_id` and receives a
fresh `physical_execution_id`. Retained completed nodes emit no new Tool row.
The TUI follow-up journal carries both IDs. Missing source coordinates remain
unknown in the Tool observation and cannot borrow current answer membership.

The comparison baseline for this continuation change is #43462 at
`c4f606876a328f11e3f2f082018e26489054abd5`. Authored public prepare/run/resume
scenarios change the current Task, trace and answer before resuming. The
synthetic owned-job scenario checks both reuse of the original completed job
and a distinct job first launched after its saved result wait; it checks two
physical result reads under one original logical wait. Ask/Tool-store scenarios
separate fresh rechecks, logical-only rows and duplicate physical records.
Protocol cases require both identities without testing TUI wording or layout.
These cases are authored, not executed here. Parser and whitespace checks do
not prove types, behavior, native TUI output, real Docker or model latency.
