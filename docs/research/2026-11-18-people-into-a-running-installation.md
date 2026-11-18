# Keeper 가 돌고 있는 설치에 사람을 들이려면 — 두 서버의 차이와 설계가 비워 둔 곳

- 날짜: 2026-11-18
- 관련 문서: [설계](../superpowers/specs/2026-10-27-multi-account-oidc-runtime-authorization-design.md), [계획](../superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md). 아래에서 "설계", "계획"은 이 둘이다.
- 코드 사실: main `ca39efe2128f` 에서 읽었다. 줄 번호도 그 커밋 기준이다.
- 경로 수: `tools/auth_route_inventory` 의 2026-11-17 빌드(main `467cfe8e8373`)가 낸 값이다.
- 한 일은 읽기와 세기뿐이다. 서버를 띄우거나 요청을 보내지 않았다.
- 이 문서는 연구 기록이다. 무엇을 만들지는 설계와 계획이 정한다.

## 0. 요약

- 풀려는 사용예는 이것이다. 단일 사용자로 Keeper 를 돌리던 설치에 운영자가 사람을 초대한다. 초대받은 사람은 같은 서버의 Dashboard, Board, Keeper 를 같이 쓴다.
- 지금 한 boot 는 두 서버 중 하나만 띄운다. 단일 사용자 서버에는 Keeper 엔진이 있고 사람이 없다. 계정 서버에는 사람이 있고 Keeper 엔진이 없다.
- Keeper 엔진은 Keeper 를 이름으로 찾는다. Keeper 기록에 주인이 없다. 도구 호출의 행위자도 그 이름이다.
- 사람의 Keeper 턴은 메시지 하나를 공식 CLI 에 넘기는 호출이다. 지시문, 기억, MASC 도구, 스스로 시작하는 턴이 없다.
- `Auth_gate.decide` 는 경로 종류를 전부 판정할 줄 안다. 그런데 계정 서버의 경로표가 받는 종류는 셋뿐이다. 나머지 경로의 handler 가 단일 사용자의 credential 저장소를 읽기 때문이다.
- 설계는 주인, 실행 주체, 채널, 귀속의 규칙을 이미 정했다. 비어 있는 것은 넷이다(§8).

## 1. 풀려는 사용예와 설계의 자리

설계 §1 은 이렇게 시작한다.

> 한 머신에서 MASC를 실행하고, 초대받은 사용자만 Google OIDC나 GitHub 계정으로 Dashboard에 로그인한다. 각 사용자는 자신의 Codex 또는 Claude Code 구독을 등록하고 기본적으로 본인만 Runtime을 사용한다.

목표 4 는 "직접 호출·Keeper·schedule·Board·retry·resume·Fusion·vision·failover에서 같은 인가 모델을 적용한다"이다. Keeper 엔진 전체가 다계정에서 도는 것이 설계의 끝 상태다.

지금 만든 것은 그 앞부분이다. 계획 S1a 와 S1b 가 계정 서버를 열었다. 사람은 로그인하고, 구독을 연결하고, Keeper 를 만들고, 그 Keeper 에게 묻는다.

이미 돌던 설치를 다계정으로 넘기는 일은 설계 §10.3(귀속)과 §10.5(모드 전환)가 다룬다. 계획에서는 F4 이고 2단계다(계획 1386행).

## 2. 한 boot 는 두 서버 중 하나만 띄운다

`Server_runtime_bootstrap` 이 base path 의 모드를 읽고 갈래를 고른다(`server_runtime_bootstrap.ml:2296`, `Authz_boot_mode_read.boot`).

| 판정 | 띄우는 것 | 좌표 |
|---|---|---|
| `Multi_account` | `Server_accounts.run` | `server_runtime_bootstrap.ml:2320` |
| `Single_user` | `run_single_user` | `server_runtime_bootstrap.ml:2330`, 정의는 `:1638` |

계정 서버의 mli 가 자기에게 없는 것을 적어 둔다(`server_accounts.mli:8-13`).

> This server builds no [Mcp_server.server_state], starts no Keeper, and registers none of the routes whose wrappers read the credentials of a single user ([Server_auth]).

단일 사용자 갈래만 만드는 것을 묶으면 이렇다. 함수 이름은 모두 `server_runtime_bootstrap.ml` 과 `server_bootstrap_loops.ml` 에 있다.

