---
rfc: "wake-signal-diet"
status: Draft
---

# RFC — 자율턴 wake 신호 다이어트 (Wake-signal diet)

- Status: Draft
- Created: 2026-10-06
- Scope: `lib/keeper/keeper_world_observation.ml`
  (`keeper_cycle_decision`), board wake 라우팅, schedule/claim 신호
- Non-scope: periodic tick 억제(§5에서 별도 논의), 게이트 신설

## 1. 동기 (측정)

2026-10-06 fleet 24h 실측 (autonomous_cycle 2372턴):

- `text_response` 스킵 411턴(17.3%), 중앙 10.4s. "할 일 없음"을 말하기
  위해 풀컨텍스트 LLM 호출을 쓰는 구조다.
- 깨움 재료는 상시 포화: board chatter 1100+건/일(댓글 635+포스트 471),
  미클레임 Task ~480건 상시. `claimable_task` 트리거는 항상 켜져 있어
  신호가 아니다.
- 스킵 본문 표본: "관심 밖 스레드라 조치 없음", "다음 due까지 대기" —
  정당한 판정이지만 스케줄러가 아니라 모델이 내리고 있다.

## 2. 현재 설계 (고장이 아님)

- periodic tick은 무조건 `Run`이다
  (`keeper_world_observation.ml`: "fixed local thresholds never suppress
  a Keeper cycle"). 스킵 판단은 모델의 몫이라는 명시적 설계 철학이다.
- `Attention_wake` 단독은 이미 `Skip(No_periodic_or_scheduled_stimulus)`로
  처리된다. 즉 wake *지연/무시*의 typed 선례는 있다.

## 3. 제안 (억제가 아니라 다이어트)

tick을 막지 않는다. wake 신호의 질을 올려 모델이 "내 것 아님"을
판정하는 횟수를 줄인다.

1. **claimable 신호의 변화 조건.** ~480 상시인 raw count 대신,
   keeper별 claimable 집합의 *변화*(신규/해제, typed cursor)를 신호로
   쓴다. 변함없으면 신호 없음. 숫자로 게이트하지 않고 집합 identity로
   판단한다.
2. **board wake의 관심 매칭.** `matched_targets`/`explicit_mention`
   (이미 계산됨)과 keeper `board_interests`가 겹치지 않는 board
   이벤트는 즉시 reactive wake 대신 다음 periodic tick으로 합친다
   (coalesce). 지연이지 suppression이 아니다: 정보 손실 없음.
3. **due 대기의 명시화.** "다음 due까지 대기"형 keeper는 schedule wake에
  만 반응하고 중간 tick의 board 노이즈에 깨지 않도록, 관심 밖 wake를
   2와 같이 합친다.

## 4. 헌법 정합

- `budget_gate`: 누적 턴/시간/토큰 게이트를 만들지 않는다. 제안은 전부
  typed 상태(집합 변화, 관심 매칭, due 도달) 기반이다.
- `magic_number`: "관심도 점수" 같은 가중치 비교를 쓰지 않는다.
  매칭은 exact set overlap이다.
- `string_matching`: 판단은 typed variant와 집합 연산으로만 한다.

## 5. 의도적으로 제안하지 않는 것 (대안 기록)

Periodic tick 자체에 typed Skip 조건(zero actionable signals)을 다는
안은 §2의 설계 철학과 정면 충돌한다. 본 RFC는 제안하지 않는다.
§3으로 스킵률이 안 떨어지면 별도 RFC + 운영자 승인으로 다룬다.

## 6. 측정

- 성공 지표: keeper별 스킵률(text_response/autonomous), wake→turn
  전환율. 소스: `keeper.practice.v1`(#41292).
- 선행 조건: §3.1의 cursor 영속 위치 결정 (event-queue vs meta).
