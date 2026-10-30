# Task document preparation outside repeated frame work

Relates #42799 and follows #43991. The previous unit connected exact original
Task/history inspection. This unit addresses repeated full-document preparation
in both actual Work and Tools consumers. All six original axes remain active.

## As-Is / To-Be

| Boundary | Before | Source behavior after this change |
| --- | --- | --- |
| Full Task body | Each draw/count wraps description, contracts, handoff and evidence again. | An immutable input captures the exact Task object, Goal reading and actual pane width. The loop prepares complete rows through the existing CPU pool; draw/count/scroll reuse those rows. No full Task hashing or structural content scan in input equality. |
| Event history | Each draw recreates and wraps every observed event. | The original immutable event list and actual width form a separate preparation input. Current pending/failure metadata remains outside the prepared event body. |
| Independent results | Full body/history work executes synchronously while building the frame. | Body and history own separate asynchronous preparation jobs. Either can finish first. HTTP/data retrieval remains unchanged and independent. |
| Source update | No prepared source lifetime exists. | Exact source/consumer, Task/run, Goal observation, width, read epoch and opaque ticket must still match at completion. Old width, other consumer, replaced source and withdrawn replies cannot settle the current preparation. |
| Retention | Drawing always rebuilds the source. | Same-source/same-width prior rows remain explicitly earlier content while newer rows are prepared or preparation fails. Another source/width cannot borrow them. The Work reader keeps its stored scroll while row preparation is incomplete. |
| Evidence meaning | Build timing includes full document text wrapping on every invocation. | Separate `task.document.body.prepare_wait` and `task.document.history.prepare_wait` observations cover CPU queue/work/return. Prepared rows authorize no retrieval, effect, replay or Task completion. No input/paint or latency improvement is claimed. |

## Actual producer and consumers

`task_document_inputs` captures the selected domain Task for Work or the exact
original request/run/Task reading for Tools. It never picks a current Keeper
Task. Goal unavailability remains distinct from no membership. Task identity is
read from the original immutable payload; equality uses its object identity,
not repeated serialization or a digest of its description. Event-list identity
is likewise immutable. Input comparison includes actual pane width and the
separate Goal reading.

The loop reconciles demands before drawing, shares an in-flight identical
input, and launches the existing CPU execution path in original workspace
observation jobs. Source/width changes retire only the original preparation
job. Actual cleanup retains the common registry's ownership. Completed immutable
rows are retained in UI-owned slots, and both Work and Tools render/count those
same rows. Tools avoids wrapping these already bounded rows a second time.
The live read status, partial-field diagnostics and errors still come from the
current source readings, not a cached document.

The shared Unicode display-piece cache previously assumed UI-only wrapping.
Its storage is now domain-local, and document preparation uses a private cache
scope restored on success or exception, including the existing inline fallback.
This preserves the UI's two-frame reuse policy while avoiding concurrent table
mutation and retaining worker Task text beyond that preparation. The separate
UI-only chat row-count cache is unchanged; no claim of general layout-thread
safety is made.

Workspace suspension retires pending preparation without turning it into a
completed reading; the same source can prepare again. Workspace withdrawal
clears all rows/provenance. Failed preparation does not loop automatically;
source reread, reentry or width/source change can create a new input. No new
timer, worker pool, timeout, size cap, history cap, retry limit or runtime gate
is introduced. Complete text remains available after preparation.

## Authored scenarios and evidence limits

The existing real first-loss Composition/resource scenarios now continue from
actual exact Task/history producers into the actual UI preparation ownership.
Authored delayed completions cover width change, independent history/body
settlement, a same-ID Task moving from its original async source into the Work
consumer, and suspension/reentry. These occur inside the original resource and
journal continuity scenario; no row/wording/layout/snapshot/PTY, invocation-count
or helper-mirror assertions are added. The scenarios are **unexecuted**.

Validation is OCaml parsing and whitespace inspection only. No local
build/typecheck/test, CI dispatch/watch, native/model/PTY/controller/coordinator/
report run, install, restart, live prompt/configuration write or own merge is
performed. Actual visible behavior, input/paint, runtime usefulness, matched
Before/After and speedup remain unverified. Full-document preparation costs and
failed/cancelled/interrupted/unfinished samples must remain in future matched
measurement denominators.

The original Ask to Task/useful-work chain, preparation attribution/frozen
discovery reuse, ordinary/nested/dynamic/effectful Composition continuity,
held/shared-backend continuity, cold-start/TUI visibility and matched actual
cohorts remain active. This source optimization does not replace their evidence.
