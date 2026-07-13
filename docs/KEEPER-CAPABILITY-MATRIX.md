---
status: reference
last_verified: 2026-07-04
code_refs:
  - lib/keeper/
  - lib/tool/tool_dispatch.ml
  - lib/keeper/keeper_tool_descriptor.ml
  - config/prompts/keeper.world.md
  - config/prompts/keeper.capabilities.md
---

# Keeper Capability Matrix

Keepers do not receive the full public MCP surface.
They get keeper-native tools plus `masc_*` tools that are executable without
MCP runtime/session context. This matrix names internal handler IDs for
implementation/audit purposes; model-facing prompts and recovery hints must use
the exact active schema names, such as the public `Execute` alias when it is
listed.
Triage and trigger detection run on each heartbeat using the proactive idle/cooldown settings.

## Tool Catalog and Descriptor Surface

`Tool_shard` is a legacy module name for an immutable catalog facade. It has no
runtime membership, grant/revoke API, per-Keeper override, recovery floor, or
read-only/removable classification. Its schema families are flattened and
de-duplicated into one complete Keeper catalog. The descriptor/registry
projection determines exact model-facing names; execution-time external
effects converge on the Gate.

Current exact tool names must come from the active schema. Use
`keeper_tools_list` / `keeper_tool_search` when unsure.

Schema files remain grouped by domain only for code ownership: base/context,
Board, filesystem/search/execute, library, Channel/Connector surface, Task, and
voice. These groups do not affect availability or authorization.

Notes:
- The old governance petition/case subsystem is retired. Collaboration uses Board/Goal/Task, while external effects use the product-neutral Gate and its approval audit.
- Write-capable tools such as `tool_edit_file` and `tool_write_file` are present in the Keeper catalog. Descriptor/registry availability determines which typed tools exist, and external effects converge on the Gate.
- Typed command execution is model-facing as `Execute`, backed by the `tool_execute` descriptor route.

## Tool Surface

All keepers receive a descriptor/registry-driven active schema. The prompt rule
is: call only exact names in the active schema, and inspect with
`keeper_tools_list` / `keeper_tool_search` when unsure.

Core model-facing public aliases include `Execute`, `Grep`, `Read`, `Edit`,
`Write`, `WebSearch`, and `WebFetch` when the descriptor/registry projection
contains them. Internal
descriptor-backed families can also appear by exact keeper or masc tool name.
Important families:

- context/tool introspection: `keeper_context_status`, `keeper_tools_list`,
  `keeper_tool_search`
- board/task communication: `keeper_board_list`, `keeper_board_search`,
  `keeper_board_post_get`, `keeper_board_post`, `keeper_board_comment`,
  `keeper_board_vote`, `keeper_tasks_list`, `keeper_tasks_audit`,
  `keeper_task_claim`, `keeper_task_create`, `keeper_task_done`,
  `keeper_broadcast`
- connected surfaces: `keeper_surface_read`, `keeper_surface_post`,
  `keeper_person_note_set`
- memory/library: `keeper_memory_search`, `keeper_memory_write`,
  `keeper_library_search`, `keeper_library_read`
- goals/plans/runs: `masc_goal_list`, `masc_goal_upsert`,
  `masc_goal_transition`, `masc_plan_get`,
  `masc_plan_update`, `masc_run_list`, `masc_note_add`, `masc_deliver`
- scheduled automation: `masc_schedule_create`, `masc_schedule_list`,
  `masc_schedule_get`, `masc_schedule_cancel`, `masc_schedule_approve`,
  `masc_schedule_reject`
- keeper management/messaging: `masc_keeper_list`, `masc_keeper_status`,
  `masc_keeper_msg`, `masc_keeper_msg_result`, `masc_keeper_msg_queue`,
  `masc_keeper_msg_cancel`
- operator/maintenance keeper controls: broader descriptors such as
  `masc_keeper_compact`, `masc_keeper_clear`, `masc_keeper_sandbox_start`,
  `masc_keeper_sandbox_stop`, `masc_keeper_reset`,
  `masc_keeper_adversarial_review`, `masc_keeper_down`, and `masc_keeper_up`
  may exist in code, but normal keeper prompts must not assume them unless
  those exact names are visible; each concrete external effect is then
  evaluated independently by the Gate
- advisory deliberation and media: `masc_fusion`, `masc_fusion_status`,
  `analyze_image`

Voice schemas are part of the same flat Keeper catalog.

Excluded from keeper exposure:
- inline MCP-runtime tools such as `masc_start`, `masc_bind`, `masc_unbind`,
  `masc_messages`, `masc_listen`, and `masc_agents`
- other tools that depend on MCP runtime-only context rather than keeper context

## Usage Timing