| 묶음 | 하는 일 | 대표 함수 |
|---|---|---|
| 서버 상태 | `Mcp_server.server_state` 를 만든다. Keeper 기억 lane, Librarian 대기열, Keeper 등록부 관찰자, Dashboard 방송이 여기서 붙는다 | `create_server_state`, `initialize_owner_state_blocking` |
| 작업 공간 | Board, task, agent 저장소를 열고 SSE 방송을 건다 | `bootstrap_server_state_blocking`(`Workspace.init`) |
| Keeper 주인 등록부 | 저장소에서 Keeper 주인을 올리고 턴 자리 깨우기를 건다 | `Keeper_owner_registry.install_from_store` |
| Keeper 루프 | 이벤트 버스, Board 글이 Keeper 를 깨우는 hook, Keeper 마다 keepalive 를 시작한다 | `start_keeper_loops`(`Board_dispatch.set_board_signal_hook` `:1707`, `keeper_autoboot` `:1957`) |
| 도구 실행 | MCP 도구 호출을 받아 실행한다 | `Mcp_server_eio_execute.execute_tool_eio` |
| 곁일 | 완료 판정, Goal 검증, candle, sandbox 정리, Discord·Slack 연결 | `Server_auxiliary_startup.run_all`, `start_post_ready_owner_lanes` |
| 경로 | Dashboard, Keeper·Board API, MCP endpoint | `Server_routes_http.make_routes_with_transport` |

- 단일 사용자 갈래는 시작할 때 `Runtime_account_access.Single_user` 를 공표한다. 계정 서버는 `Multi_account` 를 공표한다. 자격 증명을 꺼내는 판정(`Runtime_account_access.authorize`)이 이 값을 읽는다.
- 두 서버가 같이 쓰는 것은 listener 코드, Host·Origin 확인과 주소별 한도(`Server_http_ingress`), 환경의 HTTP 설정이다(`server_accounts.mli:15-19`). `Auth_gate` 는 다계정 요청만 판정한다. 단일 사용자 요청은 옛 함수가 판정한다(설계 §5.3, 2026-11-07 결정).

## 3. Keeper 의 신원은 이름이다

- Keeper 의 실행 기록은 `keeper_meta` 다(`keeper_meta_contract.mli`). `name`, `instructions`, sandbox 설정, `runtime` 같은 필드가 있다. 주인을 가리키는 필드는 없다. `owner`, `principal`, `user_id` 로 찾으면 Keeper 턴 번호의 주석 한 줄만 나온다.
- Keeper 정의는 TOML 파일이다. 자리는 `<config root>/keepers/<이름>.toml` 이다(`Config_dir_resolver.keeper_toml_path_for_base_path`). 여기도 주인이 없다.
- 등록부는 프로세스에 하나이고 열쇠는 `base_path ^ "\x1f" ^ name` 이다(`keeper_registry_types.ml:200`).
- `lib/` 에서 `keeper_name` 은 1,189개 파일에 11,647번 나온다. `meta.name` 은 156개 파일에 1,170번 나온다(`rg -c`, 2026-11-18).
- 권한 로그의 Keeper 는 다르게 찾는다. 설계 §4.3 은 "로그의 Keeper는 (owner, 이름) 쌍으로 찾는다"고 정했다. 두 사람이 같은 이름을 쓸 수 있고, 운영자의 TOML Keeper 와 이름이 같아도 다른 Keeper 다(설계 156행, 2026-11-12 결정).

## 4. 도구 호출의 행위자도 이름이다

- Keeper 가 엔진 안에서 도구를 부르면 행위자는 `meta.name` 이다. 예: `Tool_agent.context = { config; agent_name = meta.name }`(`keeper_tool_in_process_runtime.ml:2064`), `Workspace_dispatch_ref.dispatch ~config ~agent_name:meta.name`(`:2080`).
- 이 길에는 token 도 principal 도 없다. Board 글의 작성자는 그 이름 문자열(`Agent_id.t`)이고, Board 의 읽기 규칙은 Direct 수신자만 강제한다(계획 1174행).
- 바깥에서 HTTP 로 부르면 `Mcp_server_eio_caller_identity.resolve` 가 행위자를 정한다. 이름은 `_agent_name` 인자에서 오고, HTTP transport 가 token 주인의 이름으로 바꿔 넣는다(`Server_mcp_actor_injection.inject_agent_name_into_body`).

## 5. 사람의 Keeper 턴이 하는 일

진입은 `Server_preview_keeper_turn.run` 이다. 경로는 `POST /api/v1/auth/keepers/turn` 이고, 사람의 MCP 도구 `masc_my_keeper_turn` 도 같은 함수를 부른다.

| 항목 | 지금 |
|---|---|
| 입력 | `{"keeper_id","message"}` 뿐. 메시지는 4,096 byte 까지(`:10`), 턴은 120초(`:11`) |
| Keeper 와 Runtime | 권한 로그의 기록에서 읽는다. Keeper TOML 을 쓰지 않는다 |
| 인가 | `Runtime_account_access.Keeper_turn { owner; keeper_id; channel = Direct; … }` 를 `authorize` 가 판정한다 |
| 모델에 가는 것 | 메시지 그대로(`~prompt:message`, `:285`). system prompt, 지시문, MASC 도구, 기억이 없다 |
| Claude Code | 대화를 이어 간다. 턴마다 `asked`, `answered` 또는 `failed` 를 `turns.jsonl` 에 쓴다 |
| Codex | 임시 폴더의 일회용 thread. 남기는 것이 없다 |
| 거절하는 Runtime | `Antigravity_cli`, `Muse_serve`, `Vibe_cli`, `Agent_core` 는 `Runtime_not_supported` |

