# Health message-mutation cache Linux R1

## 결과

mentioned workspace broadcast는 stopped Keeper의 durable event queue와 reaction ledger를
변경하지만, message mutation hook은 workspace/dashboard cache와 SSE만 갱신했다. 따라서
`/health?full=1`은 accepted mention 뒤에도 이전 queue counts를 담은 ready snapshot을 반환했다.

변경 뒤 `Server_bootstrap_loops`는 기존 cache/SSE callback과 full-health invalidator를 같은
message mutation observer에 설치한다. 기존 callback failure와 full-health callback failure는
각각 격리되며, already-committed message 결과를 뒤집지 않는다. full-health invalidator는
snapshot을 폐기하고 background refresh wake stream에 신호를 보낸다.

## exact identity

- issue: `#31980`
- stacked base: `851f2720bd5865af0355dac91a19be8b0c5053a9` (`#31979` head)
- product change: `73513425d2c4004d1e7b3b92cfb9849136b25c1c`
- measurement composition: `71fdc1f350f2ecfc3c1b945fabec22085bbcec15`
- Linux/arm64 image: `sha256:47cb26fd99c537df951bbd0ac2c91181fe60c74917dbe71b14d5acbab6d25af4`
- binary SHA-256: `a9bc4b031f2cf16b39a8dfb8f6fea7632752da49fc94ba46e8ec95407495cabc`
- runtime instance: `01a0533f-df9f-7000-a83f-eb048e6ada6a`

measurement composition은 product change에 old-stack Docker source-build input 보완만 포함한다.
source identity는 BuildKit remote commit checkout, image digest, in-process binary SHA로 고정했다.

## pre-fix r47

r47은 stopped `frontend`가 이미 queue/ledger pending count 1을 가진 격리 control이었다.

1. `2026-08-30T15:09:50.037619297Z`: admin이 explicit `@frontend` mention 시작.
2. `2026-08-30T15:09:50.057142130Z`: request
   `wmsg-0f747ff7f6705c2a953e39038e7c8a1e` accepted.
3. runtime은 pending chat row retained, fleet projection appended 1/failed 0을 기록했다.
4. `2026-08-30T15:09:50.060821214Z`: immediate health는 24,133ms old ready,
   `refresh_requested=false`, queue/ledger pending 1을 유지했다.
5. 나중 fresh snapshot computed `1788102596.834971`은 queue/ledger pending 2를 반환했다.

fresh snapshot이 같은 durable state를 2로 계산했으므로 immediate 1은 stale projection이다.
나중 refresh의 trigger는 이 기록에서 특정하지 않으며 periodic이라고 주장하지 않는다.

## post-fix r48

r47 app을 exit 0으로 종료하고 같은 격리 볼륨을 exact-source r48 image로 재기동했다.

1. control: ready computed `1788103152.257541`, queue/ledger pending 2.
2. `2026-08-30T15:19:33.741257179Z`: 새 explicit mention 시작.
3. `2026-08-30T15:19:33.760691512Z`: request
   `wmsg-2a218a0608c3cd436c92ddf1339e996d` accepted.
4. refreshed snapshot computed `1788103173.761892`, accepted response 약 1.2ms 뒤.
5. `2026-08-30T15:19:33.764653637Z` immediate probe는 age 1ms current-ready,
   queue/ledger pending 3을 반환했다.

refresh가 첫 probe보다 먼저 완료됐으므로 runtime warming window는 관측되지 않았다. 결과는 더
강한 current-ready 경로이며, focused stacked bootstrap test가 warming contract를 고정한다.

## 검증과 경계

- focused build: `test_broadcast_wakeup_policy.exe`, `test_server_runtime_bootstrap.exe` pass
- message hook composition: fleet_projection 7, 1/1 pass
- stacked full-health invalidation response: bootstrap 51, 1/1 pass
- `ocamlformat --check`, `git diff --check`: pass
- r47 pre-fix app exit 0; r48 post-fix app exit 0
- deployed 8935와 `/Users/dancer/me/.masc`는 건드리지 않았다.
- full suite와 CI는 실행/주장하지 않는다.

## 근거

- [근거] remote exact-commit BuildKit checkout, image/binary identity, accepted mention logs,
  pre-fix stale count와 post-fix same-millisecond current count, 2026-08-31T00:19:58+09:00 확인,
  신뢰도 High.

