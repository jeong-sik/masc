> 파생본이다. 원본 조사 보고서를 [README](README.md)에 적은 대로 손질했다.

기준 head 85b8af5b0453 (branch feat/authz-f3a-off-command-20261110), 확인 시각 2026-11-10 16:51 KST, 읽은 방식: rg와 파일 읽기만 한 정적 집계이고 빌드·실행·네트워크는 없다.

# 서버 문 지도: 다계정 부팅 때 닫거나 `Auth_gate.decide`로 보내야 하는 문

- worktree: `.worktrees/authz-d1-1-20261108`. 아래 경로는 이 worktree 기준이다.
- 16:51 KST에 `git rev-parse`로 head가 85b8af5b0453 그대로임을 다시 확인했다.
- 상태 말은 넷이다: open, shut, decided by Auth_gate, unknown (not traced).
- 줄 번호는 조사 때 직접 본 것만 적었다. 줄을 적어 두지 않은 근거는 함수 이름으로 적었다.
- 작성: rev-server-doors (적대적 보안 리뷰). 저장소 파일은 고치지 않았다.

## 결론

`Auth_gate.decide`를 부르는 곳은 미리보기 핸들러뿐이다. rg `Auth_gate\.` 결과가 `lib/auth_preview.ml`의 `whoami`, `human`, `member`뿐이다.
실제 서버의 route 래퍼 385곳, `/mcp`, `/ws`, gRPC는 계정 모드를 보지 않는다.
지금 다계정을 막는 것은 부팅 거부 하나다 (`lib/server/server_runtime_bootstrap.ml:1689-1701`).
이 거부만 풀면 아래 문이 legacy credential로 그대로 열린다.

## 1. 문 표

