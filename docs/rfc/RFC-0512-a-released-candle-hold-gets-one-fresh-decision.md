---
rfc: "0512"
title: "보류된 Candle 지급 창은 해제되고 한 번 다시 판정된다"
status: Draft
created: 2026-11-07
updated: 2026-11-07
author: sangsu
supersedes: []
superseded_by: null
related: ["goal-candle-ledger"]
---

# RFC-0512 — 보류된 Candle 지급 창은 해제되고 한 번 다시 판정된다

## 0. 요약

- Candle 원장에는 지급할 몫(`payout_owed`)이 열린 채 `Candidate_window_held` 행으로 보류된 Goal 이 있다(#49172, `a46df693`).
- 보류는 후보 창 시간 경계의 영구 모호성(`Same_second`, `Reversed_window`)에서 온다(#47219). 관측을 다시 읽어도 기록된 시계는 그대로라 같은 모호성이 재현된다.
- 그래서 지금의 drain 은 보류를 읽고 `Held_window` 만 돌려준다. 보류를 닫는 이벤트와 명령이 없어서, 들어가는 길만 있고 나오는 길이 없다.
- 이 RFC 는 두 가지를 넣는다.
  1. `Candidate_window_released` 행: 운영자가 이 보류를 더 이상 막는 것으로 보지 않기로 한 결정. 열린 보류와 같은 goal · request · verification_run 을 이름으로 대조해 받는다.
  2. 해제 뒤의 유일한 재판정: 다음 payout pass 가 후보 관측을 새로 읽는다. 모호성이 사라졌으면 지금의 Candidates → 감정 → 정산 경로가 그대로 돈다. 같은 영구 모호성이 재현되면 두 번째 보류를 쓰지 않고 `Unattributed { reason = "window_released" }` 로 닫는다.
- 새 상태 기계와 새 Gate 는 없다. 이벤트 한 종, 정산 이유 한 개, 그리고 각 읽는 곳의 규칙 하나가 늘어난다.

## 1. 지금

- 보류는 `Candle_candidates.write_candidates` 가 `window_issues` 에 `Same_second` 나 `Reversed_window` 를 관측하면 `Candidate_window_held` 행을 쓰면서 시작된다. 그 행은 그 순간의 완전한 Task 관측과 얼어 붙은 Keeper 분류를 보존한다.
- 한 번 보류되면 `Candle_payout.held_window_of` 가 계속 `Some` 을 돌려주고, `prepare` 는 재판정 없이 `Held_window` 만 돌려준다.
- 검증 규칙도 보류를 열어 둔 Goal 의 뒷행을 전부 거절한다(`Candle_payout.validate_under`):
  - 새 `Payout_owed`: "candidate window is held; a new payout obligation cannot replace it"
  - 새 `Candidates`/`Candidates_fenced`: "candidate window is held"
  - 정산(Paid · Unattributed · Payout_failed): "settlement requires resolving the retained candidate window"
- 보류를 닫는 이벤트는 코드에 없다. `a46df693` 의 지급은 원장에서 영구히 멈춰 있다(#49172).

## 2. 바꿈

### 2.1 `Candidate_window_released` 행

- 필드: `goal_id`, `request_id`, `verification_run_id` — 열린 보류의 식별과 정확히 같은 세 값. `kind` 는 `"candidate_window_released"` 다.
- 이 행이 기록하는 사실은 하나다: 운영자가 이 보류를 더 이상 지급의 장애물로 보지 않기로 결정했다. 보류 행은 지워지지 않고 그대로 남는다. 원장은 관측을 지우지 않는다.

### 2.2 해제 행의 입장 규칙

- `Candidate_window_released` 행은 다음일 때만 받는다.
  - 같은 식별의 지급이 `Waiting` 이고,
  - 그 지급에 열린 보류가 있다(`held_window_of` 가 `Some`).
- 그 외에는 거절한다: "candidate window release requires the held window of the current open payout".
- 두 번째 해제는 자연히 거절된다. 첫 해제 뒤로 `held_window_of` 는 `None` 을 돌려주기 때문이다.

### 2.3 `held_window_of` 는 해제를 잃지 않는다

- 같은 식별의 해제 행이 원장에 있으면 `held_window_of` 는 `None` 을 돌려준다.
- 1 절의 차단 규칙들은 전부 `Some`/`None` 에만 달려 있으므로, 이 한 곳의 규칙으로 새 의무 · 후보 · 정산의 차단이 함께 풀린다. 규칙을 두 번 쓰지 않는다.

### 2.4 해제 뒤의 재판정은 한 번

- `prepare` 는 보류가 없어진 지급을 기존 경로 그대로 다시 준비한다. Task 관측을 새로 읽는다.
- 새 관측이 깨끗하면 지금의 흐름이 그대로 돈다: `Candidates` → 감정 → Paid 또는 Unattributed.
- 새 관측이 같은 영구 모호성(`Same_second` · `Reversed_window`)을 재현하면 두 번째 보류를 쓰지 않는다. `write_candidates` 의 보류 분기는 해제된 지급에서 보류 행 대신 `Unattributed { reason = Window_released }` 를 쓴다.
- 새 정산 이유 `window_released` 가 말하는 사실: "보류 창이 해제됐고, 해제 뒤의 다시 읽기도 같은 모호성을 재현했으므로 아무도 지급될 수 없다." `no_candidates` 와 다르다. 후보가 없어서가 아니라, 창이 풀려도 경계를 정할 수 없어서다.
- 해제된 지급에 보류 행을 다시 쓰려는 시도는 `validate_hold` 이 거절한다: "released payout window cannot be held again".

### 2.5 정산 검증

- `Unattributed { reason = Window_released }` 는 durable Candidates 를 요구하지 않는다. 재판정이 Candidates 를 쓰지 못한 것이 이 이유의 내용이기 때문이다. 대신 이 지급의 해제 행이 먼저 있어야 한다.
- `validate_replay` 도 같은 규칙으로 과거의 해제 + `window_released` 원장을 다시 읽는다. 오늘의 적격 규칙으로 옛 후보 목록을 다시 판정하지 않는다(Recorded_rules, 기존 원칙 유지).
- 감정 기한 검증(`validate_due_date`)에서 `window_released` 는 `no_candidates` 와 같이 지각 판정과 무관하게 닫힌다. 감정이 돌지 않았으므로 기한 감정도 없다.

### 2.6 운영 명령

- `POST /api/v1/dashboard/goals/candle/hold/release`, CanAdmin. 본문은 `{ "goal_id": "..." }` 하나다.
- 서버는 원장을 읽고 그 goal 의 `Waiting` 지급과 열린 보류를 확인한 뒤, 해제 행을 원자적으로 덧붙인다(`Candle_ledger.update_once`, append 시 검증은 모든 행과 같은 규칙).
- 성공 뒤 `Candle_payout_worker.wake ()` 를 부른다. 다음 pass 가 기다리지 않고 재판정한다.
- 응답은 결과를 그대로 말한다: `released` · `not_waiting` · `not_held` · `unknown_goal` · `superseded`.

## 3. 무엇이 그대로인가

- 보류 행의 내용과 `validate_hold` 의 엄격함. 해제는 보류를 지우는 게 아니라 닫는 것이다.
- 해제 행이 없는 옛 원장은 지금과 정확히 같은 규칙으로 읽힌다. 읽기 규칙은 확장만 있고 느슨해짐이 없다.
- 지급 · 구매 · 장비 · 증여의 나머지 전부.

## 4. 시험

- 이벤트: `Candidate_window_released` 와 `window_released` 이유의 roundtrip.
- 검증: 해제 입장(열린 보류 필요) · 거절(보류 없음 · 지급 없음 · 이미 해제됨) · 해제 뒤 두 번째 보류 거절 · 해제 뒤 Candidates 허용 · `window_released` 정산 입장 · replay.
- candidates: 해제 뒤 모호성 재현 → `Unattributed { window_released }` 원장 줄, 해제 뒤 깨끗한 관측 → `Candidates`.
- 라우트: released · not_held · unknown_goal.
