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

- `lib/keeper/keeper_unified_prompt.ml:467` - primary/short/mid/long goal lines
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

Post-turn memory writes happen after response finalization:

- reply-derived memory notes;
- tool-result memory notes when tool emission is enabled;
- episodic memory via `Memory_oas_bridge`;
- memory-bank compaction if needed;
- post-turn recall/goal-alignment evaluation.

Code anchors:

- `lib/keeper/keeper_agent_run_post_turn_memory.ml:23` - memory notes from reply
- `lib/keeper/keeper_agent_run_post_turn_memory.ml:40` - memory notes from tool results
- `lib/keeper/keeper_agent_run_post_turn_memory.ml:76` - episodic memory
- `lib/keeper/keeper_run_tools_hooks.ml:642` - OAS memory bridge creation

### 4. Tool surface selection

Keeper tools are not a static full MCP surface. `prepare_agent_setup` builds the
candidate bundle, then each SDK turn recomputes the visible tool surface from
the latest message context, deterministic prefilter, discovered tools, tool
affordances, overlays, fallback floor, and last-turn restrictions.

The actual OAS call receives `AllowList turn_visible_tool_names`.

Terminology is strict here:

- `allowed_tool_names`: policy/candidate surface after keeper profile and denylist
  resolution. This is not necessarily the exact set exposed to one SDK turn.
- `turn_visible_tool_names`: internal name for the per-turn resolved tool surface.
  It is the exact list passed to `Agent_sdk.Guardrails.AllowList`.
- `oas_allowlist_tool_names`: operator-facing decision-log field for that same
  list. This avoids introducing a second "visible tool" concept in audit logs.

Code anchors:

- `lib/keeper/keeper_run_tools_setup.ml:489` - compute per-turn tool surface
- `lib/keeper/keeper_run_tools_setup.ml:659` - final visible tool names
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

Follow-up started in this series: decision-log `tool_disclosure` records should
include the concrete `oas_allowlist_tool_names`, not only the final count, so an
operator can reconstruct exactly what the Keeper could call at that SDK turn.

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

Finding: moving to a repo/worktree is a `cwd` discipline plus path repair, not a
separate first-class state. The Keeper must call Execute/Edit/Read with the
right repo/worktree path.

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

### 8. Task result and PR evidence

Task completion and PR evidence are explicit task tool transitions.

`keeper_task_done` requires `task_id` and `result`, maps the result into
`handoff_context.summary`, and calls `Task.Tool.handle_transition` with
`action=done`.

`keeper_task_submit_for_verification` requires `task_id`, `notes`, and a valid
`pr_url`, then maps the PR URL into `handoff_context.evidence_refs` and calls
`action=submit_for_verification`.

Code anchors:

- `lib/keeper/keeper_tool_task_runtime.ml:717` - task done
- `lib/keeper/keeper_tool_task_runtime.ml:775` - submit for verification
- `lib/task/tool_task.ml:83` - transition argument normalization
- `lib/task/tool_task.ml:341` - evidence gate for verification submissions
- `lib/task/tool_task.ml:486` - persisted workspace transition
- `lib/task/tool_task.ml:525` - verification notification path

Finding: PR evidence can be persisted cleanly, but it is not automatic merely
because the Keeper ran `gh pr create`. The Keeper must call the task transition
tool or another explicit task/comment tool.

### 9. Receipt and lineage

The receipt records current task, goal IDs, requested/reported/observed/canonical
tools, final tool surface metrics, materialized tools, sandbox root, network
mode, approval profile, runtime, and context/memory injection sizes.

Code anchors:

- `lib/keeper/keeper_agent_run_receipt.ml:154` - receipt fields
- `lib/keeper/keeper_agent_run_receipt.ml:174` - requested/reported/observed tools
- `lib/keeper/keeper_agent_run_receipt.ml:181` - tool surface summary
- `lib/keeper/keeper_agent_run_receipt.ml:322` - tool lineage manifest

Finding: receipt and `Tool_lineage_recorded` can reconstruct tool visibility, but
the per-SDK-turn `tool_disclosure` log should carry names too. Without that, the
fast diagnosis path sees only counts.

## Visibility Matrix

| Surface | Model sees | Runtime enforces | Operator can audit | Status |
| --- | --- | --- | --- | --- |
| Allowed Path | Tool schema and path errors; world prompt may not list exact paths | path/cwd resolver and sandbox/allowed-path checks | tool call log context and runtime contract include allowed paths | Partial |
| Allowed Tool | OAS schemas filtered by `AllowList` | `turn_visible_tool_names` OAS allowlist plus candidate/deny execution gate | receipt/lineage names plus `tool_disclosure.oas_allowlist_tool_names` | Partial, first patch adds allowlist names |
| Assign Task | task counts, claim guidance, current task context | claim/start transitions and current-task reconciliation | backlog, receipt current task, task events | Good after claim; acquisition is advisory |
| Assign Goal | goal prompt and active-goal world state | advisory scope only | receipt goal IDs and goal progress JSON | Partial |
| Past Memory | memory context, checkpoint history, temporal context | memory hooks and checkpoint lifecycle | digests, memory files, post-turn eval | Good model-side; raw audit requires backing files |
| PR evidence | only if tool output/notes/transition show it | task verification requires real PR URL | handoff evidence refs and task events | Partial; not automatic from `gh pr create` |

## Work Queue

1. **Done in PR #20055**: add concrete `oas_allowlist_tool_names` to the
   per-turn `tool_disclosure` decision log. This closes the fastest
   observability gap without changing policy.
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
5. Decide whether PR creation should become a structured Keeper workflow, or
   whether explicit `keeper_task_submit_for_verification` remains the SSOT.
6. Add a first-class "worktree selected" observation if the Keeper should see a
   stable repo/worktree assignment rather than infer it from `cwd`.
