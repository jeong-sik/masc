---
rfc: "uncollected-provider-turn-is-not-resumed"
title: "Name the turn cut before collection instead of resuming it"
status: Draft
created: 2026-11-16
updated: 2026-11-16
author: claude-main
related: []
---

# RFC: 응답을 모으기 전에 끊긴 턴은 다시 잇지 않고 이름을 붙여 돌려준다

- 관련: #52341, #42073, #47059
- 범위:
  - agent_core 의 durable 실행 다시 잇기(`Pipeline_execution_scope`, `Pipeline_execution_resume`).
  - masc 가 채팅 작업의 native 호출을 다시 잇는 자리(`Keeper_direct_native_continuation`, `Keeper_turn_driver`).
  - 기록(journal) 구조와 체크포인트 형식은 바꾸지 않는다.

## 1. 사건

2026-11-15 15:42 UTC 에 운영 서버가 종료 절차 없이 끝났다.
17:00 과 17:06 에 다시 띄우자 Keeper 메시지 8건이 아래 오류로 끝났다(`chat-operations.sqlite3` 에서 `failed / Turn_exception`).

```
Internal error: restored checkpoint turn counter differs from the owning durable turn
```

- 같은 때 `masc restart` 로 끊긴 메시지 3건은 `Interrupted_by_restart` 로 닫혔다.
- 10-09 의 #42073 도 같은 상태로 보인다. 그때는 `provider response authority is not materialized` 로 끝났다.
- #47059(11-02)가 턴 번호 검사를 앞에 둔 뒤로 문구만 바뀌었다.

## 2. 왜 문제인가

- 같은 사건을 두 경로가 다르게 끝낸다.
  - 종료 절차를 거치면 Owner 가 `Interrupted_by_restart` 를 남긴다.
  - 거치지 않으면 다음 기동이 다시 잇기를 시도하다 `Turn_exception` 으로 끝난다.
  - `keeper_owner.ml:1865-1868` 은 「이 기록 없이 죽은 행도 다음 기동에서 같은 종류로 정리된다」고 적는다. 두 번째 경로가 이 약속과 어긋난다.
- 이 실패가 깨진 기록과 구별되지 않는다. 운영자도 masc 도 `Error.Internal` 문구만 본다.
- 헛된 다시 잇기에 몇 분을 쓴다. 11-15 사례는 기동 뒤 2~4분 동안 Librarian inventory 와 입력 조립을 마친 뒤에야 실패했다.
- 끊기는 자리가 대부분 이 상태다. 턴 시간 대부분이 provider 호출이기 때문이다.

## 3. 지금 일어나는 일

### 3.1 한 턴의 기록 순서

`packages/agent_core/lib/pipeline/pipeline.ml` 기준이다.

1. provider 시도를 연다. `Pipeline_execution_scope.before_provider_attempt`(`pipeline_execution_scope.ml:116`)가 턴마다 한 번 연다(`~ordinal:0`, 120행).
2. provider 에 HTTP 호출을 한다.
3. 받아들인 응답을 기록한다(`record_provider_response`, 292행).
4. `turn_count` 를 턴 번호 + 1 로 올리고 체크포인트를 `After_assistant_collected` 로 저장한다(456~463행).
5. Tool 을 실행한다(`stage_execute`, 532행). Tool invocation 은 여기서 열린다(`agent_tools.ml:1033`).

### 3.2 다시 잇기

- `Pipeline_execution_scope.resume_current` 는 열린 턴 아래의 열린 provider 시도를 `Active` 로 돌려준다.
- `Execution_agent_scope.resume_provider_attempt`(`execution_agent_scope.ml:430`)는 응답이 기록됐는지 보지 않는다.
- `Pipeline_execution_resume.dispatch` 는 `Active` 에서 먼저 `validate_collected_counter`(185행)를 부른다. 이 검사는 `turn_count = 턴 번호 + 1` 을 요구한다.
- 1~4 사이에서 끊기면 마지막 체크포인트는 호출 전 것이다. `turn_count` 가 턴 번호와 같아서 검사에 걸린다.
- 3 과 4 사이(응답은 기록, 체크포인트는 전)도 같다.

