# Runtime missing env credential Linux runtime R1

## 결과

Agent Core runtime은 env credential이 없을 때도 빈 secret으로 provider config를
만들었다. Keeper는 이 config로 약 82KB 요청을 외부 provider에 보냈고 401을
받았다.

runtime materialization은 그대로 둔다. dashboard가 `missing_auth`를 표시하려면
credential이 빠진 runtime도 읽을 수 있어야 하기 때문이다. 대신 실제 dispatch
직전에 최종 provider config를 검사한다. transform이 secret을 넣었거나 provider가
credential을 요구하지 않으면 기존 경로를 유지한다.

## exact identity

- source change commit:
  `387fc7288d7a083967b73988b24ad583350c88b8`
- Linux measurement composition/embedded commit:
  `a4edc823369a7c01572f4d7f8cd4c21dd9c028a8`
- Linux/arm64 image digest:
  `sha256:142da6d8405651ad074ac48bfef47ee4460957931dc61fbb6f439dca18b5127f`
- binary SHA-256:
  `aaf108d7dbd09d261c4b03b53580f681f977046d0d1158571bf89f8e0ddad1c6`
- fresh runtime instance: `01a05215-9322-7000-87f5-e5022cbc2f82`
- restarted runtime instance: `01a05215-edf9-7000-bcbd-46e3ef04fd6f`

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
BuildKit fetch SHA, image inspect, container `build-commit`, `/health?full=1`, binary
hash가 같은 composition head를 가리켰다.

## baseline r20

직전 composition `d8a5809049a7ad63be8d256cba82a37a63d43d4f`, image
`sha256:4507f9b0f2e5fece391198c29bbcf01ced9b25ccc5b9f5b4934dffe19cae2650`,
binary `81eab09dfdd8dc65cb26a205a60cba585d2631c08d4fe68a32cd3918cff4249`
에서 empty-key classic team은 다음 요청을 보냈다.

- provider HTTP 4xx request: 4건
- status: 401
- request body: 81,822–81,988 bytes
- keeper cycle failure: 4건
- turn latency: 235–240ms

요청에는 provider 인증 header가 없었다. 내부 keeper MCP token 검증과 provider
credential은 별도 계약이다.

## fixed fresh

explicit `MASC_KEEPER_BOOTSTRAP_ENABLED=true`와 빈
`OLLAMA_CLOUD_API_KEY`로 four-keeper classic team을 시작했다. 4/4 keeper가
materialize됐고 첫 turn은 모두 로컬에서 끝났다.

- `Invalid config 'provider_credential'`: 4건
- turn latency: 4–7ms
- provider `chat/completions`: 0
- HTTP 401: 0
- autoboot initial pass: 4/4

따라서 one-click entrypoint의 empty-key autoboot guard를 우회해도 무인증 요청은
나가지 않는다.

## 실제 restart

같은 volume을 `docker restart`했다. 새 runtime instance는 저장된 warmup
65–74초를 복원했다. 예약 시간이 지난 뒤 네 turn이 다시 실행됐다.

- `Invalid config 'provider_credential'`: 4건
- turn latency: 9–10ms
- provider `chat/completions`: 0
- HTTP 401: 0
- health: `overall_status=ok`, `keeper_fleet_safety=ok`

컨테이너는 graceful shutdown exit 0으로 끝났고 volume은 보존했다.

## air-gap 대조군

같은 이미지를 새 volume과 Docker `--network none`으로 시작했다. Docker health는
`healthy`였고 four-keeper turn도 실행됐다.

- network mode: `none`
- `Invalid config 'provider_credential'`: 4건
- turn latency: 4–7ms
- provider `chat/completions`: 0
- HTTP 401: 0
- DNS failure / network unreachable: 0

외부 연결이 불가능한 상태에서도 provider transport 오류가 아니라 같은 typed
config error가 나왔다. 차단 지점이 HTTP보다 앞이라는 런타임 증거다.

## focused 검증

- `git diff --check`
- `ocamlformat --check` on six touched OCaml files
- `scripts/dune-local.sh build test/test_runtime_provider_auth_headers.exe`
- provider config group: 52/52
- `scripts/dune-local.sh build test/test_keeper_turn_driver_accept.exe`
- keeper turn driver accept: 38/38
- `scripts/dune-local.sh build test/test_runtime_per_keeper_routing.exe`
- runtime resolver driver lookup: 11/11

새 테스트는 missing env 거부, dispatch transform 허용, credential-free provider
허용, non-Keeper Agent Core resolver 거부를 고정한다. 기존 dashboard test도
`missing_auth` 상태에서 HTTP 호출 0을 계속 확인한다.

## 남은 경계

실제 non-empty Ollama Cloud key를 사용한 성공 호출은 비용과 외부 credential이
필요해 실행하지 않았다. provider config에 secret을 넣는 transform과
credential-free 경로는 focused test로 검증했다.

운영 중인 8935 server와 deployed `/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] Git remote-context build, image inspect, container `build-commit`,
  fresh/restart/air-gap health와 keeper/provider logs,
  2026-08-30T18:56:06+09:00 확인, 신뢰도 High.
