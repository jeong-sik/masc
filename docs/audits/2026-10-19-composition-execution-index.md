# Index original execution owners without changing their authority

Source comparison base: `bc0b1a16045e3726567ea38f83e7ce427aee08f7` (#43809).
This is a source implementation comparison. No preparation or runtime timing
has been measured for this layer.

## As-Is / To-Be

Dependency layers already use a stable immutable frontier and one graph result
per execution. Five fixed-identity lookups still scan lists repeatedly while
constructing schedules and running ready nodes. Dependency/resource fanout adds
more reads of the same promise owners; settling and collecting results searches
them again. The identities do not change during those scopes.

Use private immutable `Node_id` maps at those exact boundaries. One map resolves
original plan ordinals while a schedule is constructed. Ready execution builds
maps referring to the original scheduled nodes, Serial predecessor relation,
original outcome promise pairs and optional original file-binding promise pairs.
The maps do not manufacture a replacement owner on lookup.

| Boundary | Before | Source implementation |
| --- | --- | --- |
| Planned index | Scan original ID/index list for each scheduled node | Original ordinal table local to schedule call |
| Scheduled operand | Scan flattened schedule for each admission/cause | Same scheduled objects indexed within this execution |
| Serial predecessor | Walk filtered Serial chain for each request | One fold over original batches; lookup by original Serial node ID |
| Outcome owner | Scan original node/promise/resolver list per wait/settlement/collection | Same per-node promise pair in an execution-local table |
| File preparation owner | Scan original binding list per publication/predecessor wait | Same optional per-node binding promise pair in that execution |
| Node/batch/result order | Original list iteration | Same original list iteration, never map-key iteration |
| Outcome cells allocated | One per original node per execution | Same count and allocation scope |
| Binding cells allocated | One per original node only with ready files | Same count and condition |
| Reuse across runs | No reuse | No reuse |

For `N` scheduled nodes, the old planned-index lookup compares node IDs
`N(N+1)/2` times in total, because every original ordinal is found once. The
replacement inserts `N` ordinal bindings and makes `N` ordered-map lookups.
Building each other table uses linear passes over its original nodes/batches plus
ordered-map insertions; reads use `O(log N)` key lookup instead of an `O(N)` scan.
These are source operation counts and asymptotic lookup costs, not measured
speed, memory savings or an end-to-end complexity claim.

The implementation adds ordered-map allocation and comparison cost. Small-plan
timing and allocation effects are unmeasured. Dependency extraction, contract
lookup, prepared-input lookup, resource predecessor/prefix comparison, blocked
and failure state, dispatch and observation retain their own costs. This layer
does not establish total preparation or model-roundtrip latency.

## Owner and order invariants

The abstract validated plan has unique typed IDs; the private schedule builders
consume its stable layers and preserve each node once. These tables index that
canonical data rather than accepting an external lookup inventory. Required
missing canonical schedule/outcome/binding entries still raise the original
invariant error; lookup never creates a default promise or silently skips work.

Only Serial batches participate in the Serial predecessor relation, including
terminal scheduling represented by the original Serial batch constructor. A
concurrent node and the first Serial node have no Serial predecessor, as before.
Runtime ready-file resource ordering and preparation barriers retain their own
typed success/settlement requirements.

Each outcome/binding promise and resolver is allocated once inside its original
execution, using the original node list and condition. The immutable map holds
references to those cells; it does not make the mutable promise state immutable.
It is discarded with the execution and never keyed globally by node spelling.
No result, parameter, compiled child operand, Task/run identity, admission,
prepared file capability, cancellation decision or durable replay authority is
transferred to a different execution by this index.

The original lists still own fiber creation, node/batch order and canonical
result collection. Actual settlement/cause classification, completion tickets,
lowest-planned-index cause selection, file ownership and effect handlers remain
in their existing code paths. No public signature, wire schema, runtime knob,
Keeper prompt or live configuration changes.

## Authored evidence and limits

One additional compound scenario is authored and **unexecuted**. It reuses one
validated plan with the same node IDs across three fresh executions: interrupt
the producer while its original owner is pending; refuse one branch in the next
run while independent work settles; then complete a third run. It checks actual
dispatch/observer membership, original ordinals, canonical settlements, current
structured output and distinct original tool-use IDs, without settling the
interrupted observer from a later run. It uses the public plan/executor and
explicit dispatch fixtures, without a timer, model, candidate or PTY.

Existing authored cases cover forward-declared typed flow/Serial refusal,
private compiled-child argument binding, mixed ready-file overlap, source/parent
changes and cancellation/resource release. Those assertions remain unexecuted;
their presence is not proof of file-resource or nested continuity for this head.
No helper-mirror test, arbitrary graph cap, favorable timing threshold or TUI
wording/layout assertion is added.

OCaml parsing-only, diff and changelog checks establish syntax/metadata only.
No typecheck, local Dune build, test execution, CI dispatch/watch, native/model
run, install/restart or actual Before/After collection accompanies this layer.
Independent current-head source review remains pending. The full objective
still includes original Ask/Task/useful work, exact frozen preparation,
ordinary/nested/dynamic/effectful resource continuity, held/shared-backend work,
TUI readability/visibility and matched real observations retaining failures,
cancellations, interruptions and unfinished attempts.
