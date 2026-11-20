# Keeper 가 돌고 있는 설치에 사람을 들이려면 — 두 서버의 차이와 설계가 비워 둔 곳

- 날짜: 2026-11-18
- 관련 문서: 설계(#46428), 계획(#46469). 아래에서 "설계", "계획"은 이 둘이다. 이 문서는 진행 중인 RFC(`docs/rfc/RFC-a-persons-keeper-runs-on-the-engine.md`)의 근거 자료이며 변경이 착지하면 함께 지운다(`docs/guides/WORKSPACE-STORAGE.md`).
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

- 엔진을 다계정 프로세스에서 띄웠을 때 무엇이 깨지는지. 띄워 보지 않았다. 읽어서 찾은 것은 §10 이다.
- Keeper 이름을 쓰는 11,647곳 가운데 이름이 작업 공간에서 유일하다고 가정하는 곳의 수. 세지 않았다.
- `/api/v1/dashboard` 89개 경로가 각각 무엇을 읽는지. 종류만 셌다.
- 공식 CLI 가 아닌 lane(remote ssh)에서 다른 사람의 홈을 읽을 수 있는지. `test/test_keeper_account_home_reach.ml` 은 Docker, microVM, 읽기 경로만 본다.
- event queue 가 디스크 어디에 쓰는지.
- MCP session 등록부와 SSE 처럼 §10.2 에 없는 전역이 두 번째 엔진을 거절하는지.
- 곁에서 부르는 호출(§11.6)이 거절된 뒤 Keeper 턴이 실패하는지 계속 가는지.
- 다계정 boot 가 exact-output 등록표를 만드는지. Librarian 과 HITL 요약이 그 표를 쓴다.
- 엔진의 Runtime 표를 돌고 있는 서버에서 바꾸는 길이 어디까지 닿는지.

## 10. 엔진을 계정 서버 프로세스에 올릴 때 걸리는 것 (2026-11-19)

- 읽어서 찾았다. 띄워 보지 않았다.
- main `1805632f31f6` 에서 읽었다. 이 절의 줄 번호는 그 커밋 기준이다.
- 개수는 적힌 `rg -o` 패턴이 낸 줄 수다.
- "조사만 함"이라고 적은 항목은 조사 agent 가 읽은 것이다. 나머지는 다시 읽어 확인했다.

### 10.1 엔진이 뜨는 길

- `Server_runtime_bootstrap.run`(`lib/server/server_runtime_bootstrap.ml:2338`)이 판정(`judge`, 2324행)에 따라 둘 중 하나를 부른다. `run_single_user`(1673행)이거나 `Server_accounts.run`(`lib/server/server_accounts.ml:194`)이다.
- `run_single_user` 는 `create_server_state`(392행)로 `Mcp_server.server_state` 를 만든다. Keeper 는 `lib/server/server_bootstrap_loops.ml` 의 `keeper_autoboot`(1957행)가 시작한다.
- 일정 저장소는 `.masc/schedules.json` 이다(`lib/schedule/schedule_store.ml:256`). 엔진이 준비된 뒤 뜨는 유지 작업이 일정을 돌린다(조사만 함). §9 에 있던 물음의 답이다.
- 계정 서버가 받는 것은 switch 하나, clock, net, 주소와 port, lease, 다계정 설정, 권한 zone 이다. 엔진은 그 밖에 runtime switch, process manager, fs, domain manager, `runtime.toml`, prompt 와 도구 정의, run registry 파일 넷, Keeper TOML 과 실행 기록, token 셋을 받는다(조사만 함).

### 10.2 한 프로세스에 엔진은 하나다

두 번째 설치를 거절하는 전역이다.

| 전역 | 자리 | 두 번째가 받는 답 |
|---|---|---|
| `Runtime_account_access.state` | `lib/runtime/runtime_account_access.ml:86` | `Already_published` |
| run registry 넷의 `Global.install` | `lib/fusion_core/fusion_run_registry.ml:392`, `lib/verification_run_registry.ml:599`, `lib/goal_verification_run_registry.ml:527`, `lib/exact_lane_run_registry.ml:1570` | `Already_installed` |
| `Board_dispatch.backend_state` | `lib/board/board_dispatch.ml:162` | 작업 공간이 다르면 `Workspace_mismatch` |
| `persistence_lifecycle` | `lib/server/server_bootstrap_loops.ml:630` | 조사만 함 |

- `Runtime_account_access.state` 는 계정 서버가 `Multi_account` 로 올리고(`server_accounts.ml:330`), 엔진이 `Single_user` 로 올린다(`server_runtime_bootstrap.ml:729`). 한 프로세스에서 둘 다 올릴 수 없다. 엔진을 계정 서버 프로세스에 올리는 층이 가장 먼저 만나는 자리다.

마지막에 쓴 값이 남는 전역이다.

- `resolved_base_path_cache`(`lib/workspace/workspace_utils_backend_setup.ml:151`). 값이 있으면 `resolve_masc_base_path` 는 인자를 보지 않고 그 값을 돌려준다.
- 환경 변수 `MASC_BASE_PATH` 와 token 둘, `Config_dir_resolver` 의 cache, `Runtime_params`, 이벤트 버스, Board hook(조사만 함).

읽는 법은 이렇다. 사람마다 엔진을 하나씩 띄우려면 이 전역을 먼저 걷어내야 한다. 지금 코드에서 한 프로세스의 엔진은 하나고 작업 공간도 하나다.

### 10.3 이름 하나로 찾는 것

| 종류 | 자리 | 주인 |
|---|---|---|
| 메모리 등록부 | key 가 base path 와 이름이다(`lib/keeper/keeper_registry_types.ml:196`) | 없음 |
| 도구 호출의 행위자 | `agent_name : string`(`lib/tool_agent.mli:6`) | 없음 |
| 실행 기록과 저장소 | `.masc/keepers/<이름>.json`, `.masc/keepers/<이름>/`(조사만 함) | 없음 |
| 정의 | `<config>/keepers/<이름>.toml`(조사만 함) | 없음 |
| Board 작성자, 일정, 대기열, mention, metric label, HTTP 경로 `/api/v1/keepers/<이름>/` | 조사만 함 | 없음 |

- 권한 로그는 Keeper 를 `(User_id.t * Keeper_id.t)` 로 찾는다(`lib/auth/authz_keeper_state.ml:9`).
- 사람의 Keeper 턴은 권한 로그에서 그 사람의 Keeper 와 Runtime 을 찾아 공식 CLI 를 부른다. 엔진의 등록부를 거치지 않는다(조사만 함, `lib/server/server_preview_keeper_turn.ml`).
- 타입이 붙은 이름 `Keeper_name.t` 는 `lib/` 에 37번 나온다(`Keeper_name\.t\b`).

### 10.4 base path 를 넘겨받는 곳과 전역에서 읽는 곳

- `Workspace.masc_dir` 는 언제나 `<base path>/.masc` 다(`lib/workspace/workspace_utils_paths_backend.ml:4`). 사람 루트(`<base>/.masc/accounts/<namespace>`)는 `Workspace.config` 로 가리킬 수 없다.

| 패턴 | 범위 | 수 | 뜻 |
|---|---|---|---|
| `Config_dir_resolver\.\w+_for_base_path` | `lib`, `bin` | 154 | base path 를 넘긴다 |
| `Config_dir_resolver\.(keepers_dir\|tools_dir\|prompts_dir) \(\)` | `lib`, `bin` | 6 | 전역 cache 에서 읽는다 |
| `Workspace\.default_config(_uncached)?\b` | `lib`, `bin` | 52 | 전역 base path cache 를 거친다 |
| `Runtime_params\.get\b` | `lib` | 67 | 전역 설정을 읽는다 |
| `\bcurrent_server_state\b` | `lib`(`.ml`) | 17 | 전역 server state 를 읽는다 |

## 11. 사람의 Keeper 를 엔진에서 돌릴 때 걸리는 것 (2026-11-19)

- 읽어서 찾았다. 띄워 보지 않았다. main `1805632f31f6` 기준이다.
- "조사만 함"이라고 적은 항목은 조사 agent 나 리뷰 agent 가 읽은 것이다. 나머지는 다시 읽어 확인했다.
- 개수는 `rg -o '\b이름\b' lib --glob '*.ml'` 이 낸 수다.

### 11.1 엔진이 띄울 이름을 읽는 곳은 하나가 아니다

| 곳 | 읽는 것 | 자리 |
|---|---|---|
| boot 의 autoboot | 실행 기록의 이름과 정의 파일의 이름 | `lib/server/server_bootstrap_loops.ml:1957` |
| supervisor sweep | 정의 파일의 이름. 실행 기록이 없어도 방식이 manual 이 아니면 띄운다 | `lib/keeper/keeper_supervisor_reconcile_keepalive.ml:46` → `lib/keeper/keeper_meta_store.ml:577` |
| boot 의 Keeper credential | 띄울 수 있는 이름마다 credential 을 만든다 | `lib/server/server_runtime_startup_credentials.ml:50`(조사만 함) |
| Keeper 를 만드는 길 넷 | MCP `masc_keeper_up`, `POST /api/v1/keepers/<이름>/up`, TUI, CLI | 조사만 함 |

- 실행 기록을 처음 쓰는 것은 언제나 `keeper_up` 이다. 정의 파일, 실행 표의 배정, 실행 기록을 한 번에 쓴다(조사만 함, `lib/keeper/keeper_turn_up_create.ml:56`).

### 11.2 Runtime 은 전역 실행 표에서 이름으로 읽는다

| 함수 | 곳 | 파일 |
|---|---|---|
| `runtime_id_of_meta` | 39 | 21 |
| `Runtime.get_runtime_by_id` | 32 | 18 |
| `Runtime.resolve_assignment` | 19 | 12 |

- `runtime_id_of_meta` 는 Keeper 이름의 배정을 읽고, 없으면 기본 route 를 돌려준다(`lib/keeper/keeper_meta_contract.ml:377`).
- 사람의 Runtime 은 그 표에 없다. `Login.person_runtime`(`lib/server/server_setup_account_login.ml:484`)이 호출마다 만든다. 실행 표의 template, 로그의 계정 기록, 계정의 홈, key 계정이면 지금 세대의 key 파일로 만든다.
- 그 함수는 계정의 호출 안에서만 불린다. 계정의 파일은 그 호출 안에서만 바뀐다.

### 11.3 계정당 한 번에 한 호출

- 설계 565행: "다계정에서 같은 ProviderAccount의 official dispatch는 항상 Single_flight다."
- 그것을 지키는 것은 `Login.one_call_of`(`server_setup_account_login.ml:450`)다. 호출이 돌고 있으면 기다리지 않고 거절한다.
- `lib/server` 의 여덟 파일이 쓴다(`\bone_call_of\b`). 사람의 턴, 로그인 뒤 확인, key 등록·바꾸기·없애기, 대화 시작·지우기다.
- 엔진의 턴은 시도마다 판정만 받는다. 이 호출을 잡지 않는다. `one_call_of` 는 서버 라이브러리에 있어서 엔진이 부를 수 없다(조사만 함, `lib/dune`, `lib/server/dune`).

### 11.4 턴을 깨우는 원인과 채널

- 엔진의 원인은 `Proactive_tick`, `Woken of stimulus list`, `Chat_request` 다(`lib/keeper/keeper_registry_types.mli:249`). 자극에는 Board 신호, 일정, Fusion 완료, 도구 결과가 있다(`lib/keeper_runtime/keeper_event_queue.mli:108`).
- 로그의 채널은 `Direct`, `Delegate`, `Schedule`, `Board_trigger`, `Retry`, `Resume`, `Fusion`, `Vision`, `Verifier`, `Autonomous` 다. 사람이 만든 Keeper 의 정책은 `Direct` 와 `Autonomous` 만 허용한다(`lib/auth_preview_keeper.ml:48`).
- 원인은 턴이 시작됐다고 적는 곳까지만 타입으로 온다(`Keeper_registry.mark_turn_started ~wake`, `lib/keeper/keeper_turn.ml:1228`). 판정에 묻는 `run_named` 호출에는 원인을 든 칸이 없다(조사만 함, `lib/keeper/keeper_agent_run.ml:1482`).
- 방식 선언은 `manual`, `on_demand`, `autonomous` 셋이다(`lib/keeper/keeper_activation_mode.ml`). `on_demand` 는 정기 턴을 끈다. mention 과 Board 신호로 깨는 턴은 방식과 상관없이 돈다(조사만 함).

### 11.5 메시지가 닿는 길과 Keeper 의 정의

- 메시지는 대화 연산으로 Keeper 의 FIFO 에 들어간다. MCP `masc_keeper_msg` 는 받았다는 답만 주고, 답은 나중에 읽는다. TUI 는 연산이 끝날 때까지 SSE 를 잡고 있다(조사만 함, `lib/keeper/keeper_tool_surface_ops.ml`, `lib/server/server_routes_http_keeper_stream.ml`).
- 보낸 이는 연산에서 문자열 `submitted_by` 고, 턴에서 `Person (Owner | Keeper | External)` 이다(`lib/keeper/keeper_input_speaker.mli:28`). 사람의 id 를 든 칸이 없다.
- 정의 파일에 꼭 있어야 하는 것은 `instructions` 와 `sandbox_profile` 이다. 목록에 없는 키가 있으면 읽지 못한다(조사만 함, `lib/keeper/keeper_types_profile.ml:136`, `lib/keeper/keeper_meta_contract.ml:154`).
- 엔진은 정의 파일을 heartbeat 마다, 메시지를 받을 때마다 다시 읽는다(조사만 함).

### 11.6 턴이 곁에서 부르는 호출

`Operator_call` 을 만드는 `.ml` 은 여섯이다(`\bOperator_call\b`, 정의한 모듈 제외).

| 호출 | 묻는 것 | 다계정의 답 뒤에 부른 쪽이 받는 것 |
|---|---|---|
| Keeper 턴 | `Operator_keeper_turn` | 설정 오류 `account` |
| Librarian(기억, 대화 요약) | HTTP 칸은 `authorize_api`, CLI 칸은 `Operator_call` | 칸 실패(조사만 함) |
| vision 도구 | `authorize_api`, `Operator_call` | 도구 결과 "Runtime 없음"(조사만 함) |
| 목표 검증 | `One_shot_walk` → `Operator_call` | 기다리는 줄이 남는다(조사만 함) |
| Fusion | `Operator_call`, `authorize_host`, `authorize_api` | 준비 실패(조사만 함) |
| capability probe | `Operator_call`, `authorize_host` | CLI 도구와 시험만 부른다(조사만 함) |

- 따로 요약 모델을 부르는 compaction 은 찾지 못했다. 대화 요약은 Librarian 이 한다(조사만 함).

### 11.7 boot 와 로그

- 엔진의 boot 는 Admin token, 내부 MCP token, Keeper credential 을 만든다(조사만 함, `lib/server/server_runtime_bootstrap.ml:1029`).
- `initialize_owner_state_blocking` 을 부르는 곳은 둘이다. 단일 사용자 서버(`lib/server/server_runtime_bootstrap.ml:1796`)와 stdio 서버(`bin/main_stdio_eio.ml:129`)다. 이 함수가 계정 접근 값을 올린다.
- 로그의 Keeper 기록은 칸 넷을 정확히 맞춰 읽는다(`lib/auth/authz_keeper_event.ml:106`). 칸이 하나 늘면 옛 기록이 있는 로그는 재생이 실패한다.

## 12. 엔진에 사람이라는 축이 없는 자리 셋 (2026-11-19)

- §11 위에 쓴 RFC 의 둘째 판을 공격 리뷰가 읽고 찾은 것이다. 근거 줄을 다시 읽어 확인했다. "조사만 함"은 리뷰 agent 만 읽었다.
- 세 자리 모두 엔진이 운영자 한 사람을 전제로 만든 타입이다.

### 12.1 실행 표를 올리는 곳

- 표를 올리는 함수는 `publish_loaded_state` 하나고(`lib/runtime/runtime.ml:798`), 부르는 곳이 셋이다.
  - `set_loaded`(:845). `runtime.toml` 을 구체화한 값으로 표를 통째로 올린다. `runtime.mli` 에 없다. 안에서 네 곳이 부른다(:895, :1108, :1153, :2774). 넷째는 설정을 commit 할 때다.
  - `enter_setup_required`(:824). 빈 표를 올린다.
  - `For_testing.restore`(:2986).
- `runtime.toml` 을 구체화하지 못하면 엔진 boot 는 빈 표를 올린다(`lib/server/server_runtime_bootstrap.ml:995`). autoboot 는 `Runtime_startup_state.await_available` 에서 기다린다(`lib/server/server_bootstrap_loops.ml:1958`).
- 계정 서버는 `runtime.toml` 을 parse 만 한다(조사만 함, `lib/server/server_runtime_setup_actions.ml:50`).
- `Login.person_runtime` 은 계정의 호출(`in_call`)을 받아야 불린다. `in_call` 은 `one_call_of` 만 만든다(`lib/server/server_setup_account_login.ml:446`). 표를 올리는 자리에는 계정의 호출이 없다.
- 판정은 key 계정의 지금 세대 key 파일 경로를 요청이 든 경로와 맞춘다(`own_key`, `lib/runtime/runtime_account_access.ml:282`). 계정의 홈은 판정이 내준다(조사만 함).
- 조회 함수 셋은 그 표만 읽는다. 디스크에서 배정을 읽는 Keeper 실행 경로는 찾지 못했다(조사만 함, `runtime.ml:1177, 1265, 1543, 1563`).

### 12.2 턴이 들고 가는 것과 돌려주는 것

지금 사람의 턴이 지키는 순서다(`lib/server/server_preview_keeper_turn.ml:380-410`).

1. `admit`. PAT 의 범위를 계정의 호출 전에 판정한다. 거절될 token 에게 호출이 도는지 알리지 않는다.
2. `one_call_of`. 호출이 돌고 있으면 아무것도 쓰지 않고 409 로 답한다.
3. 호출 안에서 Runtime 을 만들고 다시 판정한다.

엔진의 대화 턴은 다르다.

- dispatch 전에 턴 번호를 쓰고 턴이 시작됐다고 적는다(`lib/keeper/keeper_turn.ml:1210-1232`).
- 판정의 거절을 문자열로 편다. `Config (InvalidConfig { field = "account"; detail })` 다(`lib/keeper/keeper_turn_driver.ml:273`). 같은 길로 재시도하지 않는 종단이다(조사만 함, `lib/keeper_runtime/keeper_runtime_failure_route.ml:442`).
- 지금 사람의 턴은 거절 종류마다 답을 고른다. `Home_unresolved` 는 서버 경로가 들어 있을 수 있어 로그로만 보낸다(`server_preview_keeper_turn.ml:85-132`).
- 깨운 원인 `Woken` 은 자극의 list 다. 빈 list 도 있다(`lib/keeper/keeper_registry_types.mli:251`, `lib/keeper/keeper_heartbeat_source_batch.ml:62`). 재시도와 미룬 dispatch 는 깨운 원인이 아니다(조사만 함, `lib/keeper/keeper_owner_registry.mli:290`).
- 말한 이 `Owner` 는 인증 사실이 아니다. connector 의 speaker 도 보낸 Keeper 도 없는 요청이 `Owner` 다(`lib/keeper/keeper_input_speaker.mli:23`). 연산의 source 와 input 은 JSON 이다(조사만 함, `keeper_owner_registry.mli:318`).
- 판정은 PAT 의 범위 값을 받는다. 요청 때 읽은 값이다(조사만 함, `lib/auth/authz_keeper_turn.ml:137`).
- 지금 사람의 턴은 Claude Code 와 Codex 만 돌린다. 엔진에는 Muse 갈래가 있다(조사만 함, `server_preview_keeper_turn.ml:432`, `keeper_turn_driver.ml:284`).

### 12.3 boot

- `initialize_owner_state_blocking` 은 `~single_user` 를 받는다. 그 값으로 접근 값을 올린다(`lib/server/server_runtime_bootstrap.ml:712-731`). base path 도 거기서 꺼낸다(조사만 함).
- `keeper_up` 은 Runtime id 를 받지 않으면 있던 배정을 다시 쓴다(`lib/keeper/keeper_turn_up_config_persistence.ml:746`). 있던 배정이 없으면 쓰지 않는다(조사만 함, `runtime.ml:3136`).

### 12.4 사람의 Runtime 값

- 지금 사람의 Runtime 값은 넷에서 만든다(`lib/server/server_setup_account_login.ml:484-527`).
  - 로그의 계정 기록. 종류는 `Login` 과 `Key { integration_id; generation }` 이다(`lib/auth/authz_provider_account_state.mli:31`).
  - login 계정의 영수증 파일. 어느 integration 인지를 여기서 읽는다(`:498`, `lib/runtime/runtime_setup_login_receipt.ml:114`). 로그의 `Login` 기록에는 없다.
  - 디스크에서 parse 한 `runtime.toml`(`:503`).
  - key 파일.
- Claude Code key 계정의 값은 key 를 든다. 값을 만들 때 key 파일을 읽어 key 변수 줄을 값의 environment 에 넣는다(`lib/runtime/runtime_adapter.ml:1152`, `lib/runtime/runtime_official_account.ml:157-178`). Codex 계정은 값을 만들 때 홈의 설정을 읽는다(`runtime_official_account.ml:145`).
- 봉인(`seal`)은 그 값을 그대로 든다(`lib/runtime/runtime_account_access.ml:9`). 판정 밖에서 봉인을 읽는 곳은 넷이다(`lib/runtime/runtime_instance.ml:134, 137`, `lib/runtime/runtime_execution.ml:48, 50`).
- 판정은 봉인이 든 홈과 key 파일 경로를 로그가 적는 경로와 맞춰 본다(`own_home` `runtime_account_access.ml:252`, `own_key` `:282`). 두 경로는 로그의 기록과 base path 로 적는다.

### 12.5 실행 표를 읽는 곳

- 표의 타입에는 `runtime.toml` 의 원문 설정이 없다. 구체화한 Runtime 목록, 배정, lane, 설정 파일 경로가 있다(`lib/runtime/runtime.ml:752-774`). 구체화 결과의 타입에도 없다(`:428`).
- 하나를 찾는 조회가 한 함수를 지나지 않는다. `get_runtime_by_id`(`:1543`) 말고도 `resolve_assignment_in`(`:1568`)과 `keeper_dispatch_snapshot`(`:1618`)이 목록을 직접 훑는다. verifier 조회 둘과 Dashboard 스냅샷의 클로저도 그렇다(조사만 함, `:1305, :1358, :1609`).
- `keeper_dispatch_snapshot` 은 배정이 없는 Keeper 를 default route 로 보낸다(`:1623`).
- 전체를 나열하는 공개 함수가 여덟이고 `lib` 와 `bin` 에서 부르는 곳이 열여섯이다(조사만 함). 쓰임은 quota scope 목록, Dashboard 문서, exact-output catalog, 선택지 목록이다.
- Runtime 값은 backpressure 칸을 든다. 표를 다시 올릴 때 id, binding, 계정 선택이 같은 값만 이전 칸을 이어받는다(`:831, :856`). dispatch 스냅샷은 칸이 같은 물건인지로 견준다(`:1645`).
- CLI 로 도는 Runtime 은 provider admission 을 지나지 않는다(조사만 함, `lib/keeper/keeper_turn_driver.ml:3229, 3698`, `runtime.ml:669`).

### 12.6 계정의 호출과 줄을 선 턴

- 계정의 호출 등록부는 잡지 못하면 바로 거절한다. 기다리는 길이 없다(`server_setup_account_login.ml:450`).
- 엔진 dispatch 는 판정이 거절하면 CLI 를 시작하지 않고 끝난다(`lib/keeper/keeper_turn_driver.ml:3228-3236`).
- 엔진의 대화 연산은 디스크에 남는다(조사만 함, `lib/keeper/keeper_owner_registry.mli:57`). 기록의 `source` 와 `input` 은 JSON 이고 부르는 쪽이 정한다(`lib/keeper_chat_operations/keeper_chat_operation.mli:72`).
- PAT 묶음 값은 범위와 만료를 든다. id 는 없다(`lib/auth/authz_types.mli:175-190`). 판정은 만료를 본다(`lib/auth/authz_decision.ml:136`).
- 턴의 판정은 `stored_scope` 를 전체로, 인증 묶음을 살아 있는 것으로 놓는다(`lib/auth/authz_keeper_turn.ml:100, 142`).

