# Keeper Task Execution Visibility Audit

**Date**: 2026-06-04
**Scope**: `lib/keeper/**`, `lib/task/**`, `docs/keeper-turn-lifecycle.md`
**Baseline**: local `main` at `e75a4f38c892250fddd337359d91c860f4ae0164`

This audit follows one Keeper turn from the Keeper's own point of view:

1. start a turn,
2. observe work,
3. claim/start a task,
4. execute commands in the repo/worktree,
5. create branch/commit/PR,
6. attach the result back to the task,
7. persist receipt, checkpoint, and memory.

The purpose is to find missing teeth in the operational contract: what the
Keeper clearly sees, what only operators can reconstruct later, and what is
currently advisory rather than enforced.

## Flow

### 1. Turn entry

Autonomous turns enter through `Keeper_unified_turn.run_keeper_cycle` in
`lib/keeper/keeper_unified_turn.ml`.

Important steps:

- allocate `keeper_turn_id` from `meta.runtime.usage.total_turns + 1`;
- append `Turn_started`;
- enter the typed turn FSM at `Idle -> Phase_gating`;
- apply phase gate and runtime routing;
- build the unified prompt from `keeper_meta` and `world_observation`.

Code anchors:

- `lib/keeper/keeper_unified_turn.ml:24` - `run_keeper_cycle`
- `lib/keeper/keeper_unified_turn.ml:106` - `Turn_started`
- `lib/keeper/keeper_unified_turn.ml:245` - provider-awaiting and prompt build
- `lib/keeper/keeper_unified_prompt.ml:556` - final system/user prompt pair

### 2. World and goal visibility

The model-facing world state is rendered as `## Current World State`.
It includes active goals, namespace task counts, context utilization, continuity,
pending mentions, scope messages, claimable work guidance, and board activity.

Code anchors:

- `lib/keeper/keeper_unified_prompt.ml:920` - active goal section
- `lib/keeper/keeper_unified_prompt.ml:567` - active goals section
- `lib/keeper/keeper_unified_prompt.ml:574` - namespace task counts
- `lib/keeper/keeper_unified_prompt.ml:652` - continuity filtering
- `lib/keeper/keeper_unified_prompt.ml:687` - claimable work guidance

Finding: goals are visible and active goal assignment is now a hard claim
boundary. `Keeper_runtime_contract.resolve_claim_goal_scope` turns
`active_goal_ids` into the `Workspace.claim_next_r` `task_filter`; tasks outside
the active goal set are excluded and counted in `scope_excluded_count`.

Code anchor:

- `lib/keeper/keeper_runtime_contract.ml:49` - active goal task filter

### 3. Context, checkpoint, and memory

`Keeper_agent_run.run_turn` prepares the execution context before OAS dispatch.
It reconciles `current_task_id` from backlog ownership, loads the checkpoint,
loads active goal titles, and builds the base system prompt.

Code anchors:

- `lib/keeper/keeper_run_context.ml:51` - sync current task from backlog
- `lib/keeper/keeper_run_context.ml:97` - load checkpoint
- `lib/keeper/keeper_run_context.ml:127` - load active goal titles
- `lib/keeper/keeper_run_prompt.ml:146` - render memory context
- `lib/keeper/keeper_agent_run.ml:312` - manifest records prompt digests

Finding: past memory is real and model-facing through memory context, but the
runtime manifest stores digests rather than raw memory text. That is good for
privacy and size, but weak for operator reconstruction of exactly what the
Keeper remembered without reading the backing memory/checkpoint files.

Durable memory writes have explicit typed producers:

- `keeper_memory_write` tool operations;
- tool-result memory notes after response finalization when tool emission is enabled;
- memory-bank compaction if needed;
- post-turn recall/goal-alignment evaluation.

Code anchors:

- `lib/keeper/keeper_tool_memory_runtime.ml:626` - explicit memory write
- `lib/keeper/keeper_agent_run_post_turn_memory.ml:46` - memory notes from tool results
- `lib/keeper/keeper_agent_run_post_turn_memory.ml:165` - memory-bank compaction

### 4. Tool surface selection

Keeper tools are not a static full MCP surface. `prepare_agent_setup` builds the
candidate bundle, then each SDK turn computes a local OAS schema filter from the
latest message context, deterministic prefilter, discovered tools, affordances,
overlays, and last-turn restrictions.

That filter is execution input, not a Keeper-visible contract. Operator evidence
should come from requested, reported, observed, and materialized tool-use records.

Code anchors:

- `lib/keeper/keeper_run_tools_setup.ml:489` - compute per-turn tool surface
- `lib/keeper/keeper_run_tools_setup.ml:659` - final allowed tool names
- `lib/keeper/keeper_run_tools_setup.ml:712` - tool requirement is Optional when tools exist
- `lib/keeper/keeper_run_tools_hooks.ml:480` - OAS allowlist guardrail
- `lib/keeper/keeper_run_tools_hooks.ml:515` - tool call log turn context

