# Resource-ready ordinary Tool execution

Ordinary Tool execution already supports declared `Concurrent` calls. Calls
whose producer resolves exact occupied resources also support disjoint effects
in parallel. This change removes an unnecessary join inside that scoped region.
Composition has its own dependency executor; this guide describes ordinary
Agent Core Tool batches, not a new Composition or provider request policy.

## Before and after

Consider three prepared calls in input order:

- A occupies resource X and is slow.
- B occupies resource Y and finishes earlier.
- C conflicts with B on Y, but has no conflict with A.

| Boundary | Before | After |
|---|---|---|
| Initial admission | A and B run concurrently. | A and B run concurrently. |
| C admission | Wait for the entire A/B wave. | Wait for B's actual settlement and check for a known fatal failure. |
| C vs. A | C waits even though the resources are disjoint. | C can overlap A while no fatal failure is known. |
| Completion | Return ordered results after all started work settles. | Return ordered results after all started work settles. |

Ignoring setup and scheduling overhead, the old completion bound is
`max(A, B) + C`; the new bound is `max(A, B + C)`. These are dependency formulas,
not measured durations. There is no benefit when the actual critical path is
unchanged. Explicit predecessor edges, promises and waiting fibers add overhead;
the conflict graph may retain quadratically many edges in a dense region.
Neither that overhead nor an overall latency improvement has been measured here.

Every earlier conflicting call is a predecessor, including one that is itself
waiting. Settlement includes the existing observers and journal boundaries, not
just the handler returning. Multiple read/write claims and producer-supplied
ancestry keep their existing conflict rules. Original result order is preserved.

## Failure, recovery and surrounding boundaries

The initial roots form one admitted concurrent cohort. A hook, observer or
durability failure stops admission of new successors once it is known. Calls
already admitted still settle; their actual completed results remain available.
A successor may start before an unrelated root fails later. Removing the wave
join intentionally permits that overlap; the later failure cannot undo an
effect that already started. An ordinary model-visible Tool error keeps its
existing non-aborting behavior.

Opaque unscoped `Concurrent` regions and ordinary `Serial` calls still wait for
the whole preceding region. Terminal calls remain isolated, restored durable
occurrences retain their serialized recovery path, and cancellation still closes
the execution scope and prepared resources. Unstarted calls produce no invented
invocation, attempt or completion. Resource claims grant no additional permission
or replay authority.

`schedule.batch_index` and `schedule.batch_size` retain the deterministic planned
wave coordinates. They describe the plan, not a record of simultaneous execution
or a requirement to join every earlier wave. Hooks and projections must use actual
invocation lifecycle evidence to infer start/finish order.

## Evidence and next measurements

The authored feature scenarios cover a multi-resource successor chain overlapping
an unrelated root, suppression after a known peer failure, preservation of a
successor started before a later failure, and cancellation of predecessor waiters.
They have not been executed for this change. Parser and whitespace checks alone
do not establish type correctness, execution behavior or native/model speedup.

A future matched comparison should freeze the same Tool inputs, resource
bindings, hooks, persistence and provider conditions. Join actual start/finish
observations by the original Tool occurrence and invocation identities. Record
successor start after its last real predecessor, unrelated sibling overlap,
whole-batch completion, failed/unfinished samples and scheduler overhead. A
planned wave number alone cannot measure resource waiting.

Preparation still happens up front and this change adds no provider request. It
does not reduce model reasoning time, request bytes, TUI refresh time or
admission-to-first-useful-action time by itself. See
[Keeper preparation measurement](keeper-preparation-measurement.md) for those
separate boundaries.
