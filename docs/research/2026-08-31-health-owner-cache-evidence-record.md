# Health Keeper Owner cache 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-31T01:07:10+09:00`
- 작성자: `Codex`
- 결정 ID: `health-owner-cache-linux-r1`
- 적용 대상: Keeper Owner health projections and cached full-health response
- 결정 상태: `추적 필요`

## 근거

- 항목: health-visible Owner projection mutation 뒤 full health는 이전 ready owner facts를 재사용하면
  안 된다.
- 출처: exact-source Linux authenticated `masc_keeper_msg` snapshots, image/binary identity,
  focused Owner tests
- 확인일시: `2026-08-31T01:07:10+09:00`
- 신뢰도: `High`
- 제한조건: isolated one-server Linux/arm64 container와 direct backend operation을 실측했다.
- Delta: Keeper Owner state-change observer가 server full-health invalidation/wake에 연결된다.

## 검증

- 1차: source audit에서 operation/turn/shutdown Atomics와 full-health 사이 observer가 없음을 확인했다.
- 2차: pre-fix accepted operation 4ms 뒤에도 14,351ms old ready owner count 0을 유지했다.
- 3차: fresh snapshot은 terminal count 1을 계산했다.
- 4차: post-fix accepted response 6.9ms 뒤 current-ready snapshot은 running count 1과 active chat
  turn을 계산했다.
- 5차: terminal mutation 뒤 별도 event-driven snapshot은 running/in-flight 0, terminal count 2를
  계산했다.
- 6차: focused tests는 mutation notification, no-op/replay suppression, observer failure isolation을
  확인했다.
- 재현 결과: 성공. Keeper Owner mutation을 숨기던 false-ready window를 제거했다.

## 불확실성

- 미확인 항목: multi-server process, Owner mutation burst 중 wake coalescing의 장시간 부하,
  Draft PR CI/review.
- 영향: process-global observer와 current-ready refresh는 one-server process에서 검증됐다.
- 추가 확인 필요: Draft PR checks/review와 #31977 → #31979 → #31981 → #31984 merge 순서를
  유지한다.

## 적용범위

- 영향 받는 영역: queued/running/terminal/store-unavailable operation projection, turn-in-flight,
  shutdown reservation, cached full-health Owner projection.
- 제약/배제: Owner admission/order, operation persistence, turn scheduling, shutdown authority, TTL은
  바꾸지 않는다.
- 롤백 조건: successful Owner mutation 뒤 old ready facts가 재출현하거나 observer failure가 Owner
  결과를 실패로 relabel하면 롤백한다.

