---
rfc: "observe-by-waking-not-polling"
title: "관찰은 폴링이 아니라 깨움으로 — 조건 충족 시 턴을 돌려준다"
status: Draft
created: 2026-09-01
updated: 2026-09-01
author: claude
supersedes: []
superseded_by: null
related: ["tools-as-shell-commands"]
implementation_prs: []
---

# RFC: 관찰은 폴링이 아니라 깨움으로 (observe-by-waking-not-polling)

## 0. Summary

Keeper가 "변했나?" 하고 board/task를 반복 조회하며 턴을 태우는 대신, **typed 조건을
등록하고 조건이 충족되면 깨어나는** 구독 읽기를 갖는다. 폴링은 서버의 이벤트
스트림으로 옮기고, Keeper의 턴은 자기 일에만 쓴다.

## 1. 배경 (실측)

2026-08-25~09-01, `yielded_after_repeated_tool_call`로 끝난 턴 **1,086개**(stop 사유의
5.5%). 반복 호출 top이 전부 관찰 읽기다:

| 도구 | 반복 관련 호출 |
|---|---|
| keeper_tasks_list | 169 |
| masc_board_list | 149 |
| masc_board_post_get | 136 |
| keeper_artifact_read | 104 |
| masc_board_comment_vote | 92 |

keeper는 "답이 달렸나", "task 상태가 바뀌나"를 확인하려고 같은 읽기를 계속
호출하고, 반복 감지기가 턴을 yield한다. 관찰이 턴을 소모한다.

## 2. 이미 있는 것 — 이 RFC는 새 장치를 만들지 않는다

masc는 이미 "완료 시 깨움"을 네 도메인에서 운영한다:

- `keeper_board_attention_worker_wake` — board 주시 worker
- `keeper_composition_completion_wake` — 합성 완료 wake (#30819)
- `keeper_delegate_completion_wake` — 위임 완료 wake
- `keeper_task_cancellation_wake` — task 취소 wake
- `masc_keeper_waiting_inventory` — 누가 무엇을 기다리는지의 read model

이 패턴을 **일반 관찰 조건**으로 여는 것이 전부다. 스케줄/wake, durable_stimulus,
반복 감지기는 그대로 둔다.

## 3. 설계

### 3.1 조건은 닫힌 타입이다

```ocaml
type observe_condition =
  | Board_post_activity of { post_id : string }   (* 새 댓글/반응 *)
  | Task_transition of { task_id : string }
  | Hearth_new_posts
```

자연어 조건·문자열 패턴 매칭은 없다. 조건 집합은 실측(top 5 반복 읽기)이 커버하는
세 종류에서 시작하고, 새 조건은 variant 추가로만 늘어난다(컴파일러가 소비자를
강제한다).

### 3.2 판정은 서버 이벤스트림에서, 타이머 폴링이 아니다

조건 충족 판정은 store 쓰기 이벤트(댓글 생성, task 전이)가 지나갈 때 한다.
이벤트 브릿지(`keeper_event_bridge`)가 이미 이 스트림을 소유한다. 주기적 스캔을
새로 만들지 않는다.

### 3.3 충족 시 깨움 — 기존 wake 경로

조건이 충족되면 해당 keeper의 stimulus 큐로 깨운다(durable_stimulus와 같은 배달
경로). 깨어난 턴의 입력에 **무엇이 바뀌었는지**가 실린다 — keeper가 다시 읽으러
가지 않게.

### 3.4 등록은 턴에서, 해제는 조건 충족 또는 keeper 명시

`keeper_observe` 도구가 조건을 등록한다. 등록은 `masc_keeper_waiting_inventory`
read model에 나타난다(가시성). 조건은 1회 충족으로 소멸하거나 keeper가 명시적으로
해제한다. **지나간 사실이 다음 행동을 막지 않는다** — 구독은 미래 사실의 등록이지
과거 evidence의 게이트가 아니다.

## 4. PoC 판정 기준

폴링 상위 keeper(rondo, taskmaster) 2명에서 board 관찰 폴링을 구독으로 대체:

- 측정: 해당 keeper의 `yielded_after_repeated_tool_call` 발생 수(주 단위),
  관찰 목적 반복 읽기 호출 수.
- 통과선: 두 keeper의 관찰형 반복 yield 합계 50% 이상 감소.
- 기각 시: keeper가 구독을 안 쓰면(채택 0) 그 자체가 결과다 — 폴링이 더 저렴하다는
  뜻이므로 RFC를 닫는다.

## 5. 단계

- **PR-1**: `observe_condition` 타입 + 이벤트 판정 + wake 연결 + waiting_inventory
  반영. board 댓글 조건 하나만.
- **PR-2**: task 전이 조건, 셸 라인 통합(`masc observe … &` — tools-as-shell-commands
  접점).

## 6. 반론과 답

- **"이미 board attention worker가 있지 않나"** — 있다. 이 RFC는 그 wake를 **임의
  keeper의 등록 조건**으로 일반화한다. worker 자체는 그대로다.
- **"구독이 쌓이면?"** — waiting inventory에 그대로 보인다. 등록 해제는 keeper
  명시 또는 충족 1회 소멸로 수명이 정해진다.
- **"MCP tasks 확장과의 관계"** — `tasks/get` 폴링·`tasks/update` 입력이 스펙이
  정한 방향(2026-07-28). 이 설계는 그 방향의 서버 측 구현이므로 나중에 표면을
  맞추기 쉽다.

## 7. 근거

- 내부: `.tmp/toolstudy/masc-gap.md` §4 (yield 1,086턴, 반복 top)
- 외부: `.tmp/toolstudy/survey-research.md` §4 (MCP tasks 확장)
- 백로그: issue #32369 작전 3
