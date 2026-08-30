# Keeper config-error disposition Linux runtime R1

## 결과

기존 receipt는 terminal preflight config error를
`fail_open_next_runtime / preflight_config_error`로 기록했지만 실제 runtime facts는
attempt 0, fallback false, rotation empty였다. 로그도
`deferred_next_runtime=none`이었다. 다음 runtime으로 넘어갔다는 표현이 관측 사실과
충돌했다.

새 `operator_action_required` wire value로 terminal config/auth failure를 닫힌 상태로
표현한다. parser round-trip, operator broadcast, dashboard `Blocked` display와 영문/한국어
manual도 같은 의미를 사용한다.

## exact identity

- source change head: `31bfcd55192f23efd6e388febc3dd8d7cf6b16d5`
- Linux measurement composition/embedded commit:
  `776be0009277a2935ec71de7f8aa656f50503b15`
- Linux/arm64 image digest:
  `sha256:4db8aae5071aa2807bec5ca664b7627e81bf5abcf97cfc0b47a27793cc798ef3`
- binary SHA-256:
  `a61110401f8bfdbac14f9f1e2d96d2a9f341595090d02d558510418928876f54`
- first-start runtime instance: `01a05245-7017-7000-bb96-9e52cc74fffb`
- restarted runtime instance: `01a05247-4766-7000-845b-6e4a4b3245b0`

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
BuildKit fetch SHA, container `build-commit`, `/health?full=1`, binary hash가 같은
composition head를 가리켰다.

이 변경은 `origin/main`에서 독립적으로 작성했다. Linux measurement composition에는
missing credential을 HTTP 전에 막는 #31952와 typed fleet blocker를 보존하는 #31954
code도 포함했다. 따라서 같은 typed failure를 receipt와 health 두 surface에서 함께
검증했다.

## baseline r25

composition `be2e8233277576d9a37b777a5a64c55332db0f9c`, image
`sha256:c49b366416b0443fdabafb9d40dde02a4ad45255e7265e666b25db3e4afe7b49`,
binary `898a3dfaced31fbcda7b0a4fa8dd7178d1005c1055e97e1b04cbfd7c7207fe51`
의 config-error receipt는 다음처럼 서로 충돌했다.

- outcome: `receipt_failed`
- terminal reason: `config_error`
- disposition: `fail_open_next_runtime`
- disposition reason: `preflight_config_error`
- runtime attempt/lane attempt: 0/1
- fallback/degraded retry: false/false
- fallback reason: null
- rotation attempts: empty
- turn log: `deferred_next_runtime=none`

manual은 `fail_open_next_runtime`을 다음 candidate로 fall through하는 상태로 정의하므로,
이 receipt는 실행하지 않은 fallback을 암시했다.

## fixed r26 최초 기동

보존된 r24/r25 volume을 fixed image로 열었다. 65–74초 warmup 후 네 Keeper가
missing credential을 provider HTTP 전에 거부했다. 시작 시각
`2026-08-30T10:44:37Z` 이후 새 receipt만 분리했다.

- 새 config-error receipt: 4건, Keeper별 1건
- disposition: 4/4 `operator_action_required`
- disposition reason: 4/4 `preflight_config_error`
- runtime attempt/lane attempt: 4/4 0/1
- fallback/degraded retry: 4/4 false/false
- fallback reason: 4/4 null
- rotation attempts: 4/4 empty
- fleet health: `blocked / turn_configuration_error`
- operator action required: true

각 Keeper는 `operator_broadcast_required`를 한 번씩, 총 4회 기록했다.

## 실제 재시작

같은 컨테이너를 `docker restart`해 runtime instance가
`01a05245-...`에서 `01a05247-...`로 바뀐 것을 확인했다. 재시작 시각
`2026-08-30T10:46:37Z` 이후 receipt만 다시 분리했다.

- 새 config-error receipt: 4건, Keeper별 1건
- disposition/reason: 4/4
  `operator_action_required / preflight_config_error`
- runtime facts: 4/4 attempt 0, lane attempt 1, fallback false,
  degraded retry false, rotation empty
- fleet health: `blocked / turn_configuration_error`
- operator broadcast: 4회

추가 heartbeat 관찰 시점까지 두 번째 receipt는 생기지 않았다. 따라서 관측 구간에서
동일 process의 빠른 재방송 loop는 없었다. 재시작마다 한 번씩 다시 알리는 동작은
확인했지만, alert dedupe나 장기 recovery latency는 이번 변경의 성능 주장에 포함하지
않는다.

## focused 검증

- `scripts/dune-local.sh build test/test_keeper_terminal_reason_typed.exe
  test/test_keeper_runtime_trust_snapshot.exe`
- terminal-reason independent field matrix: 147,200 cases, mismatch 0
- terminal-reason suite: OK
- `test_keeper_runtime_trust_snapshot.exe test receipt_runtime_model 10`: 1/1
- `git diff --check`
- touched OCaml files `ocamlformat --check`

첫 시도의 잘못된 Alcotest filter는 모든 case를 skip해 exit 1이었다. 위 명령은 정확한
case 10을 실행해 통과했으며, skip 결과를 통과 증거로 사용하지 않았다.

## 종료와 경계

재시작한 container는 graceful shutdown 후 exit code 0이었다. measurement volume은
후속 반증을 위해 보존했다. 운영 중인 8935 server와 deployed
`/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] Git remote-context build, image inspect, container `build-commit`, 최초
  기동/실제 재시작 receipt·health·logs, 2026-08-30T19:50:50+09:00 확인,
  신뢰도 High.
