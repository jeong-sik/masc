# Full-refresh composition: retain component receipts and partial completion

Source baseline: `5ad5e7c1cc886498387b27a0334c32803d70170d` (#43708).

## As-Is / To-Be / Before and After

| Returned composed reader | Baseline | This layer |
| --- | --- | --- |
| One component received, one failed | Whole reader marked failed | Partial reader with both actual component receipts |
| Component receipts retained in diagnostic JSON | None | Two for each returned supported composition |
| Two declared successes | Received | Received with both component receipts |
| Two declared errors | Failed | Failed with both component receipts |
| Outer roster error / exception without components | Failed | Failed without invented component results |
| Cancellation / unfinished reader | Interrupted | Interrupted; already settled partial siblings retained |
| Counts for one mixed reader | failed=1, received=0 | partial=1, failed=0, received=0 |
| HTTP, source publication and read ordering | Existing calls and guards | Unchanged; observation only |

These are source-derived evidence changes, not timing measurements. Reader counts
are neither component counts nor HTTP/Tool/Task counts. The change adds no requests,
new retry, timeout, admission condition or action cap. It does not accelerate a read.

## Actual composed contracts

`observe_http_reader` previously accepted a boolean classifier, so Runtime
catalogue/usage, Board posts/hearths and Keeper roster/Candle lost successful
sibling evidence whenever the combined predicate was false. The observer now takes
a typed outcome. Simple readers use their Result classification; composed readers
carry closed products for their actual two components.

The Keeper loader returns `roster * Candle_observation result`, not tool settings.
An outer roster error returns no separate component results and remains failed.
An available typed roster response and failed Candle become partial. Receiving the
roster response does not assert complete roster coverage: partial/invalid roster
content and action availability remain the existing data surface's decisions.

Completion category is derived from the typed pair, not error strings or numeric
thresholds. Both received is complete receipt, both failed is failed receipt, mixed
is partial. Separate counts expose pending/received/partial/failed/interrupted
logical readers. `partial` is not counted as received. JSON keeps the existing
reader names and parent clocks and adds component statuses and these reader counts.
The badge identifies failed and received components for a partial reader, with no
new screen rows or frame-clock meaning.

## Ownership, interruption and timing boundaries

The observation wrapper returns the same read result. All dataset publication,
workspace/read authority, source ordering, retries and current-request checks keep
their prior contracts. Dataset admission's separate `received` booleans are not
replaced. Diagnostic receipt cannot publish data, confirm workspace identity,
authorize actions, demonstrate useful Keeper work or complete a Task.

Component statuses are co-observed at the parent reader's return. There are no
individual component clocks; Board's physical readers and the shared Runtime
response have different IO shapes. If a combined producer is interrupted before
returning, this layer cannot recover unreported inner completions and does not
invent their status. Existing unfinished-reader interruption, duplicate settlement,
old request and foreign authority rejection remain. This is not streaming child
completion observation or first usable input proof.

## Evidence and matched follow-up

Four changed OCaml files passed parsing-only checks; diff hygiene is separate.
Two feature/protocol scenarios are authored, unexecuted: a partial Runtime receipt
through lifecycle/serialization/interruption without dataset authority; and the
success/partial/failure matrix across all three supported composed contracts.
Existing progress tests use the new named counts and completion categories.
No wording/layout/screen-row-order/snapshot-output/PTY tests are added; serialized
component checks cover the diagnostic protocol and stored state.

The variant/interface trace is `Http_refresh_progress` → observer/full-refresh
collectors → progress ledger/JSON and badge; direct tests and protocol guidance
are updated. Historical raw observation artifacts are not rewritten. Existing
observer scripts collect these transport log lines without enumerating statuses.

No local Dune/typecheck/tests, CI dispatch/watch, native/model run, install/restart,
live config write or own merge is part of this unit. Parsing does not establish
typing, execution, independent approval, merge, installed behavior or visible paint.

Future matched samples must pin source/binary and workspace, hold component
outcomes fixed, and keep complete, partial, failed, cancelled, interrupted and
unfinished samples. Compare reader and component results separately; do not derive
component durations from the parent interval. Preparation/discovery attribution,
cold-start input, Ask-to-original-Task/useful work, resource-owned Composition and
held-job/shared backend reuse remain in the full objective. No measured speedup
or whole-goal completion is claimed here.
