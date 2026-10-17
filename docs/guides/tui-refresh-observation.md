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
Item refresh. Error and cold-start results retain their terminal admission path.
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
receipt is accepted and consumed. Stale, foreign, cold-start or replayed messages
do not produce an admission. Question text, answers and workspace paths are not
copied into this record. Join the same refresh clock to `tui_http_refresh` to
compare question state usability with terminal refresh completion. A painted or
actionable native frame remains separate evidence; the log grants no authority
and does not establish that a Keeper acted on an answer.

## Collect comparable before/after evidence

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