| # | 문 | 위치 | 받는 credential | 더 안 만들면 | 할 일 |
|---|---|---|---|---|---|
| 1 | HTTP/1 route 표, 등록 호출 385곳 | `lib/server/server_routes_http.ml:8` `make_routes`, 래퍼는 `lib/server/server_auth.ml` | legacy bearer, workspace secret, MCP OAuth, internal token | open | 다계정 표를 따로 만든다 |
| 1a | `Token_permission` 137, `Permission` 16, `Tool`·`Tool_actor`·`Tool_observation` 50, `Read_auth` 11, `Private_token_permission` 1 | 같은 곳 | legacy role | open (legacy Admin·Worker) | 닫는다 |
| 1b | `Public_read` 115 | `server_auth.ml` `with_public_read` | strict가 아니면 없음 | open (loopback 무자격) | 닫는다 |
| 1c | `Always_public` 14, `Open_when_strict` 10, `on_canonical_host` 3 | — | 없음 | open | 하나씩 판정 (F6) |
| 1d | `Self_authenticated` 26: Mcp_transport 13, Oauth_protocol 10, Subpath_dispatch 2, Loopback_dev_token 1 | 핸들러 안 | legacy | open | 닫는다 |
| 2 | HTTP/2 | `lib/server/server_h2_gateway.ml` → `Server_http_ingress.serve ~routes` | 1과 같음 | 1과 같음. 표를 같이 쓴다 | 없음 |
| 3 | Router 밖 갈래 4개: `OPTIONS *`, `DELETE /mcp`, `/mcp/managed`, `/mcp/operator` | `lib/server/server_http_ingress.ml` `dispatch_route` | DELETE는 legacy | open | 표 안으로 옮기거나 닫는다 |
| 4 | `/mcp` GET·POST, `POST /`(MCP 별칭), `/mcp/managed`, `/mcp/operator`, `/mcp/play`, `/sse` | `lib/server/server_routes_http_routes_frontend.ml`(1-275행 범위), `lib/server/server_mcp_transport_http.ml:1230-1348` | legacy, OAuth, internal token | open | 닫는다 (C4-11·12까지) |
| 5 | `/ws` upgrade | `lib/server/server_routes_http_routes_frontend.ml:75-88` | legacy. 실패하면 same-origin `Origin`만으로 통과 | open | 닫는다 |
| 5a | `/ws` 프레임 | `lib/server/server_runtime_bootstrap.ml:1868-1960`, token 없이 `Mcp_eio.handle_request` | `dashboard/hello`의 legacy token | Public 메서드 9개만 통과. hello 뒤에는 모든 broadcast를 받는다 | 닫는다 |
| 6 | SSE: `GET /mcp`, observer와 `/events/presence`(`?token=`), `/ag-ui/events`, `Public_read` 스트림(activity, ide, log, fleet) | frontend:151-152, `server_routes_http_routes_activity.ml:848`, `server_ide_http.ml:540`, `server_routes_http_routes_log_stream.ml:141`, `server_routes_http_routes_fleet_stream.ml:77-81` | legacy, query token | open | 닫는다 |
| 7 | gRPC `ToolCall`, subscribe | `server_runtime_bootstrap.ml:1849-1867`, `lib/server/server_grpc_listener.ml:64`, loopback 8936, `MASC_GRPC_ENABLED=1` | 없음 | open (켜져 있으면) | listener를 띄우지 않는다 |
| 8 | stdio `masc-stdio` | `bin/main_stdio_eio.ml:76-89` | env `MASC_TOKEN` (20행) | shut (`single_user` 값이 있어야 owner 초기화, 111-129행) | 그 값을 다계정에 만들어 주지 않는다 |
| 9 | dev-token | `lib/server/server_routes_http_routes_dashboard.ml:451` | 없음 | open: legacy Admin bearer를 내준다 (F2) | 닫는다 |
| 10 | `/oauth/*` 8, Keeper OAuth callback | `lib/server/server_oauth_http.ml:194-209`, `lib/server/server_keeper_oauth_http.ml:216` | same-origin 검사 | open. 승인 주체는 unknown (not traced) | 닫는다 |
| 11 | 로그인 8 + 미리보기 12 | `lib/server/server_login_http.ml` `add_routes`, `add_preview_routes` | session cookie+CSRF, PAT, service | decided by Auth_gate (로그인 8은 자기 route가 판정) | 충돌 정리 (F8) |
| 12 | 호스트 CLI: `masc login`, TUI | `lib/auth/auth_login.ml:66`, `bin/main_eio.ml:912-922`, `bin/masc_tui_http.ml:165-175` | 파일 접근 | open: 계정 모드를 안 보고 Admin bearer를 파일에 쓴다 | 다계정 workspace에서 거절 |
| 13 | 커넥터 inbound 4종, Slack poll | `lib/server/server_*_in_process_gateway.ml` → `lib/gate_keeper_backend.ml:257-294` | 외부 채널 사용자 | open: author가 문자열 agent 이름 | gateway를 띄우지 않는다 |
| 14 | 백그라운드: owner lane, goal verifier, completion authority, candle, curator | `server_runtime_bootstrap.ml:1515-1558` `start_post_ready_owner_lanes` | 없음 | 저장소 쓰기는 open. 모델 호출은 `Multi_account`를 게시하면 shut (`No_operator`, `Host_not_shared`) | 띄우지 않거나 typed author를 붙인다 |
| 15 | Keeper 턴의 계정 선택 | `lib/runtime/runtime_account_access.ml:239-269` | — | `Authz_keeper_turn.decide`가 판정 (Auth_gate 아님) | F3 |
| 16 | official-client MCP listener | `lib/runtime/runtime_official_client_mcp_http.ml:535-543` | 턴마다 새 bearer (370-372행에서 비교) | shut (턴에 묶임) | 없음 |
| 17 | egress proxy, browser addon·exec shim unix socket, microVM agent socket, schedule runner | `lib/keeper/keeper_keepalive.ml:535`, `lib/egress_proxy_net/egress_proxy_net.ml:257`, `lib/browser_addon_service.ml:91`, `lib/browser_addon_live_ego.ml:169`, `lib/exec_shim/shim_agent.ml:131` | — | unknown (not traced) | — |

집계는 rg 정적 집계다. 인벤토리 도구(`tools/auth_route_inventory`)는 빌드가 필요해 돌리지 않았다. 호출 하나가 경로 여럿을 등록하는 곳은 세지 못했다. 내역은 부록 C에 있다.

DO 1-(b) 답: HTTP/2는 갈래를 따로 정하지 않는다. h2 스트림을 `Http_reqd`로 만들어 `Server_http_ingress.serve ~routes`를 부른다. 직접 답하는 것은 `Unsupported_asterisk_form_options`의 400 하나다.

## 2. 발견

### F1 (P1) 래퍼가 legacy credential을 그대로 받는다

- 내용: `Server_auth.with_*`와 MCP·WS 인증은 계정 모드를 보지 않는다. `Auth_gate`는 같은 credential을 거절하지만 아무도 부르지 않는다.
- 무엇이 틀렸나: 다계정의 Admin이 아닌 사람도 예전에 받은 agent bearer나 workspace secret을 가지고 있으면 래퍼를 통과한다. 그 경로로 남의 Keeper 설정과 secret, 공용 runtime 설정이 바뀐다.
- 근거:
  - rg `Auth_gate\.` (lib, bin) → `lib/auth_preview.ml`뿐.
  - `lib/auth/auth.ml` `resolve_role_with_auth_config` (100-313행 범위): workspace secret을 bearer로 내면 Admin, internal keeper token은 Worker, agent credential은 그 role.
  - `lib/server/server_routes_http_routes_keepers.ml:320-330`: `Keeper_post_config`, `Keeper_post_secrets`가 `with_token_permission_auth ~permission:CanAdmin`.
  - `lib/server/server_routes_http_routes_setup.ml`: 등록 14곳이 `Token_permission CanAdmin` (줄 번호 미기록).
  - `lib/auth_gate.ml` `authenticate`: `Legacy_bearer` → `Legacy_credential_forbidden`, `Mcp_oauth_token` → `Mcp_oauth_token_not_bound`, `Query_credential` 거절.