결정론 재현(#52341 댓글):
- `test_active_terminal_resumes_committed_checkpoint` fixture 를 본떴다.
- `turn_count = 7` 체크포인트를 기록하고, 턴 7 과 provider 시도를 연 채 `Agent.resume` → `Agent.run` 을 불렀다.
- 응답이 없을 때와 있을 때 모두 provider 호출 0번, 위 오류, 실행 root 는 성공이 아닌 종료였다.

### 3.3 agent_core 가 약속한 범위

`packages/agent_core/lib/agent/agent.mli` 는 이 상태를 resume 이 이어 준다고 약속하지 않는다.

- 327행: resume 은 terminal 응답과 모은 체크포인트가 저장된 경우를 잇는다.
- 315~317행(`observe_execution`): `Retire` 는 writer 를 잃을 때 열려 있던 provider 요청에 대해 아무것도 말하지 않는다. 잃은 실행이 host 의 일에 무엇을 뜻하는지는 host 가 정한다.

masc 는 이 결정을 하지 않고 같은 기록을 resume 에 넘긴다.
agent_core 는 약속 밖의 상태를 깨진 기록과 같은 `Error.Internal` 로 돌려준다.
그래서 masc 는 「모으기 전에 끊김」과 「기록이 어긋남」을 가를 수 없다.

### 3.4 masc 에 이미 있는 것

- native 호출의 기록이 `recovery = Retire` 로 끝나 있으면, 다음 시도는 붙은 호출이 없는 것으로 보고 새로 시작한다(`keeper_turn_driver.ml:2659`).
- 실패한 runtime 을 다음 runtime 으로 넘길 때 새 native 호출이 체크포인트에서 이어 한다(`Native.Continue_from_checkpoint`, `keeper_turn_driver_try_provider.ml:2716`).
- 종료 절차 중에는 Owner 가 도는 턴을 멈추고 `Interrupted_by_restart` 를 남긴다(`keeper_owner.ml:1865-1875`).

## 4. 제안

### 4.1 agent_core: 모으기 전에 끊긴 턴에 이름을 붙인다

`Pipeline_execution_resume.resolve`(412행)가 `resume_current` 에서 열린 provider 시도를 받으면, 복원한 체크포인트의 `turn_count` 를 턴 번호와 견줘 세 갈래로 나눈다. 체크포인트를 가진 것은 `resolve` 가 받는 Agent 상태다.

| `turn_count` | 뜻 | 처리 |
|---|---|---|
| 턴 번호 + 1 | 모은 체크포인트가 있다 | 지금처럼 `Active` 로 잇는다 |
| 턴 번호 | 모으기 전에 끊겼다 | 새 갈래 `Uncollected` |
| 그 밖 | 기록이 어긋났다 | 지금처럼 `Error.Internal` 로 막는다 |

`Uncollected` 일 때 하는 일:
- provider 를 부르지 않는다.
- provider 시도, 턴, root 를 `Cancelled` 로 닫는다.
- 종료 disposition 의 `recovery` 는 `Retire` 다.
  - 이 턴에는 Tool invocation 이 있을 수 없다(3.1 의 5). invocation 이 있으면 기록이 어긋난 것이라 `Error.Internal` 로 막는다.
- 부른 쪽에는 타입 있는 결과로 알린다. 문구로 가르지 않는다.

기록된 응답(3 과 4 사이)은 쓰지 않는다.
- 응답만으로는 모은 메시지를 다시 만들 수 없다.
- 받아들이지 못한 tool 호출은 응답에서 빠지고 따로 답한다(`pipeline.ml:283-287`). 그 답은 응답에 없다.
- #47059 가 응답을 체크포인트 전에 기록한 것은 체크포인트 **뒤**의 복구(Tool 실행 중 끊김)에 쓰려는 것이다. 이 구간을 위한 것이 아니다.

### 4.2 masc: 같은 사건은 같은 결과로 끝낸다

채팅 작업의 native 호출이 `Uncollected` 로 끝나면 Owner 가 그 작업을 `Interrupted_by_restart` 로 정리한다.
- 종료 절차를 거친 재시작과 결과가 같다.
- `keeper_owner.ml:1865-1868` 의 약속과 맞는다.
- 몇 분 걸리는 헛된 다시 잇기를 하지 않는다. `Uncollected` 는 provider 와 Tool 을 부르기 전에 정해진다.

메시지는 여전히 실패로 끝난다. 끊긴 메시지를 이어 할지는 두 재시작 경로를 함께 바꾸는 별도 결정이다(7 절).

## 5. 순서와 상태

Keeper 하나가 채팅 작업 하나를 돌리는 동안의 틱이다.

| 틱 | 일 | 지금 | 제안 |
|---|---|---|---|
| N | 턴 k 의 provider 호출 중 프로세스가 죽는다 | 작업 `running`, 턴 k·provider 시도 열림, 체크포인트 `turn_count = k` | 같음 |
| N+1 | 기동, Owner 가 작업을 다시 집는다 | 입력을 조립한 뒤 `dispatch` 의 검사에서 `Error.Internal` | `resolve` 가 `Uncollected` 를 돌려준다. 실행은 `Cancelled`·`Retire` 로 닫힌다 |
| N+2 | Owner 가 작업을 정리한다 | `failed / Turn_exception` | `failed / Interrupted_by_restart` |
| N+3 | 다음 작업이 슬롯을 받는다 | 같음 | 같음 |

- 다른 Keeper 가 그 메시지를 보냈다면 N+2 에 실패를 받는다. 지금과 같고, 실패 종류만 바뀐다.
- 재시작이 다시 일어나도 갈래는 같다. 재시도 횟수나 시간 한도가 없다. 아무것도 다시 부르지 않기 때문이다.
- 종료 절차를 거친 재시작은 지금과 같다.

## 6. runtime 바꿈·문맥 창·계정·위임

- runtime 바꿈(failover): `Uncollected` 는 어느 runtime 도 부르지 않는다. 끊긴 시도의 runtime 과 다음 후보는 이 RFC 와 관계없다.
- 문맥 창: 새 요청을 만들지 않으니 크기 판정이 없다.
- 계정(Provider Runtime 소유): 끊긴 호출의 계정 사용은 프로세스와 함께 사라졌다. 정리할 것이 없다.
- 위임(하위 Agent): 하위 실행은 부모 턴의 Tool 안에서 돈다. 부모 턴은 모은 체크포인트 뒤라서 `Active` 다. Tool 결과가 없는 invocation 은 지금처럼 `Operator_repair_required Effect_outcome_unknown` 이다. 바뀌지 않는다.
- 공식 클라이언트(CLI) 레인: agent_core durable provider 시도를 쓰지 않는다. 범위 밖이다.

## 7. 하지 않는 것

- 같은 턴에서 provider 를 다시 부르지 않는다. 턴마다 provider 시도가 하나라는 기록 규칙을 그대로 둔다.
- 기록된 응답으로 메시지를 다시 만들지 않는다(4.1).
- `validate_collected_counter` 를 지우지 않는다. 어긋난 기록은 그대로 막는다.
- 오류 문구로 상태를 가르지 않는다.
- 끊긴 메시지를 호출 전 체크포인트에서 새 native 호출로 이어 하는 것은 이 RFC 에 넣지 않는다.
  - 이어 하려면 종료 절차를 거친 재시작도 `Interrupted_by_restart` 대신 이어 해야 같은 사건이 같은 결과가 된다.
  - 장치는 있다(3.4). 하지만 재시작이 무엇을 뜻하는지 바꾸는 결정이라 따로 정한다.

## 8. 시험

agent_core:
- #52341 재현 fixture 두 경우(응답 없음·있음) → `Uncollected`, provider 0회, root `Cancelled`·`Retire`.
- `turn_count = 턴 번호 + 2` → `Error.Internal`(지금의 `Stale_terminal_counter` 와 같은 쪽).
- `Uncollected` 인데 Tool invocation 이 열려 있음 → `Error.Internal`.
- 기존 `Active` 다시 잇기 시험이 그대로 통과한다.
- 세 갈래 가운데 둘의 처리를 맞바꾸면 시험이 실패한다.

masc:
- 기동 뒤 native 호출이 `Uncollected` 로 끝난 채팅 작업 → `failed / Interrupted_by_restart`, Agent 호출은 provider 를 부르지 않는다.

## 9. 단계

| 층 | 내용 |
|---|---|
| L0 | 이 RFC |
| L1 | agent_core: `Uncollected` 갈래, 닫기, 타입 있는 결과, 시험 |
| L2 | masc: `Uncollected` → `Interrupted_by_restart`, 시험 |

## 10. 정할 것

- `Uncollected` 를 부른 쪽에 알리는 모양: `Error.t` 의 새 갈래인지, 실행 결과(`execution_terminal_evidence`)에서 읽게 할지.
- 끊긴 메시지를 이어 할지(7 절). 정하면 두 재시작 경로를 함께 바꾸는 RFC 를 따로 쓴다.
