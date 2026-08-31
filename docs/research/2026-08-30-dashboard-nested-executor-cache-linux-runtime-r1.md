# Dashboard nested executor cache Linux runtime R1

## 결과

dashboard execution의 바깥 계산은 shared `Eio.Executor_pool` worker에서 실행된다.
그 안의 operator snapshot이 `Dashboard_cache` miss를 만나면 같은 pool에 다시
submit했다. Docker one-click runtime은 worker가 2개라 startup refresh와 요청이
겹치면 worker가 자기 pool의 빈 자리를 기다렸고, 30초 timeout 뒤 Keeper row를
0건으로 반환했다.

`Executor_pool_ref.submit_or_inline`이 worker context에서는 중첩 작업을 inline으로
실행하도록 만들고, 실제 `run_dashboard_compute`도 raw `submit_exn` 대신 그 facade를
사용하도록 바꿨다. 첫 수정만 들어간 r8은 바깥 raw submit이 worker 표식을 만들지
않아 여전히 30초였다. 두 번째 수정이 실제 producer 경로를 연결한다.

## exact identity

- source change head: `861f549d32f0c283cccf1f07a1dedb4c352808d9`
- worker-context guard commit: `f3f9c26d59d36be3b64194217a9a1de7c6f3808c`
- dashboard offload facade commit: `861f549d32f0c283cccf1f07a1dedb4c352808d9`
- Linux measurement composition/embedded commit:
  `37b1350888999c21676f8c83cd86ff9b14e0315a`
- Linux/arm64 image digest:
  `sha256:d9f64f5878cb5b1f8383a8acfb19fedc2fdaa5aebcc6ae43af0005ce21ed324f`
- binary SHA-256:
  `5d59b09adc179714a684c7e86f1075a233e8ea52496b5078781eea56cab3d980`
- first runtime instance: `01a051a1-30a4-7000-8543-ab4f02798db0`
- restarted runtime instance: `01a051a2-4bf0-7000-a608-6a5d9dcc2a1e`
- effective base path: `/app`
- effective MASC root: `/app/.masc`

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
container `build-commit`, `/health?full=1`, binary hash가 같은 source head를
가리켰다. commit이 빠진 local-context r9 이미지는 측정 전에 중단했다.

## baseline

첫 수정만 포함한 composition `126f720e0cc7b11cf4efd2c57d2da23096ec2ddb`의
r8은 parameterized execution을 두 번 측정해 각각 30.3497초와 30.0322초였다.
둘 다 HTTP 200이었지만 Keeper 0건, continuity 0건을 반환했다. 두 번째 요청은
startup 직후가 아닌 안정화 뒤에도 `snapshot:/app/.masc:admin` compute가 30초
timeout됐다.

baseline image digest는
`sha256:e2374c7edbe551dc03b0b5146008c466d61033321f80f5f6a3a637d4a98bdb97`,
binary SHA-256은
`380f4f2b71a381b60be00e67f9edc63bfc861cd684cb602bc8adf2502f717a70`,
runtime instance는 `01a05195-9efe-7000-b735-069ebced353c`였다.

앞선 r6 로그는 실제 중첩 위치를 더 직접적으로 보였다.

```text
[keepers_json:continuity-live-purge-r1] sub-op: meta=0ms ka=0ms audit=29997ms ... total=30009ms
[snapshot_json] keepers_json: 30009ms
```

## fixed 실측

fresh r10에서 Local Keeper를 만들되 provider turn은 실행하지 않았다. 첫 cold
parameterized execution은 HTTP 200, 8.982ms, Keeper 1건, continuity 1건이었다.

같은 exact-head container를 실제 restart해 process cache를 비웠다. runtime
instance가 `01a051a1-...`에서 `01a051a2-...`로 바뀐 뒤 첫 cold 요청은 HTTP 200,
199.545ms, Keeper 1건, continuity 1건이었다. declarative autoboot가 꺼져 있어
Keeper는 offline으로 표현됐지만 row와 typed continuity diagnostic은 보존됐다.

restart 31초 뒤 execution, transport health, execution trust, mission, operator
snapshot, operator digest refresh loop가 동시에 시작된 창에 새 cache key를 요청했다.
응답은 HTTP 200, 7.036ms, Keeper 1건, continuity 1건이었다. 그 뒤 종료까지
61.6초의 timestamped log 25줄에서 cache compute timeout, refresh timeout,
30초 slow-render signature는 0건이었다.

## 검증

- `scripts/dune-local.sh build test/test_dashboard_http_core.exe
  test/test_dashboard_cache.exe test/test_executor_pool_eio_mutex.exe`
- dashboard HTTP executor group 54/54
- dashboard cache offload group 3/3
- executor pool Eio mutex safety 8/8
- fresh Linux/arm64 first cold request
- 같은 container의 실제 restart 뒤 first cold request
- 6개 startup refresh loop와 겹친 cold request 및 61.6초 후속 로그

## 남은 경계

one-click periodic janitor의 missing Docker CLI는 r10에서도 1회 재현돼 #31934에
추가했다. `keeper_tool_search.toml` managed-asset drift는 같은 root의 #31156에
추가했다. 둘은 이 latency 수정 범위에 포함하지 않는다. deployed
`/Users/dancer/me/.masc`는 바꾸지 않았다.

## 근거

- [근거] Git remote-context build log, image inspect, container `build-commit`,
  `/health?full=1`, binary `sha256sum`, baseline/fixed execution responses,
  real restart 전후 runtime identity, timestamped server logs, 2026-08-30T16:48:37+09:00
  확인, 신뢰도 High.
