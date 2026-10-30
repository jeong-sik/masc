# Keeper config failure health 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T19:32:17+09:00`
- 작성자: `Codex`
- 결정 ID: `keeper-config-health-linux-r1`
- 적용 대상: Keeper registry failure reason과 fleet health
- 결정 상태: `추적 필요`

## 근거

- 항목: 모든 target keeper가 operator-only config error를 반복하면 live fiber가
  있어도 fleet health를 `blocked`로 표시해야 한다.
- 출처: exact-head Linux restart health/logs와 focused OCaml tests
- 확인일시: `2026-08-30T19:32:17+09:00`
- 신뢰도: `High`
- 제한조건: one-click classic preset의 missing provider credential로 측정했다.
- Delta: typed config root cause를 registry에 보존하고 fleet capacity와 별도로
  operator blocker를 투영한다.

## 검증

- 1차: baseline은 failing/recovering 4, executable 4인데도 overall/fleet `ok`였다.
- 2차: typed reason, health projection, status bridge, heartbeat overwrite focused
  tests가 통과했다.
- 3차: fixed exact-source Linux restart에서 네 번 연속 overall/fleet `blocked`,
  config-blocked 4, operator action true를 확인했다.
- 재현 결과: 성공. executable fiber 수는 4로 유지해 lifecycle 사실도 숨기지
  않았다.

## 불확실성

- 미확인 항목: 여러 provider failure class가 섞인 실제 production fleet.
- 영향: partial fleet은 pure projection test로만 `degraded`를 확인했다.
- 추가 확인 필요: Draft PR CI와 review bot 결과를 확인한다.

## 적용범위

- 영향 받는 영역: Agent Core config failure registry record, post-turn heartbeat,
  Keeper fleet health JSON.
- 제약/배제: provider retry, keeper stop/pause, one-click entrypoint, deployed 8935
  runtime은 바꾸지 않았다.
- 롤백 조건: transient failure가 config blocker로 오분류되거나 typed config reason이
  generic turn count로 다시 덮이면 롤백한다.
