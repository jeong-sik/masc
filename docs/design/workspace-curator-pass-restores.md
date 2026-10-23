# Curator restore calls per pass

One sample covers one actual serialized owner drain iteration: the call to
`Server_workspace_memory_curator.run`, including its classification stage and
then its Briefing stage. A wake admission is not a sample. Even an idle iteration
with zero restores emits a sample; an iteration unwound by an exception or
cancellation emits the work actually entered before unwinding. These observations
are never read by scheduling, admission, retry or size policy.

The common `Server_workspace_memory_addon.restore` boundary captures the
fiber-local pass context before crossing into the system thread. It increments
only when the callback actually enters `Capture.restore`. A rejected/cancelled
submission whose callback never runs counts zero. Every entered invocation counts,
including repeated restores of the same original during observer preparation and
ACK rechecks. A returned `Error`, thrown exception or cancellation from the entered
callback is a failed invocation. The result or original exception/backtrace is
returned unchanged. Counts are protected by the pass's own mutex; another
workspace/pass cannot borrow them through a process-global before/after delta.

This unit is a complete `Capture.restore` API invocation, not an original request,
record read or ledger file read. Its internal ancestor walk, deterministic child
reconstruction and row validation are inside that invocation. They do not add
calls. Owner/body loads and workspace observations that fail before restore entry
also do not add calls or failures. This metric cannot substitute for filesystem
read counts or restore duration.

| Label | Included work |
| --- | --- |
| `domain=classification` | Calls made while the classification stage runs |
| `domain=briefing` | Calls made while the Briefing stage runs |
| `domain=outside_domain` | Calls within a pass outside either stage; normally zero, explicitly observed rather than assigned a domain |
| `phase=discovery` | Discovery and its recovery of existing successor intents, including a later rediscovery |
| `phase=observer` | Registration/completion preparation, their ACK integrity rechecks and final observation reread |
| `phase=successor` | Restoring candidate size-refusal frontiers, narrowing/link recovery and child validation |
| `phase=primary` | Resume, original domain settlement and other synchronous stage work not in the three paths above |

The domain labels describe the **stage performing the work**, not the restored
original's domain. Both stages discover and observe both kinds of original; for
example, a Briefing observer restore during classification is counted under
`classification/observer`. It counts again if actually invoked later. Successor
recovery inside discovery is `discovery`, while an explicit successor operation
is `successor`. The innermost bound phase owns a call, so it is never counted in
two phases.

The separate asynchronous Exact authorization path in
`Server_workspace_memory_addon_validation.authorize`, direct calls to the pure
capture module, and operator/test consumer calls outside an owner pass are not
attributed to these samples. This measures owner-pass restoration cost only; it
does not claim all server restores. A pass does not wait for or adopt background
Exact activity to improve its measurement.

`Otel_metric_store` receives two histograms for each domain/phase combination:

- `masc_workspace_curator_restore_calls_per_pass`: entered restore invocations.
- `masc_workspace_curator_restore_failures_per_pass`: returned errors, raised
  exceptions and callback cancellations combined.

The store's histogram value accumulates sample values; the companion name from
`Otel_metric_store.histogram_count_name` (the metric name plus `_count`) counts
samples. Over an observation window, divide a cell's value delta by its count
delta for that cell's mean per owner pass. For total restores per pass, sum the
value deltas across cells and divide by **one cell's** count delta: every cell
gets one sample per iteration, including zero. Summing their counts would
multiply the denominator. The series aggregate all owner workspaces in the
process. The existing metric exporter exposes these store observations; do not
infer a live value before this implementation is installed and observed.

Each iteration also emits one `workspace curator pass restores` log with a fresh
`pass_id`, `base_path` and the cell counts. Each cell separates `errors`, `raised`
and `cancelled`; successful calls are `calls - errors - raised - cancelled`.
Pass IDs and paths stay out of metric labels. Logs provide the individual-pass
and workspace join; metrics provide the process-level interval aggregate.

Focused test sources join actual production worker/owner fixtures to the
observations: both stages emit calls, an unchanged wake adds a zero-restore
sample, repeated observer restoration counts separately, a semantically invalid
capture counts as a failed actual call, and an out-of-pass preparation leaves the
previous pass unchanged. A separate executor-boundary case proves a callback that
never enters contributes zero. Authoring these tests is not execution evidence.
