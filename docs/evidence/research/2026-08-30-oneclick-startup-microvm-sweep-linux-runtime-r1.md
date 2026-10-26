# One-click startup microVM sweep Linux runtime R1

## 결과

server startup은 모든 배포에서 `microvm_guest_sweep`를 실행했다. one-click Linux
이미지에는 Apple `container` CLI가 없으므로 fresh boot마다 `container list -a`
spawn이 실패하고 error log가 남았다. 서버는 계속 뜨지만 실제 장애가 아닌 오류가
운영 로그에 섞였다.

microVM sweep 계약이 `Executable_path.command_available`로 CLI 존재를 먼저
확인하도록 바꿨다. CLI가 없으면 process를 spawn하지 않고 `None`을 반환한다.
startup은 이 값을 error가 아닌 명시적 skip log로 기록한다. CLI가 있으면 기존
owner-pid 기반 abandoned guest 선택과 제거를 그대로 실행한다.

## exact identity

- source change commit: `89b25b239e2fc499c5e31b7c5477deb0377cbf19`
- Linux measurement composition/embedded commit:
  `13223ffdece94ffa8c5b9f4373bd0617836204d5`
- Linux/arm64 image digest:
  `sha256:3b95bc2ddd034b27f5e03701de00fdb939a853fdefb16dd5e7f0fd7d07911f69`
- binary SHA-256:
  `c37c9e5f73ffd2a47e475f3dd3b205635c291e87a6467b401eb9538ca56e70e5`
- runtime instance:
  `01a05172-8060-7000-af0d-7b442289e8c3`
- effective base path: `/app`
- effective MASC root: `/app/.masc`

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
container `build-commit`, `/health` embedded commit, binary hash가 같은 source
head를 가리켰다.

## baseline

직전 composition image `131c61c6c05fcb9e135b06320ecd4a6bae4fdc4d`의
fresh r4 boot는 다음 error를 1건 남겼다.

```text
[ERROR] [Misc] [Process_eio] argv error: 'container' 'list' '-a' '--format' 'json' — Eio.Io Process Executable "container" not found
```

baseline image digest는
`sha256:ba224b7ceacdbadb91c7331d63e9e2b267e182d3a26495dab3f1e87434dec1f4`였다.

## fixed 실측

fresh named volume과 Keeper 0개로 r5를 시작했다. startup log 115줄에서 아래 skip
log는 1건, `container list`/missing executable error는 0건이었다.

```text
[INFO] [Misc] startup microvm sweep skipped: `container` CLI is not available on PATH
```

부팅 63초 뒤 `/health?full=1`은 `status=ok`, `overall_status=ok`, startup
`phase=ready`, `state_ready=true`, pending lazy task 0, `last_error=null`이었다.
server는 Keeper를 만들거나 provider turn을 실행하지 않았다.

## 검증

- `scripts/dune-local.sh build test/test_keeper_sandbox_microvm.exe test/test_server_runtime_bootstrap.exe`
- microVM suite 19/19
  - CLI absent이면 listing spawn 0회
  - CLI available이면 listing spawn 1회와 empty exact outcome
  - 기존 owner-liveness selection과 argv tests 포함
- startup plan focused test 1/1
- exact Linux/arm64 fresh one-click boot

## 남은 경계

Apple `container` CLI가 실제 있는 macOS host에서 abandoned guest를 제거하는 live
proof는 이번 R1에서 다시 측정하지 않았다. 기존 selection은 unit test로만
확인했다. `container`가 PATH에 있지만 daemon이 고장 난 경우는 기존처럼 실제
spawn 결과를 남긴다. 이는 CLI가 없는 배포와 다른 장애다. 성능 향상은 주장하지
않는다.

## 근거

- [근거] Git remote-context build log, image inspect, container `build-commit`,
  `/health?full=1`, binary `sha256sum`, baseline/fixed timestamped startup logs,
  2026-08-30T15:55:16+09:00 확인, 신뢰도 High.
