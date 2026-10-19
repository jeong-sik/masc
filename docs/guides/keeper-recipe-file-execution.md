# File execution in task recipes

An inline task recipe can use the canonical `Edit` and `Write` Tools and exact
inline Skill children that contain them. The draft keeps each original
effectful descriptor and its filesystem authority. A Read output can supply
the original content to Write in the same run; Write uses its ordinary Serial
handler, Gate and publication recovery, including safe parent creation.

A source-bound eligible Read/Edit/Write plan can prepare its real file
capabilities for that invocation. Preparation records no Skill activation and
grants no effect authority. An output-dependent node binds its
resources only after upstream outputs validate its input. Independent leaves may run together.
Conflicting resources follow their existing canonical predecessor ordering,
alongside the plan's explicit `after` and input dependencies. The transient
`keeper_composition_run` itself retains its Serial outer descriptor.

## As-Is and To-Be

| Case | Previous behavior | Implemented behavior |
|---|---|---|
| Ordinary Edit in an inline recipe | Rejected as an unsupported prepared leaf | Uses its original effectful Serial producer and ordinary Gate checks |
| Ordinary Write or an exact inline child containing it | Rejected before executing the inline task recipe | Runs its original effectful Serial producer; upstream content can be written and read back in one run |
| Exact inline child containing Edit | Rejected by the enclosing draft | Keeps exact Skill identity, activation scope, original Task/turn and physical leaf receipts |
| Fully resolved inline Read/Edit recipe | No resource-owned execution path | Uses the same prepared file capabilities and conflict ordering as an existing named inline Skill |
| Fixed-input child flattened to Read/Edit leaves | No resource-owned execution path | Eligible for the same file preparation as ordinary recipe leaves |
| Conflicting files | Recipe rejected before execution | Consume the actual committed predecessor bytes in order |
| Cancelled prepared recipe | No such execution path | Its call-owned switch releases file capabilities; a new invocation acquires its own |
| Input depends on an earlier Read output | Ordinary execution | Binds the actual file producer when the input resolves; independent ready leaves may overlap |
| Exact inline child arguments depend on upstream output | Ordinary execution | Keeps the compiler-owned pure argument node and binds its original file leaves when ready |
| A resource cannot be prepared | Ordinary execution | Runs its original file handler alone, ordered against earlier file operations |
| Ordinary tools mixed with supported file leaves | The whole plan loses ready file preparation | Ordinary leaves keep their original handlers and modes; supported file leaves bind their own resources |
| Failed concurrent lookup before independent writes, `Continue_independent` | Ordinary file scheduling | Lookup settlement orders later mutations without becoming a file/data success dependency |
| Missing source or an unisolatable Gate callback | Ordinary execution | Retains ordinary node scheduling |
| Edit in an async scope | Rejected | Still rejected: an ordinary file Edit has no durable replayable launch identity |
| Write in an async scope | Rejected | Rejected through both catalog and nested admission; ordinary Write has no durable replayable launch identity |

Preparation uses the original Keeper, trace, Task and absolute Keeper turn.
Paths are derived by the existing filesystem producer from workspace and Keeper
configuration. The executor consumes the exact prepared plan, node and validated
model input, and the original handler rechecks owner/confinement. Unsupported
resource bindings never transfer a claim to an ordinary handler. The inline call's
switch releases every acquired capability, including on cancellation. No prepared
file capability is transferred to a durable async worker.

