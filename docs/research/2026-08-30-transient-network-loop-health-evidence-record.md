# Keeper transient network loop health 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T20:24:48+09:00`
- 작성자: `Codex`
- 결정 ID: `transient-network-loop-health-linux-r1`
- 적용 대상: transient transport failure accounting과 Keeper fleet health
- 결정 상태: `추적 필요`

## 근거

- 항목: network/timeout failure의 crash-accounting 면제는 bounded여야 하며, bound 이후
  failing Keeper가 실행 가능하더라도 fleet health는 `ok`가 아니어야 한다.
- 출처: exact-head network-none Linux loop/restart와 focused OCaml tests
- 확인일시: `2026-08-30T20:24:48+09:00`
- 신뢰도: `High`
- 제한조건: one-click classic preset과 5초 측정 cadence의 persistent DNS failure다.
- Delta: Keeper별 transient transport 면제를 3회로 제한하고, 일반 recovering failure를
  fleet `degraded / turn_failure_recovering`으로 투영한다.

## 검증

- 1차: baseline은 59초에 44회 실패하면서 44/44 `consecutive=0`, health `ok`였다.
- 2차: failure accounting 11/11, recovering-health pure case 1/1, 기존 config-health
  case 1/1이 통과했다.
- 3차: fixed 최초 기동은 12회만 면제하고 60회를 nonzero counter로 기록했으며 health가
  `degraded`였다. 실제 재시작도 12회만 면제하고 28회를 nonzero로 기록했다.
- 재현 결과: 성공. 두 runtime instance 모두 lifecycle/executable 4를 유지하면서
  `turn_failure_recovering`을 투영했고 operator action은 false였다.

## 불확실성

- 미확인 항목: 실제 network recovery 뒤 success가 budget과 fleet phase를 reset하는
  end-to-end Linux 경로.
- 영향: success reset은 focused test로만 검증했다.
- 추가 확인 필요: stacked Draft PR CI와 review bot 결과를 확인한다.

## 적용범위

- 영향 받는 영역: failure accounting, success reset, fleet health status/blocker.
- 제약/배제: Keeper lifecycle을 중단하지 않고 retry cadence를 바꾸지 않으며 operator
  action을 요구하지 않는다. receipt label은 #31959에서 별도로 처리한다.
- 롤백 조건: 짧은 transient blip이 첫 3회 안에 durable failure로 집계되거나 success
  뒤 budget이 reset되지 않으면 롤백한다.
