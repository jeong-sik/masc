# Composition file scopes: reuse original immutable values during comparison

Comparison base: `c1457a9194e8728c00e09af572cf2a00f4030546` (#43921).
This is a source comparison. No execution or performance was measured.

## As-Is / To-Be

Read/Edit scope getters delegate to `Keeper_prepared_file.scopes`, whose body
constructs a four-cell list from the original target/source entry and object
scope fields on each call. Write's getter returns its existing `resources` list.
These scope fields are immutable. The mutable `released` flag and current
owner/input/confinement checks belong to consumption, not scope retrieval.

Aggregate resource ordering previously rebuilt each prior leaf's scope list
while comparing every pair. It now carries each original prior ID and its
already-read scope list through the same ordered accumulator. Scope capture
remains inside this one ordering call, after the original plan/member checks.

Ready binding previously retained only the original operation. Pair ordering
read the left scopes once and reconstructed right scopes inside the predicate
for each visited left scope. A successful prepared binding now retains its same
operation and immutable scope list. Its original input resolution, opaque
settlement barriers and physical preparation still precede capture. Ordering
uses the two original lists directly in the same nested comparison order.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Aggregate current leaf scopes | One read per leaf | Same read, retained for later pairs in this call |
| Aggregate prior leaf scopes | Getter per pair | Same original list from accumulator |
| Ready binding | Original operation only | Same operation plus its original scope list |
| Ready file-pair classification | Getter inside nested comparison | Original lists captured with the two bindings |
| Write footprint | Existing resource-list field | Same list reference; no copied claims |
| Physical consumer checks | Release, operation, owner, input and confinement | Same live checks |
| Unknown/ordinary/pure binding | Existing mode and barriers | Same modes, no new scope capture |
| Pair comparison / result | Original scope order and Require_success rules | Same comparison order and rules |

## Ownership and lifecycle

The prepared records retain immutable scope values; no filesystem read,
revalidation, model lookup or callback occurs in these getters. The lifecycle
flag remains mutable and is deliberately not cached by this change. Consumers
still read it and revalidate the operation, exact owner/input and current
physical confinement. Retained scope metadata cannot consume a released token
or authorize a changed path, owner or input.

Aggregate scope/ID pairs are local to that ordering pass and are not returned
in the public ordering result. The Ready representation remains private behind
its abstract binding type. It adds a scope-list reference to the existing
operation binding; `Ready.operation` returns the same original operation. No
new field is added to a plan or the filesystem preparation objects, and no
global/cross-execution cache, guessed path claim, timer, cap or authority is added.

All Read/Edit/Write cases in the private binding classifiers retain explicit
operation matching. Original Serial classification, opaque settlement versus
success requirements, fallback exclusivity, Gate/handler dispatch, input checks,
failure tickets and switch-owned release keep their existing paths. Dynamic
Ready resources are still prepared only when their actual inputs are ready;
scope capture is not moved before the original binding/barrier boundary.

## Quantitative Before / After

For an aggregate ordering pass of `N` leaves and all `P = N*(N-1)/2` pairs,
scope-getter evaluations change from `N + P` to `N`. With all Read/Edit leaves,
the source constructs four temporary list cells per getter. At `N = 100`,
that is 20,200 former cells versus 400, plus 100 new ID/scope accumulator pairs.
The original accumulator list cells, output rows and actual scope comparisons
remain. Compiler optimization and actual allocation bytes were not measured.

For Ready, a file-pair comparison formerly read the left scopes once and the
right scopes once per visited left scope. When both are Read/Edit and all four
left scopes are visited, that is five getter evaluations, or 20 source list
cells for that pair. The new classifier reads no getters: each successful
prepared binding has captured its scopes once, with four cells for a Read/Edit
binding, shared across all of its pair comparisons. Early conflict can visit
fewer scopes, so it must not be counted as the full nonconflicting example.

The tradeoff is aggregate accumulator pairs and Ready binding metadata/list
retention. A single binding or one never compared previously needed no such
Ready list; it now pays capture cost. Write already returned a stored list, so
Write-only cases do not receive the four-cell-list saving and may pay additional
metadata overhead. The same applies when failures prevent later comparisons.
These costs and failed/cancelled/interrupted/unfinished cases must stay in any
matched cohort. Unused aggregate preparation adds no ordering snapshot cost.

Actual pairwise conflict tests can remain quadratic; physical claims, resource
authorization, tool/provider calls and schedules are not reduced. No time,
latency percentile, net memory, throughput or speedup result is asserted.

## Existing scenarios and evidence limits

Existing source scenarios cover aggregate and Ready file chains, same-layer
conflicts with next-layer dependencies, actual independent file effects,
dynamic failed conflicts, aliases/shared reads, nested Skills, original
member/plan/owner/input refusal and cancellation with successor reacquisition.
Their actual producer/consumer boundaries remain the evidence surface. None
was executed for this change. No getter/invocation/count mirror, wording/layout/
row-order, snapshot or PTY test was added.

The changed interface and implementation passed OCaml parsing only, and
`git diff --check` passed. No build, typecheck, test, CI dispatch/watch,
native/model/PTY/controller/report run, install, restart, live write or own merge
was performed. Independent current-head source approval, compilation, physical
execution, useful Task progress, usable input, visible paint and actual matched
Before/After performance remain separate, unproven boundaries for this layer.