- 사람의 MCP 도구는 아홉이다. `masc_whoami`, `masc_my_runtimes`, `masc_my_keepers`, `masc_my_keeper_create`, `masc_my_keeper_assign`, `masc_my_keeper_turn`, `masc_my_keeper_conversation_new`, `masc_my_keeper_conversation`, `masc_my_keeper_conversation_delete`(`server_person_mcp.ml:66-74`).
- 계획 S1b-3 은 이 조각이 하지 않는 것을 적었다. "Keeper 지시문과 system prompt, 기억, MASC 도구, 스스로 시작하는 턴, Board, Codex"(계획 1287행).
- `Agent_core` Runtime 을 거절하므로, HTTP provider 로 도는 Keeper 는 이 길로 돌릴 수 없다. 다계정 프로세스는 실행 표의 API provider 자격 증명도 꺼내 주지 않는다(`authorize_api` 가 `Host_account Api_provider` 로 거절, 계획 698행).

## 6. 경로와 판정

`Route_access.t` 의 종류는 열둘이다(`route_access.mli`). `Auth_gate.decide` 는 이것을 모두 판정한다(`auth_gate.ml`, `need_of`).

| 경로 종류 | `decide` 가 요구하는 것 |
|---|---|
| `Always_public`, `Public_read Open_when_strict` | 없음 |
| `Public_read Credential_when_strict`, `Read_auth` | `CanReadState` |
| `Permission p`, `Token_permission p`, `Private_token_permission p` | `p` |
| `Tool`, `Tool_observation`, `Tool_actor` | 그 도구의 `required_permission` |
| `Manage_own_provider`, `Manage_own_keeper` | 자기 것 |
| `Self_authenticated (Browser_session \| Person_mcp)` | 경로가 스스로 판정 |
| `Self_authenticated (Oauth_protocol \| Loopback_dev_token)` | 다계정에서 내주지 않음 |
| `Self_authenticated (Mcp_transport \| Websocket_upgrade \| Subpath_dispatch)` | `CanReadState` |

계정 서버의 경로표는 이 가운데 셋만 받는다. `Always_public`, `Self_authenticated Browser_session`, `Self_authenticated Person_mcp` 다(`server_account_table.ml:22-41`). 이유가 주석에 있다.

> A route of any other kind reads the credentials of a single user, through a wrapper of [Server_auth] or in its own handler.

단일 사용자 서버의 경로는 386개다.

| 종류 | 수 |
|---|---|
| `token_permission` | 137 (`CanAdmin` 116, `CanPlayMachine` 9, `CanReadState` 8, `CanBroadcast` 3, `CanVote` 1) |
| `public_read` | 130 |
| `tool_actor` | 39 |
| `self_authenticated` | 28 |
| `always_public` | 14 |
| `permission` | 12 |
| `tool` | 12 |
| `read_auth` | 11 |
| `tool_observation` | 2 |
| `private_token_permission` | 1 |

- `/api/v1/dashboard` 로 시작하는 경로는 89개다.
- 판정은 "이 사람이 이 종류의 경로를 부를 수 있는가"까지 답한다. "이 경로가 누구의 것을 읽는가"는 답하지 않는다. 설계 §4.2 는 원칙만 적었다. "다른 사람의 ID 존재·이름·오류는 projection으로 제한한다"(설계 125행).

## 7. 설계와 계획이 이미 정한 것

