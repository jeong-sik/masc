# Ready Composition: retain the producer's immutable dependency order

Comparison base: `07f4e2117ab399e22daa341682965f4ea569d36b` (#43910).
This audit describes source structure, not measured execution or performance.

## As-Is / To-Be

`Ready.create` computes `Plan.dependency_layers` to build preparation barriers.
The successful Ready object retains the original plan and barrier index, but
previously discarded those layers. `execute_with_tool_use_id` subsequently
recomputed them for the same physically checked plan before sharing the new
value between scheduling and Ready binding order. The graph builder constructs
immutable dependency counts, successor adjacency, ordinal frontiers and layers
on every call; it is not just a field lookup.

Ready now retains the layers it already computed. Preparation barriers consume
that value, and the executor reads it through `Ready.dependency_layers` after
the existing physical plan-identity check. Scheduling and binding order continue
to share that exact original immutable value. This does not cache all plans or
change the public `Keeper_tool_plan.dependency_layers` contract.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Successful Ready preparation | Build layers, derive barriers, discard layers | Same build and barrier work, retain original layers |
| Execution with that original Ready plan | Build layers again | Read retained original layers |
| Execution without Ready | Build its own layers | Same ordinary path |
| Foreign plan with original Ready | Reject before graph construction | Same rejection before graph reuse |
| Unsupported/source-mismatched Ready creation | Return `None` before graph construction | Same boundary |
| Ready created but never executed | One graph build | Same build; longer retention of its layer lists |
| New Ready object or reconstructed plan | Own graph construction | Still own construction; no global cache |
| Dynamic inputs and file resources | Resolve, validate and bind at original node boundary | Same live producer/consumer operations |

## Owner and feature continuity

The production surface passes the same original plan to Ready creation and
execution inside its call-owned switch. The executor already rejects Ready
files whose `Ready.plan` is not physically the supplied plan. That check still
precedes selecting the retained graph; same IDs, structurally equal plans and
even identical node objects in a newly constructed plan do not bypass it.

The getter exposes immutable original nodes and their stable layers. It carries
no dynamic arguments, resolved input, binding promise, resource capability,
settlement, journal occurrence or execution grant. There is no caller-supplied
graph parameter, new replay channel, mutable cache, timer, limit or provider/tool
surface. Original plan construction and validation order are unchanged.

Preparation barriers still derive from the same stable topological order.
The executor still publishes bindings before predecessor waits and checks actual
file conflicts, opaque barriers and Serial success chains. Inputs resolve from
the current execution's validated outputs. Gate admission, handlers, effect
settlement, Fail_fast/Continue_independent behavior and switch-owned release
remain at their original boundaries. Sharing graph data does not reuse a prior
run's input, result or file authorization.

## Quantitative Before / After

For one successful Ready creation followed by one execution reaching graph
selection with that original plan, dependency-layer constructions change from
two to one. With `E` such executions of one Ready object, the source relation is
`1 + E` builds before and one build after. This includes executions that later
fail input validation, admission or effect handling; success is not the
denominator. Executions rejected before graph selection are excluded from `E`
in both versions and must remain in any actual outcome cohort.

For `E = 0`, both versions perform the same one build. The new object retains
the original `N` node-list cells and `L` outer layer-list cells longer and adds a
record reference; it does not duplicate the nodes or build another index.
Ordinary execution still performs its original one graph build. Actual barrier
classification, list flattening, binding promises and resource checks remain.

The two-to-one count is a source relation, not a 50 percent execution-time or
allocation-byte improvement. No runtime, memory, latency percentile, provider
round-trip, tool-call, batch or speedup measurement was performed. A matched
comparison must keep failed/cancelled/interrupted/unfinished and unused-Ready
samples rather than selecting completed executions.

## Compound scenario and evidence limits

The existing original-member resource scenario now attempts production executor
entry with a newly constructed plan containing the same original node objects
and the original Ready preparation. It requires rejection with unchanged real
file bytes, then executes the original plan and checks committed predecessor
bytes, original Task/parent identity and existing physical receipts. This tests
authority continuity through actual producer/executor/handler boundaries rather
than asserting getter identity or invocation/lookup counts. The aggregate
prepared-file branch keeps its original path. The scenario was not executed.

Existing source scenarios include consumers declared before their source Reads,
dynamic failed conflicts with an independent committed effect, mixed opaque and
Serial barriers, nested Skills, aliases and cancellation with successor resource
reacquisition. They were not executed for this change either.

OCaml parsing only passed for both changed interfaces, both implementations and
the changed scenario; `git diff --check` passed. No build, typecheck, test, CI
dispatch/watch, native/model/PTY/controller/report run, install, restart, live
write or own merge was performed. Independent current-head source approval,
compilation, physical execution, useful Task progress, usable input, visible
paint and actual Before/After performance remain separate evidence boundaries.
