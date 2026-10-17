# File execution in task recipes

An inline task recipe can use the canonical `Edit` Tool and exact inline Skill
children that contain it. The draft keeps the original effectful descriptor;
it does not classify an Edit as a read or give it a new filesystem authority.

Once a source-bound run is recorded, an eligible Read/Edit plan can prepare its
real file capabilities for that invocation. An output-dependent node binds its
resources only after upstream outputs validate its input. Independent leaves may run together.
Conflicting resources follow their existing canonical predecessor ordering,
alongside the plan's explicit `after` and input dependencies. The transient
`keeper_composition_run` itself retains its Serial outer descriptor.

## As-Is and To-Be

| Case | Previous behavior | Implemented behavior |
|---|---|---|
| Ordinary Edit in an inline recipe | Rejected as an unsupported prepared leaf | Uses its original effectful Serial producer and ordinary Gate checks |
| Exact inline child containing Edit | Rejected by the enclosing draft | Keeps exact Skill identity, activation scope, original Task/turn and physical leaf receipts |
| Fully resolved inline Read/Edit recipe | No resource-owned execution path | Uses the same prepared file capabilities and conflict ordering as an existing named inline Skill |
| Fixed-input child flattened to Read/Edit leaves | No resource-owned execution path | Eligible for the same file preparation as ordinary recipe leaves |
| Conflicting files | Recipe rejected before execution | Consume the actual committed predecessor bytes in order |
| Cancelled prepared recipe | No such execution path | Its call-owned switch releases file capabilities; a new invocation acquires its own |
| Input depends on an earlier Read output | Ordinary execution | Binds the actual file producer when the input resolves; independent ready leaves may overlap |
| Exact inline child arguments depend on upstream output | Ordinary execution | Keeps the compiler-owned pure argument node and binds its original file leaves when ready |
| A resource cannot be prepared | Ordinary execution | Runs its original file handler alone, ordered against earlier file operations |
| Missing source or an unisolatable Gate callback | Ordinary execution | Retains ordinary node scheduling |
| Edit in an async scope | Rejected | Still rejected: an ordinary file Edit has no durable replayable launch identity |

Preparation uses the original Keeper, trace, Task and absolute Keeper turn.
Paths are derived by the existing filesystem producer from workspace and Keeper
configuration. The executor consumes the exact prepared plan, node and validated
model input, and the original handler rechecks owner/confinement. Unsupported
resource bindings never transfer a claim to an ordinary handler. The inline call's
switch releases every acquired capability, including on cancellation. No prepared
file capability is transferred to a durable async worker.

Ready nodes publish their resolved resource binding before waiting for earlier
bindings in stable topological order. A later node cannot assume an unresolved
earlier input targets a different file. Once identities are known, only actual
conflicts await predecessor settlement. A failed or skipped conflicting owner
prevents its successors from dispatching; independent branches follow the plan's
existing failure policy. Pure child argument validation has no file footprint.
Plans containing other tools or async child submission/result targets retain
ordinary scheduling. Named calls without whole-plan scoped admission and transient
run calls retain their outer descriptor; only their inner ready file leaves overlap.

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
