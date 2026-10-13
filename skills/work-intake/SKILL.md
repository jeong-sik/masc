---
name: work-intake
description: "Reads task ownership, recent Board activity, open questions and your unfinished schedules when choosing new work or checking a changed dependency. If the current Task and next step are already known, continue them directly; this is not a prerequisite on every wake. For missing scope or acceptance criteria, use keeper_tasks_list with task_ids and projection=full. An open question blocks only the work depending on its answer; check an answered or withdrawn question by its exact ID with include_resolved=true. Respect existing owners and avoid duplicating scheduled work. A failed node is named in the result; use its settled results before repeating reads. Task pages with truncated=true continue with next_cursor."
---

# work-intake

`keeper_compose_work-intake` 는 새 일을 고르거나 바뀐 의존성을 확인할 때 일곱 노드로 현황을 읽는다.
진행할 Task와 다음 단계가 이미 있으면 이 호출 없이 그 단계부터 이어간다.

Keeper 에게 보이는 설명은 아래 fence 의 `description` 뿐이다. 이 본문은 사람이 읽는다.
읽는 법(답이 왔나, 예약이 겹치나, 남이 잡았나, 보드가 움직였나)은 그 `description` 에 있다.

## 노드

| id | 도구 | 입력 | 보는 것 |
|---|---|---|---|
| `tasks` | `keeper_tasks_list` | `status = "in_progress"`, `projection = "compact"`, `limit = 10` | 누가 무엇을 하고 있나 |
| `claimed` | `keeper_tasks_list` | `status = "claimed"`, `projection = "compact"`, `limit = 10` | 잡았지만 아직 시작하지 않은 task |
| `board` | `masc_board_list` | `sort_by = "updated"`, `limit = 10`, `compact = true`, `exclude_automation = true` | 댓글·투표까지 포함해 최근에 움직인 글 |
| `answers` | `masc_ask_status` | `include_resolved = false` | 아직 답이 안 온 내 질문 |
| `scheduled` · `due` · `running` | `masc_schedule_list` | `owner = "self"`, 각자 `status`, `limit = 10` | 아직 끝나지 않은 예약 |

- 일곱 노드는 모두 `Concurrent` 이고 서로의 출력을 쓰지 않으므로 `after` 가 없다.
  executor가 독립된 read-only 노드를 함께 실행한다. `continue_independent`로 한 조회가
  실패해도 다른 조회를 마친다. 전체 결과에는 실패 원인과 이미 끝난 노드 결과가 함께 남는다.
- `keeper_tasks_list`의 `status`는 정확한 상태 하나를 고른다. `assignee`·`task_ids`·`goal_id`·
  `query`로도 좁힐 수 있고, 주어진 필터는 페이지를 나누기 전에 모두 함께 적용한다.
  이 조합은 다른 담당자의 작업도 보려고 `assignee`를 지정하지 않는다. claim은 보통 곧바로
  `in_progress`로 넘어가지만 시작에 실패하면 `claimed`에 남으므로 둘 다 읽는다
  (`keeper_tool_task_runtime.ml` auto-start).
- `masc_schedule_list`의 `owner = "self"`는 내가 만든 예약 또는 나를 깨우는 예약이다.
  특정 생성자나 대상 Keeper는 `owner = "scheduled_by"` 또는 `"wake_target"`와
  `owner_name`으로 고른다(`self`·`all`에는 `owner_name`을 받지 않는다).
  `status = "active"`는 모든 비종료 상태이며 현재 `scheduled`·`due`·`running`을 포함한다.
  이 조합은 셋의 첫 페이지를 각각 읽도록 정확한 상태를 명시했다. 재시도와 재기동 복구는
  `running`을 `due`로 돌린다(`schedule_store.ml` `retry_running`, `recover_running_on_startup`).
- `status` 없이 `owner = "self"`만 주면 종료된 예약도 `schedule_id` 순서의 첫 페이지에
  포함될 수 있다. 2026-09-15 저장소에서 `code-reviewer`는 자기 행 256건 중 `due`가 1건이었다.
- claim 할 수 있는 todo 는 턴 프레임이 "next to claim / Newly added" 로 이미 보여 준다.
- `masc_ask_status` 는 `include_resolved = true` 면 답이 끝난 질문 기록 전체를 돌려주고,
  개수를 줄이는 인자가 없다. 이 조합은 열린 질문만 읽는다. 목록에서 사라진 질문은
  답변과 철회를 구분할 수 없으므로, 확인이 필요하면 해당 ID로 `include_resolved = true`를 쓴다.
