---
rfc: "candle-held-window-release"
title: "보류된 Candle 지급 창을 운영자 근거로 닫는다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: sangsu
related: ["goal-candle-ledger"]
---

# RFC: 보류된 Candle 지급 창을 운영자 근거로 닫는다

이슈 #49172 와 task-3288 을 다룬다. 보류(`candidate_window_held`)에 들어간 지급에는 나오는 길이 없다.

개정(2026-11-06): 독립 검토 세 건(pangyo-preachers 두 건, anyang-keepers 한 건)의 지적을 받아 `Order_ruled` 를 이 RFC 에서 뺐고, 닫는 길을 **새 이벤트를 따로 두지 않고 기존 `Unattributed` 에 이유 하나를 더하는 것**으로 바꿨다. 이유는 §3 과 §6.

## 1. 관찰한 현재 동작

모두 `origin/main` e1001bccf3 에서 직접 읽은 것이다.

- 쓰는 곳: `lib/candle_runtime/candle_candidates.ml` 의 `write_candidates`. 후보 창 관측에 `Same_second` 또는 `Reversed_window` 가 있으면 `Candidate_window_held` 를 쓴다. 이 두 가지는 Task 완료와 Goal 생성·확정의 선후를 시각으로 정할 수 없다는 뜻이다. 감정(appraiser) 결과 모름과는 다른 경로다.
- 한 번 쓰이면 `prepare` 는 `Held_window` 만 돌려준다(`candle_candidates.ml` 159-160).
- `lib/candle/candle_payout.ml` 의 `validate_settlement_under`(435, 441) 는 보류가 있으면 `Paid`·`Unattributed`·`Payout_failed` 를 모두 거절한다. `validate_under` 는 `Payout_owed`·`Candidates`·`Candidates_fenced` 도 거절한다.
- 보류를 닫는 이벤트는 없다. goal-candle-ledger RFC 도 이를 한계로 적었다("보류를 해제하거나 운영자 근거를 받아 재판정하는 명령과 화면이 없다").
- 요청이 닫힌 것으로 읽히는 기준은 `is_settled`(`candle_payout.ml` 46-56)다. 같은 `goal_id` 에 `Unattributed` 또는 `Paid` 가 하나라도 있으면 `Settled` 다. `state` 도 `is_settled` 를 먼저 본다(89). `Settled` 가 된 의무에는 `append_when_still_open` 의 `open_payout = waiting` 조건(`candle_candidates.ml` 33-40)이 거짓이라 `write_candidates` 가 아무것도 쓰지 않는다.

따라서 보류된 지급은 원장 규칙상 영구히 열린 채 남는다. 이슈 본문의 재현 3단계(감정 결과 모름 → 보류)는 위 코드와 다르다. a46df693 의 보류 행(`tasks`)을 읽어 실제 원인을 확인해야 한다. 이 문서를 쓰는 레인은 원장 파일을 읽지 못했으므로 **미확인**이다.

## 2. 단순 재시도는 답이 아니다

보류의 원인은 이미 기록된 Task 완료 시각이다. 시각은 바뀌지 않으므로 보류를 풀고 다시 관측하면 같은 이유로 다시 보류된다. 풀려면 시각이 못 정한 선후를 누군가 정해 줘야 한다. 그리고 정한 값이 다시 `Candidates` 로 이어지려면 `prepare` 와 `validate_durable_candidates_internal` 의 `observation_issues` 검사를 건너뛰는 출처 표시가 필요하다(§6).

## 3. 제안: 이유 하나를 더한 `Unattributed`

새 이벤트를 만들지 않는다. 기존 `Unattributed` 의 이유(`unattributed_reason`, `lib/candle/candle_event.ml` 33)에 변형 하나를 더한다.

```
| Held_window_closed of
    { held_at : Candle_time.t     (* 닫는 보류 행의 시각 *)
    ; operator : string           (* 서버가 확인한 관리자 신원 *)
    ; reason : string }           (* 비어 있지 않은 근거 문장 *)
```

효과: 지급 없이 닫는다. 가장 보수적이다. `Reversed_window` 도 같은 방법으로 닫는다(Goal 시각 자체가 모순이라 선후를 정할 수 없다).

검증 규칙(`validate_settlement_under`):

