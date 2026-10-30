# One-click periodic Docker janitor 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T17:02:51+09:00`
- 작성자: `Codex`
- 결정 ID: `oneclick-periodic-docker-janitor-linux-r1`
- 적용 대상: periodic Keeper Docker sandbox cleanup capability gate
- 결정 상태: `추적 필요`

## 근거

- 항목: Docker CLI가 배포되지 않은 server의 periodic janitor는 process를 spawn하지
  않고 typed skip을 interval-throttled하게 기록해야 한다.
- 출처: exact Git-context Linux image, container `build-commit`,
  `/health?full=1`, `sha256sum`, baseline/fixed timestamped logs, 실제 restart
- 확인일시: `2026-08-30T17:02:51+09:00`
- 신뢰도: `High`
- 제한조건: Docker CLI 없는 Linux/arm64 one-click image에서 janitor tick을 1초로,
  cleanup interval을 10초로 가속했다.
- Delta: interval winner가 injected executable capability를 확인하고
  `Cleanup_skipped_command_unavailable`을 반환한다.

## 검증

- 1차: baseline r10은 one-click에서 `docker ps` missing-executable 오류와 cleanup
  error를 같은 tick에 기록했다.
- 2차: focused build와 Docker cleanup test 8/8이 통과했고 unavailable fake CLI는
  spawn 0회였다.
- 3차: fixed r11 fresh boot와 실제 restart에서 explicit skip 2회/3회, spawn error
  0건을 확인했다.
- 재현 결과: 성공. process restart로 gate가 초기화된 뒤에도 오류 spawn 없이 같은
  typed skip 계약을 유지했다.

## 불확실성

- 미확인 항목: executable은 있지만 daemon socket 권한이 없는 host, 실제 stale
  Docker container가 있는 host의 removal.
- 영향: 해당 deployment는 command availability를 통과한 뒤 기존 explicit error
  또는 removal 경로를 사용한다.
- 추가 확인 필요: Docker-enabled fixture에서 periodic stale removal을 별도로
  측정한다.

## 적용범위

- 영향 받는 영역: `Keeper_sandbox_runtime.maybe_cleanup_stale_containers`와
  `Server_bootstrap_maintenance` periodic caller.
- 제약/배제: Docker Keeper execution/preflight, manual cleanup result, cleanup TTL,
  #31156 managed assets, deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: Docker-enabled caller가 cleanup을 건너뛰거나, unavailable command가
  spawn되거나, typed skip이 interval gate를 소비하지 않으면 롤백한다.
