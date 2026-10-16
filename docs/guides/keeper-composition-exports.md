# Select a composition's final fields

A composition can return named fields from declared node outputs. Its nodes
still run through the canonical plan validator and executor. Input/output
references, permissions and execution order do not change.

```toml
[[compositions]]
name = "read-path"
execution = "inline"
branch_failure_policy = "continue_independent"

[[compositions.exports]]
name = "path"
node = "read"
pointer = "/path"

[[compositions.nodes]]
id = "read"
tool = "Read"
[compositions.nodes.input]
kind = "literal"
value = { file_path = "probe.txt" }
```

`exports` is optional. Each export names a node and an RFC 6901 pointer into
that tool's composable output schema. Unknown nodes, opaque producers, unknown
fields and duplicate export names are rejected before execution. A nullable
field returning JSON null is available; an absent optional field is reported
unavailable. Do not add exports to a tool whose producer has no typed output.

When exports are present, the result contains `exports`, every plan node's
settlement and execution disposition, any failure cause/effect disposition,
and `execution_artifact`. The artifact holds the complete original result and
settled node records, including intermediate inputs and results. Use the
existing artifact reader with its normalized reference when those details are
needed. Persistence failure reports failure and never advertises an unstored
result. It does not rerun tool effects.

At the model boundary, a small exported result stays immediately readable in
`structured_content`, alongside an exact `artifact_manifest` reference. Failure
diagnostics remain visible too. The complete envelope must fit the tool's typed
projection ceiling; larger selected outputs keep the existing manifest marker.
Async status retrieval follows the same rule, with the selected result under
`structured_content.result`.

The execution artifact uses the canonical manifest MIME/schema. Its
`structured_content` contains `result`, `nodes` and `retained_artifacts`, so
offline retention follows intermediate artifacts through explicit typed edges.
Skill composition evidence and terminal async request records independently
retain that execution document even when no Keeper checkpoint remains.

Without exports, the composition retains its full result. Export selection is
not a text summary or a length cutoff. Large selected values still follow the
normal tool-output externalization contract.

`branch_failure_policy` accepts `fail_fast` (the default) or
`continue_independent`. The latter keeps branches unrelated to a failed node
running and returns their results alongside the failure; descendants of a
failed producer do not run. Parameter binding and durable JSON plan encoding
retain this policy and the exact exports. Async admission still requires the
existing static read-only tool contract.

The structured plan request uses the same declarations:

```json
{
  "branch_failure_policy": "continue_independent",
  "nodes": [{
    "id": "read",
    "tool": "Read",
    "input": {"kind": "literal", "value": {"file_path": "probe.txt"}}
  }],
  "exports": [{"name": "path", "node": "read", "pointer": "/path"}]
}
```

The [transient prepare/run tools](keeper-transient-compositions.md) use this
request codec and describe the eligibility of named inline compositions for
parallel execution. Completion wakes project selected exports and original
task/run references from the canonical owned request, or an exact lookup when
they do not fit inline. This preserves failed-branch availability, cause and
unknown-effect evidence. It does not copy full intermediate bodies into the
durable queue. See [exact Skill children](keeper-nested-compositions.md) for
nested export/input mappings and [owned jobs](keeper-owned-jobs.md) for effect
ownership and result continuation. Their execution evidence and remaining
integration work are tracked in [issue #42799](https://github.com/jeong-sik/masc/issues/42799).
