---
status: reference
---

# Keeper Capability Matrix

Keeper가 실제로 호출할 수 있는 이름과 인자는 매 turn에 제공되는 typed schema가
권위다. 이 문서는 현재 주요 capability family와 source SSOT를 찾기 위한 색인이다.

| 목적 | 현재 capability | Source SSOT |
|---|---|---|
| 현재 identity, Task, sandbox, repository checkout 확인 | `keeper_context_status` | `lib/tool_surface/tool_shard_types_schemas_base.ml` |
| 실행 레인의 상태(probe 응답, 마지막 실행 결과, 운영자 조치) 확인 | `keeper_lane_status` | `lib/keeper/keeper_tool_lane_status.ml` (RFC-0427 D-1) |
| Board 읽기/쓰기 | `masc_board_list`, `masc_board_post_get`, `masc_board_search`, `masc_board_post`, `masc_board_comment`, `masc_board_vote`, `masc_board_stats`, `masc_board_curation_read`, `masc_board_curation_submit` | `lib/board_tool_adapter/board_tool_registry.ml` + Keeper projection `lib/tool_surface/tool_shard_types_board_keeper_projection.ml` |
| Task 조회/소유/완료/생성 | `keeper_tasks_list`, `keeper_tasks_audit`, `keeper_task_claim`, `keeper_task_done`, `keeper_task_create` | `lib/tool_surface/tool_shard_types_schemas_taskboard.ml` |
| Goal 조회/변경 | `masc_goal_list`, `masc_goal_upsert`, `masc_goal_transition` | `lib/tool_schemas/tool_schemas_workspace_extra.ml` |
| Schedule 생성/수정/조회/취소 | `masc_schedule_create`, `masc_schedule_update`, `masc_schedule_list`, `masc_schedule_get`, `masc_schedule_cancel` | `lib/tool_schemas/tool_schemas_schedule.ml` |
| Conversation 읽기/게시 | `keeper_surface_read`, `keeper_surface_post` | `lib/keeper/keeper_tool_descriptor.ml` |
| Repository/file 탐색 및 실행 | 현재 schema가 제공하는 search, read, write, edit, execute capability | `lib/keeper/keeper_tool_descriptor.ml`, `lib/tool_surface/` |
| Memory | `keeper_memory_search`, `keeper_memory_write` | `lib/tool_surface/tool_shard_types_schemas_base.ml` |
| Shared references | `keeper_library_search`, `keeper_library_read` | `lib/tool_surface/tool_shard_types_schemas_library.ml` |
| 다중 판단 합성 | `masc_fusion`, `masc_fusion_status` | `lib/keeper/keeper_tool_descriptor.ml` |
| 사용 가능한 capability 검색 | `keeper_tools_list`, `keeper_tool_search` | `lib/tool_surface/tool_shard_types_schemas_base.ml`, `lib/keeper/keeper_tool_descriptor.ml` |

## Autonomous action contract

- Goal, Task, Board, Schedule, conversation, repository checkout의 현재 상태를
  먼저 읽고, 근거가 있는 가장 작은 행동을 실행한다.
- Catalog 등록은 checkout 존재 증거가 아니다. `repository_checkouts`에서
  checkout, catalog identity, dirty state, local tracking ref 기준 freshness를
  함께 확인한다.
- Task claim은 소유권 조율이며 capability 권한을 추가하지 않는다.
- Schedule은 미래 wake를 만들 뿐 외부 효과를 승인하지 않는다.
- Gate가 pending이면 operation 또는 approval ID를 보존하고 다른 일을 계속한다.
- 실패는 typed error로 남기고 정확한 요청을 고치거나 blocker로 보고한다.

## Schema synchronization

- Schedule name list SSOT: `Tool_schemas_schedule.definitions`
- Goal schemas SSOT: `Tool_schemas_workspace_extra.schemas`
- Keeper descriptor assembly: `Keeper_tool_descriptor`
- Surface membership SSOT: `Tool_catalog_surfaces`

문서와 schema가 다르면 schema가 현재 실행 계약이며, 문서를 즉시 수정한다.