| Need | Use | Avoid |
|------|-----|-------|
| Identity, sandbox, context, or active schema uncertainty | `keeper_context_status`, `keeper_tools_list`, `keeper_tool_search` | Guessing hidden tools or reconstructing paths from memory |
| Durable workspace discussion, findings, votes, or shared decisions | board tools | Connected-surface replies for long-lived workspace state |
| Current dashboard/Discord/Slack/connector lane context or reply | `keeper_surface_read`, `keeper_surface_post`, `keeper_person_note_set` | Treating surfaces as repo files, board posts, or connector-wide registries |
| Backlog ownership and completion | `keeper_tasks_list`, `keeper_task_claim`, `keeper_task_done`, `keeper_task_create` | Claiming work just to show activity when the right outcome is no-op/blocker reporting |
| Past decisions or shared references | memory and library tools | Writing scratch notes to durable memory |
| Workspace planning, goal lifecycle, run logs, notes, deliverables | `masc_goal_*`, `masc_plan_*`, `masc_run_*`, `masc_note_add`, `masc_deliver` | Mutating goals/plans for ordinary status narration |
| Durable future automation | `masc_schedule_*` | Assuming side-effecting schedules run without human approval |
| Targeted async help from another keeper | `masc_keeper_list`, `masc_keeper_status`, `masc_keeper_msg`, result/queue/cancel tools | Broadcasting a private question, or messaging an unknown keeper without status/list evidence |
| High-impact ambiguous decision needing independent perspectives | `masc_fusion` with self-contained context | Replacing cheap code inspection, exact status evidence, or blocker reporting |
| Stored image artifact analysis | `analyze_image` | Treating visible chat attachments as hidden sandbox files |

## Continuity Positioning

Keeper continuity is a bounded advanced capability, not a general memory promise.

If productized, the continuity promise is:

- `masc_keeper_msg` can continue a same-trace conversation when checkpoint restore is healthy
- `masc_keeper_status` and `masc_keeper_list(detailed=true)` expose enough continuity state to diagnose restore and handoff behavior
- validation should rely on OAS checkpoint truth plus live runtime evidence

The product should not promise:

- long-term or general conversational memory
- cross-generation recall
- assistant reply recall outside the active checkpoint window
- memory bank resurrection as part of keeper continuity

Primary continuity fields:

- `trace_id`
- `generation`
- `trace_history_count`
- OAS checkpoint inventory (`checkpoint_found`, `message_count`, `generation`)
- runtime-manifest checkpoint load/save events
- terminal turn receipts

Assistant prose is not a continuity field. See
`docs/KEEPER-STATE-OWNERSHIP.md` for the normative ownership contract.

## Triage System

Triage evaluates 9 trigger types on each heartbeat:
DirectMention, NewUnclaimedTask, FailedTask, AgentJoinedOrLeft, GoalDeadline,
BoardActivity, IdleTimeout, MetricsAnomaly, StrategicReview.

## Keeper Workflows

| Workflow | Primary tools |
|----------|---------------|
| 의견 내기 / 토론 참여 | `keeper_board_post`, `keeper_board_comment` |
| 최신 정보 / 외부 자료 확인 | `WebSearch { "query": "...", "includeContent": true }` for current results plus keeper-readable `content_text` and raw `page_content`; `WebFetch { "url": "..." }` for one selected URL when deeper reading or a citation is needed. See `config/prompts/keeper.unified.system.md` for exact input/output shape. |
| 찬성 / 반대 신호 | `keeper_board_vote` |
| 커넥터/현재 대화 lane 확인 및 답장 | `keeper_surface_read`, `keeper_surface_post`, `keeper_person_note_set` |
| 외부 효과 승인/판단 | exact Always Allow, configured LLM Auto Judge, or nonblocking HITL Gate |
| 목표 / 계획 lifecycle | `masc_goal_list`, `masc_goal_upsert`, `masc_goal_transition` |
| 계획/런/산출물 기록 | `masc_plan_get`, `masc_plan_init`, `masc_plan_update`, `masc_plan_set_task`, `masc_plan_get_task`, `masc_plan_clear_task`, `masc_run_init`, `masc_run_list`, `masc_run_get`, `masc_run_plan`, `masc_note_add`, `masc_deliver` |
| 예약 자동화 | `masc_schedule_create`, `masc_schedule_list`, `masc_schedule_get`, `masc_schedule_cancel`, `masc_schedule_approve`, `masc_schedule_reject` |
| 다른 keeper 상태/메시지 | `masc_keeper_list`, `masc_keeper_status`, `masc_keeper_msg`, `masc_keeper_msg_result`, `masc_keeper_msg_queue`, `masc_keeper_msg_cancel` |
| 패널 심의 / 비동기 판단 보강 | `masc_fusion`, `masc_fusion_status` |
| 저장 이미지 artifact 분석 | `analyze_image` |
| 코드 작성 / 수정 | `Read` / `Grep` -> `Edit` / `Write`, then `Execute` with typed `git` argv |
| 테스트 실행 | `Execute` with typed argv from the worktree `cwd` |

The goal lifecycle surface is descriptor/registry-driven. Social and messaging
keepers should keep board/task workspace
collaboration without assuming goal mutation execution surface unless the exact
goal tools are visible.

## Research Profile Additions

Research-profile keepers use the active web, board, task, code, and goal
surfaces.

## Execution Boundary

External effects use one non-hierarchical Gate: exact Always Allow, configured
LLM Auto Judge, or nonblocking HITL. A pending decision does not block the
Keeper lane. Objective typed-input, path-jail, and sandbox-confinement
invariants remain at their owning execution boundaries. Cost, token, and turn
data are observations rather than stop/pause authorization classes.

Source: `lib/keeper/keeper_gate.ml`, `lib/tool_shard.ml`,
`lib/keeper/keeper_tool_descriptor.ml`, `lib/keeper/keeper_tool_policy.ml`,
`lib/keeper/keeper_tool_dispatch_runtime.ml`,
`lib/tool_surface/tool_shard_types_schemas_search_files.ml`
