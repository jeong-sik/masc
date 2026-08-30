# Failed lane attempt count Linux runtime R1

## 결과

두 candidate가 모두 실패한 lane은 provider/log에서 두 dispatch가 보였지만 기존 receipt는
`lane_attempt_count=1`만 기록했다. 마지막 candidate의 `selected_model`은 보존됐으므로
“두 번째 모델이 선택됐는데 lane attempt는 하나”라는 내부 모순이었다.

runtime-attempt callback에서 마지막 0-based lane index를 receipt ref에 보존한다. receipt
count는 index+1로 계산한다. `fallback_applied`는 turn이 성공하고 later candidate에서
settle한 경우에만 true이므로, failed second candidate는 count 2와 fallback false를 함께
기록한다.

## exact identity

- source change head: `1cc5124f5923d8397ddc7ac5f88ad5a22202c14f`
- source base head: `b4e0f6073909b2f84f71f15957b9368e077cdbb9`
- Linux measurement composition/embedded commit:
  `8ca359b870c7bb78c01f762717ad3eead00e480b`
- Linux/arm64 image digest:
  `sha256:588c862ee3c2d0ff79f16aec1faebf00c1d43b7f48323d4a7f461dae7db18820`
- binary SHA-256:
  `73636f643d4206edfbc7495b5e924e2065ca8d83db19d0fb643cb72c54bbc9f3`
- first-start runtime instance: `01a05288-ae3b-7000-a9f0-ca4e68a17107`
- restarted runtime instance: `01a05289-084e-7000-b06d-819f31fb639d`

제품 변경은 `origin/main`에서 독립적으로 작성했다. measurement composition에는 앞선
Docker source-build, receipt disposition, fleet-health 변경도 포함하지만 이 PR의 delta는
lane attempt observation뿐이다. BuildKit remote checkout, embedded `build-commit`,
`/health?full=1`, binary hash가 위 identity를 직접 보고했다.

## isolated two-candidate lane

default runtime id와 같은 이름의 lane을 만들고 candidate를 다음 순서로 고정했다.

1. `ollama_cloud.ollama-cloud-glm-5-3-flash`
2. `ollama_cloud.deepseek-v4-flash`

두 candidate는 같은 internal fake provider에서 HTTP 429를 받았다. 각 turn마다 provider
POST가 정확히 두 건 발생했고 외부 provider request는 없었다.

## baseline r34

composition `b09c851dac888263fedb3cd10ad40b6f7a698f6f`, image
`sha256:9b7cf86ab582bced204bec45f46c1e0831ee284e3a43e370b7155b60b35374f2`,
binary `e4dcec243bcf6f3034972aee04d41e134fb0de2c557385906194dbc7046c1937`
의 fresh run은 provider model GET 1건과 chat POST 8건을 만들었다.

- Keeper turn/receipt: 4건
- 실제 candidate dispatch: 8건, turn당 2건
- selected model: 4/4 `deepseek-v4-flash`
- receipt attempt/lane attempt: 4/4 1/1
- fallback applied: 4/4 false
- runtime outcome: 4/4 failed

`attempt_count=1`은 마지막 runtime 자체의 call 수라 맞지만, lane attempt 1은 첫 candidate를
지웠다.

## fixed r35 최초 기동

fresh volume의 시작 시각 `2026-08-30T11:58:04Z` 이후 receipt만 분리했다.

- provider chat POST: 8건, turn당 2건
- receipt: 4건, Keeper별 1건
- selected model: 4/4 `deepseek-v4-flash`
- runtime attempt/lane attempt: 4/4 1/2
- fallback applied: 4/4 false
- runtime outcome: 4/4 failed
- rotation attempts: 4/4 empty

## 실제 재시작

같은 container/volume을 `docker restart --timeout 20`으로 재시작했다. runtime instance가
`01a05288-ae3b-...`에서 `01a05289-084e-...`로 바뀌었다. 재시작 시각
`2026-08-30T11:58:26Z` 이후 receipt만 분리했다.

- provider chat POST: 8건, turn당 2건
- receipt: 4건, Keeper별 1건
- selected model: 4/4 `deepseek-v4-flash`
- runtime attempt/lane attempt: 4/4 1/2
- fallback applied: 4/4 false
- runtime outcome: 4/4 failed
- rotation attempts: 4/4 empty

fixed 전체 provider 요청은 startup model GET 2건, chat POST 16건이다. MASC와 fake-provider
container를 모두 정지했다. MASC는 graceful shutdown 후 exit code 0이었고 volume은
보존했다.

## focused 검증

- `scripts/dune-local.sh build test/test_keeper_terminal_reason_typed.exe`
- failed two-candidate: attempt count 2, fallback false
- successful two-candidate: attempt count 2, fallback true
- terminal-reason independent field matrix: 147,200 cases, mismatch 0
- `git diff --check`
- touched OCaml files `ocamlformat --check`

## 경계

3개 이상 candidate 실패는 Linux에서 실행하지 않았다. pure helper는 마지막 candidate
index+1을 사용하며 no-attempt/default floor는 기존 1을 유지한다. 운영 중인 8935 server와
deployed `/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] isolated fake-provider request log, exact-source BuildKit log, embedded build
  commit, image/binary identity, 최초 기동/실제 재시작 receipts·logs,
  2026-08-30T21:00:59+09:00 확인, 신뢰도 High.
