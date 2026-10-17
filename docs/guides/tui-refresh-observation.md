# TUI refresh observations and before/after comparisons

The TUI records the logical readers of a full HTTP refresh and shows which reader
it is waiting for. Diagnostic status explains a refresh that has not finished;
independent roster delivery also removes the unrelated-reader wait for that
dataset. Status alone does not certify workspace admission or faster completion.

## As-Is and To-Be

| Aspect | Before | This change | Still to implement or measure |
|---|---|---|---|
| Refresh visibility | Connection badge and one full-refresh start clock | Pending reader, failed and interrupted reader counts; native captures at 120 x 36 and 80 x 24 | Broader live-use readability |
| Attribution | Existing endpoint and mailbox diagnostics | One terminal record with logical reader outcomes and elapsed time; controlled native comparison | Production latency distributions |
| Partial results | Verified Dashboard preview and questions can arrive early; roster waits for the full bundle | A matching workspace's roster can settle before unrelated reads, once per source request | Cold-start authority and other scoped datasets still use terminal admission |
| Authority | Request tickets and workspace identity guard admission | Diagnostic observations use the same request and authority identities | These observations never grant data or action authority |
| Keeper execution | Existing Task/Skill preparation and owned job recovery | No model or Tool execution change in this unit | Request byte attribution, redundant roundtrips, recipe concurrency and held-job reactivation |

The source baseline for this comparison is
`683c7950682b45a2591002e09f654515ccf02155`, the stack's integration base when the
comparison was prepared. A controlled native before/after at candidate
`f7632e71601da3ce6c7b5a5e8a6b528bcf42fa4c`, including failed and non-demonstrating
attempts, is retained in [the native observation report](../evidence/2026-10-17-tui-refresh/README.md).
It uses a real private backend and a synthetic two-second sibling delay, with one
changed-health sample per arm and viewport. It is not a production benchmark.
A parsed file, an authored state scenario and an observed native frame are
different evidence.

## Read the observations

The header keeps the connection/workspace warning and adds the oldest pending
logical reader, with the number of other pending readers. Failed or interrupted
readers remain visible after the refresh finishes, until the next refresh starts.
A successful completed refresh adds no extra header text. These are diagnostic
counts, not the number of usable records or completed tasks.

Each requested source starts once and settles once. The sources are:

| Reader | Work covered |
|---|---|
| workspace | Initial server identity/readiness probe |
| dashboard | Dashboard snapshot and its preview identity verification |
| confirmations | Requested approval listing |
| questions | Questions listing and its response-bound workspace/readiness verification |
| keepers | Requested roster, its identity verification and Candle reading |
| view data | Other reads required by the current surface, grouped together |
| workspace verification | Final identity probe after the independent reads join |

Not every surface requests all seven readers. A reader can contain multiple HTTP
calls; the counts are not endpoint or network request counts. `view data` fails
when any requested constituent returns an error. A Keeper roster with a failed
Candle read is also a failed group, even if the roster itself was received.

`received` means the reader returned its declared successful result. It does not
mean the final workspace identity matched, the dataset was published, or a Tool
effect succeeded. `failed` means a declared error or exception; `interrupted`
means cancellation or a pending reader when the refresh ended. Old request and
workspace observations cannot update the active ledger. An old ledger is hidden
when its workspace authority is no longer current.

The existing Transport logger emits one `tui_http_refresh=<JSON>` record at the
terminal application of a current full refresh. The JSON contains:

- `scope`: logical full-refresh readers.
- `started_ns`: a monotonic process-relative refresh identifier, encoded as text
  to preserve integer precision. It is not a wall-clock timestamp.
- `elapsed_ms`: dispatch to application of the terminal refresh message.
- `sources`: each reader's name, outcome and execution `elapsed_ms`.

