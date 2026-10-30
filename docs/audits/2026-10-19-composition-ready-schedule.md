# Ready Composition: remove synthetic resource-order scheduling

Comparison base: `b3ff945af1417217101ef850f024f3293f32252a` (#43911).
All counts below describe source structure, not measured runtime performance.

## As-Is / To-Be

The executor represented Ready scheduling as `Some` resource dependencies with
one `(original node ID, [])` row for every plan node. This selected the generic
`prepared_layer` algorithm. For each node, that algorithm linearly found its row
and scanned every pending node for membership in its empty predecessor list.
Every node was therefore ready, preserving one concurrent static group per
dependency layer, but obtaining that result required redundant whole-list work.

Actual Ready file conflicts never came from those empty rows. They derive from
live producer bindings in the runner, after dynamic inputs resolve. Sending
Ready through the ordinary descriptor scheduler instead would change its
grouping and sharing; that is not the same operation.

The private `resource_ordering` type now distinguishes `Descriptor_order`,
`Prepared_order` with its real predecessor data, and `Ready_order`. Ready directly
maps each nonempty original dependency layer into the same concurrent static
group. Empty layers emit no group. No synthetic row list, row lookup or pending
scan is needed for this mode. No new index, cache, timer, cap, public parameter
or provider/tool surface is introduced.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Ready mode representation | Resource dependency option with empty rows | Explicit private Ready constructor |
| Ready static grouping | Generic prepared wave algorithm, all nodes ready | Same group directly from original layer |
| Ready empty resource rows | One per plan node | None |
| Ready pending membership scan | Every pending node for each node | None |
| Descriptor-only schedule | Descriptor grouping and Serial chain | Same branch and algorithm |
| Exact aggregate file schedule | Real resource dependencies and prepared waves | Same data and algorithm |
| Ready actual resources | Resolve input, bind, await/classify original bindings | Same runner |
| Ready success-predecessor accounting | Included by resource-option presence | Explicitly included for Ready and Prepared modes |

## Order, failure and resource continuity

The physical original-plan check still precedes selecting Ready mode and its
retained graph. A newly constructed plan cannot borrow the original preparation.
The original layer nodes, their order, contracts, planned indices, batch indices
and initial batch size/mode remain the same. The producer's retained dependency
layers and the execution-local shared suffix index keep their own scope.

The runner still publishes resolved bindings before awaiting earlier bindings.
Real file conflicts and original Serial-to-Serial chains retain Require_success;
opaque barriers retain their separate settlement policy. Required predecessor
outcomes still contribute to the dependency-blocked flag and commit ticket in
Ready mode. Ready barriers still contribute their observed tickets to Fail_fast
ordering. Removing the old option must not remove that failure accounting.

Live `Ready.exclusive` binding classification still determines shared/exclusive
gate acquisition and the leaf's actual serial schedule. Gate release, resource
authorization, actual handlers, compiled/nested dispatch, journal validation,
settlement observation, cancellation and switch-owned cleanup are unchanged.
The aggregate prepared-file path still uses its real predecessor list, and the
ordinary path still uses descriptor Serial ordering. No map iteration or string
matching selects a mode, execution order or failure policy.

## Quantitative Before / After

For a Ready plan whose `N` nodes form one dependency layer, the previous
scheduler's empty rows required `N * N` pending-entry visits and
`N * (N + 1) / 2` row-ID comparisons. Ready now performs zero of either operation
and builds no synthetic row pairs or enclosing row-list cells. It still visits
the `N` original nodes to build the group, resolves their original contracts,
builds the original planned-index map and creates the same final schedules.

At `N = 100`, that source-only illustration changes 10,000 pending-entry visits,
5,050 row-ID comparisons and 100 synthetic rows to zero in this scheduling path.
It is not a benchmark, an allocation-byte result or a speedup percentage.
For multiple layers, the old empty-predecessor pending visits sum to the squares
of the layer sizes; Ready now needs none of those visits.

Actual pairwise binding/resource checks still remain and may be quadratic.
Binding promises, selected predecessor lists, result settlement, provider/tool
calls and logical batch counts are not reduced by this change. Failed journal
or input admission can occur after static scheduling; those executions receive
the same removed setup work and must stay in a matched cohort. Foreign-plan
rejection and unused Ready creation remain distinct earlier boundaries.
Failed/cancelled/interrupted/unfinished cases cannot be dropped to claim speed.

## Existing feature scenarios and evidence limits

No helper, invocation-count, lookup-count, wording/layout/row-order, snapshot or
PTY test was added. Existing `test/test_keeper_prepared_edit.ml` scenarios already
exercise the affected feature boundaries with actual file producers/handlers:

- mixed public ordinary/file recipes require disjoint writes to overlap at
  authorization while preserving real bytes, Task/trace identity and receipts;
- mixed runtime cases retain opaque-failure continuation, Fail_fast refusal,
  Serial success requirements and parent replacement before file binding;
- consumers declared before source Reads retain dynamic failed conflicts and an
  independent committed file effect;
- nested Skills, aliases, original-plan/member rejection and cancellation with
  successor resource reacquisition retain their original boundaries.

These scenarios were source-inspected, not executed. Both changed executor
interface/implementation files passed OCaml parsing only; `git diff --check`
passed. No build, typecheck, test, CI dispatch/watch, native/model/PTY/controller/
report run, install, restart, live write or own merge was performed. Independent
current-head source approval, compilation, physical execution, useful Task
progress, usable input, visible paint and actual matched Before/After performance
remain separate, unproven boundaries for this layer.
