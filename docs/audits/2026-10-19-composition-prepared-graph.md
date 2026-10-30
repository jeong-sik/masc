# Exact prepared files: share the resource producer's dependency layers

Comparison base: `d59efcd80a0675d312ec6e56672e08800b67f9c9` (#43918).
This is a source comparison, not a runtime or performance result.

## As-Is / To-Be

The aggregate prepared-file producer built `Plan.dependency_layers` to visit
original leaves and derive resource predecessor rows. Its result discarded the
layers. Non-Ready execution then built the same immutable plan graph again for
scheduling. Ready already shared its own original layers; this duplicate work
remained specifically in the aggregate prepared-file path.

The producer now returns a private immutable `resource_ordering` record with
the original layers and original predecessor rows. The executor selects its
scheduling mode and layers together, builds the existing predecessor index from
the original rows, and gives scheduling the producer's same layers. The replaced
`resource_dependencies` function has no compatibility wrapper. A tracked OCaml
caller/interface census found only its definition, interface and executor use;
all have been changed together.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Matching aggregate resource ordering | Build graph, return rows, discard layers | Build same graph, return original layers and rows |
| Subsequent aggregate scheduling | Build graph again | Use producer layers |
| Runtime predecessor index and waits | Original row lists in execution-local map | Same rows and map construction |
| Unused aggregate preparation | No resource-order graph build | Same zero builds |
| Ordinary execution | Build its own graph once | Same one build |
| Ready execution | Read retained original Ready graph | Same retained graph |
| Foreign aggregate plan | Producer returns `None` before its graph build | Same boundary and ordinary scheduling fallback |
| Dynamic inputs/resources/authority | Original validation and consumers | Same boundaries |

## Original plan, members and order

Physical plan equality still precedes the aggregate producer's graph build.
Each graph node is then looked up in the existing original-member index and
checked by physical identity, before resource edges are collected. Missing or
copied membership keeps its original invariant error. The record is returned
only after all these checks and the original edge collection.

The record retains original immutable nodes, including their plan templates,
and predecessor ID lists. It adds no prepared operation/capability, separately
captured runtime input/result or grant fields.
Its private record representation permits reads while preventing construction
or field replacement by the consumer. There is no caller-supplied graph option,
new global cache, replay channel, timer, cap or public tool/provider parameter.

Selection now binds mode and graph together before the effect-summary closures
are defined. This moves only pure graph selection across function definitions;
the resource producer's plan/member/edge checks retain their original order.
Ready's physical plan check still precedes access to its retained layers. The
ordinary graph constructor retains its fresh-per-call public contract.

Original layers still own schedule iteration. Original predecessor lists still
own outcome wait order, and the layer-local pending set/index retain the prior
list-driven static waves. Journal/input admission, failure tickets,
Fail_fast/Continue_independent behavior, handler dispatch, Gate checks, actual
file consumers and switch-owned cleanup keep their existing paths. A graph
record neither authorizes effects nor replaces any owner, input or confinement
check. It does not carry a previous run's outputs into another execution.

## Quantitative Before / After

For one executor entry that obtains matching aggregate resource ordering and
reaches the old subsequent graph-selection point, graph constructions change
from two to one. For `E` such entries, the source relation is `2E` before and `E`
after. Each call still constructs its own ordering; this is not retention across
executions. These entries can later fail journal/input admission, handler work
or cancellation; completed executions are not the denominator.

An aggregate preparation that never enters resource ordering performs zero
ordering graph builds in both versions. A standalone ordering call without
execution performs one in both versions, now retaining its layers in the result.
Foreign-plan rejection occurs before the producer build; member rejection after
its first graph build retains that earlier cost. Those cases must remain in a
matched actual cohort, separately from entries receiving the removed second
build. Ordinary and Ready graph counts are unchanged.

The tradeoff is the small immutable result/selection wrappers and retaining the
producer's original layer-list references until execution is done. No graph
nodes, predecessor lists or new index are copied for this transfer. Existing
row-index construction, pending-set work, resource-pair classification, list
flattening, schedule creation and physical tool calls remain. The two-to-one
source count is not a 50 percent runtime or allocation-byte improvement. No
latency, percentile, throughput, net memory or speedup was measured. Failed,
cancelled, interrupted and unfinished samples cannot be dropped from a matched
actual Before/After comparison.

## Existing feature evidence and limits

The existing original-member scenario has four real file effects across a
same-layer conflict and a next-layer explicit dependency. Aggregate-prepared
and Ready paths retain refusal of copied members/foreign plans, unchanged
pre-execution bytes, both files' committed predecessor bytes and original
Task/parent/receipt/Gate coverage. Other existing source scenarios cover actual
alias conflicts, nested Skills, dynamic bindings and cancellation with successor
resource reacquisition. These scenarios were not executed for this change.

No helper/getter/count mirror, wording/layout/row-order, snapshot or PTY test
was added. Both changed interfaces and implementations passed OCaml parsing
only, and `git diff --check` passed. No build, typecheck, test, CI dispatch/watch,
native/model/PTY/controller/report run, install, restart, live write or own merge
was performed. Independent current-head source approval, compilation, physical
execution, useful Task progress, usable input, visible paint and actual matched
Before/After performance remain separate, unproven boundaries for this layer.