Reader durations end in the worker; total refresh duration ends in the UI loop,
so it also includes mailbox delay. Neither measures the first painted frame or
the time an operator can act. Existing slow endpoint and mailbox records retain
their narrower meaning. The synchronous fallback has the total refresh clock but
does not emit individual reader events. Scoped refreshes and independent side
reads are outside this ledger.

## Admit the first matching workspace before the collection joins

On an initial unread workspace, the existing initial health response is now
acknowledged by the UI before the worker starts parallel surface collection.
Only a ready response with both matching workspace paths, the current full
refresh ticket and the dispatch workspace authority can take this path. Warm,
foreign, incomplete, booting and retired observations retain their existing
handling. The synchronous fallback does not wait for a mailbox acknowledgement.

Identity admission invokes the same canonical workspace transition as terminal
admission. That transition retires old source requests, so the UI issues fresh
question, approval and requested roster receipts under its successor authority.
The worker uses only this acknowledged binding for subsequent progress, early
observations, final results and failure settlement. It does not take a later
workspace authority from mutable UI state. Rejection and handler exit resolve the
acknowledgement; cancellation still propagates through the worker's switch.

| Boundary | Before | Source implementation |
|---|---|---|
| First matching identity enters UI state | After all readers and final health | After initial health and its UI acknowledgement |
| First cold questions, roster or approvals | Terminal bundle; original source receipts can already be retired | Each response settles its fresh source owner as soon as its own verified read is available |
| Saved Keeper chat opening | Whole refresh completion | Owned roster application; history then loads independently |
| Whole bundle completion and final identity check | Wait for every requested reader | Same enclosing interval contract |

Opening still yields to operator navigation. A missing Keeper or failed roster
keeps its existing unavailable outcome. An early receipt settles once, so the
terminal bundle cannot apply it again. A later failed or foreign final probe
still withdraws or suspends workspace authority through the existing outcome
handler. Admission does not imply that other readers succeeded.

`tui_initial_identity refresh_started_ns=... admitted_ms=...` records the UI
admission boundary. Join the unchanged refresh clock to `tui_roster_early`,
`tui_asks_early`, `tui_approvals_early` and `tui_http_refresh`; these are source
state clocks, not first paint or Keeper action. A cold native Before/After and
candidate runtime behavior have not been measured for this change.

For a paired cold run, keep the same binary/backend identities, workspace,
viewport and saved opening choice. Delay an unrelated reader, retain both source
outcomes and the final frame, and compare initial workspace admission, first
usable question/roster/chat and full refresh separately. Preserve failed and
unfinished attempts. Existing warm native pairs (~6.03 seconds full refresh on
both arms despite one fewer health call) are a different cohort and establish no
cold-start latency gain.

## One enclosing workspace verification

Full refreshes and scoped refreshes each own one initial identity probe and one
final probe after all their requested readers have joined. Previously the shared
scoped-data collector also ran its own trailing health request, so both paths
waited for three enclosing identity requests. The collector now returns
`unit http_scoped_surface_readings`: it carries data and its original request
ticket, but no checked server identity. Only the enclosing successful interval
binds the final identity and constructs the result accepted by the UI mailbox.

| Enclosing identity requests | Before | Source implementation |
|---|---:|---:|
| Full refresh | 3 | 2 |
| Scoped refresh | 3 | 2 |

These counts exclude independent early-preview and per-surface requests. The
full refresh still checks booting, foreign, failed and unread final identities
before producing a usable bundle. A scoped refresh still checks its original
workspace and authority before and after its own reads. Early Ask and roster
admission retain their separate response-bound workspace and request receipts.
No data source is dropped, and a failed source remains a failed observation.

The `view data` reader now ends when its data reads settle; final workspace
verification has its own existing ledger entry. Reader success still grants no
publication authority. Removing one request is a source-level result; matched
native request counts, full refresh timing and final workspace-refusal behavior
must be recorded separately before claiming an observed latency improvement.

## Keep the last Ask answer receipt visible

