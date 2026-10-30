# One-click startup microVM sweep 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T15:55:16+09:00`
- 작성자: `Codex`
- 결정 ID: `oneclick-startup-microvm-sweep-linux-r1`
- 적용 대상: startup abandoned microVM guest sweep
- 결정 상태: `추적 필요`

## 근거

- 항목: microVM CLI가 없는 배포는 startup guest listing을 spawn하지 않아야 한다.
  skip은 error가 아닌 명시적 사실로 남겨야 한다.
- 출처: exact Git-context Linux image, binary `build-commit`, `/health?full=1`,
  `sha256sum`, baseline/fixed timestamped startup logs
- 확인일시: `2026-08-30T15:55:16+09:00`
- 신뢰도: `High`
- 제한조건: Apple `container` CLI가 없는 Linux/arm64 one-click image에서
  측정했다.
- Delta: shell-free executable lookup 결과가 false이면 sweep process를 spawn하지
  않고 `None`을 반환하며 startup이 skip log를 기록한다.

## 검증

- 1차: baseline fresh boot에서 `container list -a --format json` missing
  executable error 1건을 확인했다.
- 2차: focused build, microVM suite 19/19, startup plan test 1/1이 통과했다.
- 3차: fixed fresh boot에서 skip log 1건, container CLI error 0건,
  `/health` startup ready와 overall ok를 확인했다.
- 재현 결과: 성공. CLI가 없는 배포는 microVM listing을 spawn하지 않았다.

## 불확실성

- 미확인 항목: CLI가 있는 macOS host의 실제 abandoned guest deletion.
- 영향: available 분기의 wiring이 깨지면 죽은 server가 남긴 guest를 회수하지
  못할 수 있다.
- 추가 확인 필요: owner PID가 죽은 tagged guest 하나를 만든 뒤 macOS fresh
  server boot가 정확히 그 guest만 제거하는지 다시 측정한다.

## 적용범위

- 영향 받는 영역: `Keeper_sandbox_microvm.sweep_abandoned_guests`와
  `Server_runtime_startup_maintenance.startup_sweep_microvm_guests`.
- 제약/배제: Keeper shutdown/purge(#31932), Docker cleanup, microVM daemon
  장애, deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: CLI absent에서 spawn이 일어나거나, CLI available에서 sweep를
  건너뛰거나, startup이 skip을 error로 기록하면 롤백한다.