Ready nodes publish their resolved resource binding before waiting for earlier
bindings in stable topological order. A later node cannot assume an unresolved
earlier input targets a different file. Once identities are known, actual file
conflicts await predecessor settlement. A failed or skipped conflicting owner
prevents its successors from dispatching; independent branches follow the plan's
existing failure policy. Pure child argument validation has no file footprint.
An execution computes its immutable dependency layers once and shares them
between batch construction and ready binding order. The ready order is flattened
once, rather than rebuilding the graph for each node. This reuses original node
objects only; inputs, file preparation, Gate decisions and settlements still
resolve at their original boundaries. It is not a cross-call result cache.
See the [source comparison](../audits/2026-10-19-composition-dependency-order-reuse.md)
for traversal counts and measurement limits.
Read/Edit/Write plans retain supported file capabilities. Overwrite/Append Write
can bind existing physical parents or the deepest existing ancestor when child
directories are missing; unsupported paths retain the original exclusive handler.
Mixed ordinary Serial/Concurrent leaves retain their original handlers. Their
unknown footprint supplies an ordering barrier, never an invented file claim.
Before preparing a later file mutation, earlier opaque ordinary operations must
settle so the file producer captures the current physical paths. An earlier
ordinary Serial operation similarly precedes preparation of a later file read.
The immutable preparation-order index is built once from the original plan;
file-only plans have no opaque preparation predecessors. Ordinary Concurrent
leaves and prepared reads retain their sharing.

Real file conflicts, explicit plan dependencies and original Serial-to-Serial
chains require success. A barrier alone only requires settlement under
`Continue_independent`, so an unrelated concurrent lookup failure does not block
independent writes. `Fail_fast` still stops at an observed failed barrier. Files
without supported preparation retain the conservative exclusive fallback.
Terminal leaves and async child submission/result targets retain ordinary
scheduling. Named calls
without whole-plan scoped admission and transient
run calls retain their outer descriptor; only their inner ready file leaves overlap.
Whole-plan resource transfer to the outer named-call SDK batch still requires
only supported file leaves. A mixed ordinary/file plan keeps its Serial outer
envelope even when its inner file leaves are ready. See the
[mixed-plan source comparison](../audits/2026-10-19-mixed-ready-resources.md).

## Bind original Write resources when inputs become ready

The original Shared_mount Write producer now prepares opaque Overwrite/Append
resources as well as Read/Edit. It pins the selected allowed root and existing
target/resolved-source parents or ancestors without creating directories or files, reading content or asking
the Gate. The same ordinary Write handler revalidates the exact input, owner,
operation, current confinement and physical directory bindings before consuming
those capabilities. Overwrite retains its atomic publication/recovery path;
Append retains its existing pinned-file/exclusive-create semantics. Result and
Gate observers keep the original Task, parent invocation and physical leaf.

| Ready leaf | Previous scheduling | Source implementation |
|---|---|---|
| Disjoint existing Write targets | Exclusive barrier against every file leaf | Entry/object resource conflicts only; independent authorizations may overlap |
| New files under different existing parents | Exclusive barrier | Each actual parent owns its creation; independent parents may overlap |
| Missing files in one physical parent | Exclusive barrier | Parent creation claims preserve order; no guessed case or Unicode normalization |
| Append through hard links or directory aliases | Exclusive barrier | Actual inode/entry claims preserve backend conflict order |
| Write content/path from upstream outputs | Exclusive barrier after input resolution | The original producer binds resources after exact input validation |
| Missing directories under disjoint existing ancestors | Original exclusive handler | Each existing ancestor owns its subtree; independent authorizations may overlap |
| Missing directories under one physical ancestor | Original exclusive handler | The shared ancestor claim preserves order, including spelling and directory aliases |
| Endpoint trees or unsupported resources | Ordinary handler | Original exclusive handler, including authorized parent creation |
| Async file effects | Refused without replay authority | Same refusal; resource claims grant no replay permission |

An absent file has no object identity to unify filesystem spelling aliases, so
its physical parent carries the write claim. This also conflicts with reads or
mutations of other entries under that parent. Existing targets keep their actual
entry and object identities. A changed root, parent, owner or translated input
cannot fall back to an ordinary write after a preparation was accepted.

For missing parent directories, preparation only opens the deepest existing
ancestor. Before the original Gate, the consumer resolves the current target and
recomputes the remaining missing directories. A predecessor can create those
directories and the file: a preprepared Append then appends the predecessor's
bytes instead of attempting exclusive creation. The pinned ancestor must retain
its physical binding, and the resolved target and source must stay inside its
claimed subtree. A redirect outside that ancestor is refused even when its
destination is inside the allowed root. Directory creation and its commit
observations still belong to the original authorized consumer.