The Approvals surface retains its last admitted answer receipt after transient
notices expire, an empty question reload or an ordinary refresh. Its status is
drawn before the Keeper/choice detail, and the same rendered block determines
the remaining question and approval row budgets. This is session-local feedback,
not a durable history or a current Keeper execution status.

| Aspect | As-Is | To-Be source change |
|---|---|---|
| First answer feedback dependency | Answer POST, then question reload, then UI delivery | Original POST result is offered to the UI before the reload starts |
| Result after transient notice expires | Empty question list can hide the accepted result | Last admitted receipt remains on Approvals |
| HTTP requests | Original POST and workspace-bound question reload | Same original POST and reload; no additional request |
| Duplicate answer | Newly submitted labels cannot describe the canonical winner | Same rule applies to retained feedback |
| Keeper progress | A stored wake does not prove resumed work | Delivery receipt remains distinct from Keeper activity |

The early observation changes no submission/draft gate and settles no workspace
operation. The original operation continues through its canonical list reload
and final completion. Both phases share one typed submission with its original
Keeper, Ask, dispatch authority and opaque request identity. A newer submission
supersedes old observations. The same submission cannot log or replace its
receipt twice; a later reread failure cannot downgrade an earlier admitted POST
receipt. Workspace withdrawal clears it, and unread or changed authority hides it.

Recorded, existing-winner, delivery-pending, append-without-confirmed-winner,
refused and recording-unconfirmed outcomes remain distinct. Only a newly
recorded canonical answer retains submitted choice labels. A pending receipt
describes the last response; automatic recovery may subsequently change delivery.
Observe Keeper activity to establish whether actual work has resumed.

`tui_ask_answer_receipt` records the admitted phase (`post_response` or the
terminal fallback `reread_complete`), a process-local monotonic `admitted_ns`,
and a `receipt` object with `keeper`, `ask_id`, `recording`, and `delivery`.
Delivery is null when no delivery fact was established. Choice/free-text bodies
and server error details are excluded from that log. These are state-admission
observations, not physical POST counts, first paint or Keeper action proof.

For native Before/After, keep question bytes, backend, viewport and submission
actions fixed; delay only the post-answer question reload. Retain actual POST
responses, UI receipt clocks, original canonical answer/wake records and later
frames at both normal and narrow widths. Native latency and visible After for
this new source remain unmeasured; prior answer frames establish the transient
feedback problem, not the result of this implementation.

## Early operator confirmation delivery

A warm full refresh can apply its operator confirmations while unrelated
Dashboard or surface readers are still running. The parameterized operator
summary computes its own rows and includes `workspace_identity` with canonical
`base_path`, `masc_root`, and boolean `state_ready`. The TUI checks both paths
against the original identity probe and requires readiness before offering the
result to the UI. A missing, duplicate, malformed, foreign or booting attestation
is a failed read, including when the confirmation list is empty. Default cached
operator publications are not relabeled with the current workspace.

The UI also checks the current full-refresh ticket, dispatch authority, local
workspace and original `Listing_order` receipt. A newer admitted listing or an operator
action supersedes that receipt. Applying it early consumes the same receipt that
the terminal bundle carries, so the final bundle cannot apply it again. Cold
start and scoped reads retain their existing terminal admission path. The final
workspace probe and confirmation-time checks remain in place.

| Aspect | As-Is | To-Be source change |
|---|---|---|
| Warm confirmation availability | After all readers join and final identity returns | After its own attested response reaches the current UI request |
| Additional HTTP requests for early delivery | None | None |
| Stale/duplicate completion | Original listing/press ordering | Same ordering, shared by early and terminal delivery |
| Observability | Terminal full-refresh ledger | Original listing request and matching refresh clock at early state admission |

`tui_approvals_early` records `request`, `refresh_started_ns`, and `admitted_ms`
after the original listing has been admitted and applied. Join its refresh clock
to `tui_http_refresh` to distinguish confirmation availability in state from the
time the full refresh settles. It does not measure first paint or an operator
decision. Native latency and visible Before/After for this change remain
unmeasured; the source changes a dependency, not an established time percentile.

