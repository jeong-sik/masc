# Keeper config failure health Linux runtime R1

## 결과

Keeper가 모두 deterministic config error를 반복해도 기존 fleet health는
`overall_status=ok`, `operator_action_required=false`를 반환했다. 네 fiber가
failing/recovering 상태여도 executable capacity 4로 계산했기 때문이다.

`Agent_core.Error.Config`를 typed `Turn_configuration_error`로 registry에 보존한다.
post-turn heartbeat가 이 root cause를 generic consecutive count로 덮지 않게 했다.
health는 executable fiber 수와 config-blocked keeper 수를 별도로 보여준다.

## exact identity

- source change head: `ba9eaeace1192b86d9dc968a94b531342e041b03`
- Linux measurement composition/embedded commit:
  `be2e8233277576d9a37b777a5a64c55332db0f9c`
- Linux/arm64 image digest:
  `sha256:c49b366416b0443fdabafb9d40dde02a4ad45255e7265e666b25db3e4afe7b49`
- binary SHA-256:
  `898a3dfaced31fbcda7b0a4fa8dd7178d1005c1055e97e1b04cbfd7c7207fe51`
- fixed runtime instance: `01a05237-af46-7000-9bd5-5ddc5c433695`

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
BuildKit fetch SHA, image inspect, container `build-commit`, `/health?full=1`, binary
hash가 같은 composition head를 가리켰다.

이 health 변경은 `origin/main`에서 독립적으로 작성했다. Linux 재현 composition에는
missing credential을 HTTP 전에 막는 #31952 code도 포함했다. 그 code가 만든 typed
`provider_credential` error를 이 변경이 health까지 보존하는 구조다.

## baseline r22b

composition `a4edc823369a7c01572f4d7f8cd4c21dd9c028a8`, image
`sha256:142da6d8405651ad074ac48bfef47ee4460957931dc61fbb6f439dca18b5127f`,
binary `aaf108d7dbd09d261c4b03b53580f681f977046d0d1158571bf89f8e0ddad1c6`
의 실제 restart 결과는 다음과 같았다.

- failing keeper fiber: 4
- recovering keeper fiber: 4
- executable keeper fiber: 4
- fleet status: `ok`
- overall status: `ok`
- operator action required: false

turn 네 건은 모두 8–10ms `provider_credential` config error로 끝났고 provider HTTP
요청은 없었다. 따라서 executable count는 fiber 생존 사실만 말할 뿐, 실제 turn
성공 가능성을 뜻하지 않았다.

## 두 번의 반증

r23은 typed failure reason을 추가했지만 config-blocked count가 0이었다. Owner meta
commit과 registry write 순서를 조정한 r24도 count 0이었다. post-turn heartbeat가
typed reason을 `Turn_consecutive_failures`로 다시 덮고 있었다.

세 번째 변경은 heartbeat에 pure 정책을 추가했다. config reason만 보존하고,
`None`이나 다른 failure reason은 기존 `Turn_consecutive_failures` 집계를 유지한다.

## fixed r25

보존된 volume을 r25 image로 다시 열었다. 65–74초 warmup 뒤 네 keeper turn이
6–10ms에 같은 typed config error로 끝났다. full-health cache가 갱신된 뒤 8초
간격으로 네 번 조회했고 모두 같은 값을 반환했다.

- overall status: `blocked`
- fleet status: `blocked`
- blocker: `turn_configuration_error`
- operator action reasons: `keeper_fleet_safety:turn_configuration_error`
- failing/recovering keeper fiber: 4/4
- executable keeper fiber: 4
- configuration-blocked keeper: 4
- blocked names: backend, frontend, qa, tech_lead
- all target keepers configuration-blocked: true
- operator action required: true

fiber가 살아 있다는 사실을 지우지 않으면서, 현재 process에서 고칠 수 없는 config
failure를 `ok`로 표시하지 않는다. 일부 target만 config-blocked인 경우는 pure test에서
`degraded`와 operator action true를 확인했다.

## focused 검증

- `git diff --check`
- `ocamlformat --check` on all touched OCaml files
- registry failure reason group: 3/3
- fleet health config blocker case: 1/1
- status bridge: 13/13
- heartbeat turn-failure group: 5/5

같이 실행한 기존 bootstrap case 45는 executable 1을 기대했지만 0을 받아 실패했다.
해당 함수는 `origin/main`과 동일하고, 기존 미배선 test 문제 #27250에 이미 등록돼
있다. 이번 변경의 새 case 46은 독립 execution snapshot을 써 통과했다.

## 남은 경계

실제 fleet에서 transient provider error와 config error가 섞인 partial 상태는 실행하지
않았다. pure health test는 config-blocked 1 + healthy 1을 `degraded`로 고정했다.

운영 중인 8935 server와 deployed `/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] Git remote-context build, image inspect, container `build-commit`, baseline과
  fixed restart health/logs, 2026-08-30T19:32:17+09:00 확인, 신뢰도 High.
