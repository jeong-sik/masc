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

- `tasks`·`claimed`·`board` 는 descriptor 가 `Concurrent` 라 같은 batch 에서 함께 돈다.
  나머지는 `Serial` 이라 그 뒤에 하나씩 돈다. 서로의 출력을 쓰지 않으므로 `after` 는 없다.
- 두 목록 도구의 `status` 는 값 하나와 정확히 같은 행만 고른다. 담당자로 좁히는 인자도 없다.
  그래서 상태마다 노드를 하나씩 둔다.
  - task: claim 은 보통 곧바로 `in_progress` 로 넘어가지만, 시작에 실패하면 `claimed` 에
    남는다(`keeper_tool_task_runtime.ml` auto-start). 둘 다 봐야 "누가 잡고 있나"가 된다.
  - 예약: 아직 끝나지 않은 상태는 `scheduled`·`due`·`running` 셋이다. 다시 시도하거나
    재기동 뒤 되살린 실행은 `running` 에서 `due` 로 돌아온다(`schedule_store.ml`
    `retry_running`, `recover_running_on_startup`).
- `status` 없이 `owner = "self"` 만 주면 `schedule_id` 순서로 잘려서 첫 페이지가 이미 끝난
  예약으로 찬다. 2026-09-15 저장소에서 `code-reviewer` 는 자기 행 256건 중 `due` 가 1건이었다.
- claim 할 수 있는 todo 는 턴 프레임이 "next to claim / Newly added" 로 이미 보여 준다.
- `masc_ask_status` 는 `include_resolved = true` 면 답이 끝난 질문 기록 전체를 돌려주고,
  개수를 줄이는 인자가 없다. 이 조합은 열린 질문만 읽는다. 목록에서 사라진 질문은
  답변과 철회를 구분할 수 없으므로, 확인이 필요하면 해당 ID로 `include_resolved = true`를 쓴다.
- 샌드박스·체크아웃 상태(`keeper_context_status`)는 넣지 않는다. 크기를 줄이는 입력이 없고
  체크아웃 수에 따라 결과가 달라진다.
- 브로드캐스트는 이 호출이 읽지 않는다.

## 크기

도구 결과가 16,384 byte(`Common.max_tool_result_wire_bytes`)를 넘으면 봉인된 blob 으로
바뀌어 Keeper 가 다시 읽어야 한다. 합성 결과는 노드 결과를 모두 담으므로 합이 이 안에
들어가게 개수를 골랐다. 근거는 `<base-path>/.masc/tool_calls/2026-09/*.jsonl` 과
2026-09-15 의 backlog·schedule 저장소다.

| 노드 | 크기 |
|---|---|
| `tasks` | 같은 입력의 09-14 기록 두 번: 5,552 byte(진행 중 14건), 5,497 byte(13건). 페이지 10행 + `new_tasks` 10행이라 20행을 넘지 않는다 |
| `claimed` | 09-14 이후 `claimed` 를 읽은 기록 278 byte(0건) |
| `board` | `limit = 10`·compact 호출 786회: 중앙값 2,090 byte, 90% 2,254 byte, 최대 2,532 byte |
| `answers` | 열린 질문만 읽은 호출 1,032회: 중앙값 69 byte, 90% 1,379 byte, 최대 7,677 byte |
| `scheduled` | Keeper 별 0~4건, 한 페이지 최대 1,238 byte. 행 하나는 최대 478 byte |
| `due` · `running` | Keeper 별 0~1건, 최대 369 byte · 0건 74 byte |

노드마다 `node_id`·`schedule`·`tool_use_id` 같은 틀이 545~588 byte 붙어서 일곱 노드면
약 4,000 byte 다. 노드별 90%(표에 90% 가 없으면 최대) 값을 더하면 약 15,200 byte 로 한도
아래다. 중앙값으로는 약 12,600 byte 다.

봉인되는 경우:
- `masc_ask_status` 에는 개수 인자가 없다. 관측 최대 7,677 byte 가 나오면 다른 노드가 90%
  값이어도 약 21,500 byte 가 된다.
- 대기 예약이 10건 가까이 쌓이면 `scheduled` 가 약 4,800 byte 까지 커진다.

잘리는 경우: 진행 중 task 가 10건을 넘으면 `tasks` 페이지는 잘리고 `truncated = true`,
`next_cursor`, 전체 건수 `matching_count` 가 실린다. 가장 최근 10건은 `new_tasks` 에 따로
실린다. 예약 목록도 더 있으면 `next_cursor` 를 싣는다. 보드 목록에는 잘렸다는 표시가 없다.

```toml composition
[[compositions]]
name = "work-intake"
description = "Reads task ownership, recent Board activity, open questions and your unfinished schedules when choosing new work or checking a changed dependency. If the current Task and next step are already known, continue them directly; this is not a prerequisite on every wake. For missing scope or acceptance criteria, use keeper_tasks_list with task_ids and projection=full. An open question blocks only the work depending on its answer; check an answered or withdrawn question by its exact ID with include_resolved=true. Respect existing owners and avoid duplicating scheduled work. A failed node is named in the result; use its settled results before repeating reads. Task pages with truncated=true continue with next_cursor."
execution = "inline"

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
