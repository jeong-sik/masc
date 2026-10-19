# Prepare and run a task-specific composition

Use `keeper_composition_prepare` to check a task-specific plan before executing it.
The draft is local to the preparing Keeper; it does not publish a shared Skill.
The tools are discoverable through the Keeper tool search surface.

An ordinary Tool node accepts fixed arguments as an object:
`{"id":"lane","tool":"keeper_lane_status","args":{}}`.
Use tagged `input` for output-dependent templates. Fixed `args` normalizes to
the existing literal input AST; the canonical encoded plan still uses `input`.
Supplying both forms or non-object `args` is rejected before execution.
Represent a Skill child with its exact `skill_reference`; its callable Tool
name does not make it an ordinary node Tool. Both fixed `args` and a resolved
tagged child `input` must match the Skill's parameter object schema.
Leave optional `after` out or supply an array of node IDs (`[]` means no
explicit dependencies). `after: null` is invalid.

When the plan is ready to execute, submit the same prepare input as
`keeper_composition_run.recipe` in one call:

```json
{"recipe":{"execution":"inline","nodes":[{"id":"lane","tool":"keeper_lane_status"}],"exports":[{"name":"profile","node":"lane","pointer":"/profile"}]}}
```

The server validates and durably freezes the recipe, binds the original SDK
invocation, then uses the same inline or async executor and leaf permissions.
The result retains both `draft` and `run_artifact` references. This avoids a
required model roundtrip between preparation and execution; it makes no fixed
latency promise. Use separate prepare when inspection is useful. Supply exactly
one of `recipe` or `sha256`; a fresh recipe cannot include `resume_run_id`.
To continue an async run created from a recipe, use its returned draft digest
and original run ID in the ordinary continuation form below.

When an immutable input artifact's address is already known, add its
`keeper_artifact_read` as an ordinary recipe node. Bind the exact Skill child's
tagged `input` to that node's `/content` output, and export both the selected
input and required child result. This preserves the physical upstream read
inside one execution. The model receives the selected values from the exports.
See [current Task schema readiness](keeper-task-schema-readiness.md)
for the initial callable surface and measurement boundaries.

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

New-request acceptance reads only that request's canonical active and terminal
records rather than inventorying unrelated active requests. Terminal precedence,
strict identity decoding and agreement with a current-process Queued reservation
are checked before the original source context and run ownership CAS. This proof
describes the record at read time; the submitting callback still owns the
before-worker boundary. Unreadable or conflicting exact evidence refuses admission
without changing the records. Timing comparisons of these two acceptance reads
do not measure total preparation time or external tool latency.

Completed nodes retain their complete typed result and original occurrence IDs;
they do not dispatch or emit another ordinary tool observation. Their outputs
are validated against the frozen plan in the new executor before downstream
inputs use them. An unfinished read-only attempt from a previous owner, or a
failed node with producer-proven pre-effect evidence, can dispatch again.
Deferred results and failed nodes with unknown or post-effect evidence cannot.
Missing, corrupt, foreign or conflicting run evidence remains a typed refusal;
the tool never converts it into a fresh run. This continuation applies to
prepared async ordinary drafts. An original owned-job result wait uses its
sealed canonical continuation; completed launch nodes retain their full result
without recreating the job. An interrupted launch node — an unfinished
attempt, or a failure whose effect outcome is unknown — replays instead of
refusing the whole run: the durable occurrence recorded the exact invocation
identity and complete original source (Task, trace, TurnRef, tool-use ID and
optional Keeper turn). The resuming owner passes that source to an Existing-only
invocation transaction. If the invocation binding was never written and every
owned-job journal and pending completion marker is readable without carrying
that exact original source, the interrupted attempt never reached the backend,
so the resuming owner reserves the original invocation once and completes the
initial launch; otherwise it can observe only the original job, and a missing,
unreadable or different binding cannot reserve a replacement.

A first interrupted launch can recover through `resume_run_id` without inventing
a prior result wait. Unavailable replay authority leaves the physical attempt
Lost and its logical completion pending, with no failure notification. Restore
the exact original authority before resuming. Once a launch requires Existing-only
recovery, a later pre-effect refusal cannot turn it into a fresh launch. A genuine
pre-effect failure of the initial launch retains its ordinary retry behavior.
A launch node without its complete recorded identity keeps refusing replay.

These journal records require the exact original identity and replay-mode
fields. Missing evidence is rejected rather than inferred or rewritten into
fresh work. Inline task recipes can also use canonical Edit leaves through their
original file producer; this does not give those effects durable async replay.

