# Dashboard purge continuity cache Linux runtime R1

## 결과

dashboard execution은 lightweight operator snapshot의 Keeper row를 받아 live
meta에서 `diagnostic`을 다시 붙인다. lightweight row 자체는 health를 계산해
`status`를 만들지만 `diagnostic` 필드를 싣지 않는다.

dashboard purge가 meta를 지운 뒤 lifecycle listener는 기존 execution row만
patch했다. operator snapshot cache, 5초 projection cache, parameterized execution
cache는 남았다. refresh가 그 안의 stale Keeper row를 읽으면 meta enrich는
실패하고 원본 row가 남는다. continuity builder는 빈 health를 허용하지 않으므로
`unknown keeper health ""`로 전체 refresh가 실패했다.

listener가 dashboard POST lifecycle 경로와 같은
`refresh_keeper_execution_surfaces` facade를 호출하도록 바꿨다. lifecycle event를
받으면 operator snapshot, projection, 모든 execution/shell cache를 지운 뒤 현재
execution row를 patch한다.

## exact identity

- source change commit: `f7f32513a81e8a0bcfc0c177dc052d87353f7172`
- Linux measurement composition/embedded commit:
  `babdccc8556a98b2ed9f787b55664b5d36792cab`
- Linux/arm64 image digest:
  `sha256:0d9824a0e42539c4dedd9b32d59a66045eaad5f7d54ae9ddcbda3eb78df0c1de`
- binary SHA-256:
  `c54461bf4171c240b9b7f9de419c690c46f3cf573a77549e838a29bb0ea6d9a9`
- runtime instance:
  `01a05185-32e2-7000-89b1-b6f8fa6871cb`
- effective base path: `/app`
- effective MASC root: `/app/.masc`

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
container `build-commit`, `/health` embedded commit, binary hash가 같은 source
head를 가리켰다.

## baseline

직전 composition `131c61c6c05fcb9e135b06320ecd4a6bae4fdc4d`의 r4
dashboard purge는 HTTP 202와 finalized operation을 남겼지만 2.3초 뒤 한
continuity incident를 경고 2줄로 기록했다.

```text
dashboard offload failed, using inline compute: Invalid_argument("dashboard continuity: unknown keeper health \"\"")
execution refresh failed (1 consecutive, next in 60s, 0.0s): Invalid_argument("dashboard continuity: unknown keeper health \"\"")
```

baseline image digest는
`sha256:ba224b7ceacdbadb91c7331d63e9e2b267e182d3a26495dab3f1e87434dec1f4`였다.

## fixed 실측

fresh r7에서 Local Keeper를 만들고 `masc_keeper_down`을 finalized했다. purge 직전
actor-scoped lightweight snapshot을 일부러 prime했다. row count는 1,
`status=paused`, `diagnostic` field는 absent였다.

dashboard purge는 HTTP 202와 operation
`shutdown-14ec09c0-d291-4666-9116-7df0f75bf4e9`을 반환했다. operation은
`dashboard_keeper_purged` completion까지 delivered 상태로 finalized됐고 계획
경로 11곳은 모두 absent였다.

1초 뒤 같은 actor/query는 Keeper count 1→0을 반환했다. prime 응답은 16.59초,
purge 뒤 응답은 4ms였다. 새 execution cache key를 명시적으로 계산한 요청도 HTTP
200, `error=null`, Keeper count 0, continuity count 0이었다. purge 이후 70초와
명시적 refresh를 포함한 로그 18줄에서 continuity error와 execution refresh
failure는 각각 0건이었다. provider turn은 실행하지 않았다.

## 검증

- `scripts/dune-local.sh build test/test_server_runtime_bootstrap.exe`
- lifecycle refresh projection invalidation focused test 1/1
  - event 전 snapshot compute 1회
  - `Purged` event 뒤 같은 key compute 2회
- exact Linux/arm64 stopped Local Keeper snapshot-prime→purge→operator/execution
  refresh chain

## 남은 경계

one-click periodic janitor의 missing Docker CLI 오류는 #31934로 분리했다.
execution snapshot의 `tool_audit≈30s` timeout은 #8822를 reopen해 기록했다. fixed
execution 요청도 30.02초였으므로 이 PR은 latency 개선을 주장하지 않는다.
deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.

## 근거

- [근거] Git remote-context build log, image inspect, container `build-commit`,
  `/health?full=1`, binary `sha256sum`, operator snapshots, MCP down/status,
  dashboard purge response, operation JSON, execution response, path probes,
  timestamped server logs, 2026-08-30T16:19:05+09:00 확인, 신뢰도 High.
