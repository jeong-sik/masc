---
rfc: "0489"
title: "Goal 검증이 판정 없이 끝나면 새 시도로 다시 판정한다"
status: Draft
created: 2026-11-05
updated: 2026-11-05
author: claude
supersedes: []
superseded_by: null
related: ["0387"]
---

# RFC-0489 — 판정을 잃은 Goal 검증은 새 시도로 다시 판정한다

## 0. 요약

- 11-04 08:55:28Z 에 wkbl 1.0.0 Goal 이 완료를 요청했다. 검토는 08:59:29Z 의 SIGTERM 에 243초 만에 취소됐다.
- 그 뒤 25시간 동안 검사가 21번 이 줄만 남기고 지나갔다: `goal verifier deferred ... gate=Original_pending reason=Goal reviewer may have dispatched; no automatic replay`.
- Goal 은 `verifying` 에 머물렀고 알림은 없었다. 11-05 10:25Z 에 운영자가 Reopen 하고 다시 요청하자 5분 만에 판정이 나왔다.
- 같은 모양이 10-30~11-01 에 `goal-1790248232808-05fe959c` 에서 26번 있었다.
- Goal 검증은 판정만 한다. 판정은 저장한 뒤 커밋으로만 기록에 들어간다. 그래서 같은 입력으로 다시 판정해도 기록이 겹치지 않는다.
- 그런데 Goal 검증은 부작용이 있는 요청의 규칙을 따른다. "결과를 모르면 다시 보내지 않는다."
- 이 RFC 는 하나를 제안한다. 판정을 보낸 실행이 판정을 저장하지 않고 끝났으면 그 사실을 거절로 기록한다. 그리고 같은 입력으로 다음 시도(attempt+1)를 만든다. 새 상태와 Gate 는 없다.

## 1. 지금

좌표는 main `f272869591e` 에서 읽었다.

### 1.1 Goal 검증이 멈추는 길

| 들어오는 길 | 남는 기록 | 다음 검사 |
| --- | --- | --- |
| 재시작·취소로 검토 fiber 가 끝남 | `goal_verifier_worker.ml:704-715` 가 `Execution_observed (Outcome_unknown {cause="review_cancelled"})` 를 쓴다 | `:630` 이 `Dispatch_pending _` 를 보고 "no automatic replay" 로 끝낸다 |
| 보낸 뒤 timeout·네트워크·내부 오류 | `anti_rationalization.ml:604-620` 이 결과 모름으로 분류하고 `:673` 이 기록한다 | `:691` 이 `Execution_pending` 을 돌려준다 |
| 판정 저장 실패(`Retention_failed`) | 아무것도 안 쓴다. `Dispatch_pending None` 이 남는다 | `:630` 과 같다 |
| SIGKILL·OOM·강제 종료 | 처리기가 돌지 못한다. `Dispatch_pending None` 이 남는다 | `:630` 과 같다 |

- `goal_verification_agent.ml:517` 은 이 결과를 `Not_reviewed {gate="Original_pending"; retryable_runtimes=[]}` 로 바꾼다.
- `schedule_retry`(`:737`)는 재시도할 런타임이 있을 때만 타이머를 건다. 여기서는 아무것도 걸지 않는다.
- 운영자나 Keeper 가 다시 요청해도 `request_retry`(`goal_verifier_worker.ml:606-609`)가 거절한다.
- #48000 이 정체를 알리던 Board 글을 지웠다. 남는 신호는 WARN 줄과 실행 원장 행뿐이다.
- 시험 `test/test_goal_verifier_worker.ml:336-348` 은 취소된 원본을 다시 돌리지 않는다고 단언한다.

### 1.2 지금 규칙이 지키는 것

- 공용 규약 `lane_addon_request_progress.mli:63-64` 는 대기·결과 모름·worker 없음이면 같은 원본을 다시 보내지 않게 한다. 보낸 요청이 바깥에 효과를 냈을 수 있는 경우에 맞는 규칙이다.
- #47530 은 Goal 재요청을 막으며 이유를 적었다. "pending 기록만으로는 이전 실행이 끝났다는 걸 알 수 없다."

### 1.3 Goal 검증에서 맞는 사실

- Goal 판정은 같은 프로세스 안의 콜백 하나로만 들어온다(`goal_verifier_worker.ml:684-685` 의 `~on_verdict:retain_reply`).
- 판정을 저장하지 못한 원본은 커밋할 수 없다. 규약은 `Dispatch_pending` 에서만 `Judged` 로 가게 한다(`lane_addon_request_progress.ml:158-161`).
- 규약은 `Dispatch_pending` 에서 `Rejected` 로 가는 실행 거절을 이미 허용한다(`lane_addon_request_progress.ml:187`).
- base path 는 프로세스 하나만 쥔다(`server_startup_takeover.mli:117` 의 `acquire_base_path_lock`).
- 그러므로 판정을 보낸 실행이 끝났거나 그 원본을 쓴 프로세스가 사라졌으면, 그 원본의 판정은 다시 오지 않는다. #47530 이 요구한 "실행이 끝났다는 사실"이 이것이다.
- constitution 은 비용을 문제 삼지 않고(`cost_and_observability`) 하드 게이팅을 기본으로 두지 않는다(`gates`).

## 2. 제안

### 2.1 사실 하나: 판정을 잃음

Goal worker 에 닫힌 합을 둔다.