- 보류가 있고 `Unattributed { reason = Held_window_closed h }` 이며 `h.held_at` 이 그 보류 행의 시각과 같을 때만 통과시킨다. 다른 보류를 닫지 못한다.
- 보류가 있는데 이유가 `Held_window_closed` 가 아니면 지금처럼 거절한다.
- 보류가 없는데 `Held_window_closed` 이면 거절한다.
- `operator` 와 `reason` 이 비어 있으면 거절한다.
- `Held_window_closed` 는 감정이나 후보 id 집합 검사를 건너뛴다. 닫는 데 후보가 필요 없기 때문이다. 대신 보류 행이 가진 `tasks` 를 지우지 않는다. 원장에 근거가 남는다.

이 방식이 검토에서 나온 질문에 답하는 방법:

- 해소 뒤 재보류 루프: 닫는 행이 `Unattributed` 라 `is_settled` 가 참이 된다. `Settled` 가 된 의무는 `open_payout = waiting` 이 거짓이어서 `write_candidates` 가 새 `Candidate_window_held` 를 쓰지 못한다. 별도 이벤트 뒤에 `Unattributed` 를 따로 쓰는 두 단계였다면 그 사이에 `prepare` 가 한 번 돌 수 있었다. 한 행으로 닫으므로 그 틈이 없다.
- 이벤트가 하나인가 둘인가: 하나다. `state`·`is_settled`·잔액 집계 같은 reader 는 이미 `Unattributed` 를 종결로 읽으므로 코드를 바꾸지 않는다. 바뀌는 곳은 `unattributed_reason` 의 변형을 매칭하는 곳이다(§5).
- 이전 reader: 새 이유 변형을 해석하지 못한다. goal-candle-ledger RFC 의 형식 변경 규칙(모든 writer 정지 후 reader/writer 동시 갱신)을 따른다.

진입점은 관리자 전용 명령 하나다. 모델 호출이나 지급 재시도를 하지 않는다.

## 4. 결정이 필요한 것

- 이미 일한 Keeper 가 받을 몫을 영구히 포기한다. 이 결정과 Candle 지급 정책(task-3289)의 관계는 운영자가 정한다. 이 RFC 는 닫는 길만 연다.
- 관리자 신원을 어디서 읽는지(기존 관리자 전용 명령이 쓰는 신원 확인 경로를 재사용한다고 가정한다). 구현 PR 전에 그 경로를 읽어 확정한다.

## 5. 구현 범위(작게)

- `candle_event.ml`: `unattributed_reason` 에 변형 하나, 직렬화·복원.
- `candle_payout.ml`: `validate_settlement_under` 의 보류 거절에 위 예외 하나, `Unattributed` 이유를 매칭하는 곳(468 근방의 `Unattributed u` 분기)에 새 변형 처리.
- 관리자 명령 한 곳과 시험.

## 6. 이 RFC 에서 뺀 것: `Order_ruled`

운영자가 Task 별 선후를 정해 지급을 이어 가는 길은 이 RFC 에서 다루지 않는다. 검토가 짚은 이유:

- 정한 값을 `Candidates` 로 만들어도 `prepare` 가 `observation_issues <> []` 이면 다시 `Held_window` 를 돌려주고, `validate_durable_candidates_internal`(399-406) 은 정산 때 `observation_issues` 가 비어야 한다고 본다. `decide_candidates` 도 `window_issues` 가 있으면 `Error` 를 돌려준다.
- 따라서 `Order_ruled` 에는 (a) `Candidates` 행이 운영자 판정 출처를 담는 방법, (b) 위 두 검사가 그 출처를 건너뛰는 방법, (c) `Recorded_rules` 재생에서 같은 행이 계속 읽히는 방법이 모두 필요하다. 비용이 크다.
- `Same_second` 는 `{task_id; boundary}` 쌍마다 생기고(Goal_created / Human_confirmed 두 경계), `Reversed_window` 는 Task 선후가 아니라 Goal 시각의 모순이라 `Order_ruled` 로 풀 수 없다.

필요해지면 별도 RFC 로 한다.

## 7. 검증 계획

- 단위: 맞는 보류에만 `Held_window_closed` 가 통과하고, 다른 Goal·다른 `held_at`·보류 없음·빈 `operator`/`reason` 은 거절된다.
- 단위: 닫은 뒤 `is_settled` 가 참이고 `state` 는 `Settled`, 같은 의무에 `write_candidates` 가 새 보류를 쓰지 않는다(재보류 루프 없음).
- 단위: `Held_window_closed` 가 없는 기존 원장 행의 재생이 달라지지 않는다.
- 운영: a46df693 이 `Unattributed` 로 끝난 원장 줄을 #49172 에 남긴다. 이 항목은 구현 병합과 운영자 실행이 모두 끝나야 채워진다. 운영자가 닫기가 아니라 지급을 원하면 `Order_ruled` 별도 RFC 가 먼저다.
