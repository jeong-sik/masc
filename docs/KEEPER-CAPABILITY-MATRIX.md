---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/
  - lib/tool_dispatch.ml
---

# Keeper Capability Matrix

Keepers do not receive the full public MCP surface.
They get keeper-native tools plus `masc_*` tools that are executable without
MCP runtime/session context. This matrix names internal handler IDs for
implementation/audit purposes; model-facing prompts and recovery hints must use
the exact active schema names, such as the public `Bash` alias when it is
listed.
Triage and trigger detection run on each heartbeat using the proactive idle/cooldown settings.
The `masc_autoresearch_*` MCP/keeper tool family is retired; dashboard lab
routes may still expose historical loop artifacts, but keepers must not receive
autoresearch as a callable shard.

## Tool Shards

| Shard | Tools | Count | Removable |
|-------|-------|-------|-----------|
| **base** | `keeper_stay_silent`, `keeper_time_now`, `keeper_context_status`, `keeper_memory_search`, `keeper_tools_list` | 5 | No |
| **board** | `keeper_board_{get,post,list,comment,vote,stats,search}` | 7 | Yes |
| **filesystem** | `keeper_fs_{read,edit}` | 2 | Yes |
| **shell** | `keeper_shell` | 1 | Yes |
| **library** | `keeper_library_{search,read}` | 2 | Yes |
| **taskboard** | `keeper_tasks_{list,audit}`, `keeper_task_{force_release,force_done,claim,done,submit_for_verification,create}`, `keeper_broadcast` | 9 | Yes |
| **voice** | `keeper_voice_{speak,listen,agent,sessions,session_start,session_end}` | 6 | Yes |
| **coding** | `keeper_bash`, `keeper_preflight_check`, `keeper_pr_{list,status,create,review_read,review_comment,review_reply}`, `masc_{worktree_create,worktree_list,code_search,code_symbols,code_read}` | 13 | Yes |

Notes:
- The `voice` shard still exists, but it is no longer part of the default keeper surface. The historical weather shard is retired from `Tool_shard`.
- The historical `autoresearch` shard and `masc_autoresearch_*` tool family are retired from `Tool_shard` and keeper model-tool exposure.
- The old governance petition/case tools were retired from the callable tool surface. Governance-style participation now uses board discussion/vote paths plus dashboard governance/audit read models.
- Write-capable tools such as `keeper_fs_edit` and code mutation tools are present in the keeper surface; preset/policy and eval gates decide whether a keeper may execute the mutation.
- `keeper_shell` is structured-only (`pwd`, `ls`, `cat`, `rg`, `find`, `head`, `tail`, `wc`, `tree`, `git_status`, `git_log`, `git_diff`, `git_worktree`, `git_clone`, `gh`). Typed command execution is model-facing as `Bash` when that alias is listed, backed internally by `keeper_bash`.
- Code mutation uses `masc_code_{write,edit,delete,shell,git}` in addition to the `coding` shard above.

## Tool Surface

All keepers receive: base + board + fs + shell + library + taskboard + coding shards.
Voice tools are added when `policy_voice_enabled = true`.
`write_done = true` returns empty tool list (session terminated).

Excluded from keeper exposure:
- inline MCP-runtime tools such as `masc_start`, `masc_join`, `masc_leave`,
  `masc_broadcast`, `masc_messages`, `masc_listen`, and `masc_who`
- other tools that depend on MCP runtime-only context rather than keeper context

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
- `continuity_summary` (optional before the first continuity snapshot exists)

Supporting diagnostic field:

- `last_continuity_update_ts` (detailed status tie-breaker)

`continuity_summary` is the latest continuity snapshot text. It may be empty or `null` before the first continuity snapshot exists. During validation, a harness-validated continuity update should correlate with a non-empty latest snapshot in detailed keeper status.

## Triage System

Triage evaluates 9 trigger types on each heartbeat:
DirectMention, NewUnclaimedTask, FailedTask, AgentJoinedOrLeft, GoalDeadline,
BoardActivity, IdleTimeout, MetricsAnomaly, StrategicReview.

## Keeper Workflows

| Workflow | Primary tools |
|----------|---------------|
| 의견 내기 / 토론 참여 | `keeper_board_post`, `keeper_board_comment` |
| 최신 정보 / 외부 자료 확인 | `masc_web_search` (also exposed to model clients as `WebSearch`) |
| 찬성 / 반대 신호 | `keeper_board_vote` |
| 거버넌스 의견 제출 | retired as keeper tools; use board discussion/vote paths and governance dashboard read models |
| 목표 / 계획 lifecycle | `masc_goal_list`, `masc_goal_upsert`, `masc_goal_transition`, `masc_goal_verify`, `masc_coordination_fsm_snapshot` |
| 코드 작성 / 수정 | `masc_worktree_create` -> `masc_code_write` / `masc_code_edit` / `masc_code_git` |
| 테스트 실행 | `masc_code_shell` (worktree `cwd` required) |
| GitHub PR / 이슈 작업 | `keeper_preflight_check`, `keeper_pr_list`, `keeper_pr_status`, `keeper_pr_create` (draft-only). Structured `gh` routing is an internal/fallback path when repo context is bound, not prompt guidance unless that exact tool is listed |

The goal lifecycle surface is configured as the `masc.goal` policy group and is
routed to `dispatch`, `coding`, `research`, and `delivery` presets. Social and
messaging keepers keep board/task coordination without goal mutation access.

## Research Profile Additions

Research-profile keepers use the active web, board, task, code, and goal
surfaces. They do not receive `masc_autoresearch_*`; allowlists and preset
selection must not resurrect retired autoresearch tools.

## Safety Gates (applied to all keepers)

| Gate | Description | Config |
|------|-------------|--------|
| Cost budget | Per-session limit | `max_cost_usd` (default: $0.50) |
| Turn limit | Max tool calls per turn | `max_tool_calls_per_turn` (default: 10) |
| Entropy | Consecutive same-tool detection | `entropy_threshold` (default: 3) |
| Destructive | Pattern-match on bash/edit commands | 19 patterns, substring match |
| Allowlist/Denylist | Explicit tool filtering | `allowed_tools`, `denied_tools` |

Source: `lib/eval_gate.ml`, `lib/keeper/keeper_exec_tools.ml`, `lib/tool_shard.ml`
