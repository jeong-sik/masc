---
rfc: "0466"
title: "Librarian 은 그 턴이 하던 Task 의 Goal 을 본다"
status: Draft
created: 2026-09-23
updated: 2026-09-23
author: vincent + claude
supersedes: []
superseded_by: null
related: ["librarian-lifecycle", "0463-librarian-absorb-rewrite-round"]
implementation_prs: []
---

# RFC-0466 — Librarian 은 그 턴이 하던 Task 의 Goal 을 본다

## 1. 문제

Librarian 프롬프트에는 "현재 Task 에 연결된 Goal 기준" 자리가 있다
(`config/prompts/librarian.md`, `{{goal_context}}`). #34919 가 이 자리를 채웠다.
턴이 끝날 때 도는 closure 가 그 턴의 meta 에서 `current_task_id` 를 읽어
`goal_context_for_task` 를 불렀다.

#37527 이 그 closure 를 지우고 durable 회차로 옮겼다. 지금 세 회차가 싣는 값은
이렇다.

| 회차 | 무엇을 읽나 | `goal_context` |
|---|---|---|
| durable | 지나간 턴 범위 | `No_task` 고정 (`keeper_librarian_durable_consumer.ml`) |
| continuity | 지나간 턴 범위 | `No_task` 고정 (`keeper_librarian_queue_refresh.ml`) |
| queue | 밀린 입력 | 회차가 도는 순간의 task (#38114) |

durable·continuity 의 `No_task` 는 실수가 아니다. #37208 이 일부러 두었고
`test_historical_range_does_not_borrow_the_current_task` 가 고정한다. 지나간 턴의
Task 를 지금 meta 에서 읽으면, 옛 턴이 나중에 맡은 Task 의 Goal 에 묶인다.
턴 끝 기록(`Keeper_turn_boundaries.Turn_ended`)에는 `turn_ref`,
`history_at_start`, `position` 만 있고, 그 턴의 Task 가 없다.

그래서 기억 대부분을 만드는 두 회차가 Goal 기준을 한 번도 보지 못한다.

## 2. 결정

### 2.1 턴이 다룬 Task 를 모두 적는다

턴이 끝날 때의 `current_task_id` 하나로는 모자란다. 턴 안에서 Task 가 바뀐다.

- claim 이 `current_task_id` 를 세운다(`tool_task_handlers.ml`, `keeper_tool_task_runtime.ml`).
- `masc_transition` 이 성공하면(done 포함) `sync_owner_current_task_binding` 이 값을
  비우거나 다른 Task 로 바꾼다(`lib/task/tool_task.ml`).
- 그래서 Task A 를 끝낸 턴은 끝 시점 값으로 보면 `no_task` 나 다음 Task B 다. Goal
  기준이 가장 필요한 턴이 가장 틀리게 적힌다.

finalize 는 이미 필요한 값을 들고 있다.

- 턴이 시작될 때(admission)의 `meta.current_task_id`
- `acc.tool_calls[].task_id`: task 도구 호출의 명시적 `task_id`, 또는 그 호출 때의 현재
  Task(`keeper_run_tools_task_scope.ml`)
- 턴이 끝날 때의 `acc.meta.current_task_id`

이 셋의 합집합을 처음 나온 순서대로, 중복 없이 적는다.

### 2.2 턴 끝 파일에 새 종류의 줄로 적는다

`turn-boundaries.jsonl` 은 줄 종류(`kind`)를 생성자로 구분한다
(`keeper_turn_boundaries.mli`, "a kind of line is a constructor rather than a
field"). 새 생성자를 더해도 옛 줄은 그대로 읽힌다. 호환 reader 가 생기지 않는다.

```
{ "kind": "turn_tasks", "turn_ref": "...", "tasks": [] }
{ "kind": "turn_tasks", "turn_ref": "...", "tasks": ["task-a", "task-b"] }
```

- `Turn_tasks { turn_ref; tasks : Task_id.t list }`. 빈 목록은 "이 턴은 Task 가 없었다"
  는 사실이다.
- finalize 가 `Turn_ended` 줄을 쓰기 **바로 전에** 따로 한 번 append 한다. 지금
  `Keeper_turn_boundaries.append` 는 레코드 하나를 한 번에 쓰는 API 다
  (`keeper_turn_boundaries.mli`, "One record in one durable append"). 두 줄을 한 번에
  쓰는 API 는 만들지 않는다. 만들어도 쓰던 중 죽으면 마지막 온전한 줄까지 잘라
  남기므로(같은 mli), Task 줄만 남는 경우가 어차피 생긴다.
- 쓰는 자리는 `keeper_agent_run_finalize_response.ml` 의 `Ok position` 갈래 안, 재시작 줄
  (`History_restarted`) 뒤, `Turn_ended` append 앞이다. 위치를 못 만들어 경계 줄을 쓰지
  않는 턴(`site:"position"`)은 Task 줄도 쓰지 않는다. #37527 의 fragment 줄이 경계 줄보다
  먼저 쓰이는 것과 같은 방향이다. 경계 줄을 읽은 reader 는 그 앞의 Task 줄도 이미 볼 수
  있다.
- 짝은 줄 순서로 맞춘다. `Turn_ended` 의 **바로 앞 줄**이 `Turn_tasks` 이고 두 줄의
  `turn_ref` 가 같으면 그 턴의 것이다. 그 밖이면 그 턴은 기록 없음이다. `turn_ref` 는
  파일 전체의 키가 아니다(같은 mli). 번호가 다시 쓰여도 붙어 있는 두 줄의 짝은 흔들리지
  않는다. `turn_ref` 비교는 붙어 있는 두 줄이 같은 finalize 에서 나왔는지만 본다.
- 두 번 append 하므로 "Task 줄은 썼는데 경계 줄은 실패" 가 생긴다. 이 짝 없는
  `Turn_tasks` 는 어느 턴의 것도 아니다. 다음 턴이 두 줄을 다 쓰면 그 턴의 Task 줄이
  바로 앞 줄이라 짝이 맞는다. 다음 턴의 Task 줄마저 실패하면 그 턴의 경계 줄 바로 앞이
  앞 턴의 짝 없는 줄이 된다. 두 줄의 `turn_ref` 가 달라서 그 턴은 기록 없음이 된다. 앞 턴의
  Task 를 빌려 오지 않는다.
- 경계 줄을 읽는 reader 는 `Keeper_turn_boundaries.read` 호출자 9곳이다
  (`keeper_carried_front.ml`, `keeper_librarian_durable_consumer.ml`,
  `keeper_turn_driver_try_provider.ml` 2곳, `server_dashboard_http_keeper_api_checkpoints.ml`,
  `bin/` 의 `deployment_preflight_helper.ml`·`masc_librarian_replay.ml`·
  `masc_librarian_continuity.ml`·`masc_checkpoint_purge.ml`). 새 생성자를 더해도 컴파일러가
  잡지 못하는 와일드카드 match 가 main 에 있다.
  - `keeper_carried_front.ml` 의 `| (_, Ok _) :: rest -> loop latest_turn floor rest`
  - `librarian_continuity_snapshot.ml` 의 세 fold 끝 `| _ -> None` / `| _ -> false`
  - `keeper_librarian_durable_consumer.ml` 의 `| Ok _ | Error _ -> false`, `| Ok _ | Error _ -> None`

  이 자리들은 `Turn_tasks` 를 조용히 건너뛴다. 대부분은 맞는 동작이지만, 구현 PR 에서
  reader 하나씩 판정하고 와일드카드를 생성자를 적은 갈래로 바꾼다. 그래야 다음 생성자부터
  컴파일러가 실제로 강제한다. 줄 번호는 위치일 뿐이라 `boundary_lines_seen` 같은 위치
  값은 바뀌지 않는다. 줄 수로 턴을 세는 reader 가 있는지도 같은 판정에서 본다.

### 2.3 모르는 턴은 모른다고 싣는다

배포 전의 턴, Task 줄을 쓰지 못한 턴에는 `Turn_tasks` 가 없다. 이것을 `No_task` 로
접으면 "Task 가 없었다" 는 거짓이 된다(`docs/constitution.xml` `strict_parse_no_default`).

```ocaml
type task_goals =
  { task_id : string
  ; criteria : ((string * Goal_phase.t * Goal_store.criterion) list, string) result
  }

type goal_context =
  | No_task
  | Task_goals of { tasks : task_goals Agent_core_base.Nonempty.t; unrecorded_turns : int }
  | Unrecorded of { turns : int }
```

`task_goals` 는 지금 `Keeper_librarian.goal_context` 의 `Task_goals` 가 싣는 필드 그대로다
(#38114). 비어 있지 않은 목록은 새로 만들지 않고 `packages/agent_core/lib/base/nonempty.mli`
의 `Agent_core_base.Nonempty.t` 를 쓴다(`lib/dune` 이 이미 `masc.agent_core.base` 에 기댄다).

- 범위의 턴이 모두 기록돼 있고 Task 가 없으면 `No_task`.
- 하나라도 Task 가 있으면 `Task_goals`. 기록이 없는 턴이 섞였으면 그 수를 함께 싣는다.
- 모든 턴이 기록 없음이면 `Unrecorded`.
- 프롬프트는 `unrecorded` 를 "이 턴들의 Task 는 알 수 없다" 로 설명한다. `no_task` 와
  섞지 않는다.

Task 줄 append 가 실패하면 그 턴은 영구히 `unrecorded` 다. 경계 줄과 달리 다음 줄이
대신 덮어 주지 않는다. finalize 는 경계 줄 실패와 같은 방식으로 실패를 센다
(`TurnBoundaryFailures`, `site:"tasks_append"`). 두 번 append 하므로 Task 줄만 따로
실패할 수 있다(§2.2).

### 2.4 범위와 맞춘다

- durable 회차는 `steps` 의 각 `turn_ref` 에 해당하는 `Turn_tasks` 를 모은다.
  대체 컷(범위에 경계 줄이 없을 때)은 끝 턴 하나만 안다. 그때는 끝 턴의 Task 만
  싣고 나머지는 `unrecorded_turns` 로 센다.
- continuity 회차는 `fit_continuity` 가 범위를 줄인 **뒤에** `goal_context` 를 만든다.
  지금은 줄이기 전에 만든다(`keeper_librarian_queue_refresh.ml`). 보내지 않은 턴의
  Task 가 실리면 안 된다.

### 2.5 배포와 롤백 순서

경계 파일 reader 는 모르는 `kind` 를 거절한다. 경계를 읽지 못하면 `turn_start` 가
`Turn_boundary_unknown` 이 되고(#38070), 모든 Keeper 가 가장 새 atom 하나만 싣는다.
그래서 `turn_tasks` 줄을 모르는 바이너리가 그 줄이 든 파일을 한 번이라도 읽으면 fleet
전체가 한꺼번에 영향을 받는다.

두 릴리스로 나눈다.

1. **reader 릴리스.** `Turn_tasks` 생성자와 모든 경계 reader 의 처리를 넣는다. writer 는
   넣지 않는다. 이 릴리스는 파일에 새 줄을 쓰지 않으므로 옛 바이너리로 되돌려도 안전하다.
2. **writer 릴리스.** finalize 가 `turn_tasks` 줄을 쓰기 시작한다. 이 릴리스를 되돌릴 때는
   1번 릴리스까지만 되돌린다. 1번보다 옛 바이너리로 되돌리려면, 서버를 멈춘 것을 확인한
   뒤 시작하기 전에 경계 파일에서 `turn_tasks` 줄을 먼저 지워야 한다.

두 릴리스 사이에 적어도 한 번 라이브를 1번으로 배포해 둔다. 롤백 대상 바이너리에
reader 가 있다는 것을 보장하려는 것이다.

## 3. 바꾸지 않는 것

| 그대로 | 왜 |
|---|---|
| queue 회차의 Task 읽기 | 턴 범위가 없는 회차라 도는 순간의 Task 를 쓴다. #38114 가 연결했다(병합됨). 구현 PR 은 그 `Task_goals { task_id; criteria }` 를 원소 하나짜리 `tasks` 로 옮긴다. |
| 옛 경계 줄 | 새 생성자만 더한다. 옛 줄은 그대로 읽힌다. |
| Goal 기준을 기억의 근거로 쓰지 않는다는 프롬프트 규칙 | Goal 은 참고 자료다. |

## 4. 대안

- **턴이 끝날 때의 Task 하나만 적는다.** Task 를 끝낸 턴이 틀리게 적힌다(§2.1).
- **새 파일 `turn-tasks.jsonl` 에 적는다.** 처음 초안이다. 두 파일 사이의 쓰기 순서,
  같은 `turn_ref` 가 두 번 나오는 경우, 배포 preflight 등록이 새로 생긴다. 같은 파일의
  새 생성자는 이 셋이 모두 없다.
- **경계 줄 `Turn_ended` 에 필드를 더한다.** 옛 줄에 필드가 없어서 필드 없는 줄을
  받아 주는 코드가 생긴다.
- **지금 meta 의 Task 를 쓴다.** 옛 턴이 나중 Task 에 묶인다(#37208 이 막은 오류).
- **실행 receipt 의 `current_task_id` 를 쓴다.** receipt 는 턴마다
  `acc.meta.current_task_id` 를 이미 적는다(`keeper_agent_run_receipt.ml`). 그러나
  날짜별 store 라 기본 30일 뒤 지워지고, 끝 시점 값 하나뿐이다. 뒤처진 keeper 는
  Task 를 잃는다.

## 5. 검증

단위 테스트:
- 턴 안에서 Task 를 끝낸 턴은 그 Task 를 적는다.
- claim A 후 claim B 한 턴은 둘 다 적는다.
- `Turn_tasks` 가 `Turn_ended` 바로 앞에 쓰이고, 줄 순서로 짝지어진다.
- 같은 `turn_ref` 가 두 번 나와도 줄 순서로 맞는 턴을 고른다.
- 기록 없는 턴만 있는 범위는 `Unrecorded`, 섞이면 `unrecorded_turns` 가 센다.
- `no_task` 와 `unrecorded` 가 프롬프트에 다르게 그려진다.
- 줄인 continuity 범위의 Goal 목록이 실제로 보낸 턴과 맞는다.
- 모르는 `kind` 는 읽기 오류다.
- red control: `Turn_tasks` 를 모르는 reader(= reader 릴리스 이전 바이너리)가
  `turn_tasks` 줄이 든 파일을 읽으면 `Keeper_carried_front.current_generation_floor` 가
  `Error` 다. §2.5 의 두 릴리스 순서가 왜 필요한지 이 테스트가 말한다.
- Task 줄만 쓰고 경계 줄이 실패한 뒤, 다음 턴이 두 줄을 다 쓰면 다음 턴은 자기 Task 를
  싣는다. 다음 턴의 Task 줄도 실패하면 다음 턴은 기록 없음이고 앞 턴의 Task 를 빌리지
  않는다(`turn_ref` 불일치).
- `Turn_ended` 바로 앞이 `Turn_tasks` 가 아닌 줄(예: `History_restarted`)이면 기록 없음이다.

라이브: 배포 뒤 Task 를 가진 keeper 의 durable 회차 입력(exact-input payload)에
`goal_context` 가 실리는지 본다.

## 6. 열린 항목

- 공식 클라이언트 턴은 끝까지 가면 finalize 를 지나고 `No_atom_history` 경계 줄을
  남긴다. finalize 전에 `Error` 로 끝난 턴은 경계 줄도 없어서 지금도 읽히지 않는다.
  이 RFC 가 바꾸지 않는다.
- 모르는 `kind` 는 지금 경계 파일 reader 가 하는 대로 읽기 오류다. 옛 reader 가
  `turn_tasks` 줄을 만나지 않게 하는 순서는 §2.5 가 정한다.
