# Dashboard purge continuity cache 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T16:19:05+09:00`
- 작성자: `Codex`
- 결정 ID: `dashboard-purge-continuity-cache-linux-r1`
- 적용 대상: Keeper lifecycle event의 dashboard projection cache 갱신
- 결정 상태: `추적 필요`

## 근거

- 항목: Keeper lifecycle event는 current execution row뿐 아니라 그 row를 다시
  만드는 operator/projection/parameterized cache도 함께 무효화해야 한다.
- 출처: exact Git-context Linux image, binary `build-commit`, `/health?full=1`,
  `sha256sum`, operator snapshot prime, down/purge operation, execution response,
  timestamped server logs
- 확인일시: `2026-08-30T16:19:05+09:00`
- 신뢰도: `High`
- 제한조건: Local sandbox Keeper와 dashboard purge completion event에서
  측정했다.
- Delta: lifecycle listener가 partial execution patch 대신 기존 full refresh
  facade를 호출한다.

## 검증

- 1차: baseline은 purge 2.3초 뒤 stale lightweight row의 빈 health로 continuity
  refresh가 실패했다.
- 2차: focused build와 event 전후 projection recompute test 1/1이 통과했다.
- 3차: fixed image에서 diagnostic 없는 row를 prime한 뒤 purge해 operator row가
  1→0, explicit execution이 200/error null/continuity 0, 관련 log error 0임을
  확인했다.
- 재현 결과: 성공. 제거된 Keeper row가 5초 cache에서 되살아나지 않았다.

## 불확실성

- 미확인 항목: 동시에 여러 lifecycle event가 들어오는 invalidation generation
  race와 remote PostgreSQL dashboard backend.
- 영향: generation ordering이 틀리면 늦은 pre-purge compute가 새 snapshot을
  덮을 수 있다.
- 추가 확인 필요: concurrent up/down/purge event burst와 offloaded PG 경로를
  별도 측정한다.

## 적용범위

- 영향 받는 영역: `Server_bootstrap_loops` lifecycle listener와 기존
  `Server_dashboard_http_keeper_api.refresh_keeper_execution_surfaces` facade.
- 제약/배제: continuity health parser의 fail-loud 계약, snapshot payload schema,
  #8822 latency, #31934 Docker janitor, deployed `/Users/dancer/me/.masc`는 바꾸지
  않았다.
- 롤백 조건: lifecycle event 뒤 projection key가 재계산되지 않거나, purged
  Keeper가 operator/execution row에 남거나, 이전 generation이 다시 publish되면
  롤백한다.
