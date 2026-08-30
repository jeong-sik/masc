# One-click OTLP background startup 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T17:42:29+09:00`
- 작성자: `Codex`
- 결정 ID: `oneclick-otel-background-startup-linux-r1`
- 적용 대상: server OTLP exporter setup과 background maintenance wiring
- 결정 상태: `추적 필요`

## 근거

- 항목: collector 부재 시 OTLP retry/recovery는 유지하되 listener와 maintenance
  wiring은 동기 retry를 기다리지 않아야 한다.
- 출처: exact Git-context Linux image, container `build-commit`,
  `/health?full=1`, binary hash, fresh/restart OTLP와 dashboard timestamp logs
- 확인일시: `2026-08-30T17:42:29+09:00`
- 신뢰도: `High`
- 제한조건: OTLP collector가 없는 Linux/arm64 one-click image에서 측정했다.
- Delta: exporter setup을 server root switch 아래의 logged fiber로 fork한다.

## 검증

- 1차: baseline r14 fresh/restart에서 5회 retry 완료 뒤에만 listener와 dashboard
  loop가 시작되는 것을 확인했다.
- 2차: bootstrap exact tests 24/25가 기존 soft-failure 계약과 새 non-blocking
  wiring 계약을 각각 통과했다.
- 3차: fixed r15 fresh/restart에서 dashboard loop가 listener 뒤 1ms 안에
  시작하면서도 5회 retry와 recovery 전환이 유지됨을 확인했다.
- 재현 결과: 성공. process restart 뒤에도 startup wiring이 retry를 기다리지
  않았고 health는 ready/ok로 수렴했다.

## 불확실성

- 미확인 항목: collector late-start 뒤 exporter active 복구와 실제 span export.
- 영향: recovery producer 내부의 network-success 경로 회귀는 이번 측정만으로
  배제할 수 없다.
- 추가 확인 필요: disposable collector를 늦게 시작해 active 전환과 span 수신을
  별도 측정한다.

## 적용범위

- 영향 받는 영역: `Server_bootstrap_maintenance`의 OTLP setup scheduling과
  focused test seam.
- 제약/배제: retry policy, recovery interval, exporter shutdown implementation,
  collector configuration, deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: retry/recovery가 사라지거나, setup fiber crash가 발생하거나,
  shutdown에서 exporter fiber가 남으면 롤백한다.
