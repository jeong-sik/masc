---
rfc: "0520"
title: "필수 MCP bridge 에 한 번도 접속하지 않은 Muse 턴은 성공이 아니다"
status: Draft
created: 2026-11-14
updated: 2026-11-14
author: claude
supersedes: []
superseded_by: null
related: ["0390", "0509", "0495"]
---

# RFC-0520: 필수 MCP bridge 에 한 번도 접속하지 않은 Muse 턴은 성공이 아니다

- 상태: 초안.
- 이슈: #51918.
- 먼저 있는 변경: #51961 이 MASC 가 만든 workspace 에서만 `muse serve` 를 `--trust-workspace` 로 띄운다. 이 RFC 는 그 조건 밖에 남는 턴과, Muse Code 가 다시 조용히 접속을 건너뛰는 경우를 다룬다.
- 먼저 있는 결정: RFC-0509 가 Muse 턴이 무엇을 했는지를 durable item 으로 판정한다(`Turn_quiet`·`Turn_item_may_have_acted`·`Turn_items_unread`). RFC-0390 이 native 도구 자세를 정했다.
- 코드 좌표는 `origin/main` `be09733135e7` 에서 읽었다.
- 사용자 요청(2026-11-13): Keeper 의 턴 흐름과 도구 사용을 점검하고 개선점을 찾는다.

## 0. 요약

Keeper 턴이 Muse 로 갈 때 MASC 는 턴마다 loopback MCP bridge 를 띄우고, 세션 설정에 `mode: "required"` 로 넣는다. Muse Code 1.4.15 부터는 `--trust-workspace` 없이 뜬 host 가 이 서버에 접속하지 않는다. 거절도 하지 않는다. 세션은 시작되고 턴은 끝까지 돈다. MASC 는 그 턴을 `success` 로 기록했다.

`~/me/.masc` 기록(2026-11-11~12)에서 Muse 로 성공한 턴 1,139개가 전부 도구 호출 0건이다. 그 가운데 한 턴은 1,512,842 토큰을 썼다.

bridge 는 클라이언트가 어디까지 왔는지를 이미 안다. `Awaiting_initialize`, `Awaiting_initialized`, `Ready` 세 단계다. 이 값을 읽는 production 코드가 없다.

이 RFC 는 세 가지를 정한다.

1. bridge 가 자기 단계를 production 값으로 내준다(D1).
2. Muse host 가 완료했다고 알린 턴은 bridge 가 `Ready` 일 때만 성공이다. 아니면 이름 있는 실패다(D2).
3. 그 실패가 났을 때 턴이 한 일은 RFC-0509 판정을 그대로 따른다(D3).

## 1. 결정

### D1. bridge 가 클라이언트 단계를 내준다

`Runtime_official_client_mcp_http` 에 `client_phase : t -> Runtime_official_client_mcp.phase` 를 더한다. `For_testing.snapshot` 이 읽는 값과 같은 값이다. 새 상태를 만들지 않는다.

`Ready` 는 클라이언트가 `initialize` 와 `notifications/initialized` 를 마쳤다는 뜻이다. bridge 는 `Ready` 가 아니면 `tools/list` 와 `tools/call` 을 거절한다(`runtime_official_client_mcp.ml` 의 `require_phase`). 그래서 `Ready` 가 아닌 bridge 로는 도구가 한 번도 나가지 않았다.

### D2. `Ready` 가 아닌 bridge 의 턴은 성공이 아니다

`Keeper_muse_runtime` 은 dynamic tool 이 하나라도 있으면 bridge 를 띄운다. `Serve.run_turn` 이 `Ok` 를 돌려준 뒤, bridge 가 있으면 `client_phase` 를 읽는다.

| bridge | 단계 | 턴 결과 |
|---|---|---|
| 없음 (dynamic tool 0개) | 해당 없음 | 지금과 같다 |
| 있음 | `Ready` | 지금과 같다 |
| 있음 | `Awaiting_initialize` | 실패 `Session_mcp_not_connected` |
| 있음 | `Awaiting_initialized` | 실패 `Session_mcp_not_connected` |

실패는 닫힌 타입으로 둔다. 문장을 읽어 분류하지 않는다. 단계 값을 실패에 싣는다.

판정 시점은 턴이 끝난 뒤다. host 는 세션 시작 응답 뒤에 비동기로 접속한다(1.4.18 탐침: 응답 시점 요청 0건, 6초 뒤 `initialize`·`notifications/initialized`·`tools/list`). 턴이 끝났는데도 `Ready` 가 아니면 그 턴의 모델은 MASC 도구 목록을 받지 못했다.

### D3. 실패한 턴이 한 일은 RFC-0509 판정을 따른다

`Session_mcp_not_connected` 는 요청이 나간 뒤의 실패다. 모델이 돌았고 native 도구가 움직였을 수 있다. 효과 판정은 지금의 durable item 판정을 그대로 쓴다. 새 판정 규칙을 더하지 않는다.