- 확인한 방법: 래퍼 본문과 `Auth_gate` 전체를 읽고 호출자를 rg로 셌다.
- 신뢰도: High.

### F2 (P1) loopback이면 무자격 요청이 Admin bearer를 받는다

- 내용: strict는 env, non-loopback bind, non-loopback base URL 중 하나일 때만 참이다. 부팅 판정은 strict를 요구하지 않는다.
- 무엇이 틀렸나: loopback에 묶이고 strict가 아닌 구성에서는 dev-token 경로가 자격 없는 요청에 Admin 역할 bearer를 준다. 미리보기가 쓰는 `127.0.0.1` 구성이 그렇다. 다계정 서버가 이 구성으로 뜨면 그 bearer로 F1의 경로가 모두 열린다. 같은 조건에서 `Public_read` 115곳이 무자격으로 열리고 board 접근은 `Operator`가 된다.
- 근거:
  - `lib/server/server_auth.ml:23-26` `http_auth_strict_enabled`.
  - `lib/server/server_routes_http_routes_dashboard.ml:445-466`: loopback bind이고 strict가 아니면 `with_public_read` 뒤에 token을 내준다.
  - `lib/server/server_routes_http_dashboard_dev_token.ml:19`: `dashboard_dev_role = Masc_domain.Admin`.
  - `lib/auth/authz_boot_mode.ml` `judge`: 다계정 거부 사유는 `Auth_disabled_in_multi_account`, `Token_not_required_in_multi_account`, `Anonymous_mutations_in_multi_account`, `Auth_settings_unreadable_in_multi_account` 넷이다. strict는 없다.
  - `server_auth.ml` `board_access_for_request`: token이 없으면 strict일 때 `Anonymous`, 아니면 `Operator`.
  - `bin/masc_cli_auth.ml:157, 205-212`: 미리보기는 `127.0.0.1`에 묶인다.
- 확인한 방법: 코드 읽기. 실행은 하지 않았다.
- 신뢰도: High(코드).

### F3 (P1) 턴 판정은 누가 시작했는지 모른다

- 내용: `Authz_keeper_turn.decide_on`은 initiator와 executor를 늘 Keeper 소유자로 둔다. runtime은 채널을 `Autonomous`·`Direct` 둘만 낸다.
- 무엇이 틀렸나: B의 Keeper 큐에 메시지를 넣는 문이 하나만 열려도 A가 B의 구독으로 턴을 돌린다. 후보는 MCP `masc_keeper_msg`, `/api/v1/keepers/chat/stream`, `/api/v1/gate/message`, 커넥터, board다.
- 근거:
  - `lib/auth/authz_keeper_turn.ml:139-179` `decide_on`. 152-153행이 `initiator = owner`, `executor = owner`.
  - `lib/keeper/keeper_agent_run.ml:478-480` `channel_of_turn_kind`: `Autonomous`, `Direct`만 있다.
  - `lib/keeper/keeper_turn_driver.ml:272-276` `account_request`: fleet 턴은 `Keeper_turn { keeper_name; channel; runtime_id }`.
  - `lib/runtime/runtime_account_access.ml:247-268`: Keeper 이름 문자열을 `Keeper_id.of_string`으로 읽어 로그의 Keeper와 맞춘다.
  - `lib/auth_preview_keeper.ml:49`: 미리보기가 만드는 Keeper의 채널 범위는 `Autonomous`, `Direct`.
  - `lib/server/server_routes_http_routes_keepers.ml:49`(`Tool_actor Keeper_delegate`), `lib/server/server_routes_http_routes_channel_gate.ml:859`(`Tool_actor channel_gate`).
- 확인한 방법: 턴 판정과 채널 대응을 읽었다. 메시지 진입점 전수는 세지 않았다.
- 신뢰도: High.

### F4 (P1) internal keeper token은 프로세스에 하나이고 Keeper 이름은 헤더가 정한다

- 내용: `x-masc-keeper-name`이 말한 이름이 그대로 호출자가 된다. 토큰은 `MASC_INTERNAL_MCP_TOKEN` 하나다.
- 무엇이 틀렸나: 한 사람의 Keeper 프로세스가 그 토큰을 가지면 다른 사람의 Keeper 이름을 호출자로 댈 수 있다. 그러면 그 Keeper로 board에 쓰고 도구를 부른다.
- 근거:
  - `lib/server/server_auth.ml:190-202` `resolve_agent_name_for_auth_raw`.
  - `lib/auth/auth_credential_base.ml:150-200` `verify_internal_keeper_token` (hash 파일 비교).
  - `lib/server/server_mcp_transport_http.ml:539-558`: `is_verified_internal_keeper_request`로 `internal_keeper_runtime`을 정한다.