Finding: execution is allowlist-filtered at OAS dispatch, but the older
`tool_access` naming is misleading. Runtime execution uses candidate tools minus
the denylist; narrow `tool_access` does not hide descriptor-backed tools.

Code anchors:

- `lib/keeper/keeper_tool_policy.ml:289` - allow set retained for compatibility
- `lib/keeper/keeper_tool_policy.ml:321` - execution gate uses candidate/deny semantics
- `lib/keeper/keeper_tool_policy.ml:397` - Keeper allowed names are candidate minus denied

Follow-up in this series removed the decision-log disclosure record as an
operator evidence surface. Operators should reconstruct execution from receipt
lineage and actual tool-call logs, not a per-turn candidate list.

### 5. Task claim and task assignment

Task acquisition is a tool action, not an unconditional FSM transition.
When the Keeper calls `keeper_task_claim`, the runtime resolves advisory goal
scope, applies WIP admission, calls `Workspace.claim_next_r`, syncs
`current_task_id`, and auto-starts the task if needed.

Code anchors:

- `lib/keeper/keeper_tool_task_runtime.ml:521` - task claim handler
- `lib/keeper/keeper_tool_task_runtime.ml:546` - `Workspace.claim_next_r`
- `lib/keeper/keeper_tool_task_runtime.ml:556` - sync current task
- `lib/keeper/keeper_tool_task_runtime.ml:569` - auto-start
- `lib/keeper/keeper_current_task_reconcile.ml:126` - backlog ownership sync

After a claim-only turn, the next OAS turn gets an explicit nudge telling the
Keeper not to call claim again and to use an execution tool or report a blocker.

Code anchor:

- `lib/keeper/keeper_run_tools_hooks.ml:316` - claimed-task nudge

Finding: task assignment is clear once a task is owned. The acquisition step
itself remains advisory/model-chosen; if claim tools are hidden or the model
chooses text-only output, no hard "must claim before execution" transition fires.

### 6. Execute, git, branch, commit, and PR

Git and GitHub work is not a first-class PR workflow state machine. It is typed
command execution through the `Execute` public descriptor backed by
`tool_execute`.

The schema accepts `executable`, `argv`, optional `pipeline`, `cwd`, timeout, and
typed stdin/stdout/stderr redirects. Raw shell command strings are rejected.

Code anchors:

- `lib/tool_shard_types_schemas_execute.ml:205` - Execute schema description
- `lib/keeper/keeper_tool_execute_runtime.ml:263` - typed Execute runtime
- `lib/keeper/keeper_tool_execute_runtime.ml:421` - destructive command block
- `lib/keeper/keeper_tool_execute_runtime.ml:430` - write-operation gate
- `lib/keeper/keeper_tool_execute_runtime.ml:457` - Shell IR dispatch

`cwd` is resolved into the Keeper sandbox, explicit allowed paths, repo clones,
or repo worktrees. `repos/<repo>/.worktrees/<task>` is recognized as a worktree
root. Repo/worktree paths are validated and can be repaired before execution.

Code anchors:

- `lib/keeper/keeper_tool_execute_path.ml:56` - repo/worktree path context
- `lib/keeper/keeper_tool_execute_path.ml:124` - execution location JSON
- `lib/keeper/keeper_tool_execute_path.ml:267` - worktree repair path
- `lib/keeper/keeper_tool_execute_path.ml:418` - write cwd resolution

Finding: moving to a repo/worktree is still a `cwd` discipline plus path repair,
not a persistent global Keeper state. PR #20055 makes the selected worktree a
first-class Execute observation: `execution_location.worktree_selected`,
`worktree_name`, and `selected_worktree` identify the repo/worktree assignment
without requiring the Keeper or operator to reparse `cwd`.

### 7. Tool dispatch and side-effect safety

Tool calls pass through OAS argument validation, workflow-rejection gates,
resource permits, and Keeper dispatch.

Code anchors:

- `lib/keeper/keeper_tools_oas_handler.ml:38` - schema validation
- `lib/keeper/keeper_tools_oas_handler.ml:187` - resource gate
- `lib/keeper/keeper_tool_dispatch_runtime.ml:352` - execution allow check
- `lib/keeper/keeper_tool_dispatch_runtime.ml:397` - runtime context and dispatch

The unified turn tracks committed mutating tools through the OAS event bus. If a
provider error or wall-clock timeout happens after mutating tools, retry is
blocked or reclassified to avoid duplicate side effects.

Code anchors:

- `lib/keeper/keeper_unified_turn.ml:304` - side-effect retry rationale
- `lib/keeper/keeper_unified_turn_execution.ml:362` - committed tool snapshot
- `lib/keeper/keeper_unified_turn_execution.ml:390` - ambiguous partial commit path
- `lib/keeper/keeper_unified_turn_execution.ml:803` - timeout after committed tools

