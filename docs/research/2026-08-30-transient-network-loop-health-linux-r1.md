# Keeper transient network loop health Linux runtime R1

## 결과

persistent provider-network outage가 모든 Keeper turn을 실패시켜도 기존 runtime은 각
failure를 무제한 auto-recoverable로 처리했다. 5초 cadence의 bounded observation에서
59초 동안 44회 실패가 났지만 counter는 44/44 `consecutive=0`, full health는
`overall/fleet=ok`였다.

transient transport exemption을 Keeper별 3회로 제한한다. 4번째와 이후 연속 실패는
ordinary durable failure accounting으로 들어가며 lifecycle과 retry scheduler는 그대로
살아 있다. 실행 가능한 failing Keeper는 fleet
`degraded / turn_failure_recovering`으로 투영하되 자동 recovery 경로이므로 operator
action은 false다.

## exact identity

- source change head: `cfbc540440c4542abf5f195bc920e5fd4bd08191`
- stacked parent head: `c1f7cc5c672b119da55ebac0903c1ba9577d0b87`
- Linux measurement composition/embedded commit:
  `e635edb7da7e4b72d3a8e389356dd9d48e8e5843`
- Linux/arm64 image digest:
  `sha256:add2362949b81c6032d6f4460215039218be4395856dcc6a4be81ecc0561648d`
- binary SHA-256:
  `35cdfd6a0cf0c62cc786a160789c295c5ecf7e1d989f6e34d540338a02459865`
- first-start runtime instance: `01a05266-6266-7000-a28d-55123e3d005e`
- restarted runtime instance: `01a05267-f3f7-7000-b99d-3d9d816ee6cc`

제품 변경은 #31954 head 위에 한 commit으로 작성했다. measurement composition에는
검증된 Docker source-build fix와 앞선 receipt truthfulness 변경도 포함하지만, 이 PR의
delta는 failure accounting과 health projection뿐이다. BuildKit remote checkout,
embedded `build-commit`, `/health?full=1`, binary hash가 위 identity를 직접 보고했다.

## baseline r27b

composition `776be0009277a2935ec71de7f8aa656f50503b15`, image
`sha256:4db8aae5071aa2807bec5ca664b7627e81bf5abcf97cfc0b47a27793cc798ef3`,
binary `a61110401f8bfdbac14f9f1e2d96d2a9f341595090d02d558510418928876f54`,
runtime instance `01a05251-0e5e-7000-808c-e12ab7e46d5b`를 non-empty dummy
credential, `--network none`, 5초 cadence로 실행했다.

- 관찰 시간: 59초
- terminal DNS failure/receipt: 44건
- Keeper별 failure: 11건
- auto-recoverable: 44건
- `consecutive=0`: 44건
- `deferred_next_runtime=none`: 44건
- overall/fleet status: `ok / ok`
- operator action required: false

컨테이너는 반복 쓰기를 제한하려고 측정 직후 정지했고 exit code 0이었다.

## fixed r29 최초 기동

fresh volume, 같은 network/cadence 조건에서 93초 측정했다.

- terminal DNS failure/receipt: 72건, Keeper별 18건
- exempted / `consecutive=0`: 12건, Keeper별 정확히 3건
- nonzero consecutive failure: 60건
- overall/fleet status: `degraded / degraded`
- blocker: `turn_failure_recovering`
- failing/recovering/executable Keeper: 4/4/4
- operator action required: false

12건 이후 각 Keeper의 counter가 1, 2, 3, 4로 증가하는 로그를 직접 확인했다. 자동
recovery를 막지 않으면서 outage evidence가 더는 0에 고정되지 않는다.

## 실제 재시작

같은 container/volume을 `docker restart --timeout 20`으로 재시작했다. process-local
budget은 다시 시작됐지만, 새 runtime instance에서도 bound는 동일하게 작동했다.

- 재시작 뒤 terminal DNS failure/receipt: 40건
- exempted / `consecutive=0`: 12건, Keeper별 정확히 3건
- nonzero consecutive failure: 28건
- overall/fleet status: `degraded / degraded`
- blocker: `turn_failure_recovering`
- failing/recovering/executable Keeper: 4/4/4
- operator action required: false

Keeper별 warmup이 65–74초로 달라 observation 종료 시 receipt 수는 9/11/11/9였지만,
모든 Keeper는 동일한 3회 면제 뒤 nonzero counter로 전환했다. 최종 container는 graceful
shutdown 후 exit code 0이었고 volume은 보존했다.

## focused 검증

- `scripts/dune-local.sh build test/test_keeper_runtime_observation_boundaries.exe
  test/test_server_runtime_bootstrap.exe`
- runtime observation/failure accounting: 11/11
- recovering health case: bootstrap 47, 1/1
- existing config blocker case: bootstrap 46, 1/1
- `git diff --check`
- touched OCaml files `ocamlformat --check`

success가 transient budget을 reset하는 것은 focused accounting test로 확인했다. 실제
network recovery end-to-end는 실행하지 않았다.

## supplemental rate-limit boundary r33

더 최신 composition `b09c851dac888263fedb3cd10ad40b6f7a698f6f`, image
`sha256:9b7cf86ab582bced204bec45f46c1e0831ee284e3a43e370b7155b60b35374f2`,
binary `e4dcec243bcf6f3034972aee04d41e134fb0de2c557385906194dbc7046c1937`
에서 internal fake provider가 HTTP 429를 반복 반환하게 했다.

5초 cadence로 32건, Keeper별 8건의 `api_error_rate_limited`가 발생했다. 32건 모두
처음부터 nonzero failure counter로 집계됐고 면제는 0건이었다. health는
`degraded / turn_failure_recovering`, failing/recovering/executable 4/4/4, operator
action false였다. 따라서 새 3회 budget은 typed network/timeout 경계에만 적용되고 rate
limit의 기존 durable accounting을 약화하지 않는다. 측정 container는 exit code 0으로
종료했다.

## 경계

3회 면제는 crash accounting만 제어한다. Keeper lifecycle, retry scheduler, lane routing,
operator action policy는 바꾸지 않는다. 운영 중인 8935 server와 deployed
`/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] exact-source BuildKit log, embedded build commit, image/binary identity,
  network-none 최초 기동/실제 재시작 counters·health·receipts, 2026-08-30T20:24:48+09:00
  확인, 신뢰도 High.
