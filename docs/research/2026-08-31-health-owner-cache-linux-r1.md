# Health Keeper Owner cache Linux R1

## 결과

Keeper Owner의 operation, turn, shutdown projection은 `keeper_owner` health fact를 바꾸지만
full-health cache를 무효화하지 않았다. `masc_keeper_msg`가 queued operation을 승인하고 같은 초에
terminal로 정착한 뒤에도 이전 owner count가 담긴 ready snapshot이 유지됐다.

변경은 `Keeper_owner`에 process-wide non-yielding state-change observer를 추가하고 server
bootstrap에서 full-health invalidation/wake에 연결한다. health에 노출되는
`operation_projection`, `turn_in_flight`, `shutdown_operation_id`가 실제로 달라진 뒤에만 알린다.
rejection, no-op, idempotent replay는 알리지 않으며 observer 예외는 이미 승인되거나 정착한 Owner
결과를 바꾸지 않는다.

## exact identity

- issue: `#31986`
- stacked base: `74472f30f3067acf67d333fe94b24a55008512a3` (`#31984` head)
- product change: `531196eba70ba2e4fe5b04beca93c2a8475068d1`
- measurement composition: `9f9e3e8dc678ec15e9b1c90012564c47d8a9e2a3`
- Linux/arm64 image: `sha256:3de6c384dedf49025fb0bfc1b3cd9112a90ba1c771fd9bf6e8308afcd9a847be`
- binary SHA-256: `37c5400a4c918a30330ca3084543bc4891380322830a227bc6855173499a2f5a`
- runtime instance: `01a05369-13dc-7000-a8c9-ee54748c229f`

measurement composition은 product change와 앞선 health observer stack, old-stack Docker source-build
input 보완만 포함한다. committed clean tree, image digest, in-process binary SHA를 함께 고정했다.

## setup

앞선 r50과 같은 격리 volume을 새 exact-source image로 재시작했다. fresh control은 backend의 기존
terminal operation 1개와 queued/running/in-flight 0을 보고했다. deployed 8935와
`/Users/dancer/me/.masc`는 건드리지 않았다.

transport 준비 과정의 missing-token HTTP 401과 missing-session HTTP 400은 Owner mutation이 없어
증거에서 제외했다. 채택한 r54는 인증된 `initialize`, `notifications/initialized` 뒤
`masc_keeper_msg`를 정확히 한 번 호출했다.

## pre-fix r51

1. fresh control computed `1788104813.804038`: owner queued/running/terminal `0/0/0`.
2. `2026-08-30T15:47:39.021313542Z`: registered backend message 시작.
3. `2026-08-30T15:47:39.031381750Z`: accepted,
   `operation_id=kmsg-f3c76b1de8afe372d5f8b898446e41af`, queued count 1.
4. `2026-08-30T15:47:39.035679833Z`: immediate health는 14,351ms old ready,
   `refresh_requested=false`, owner queued/running/terminal `0/0/0`을 반환했다.
5. fresh snapshot computed `1788104877.485951`은 backend/fleet terminal count 1을 반환했다.

workflow-rejected qa call은 mutation이 없어 baseline 증거에서 제외했다.

## post-fix r54

fresh control은 computed `1788105964.339817`, age 9,376ms, owner queued/running/terminal
`0/0/1`이었다.

1. `2026-08-30T16:06:13.718584752Z`: authenticated exact tool call 시작.
2. `2026-08-30T16:06:13.737528961Z`: HTTP 200, accepted,
   `operation_id=kmsg-40f847d697d65a52ad814a645d0fa886`, queued count 1.
3. `2026-08-30T16:06:13.744451502Z`: 종료 6.9ms 뒤 immediate health는 current ready,
   computed `1788105973.740156`, age 2ms를 반환했다.
4. 그 snapshot은 backend turn lane `chat_operation`, running count 1, terminal count 1을 담았다.
5. provider DNS failure로 operation이 terminal이 된 뒤 event-driven snapshot computed
   `1788105973.780633`은 running/in-flight 0, terminal count 2를 담았다.

immediate snapshot의 computed time은 accepted response 종료 약 2.6ms 뒤다. TTL이나 다음 periodic
refresh를 기다리지 않고 Owner mutation observer가 새 snapshot을 계산했다.

## 검증과 경계

- focused build: `test_keeper_owner.exe`, `test_server_runtime_bootstrap.exe` pass
- Owner lifecycle/observer/shutdown focused cases: actor 13-15, 29-30, 5/5 pass
- Owner health/full-health cache focused cases: bootstrap 31, 51, 2/2 pass
- queued/running/terminal, turn start/end, shutdown reserve/transition/release를 확인했다.
- rejection/no-op/replay suppression과 observer failure isolation을 확인했다.
- `ocamlformat --check`, `git diff --check`: pass
- pre-fix r51과 post-fix r54 app exit 0
- full suite와 CI는 실행/주장하지 않는다.

## 근거

- [근거] exact committed source, Linux image/binary identity, authenticated MCP accepted response,
  pre-fix stale-ready와 post-fix current-ready/terminal snapshots, 2026-08-31T01:07:10+09:00 확인,
  신뢰도 High.