- 확인한 방법: 코드 읽기. 토큰이 sandbox 안에 닿는지는 추적하지 못했다.
- 신뢰도: Medium.

### F5 (P1) gRPC `ToolCall`은 인증과 호출자 없이 `execute_tool_eio`를 부른다

- 무엇이 틀렸나: gRPC가 켜진 다계정 서버에서 호스트의 아무 프로세스가 아무 도구나 실행한다.
- 근거:
  - `lib/server/server_runtime_bootstrap.ml:1849-1867` `tool_dispatcher`.
  - `lib/server/server_grpc_listener.ml:64` (loopback listen), `lib/server/masc_grpc_server.mli` (기본 포트 8936, `MASC_GRPC_ENABLED=1`).
  - `lib/server/server_grpc_tool_dispatch.ml`: JSON 모양만 본다.
  - `lib/server/masc_grpc_service.ml`: rg로 인증 코드를 찾지 못했다. broadcast는 `from_agent:req.agent_name`을 그대로 쓴다.
- 확인한 방법: dispatcher는 읽었고 service 본문은 rg로만 봤다.
- 신뢰도: High(dispatcher), Medium(기동 조건).

### F6 (P2) "전부 Auth_gate로"만으로는 안 닫히는 경로가 있다

- 내용: `need_of`가 `Nothing_needed`로 두는 종류가 사람 소유 데이터를 낸다.
- 대상:
  - `/health?full=1`: Keeper 이름, 멈춘 Keeper, base path 진단.
  - `/api/v1/gate/events`, `status`, `connectors`, `connector/status`, `health`: 커넥터 이벤트. `events`는 `channel`, `keeper`, `workspace_id`로 거른다.
  - `/api/v1/msx/carts`.
  - capability URL: voice audio prefix, `/api/v1/published-artifacts/`.
- 근거:
  - `lib/auth_gate.ml` `need_of`: `Always_public`과 `Public_read Open_when_strict` → `Nothing_needed`.
  - `lib/server/server_routes_http_routes_channel_gate.ml:863-883` (등록), 182-200행 (`handle_gate_events`).
  - `lib/server/server_routes_http_runtime.ml` 100-304행, 1780-1889행 범위 (`/health`).
  - `lib/server/server_routes_http_routes_published_artifacts.ml:218` (등록), 107-121행 (`capability_read`).
- 확인한 방법: 등록 줄과 핸들러 일부를 읽었다. `/health?full=1` 필드 전체는 읽지 않았다.
- 신뢰도: High(종류), Medium(본문 필드).

### F7 (P2) `Auth_gate` 결과가 핸들러를 묶지 않는다

- 내용:
  - `allowed`는 값일 뿐이다. 핸들러가 무시하고 `state`로 운영자처럼 동작해도 타입이 막지 않는다. `Judged_by_route`와 `Anonymous`에는 principal이 없다.
  - `Server_route`의 GADT에 `Manage_own_provider`, `Manage_own_keeper`가 없다. 미리보기 경로는 표에 `Self_authenticated Browser_session`으로 적히고 실제 판정은 핸들러 안에서 한다.
  - `Mcp_transport`, `Websocket_upgrade`, `Subpath_dispatch`는 `Holds CanReadState` 하나다. `/mcp/operator`(CanAdmin)와 `/api/v1/keepers/` 하위 경로의 실제 권한을 반영하지 못한다.
- 근거:
  - `lib/auth_gate.ml`(307줄), `lib/auth_gate.mli`(114줄) 전체.
  - `lib/http_server_eio.ml:496-897` `Router.Make_typed`, `lib/server/server_route.ml`.
  - `lib/server/server_login_http.ml`: `access = Server_route.Self_authenticated Route_access.Browser_session`.
  - `lib/server/server_routes_http_routes_keepers.ml:83-163` (GET 하위 경로: Admin, read, public이 섞임), 221-330행 (POST 하위 경로).
- 확인한 방법: 파일 전체 읽기.
- 신뢰도: High.

### F8 (P2) 미리보기 경로가 운영자 경로와 겹친다

