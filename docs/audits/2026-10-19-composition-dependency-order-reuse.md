# Reuse one dependency order within a Composition execution

Source comparison base: `5ba35837d30d45c5068c76acd64fca6f6147f2ee` (#43794).
Source work counts only; no measured runtime, input or latency claim.

## As-Is / To-Be

`Keeper_tool_plan.dependency_layers` rebuilds stable topological layers by
partitioning remaining nodes and checking their dependencies against completed
nodes. The executor previously called it for batch construction, then again for
every ready node that reached predecessor classification. Each such call also
flattened the same graph. The immutable plan did not change during execution.

The executor now computes the layers once from that original plan. Private
batch construction accepts those layers, and the ready runner flattens the same
value once for all predecessor classifications. Public `schedule` still
computes the layers for its own explicit scheduling request. The ordinary
non-ready runner does not build a flattened ready order.

Let `R` be the number of ready nodes that actually reach predecessor
classification, including any pure argument nodes on that path. It is an
observed/source path count, not a new limit or configuration value.

| Boundary within one executor invocation | Before | After |
| --- | --- | --- |
| Dependency-layer reconstructions with ready binding | `1 + R` | `1` |
| Ready-order flattening | `R` | `1` when the ready runner starts |
| Dependency-layer reconstructions without ready binding | `1` | `1` |
| Flattened ready order without ready binding | `0` | `0` |
| Per-node predecessor prefix scan | Existing scan | Same scan |
| Input/resource/Gate/result checks | Original per-node boundaries | Same boundaries |

For the admitted lookup plus two supported disjoint Writes from #43794, all
three nodes reach ready classification in the success path. The corresponding
source counts are four graph reconstructions to one and three flattenings to
one. These are not executed counters, batch counts, speed ratios or provider
roundtrips. If no node reaches classification, the old path flattened zero times;
the new ready runner still creates one shared flattened order. If journal or
static input admission rejects before the runner starts, it creates no ready
order. The retained list, prefix scans and actual file preparation still have
costs. No timing or memory benefit is asserted.

## Identity and execution boundaries

The shared value is local to one invocation and contains only original immutable
node objects. A different plan, run, instantiated input or call computes its own
layers. There is no global cache, serialized token, new authority, generation or
heuristic cutoff. Prepared-file membership still checks the exact plan. Dynamic
input validation still waits for its actual upstream output. Actual file
producers still acquire current capabilities after opaque preparation barriers.

Stable layer/node order and schedule metadata construction are unchanged.
Ready publication, explicit data dependencies, real file conflicts, opaque
wait-only barriers, original Serial success requirements, branch policies,
exclusive fallback, cancellation, Gate and physical receipts keep their existing
logic. Sharing a graph value cannot substitute for a successful predecessor,
permission to dispatch, a file identity or an observed result.

The source count covers the executor's batch and ready-order boundary only.
Independent preparation factories, including the ready factory's opaque
preparation index and fully prepared aggregate resource collection, retain their
own graph traversal. This is not a claim that the entire preparation pipeline
traverses the graph only once.

## Evidence and limits

This change adds no implementation-mirroring call-count test or timer assertion.
Existing compound scenarios cover public mixed ordinary/file dispatch, lookup
refusal under both branch policies, Serial refusal, physical parent replacement,
dynamic Read outputs, explicit dependencies, conflicting committed bytes and
caller cancellation followed by a fresh invocation. They remain unexecuted for
this candidate under the operator's code-only scope. Existing ordinary executor
scenarios also cover independent branches and a dependent starting while an
unrelated branch remains held; this refactor does not turn their source into
executed evidence.

Parser and diff/changelog checks do not prove typing, test assertions, actual
overlap, independent approval, merge, installation, TUI input/paint or speed.
No Dune build, local tests, CI, native/model run or restart is performed. A later
matched Before/After must retain the same task, graph, provider and filesystem
semantics, count useful effects and requests, include all preparation costs,
and preserve failed, cancelled, interrupted and unfinished samples.
