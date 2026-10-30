# Keeper purge declared-sandbox teardown Linux runtime R1

## 결과

shutdown finalization은 이전까지 Keeper의 sandbox profile과 무관하게 microVM과
Docker teardown을 모두 호출했다. Local Keeper를 one-click Linux 컨테이너에서
정리하면 이미지에 없는 `container`와 `docker` CLI를 호출했고, purge는 끝났지만
`keeper removed but its sandbox container was not` 경고를 남겼다.

finalizer가 제거 전 exact owner meta에서 typed sandbox backend를 보존하도록
바꿨다. Local과 Remote SSH는 local container를 정리하지 않는다. Docker는
persistent Docker container만, microVM은 guest container만 정리한다.

## exact identity

- source change commit: `ae86eb9aa48bbf171c831cea8f8cf6991d8ca026`
- Linux measurement composition/embedded commit:
  `131c61c6c05fcb9e135b06320ecd4a6bae4fdc4d`
- Linux/arm64 image digest:
  `sha256:ba224b7ceacdbadb91c7331d63e9e2b267e182d3a26495dab3f1e87434dec1f4`
- binary SHA-256:
  `e93ae84ebf7e87aeea1c49a6c02208f4695d08966204803c77fb2a4d1e1f479f`
- runtime instance:
  `01a05163-2e92-7000-9209-a1e7a8967f10`
- effective base path: `/app`
- effective MASC root: `/app/.masc`
- Keeper name length: 128
- sandbox profile: `local`

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
container `build-commit`, `/health` embedded commit, binary hash가 같은 source
head를 가리켰다.

## 실측

fresh named volume에서 128자 Local Keeper를 만들었다. 측정 준비 중 첫 요청은
TOML에 `sandbox_profile`이 없어 거절됐고, 두 번째 요청은 보조 스크립트가 없는
`ollama.qwen3-8b` runtime을 지정해 거절됐다. current-format Local TOML을 넣고
모델 선택을 요청에서 빼자 같은 이름의 Keeper가 정상 생성됐다. 이 두 거절은
측정 시작 시각 전이며, provider turn은 실행하지 않았다.

`masc_keeper_down`은 operation
`shutdown-d004be9e-afd1-4b6d-b872-61800831115f`를 반환했다. 1초 뒤 status는
`shutdown_operation_phase=finalized`, `keepalive_running=false`,
`sandbox_profile=local`이었다. down 구간 서버 로그 15줄에서 container/docker
CLI와 sandbox cleanup warning match는 0이었다.

같은 process에서 dashboard purge는 HTTP 202와 operation
`shutdown-d781295f-99f7-4ab2-af6a-e1320afeda17`을 반환했다. operation은
`completion=dashboard_keeper_purged`까지 delivered 상태로 finalized됐다. core,
memory, TOML, Local/Docker/microVM playground, chat store를 포함한 계획 경로
11곳은 모두 absent였다. purge 구간 서버 로그 8줄에서 container/docker CLI와
sandbox cleanup warning match는 0이었다. purge 전후 runtime instance도 같았다.

## 검증

- `scripts/dune-local.sh build test/test_keeper_microvm_teardown_on_shutdown.exe test/test_heartbeat_integration.exe`
- teardown focused tests 2/2:
  - 시작하지 않은 microVM guest 제거
  - Local teardown이 container runtime을 호출하지 않음
- dashboard purge focused integration test 1/1
- exact Linux/arm64 same-process Local down→purge runtime chain

## 남은 경계

one-click startup의 `microvm_guest_sweep`는 Keeper 생성 전에도 없는 `container`
CLI를 호출한다. 이 경로는 #31931로 분리했다. purge 뒤 dashboard continuity가
`unknown keeper health ""`로 실패한 live 증상은 #30209를 reopen해 기록했다.
둘 다 이번 teardown 결과와 별개다. Docker와 microVM Keeper의 실제 container
제거는 이번 R1에서 새로 측정하지 않았다. 성능 향상은 주장하지 않는다.

## 근거

- [근거] Git remote-context build log, image/container inspect, container
  `build-commit`, `/health?full=1`, binary `sha256sum`, MCP down/status, dashboard
  purge response, shutdown operation record, planned path probes, timestamped server
  logs, 2026-08-30T15:43:14+09:00 확인, 신뢰도 High.