- 내용: `POST /api/v1/setup/accounts/login`과 prefix `GET`·`POST /api/v1/setup/accounts/login/`가 `Token_permission CanAdmin` + `Operator { actor }`로 이미 있다. 미리보기는 같은 경로를 `Person`으로 등록한다. `GET /`(대시보드 redirect와 홈), `POST /`(MCP 별칭)도 겹친다.
- 무엇이 틀렸나: S1이 로그인 경로를 `make_routes`에 달면 등록 순서에 따라 한쪽이 조용히 가려진다. 사람의 로그인이 401이 되거나 운영자 로그인이 사라진다.
- 근거:
  - `lib/server/server_routes_http_routes_setup.ml` (줄 번호 미기록).
  - `lib/server/server_login_http.ml` `add_preview_routes`.
  - `lib/http_server_eio.ml:496-897`: exact 경로는 `Hashtbl.replace`, prefix는 같은 길이면 최신이 앞.
  - `lib/server/server_setup_account_login.ml:48-50` (`owner`), 85-98행 (`finish`: 운영자는 setup registry에 게시, 사람은 권한 로그에 연결), 180-186행 (`account_request`).
  - `lib/server/server_routes_http_routes_frontend.ml`: `GET /`는 `Always_public`, `POST /`는 `handle_post_mcp`.
  - `bin/masc_cli_auth.ml:224-228`: 미리보기는 빈 Router에 로그인과 미리보기 경로만 단다.
- 확인한 방법: 두 등록 파일과 Router를 읽었다.
- 신뢰도: High.

### F9 (P2) session origin에 다른 HTML이 얹힌다

- 내용: `GET /auth/session`은 cookie를 가진 same-origin 요청에 CSRF token을 준다. 실제 서버는 같은 origin에서 `/dashboard`, `/play`, graphiql, artifact 경로를 서빙한다.
- 무엇이 틀렸나: 그중 사용자 작성 HTML을 실행하는 경로가 있으면 그 script가 token을 읽어 로그인한 사람으로 행동한다. 어느 경로가 그런지는 추적하지 못했다.
- 덧붙임: `Server_auth.get_origin`은 요청 Origin을 그대로 돌려주고 `cors_headers`가 `access-control-allow-credentials: true`를 붙인다. 사람 로그인 SSE가 이 헤더를 쓴다. 지금은 gate가 cross-origin을 거절해서 막힌다.
- 근거:
  - `lib/auth/login_routes.ml:475-485` `session`.
  - `lib/server/server_auth.ml:791-798` `get_origin`, 826-839행 `cors_headers`.
  - `lib/server/server_setup_account_login.ml:156-159`.
  - `lib/auth/authz_browser_request.ml:12` (cookie는 `Secure; HttpOnly; SameSite`), `lib/auth/authz_browser_request.mli:21-24` (session cookie는 `SameSite=Strict`).
  - `lib/auth/authz_browser_request.ml` `unsafe_needs`: Safe+Other_origin → `Cross_origin`. `lib/server/server_login_http.ml` `origin_of`: `Allowed_dev_origin`도 `Other_origin`.
- 확인한 방법: 코드 읽기. same-origin 사용자 HTML의 존재는 확인하지 못했다.
- 신뢰도: Medium.

### F10 (P3) 정리

- 이름 존재가 드러나는 409 두 곳: Keeper 이름(`lib/auth_preview_keeper.ml` `make`, "Another person has a Keeper of this name."), Runtime id(`lib/server/server_setup_account_login.ml:418`).
- `load_auth_config`를 요청마다 다시 읽는다 (`lib/auth/auth.ml` 100-313행 범위). 부팅 때 본 설정과 실행 중 설정이 어긋날 수 있다.
- `handle_delete_mcp`는 인증만 통과하면 헤더의 아무 `Mcp-Session-Id`나 끝낸다 (`lib/server/server_mcp_transport_http.ml` 1230-1348행 범위).
- 계획 §2의 "H2 match가 따로 있다"는 낡았다 (`docs/superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md`).
- 미리보기는 `Server_http_ingress.serve`를 거치지 않고 `Router.dispatch`를 바로 부른다 (`bin/masc_cli_auth.ml:164-180`). 실제 서버는 rate limit, MCP 사전 검사, workspace precondition, Router 밖 갈래 4개를 먼저 지난다. 미리보기에서 잰 동작이 그대로 옮겨지지 않는다.
- 신뢰도: High.

### DO 6: 미리보기 표면의 소유권 검사

로그인 8 + 미리보기 12 경로에서 남의 Keeper·Runtime을 id로 읽거나 바꾸는 길은 찾지 못했다.

