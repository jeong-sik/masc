# Bind original plan operands and contracts once

Source comparison base: `b27b5a53f07d301e165e5ca6d0d33e75716ba65f`
(#43840). This is a source implementation comparison. No actual preparation,
Loading, input, paint, model or useful-work latency has been measured.

## As-Is / To-Be

File preparation and execution already retain indexes local to their scopes.
However, `Keeper_tool_plan.contract` searches the plan's original nodes, then
searches compiled arguments, child routes and descriptor names again. Constructor
validation repeatedly resolves those same contracts. Literal input preparation,
dynamic input/output validation, descriptor/effect queries and child export
schema projection reuse the immutable plan but repeat its resolution work.

The abstract plan now retains one typed-ID map of original node/contract pairs.
After canonical descriptors, compiled operands and duplicate node/tool names
have been checked, the original first known-tool validation binds each visited
node's resolved contract and stops at the same unknown/off-surface error. Later
validators keep their original list order and reuse those contracts. Only a
fully validated plan publishes that map; every retained entry has a resolved
contract, and unresolved nodes cannot become indexed successful operands.

Runtime contract/node lookup uses the same index. Original node lists still
drive validation, input preparation, dependency layers and effects. No map-key
iteration replaces an execution order. Child schema projection retains the
original child and exact export schema. Parameter binding rebuilds nodes through
the original constructor, producing a fresh map and plan identity.

| Boundary | Before | After |
| --- | --- | --- |
| Construction contract resolution | Repeat argument/child/descriptor search for each validator request | Bind once per original node; validators read that map |
| Public contract/descriptor query | Search original plan nodes and resolve their target again | Read this plan's original resolved contract by typed ID |
| Output producer and dynamic input producer lookup | Search original plan nodes again | Locate the same original node by typed ID |
| Child exported schema | Search declared nodes and resolve their target | Reuse declared plan's original node/contract bindings |
| Validation and first error | Original phase and list order | Same validators, phases, error tags and list order |
| Reconstructed/parameter-bound plan | New nodes and plan identity | New nodes, new index and new plan identity |
| Output capability | Exact plan/run/node/tool branding | Same checks; a retained contract is not an output capability |

## Quantitative source bounds and costs

For a successful construction with `N` nodes, `R` producer-reference entries
visited by `validate_output_references`, and `X` exports, the old resolver calls
`contract_for_node` `3N + R + X` times: known tools, output schemas, terminal
classification, producer references and exports. It now calls that resolver
`N` times to build the index. Validators still make their original reads and
perform their schema, graph and capability checks. For 32 nodes without producer
references or exports, this changes 96 target resolutions to 32. These are
mathematical source counts, not benchmark samples or elapsed-time estimates.

Let `A`, `C` and `D` be compiled argument, child and descriptor entry counts.
Original contract lookup can scan `O(N + A + C + D)` entries. Subsequent contract
and original-node lookup use `O(log N)` ordered-map access. Construction still
pays the original `O(A + C + D)` target resolution per node plus `N` map
insertions. The index retains `O(N)` original operand pairs and resolved
contracts; those records previously could be temporary allocations on every
query. Allocation, retained heap and small-plan timing remain unmeasured.

Known-tool refusal resolves the same original prefix and stops before later
nodes, while retaining map insertion cost for accepted prefix members. A later
schema/graph/terminal/export refusal retains the known-tool phase's completed
index until rejection. No later input/schema check or effect runs early; map
allocation must remain in failed-case comparisons. Duplicate/canonical/compiled
operand refusal still precedes index creation. Graph dependency scans,
cycle/terminal ancestry traversal, schema and
JSON work, resource conflict construction, physical preparation, dispatch and
observations retain their own costs. This is not an overall linearity or
end-to-end speedup claim.

## Authority and scenario evidence

All construction resolver requests originate in the original canonical node
list or `node_for_id` over that list. IDs are unique before the map is built.
The indexed node is the original immutable operand, and a child target retains
the same compiler-owned child object. Descriptor canonicalization, compiled
operand equality, surface denial, schemas, dependencies, terminal boundaries,
exports and first-error choice remain in their original checks. Known-node and
missing-output errors keep their original distinctions. Runtime output tokens
still require the exact plan identity, run ID, producer ID and tool name.

The existing typed producer-to-consumer scenario now continues after wrong-run
and reconstructed-plan output refusals: the reconstructed plan consumes its own
validated output, and the original plan remains usable with its original output.
The existing dynamic exact-child scenario now resolves each parameter-bound
child query through that rebuilt plan's real input contract instead of bypassing
it with raw template resolution. Distinct original child arguments, frozen
references and argument refusals remain asserted. Existing ordinary, compiled
argument/submission/result, export, graph refusal and file-resource scenarios
remain in place. These scenarios are **unexecuted**.

Four OCaml files receive parsing-only checks; diff and changelog checks are
separate. No typing, local build, scenario execution, CI dispatch/watch,
native/model/controller/report run, installation/restart, or visible input/paint
result is claimed. No layout, wording, row-order, snapshot, PTY, helper-mirror or
invocation-count test is added.

For matched Before/After, freeze Task, original plan/child references and inputs,
provider/model, resource topology, outputs and receipt joins. Keep constructor
refusals, failed, cancelled, interrupted and unfinished attempts alongside
successful useful effects. Compare original preparation/useful-effect/completion
clocks and actual allocation observations rather than converting lookup bounds
into milliseconds or a model-roundtrip claim.
