# Health reaction-ledger cache 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-31T01:22:15+09:00`
- 작성자: `Codex`
- 결정 ID: `health-reaction-ledger-cache-linux-r1`
- 적용 대상: direct Keeper reaction-ledger appends and cached full-health response
- 결정 상태: `추적 필요`

## 근거

- 항목: direct reaction-ledger append 뒤 full health는 post-append refresh 기회를 가져야 한다.
- 출처: source commit ordering, exact-source Linux scheduled wake, image/binary identity, focused tests
- 확인일시: `2026-08-31T01:22:15+09:00`
- 신뢰도: `High`
- 제한조건: isolated one-server Linux/arm64 container와 disabled Keeper scheduled wake를 실측했다.
- Delta: direct stimulus/turn-start ledger append observer가 full-health invalidation/wake에 연결된다.

## 검증

- 1차: source audit에서 queue commit observer가 ledger append보다 먼저 실행됨을 확인했다.
- 2차: pre-fix r55에서는 queue-triggered refresh가 append 뒤를 읽어 stale이 발현되지 않았다.
- 3차: r55의 negative result를 stale 재현으로 사용하지 않았다.
- 4차: post-fix r56 immediate ready는 새 row를 포함했고 동시에 post-append 후속 refresh가
  in-flight였다.
- 5차: 후속 refresh는 별도 computed timestamp로 idle-ready에 수렴했다.
- 6차: focused tests는 success notification, append-failure suppression, observer-failure isolation을
  확인했다.
- 재현 결과: ordering hardening 성공. pre-fix stale runtime 재현은 없음.

## 불확실성

- 미확인 항목: 자연 부하에서 두 commit 사이 stale race의 발생률, multi-server process,
  ledger mutation burst 중 wake coalescing, Draft PR CI/review.
- 영향: post-append refresh chain은 one-server process에서 검증됐다.
- 추가 확인 필요: 장시간 부하 실측과 Draft PR checks/review, #31977 → #31979 → #31981 →
  #31984 → #31987 merge 순서를 유지한다.

## 적용범위

- 영향 받는 영역: direct event-queue stimulus row, direct turn-start reaction row, cached full-health
  reaction-ledger projection.
- 제약/배제: queue authority, ledger schema, transition-outbox projection, schedule dispatch, TTL은
  바꾸지 않는다.
- 롤백 조건: append 실패가 refresh를 유발하거나 observer failure가 persisted row를 실패로
  relabel하거나 mutation burst가 지속적인 refresh starvation을 만들면 롤백한다.