- 목록: `lib/auth_preview.ml` `provider_accounts`는 `Authz_provider_account.owned`와 `Authz_runtime.owned`만 낸다. `lib/auth_preview_keeper.ml` `list`는 `Authz_keeper.owned`.
- 만들기·배정: `lib/auth/authz_keeper_state.ml:85-95` `make`(남을 위해 만들면 `Made_for_another`), 97-112행 `assign`(`Assigned_by_another`, `Not_the_owners_runtime`), 116-129행 `apply`(service와 system author 거절).
- 턴: `lib/server/server_preview_keeper_turn.ml:51-71` `assigned`가 소유자를 대조하고 남의 Keeper는 404로 답한다. 284-286행에서 `Runtime_account_access.authorize`를 거친다.
- 검증: `lib/server/server_setup_account_login.ml:350-378` `person_runtime`(353-355행이 account 소유자 대조), 412-426행 `record_runtime`.
- 로그인: 같은 파일 53-55행 `actor_of`가 세션과 receipt를 `Session.Person user_id`로 나눈다. 108행은 사람의 Antigravity를, 113행은 사람의 `account_ref`를 거절한다. 저장 쪽 구현(`Runtime_setup_login_session`, `Runtime_setup_login_receipt`)은 읽지 않았다.
- allowlist: `lib/auth/login_allowlist_routes.ml:97-124`. session을 읽고 Admin 여부는 commit 때 상태가 판정한다.
- 남는 것: 사람의 로그인은 공용 runtime 설정의 `cli_path`를 읽어 실행한다 (`server_setup_account_login.ml:104-106`). 이 값을 HTTP로 바꿀 수 있는지는 추적하지 못했다. F1의 legacy Admin 경로가 열려 있으면 위험해진다.

## 3. 최소 변경 (문 체크리스트)

- [ ] 다계정 부팅은 `make_routes`를 쓰지 않고 표를 따로 만든다: 로그인 8, 미리보기 12, `/health/live`. 닫을 문 385개를 세는 것보다 열 문 21개를 세는 쪽이 작다.
- [ ] `Server_http_ingress.dispatch_route`의 Router 밖 갈래 4개를 다계정에서 닫는다.
- [ ] gRPC listener, WS handler, 커넥터 gateway 5개, owner lane과 Keeper fleet을 다계정에서 띄우지 않는다.
- [ ] dev-token, `/oauth/*`, `/mcp*`, `POST /`가 다계정 표에 없음을 시험으로 고정한다 (설계 §5.3의 "모든 항목 Reject" 시험).
- [ ] 다계정 표에 non-strict 분기가 없게 한다. 또는 strict를 부팅 조건에 넣는다.
- [ ] `masc login`, TUI mint, `ensure_local_operator`가 다계정 workspace에서 거절한다.
- [ ] `initialize_owner_state_blocking ~single_user`의 `single_user`를 다계정에 만들어 주지 않는다. 다계정용 값을 따로 둔다.
- [ ] `/api/v1/setup/accounts/login*`, `GET /`, `POST /` 충돌을 없앤다.
- [ ] Keeper 큐에 메시지를 넣는 진입점이 소유자 세션 하나뿐임을 시험한다 (F3).
- [ ] `/health`는 다계정에서 live·ready만 낸다.

## 4. 읽지 않은 것

- schedule runner, board attention이 Keeper를 깨우는 길, `Keeper_owner_registry.submit_operation` 뒤쪽.
- `lib/server/server_mcp_transport_ws.ml`, `lib/server/masc_grpc_service.ml` 본문 (rg로만 봄).
- `Authz_pat`, `Authz_service_credential`, `Authz_zone`, `Runtime_setup_login_session`, `Runtime_setup_login_receipt`.
- `/oauth/authorize`의 승인 논리, Play 경로, IDE LSP proxy, `/api/v1/keepers/` POST 분기 330행 뒤.
- `/health?full=1` 필드 전체, `lib/server/server_auth.ml:845-960`.
- egress proxy, browser addon, exec shim, microVM agent socket.
- internal token이 sandbox에 닿는지, 같은 origin에서 사용자 작성 HTML을 실행하는 경로가 있는지.
- `Server_routes_http_browser_surface.add_routes`를 부르는 곳 (rg로는 `.view`만 나옴).
- `Server_auth_config`의 dev origin 목록이 실제로 무엇을 여는지.
- 인벤토리 도구를 돌리지 않았다. 표의 수는 등록 호출 수이고 경로 수와 다를 수 있다.

## 부록 A. credential별 표 (DO 2)

