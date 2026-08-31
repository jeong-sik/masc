# Keeper purge declared-sandbox teardown 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T15:43:14+09:00`
- 작성자: `Codex`
- 결정 ID: `keeper-purge-profile-teardown-linux-r1`
- 적용 대상: shutdown finalization의 Keeper sandbox teardown 선택
- 결정 상태: `추적 필요`

## 근거

- 항목: Keeper를 제거할 때 선언된 typed sandbox backend만 정리해야 한다.
  Local과 Remote SSH는 local container CLI를 호출하지 않아야 한다.
- 출처: exact Git-context Linux image, binary `build-commit`, `/health?full=1`,
  `sha256sum`, Keeper down/status, dashboard purge, operation JSON, path probe,
  timestamped server log
- 확인일시: `2026-08-30T15:43:14+09:00`
- 신뢰도: `High`
- 제한조건: 128자 ASCII Keeper와 Local sandbox profile에서 측정했다.
- Delta: exact owner meta의 sandbox profile을 typed backend로 바꾸어 finalizer에
  전달하고, backend별 teardown을 하나만 선택한다.

## 검증

- 1차: 기존 구현이 microVM과 Docker teardown을 모두 호출하는 것을 source와
  baseline #31927 로그로 확인했다.
- 2차: OCaml focused build, teardown test 2/2, dashboard purge test 1/1이
  통과했다.
- 3차: fixed Linux image에서 같은 process의 Local stop→purge가 finalized됐고,
  계획 경로 11곳이 absent, 두 로그 구간의 container/docker match가 각각
  0이었다.
- 재현 결과: 성공. Local cleanup은 지원하지 않는 container runtime을 호출하지
  않았다.

## 불확실성

- 미확인 항목: 실제 Docker persistent container와 microVM guest가 선언된
  backend에서 제거되는 Linux/macOS runtime proof.
- 영향: backend 분기나 identity projection이 틀리면 해당 sandbox resource가
  남을 수 있다.
- 추가 확인 필요: Docker와 microVM 각각에 소유 container를 만든 뒤 다른
  runtime을 건드리지 않고 자기 resource만 제거하는지 측정한다.

## 적용범위

- 영향 받는 영역: Keeper shutdown finalizer와
  `Keeper_turn_sandbox_runtime.teardown_keeper_sandbox_by_name`.
- 제약/배제: startup microVM sweep(#31931), dashboard continuity(#30209),
  container runtime 구현, deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: Local/Remote SSH cleanup이 container CLI를 호출하거나,
  Docker/microVM cleanup이 선언되지 않은 runtime을 호출하거나, 선언된
  resource를 남기면 롤백한다.
