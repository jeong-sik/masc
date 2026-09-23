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

### 2.1 턴이 끝날 때 그 턴의 Task 를 따로 적는다

턴을 마무리하는 쪽(finalize)이 턴 끝 줄을 쓰는 같은 자리에서, 새 파일
`keepers/<keeper>/turn-tasks.jsonl` 에 한 줄을 더한다.

```
{ "turn_ref": "...", "task": { "kind": "current_task", "task_id": "..." } }
{ "turn_ref": "...", "task": { "kind": "no_task" } }
```

- `task` 는 닫힌 합이다: `No_current_task | Current_task of Task_id`. 알 수 없는
  `kind` 는 읽기 오류다.
- 값은 턴이 끝나는 순간의 meta 에서 읽는다. #34919 의 closure 가 읽던 바로 그
  시점이다.
- 한 줄을 쓰지 못해도 턴은 실패하지 않는다. 턴 끝 줄과 같은 규칙이다. 그 턴은
  아래 §2.3 에서 "기록 없음" 으로 읽힌다.

### 2.2 한 범위의 Task 가 여럿이면 모두 싣는다

durable·continuity 회차가 읽는 범위는 턴 여러 개에 걸친다. 턴마다 Task 가 다를
수 있다. 그래서 `goal_context` 는 범위 안의 서로 다른 Task 를 턴 순서대로 모두
싣는다.

```ocaml
type goal_context =
  | No_task
  | Task_goals of task_goals list   (* 범위 안에 나온 순서, 중복 없이 *)
```

프롬프트는 Task 마다 블록 하나를 그린다. 어느 턴이 어느 Task 였는지는 싣지
않는다. Librarian 은 대화 내용과 Goal 기준을 맞춰 보면 된다.

### 2.3 옛 기록은 읽지 않는다 (hard cut)

새 파일은 배포와 함께 빈 채로 시작한다. 배포 전의 턴에는 줄이 없다.

- 범위의 어떤 턴에도 줄이 없으면 그 턴은 Task 를 모르는 턴이다. 이런 턴만 있는
  범위는 지금처럼 `No_task` 를 싣는다. 오늘과 같은 결과라 나빠지는 것이 없다.
- 줄이 있는 턴과 없는 턴이 섞이면, 줄이 있는 턴의 Task 만 싣는다.
- 턴 끝 파일(`turn-boundaries.jsonl`)은 건드리지 않는다. 이 파일은 Librarian
  이 읽은 위치의 근거라 지우거나 형식을 바꾸면 위치를 잃는다. 그래서 필드를
  더하지 않고 파일을 따로 둔다. 옛 형식을 읽는 호환 코드는 생기지 않는다.

### 2.4 Keeper 를 지울 때

`purge_keeper_artifacts` 가 지우는 목록에 새 파일을 넣는다. 턴 끝 파일과 같은
묶음이다.

## 3. 바꾸지 않는 것

| 그대로 | 왜 |
|---|---|
| queue 회차의 Task 읽기 | 턴 범위가 없는 회차라 도는 순간의 Task 가 맞는 근사다 (#38114). |
| 턴 끝 파일의 형식 | §2.3. |
| Goal 기준을 기억의 근거로 쓰지 않는다는 프롬프트 규칙 | Goal 은 참고 자료다. |

## 4. 대안

- **턴 끝 줄에 필드를 더한다.** 가장 단순하지만, 옛 줄을 계속 읽어야 해서 필드가
  없는 줄을 받아 주는 코드가 생긴다. 저장소 규칙(호환 reader 금지)과 부딪힌다.
- **지금 meta 의 Task 를 쓴다.** 옛 턴이 나중 Task 에 묶인다. #37208 이 막은
  바로 그 오류다.
- **turn_ref 로 task board 이력을 거꾸로 찾는다.** task 이력에는 어느 턴에
  맡았는지가 시각으로만 남아서, 시각을 비교하는 추측이 된다.

## 5. 검증

- 단위 테스트:
  - finalize 가 두 모양(`no_task`, `current_task`)을 쓴다.
  - 범위 하나에 Task 두 개가 있으면 두 블록이 실린다.
  - 줄이 없는 범위는 `No_task` 다.
  - 알 수 없는 `kind` 는 오류다.
- 라이브: 배포 뒤 Task 를 가진 keeper 의 durable 회차 입력(exact-input
  payload)에 `goal_context` 가 `available` 로 실리는지 본다.

## 6. 열린 항목

- 공식 클라이언트 턴(Claude Code·Codex 레인)도 finalize 를 지나는지 확인해야
  한다. 지나지 않는 레인이 있으면 그 레인은 §2.3 의 "기록 없음" 으로 남는다.