| credential | 받는 곳 | 지금 래퍼가 하는 일 | `Auth_gate.decide` | 다계정 부팅 뒤 |
|---|---|---|---|---|
| workspace secret (bearer) | `lib/auth/auth.ml` `resolve_role_with_auth_config` | Admin (recovery grace) | `Legacy_bearer` → `Legacy_credential_forbidden` | 래퍼가 남아 있으면 연다 |
| agent bearer | `Server_auth.request_auth_credential_from_request`, `lib/auth/auth_credential_token.ml` 320-345행·820-870행 범위 | credential의 role | 같음 | 연다. 새로 찍는 곳: `masc login`, TUI, dev-token, `ensure_local_operator` |
| MCP OAuth token (`mat_`) | `find_credential_by_token`이 OAuth access token을 먼저 본다. 발급은 `/oauth/*` | credential의 role | `Mcp_oauth_token_not_bound` | 연다 |
| internal keeper token + `x-masc-keeper-name` | `server_auth.ml:190-202`, `lib/auth/auth_credential_base.ml` 150-200행 범위 | Worker. 호출자 이름은 헤더 | `Legacy_bearer` → 거절 (`x-masc-internal-token`도 Legacy_bearer로 읽는다) | 연다 |
| query credential (`?token=`) | `GET /mcp?sse_kind=observer`, `/events/presence`, `/api/v1/ide/lsp` | 그 세 곳에서 받는다 | `Query_credential` 거절 | 연다 |
| credential 없음 | `with_public_read`(non-strict), dev-token, `/ws` upgrade(Origin), board `Operator` | 연다 | `No_credential`은 `Nothing_needed` 종류에서 `Anonymous` | non-strict면 연다 |
| agent 이름 헤더 (`x-gate-agent`, `x-masc-agent`, `x-masc-agent-name`, `?agent=`, `?agent_name=`) | `server_auth.ml` `agent_from_request` | 인증이 아니라 행위자 이름을 정한다 | 읽지 않는다 | 이름만 정한다 |
| session cookie `__Host-masc_session` + `x-masc-csrf-token` | 로그인·미리보기 경로 | 래퍼는 읽지 않는다 | `Session` → `Authz_browser_request.check` | Auth_gate가 판정 |
| PAT `mpat_`, service `msvc_` | `lib/auth/authz_credential_presentation.ml` | 미확인 | `Pat`, `Service_credential` | Auth_gate가 판정 |
| 턴마다 새 bearer | `lib/runtime/runtime_official_client_mcp_http.ml:370-372` | 그 listener만 받는다 | 해당 없음 | 턴에 묶인다 |
| gRPC | 없음 | 인증 코드 없음 | 해당 없음 | 켜져 있으면 연다 |
| capability URL (voice audio, published artifact) | 각 경로 | token이 맞으면 연다 | `Nothing_needed` | 연다 |

부팅 설정: `Authz_boot_mode.judge`는 auth가 꺼졌거나, token이 필수가 아니거나, 익명 변경이 켜졌거나, 설정을 못 읽으면 다계정 부팅을 거부한다. strict는 보지 않는다. `Auth_gate`는 credential 조각이 둘 이상이면 `Several_credentials`로 거절한다.

## 부록 B. access kind별 표 (DO 3)

| kind | 실서버 등록 호출 | 지금 래퍼 | `Auth_gate.need_of` | 다계정에서 할 일 |
|---|---|---|---|---|
| `Always_public` | 14 | 없음 | `Nothing_needed` | live·ready만 남기고 나머지는 판정 |
| `Public_read` | 115 | strict가 아니면 무자격, strict면 legacy read | `Holds CanReadState` | 닫는다 |
| `Public_read_open_when_strict` | 10 | 늘 연다 | `Nothing_needed` | 닫는다. gate 5개, msx carts, voice audio, published artifacts가 사람 데이터다 |
| `Public_read_on_canonical_host` | 3 (`/dashboard`) | 늘 연다 | `Nothing_needed` | 대시보드 API가 닫혀 있는 동안 닫는다 |
| `Read_auth` | 11 | legacy read | `Holds CanReadState` | 닫는다 |
| `Permission p` | 16 | legacy role | `Holds p` | 닫는다 |
| `Token_permission p` | 137 | legacy token의 role, 행위자는 `cred.agent_name` | `Holds p` | 닫는다 |
| `Private_token_permission p` | 1 | 같음 | `Holds p` | 닫는다 |
| `Tool`, `Tool_observation`, `Tool_actor` | 12, 2, 36 | `Auth.authorize_tool`. token이 없으면 same-origin 검사 뒤 "dashboard" 행위자 | 카탈로그 권한. 없으면 `Unregistered_tool` | 닫는다 |
| `Self_authenticated Mcp_transport` | 13 | 핸들러의 `verify_*` | `Holds CanReadState` | 닫는다 |
| `Self_authenticated Oauth_protocol` | 10 | 핸들러 | `Not_served` | 닫는다 |
| `Self_authenticated Loopback_dev_token` | 1 | 핸들러 | `Not_served` | 닫는다 |
| `Self_authenticated Subpath_dispatch` | 2 | 하위 경로마다 다른 래퍼 | `Holds CanReadState` | 닫는다 |
| `ws_get` (`Websocket_upgrade`로 추정) | 2 | 핸들러 | `Holds CanReadState` | 닫는다 |
| `Self_authenticated Browser_session` | 미리보기 전용 18 | 없음 | `Judged_by_its_route` | 연다 |
| `Manage_own_provider`, `Manage_own_keeper` | 표에 없음 | — | `Own_provider`, `Own_keeper` | 표에 넣는다 |