- 샌드박스·체크아웃 상태(`keeper_context_status`)는 넣지 않는다. 크기를 줄이는 입력이 없고
  체크아웃 수에 따라 결과가 달라진다.
- 브로드캐스트는 이 호출이 읽지 않는다.

## 결과 범위

`limit`·`compact`·`projection`은 현재 작업을 고르는 데 필요한 첫 페이지를 읽도록 명시했다.
결과 크기는 실제 backlog·예약·열린 질문 수에 따라 달라진다. 원본 로그의 `result_bytes`를
Keeper가 받은 wire bytes나 토큰 수로 계산하지 않는다. CLI의 결과 경계와 Agent Core의
inline 결과 경계는 별도 계약이며, 한쪽 값을 다른 레인의 기준으로 쓰지 않는다.
결과가 artifact reference로 오면 필요한 원본만 그 reference로 읽는다.

`tasks`·`claimed`는 각각 priority·created_at·id 순서로 첫 10건을 읽는다. 더 있으면
`truncated = true`, `next_cursor`, 전체 건수 `matching_count`가 실린다. `new_tasks`는
첫 페이지 밖의 최근 행을 최대 10건 보여 주고 다음 페이지에서는 반복하지 않는다.
예약은 각 상태별로 `schedule_id` 순서로 읽으며 더 있으면 `next_cursor`를 싣는다.
두 도구 모두 다음 조회의 `cursor`에 `next_cursor`를 넣고 기존 필터를 유지한다.
보드 목록에는 잘렸다는 표시가 없다.

```toml composition
[[compositions]]
name = "work-intake"
description = "Reads task ownership, recent Board activity, open questions and your unfinished schedules when choosing new work or checking a changed dependency. If the current Task and next step are already known, continue them directly; this is not a prerequisite on every wake. For missing scope or acceptance criteria, use keeper_tasks_list with task_ids and projection=full. An open question blocks only the work depending on its answer; check an answered or withdrawn question by its exact ID with include_resolved=true. Respect existing owners and avoid duplicating scheduled work. A failed node is named in the result; use its settled results before repeating reads. Task pages with truncated=true continue with next_cursor."
execution = "inline"
branch_failure_policy = "continue_independent"

[[compositions.nodes]]
id = "tasks"
tool = "keeper_tasks_list"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "status"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "in_progress"
[[compositions.nodes.input.fields]]
name = "projection"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "compact"
[[compositions.nodes.input.fields]]
name = "limit"
[compositions.nodes.input.fields.value]
kind = "literal"
value = 10

[[compositions.nodes]]
id = "claimed"
tool = "keeper_tasks_list"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "status"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "claimed"
[[compositions.nodes.input.fields]]
name = "projection"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "compact"
[[compositions.nodes.input.fields]]
name = "limit"
[compositions.nodes.input.fields.value]
kind = "literal"
value = 10

[[compositions.nodes]]
id = "board"
tool = "masc_board_list"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "sort_by"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "updated"
[[compositions.nodes.input.fields]]
name = "limit"
[compositions.nodes.input.fields.value]
kind = "literal"
value = 10
[[compositions.nodes.input.fields]]
name = "compact"
[compositions.nodes.input.fields.value]
kind = "literal"
value = true
[[compositions.nodes.input.fields]]
name = "exclude_automation"
[compositions.nodes.input.fields.value]
kind = "literal"
value = true

[[compositions.nodes]]
id = "answers"
tool = "masc_ask_status"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "include_resolved"
[compositions.nodes.input.fields.value]
kind = "literal"
value = false

[[compositions.nodes]]
id = "scheduled"
tool = "masc_schedule_list"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "owner"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "self"
[[compositions.nodes.input.fields]]
name = "status"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "scheduled"
[[compositions.nodes.input.fields]]
name = "limit"
[compositions.nodes.input.fields.value]
kind = "literal"
value = 10

[[compositions.nodes]]
id = "due"
tool = "masc_schedule_list"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "owner"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "self"
[[compositions.nodes.input.fields]]
name = "status"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "due"
[[compositions.nodes.input.fields]]
name = "limit"
[compositions.nodes.input.fields.value]
kind = "literal"
value = 10

[[compositions.nodes]]
id = "running"
tool = "masc_schedule_list"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "owner"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "self"
[[compositions.nodes.input.fields]]
name = "status"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "running"
[[compositions.nodes.input.fields]]
name = "limit"
[compositions.nodes.input.fields.value]
kind = "literal"
value = 10
```
