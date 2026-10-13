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

To continue a prepared async run, pass the same draft digest and its original
`composition_run_id` to the existing run tool:

```json
{"sha256": "the original draft sha256", "resume_run_id": "the original composition_run_id"}
```

Continuation creates a new async request under the original run, invocation
artifact, source turn and task. The previous request must have an exact canonical
durable terminal record before the new worker can take ownership. A queued,
running, cancelling or unreadable prior request cannot authorize another worker.
Reusing the argument is an explicit request to continue, not notification recovery.

Completed nodes retain their complete typed result and original occurrence IDs;
they do not dispatch or emit another ordinary tool observation. Their outputs
are validated against the frozen plan in the new executor before downstream
inputs use them. An unfinished read-only attempt from a previous owner, or a
failed node with producer-proven pre-effect evidence, can dispatch again.
Deferred results and failed nodes with unknown or post-effect evidence cannot.
Missing, corrupt, foreign or conflicting run evidence remains a typed refusal;
the tool never converts it into a fresh run. This continuation applies to
prepared async ordinary read-only drafts. Owned external-job suspension and
effectful resource admission remain separate work in issue #42799.

The initial transient execution contract admits static read-only ordinary nodes.
Writes, builds and terminal actions use their direct tools until their resource
and durable continuation contracts are implemented. The restriction is checked
again on load; an artifact reference is not a new execution permission.

[Output exports](keeper-composition-exports.md) select final fields while retaining
original results and failure evidence. Publish a reusable Skill separately with
`keeper_skill_publish` after checking execution evidence and applicability. A
published Skill and a draft remain distinct objects.

For a reusable parameter-free plan, add Skill metadata during prepare:

```json
{
  "execution": "inline",
  "skill": {"package_id": "lane-profile", "description": "Returns the current lane profile when checking lane capabilities."},
  "nodes": [{"id": "lane", "tool": "keeper_lane_status"}],
  "exports": [{"name": "profile", "node": "lane", "pointer": "/profile"}]
}
```

The draft freezes both the plan and validated `SKILL.md` bytes. Its preview
identifies the source by digest. Use the same draft digest to run, validate
and publish; no handwritten TOML or repeated source-text submission is needed:

```json
{"package_id": "lane-profile", "draft_sha256": "the exact draft sha256"}
```

Pass this to `keeper_skill_validate`. For `keeper_skill_publish`, add a
non-empty `evidence` list naming the execution references that support the
reusable procedure. Validation proves static admission; it does not prove an
execution succeeded. Both calls check the frozen owner, package and tool
contracts before using the source. A task-only draft cannot be published this
way. Publication preserves the editor's no-overwrite and shadowing outcomes
and returns the exact source digest. It does not add a tool to the frozen turn.

Generated composition fences use `plan_json`, the canonical parameter-free
structured plan codec. It preserves JSON null, arrays and escaped values
without a separate TOML literal conversion. The parser refuses mixing it with
`nodes`, `params`, `exports` or `branch_failure_policy`; all belong inside that
encoded plan. Hand-authored parameterized Skills still use the existing TOML
node/parameter form and `source_text` or an exported artifact.

Named inline Skill compositions whose leaves are all statically read-only,
ordinary and concurrent may overlap with other such calls. Each invocation keeps
its own run identity, observations, activation records and causal history. The
turn still collects every completion for later judgments. A leaf that requires
serial access keeps its enclosing composition serial. Transient run and async
submission controls keep their serial admission contracts.

Nested composition references, effectful resource-aware
jobs and fixed-condition latency measurements remain tracked in
[issue #42799](https://github.com/jeong-sik/masc/issues/42799).