## 부록 C. 집계 내역

- `Server_route.<fn>` 매치 408줄 (lib+bin): get 215, post 151, add 6, prefix_get 21, prefix_post 4, prefix_put 2, prefix_delete 4, ws_get 5.
- 주석 3줄(`server_mcp_transport_ws.ml:1188`, `.mli:287`, `server_http_ingress.ml:113`)과 미리보기 전용 `server_login_http.ml` 20줄을 빼면 385.
- 합: 14 + 115 + 10 + 3 + 11 + 16 + 137 + 1 + 50 + 26 + 2 = 385.
- 파일별 호출 수 상위: dashboard 76, activity 36, frontend 35, lane_addons 20, keepers 16, channel_gate 15, setup 14, workspace 13, delete_actions 12, runtime_config 11.
- `Always_public` 14: `/api/v1/board/flairs`, `/health`, `/health/live`, `/health/ready`, `/dashboard/assets/`, `GET /`, static·graphiql 자산 6, `/play` 페이지, `Play_invite.agent_guide_path`.
- `Open_when_strict` 10: favicon 2, `/api/v1/msx/carts`, voice audio prefix, `/api/v1/published-artifacts/`, `/api/v1/gate/health`·`status`·`connectors`·`connector/status`·`events`.
- `/ws` 프레임에서 credential 없이 통과하는 메서드 9개 (`lib/mcp_server_eio_protocol.ml:61-95` `require_auth`, 921-925행, 956-974행, 1000-1004행, 1074-1110행): `server/discover`, `initialize`, `ping`, `notifications/initialized`, `dashboard/hello`, `dashboard/subscribe`, `dashboard/unsubscribe`, `dashboard/ping`, `dashboard/ack`. 그 밖의 이름은 1385-1394행에서 `Method not found`로 답한다.
- `/ws`에서 broadcast를 받는 조건 (`lib/server/server_mcp_transport_ws.ml`, rg로만 봄): 442-465행 `verify_dashboard_token`이 static credential token의 CanReadState를 본다. 871행이 hello 전 이벤트를 버린다.
- listener (rg `Eio.Net.listen`, `Unix.bind`): 주 HTTP `lib/server/server_bootstrap_http.ml:50`, gRPC `lib/server/server_grpc_listener.ml:64`, official-client MCP `lib/runtime/runtime_official_client_mcp_http.ml:538`, Keeper egress `lib/keeper/keeper_keepalive.ml:535`, browser addon `lib/browser_addon_service.ml:91`·`lib/browser_addon_live_ego.ml:169`, exec shim `lib/exec_shim/shim_agent.ml:131`, 미리보기 `bin/masc_cli_auth.ml:230`, 포트 탐침 `lib/server/server_upgrade_preparation.ml:83, 109`·`bin/masc_cli_owner_upgrade.ml:26`, 그 밖 `lib/masc_http_client/pool.ml:127`·`bin/lane_fusion_container_probe.ml:241`(용도 미확인).
- 부팅 판정을 부르는 곳: `bin/main_stdio_eio.ml:78`, `lib/server/server_runtime_bootstrap.ml:1691` (`boot`), `lib/runtime/runtime_account_access.ml:100` (`tool`). `Auth_login.mint`와 `ensure_local_operator`(`lib/auth/auth_login.ml:66, 106`)는 부르지 않는다.
- 실제 서버가 게시하는 접근: `lib/server/server_runtime_bootstrap.ml:754`의 `Single_user single_user`. 미리보기는 `bin/masc_cli_auth.ml:198-204`에서 `Multi_account`를 게시한다. `Multi_account`에서는 `Operator_call` → `No_operator`(`runtime_account_access.ml:241`), 호스트 계정 → `Host_not_shared`(355-360행), native 도구는 `Native_none`만(409-420행).
- 커넥터 inbound가 Keeper에 닿는 길: `lib/server/server_discord_in_process_gateway.ml:640, 711`, `lib/server/server_telegram_in_process_gateway.ml:59`, `lib/server/server_imessage_in_process_gateway.ml:202-205`, `lib/server/server_slack_in_process_gateway.ml:312` → `Channel_gate.handle_inbound` → `lib/gate_keeper_backend.ml:52`(`agent_name_for_channel_actor`), 257-265행(`submitted_by`), 294행(`Keeper_owner_registry.submit_operation`). 채널과 Keeper의 묶음은 `/api/v1/gate/connector/bind`(`server_routes_http_routes_channel_gate.ml:913`, `Tool channel_gate`)가 정한다.
