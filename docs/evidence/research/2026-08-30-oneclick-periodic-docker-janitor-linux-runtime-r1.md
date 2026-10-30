# One-click periodic Docker janitor Linux runtime R1

## 결과

server periodic janitor는 deployment capability와 무관하게 stale Keeper Docker
container sweep를 호출했다. Docker CLI와 daemon socket이 없는 one-click image에서도
`docker ps`를 spawn해 1회당 ERROR/INFO/WARN 세 줄을 남겼다.

cleanup interval gate가 이긴 뒤 resolved Docker command의 실행 가능성을 검사하도록
바꿨다. CLI가 없으면 `Cleanup_skipped_command_unavailable` typed result를 반환하고
서버는 explicit INFO 한 줄을 남긴다. skip도 interval을 소비하므로 빠른 janitor
tick이 같은 경고를 반복하지 않는다. Docker execution caller는 availability probe를
주입하지 않아 기존 daemon/preflight 오류 계약을 그대로 유지한다.

## exact identity

- source change commit: `96b455059b53c6cde4b4c141d3278cad05f0df18`
- Linux measurement composition/embedded commit:
  `3d4ecacabc8e83d1adc8c228ed2d7b01af74bd44`
- Linux/arm64 image digest:
  `sha256:17f12382baeb2639761defa6d8bef877607533353eb26ca1dd7209b4f5eee943`
- binary SHA-256:
  `298d60ea192b479a22b9b2fb000b08666dee72efe30598fe1a408f9c64770233`
- first runtime instance: `01a051af-7e9a-7000-b86a-8fdbe63e66e4`
- restarted runtime instance: `01a051b0-41a7-7000-8864-f45cd2cf96a9`
- effective base path: `/app`
- effective MASC root: `/app/.masc`

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
container `build-commit`, `/health?full=1`, binary hash가 같은 source head를
가리켰다.

## baseline

직전 composition `37b1350888999c21676f8c83cd86ff9b14e0315a`의 exact-head
r10은 Docker CLI가 없는 상태에서 periodic tick마다 실제 `docker ps`를 spawn했다.

```text
[Process_eio] argv error: 'docker' 'ps' ... Executable "docker" not found
Sandbox cleanup: scanned=0 removed=0 already_absent=0 errors=1
Sandbox cleanup error: docker ps failed during keeper sandbox cleanup: ...
```

baseline image digest는
`sha256:d9f64f5878cb5b1f8383a8acfb19fedc2fdaa5aebcc6ae43af0005ce21ed324f`,
binary SHA-256은
`5d59b09adc179714a684c7e86f1075a233e8ea52496b5078781eea56cab3d980`였다.

## fixed 실측

fresh r11은 Docker CLI가 없는 동일 one-click deployment였다. 재현 시간을 줄이기
위해 `MASC_JANITOR_INTERVAL_SEC=1`,
`MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC=10`을 적용했다. 기능 분기는 같고 cleanup
gate의 최소 10초 계약은 유지됐다.

fresh boot 관찰 창에서 explicit skip은 2회, Docker spawn error는 0건이었다. 같은
container를 실제 restart해 process-local gate를 초기화했고 runtime instance가
`01a051af-...`에서 `01a051b0-...`로 바뀌었다. restart 관찰 창 54초에서도 explicit
skip은 3회, Docker spawn error는 0건이었다.

```text
Sandbox cleanup skipped: Docker CLI is not available on PATH (docker)
```

Keeper와 provider turn은 실행하지 않았다. container
`masc-periodic-janitor-fixed-r11`과 volume
`masc-periodic-janitor-fixed-r11-data`는 정지·보존했다.

## 검증

- `scripts/dune-local.sh build test/test_keeper_sandbox_read_backend.exe
  test/test_server_runtime_bootstrap.exe`
- Docker cleanup focused group 8/8
  - unavailable command에서 fake CLI spawn 0회
  - typed skip이 interval gate를 소비
  - 기존 stale removal, disappearance race, retry 계약 통과
- fresh Linux/arm64 boot와 같은 container의 실제 restart
- exact-head `build-commit`, health identity, binary hash, timestamped logs

## 남은 경계

Docker CLI는 있지만 daemon/socket이 unavailable한 deployment는 명시적 cleanup
error를 계속 반환한다. 이는 command 부재와 다른 운영 상태이며 이번 skip 대상이
아니다. `keeper_tool_search.toml` managed-asset drift는 #31156에 기록돼 있다.
deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.

## 근거

- [근거] Git remote-context build log, image inspect, container `build-commit`,
  `/health?full=1`, binary `sha256sum`, fresh/restart timestamped server logs,
  2026-08-30T17:02:51+09:00 확인, 신뢰도 High.