## Early Keeper roster delivery

For a workspace already confirmed by the TUI, a successful roster response may
be applied while Dashboard, confirmations or current-view readers are still
running. Its request carries both expected workspace paths to the authenticated
roster endpoint. Early admission also checks the full-refresh ticket, dispatch
workspace authority and current server identity. It does not confirm a new
workspace or turn a cold start into an authorized reading.

The roster has its own `Snapshot_read` receipt. A newer roster request supersedes
the old one, workspace suspension retires it, and early delivery consumes it.
The terminal bundle therefore cannot replay the same roster or its dependent
Item refresh. Error and unadmitted results retain their terminal admission path.
No extra HTTP request is added. Other datasets keep their existing ordering.

`tui_roster_early` records the admitted source request, full refresh's monotonic
`refresh_started_ns` and `admitted_ms` after applying the roster to UI state.
Join the same refresh clock to `tui_http_refresh`; the difference separates
roster usability in state from the terminal refresh. This is not a first-painted
frame measurement. Native frames must still establish what was visible.

Before this delivery change, from the end of the common initial identity probe,
the roster waited for the slowest independent reader and final identity probe.
Afterwards its own successful workspace-bound read and UI mailbox application
can settle it. In the controlled native comparison, the candidate admitted its
roster in 54.594 ms at 120 x 36 and 78.039 ms at 80 x 24, while its terminal refresh
took 2046.113 ms and 2109.435 ms. Its scheduled 0.1s frames showed the new health;
the baseline still showed the previous health at the scheduled 0.5s frames.
The experiment demonstrates removal of the imposed sibling wait. It does not
measure a general or production speedup, or the baseline's exact admission clock.

## Workspace-bound question reads

The TUI sends both canonical `expected_base_path` and `expected_masc_root` on
each question read. The server checks the pair against its receiving config
before Keeper lookup or question scanning. Partial/duplicate fields return 400;
another workspace returns 409. Named and fleet responses carry the actual
canonical roots in `workspace` and the server's observed `state_ready`.

The decoder requires one complete matching workspace and exactly one true
readiness field, including for an empty list. Missing, foreign, ambiguous or
booting responses remain failed reads and retain the previous questions. A
matching response can therefore enter the existing early-delivery path without
another health request. Its refresh ticket, workspace authority and question
read receipt still govern admission; cold-start reads retain terminal admission.

| Ask-specific request path | Before | To-Be implementation |
|---|---|---|
| Warm question read before early delivery | Question GET, then health GET | One workspace-bound question GET |
| Question reload after an answer | Health GET, question GET, health GET | One workspace-bound question GET |

These are source-level request counts, excluding the full refresh's shared
identity probes and the answer write's existing admission check. They do not
establish elapsed-time savings. The actual question/choice IDs and answer
recording/delivery receipts retain their meanings. For Before/After, freeze the
same original question, workspace, viewport and delayed endpoint behavior;
record actual requests, question state admission, full-refresh completion and
manually inspected native frames. Keep foreign-workspace, booting, failed and
unfinished attempts alongside valid reads.

## Workspace-bound question reads

The TUI sends both canonical `expected_base_path` and `expected_masc_root` on
each question read. The server checks the pair against its receiving config
before Keeper lookup or question scanning. Partial/duplicate fields return 400;
another workspace returns 409. Named and fleet responses carry the actual
canonical roots in `workspace` and the server's observed `state_ready`.

The decoder requires one complete matching workspace and exactly one true
readiness field, including for an empty list. Missing, foreign, ambiguous or
booting responses remain failed reads and retain the previous questions. A
matching response can therefore enter the existing early-delivery path without
another health request. Its refresh ticket, workspace authority and question
read receipt still govern admission. An unadmitted cold read cannot authorize
itself; the initial matching probe must first be acknowledged by the UI.

