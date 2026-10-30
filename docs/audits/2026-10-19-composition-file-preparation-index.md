# Reuse original file preparation operands

Source comparison base: `1832f29972073810d34c0b96658694c1d54253d8`
(#43838). This layer changes file-resource preparation lookup in
`Keeper_prepared_inline_files`; it does not measure Loading, input, paint,
model latency or useful-work completion.

## As-Is / To-Be

An eligible aggregate already retains its exact instantiated plan. It does not
need a second plan instantiation. However, preparation searches the complete
validated-input list again for every node. Dependency projection and consumption
search the original prepared leaf list again. Ready binding searches the plan
members and resolves their producer contracts repeatedly; preparation-order
reads search another immutable association list.

The aggregate now walks canonical nodes and prepared inputs together, checking
both IDs and list termination. All literal inputs still finish validation before
any capability is acquired. It retains the ordered leaves and builds a private
typed-ID index referring to those same leaves. A failed transfer or exception,
including cancellation, still releases every earlier prepared operation.

Ready creation resolves each original member's contract once. Membership,
eligibility and predecessor construction use those retained contracts. Binding
first checks the indexed member's physical identity, then uses its contract and
the original resolved-input/file producer. Predecessor lists retain their
original order and are indexed separately. No map-key iteration drives effects.

| Boundary | Before | After |
| --- | --- | --- |
| Aggregate node/input pairing | Restart input search per node | One checked walk in original plan order |
| Aggregate dependency/consumer lookup | Search original leaves per node | Typed-ID lookup, then physical member check |
| Ready contract resolution in this module | Repeated for eligibility, predecessor building and binding | Once per original member during creation |
| Ready membership | Search original plan nodes on every bind | Typed-ID lookup, then physical member check |
| Ready preparation predecessor read | Search ID/list association entries | Typed-ID lookup of the same ordered predecessor list |
| Scope conflicts and opaque predecessor edges | Compare earlier resources/effects | Same comparisons and failure/settlement semantics |
| File handles and effect authority | Original producer and consumer guards | Same producers, owner/confinement checks and release scope |

## Quantitative source bounds

For a successful aggregate with `N` original file leaves, the old input join
compares IDs `N(N+1)/2` times. The checked walk compares `N` pairs. For example,
`N=32` changes this join from 528 to 32 ID comparisons; `N=128`, from 8256 to
128. These are mathematical source counts, not benchmark samples or tests.
The retained leaf index adds `N` ordered-map insertions and `O(N)` bindings.
Dependency projection or consumption of every original leaf changes its lookup
portion from `O(N^2)` scanning to `O(N log N)` map access. Each successful
consumer still checks the same physical node and model input.

For a supported Ready plan with `N` members, let `H` be the number visited before
the first file mutation is found. Successful creation plus one binding per node
previously called `Plan.contract` through this module `H + 3N` times: mutation
search, support validation, predecessor descriptor lookup, and binding. It now
calls it `N` times, with extra map construction and lookup costs. This excludes
all other callers of `Plan.contract` and ordinary per-input validation.
For `P` stored nonempty preparation predecessor lists, reads cost `O(log P)`
instead of an `O(P)` search; the returned original lists and their lengths are
unchanged.

Overall preparation is not claimed linear. Initial `Plan.contract` resolution,
input validation, pairwise file-scope conflict comparisons, opaque predecessor
construction, JSON equality, actual path work and effects keep their own costs.
Map allocation and small-plan timing are unmeasured. There is no concurrency
cap, new configuration knob, process-wide cache, polling or retry policy.

## Original authority and scenario evidence

Validated plans reject duplicate node IDs. Lookup by ID locates an original
operand; it does not authorize a copied node. Aggregate consumers still reject
a different physical plan, a copied node with the same ID, or changed input.
Ready binding still rejects a copied member. Its predecessor query remains an
ID-based read of existing edges, not an effect authorization boundary. All
resource scopes, explicit dependencies, Serial success requirements, settlement
barriers, branch-failure handling and ordinary fallback retain their semantics.

Two variants of one compound filesystem/protocol scenario are authored in
`test_keeper_prepared_edit`. A rejected copied member (and, for the aggregate,
reconstructed plan and altered input) leaves source bytes intact. The original
plan then executes two dependent real Edits on the same path, preserving
predecessor bytes, original Task/parent receipts and Gate results. Original node
IDs sort opposite to their effect dependency, so effects cannot follow map-key
order. Existing mixed ordinary/file, nested/dynamic, conflict and cancellation
scenarios remain in place. These scenarios are **unexecuted**. No layout,
wording, row-order, snapshot, PTY, helper-mirror or invocation-count test is added.

Only OCaml parsing and diff/changelog checks are performed for this layer.
Typing, executed scenarios, CI, native/model execution, deployment and visible
TUI behavior remain separate evidence. For matched Before/After, retain the same
original Task, plan and inputs, physical paths/aliases, model/provider, useful
effect/output and original receipt joins. Keep failed, cancelled, interrupted
and unfinished attempts; compare actual preparation/useful-effect/completion
clocks rather than deriving a speedup from the lookup counts above.
