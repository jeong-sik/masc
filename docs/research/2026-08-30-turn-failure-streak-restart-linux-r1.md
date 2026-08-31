# Turn failure streak restart Linux R1

## 결과

Keeper의 연속 turn 실패 횟수는 registry 메모리에만 있어 process restart마다 0으로
초기화됐다. 동일 checkpoint와 동일 실패 context를 재개해도 operator surface는 첫 실패를
다시 `1 consecutive cycle(s)`로 보고했다.

이번 변경은 양수 streak를 Keeper별 strict JSON으로 durable atomic write한다. 등록 전에
파일을 읽어 count와 typed `Turn_consecutive_failures` reason을 함께 복원하고, 성공 turn이나
operator clear가 durable remove에 성공한 뒤에만 registry를 0으로 만든다. 알 수 없는 schema와
malformed record는 0으로 간주하지 않고 등록을 fail-closed한다.

## exact identity

- issue: `#31966`
- source base head: `027574a822f4cd9487a90b2bbe334d130eeceefd`
- source change head: `6f84b17696833b9fdd5b206d8a6a3587186a418a`
- Linux measurement composition/embedded commit:
  `90a182640f4b77624a3efe34eadd161d867fd093`
- Linux/arm64 image digest:
  `sha256:1620ec955be1bb43f1dc3b1dc1d0c7612accda5aee0a3989fec436ea69f0ad9e`
- binary SHA-256:
  `e2c8028c534287990e663bba436703fd37b70a2734c9729cff8a5fabbc29fa39`
- fixed first start: `2026-08-30T13:03:27Z`
- fixed restart: `2026-08-30T13:05:53Z`

제품 변경은 당시 `origin/main`에서 독립적으로 작성했다. measurement composition에는
`#31967`의 deferred runtime suffix 변경과 앞선 receipt/health 변경도 포함하지만, 이 PR의
delta는 turn-failure streak의 process-restart lifetime뿐이다. BuildKit은 GitHub의 full commit을
직접 checkout했고 image digest와 `/app/masc` hash를 별도로 고정했다.

## isolated failure input

외부 provider를 호출하지 않았다. Docker internal network의 OpenAI-compatible fake provider가
SSE 200으로 visible text/tool 없이 reasoning-only 응답을 반환해 MASC `accept_rejected`를
일으켰다. 첫 실행은 GLM, restart는 `#31967`이 복원한 DeepSeek successor를 각각 한 번씩
호출했다.

## baseline r36

composition `8ca359b870c7bb78c01f762717ad3eead00e480b`의 clean restart에서는 첫
실패 뒤 operator-visible count가 1이었고, 같은 checkpoint를 재개해 다시 실패한 뒤에도 1이었다.
registry가 재시작 때 0으로 초기화됐기 때문이다.

## fixed r38 시간 순서

1. 최초 실행 provider POST 4건은 모두 `glm-5.3-flash`였다.
2. 4/4 turn이 typed `accept_rejected`로 끝나고 durable streak 4개가 모두 `count:1`이 됐다.
3. 앱을 정상 종료해 exit 0을 확인한 뒤 같은 image와 volume을 재시작했다.
4. 첫 새 provider POST 전에 live `masc_keeper_status backend`가
   `Keeper turn failed 1 consecutive cycle(s)`를 보고했다.
5. restart 최초 provider POST 4건은 모두 `deepseek-v4-flash`였고 GLM POST는 0건이었다.
6. 두 번째 typed failure 뒤 로그 4/4가 `consecutive=2`, durable streak 4/4가 `count:2`,
   live status가 `2 consecutive cycle(s)`를 보고했다.
7. consumed deferred suffix file은 0개였다.

restart 이후 health는 `overall_status=degraded`, blocker
`turn_failure_recovering`, failing/recovering/executable 4/4/4,
`operator_action_required=false`였다. 이 측정은 실패를 성공으로 바꾸는 검사가 아니라 동일
실패 chain의 누적 횟수가 process lifetime을 넘어 보존되는지 보는 검사다.

## focused 검증

- 두 focused 실행 파일 build: pass
- `test_heartbeat_integration -- test turn_failure`: 6/6 pass
- registry clear/re-register sequence: `1 -> restore 1 -> 2 -> restore 2 -> reset 0 -> restore 0`
- unknown schema registration fail-closed: pass
- `direct_keepalive 0`: 1/1 pass
- typed terminal matrix: 147,200 cases, mismatch 0
- touched OCaml format와 `git diff --check`: pass

전체 `test_heartbeat_integration`의 별도 실행은 로컬 playground가 비활성인 환경에서 기존
`direct_keepalive` 4건이 실패했으므로 full-suite pass로 주장하지 않는다. 이 변경의 focused
case와 lifecycle 충돌 재현 case는 현재 diff에서 통과했다.

## 경계

- durable write가 실패하면 현재 process의 registry count는 계속 증가하지만 restart 보존은
  보장할 수 없으며 error log를 남긴다.
- 성공 reset의 durable remove가 실패하면 registry와 health failure state를 유지한다.
- provider container는 SIGTERM 제한시간 뒤 exit 137이었다. MASC 앱은 두 번 모두 exit 0이고
  모든 request/receipt/streak 증거는 종료 전에 고정했다.
- 운영 중인 8935 server와 deployed `/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] exact-source BuildKit checkout/build log, image/binary identity, isolated provider wire,
  before/after live Keeper status, execution receipts, durable streak snapshots, restart logs,
  `/health?full=1`, 2026-08-30T22:08:59+09:00 확인, 신뢰도 High.
