# Dashboard nested executor cache 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T16:48:37+09:00`
- 작성자: `Codex`
- 결정 ID: `dashboard-nested-executor-cache-linux-r1`
- 적용 대상: dashboard offload worker 내부의 nested cache compute
- 결정 상태: `추적 필요`

## 근거

- 항목: shared executor worker에서 시작한 dashboard 계산은 nested
  `Dashboard_cache` miss를 같은 pool에 다시 submit하지 않아야 한다.
- 출처: exact Git-context Linux image, container `build-commit`,
  `/health?full=1`, `sha256sum`, baseline/fixed execution response, 실제 restart,
  startup refresh 동시 실행 로그
- 확인일시: `2026-08-30T16:48:37+09:00`
- 신뢰도: `High`
- 제한조건: 2-domain Docker one-click runtime, JSONL backend, Local sandbox
  Keeper 1개에서 측정했다.
- Delta: executor worker context를 DLS로 표시하고 실제 dashboard offload를
  `Executor_pool_ref.submit_or_inline` facade로 통일했다.

## 검증

- 1차: first patch만 포함한 r8은 안정화 뒤에도 execution이 30.0322초,
  Keeper/continuity 0건이었다.
- 2차: 실제 `run_dashboard_compute` 조합을 고정한 회귀 테스트를 포함해 focused
  test 65개가 통과했다.
- 3차: fixed r10의 fresh cold, restart cold, startup-refresh 동시 cold 요청이
  각각 8.982ms, 199.545ms, 7.036ms였고 모두 Keeper/continuity 1건이었다.
- 재현 결과: 성공. real restart 뒤 61.6초 로그에도 30초 timeout signature가
  다시 나타나지 않았다.

## 불확실성

- 미확인 항목: remote PostgreSQL backend, 2개보다 많은 동시 cold actor 요청,
  long-running provider turn과 겹친 dashboard compute.
- 영향: 다른 worker-blocking producer가 있으면 pool queue latency가 다시 생길 수
  있다.
- 추가 확인 필요: PostgreSQL runtime과 multi-actor cold-cache burst를 별도
  측정한다.

## 적용범위

- 영향 받는 영역: `Executor_pool_ref.submit_or_inline`,
  `Server_dashboard_http_runtime_support.run_dashboard_compute`, nested dashboard
  cache compute.
- 제약/배제: cache schema/TTL, operator snapshot payload, Local Keeper lifecycle,
  #31934 periodic janitor, #31156 managed assets, deployed
  `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: offloaded compute가 caller domain에 남거나, nested compute가 30초
  timeout되거나, Eio cancellation/exception fallback 계약이 깨지면 롤백한다.