The immediate comparison baseline for missing-parent support is prepared Write
PR #43455 (`8fc42fc5b832fdd454b785ce347b1f103a65930a`). Before, such nodes
retained an exclusive barrier; after, they carry physical ancestor claims. A
shared existing ancestor still orders those writes. This changes scheduling
eligibility, not measured latency, the Serial outer invocation, async replay
authority or the original Gate/publication protocol.

Feature scenarios cover actual public recipe authorization overlap
for existing targets and new targets under independent parents, upstream content
with original Task/parent receipts, plus real consumer ownership/input/parent
refusal, hard-link append semantics, missing-entry conflicts and release. Added
missing-directory scenarios cover static and upstream-content recipes, no
preauthorization creation, predecessor Overwrite then preprepared Append,
ancestor aliases, disjoint/shared creation claims, released authority, ancestor
replacement and redirects within/outside the claimed subtree. They
are authored but not executed. The authorization rendezvous is a concurrency
observation, not a latency threshold. Source parser checks do not prove these
scenarios or a runtime speedup. For a matched Before/After, retain the same
original plan, inputs, outputs, authorization and physical-leaf counts, then
compare the actual useful effect/completion clocks including failed attempts.

Supply the existing one-call grammar when the plan is ready:

```json
{
  "recipe": {
    "execution": "inline",
    "nodes": [
      {
        "id": "update-left",
        "tool": "Edit",
        "args": {
          "file_path": "left.txt",
          "old_string": "before",
          "new_string": "after"
        }
      },
      {
        "id": "update-right",
        "tool": "Edit",
        "args": {
          "file_path": "right.txt",
          "old_string": "before",
          "new_string": "after"
        }
      }
    ]
  }
}
```

Existing files and real ownership still determine whether preparation succeeds.
For an inspection before execution, use `keeper_composition_prepare`, then run
its exact returned `sha256`. Preparing a draft performs no node effect.

## Before/After evidence

The abstract plan also binds each canonical node to its original resolved
contract once. Construction validators and later descriptor/input/output/child
export queries reuse that plan-owned index. Parameter binding and reconstruction
produce a fresh index and plan identity; previous plan/run outputs remain
ineligible. See the [plan source comparison](../audits/2026-10-19-composition-plan-contract-index.md)
for validation/error-order invariants, early-refusal costs and evidence limits.

File preparation retains the original plan's leaves, member contracts and
preparation predecessor lists in private immutable ID indexes. Lookup still
requires the original physical member; aggregate consumption also checks the
exact input and plan. Dynamic inputs and physical resource/owner checks keep
their existing validation boundaries. See the [source comparison](../audits/2026-10-19-composition-file-preparation-index.md)
for lookup costs, unchanged pairwise conflict work and unexecuted scenarios.

The feature scenarios extend `test_keeper_composition_nested` and
`test_keeper_prepared_edit`. They exercise the real public run Tool, actual
filesystem authorization/write handlers, frozen child Skill references, Task and
trace receipts, Gate aggregation, conflicting patches and caller cancellation.
An authorization rendezvous establishes overlapping independent writes without
using an invented elapsed-time threshold. It is not a UI layout assertion.

Authored scenarios and syntax checks are not executed-test evidence. Record the
exact candidate head and focused CI result when these scenarios run. No runtime
or model-preparation gain is claimed by this source change alone.

For a quantitative task comparison, freeze the same task/provider/Tool semantics
and retain preparation time, actual model POSTs and request bytes, useful effect,
completion and failed/unfinished samples separately. One outer recipe call can
replace multiple model-visible leaf calls without necessarily removing a model
POST: independent direct calls may already share one model response. Other
producer/effect combinations, durable async file-effect recovery and a real-model
paired cohort remain separate work. Dynamic Read/Edit input and nested argument
scenarios are authored alongside the original fixed-input scenarios; their
execution status must be read from the exact candidate's focused run.
