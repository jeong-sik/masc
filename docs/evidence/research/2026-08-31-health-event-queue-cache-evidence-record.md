# Health event-queue cache 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-31T00:39:51+09:00`
- 작성자: `Codex`
- 결정 ID: `health-event-queue-cache-linux-r1`
- 적용 대상: durable Keeper event queue and cached full-health projection
- 결정 상태: `추적 필요`

## 근거

- 항목: durable event-queue snapshot/WAL commit 뒤 full health는 old ready queue/ledger facts를
  재사용하면 안 된다.
- 출처: exact-source Linux official operator cancel snapshots, BuildKit identity, focused tests
- 확인일시: `2026-08-31T00:39:51+09:00`
- 신뢰도: `High`
- 제한조건: isolated one-server Linux/arm64 container와 orphan queue cancel을 실측했다.
- Delta: persistence commit observer가 server full-health invalidation/wake에 연결된다.

## 검증

- 1차: source audit에서 persistence commit에 process-wide health observer가 없음을 확인했다.
- 2차: pre-fix r49 applied cancel 10ms 뒤에도 old pending count 3을 유지했다.
- 3차: fresh WAL-aware snapshot은 pending count 2를 계산했다.
- 4차: post-fix r50 applied cancel 8ms 뒤 warming/refresh-requested/in-flight를 반환했다.
- 5차: event-driven ready snapshot은 pending 1, outbox 0, reaction count 2를 계산했다.
- 6차: focused tests는 snapshot/WAL commit exactly-once, no-op/replay suppression,
  observer failure isolation을 확인했다.
- 재현 결과: 성공. durable queue commit을 숨기던 false-ready window를 제거했다.

## 불확실성

- 미확인 항목: multi-server process와 queue mutation burst 중 wake coalescing의 장시간 부하,
  Draft PR CI/review.
- 영향: process-global observer와 unbounded wake stream은 one-server process에서 검증됐다.
- 추가 확인 필요: Draft PR checks/review와 #31977 → #31979 → #31981 merge 순서를 유지한다.

## 적용범위

- 영향 받는 영역: event queue snapshot save, transition WAL fsync, outbox retirement,
  cached full-health queue/ledger projection.
- 제약/배제: queue authority, transition admission, reaction projection policy, TTL은 바꾸지 않는다.
- 롤백 조건: committed queue mutation 뒤 old ready facts가 재출현하거나 observer failure가
  committed result를 실패로 relabel하면 롤백한다.