Finding: retry safety exists. PR #20055 also wires the stale post-Execute
change hook: after a successful `Execute` result with a concrete `cwd`, the
handler reads `git --no-optional-locks status --short` and injects non-empty
status output into the normalized tool result as `changes`.

Code anchor:

- `lib/keeper/keeper_tools_oas_handler_exec.ml:13` - post-Execute git status helper
- `lib/keeper/keeper_tools_oas_handler_exec.ml:435` - change block injected into the result envelope

### 8. Task result and verification evidence

Task completion evidence is an explicit task tool transition.

`keeper_task_done` requires `task_id` and `result`, maps the result into
`handoff_context.summary`, and calls `Task.Tool.handle_transition` with
`action=done`.

The old task-verification wrapper is retired. PR URLs,
commits, artifacts, receipts, test logs, task comments, or other concrete
references belong in `keeper_task_done` result text or typed
`handoff_context.evidence_refs` on the raw transition surface.

Code anchors:

- `lib/keeper/keeper_tool_task_runtime.ml:717` - task done
- `lib/keeper/keeper_tool_task_runtime.ml:775` - submit for verification
- `lib/task/tool_task.ml:83` - transition argument normalization
- `lib/task/tool_task.ml:341` - evidence gate for verification submissions
- `lib/task/tool_task.ml:486` - persisted workspace transition
- `lib/task/tool_task.ml:525` - verification notification path

Finding: verification evidence can be persisted cleanly, but it is not automatic
merely because the Keeper ran `gh pr create`. The Keeper must call the task
transition tool or another explicit task/comment tool. Keeper code must not
treat PR URL or any single reference shape as the verification SSOT; evidence
semantics live in the task/CDAL domain.

### 9. Receipt

The receipt records current task, goal IDs, sandbox root, network mode,
approval profile, runtime, and context/memory injection sizes. Tool-call detail
is kept in the tool call log instead of being reconstructed as requested,
materialized, or lineage summary fields on the receipt.

Code anchors:

- `lib/keeper/keeper_agent_run_receipt.ml` - receipt fields
- `lib/keeper_tool_call_log.ml` - tool call log entries

Finding: the old receipt lineage summary was removed. Fast diagnosis should read
the concrete tool call log and hook/runtime events, not duplicate candidate-list
or lineage projections.

## Visibility Matrix

| Surface | Model sees | Runtime enforces | Operator can audit | Status |
| --- | --- | --- | --- | --- |
| Allowed Path | Tool schema and path errors; world prompt may not list exact paths | path/cwd resolver and sandbox/allowed-path checks | tool call log context and runtime contract include allowed paths | Partial |
| Tool Use | OAS schemas filtered locally by `AllowList` | local schema filter plus safety guards | requested, reported, observed, and materialized tool-use evidence | Execution input only; no Keeper-visible tool contract |
| Repo / Worktree Seat | Execute result `execution_location.selected_worktree` after a worktree-scoped call | `cwd` resolver, repo readiness, and worktree repair | Execute result envelope and post-Execute change hook | Good after Execute; not a persistent assignment |
| Assign Task | task counts, claim guidance, current task context | claim/start transitions and current-task reconciliation | backlog, receipt current task, task events | Good after claim/start |
| Assign Goal | goal prompt and active-goal world state | `active_goal_ids` hard-gate `keeper_task_claim` | receipt goal IDs and goal progress JSON | Good for claim scope; goal progress remains observational |
| Past Memory | memory context, checkpoint history, temporal context | memory hooks and checkpoint lifecycle | digests, memory files, post-turn eval | Good model-side; raw audit requires backing files |
| Verification evidence | only if tool output/notes/transition show it | task verification requires an evidence-bearing handoff, not a PR URL shape | notes, optional evidence refs, and task events | Good for wrapper; not automatic from `gh pr create` |

## Work Queue

1. The per-turn tool disclosure log was removed; tool visibility evidence now
   comes from requested, reported, observed, and materialized tool-use records.
2. **Done in PR #20055**: add a dedicated post-Execute working-tree status
   path for successful `Execute` calls with a concrete `cwd`.
3. **Done in PR #20055**: split `tool_access` wording from execution
   semantics in docs/UI/API. The field now reads as a candidate profile; actual
   execution still depends on descriptor/registry availability, denylist,
   per-turn OAS allowlist, and eval gates.
4. **Done in PR #20055**: make `active_goal_ids` a hard `keeper_task_claim`
   gate. The resolver now passes a goal-linked task filter into
   `Workspace.claim_next_r`, and no-scope results report excluded tasks instead
   of falling back to all work.
5. **Superseded after PR #20055**: the explicit task-verification wrapper is retired. Keepers close PR
   work with `keeper_task_done` and include PR/artifact evidence in `result`;
   `gh pr create` alone does not mutate task completion state.
6. **Done in PR #20055**: add a first-class "worktree selected" observation to
   Execute `execution_location`. This keeps repo/worktree choice tied to the
   actual `cwd` that runtime enforced, but surfaces the stable assignment as
   `selected_worktree` instead of requiring string parsing.