| 주제 | 정한 것 | 자리 |
|---|---|---|
| Keeper 의 주인 | 1단계에서 사람의 Keeper 는 주인 한 명의 것이다. 턴은 주인의 Self grant 로 인가한다 | 설계 155행 |
| 남의 글이 깨운 턴 | "다른 사람의 Board 글이 Keeper를 깨워도 실행하는 쪽과 쓰는 구독은 owner의 것이다" | 설계 155행 |
| 턴의 당사자 | initiator 와 executor 는 둘 다 Keeper 주인이다. Board 글을 쓴 사람은 턴의 입력이다 | 계획 D2 범위 |
| 채널 | Direct, Delegate, Schedule, BoardTrigger, Retry, Resume 등으로 닫힌다. "Board 작성 권한이 Runtime·tool 권한을 의미하지는 않는다" | 설계 209행 |
| 바깥 initiator | Delegate, Schedule, BoardTrigger 는 맞는 DelegatePolicy 가 있어야 한다. 2단계다 | 설계 396행 |
| 예약 | 사람의 schedule 이 cron 으로 발화해도 initiator 는 그 사람이다 | 설계 398행 |
| Keeper 상태의 주인 표시 | 지속 상태는 만든 dispatch 의 initiator 를 표시한다. 다른 initiator 에게는 `Read_state` 가 허용될 때만 보인다 | 설계 §3-11, 계획 D6 |
| 공식 CLI 실행 | 주인과 실행 주체가 같은 private 실행만 격리 아래 허용한다. 호스트에서 직접 도는 경로는 다계정에서 열지 않는다 | 설계 §7.2 |
| 운영자 Keeper | 다계정에는 운영자 Keeper 가 없다. 그 턴은 `No_operator_keeper` 로 거절한다 | 계획 614행 |
| 호스트 자격 증명 | 실행 표의 provider 자격 증명은 호스트 계정이다. 다계정은 꺼내 주지 않는다 | 계획 698행 |
| 최초 활성화 | 주인 없는 자산은 bootstrap principal 을 후보로 귀속한다. 후보가 provider 재인증과 credential 결속을 끝내고 claim 해야 새 Self grant 가 생긴다. claim 이 없으면 Disabled 다 | 설계 §10.3 |
| 옛 작업 | 최초 활성화 전에 initiator 없이 기록된 작업은 `Denied(legacy_unattributed)` 다. Service 신원으로 바꿔 살리지 않는다 | 설계 §10.5 |
| Runtime 공유 | Delegated 와 MachineShared 는 2단계다 | 설계 157-158행, 계획 D5 |

## 8. 비어 있는 것

1. **다계정 프로세스가 Keeper 엔진을 띄우는 층이 없다.** 계획의 층 목록에서 엔진(지시문, 기억, 도구, 스스로 시작하는 턴)을 다계정에 올리는 층을 찾지 못했다. S1b-3 은 그것들을 "하지 않는 것"으로 적었다. 계정 서버는 `Mcp_server.server_state` 를 만들지 않는다.
2. **이름으로 도는 엔진과 (주인, 이름)으로 찾는 기록을 잇는 규칙이 없다.** 엔진의 등록부, 저장소 경로, 도구 행위자, Board 작성자가 모두 Keeper 이름 하나를 쓴다(§3, §4). 로그의 Keeper 는 사람마다 이름을 따로 센다. 한 작업 공간에서 두 사람의 같은 이름 Keeper 가 돌 때 엔진이 무엇으로 구분하는지 정한 곳이 없다.
3. **Board 를 누가 읽고 쓰는지가 없다.** 계획이 그대로 적었다. "다계정에서 Board를 누가 읽고 쓰는지, 남의 글이 Keeper를 깨우는지는 설계에 없다. 설계 절을 따로 써서 정한다(S1b-2)"(계획 1168행). WebSocket 과 Dashboard 도 같은 문단이 따로 정한다고 적었다.
4. **경로마다 누구의 것을 읽는지가 없다.** §6 의 386개 경로 가운데 계정 서버가 받는 것은 세 종류다. 나머지를 사람의 신원으로 열려면 경로마다 읽는 범위(자기 것, 작업 공간 공용, 운영자 것)가 정해져야 한다. 설계에는 projection 원칙 한 줄이 있다.

귀속(설계 §10.3, §10.5)은 기록의 규칙이 정해져 있다. 계획 F4 가 2단계라 구현이 없다. 이미 Keeper 가 도는 설치를 넘기려면 이 층이 있어야 한다.

HTTP provider 의 자격 증명이 호스트 계정이라는 결정(계획 D4)은 이 사용예에서 이렇게 읽힌다. API key 로 도는 Keeper 는 그 key 가 사람의 계정이 되기 전에는 다계정에서 돌지 못한다. [사람의 API key RFC](../rfc/RFC-a-persons-api-key-is-their-own-provider-account.md) §3.9 가 그 계약을 2단계로 적어 두었다.

## 9. 재지 못한 것

- 엔진을 다계정 프로세스에서 띄웠을 때 무엇이 깨지는지. 띄워 보지 않았다.
- Keeper 이름을 쓰는 11,647곳 가운데 이름이 작업 공간에서 유일하다고 가정하는 곳의 수. 세지 않았다.
- `/api/v1/dashboard` 89개 경로가 각각 무엇을 읽는지. 종류만 셌다.
- 공식 CLI 가 아닌 lane(remote ssh)에서 다른 사람의 홈을 읽을 수 있는지. `test/test_keeper_account_home_reach.ml` 은 Docker, microVM, 읽기 경로만 본다.
- 일정 저장소가 boot 의 어디에서 열리는지. boot 파일에서 찾지 못했다.
