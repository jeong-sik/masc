# Original Task document preparation lifecycle observations

Relates #42799 and follows #44003. The parent moves complete Task/body/history
preparation outside repeated frame work. This unit attaches observations to its
actual producers, ownership and result admission, and fixes a terminal rejection
that could leave an expired preparation marked Loading. All six original axes
remain active.

## As-Is / To-Be

| Boundary | Before | Source behavior after this change |
| --- | --- | --- |
| Attribution | Body/history CPU spans have a name but no explicit original source or ticket in that call. | Each attempt captures Work Task or original async submitter/request/Keeper/run/Task, component, width, workspace revision/fingerprint and ticket generation. A process-unique capture ID joins its facts. |
| Stages | The CPU span combines dispatch, queueing, execution and return; UI disposition is not attached. | Requested, caller start, submission request, actual worker entry/return, caller observation and actual UI application/rejection are separate first facts. Worker context distinguishes shared worker from inline execution. |
| Retirement | Slot replacement and common cancellation cleanup are not joined to preparation observations. | Original owner retirement, cancellation request and actual registry release are separate events on the same capture. Missing stages stay null, including never-started and unfinished attempts. |
| Terminal rejection | A source/width mismatch rejects the terminal result but may leave its exact dead ticket Loading. Returning to that input before reconciliation can share a job that already ended. | The rejected reply clears only its own still-owned reading/request. It cannot clear a live replacement or erase previously completed rows. Same-input reentry can obtain a new owner. |
| Visible waiting | Preparation has a generic pending notice. | The matching current request's atomic facts distinguish start wait, text preparation, result delivery wait and UI update wait. Current failures and explicitly earlier rows remain independent. |

## Actual producer and consumer chain

`sync_task_documents` records Requested when creating the actual original owner,
before launch, so an unlaunched or unfinished attempt still has a denominator.
The request carries its observation alongside the original opaque ticket and
job key. Work and Tools capture their own original sources; the current Keeper
and other same-ID consumers cannot provide substitute provenance.

The root calls `Masc_tui_task_document_observation.run`, which uses the existing
named shared CPU submission path. Worker and caller facts surround that actual
submission and preparation without retries or inline replay on failure.
Exceptions and cancellation retain their original backtraces. Preparation's
isolated Unicode cache scope remains pure and non-yielding; diagnostic emission
occurs outside that scope.

`complete_task_document` records UI disposition after its actual admission or
rejection. Read withdrawal, supersession and current source/width mismatch stay
distinct. A rejection can retire only the exact physical slot owner. A completed
replacement remains untouched. Slot replacement, reading suspension and workspace
withdrawal record their original retirement reasons without inventing a caller
or worker result.

The existing workspace job registration emits cancellation request before
requesting cancellation, and registration release only after removing the
original key. Synchronous launch failure also releases its registration; it does
not manufacture worker entry. These callbacks map events to the captured request,
without reading a newer selection. A caller outcome and registry release are
independent facts; delivery does not prove cleanup.

## Data and interpretation boundaries

Facts are immutable first observations stored through an Atomic compare-and-set.
Each emitted event uses the exact immutable fact set accepted by that update,
not a later reread. Missing facts remain null. Logs use the existing Transport
sink and schema `masc.tui-task-document-observation/v1`. Emission failures do not
classify preparation; Eio cancellation still propagates. No new file destination,
runtime setting, gate, timeout, cap, scheduler or authority is introduced.

The source identity includes IDs and a fingerprint of the captured workspace
roots, not raw roots, Task text, context or exception details. The fingerprint
and ticket identify an attempt; they are not a digest of the full Task payload
or proof of a matched benchmark cohort. Preparation still compares the original
immutable inputs without hashing or scanning their complete text.

Monotonic timestamps are comparable within the same process only. The reported
submit-to-worker interval includes dispatch and queueing; worker-body elapsed
includes diagnostic overhead and is not pure CPU time. Request-to-UI-observed
elapsed includes observation overhead and either application or rejection.
Worker function return is not executor physical quiescence; registration release
is the workspace registry boundary. UI application can apply a failure and is
not paint, usable input, useful work or Task completion. No aggregate success or
synthetic zero-duration event fills a missing stage. Retention/sink availability
still needs actual runtime evidence; instrumentation alone does not guarantee a
complete retained dataset.

## Authored scenarios and evidence limits

The existing real first-loss Composition/resource scenario continues through
original Task/history producers and actual preparation ownership. A terminal
reply rejected at a different width, before reconciliation, must release only
its original pending owner; returning to the old width can create a live owner.
Existing late-width, independent body/history, same-ID cross-consumer and
suspension/reentry resource assertions remain. History preparation now traverses
the actual observation CPU wrapper and common workspace job, separately awaiting
result delivery and registration release before checking UI admission facts.
The scenario does not assume a shared pool is installed. These scenarios are
authored and **unexecuted**. No row, wording, layout, snapshot, PTY,
invocation-count or helper-mirror assertions are added.

Validation is OCaml parsing and whitespace inspection only. Local build,
typecheck/tests, CI dispatch/watch, model/native/PTY/controller/coordinator/report
runs, installation, restart, live prompt/configuration writes and own merge are
not performed. Visible behavior and latency improvement are unverified.

Future matched actual Before/After must retain failed, cancelled, interrupted,
rejected and unfinished attempts; include preparation and logging costs; and
match original input/resource conditions separately. No measured percentage,
speedup or completed cohort is claimed here. Original Ask to Task/useful work,
frozen preparation reuse, ordinary/nested/dynamic/effectful Composition,
held/shared-backend continuity, cold-start/TUI usability and actual matched
cohorts all remain active beyond this source unit.
