# Work Task observation retains its original producer identity

Follows #44044. That layer stabilizes equal Task values after a real read, but
its new list can differ physically from the raw backlog cache list. Repeated
observations of the same raw snapshot can then repeat index construction and
comparison. This unit carries source identity and stable values together in one
private immutable observation, through actual request/read/application consumers.

## As-Is / To-Be

| Boundary | Before this unit | Source behavior after this unit |
| --- | --- | --- |
| Saved Task data | Only the stabilized Task list is retained. Its raw producer list identity is lost. | One opaque Task observation retains the original immutable producer list and exactly equal stable Task values together. There are no parallel mutable identity/value fields. |
| Same producer snapshot | Even a raw backlog cache hit can rebuild the O(n log n) index and compare full Task values after stabilization. | Constant-time planning recognizes the identical raw immutable list and reuses the observation; no Task-comparison CPU submission. The actual read and fresh supplemental observations remain. |
| New producer snapshot | Exact typed Task comparison preserves equal values and fresh membership/order. | The same comparison runs on the shared CPU path for new nonempty producer lists. Its opaque result retains the new raw identity for the next observation. Cold/empty reads are immediate. |
| State and consumers | Work/domain readers consume a plain mutable-state list and request captures that list. | State/request/local reading carry the opaque observation. Constant-time getters expose its Task values to actual Work, Home/detail navigation and verification consumers. No UI Task scan/hash/copy is added. |
| Freshness/failure | Goal links, source errors/recovery and Task data are independently observed in the local read. | Reusing Task data cannot reuse those supplemental results. Fresh metadata/error fields stay with the new reading. Original workspace/base/source/request and cancellation/settlement rules remain. |

The pure module exposes an immediate-or-compare decision with an opaque CPU
comparison capture. Only its constructors can pair source and values. Equal
Task reuse retains the full typed equality and ambiguous-prior-ID policy from
#44044. It preserves new membership/order; no removed Task is resurrected.
Producer identity is in-process immutable data identity, not a persisted cursor,
source freshness, read/effect authority or a new mtime/global cache.

## Actual resource scenario

The existing real first-loss Composition/resource scenario already follows
actual Work reading across another Task write and an original Task content
change. It now rereads that real cached backlog while the independent primary
Goal-link registry is corrupted. The same immutable Task observation remains
stored, and the fresh authoritative Goal-link failure is separately observable.
The original registry bytes are restored in cleanup. Existing selected-Task
change and workspace-suspension/late-reply decisions continue through the typed
observation. No helper planner, CPU-invocation counter, display, wording,
row-order, snapshot or PTY assertions are added. Scenarios are **unexecuted**.

The new pure observation library depends on the existing domain types and
complete equality. Types/loader and test dependencies explicitly name it; it
does not depend on UI state, I/O, a scheduler or a global cache.

## Before/After limits

Only Task-payload planning for an unchanged raw snapshot becomes O(1), with
no full Task comparison or Task-comparison CPU submission on that path. The observation retains both raw and stable list references; their Task objects
can differ, so raw data can remain alive until the observation is replaced.
That retention and GC cost belongs in actual comparisons; lower memory use is
not claimed. The
whole Work read still performs its existing I/O, supplemental reads, projections
and diagnostics. New snapshots still build the index and compare Task content.
No total-CPU, Loading, input/paint or useful-work speedup is measured or claimed.
Future matched actual cohorts must include those costs and failed, cancelled,
interrupted and unfinished attempts.

Validation is OCaml parsing and whitespace/source inspection only. No local
build/typecheck/tests, CI dispatch/watch, native/model/PTY/controller/coordinator/
report run, install/restart, runtime prompt/config write or own merge. Module
graph inspection is not build/type success or scenario execution. All six
original feature/evidence axes remain active and incomplete.