| Ask-specific request path | Before | To-Be implementation |
|---|---|---|
| Warm question read before early delivery | Question GET, then health GET | One workspace-bound question GET |
| Question reload after an answer | Health GET, question GET, health GET | One workspace-bound question GET |

These are source-level request counts, excluding the full refresh's shared
identity probes and the answer write's existing admission check. They do not
establish elapsed-time savings. The actual question/choice IDs and answer
recording/delivery receipts retain their meanings. For Before/After, freeze the
same original question, workspace, viewport and delayed endpoint behavior;
record actual requests, question state admission, full-refresh completion and
manually inspected native frames. Keep foreign-workspace, booting, failed and
unfinished attempts alongside valid reads.

Question inventory comes from canonical durable Ask logs, including offline or
unregistered Keepers. Process registration is not the owner of a recorded
question. Named reads retain the same original owner; answer admission validates
the original stored ask and preserves its first winning answer. A durable wake
can remain pending until the Keeper runs, which is separate from answer
recording. Missing/unreadable inventory is not projected as a successful empty
fleet. Counts and rows use the same loaded fold.

The [offline native counterexample](../evidence/2026-10-17-asks-offline-inventory/README.md)
retains the failed observation that exposed registry-only inventory. Its failed
question samples are not early-Ask latency evidence.

`tui_asks_early` records the original question request ID, the full refresh's
monotonic `refresh_started_ns` and `admitted_ms` after the successful question
snapshot has entered UI state. It is emitted only when the existing early read
receipt is accepted and consumed. Stale, foreign, unadmitted or replayed messages
do not produce an admission. Question text, answers and workspace paths are not
copied into this record. Join the same refresh clock to `tui_http_refresh` to
compare question state usability with terminal refresh completion. A painted or
actionable native frame remains separate evidence; the log grants no authority
and does not establish that a Keeper acted on an answer.

## Collect comparable before/after evidence

The [native Ask comparison](../evidence/2026-10-17-native-asks/README.md)
contains exact binary/source identities, retained failures, source clocks and
manually inspected 120×36/80×24 frames. It separates early question usability
from full refresh settlement under explicit delayed-reader conditions.

The separate [native answer observation](../evidence/2026-10-17-native-ask-answer/README.md)
records actual selection and Enter confirmation, the original answer POST,
canonical answer and durable pending wake at both widths. It also retains the
narrow receipt that hid wake status after a long chosen label. Revised notices
put recording and delivery status first; choice rows spend their width on human
labels while original IDs remain in the draft and request. The published frames
precede those readability edits, whose native confirmation remains pending.
Queue admission does not establish Keeper consumption or a resumed next action.

Build or obtain binaries identified by their exact source SHAs. Use the same
isolated workspace, fixture state, endpoint behavior, terminal viewport and
refresh action for both. Record cold start separately from a warm refresh. Do not
install or restart the operator's live runtime to make a comparison.

Keep the following artifacts for each attempt:

1. Binary/source identity, viewport, workspace/fixture identity and start action.
2. HTTP request start/end records and TUI Transport output.
3. Native frame captures while a selected reader is delayed and after settlement.
4. Time to the first actionable question, usable roster/current view, and terminal
   refresh, each with its own definition. Missing or failed outcomes stay missing.
5. Failed and unfinished attempts alongside successful samples and their counts.

Use a delayed independent reader to distinguish early usability from total
refresh completion. Include a source error, cancellation, a superseding refresh
and workspace replacement when inspecting observation boundaries. Manual frame
captures are review artifacts; do not add text, row-order or layout assertion
tests. Automated TUI checks inspect sent requests, retained state and decisions.

Report median and tail latency only when the sample count supports them. Do not
call a source-only change a measured improvement. For future Keeper execution
changes, retain the same task/provider/Tool semantics and compare preparation
time, model POST count, actual request bytes and final outcome separately from
these TUI refresh observations.