Async prepared plans admit static read-only ordinary nodes, owned Ask questions
(`masc_ask`), and the isolated owned-job
launch action. The descriptor and canonical action classify admission; a job
launch keeps its existing Serial effectful contract. Other writes, builds,
status/cancel effects and terminal actions use their direct tools until their
resource and durable continuation contracts are implemented. Admission is
checked again on load; an artifact reference is not a new execution permission.

[Isolated jobs](keeper-owned-jobs.md) provide direct durable start/status/cancel
handles for programs operating in private Docker workspaces. Their producer
records create/start intent before effects. A prepared async recipe can launch
with `keeper_job_start`, bind `/job_id` into `keeper_job_result`, and continue
dependent artifact consumers when the original result is complete. Startup,
existing maintenance and durable completion hints use the same original-run
continuation; current denial, unavailable authority and unknown effects retain
the original run. When the launch leaf itself is interrupted between its
durable attempt and its settlement — a crash, or a lost reply around the
backend create/start effect — the run stays resumable: the journal replays the
leaf with the invocation identity recorded on the occurrence, the invocation
binding resolves to the original job, and the reconciled launch settles
without a second create. An admission that cannot derive that complete
identity refuses the launch before any durable attempt instead of starting a
job the run could not re-prove.

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
turn still collects every completion for later judgments. Without producer-owned
resource preparation, a serial leaf keeps its enclosing composition serial.
Transient run and async submission controls keep their serial admission contracts.

Dependency layers are derived once per execution from the validated plan using
immutable dependency counts and successor adjacency. Each layer retains original
declaration order and the actual compiler-owned node operands. Serial execution,
failure propagation and file-resource ownership remain executor decisions; a
dependency frontier grants no admission or replay authority. This reduces repeated
graph scanning in source, with no measured timing claim. See the
[source Before/After audit](../audits/2026-10-19-composition-dependency-frontier.md).

Scheduling and ready-wave lookup also use immutable indexes local to their
original call/execution. These refer to original ordinals, scheduled nodes,
Serial predecessors and the same execution's outcome/file-binding promise pairs.
The original node and batch lists still determine iteration and result order;
no promise, prepared resource or settlement is shared between executions. See
the [lookup source audit](../audits/2026-10-19-composition-execution-index.md)
for the bounded operation-count change and unexecuted owner-lifetime scenario.

When the current Task pins an exact executable composition, its callable schema
and declared ordinary node Tool schemas are supplied on the first request. Their
deferrable declarations still apply when that exact Task selection is absent.
This needs no fresh discovery/read and records no activation. See
[Task schema readiness](keeper-task-schema-readiness.md) for source identity,
scope and Before/After measurement.

Inline Skills and task recipes with at least one Edit or Write can bind
producer-owned file claims with the original call source. Alongside canonical
Read/Edit/Write leaves, inner ready plans accept ordinary Serial/Concurrent
Tools and pure compiled child argument validation. Opaque ordinary leaves keep
their handlers and execution modes; they order against file mutations without
claiming a file. Later file capabilities are prepared after these opaque
predecessors settle. Ordering alone does not propagate a concurrent lookup's
failure under `Continue_independent`; real file/data dependencies and original
Serial success chains remain. Terminal and async child submission/result
targets are outside this ready path. Upstream
inputs and exact inline child arguments bind when their values resolve. Read/Read
sharing and disjoint ready files may overlap; conflicting effects retain
topological order. Unprepared file operations use their ordinary handler alone.
Missing source or unisolatable causal callbacks retain the ordinary schedule.
Named fully resolved file-only Write and Read/Write Skills can also transfer
their aggregate resource claims to the outer SDK batch. This uses existing Write
preparation; it grants no new effect or durable async file-mutation admission.
Mixed ordinary/file plans retain their Serial outer envelope.
See [recipe file execution](keeper-recipe-file-execution.md) for supported dynamic
and nested inputs and [file resource ordering](keeper-file-resource-ordering.md)
for physical entry, ancestry and owned-tree Read behavior.

See [exact Skill children](keeper-nested-compositions.md) for nested inputs and
exports, and [owned jobs](keeper-owned-jobs.md) for durable effect ownership and
continuation. Resource claims alone do not authorize another effect or replay.
Fixed-condition latency evidence and remaining integration work are tracked in
[issue #42799](https://github.com/jeong-sik/masc/issues/42799).
