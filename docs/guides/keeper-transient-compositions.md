# Prepare and run a task-specific composition

Use `keeper_composition_prepare` to check a read-only plan before executing it.
The draft is local to the preparing Keeper; it does not publish a shared Skill.
The tools are discoverable through the Keeper tool search surface.

```json
{
  "execution": "inline",
  "nodes": [{"id": "lane", "tool": "keeper_lane_status"}],
  "exports": [{"name": "profile", "node": "lane", "pointer": "/profile"}]
}
```

Prepare returns the durable draft reference, exact execution mode, dependency
layers, descriptor schedule groups and selected output fields. The schedule is
an explanation of dependencies and execution contracts, not a fixed timetable.
Every fixed input is checked before prepare succeeds. Output-dependent inputs
are checked when their producers settle.

Pass the returned draft's exact sha256 to `keeper_composition_run`:

```json
{"sha256": "the exact 64-character digest returned by prepare"}
```

The run rechecks ownership, the frozen Tool/Skill surface and each node's
input/output schema and route before dispatch. If those contracts changed,
prepare again rather than silently executing a different preview. An invocation
record binds the draft to the actual source turn and tool-call identity before
any node executes. Plan validation does not bypass a leaf tool's permissions.

Use `execution: "async"` for an independent read whose wait would otherwise
occupy the Keeper. Run returns a durable request ID; completion uses the existing
Keeper wake. The request retains its draft/run references and original invocation.
The completion projection supplies canonical status, selected exports that fit
the existing inline context boundary, and the original task/turn/run references.
Use those results to continue the submitted task. Large results carry an exact
`result_reference`; read that reference with `keeper_composition_status`, and use
`keeper_composition_cancel` to request cancellation. Submission, completion and
cancellation acknowledgement are separate states. Async does not make the
external read itself faster.

Async admission records a completion-delivery obligation before a worker
starts. If the result is saved but its queue delivery fails, startup and the
existing maintenance pulse retry delivery from that exact canonical request.
The worker is never restarted for notification recovery. Pending/terminal
queue evidence prevents a completion from being admitted again after a crash
between delivery and acknowledgement, including after the original event has
already been consumed. Unreadable result or delivery evidence stays explicit.
Queue publication and same-source retries confirm strict durability before
acknowledgement. Conflicting terminal or tool payloads for the same pending
request are rejected. If the result record cannot be read or disagrees with
the completion, `result_available=false` and a structured error remain visible
in the next prompt; a wake alone is not proof of a usable result.

The initial transient execution contract admits static read-only ordinary nodes.
Writes, builds and terminal actions use their direct tools until their resource
and durable continuation contracts are implemented. The restriction is checked
again on load; an artifact reference is not a new execution permission.

[Output exports](keeper-composition-exports.md) select final fields while retaining
original results and failure evidence. Publish a reusable Skill separately with
`keeper_skill_publish` after checking execution evidence and applicability. A
published Skill and a draft remain distinct objects.

Named inline Skill compositions whose leaves are all statically read-only,
ordinary and concurrent may overlap with other such calls. Each invocation keeps
its own run identity, observations, activation records and causal history. The
turn still collects every completion for later judgments. A leaf that requires
serial access keeps its enclosing composition serial. Transient run and async
submission controls keep their serial admission contracts.

Nested composition references, draft-to-publish reuse, effectful resource-aware
jobs and fixed-condition latency measurements remain tracked in
[issue #42799](https://github.com/jeong-sik/masc/issues/42799).
