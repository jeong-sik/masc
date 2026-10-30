# Failure exemption restart Linux R1

## 결과

`InvalidRequest`와 empty-completion의 bounded crash-accounting budget이 process-local
`Hashtbl`에만 있어 재시작마다 0으로 초기화됐다. 같은 deterministic failure를 budget 직전에
재시작하면 durable turn-failure streak를 영구히 올리지 않을 수 있었다.

이번 변경은 두 counter를 strict Keeper별 JSON record로 durable atomic write한다. 관련 실패는
매번 current record를 읽어 increment한 뒤에만 exemption 여부를 결정한다. unknown schema,
malformed record, load/save I/O failure는 새 budget을 주지 않고 ordinary crash accounting으로
fail-closed한다. successful turn과 operator clear는 durable remove에 성공해야 reset으로 인정한다.

## exact identity

- issue: `#31970`
- stacked base head (`#31969`): `5794aa7c2a6c1453573e85eda138121735239aeb`
- product change head: `86dbc07dbc7da5924e66aef00dc70efe243e8154`
- Linux measurement composition: `fdc2c0c90846f910751511724b7bb3a000f7c082`
- Linux/arm64 image: `sha256:35926d77f6e4446faded760a5877d7c5a43ce84189d756d843ebc718173d1e9a`
- binary SHA-256: `f96f2fdb33fde870f106ca6188b62c4a5a9e4b4898f7fa439cc5fdb306fe0cf0`
- fixed first start: `2026-08-30T13:40:15Z`
- fixed restart: `2026-08-30T13:42:35Z`

measurement composition에는 앞선 receipt, retry, deferred-runtime, failure-streak 변경이 함께
들어 있다. 이 PR의 제품 delta는 현재 main 계열에 존재하는 InvalidRequest/empty-completion
exemption state의 durability뿐이다.

## isolated provider

외부 provider 호출은 0건이다. Docker internal network의 fake OpenAI-compatible provider가 모든
chat request에 HTTP 400 `invalid_request`를 반환했다. 한 Keeper만 autoboot했고 heartbeat
cadence는 15초로 설정해 clean shutdown 중 추가 turn이 생기지 않게 했다.

## baseline r39

source `90a182640f4b77624a3efe34eadd161d867fd093`, image
`sha256:1620ec955be1bb43f1dc3b1dc1d0c7612accda5aee0a3989fec436ea69f0ad9e`,
binary `e2c8028c534287990e663bba436703fd37b70a2734c9729cff8a5fabbc29fa39`에서
재현했다.

- restart 전: 첫 3회는 `consecutive=0`, 뒤 5회는 crash streak 1→5
- clean restart 뒤 첫 두 동일 HTTP 400: 다시 auto-recoverable exemption
- durable streak: restart 전 5, restart 첫 두 실패 뒤에도 5

restart가 exemption budget을 0으로 되감아 이미 exhausted된 failure를 다시 숨겼다.

## fixed r40

1. 첫 실행의 동일 HTTP 400 세 건은 기대대로 exempt됐다.
2. strict durable record는 `invalid_request_count=3`, `empty_completion_count=0`이었다.
3. turn-failure streak file은 없었다.
4. 앱을 정상 종료해 exit 0을 확인하고 같은 image/volume을 재시작했다.
5. restart 첫 HTTP 400에서 즉시 `exceeded 3` 로그가 발생했다.
6. exemption record는 4, durable turn-failure streak는 1이 됐다.
7. health는 `turn_failure_recovering`, failing/recovering/executable 1/1/1,
   `operator_action_required=false`였다.

## focused 검증

- focused executable 4개 build: pass
- InvalidRequest: 7/7 pass (durable process boundary와 unknown schema 포함)
- runtime observation boundary: 10/10 pass (empty-completion reset 포함)
- heartbeat turn failure: 6/6 pass
- direct keepalive lifecycle: 1/1 pass
- typed terminal matrix: 147,200 cases, mismatch 0
- touched OCaml format와 `git diff --check`: pass

## 경계

- measurement composition의 별도 transient-transport exemption은 선행 Draft 변경에서 도입된
  process-local counter다. conflict 조합에서는 기존 동작을 보존했으며 이 PR의 current-main delta에
  포함하지 않는다.
- provider container는 stop timeout 뒤 exit 137, MASC 앱은 두 번 모두 exit 0이었다.
- 운영 중인 8935 server와 `/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] exact-source BuildKit log, image/binary identity, isolated HTTP 400 wire, before/after
  exemption and streak records, Keeper logs, `/health?full=1`,
  2026-08-30T22:44:51+09:00 확인, 신뢰도 High.