`Agent_core.Error.Config (InvalidConfig _)` 로 만들지 않는다. `provider_attempt_dispatch` 는 요청이 나가지 않은 `InvalidConfig` 를 `Rejected_before_dispatch` 로 읽는다(`keeper_turn_driver.ml`). 이 실패는 요청이 나간 뒤라 그 뜻과 맞지 않는다.

## 2. 지금 모습

- `keeper_muse_runtime.ml`: `Mcp_http.start` 로 bridge 를 띄우고 `mcp_servers_of_bridge` 가 `required = true` 로 싣는다. 턴이 끝난 뒤 bridge 에서 읽는 것은 `await_host_stop` 뿐이다.
- `runtime_official_client_mcp_http.ml`: `authenticated_requests`, `phase` 를 `For_testing.snapshot` 으로만 내준다.
- `runtime_muse_serve.ml` 의 `handshake`: host 가 `sessionMcp` 능력을 허락했는지만 확인한다. 1.4.18 은 신뢰 없이 떠도 이 능력을 허락한다.
- MSP 1.4.18 정의(`muse schema generate-ts`): `SessionMcpServerMode` 는 「Startup failure posture」이고 기본이 `required` 다. 접속을 건너뛴 사실을 알리는 응답 필드나 알림은 정의에 없다.

## 3. 왜 이 모양인가

- **턴 전에 막지 않는 이유.** host 가 MCP 접속을 마쳤다고 알리는 프로토콜 신호가 없다. 턴 전에 막으려면 「몇 초 기다려 보고 안 오면 실패」가 된다. 기다리는 길이는 근거 없는 숫자다. 넣지 않는다.
- **`--trust-workspace` 조건만으로 닫지 않는 이유.** #51961 의 조건은 1.4.18 을 관찰해 얻었다. Muse Code 는 자동으로 갱신된다. 접속 조건이 다시 바뀌면 같은 일이 조용히 되풀이된다. bridge 단계는 MASC 가 가진 값이라 host 버전과 무관하다.
- **`authenticated_requests > 0` 이 아니라 `Ready` 인 이유.** 요청 수는 인증만 통과한 요청도 센다. 도구가 나갈 수 있었는지는 단계가 답한다.

## 4. 운영자에게 보이는 변화

- Muse 가 MASC 도구에 접속하지 못한 턴은 성공 대신 `Session_mcp_not_connected` 로 기록된다.
- `docker` Keeper 와 `native = "full"` 세션은 #51961 뒤에도 신뢰 없이 뜬다. 이 RFC 뒤에는 그 턴이 실패로 보인다.
- 지금 fleet(Keeper 29개, 전부 `microvm`·`remote_ssh`, native 읽기 전용)은 #51961 로 접속이 되므로 결과가 달라지지 않는다.

## 5. 알려진 한계와 열린 질문

1. **토큰은 한 번 쓰인다.** 판정이 턴 뒤라 그 턴의 모델 호출은 이미 끝났다. 이 RFC 는 잘못된 성공 기록을 없애고, 낭비를 막지는 못한다.
2. **같은 실패가 턴마다 되풀이되는지 모른다.** `Session_mcp_not_connected` 뒤에 lane 이 다음 턴에도 같은 Muse runtime 을 먼저 부르면 턴마다 토큰을 쓴다. 이 실패를 runtime 을 쉬게 하는 종류로 둘지는 lane 의 후보 진행 코드를 읽고 정한다. 구현 층을 열기 전에 닫아야 하는 질문이다.
3. **세션 재개.** 도구 없이 돈 턴이 Muse 세션 기록에 남는다. 다음 턴이 그 세션을 재개할지 새로 시작할지는 정하지 않았다.
4. **재개 세션의 접속 시점.** 탐침은 `session/start` 만 봤다. `session/resume` 에서도 턴 전에 접속하는지는 확인하지 않았다.
5. **1.4.15 시작 추정.** 접속이 끊긴 버전은 로그 시각으로 추정했다. 1.4.14 바이너리로 비교하지 않았다.

## 6. 확인 방법

- 단위: scripted host 가 bridge 에 접속하지 않고 턴을 완료하면 `Keeper_muse_runtime.run` 결과가 `Session_mcp_not_connected` 다. 접속하고 완료하면 성공이다. dynamic tool 이 0개면 지금과 같다.
- 실물: Muse 구독 한도가 풀린 뒤(2026-11-16T00:00Z), 신뢰 없이 띄운 host 로 한 턴을 돌려 실패 기록을 확인한다.

## 7. 하지 않는 것

- 접속을 기다리는 timer, 재시도 횟수 상한, 실패 문장 분류.
- Antigravity·Codex·Claude Code 경로. 같은 bridge 모듈을 쓰는 경로가 있지만 접속을 건너뛰는 사례를 관찰하지 않았다.
- MSP `mcpLinkError` 를 이름 있는 실패로 읽는 일. 1.4.18 정의에 있고 MASC 는 `Unrecognized_error_kind` 로 받는다. 따로 다룬다.

## 8. 층

| 층 | 내용 |
|---|---|
| L0 | 이 RFC |
| L1 | D1: `client_phase` 와 시험 |
| L2 | D2·D3: `Session_mcp_not_connected` 와 Keeper Muse 시험. 5절 2번을 닫은 뒤 연다 |