```ocaml
type dispatcher_exit =
  | Cancelled
  | Provider_outcome_unknown
  | Retention_failed
  | Raised

type judgment_lost =
  | Dispatcher_ended of dispatcher_exit
  | Previous_owner_exited
```

- `run` 이 `Dispatch_intended` 를 쓴 뒤 판정을 저장하지 않고 끝나면 `Refused {stage=Execution; evidence=<judgment_lost>}` 를 쓴다. 끝나는 방식은 위 네 가지다.
- 거절 증거는 함수 하나로 디코드한다. 결과는 닫힌 합(평가자 거절 | 판정 잃음)이다. 거절 증거를 읽는 worker 와 host 의 모든 자리가 이 함수를 거친다. 한 곳이라도 새 증거를 거절하면 Goal 이 다른 모양으로 다시 멈추기 때문이다.

### 2.2 언제 새 시도를 만드는가

| 사실 | 다음 시도 |
| --- | --- |
| `Dispatcher_ended Cancelled` | 자동 |
| `Dispatcher_ended Provider_outcome_unknown` | 자동. 기존 재시도 타이머 간격을 쓴다 |
| `Dispatcher_ended Retention_failed` | 자동 |
| `Dispatcher_ended Raised` | 명시 재요청(`request_complete`)만 |
| `Previous_owner_exited` | 자동 |

- `Raised` 만 자동에서 뺀다. 같은 입력에서 같은 예외가 나면 검사마다 LLM 을 다시 부르게 된다.
- 자동 시도는 `select_frontier ~automatic:true` 의 기존 후속 시도 경로(attempt+1)를 쓴다.
- 새 시도는 지금 요청 id 와 기준에 묶인다. Reopen·Drop·기준 변경으로 요청이 바뀌었으면 새 시도는 생기지 않는다.

### 2.3 서버가 뜰 때

- `Goal_verification_agent.start`(`goal_verification_agent.ml:940`)는 검토 fiber 를 띄우기(`:990`) 전에 남은 `Dispatch_pending` 원본을 찾는다.
- 찾은 원본은 `serialized_subject` 아래에서 `Refused {stage=Execution; evidence=Previous_owner_exited}` 로 바꾼다.
- 근거: lease 를 쥔 이 프로세스는 아직 검토를 시작하지 않았다. 그러니 남은 `Dispatch_intended` 는 이전 프로세스가 쓴 것이다.
- 이 단계는 이미 멈춘 원본도 같은 규칙으로 푼다. 옛 기록을 옮기는 코드는 따로 쓰지 않는다.

### 2.4 시험

기능 단위로 본다.

- Goal 검토 중 취소 → 다음 검사가 attempt 1 을 돌려 판정을 커밋한다. `test_goal_verifier_worker.ml:336-348` 의 단언을 이 동작으로 바꾼다.
- 보낸 뒤 provider timeout → attempt 1 이 자동으로 돈다.
- `Raised` → 자동 시도가 없다. `request_complete` 로 다시 요청하면 attempt 1 이 돈다.
- 시작 때 남은 `Dispatch_pending` → `Previous_owner_exited` → attempt 1 이 돈다.
- 판정을 잃은 원본은 커밋할 수 없다(`Rejected` 에서 `Judged` 로 못 간다).

## 3. 하지 않는 것

- 공용 규약의 "같은 원본을 다시 보내지 않는다"는 바꾸지 않는다. 같은 원본이 아니라 다음 원본을 만든다.
- Task 검증(`verifier_review_worker.ml`, `completion_authority_agent.ml`)은 바꾸지 않는다. 실행 기록에서 늦게 도착한 판정을 다시 읽는다(`verifier_review_execution.ml:94-131`). "판정이 다시 오지 않는다"가 맞지 않는다.
- 시도 횟수 상한, cooldown, 정체 알림 글을 넣지 않는다.
- Goal 검증 말고 다른 판정 요청은 이 RFC 에서 바꾸지 않는다.

## 4. 층

1. `judgment_lost` 합, `run` 종료 기록, 거절 증거 디코드 일원화, 시험. 확인: CI Core type-check 와 `test_goal_verifier_worker`.
2. 서버 시작 단계와 재시도 타이머. 확인: 시작 시나리오 시험.
3. 배포 뒤 실측: 검토 중에 한 번 재시작한다. `goal-verification-runs.jsonl` 에 attempt 1 의 `committed` 가 남는지 본다.

## 5. 열린 질문

1. base path lease 를 쥐는 다른 실행(`bin/main_stdio_eio.ml:55`, `bin/deployment_preflight_helper.ml:443`)이 Goal 검토를 돌리지 않는가. 돌린다면 2.3 의 근거가 깨진다.
2. Librarian admission, workspace memory curator, browser add-on 의 LLM 호출도 판정만 하는가. 그렇다면 같은 정지가 있는지 재 보고 따로 다룬다.
3. `Provider_outcome_unknown` 의 자동 시도 간격으로 기존 maintenance pulse 를 그대로 쓰는가.
4. 운영자 Drop·Reopen 도 검토 fiber 를 취소한다(`goal_verification_agent.ml:811` 의 `Fiber.first`). 그 원본은 `Dispatcher_ended Cancelled` 로 남는다. 요청이 바뀌어 새 시도는 생기지 않는다. 기록 이름이 사실과 맞는지만 확인한다.
