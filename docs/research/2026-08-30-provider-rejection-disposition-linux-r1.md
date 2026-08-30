# Keeper provider rejection disposition Linux runtime R1

## 결과

isolated fake provider가 HTTP 400 `invalid_request_error`를 반환했을 때 기존 receipt는
`fail_open_next_runtime / provider_runtime_error`를 기록했다. runtime facts는
attempt/lane attempt 1/1, fallback false, degraded retry false, rotation empty였고 로그는
`deferred_next_runtime=none`이었다.

generic terminal provider-runtime failure를 `retry_later`로 바꿨다. current turn에서 다른
lane candidate가 실행됐다고 주장하지 않으며, reason은 `provider_runtime_error`로 유지해
transient network retry와 구분한다.

## exact identity

- source change head: `7d0630db1dbbe5c5aa380b9dc7ba23d737ea79e5`
- stacked parent head: `19b990e23a058112806b2facefbca95c1e25292d`
- Linux measurement composition/embedded commit:
  `b09c851dac888263fedb3cd10ad40b6f7a698f6f`
- Linux/arm64 image digest:
  `sha256:9b7cf86ab582bced204bec45f46c1e0831ee284e3a43e370b7155b60b35374f2`
- binary SHA-256:
  `e4dcec243bcf6f3034972aee04d41e134fb0de2c557385906194dbc7046c1937`
- first-start runtime instance: `01a05275-36e0-7000-844d-e10807133acf`
- restarted runtime instance: `01a05275-8570-7000-9c57-597ceff103b8`

제품 변경은 #31959 head 위에 한 commit으로 작성했다. measurement composition에는
검증된 Docker source-build와 fleet-health 변경도 포함하지만 이 PR의 delta는 generic
provider receipt classifier뿐이다. BuildKit remote checkout, embedded `build-commit`,
`/health?full=1`, binary hash가 위 identity를 직접 보고했다.

## isolated provider

Node HTTP server와 MASC를 별도 `--internal` Docker network에 연결했다. runtime의
`ollama_cloud` endpoint를 그 서버의 `/v1`으로 바꾸고, 모든 요청에 고정된
OpenAI-compatible 400 body를 반환했다.

fixed 최초 기동과 재시작을 합쳐 fake provider가 관측한 요청은 다음과 같다.

- `GET /v1/models`: 2건, startup마다 1건
- `POST /v1/chat/completions`: 8건, Keeper turn마다 1건
- authorization header present: 10/10
- 외부 provider request: 0건

## baseline r30

composition `e635edb7da7e4b72d3a8e389356dd9d48e8e5843`, image
`sha256:add2362949b81c6032d6f4460215039218be4395856dcc6a4be81ecc0561648d`,
binary `35cdfd6a0cf0c62cc786a160789c295c5ecf7e1d989f6e34d540338a02459865`
에서 네 Keeper가 다음 receipt를 만들었다.

- outcome/reason: `receipt_failed / api_error_invalid_request`
- disposition/reason: 4/4
  `fail_open_next_runtime / provider_runtime_error`
- runtime attempt/lane attempt: 4/4 1/1
- fallback/degraded retry: 4/4 false/false
- fallback reason: 4/4 null
- rotation: 4/4 empty
- log `deferred_next_runtime=none`: 4건

## fixed r31 최초 기동

fresh volume의 시작 시각 `2026-08-30T11:36:48Z` 이후 receipt만 분리했다.

- 새 invalid-request receipt: 4건, Keeper별 1건
- disposition/reason: 4/4 `retry_later / provider_runtime_error`
- runtime facts: 4/4 attempt 1, lane attempt 1, fallback false,
  degraded retry false, fallback reason null, rotation empty
- log `deferred_next_runtime=none`: 4건
- operator broadcast: 0건

## 실제 재시작

같은 container/volume을 `docker restart --timeout 20`으로 재시작했다. runtime instance가
`01a05275-36e0-...`에서 `01a05275-8570-...`로 바뀌었다. 재시작 시각
`2026-08-30T11:37:08Z` 이후 receipt만 분리했다.

- 새 invalid-request receipt: 4건, Keeper별 1건
- disposition/reason: 4/4 `retry_later / provider_runtime_error`
- runtime facts: 4/4 attempt 1, lane attempt 1, fallback false,
  degraded retry false, fallback reason null, rotation empty
- log `deferred_next_runtime=none`: 4건
- operator broadcast: 0건

MASC와 fake-provider container를 모두 정지했다. MASC는 graceful shutdown 후 exit code
0이었고 measurement volume은 보존했다.

## focused 검증

- `scripts/dune-local.sh build test/test_keeper_terminal_reason_typed.exe`
- terminal-reason independent field matrix: 147,200 cases, mismatch 0
- terminal-reason suite: OK
- `git diff --check`
- touched OCaml files `ocamlformat --check`

## 경계

이 변경은 generic provider-runtime receipt의 truthfulness만 고친다. transient network,
config/auth, internal error, runtime exhausted와 capacity-backpressure 분기는 바꾸지 않는다.
운영 중인 8935 server와 deployed `/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] isolated fake-provider request log, exact-source BuildKit log, embedded build
  commit, image/binary identity, 최초 기동/실제 재시작 receipts·logs,
  2026-08-30T20:39:38+09:00 확인, 신뢰도 High.
