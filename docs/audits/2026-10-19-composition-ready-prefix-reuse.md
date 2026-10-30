# Ready Composition: shared predecessor-prefix traversal

Comparison base: `dc487fe9eba47db032074dd95c306f252cffebd2` (#43904).
This is a source change, not a measured runtime result.

## As-Is / To-Be

The production executor already shares one dependency-layer value between
scheduling and Ready binding order. For each node reaching predecessor
classification, however, `earlier_nodes` starts at the head of that order,
checks each ID and allocates a fresh list of earlier IDs. `List.filter_map`
then traverses that temporary list to await the original binding promises and
classify resource ordering. The existing planned-index table represents
declaration order, which is not necessarily topological binding order.

The executor now indexes original suffixes of the same immutable Ready order
by typed node ID. `filter_earlier` looks up the current node's suffix, visits
the original order directly until that suffix and emits only the selected
ordering predecessors. It uses the same tail-mod-cons shape as the installed
OCaml 5.5.1 `List.filter_map`. The suffix is a local traversal stop, not an
input, resource claim, permission or execution identity.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Ready prefix discovery | Scan IDs and build a prefix for every classified node | One execution-local suffix index, then direct traversal |
| Temporary full prefix | One cons per earlier node per classification | No reconstructed full-prefix list |
| Selected ordering predecessors | Separate filtered result list | Same selected result list, built during direct traversal |
| Binding and resource checks | Await and classify every earlier binding | Same original promises, order and classifications |
| Plan declaration order | Canonical schedule/result indices | Same indices; never used as binding-order stops |
| Ordinary execution | No Ready order | Empty Ready order and index; no added graph traversal |
| Failed/skipped nodes | May never reach classification | Still may not; new upfront index cost remains |
| Tool dispatch / batches | Original handler, gate and scheduling | Same boundaries; no claimed reduction |

## Original resources and ordering

The index is built after the existing original-order binding promises and the
single flattened Ready order. Neither promise creation nor ownership changes.
The index retains references to existing list suffixes; it copies no prefix or
plan node. Physical comparison is valid only inside this invocation because
both index construction and traversal use that exact immutable list. No suffix
or index escapes to another plan, replay, execution or global cache. Missing
membership or an unreachable stop is an invariant error, never an empty-prefix
fallback.

The callback still awaits every preceding binding, including when the current
binding is absent. Binding publication still precedes those waits. The actual
resource classifier, selected outcome waits, pre-binding opaque barriers,
Serial success chains, dependency/input validation, admission, failure policy,
effect settlement and switch-owned capability release remain at their original
boundaries. Map iteration does not choose execution, error or release order.

## Quantitative Before / After

Let `N` be the number of Ready nodes, `R` the nodes that actually reach this
classification, and `k_i` each such node's topological predecessor count. The
old full-prefix construction allocated `P = sum(k_i)` temporary ID-list conses.
The new traversal allocates zero such full-prefix conses. The selected ordering
result lists still exist, and all `P` actual predecessor classifications remain.

The tradeoff is `N` upfront typed-map insertions, `R` lookups and retained
references to `N` existing suffixes. Balanced persistent-map construction also
allocates tree paths; its allocation is not just `N` cells. This cost remains
when `R = 0`. The ordinary path has an empty index. Both versions already own
the same flattened Ready-order list.

If all 100 nodes reach classification, the structural formula gives 4,950
temporary prefix conses before and zero after, plus the new 100-entry index.
This is an illustration, not a workload run or a net memory measurement. The
necessary pairwise work can still be quadratic. No latency, allocation-byte,
provider-call, tool-call, throughput, percentile or speedup result is asserted.
Failed, cancelled, interrupted and unfinished executions cannot be omitted
from a future matched comparison.

## Scenario and evidence limits

The existing dynamic failed-conflict scenario in
`test/test_keeper_prepared_edit.ml` now declares consumers before their source
Reads. It still checks actual shared-file bytes after a failed Edit, refusal of
the conflicting successor, the independent Edit's committed bytes, the outer
failure and existing physical receipts. This exercises resolved graph order
with real file producers rather than a helper/index-count mirror. No assertion
about wording, layout, row order, snapshots or lookup counts was added.

Existing source scenarios also cover mixed Serial/opaque failures and parent
replacement, nested Skills, dynamic conflicts, original-member rejection and
cancellation with successor reacquisition. These scenarios were not executed.

OCaml parsing only passed for the executor interface, implementation and changed
scenario; `git diff --check` passed. No local build, typecheck, test, CI dispatch
or watch, model/native/PTY run, install, restart, live configuration write or
merge was performed. Independent source approval, compilation, physical
execution, useful Task progress, usable input, visible paint and measured
Before/After performance remain separate, unproven boundaries for this layer.
