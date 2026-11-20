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
- 일정 저장소는 `.masc/schedules.json` 이다. 파일 이름은 `lib/schedule/schedule_store.ml:256` 에, 폴더를 붙이는 줄은 `:259` 에 있다. 엔진이 준비된 뒤 뜨는 유지 작업이 일정을 돌린다(조사만 함). §9 의 물음 가운데 경로만 확인했다. boot 의 어디에서 열리는지는 조사만 했다.
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
- 원인은 턴이 시작됐다고 적는 곳까지만 타입으로 온다(`Keeper_registry.mark_turn_started ~wake`, `lib/keeper/keeper_turn.ml:1227-1230`). 판정에 묻는 `run_named` 호출에는 원인을 든 칸이 없다(조사만 함, `lib/keeper/keeper_agent_run.ml:1482`).
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
- `Login.person_runtime` 은 계정의 호출(`in_call`)을 받아야 불린다. `in_call` 은 `one_call_of` 만 만든다(`lib/server/server_setup_account_login.ml:446` 의 주석, 타입은 448행). 표를 올리는 자리에는 계정의 호출이 없다.
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

### 12.7 로그가 바뀐 것을 아는 길

- 로그에 쓰는 길은 `Authz_zone.commit` 하나다(`lib/auth/authz_zone.mli:334`). 부르는 파일이 열둘이다. 첫 기록만 `install` 이 쓴다(`:352`).
- zone 에는 바뀐 것을 알리는 길이 없다. 지금 상태를 읽는 함수가 둘이다. `snapshot`(`:195`)과, 믿을 수 있을 때만 답하는 `read`(`:239`)다.
- 상태는 head 와 같이 온다(`:138`). head 는 다음 기록의 순번을 든다(`lib/auth/authz_record.mli:140`).
- runtime 라이브러리에서 zone 을 든 것은 접근 값 하나다(`lib/runtime/runtime_account_access.ml:86`).
- 로그의 Runtime 기록은 주인, 계정, grant 를 든다(`lib/auth/authz_runtime_state.mli:18`). 모델은 들지 않는다. binding 은 Runtime id 전체를 견주어 고른다(`lib/runtime/runtime_account_runtime.mli:13`).
- 표를 올리는 `set_loaded` 를 부르는 네 곳 가운데 셋은 parse 한 설정을 지나온다(`lib/runtime/runtime.ml:890, 1102, 1149`). 넷째는 설정의 commit 이다(`:2774`).
- `runtime.ml` 은 `Runtime_account_access` 를 부른다(이름이 열 번 나온다). `runtime_account_access.ml` 은 `Runtime` 을 부르지 않는다.


### 12.8 셋째 리뷰 뒤에 읽은 것

표를 올리는 길이다.

- 표를 올리는 함수는 값을 통째로 바꿔 넣는다(`Atomic.set`, `lib/runtime/runtime.ml:798-801`). 견주어 넣지 않는다. 올릴 때마다 표의 판 번호가 오르고, 그것을 기다리는 곳이 깬다.
- 표는 worker domain 을 포함한 아무 자리에서나 읽는다(`:748-751` 의 주석). 설정의 commit 은 경로마다 잠그고, 다른 경로의 commit 은 다른 domain 에서 돌 수 있다(`:1819-1821` 의 주석).
- 그래서 조회가 표를 읽고 다시 만들어 올리면, 그 사이에 올라온 commit 의 표를 덮을 수 있다.
- zone 은 head 를 그대로 둔 채 상태를 바꿔 올리는 곳이 있다(`lib/auth/authz_zone.ml:419, 445-448`). head 는 상태 전체의 판 번호가 아니다.
- 사람의 Runtime 값을 만드는 코드는 `runtime.ml` 위에 있다. `lib/runtime/runtime_account_runtime.ml:123` 이 `Runtime.runtimes_of_config` 를 부른다. 값은 홈과 key 파일의 경로를 든다(`:110-111`).
- 배정이 없을 때 default 로 가는 코드는 `runtime.ml:1621-1623` 말고 네 자리에 더 있다(조사만 함: `lib/keeper/keeper_meta_contract.ml:369-386` 의 둘, `lib/keeper/keeper_direct_runtime_continuation.ml:31-34`, `lib/server/server_dashboard_runtime_resolved_json.ml:210-220`).

대화 연산이다.

- 연산의 실패는 닫힌 여덟 종류와 문자열 하나다(`lib/keeper_chat_operations/keeper_chat_operation.mli:10-18, 24-28`). 판정의 거절이 들 칸이 없다.
- 엔진의 실패 분류는 `Config` 와 `Internal_carried` 를 이름 없는 원인으로 묶는다(`lib/keeper_runtime/keeper_request_failure.ml:150-155`).
- 거절의 글이 연산의 `detail` 과 오류 이벤트에 실린다(조사만 함: `lib/server/server_routes_http_keeper_stream.ml:2409-2420, 2510-2533`). 다시 붙은 요청은 실패한 연산에 고정 문구 하나를 받는다(조사만 함: `:3103-3120`).
- 엔진은 줄 선 연산 가운데 이어진 것을 한 턴으로 묶는다. 묶는 조건은 `source` 가 바깥 메시지 id 만 빼고 같은 것이다(`lib/keeper/keeper_chat_operation_batch.ml:12-14`). 묶인 턴의 payload 는 맨 앞 연산의 `source` 로 만든다(조사만 함: `server_routes_http_keeper_stream.ml:2597-2603`).
- `source` 는 필드 열넷의 닫힌 schema 다. 모르는 필드는 거절한다(`lib/keeper/keeper_chat_operation_payload.ml:1-42`). 주인이나 범위를 든 필드는 없다.
- 연속이 있는 `Running` 연산은 재시작 뒤 `Queued` 로 돌아간다(`lib/keeper_chat_operations/keeper_chat_operation_store.mli:518-527`). 설계 679행은 재시작 때 직접 HTTP/WS 요청이 `Cancelled_before_effect` 를 본다고 적었다.
- 연산 실행기에서 판정까지 가는 인자는 세 층이다(조사만 함: `lib/keeper/keeper_turn.ml:1193-1204`, `lib/keeper/keeper_agent_run.ml:1491-1492`).

다계정에서 지금 도는 것이다.

- Codex 의 턴은 다계정에서 시작 전에 거절된다. Codex 에 내장 도구를 모두 끄는 값이 없어서다(`lib/server/server_preview_keeper_turn.ml:341-344` 의 주석, `:363`). 사람의 턴이 지금 도는 client 는 Claude Code 하나다.
- 사용량 기록은 기록될 때마다 운영자의 작업 공간 파일에 scope id 와 함께 쓰이고 알려진다(`lib/server/server_provider_usage_history.ml:15-28`). 사람의 턴이 그 기록을 만드는 자리는 조사만 했다(`lib/keeper/keeper_claude_code_runtime.ml:144-147, 1805-1808`).
- boot 의 `~single_user` 는 세 줄에서만 쓰인다(`lib/server/server_runtime_bootstrap.ml:716, 729, 733`). 같은 함수가 대화 연산의 실행기를 단일 사용자 경로 모듈에서 가져와 꽂는다(`:1044-1045`). Keeper loop 와 뒤 lane 을 띄우는 곳은 조사만 했다(`:1630-1671`, `:1508-1551`).
- 대화 지우기는 계정의 호출 안에서 계정 홈의 vendor 사본을 지운다(조사만 함: `lib/server/server_keeper_conversation_purge.ml:125-156`).
- dispatch 가 끝난 뒤에도 도는 사용량 읽기가 Codex 에 있다(조사만 함: `lib/keeper/keeper_codex_runtime.ml:250-257`). Claude Code 쪽은 읽지 않았다.

## 13. 대화 연산이 턴이 되고 끝나는 길

`c25461fbe` 에서 읽었다. 흐름 전체는 조사 agent 가 추적했다. 아래에서 「조사만 함」이 없는 줄은 직접 열어 읽었다.

### 13.1 들어가는 길

- 엔진의 대화 경로는 요청자를 문자열 하나로 받는다. 인증이 돌려주는 것은 `agent_name` 이다(조사만 함: `lib/server/server_auth.ml:1100-1131`). 사람의 id 와 PAT 는 이 길에 없다.
- 연산의 `source` 는 필드 열넷의 닫힌 schema 다(§12.8). 실행기가 열넷을 모두 읽는다(조사만 함: `lib/server/server_routes_http_keeper_stream.ml:606-670`).
- 엔진이 턴의 주인을 만드는 자리는 하나다. `Fleet_keeper_turn { keeper_name = meta.name }` 이다(`lib/keeper/keeper_agent_run.ml:1490-1492`). 손에 든 것은 Keeper 의 meta 뿐이다.
- 그 사이의 층은 셋이다. 실행기, `Keeper_turn`, `Keeper_agent_run` 이다. 요청자 이름은 `Keeper_turn` 에서 `run_turn` 으로 넘어가지 않는다. 연산 id 는 넘어간다(조사만 함: `lib/keeper/keeper_turn.ml:816-876`).
- 다계정에서 판정은 `Operator_keeper_turn` 을 거절한다(`lib/runtime/runtime_account_access.ml:348`). `admit` 은 같은 요청을 허락한다(`:426-430`).
- `Keeper_turn` 요청을 만드는 곳은 지금 사람의 턴 경로 하나다(조사만 함: `lib/server/server_preview_keeper_turn.ml:386`).

### 13.2 돌아오는 길

엔진에는 턴이 왜 실패했는지를 드는 타입이 이미 있다.

- `Keeper_request_failure.t` 다. 원인이 닫힌 합이고 엄격한 JSON codec 이 있다(`lib/keeper_runtime/keeper_request_failure.mli:54-138, 151-158`). 시도마다 walk evidence 에 그 JSON 을 쓴다(`lib/keeper_runtime/keeper_runtime_walk_evidence.ml:77, 87, 100`).
- agent-core 오류를 이 타입으로 바꾸는 곳은 하나다. carrier 에 실린 MASC 오류는 `Masc` 갈래가 된다(`keeper_request_failure.mli:140-145`).

거절의 종류는 세 곳에서 사라진다.

| 자리 | 들어오는 것 | 나가는 것 |
|---|---|---|
| `lib/keeper/keeper_turn_driver.ml:273-277` | 판정의 거절(닫힌 합) | `Config (InvalidConfig { field = "account"; detail })`. `detail` 은 문자열이다. carrier 에 싣지 않는다 |
| `lib/server/server_routes_http_keeper_stream.ml:793-798` | `Turn_failed { failure : Keeper_request_failure.t }` | `Keeper_request_failure.summary failure` 문자열 |
| 같은 파일 `:1198-1203`, `:2524-2526` | 실행기의 실패 종류 여섯 | 연산의 실패 종류 넷. 턴의 실패는 `Turn_exception` 이 되고 글은 `detail` 에 붙는다 |

- 그래서 계정이 거절한 턴의 끝 기록은 provider 오류로 실패한 턴과 종류가 같다.
- 거절된 시도는 `Dispatched` 로 표시된다(`keeper_turn_driver.ml:2093-2099`). CLI 는 시작하지 않았다. 엔진은 다음 후보로 넘어가지 않는다(§16.2).

### 13.3 사람에게 가는 길 넷

| 길 | 사람이 받는 것 | 자리 |
|---|---|---|
| 기다리는 stream | 고정 문장 하나와 code `event_error`. 종류는 없다 | 조사만 함: `lib/keeper/keeper_chat_events.ml:214-221` |
| 연산 id 로 읽기 | 실패 종류의 이름, 종류마다 고정 문장 하나, 연산 id | `lib/keeper_chat_operations/keeper_chat_operation.ml:186-204` |
| 다시 붙은 요청 | 고정 문장 하나 | 조사만 함: `server_routes_http_keeper_stream.ml:3103-3120` |
| 재시작 뒤 | 연속이 없는 연산은 `Interrupted_by_restart` 가 된다. 연속이 있으면 다시 줄을 선다 | §12.8 |

- `detail` 은 공개 JSON 에 나가지 않는다(`keeper_chat_operation.ml:197-204`). 대화 기록의 줄과 Keeper 도구의 JSON 에는 나간다(조사만 함: `server_routes_http_keeper_stream.ml:2043`, `lib/keeper/keeper_tool_surface_ops.ml:1293`). 거절의 글에는 서버 경로가 들 수 있다(이슈 #50018).
- 연속 실패 횟수를 올리는 함수를 부르는 파일은 둘이다. `lib/keeper/keeper_unified_turn_failure.ml` 과 `lib/keeper/keeper_heartbeat_loop.ml` 이다. 대화 연산의 실패가 그 길을 지나는지는 읽지 않았다.

### 13.4 지금 사람의 턴이 가르는 끝 까닭

- 지금 경로는 끝 까닭을 닫힌 타입 둘로 든다. HTTP 답은 `Server_preview_keeper_error.t` 다(`lib/server/server_preview_keeper_error.mli:35-113`). 대화 기록에 남는 것은 `Server_keeper_conversation.failure` 일곱이다(`lib/server/server_keeper_conversation.mli:78-87`). `Key_refused`, `No_quota`, `Not_signed_in` 이 여기에 있다.
- 판정의 거절은 한 함수가 답 다섯으로 접는다(`lib/server/server_preview_keeper_turn.ml` 의 `refusal_error`). `Turn_refused`, `Runtime_reassigned`, `Unknown_keeper`, `Server_unavailable`, `Internal` 이다.
- 엔진이 같은 실패를 어느 원인으로 바꾸는지는 §16.1 에 있다.

### 13.5 연산의 실패 종류를 하나 더하면 바뀌는 곳

- 종류 여덟을 모두 적은 `match` 는 넷이다. 하나는 읽었다(`keeper_chat_operation.ml:186-195`). 셋은 조사만 했다(`keeper_chat_operation.ml:25-34`, `lib/keeper/keeper_owner.ml:1032-1041`, `lib/keeper/keeper_chat_failure_projection.ml:18-24`).
- 컴파일러가 잡지 못하는 곳이 있다. 손으로 적은 목록, 문자열에서 읽는 함수, SQL 안의 `'Interrupted_by_restart'` 다(조사만 함: `keeper_chat_operation.ml:13-22, 36-46`, `lib/keeper_chat_operations/keeper_chat_operation_store.ml:649`).
- 연산 table 의 `CHECK` 는 그 목록에서 만든다(`keeper_chat_operation_store.ml:113-122`). 갈래를 더하면 table 의 SQL 이 바뀐다. 있던 저장소는 열리지 않는다(§16.4).
- TUI 는 공개 JSON 의 종류를 같은 함수로 읽는다. Dashboard 는 문자열로 받는다(조사만 함: `bin/masc_tui_keeper_chat_log.ml:153`, `dashboard/src/api/keeper.ts:498`).

## 14. 엔진이 Keeper 의 Runtime 을 묻는 자리

`c25461fbe` 에서 조사 agent 가 `lib`·`bin` 의 호출 자리를 세고 나눴다. 「조사만 함」이 없는 줄은 직접 열어 읽었다. 개수는 모두 조사만 했다.

### 14.1 묻는 길은 세 걸음이다

| 걸음 | 묻는 것 | 손에 든 것 | 함수 | 부르는 곳(lib) |
|---|---|---|---|---|
| 1 | 이 Keeper 의 route | Keeper 이름이나 meta | `Runtime.runtime_id_for_keeper`, 그것을 싼 wrapper 셋, `Runtime.keeper_dispatch_snapshot` | 45 |
| 2 | 이 route 의 후보들 | route 문자열 | `Runtime.resolve_assignment` | 17 |
| 3 | 이 id 의 Runtime 값 | Runtime id | `Runtime.get_runtime_by_id` 와 칸 하나를 읽는 함수들 | 46 |

- 걸음 1 의 wrapper 셋은 모두 `Runtime.runtime_id_for_keeper` 를 부르고, 없으면 default 로 간다(`lib/keeper/keeper_meta_contract.ml:369-386`, `lib/keeper/keeper_direct_runtime_continuation.ml:31-34`).
- 걸음 3 은 Keeper 를 모른다. 엔진의 후보 단계는 route 를 후보 id 로 푼 뒤 id 만 들고 표를 다시 읽는다(`lib/keeper/keeper_turn_driver.ml:314-316, 1418-1420`). 같은 파일에 그런 자리가 아홉이다(조사만 함).
- 네 조회 함수는 모두 `runtime.ml` 안에 있다(§12.5).

### 14.2 default 로 가는 자리

다섯이 아니라 일곱이고 동작이 서로 다르다. 위의 wrapper 셋은 읽었고 나머지는 조사만 했다.

| 자리 | default 가 없을 때 | 배정을 trim 하는가 |
|---|---|---|
| `keeper_meta_contract.ml:369` `runtime_route_of_keeper_name` | `None` | 한다 |
| `keeper_meta_contract.ml:377` `runtime_id_of_meta` | 예외 | 한다 |
| `keeper_direct_runtime_continuation.ml:31` `current_assignment` | 예외 | 하지 않는다 |
| `runtime.ml:1618` `keeper_dispatch_snapshot` | 후보가 빈다. default route 만 본다 | 하지 않는다 |
| `lib/server/server_dashboard_runtime_resolved_json.ml:210` | default runtime 이 있을 때만 default route 를 쓴다 | 한다 |
| `lib/runtime/runtime_verification.ml:490` | 부르는 쪽이 default runtime id 를 넘긴다 | — |
| `lib/runtime/runtime_agent_core_runner.ml:112` | 빈 id 를 default runtime 으로 읽는다 | — |

### 14.3 Keeper 와 무관하게 표를 읽는 곳

- Fusion, exact lane, verifier 슬롯, lane add-on, probe 는 Keeper 없이 route 나 id 로 묻는다(조사만 함).
- 여러 Keeper 를 한꺼번에 묻는 곳이 넷이다. Dashboard 문서 둘, 쉼 알림, client tool outbox 다(조사만 함: `lib/server/server_dashboard_runtime_resolved_json.ml:240-274`, `lib/server/server_dashboard_http_runtime_info.ml:1737-1806`, `lib/server/server_provider_rest_broadcast.ml:35-45`, `lib/keeper/keeper_client_tool_outbox_wake.ml:96-116`).
- 다른 프로세스에서 읽는 곳이 있다. CLI 넷은 자기 프로세스에서 `runtime.toml` 로 표를 채운다. TUI 의 lane 목록은 표를 채우는 호출 없이 읽는다(조사만 함: `bin/masc_tui_lane_inventory.ml:307`).

### 14.4 zone 을 읽는 값

- `Authz_zone.snapshot` 은 `Atomic.get` 하나다(`lib/auth/authz_zone.ml:166`). `read` 는 멈춤 표시 둘과 `Atomic.get` 을 본다(`:207-216`). 잠금을 잡지 않는다.

## 15. 사람의 Runtime 값의 입력과 그것이 바뀌는 때

`1677a1471` 에서 조사 agent 가 훑었다. 「조사만 함」이 없는 줄은 직접 열어 읽었다.

### 15.1 값을 만드는 데 읽는 것

- 서버의 `person_runtime` 이 입력을 모은다(`lib/server/server_setup_account_login.ml:484-527`). 읽는 것은 다섯이다.
  - 로그의 계정 기록. 주인과 종류(`Login` 이나 `Key { integration_id; generation }`)다.
  - Login 계정이면 login 영수증 파일. 거기서 integration 을 얻는다.
  - `runtime.toml`. 부를 때마다 파일을 읽고 파싱한다(`lib/server/server_runtime_setup_actions.ml:50-63`).
  - 설정에서 그 integration 의 client. 설정을 마법사의 JSON 으로 바꾼 뒤 행을 `id` 로 찾는다(같은 파일 `:361-372`).
  - 계정 홈과 key 파일의 경로, 그리고 key 파일.
- 어느 Runtime 인지는 부르는 쪽이 넘긴다. Keeper 턴은 로그의 Keeper 기록과 Runtime 기록에서 고른다(조사만 함: `lib/server/server_preview_keeper_turn.ml:46-47, 57-64`).
- `of_template` 는 그 계정의 provider 와 binding 하나만 든 설정을 만들어 `Runtime.runtimes_of_config` 에 넘긴다(`lib/runtime/runtime_account_runtime.ml:93-130`). 그 함수는 `materialize_config` 다(`lib/runtime/runtime.ml:741-744`).
- `materialize_config` 의 본문에는 파일, `Unix`, `Eio` 를 부르는 줄이 없다(`runtime.ml:574-705`, rg 로 확인).
- 값을 만드는 데 쓰는 `lib/runtime` 의 모듈 일곱은 `Runtime.` 을 부르지 않는다(rg 0건). `runtime_setup_login_client`, `runtime_account_home_layout`, `runtime_setup_spec`, `runtime_official_cli_install`, `runtime_wizard_inventory`, `runtime_setup_login_receipt`, `runtime_api_key_file` 이다.
- 운영자의 표를 올리는 길은 파일을 파싱해 표로 바꾸고, 파싱한 설정은 버린다(`runtime.ml:706-716`). 표에는 파싱한 설정이 없다(`:752-774`). 그래서 사람의 Runtime 은 지금 디스크의 파일로 만들고, 운영자의 표는 마지막으로 올린 설정으로 만든 것이다.

### 15.2 로그 상태에서 입력이 되는 칸

- 상태는 칸 열셋의 record 다(`lib/auth/authz_state.ml:20-34`). 계정은 `provider_accounts`, Runtime 은 `runtimes`, Keeper 는 `keepers` 에 든다.
- 그 세 칸을 바꾸는 기록은 종류 셋이다. `Provider_account`, `Runtime`, `Keeper` 다(`authz_state.ml:700, 718, 736`). 다른 종류는 그 셋을 바꾸지 않는다(조사만 함).
- 상태를 바꾸는 곳은 모두 `{ state with … }` 꼴이다. 열여섯 곳이다. 전체를 새로 만드는 곳은 빈 상태 하나다(`:37`). 그래서 바뀌지 않은 칸은 기록이 적용된 뒤에도 같은 물건이다.
- `hold_revocations` 는 `revocation_pending` 만 바꾼다(`:122-133`). zone 이 head 를 그대로 두고 상태를 다시 올리는 곳이 부르는 함수다(§12.7). `later` 는 `latest_at_ms` 만 바꾼다(`:864-868`).
- 요청마다, 턴마다 쓰는 기록은 없다. 로그인할 때 `Session` 기록이 하나 쓰이고, 그 기록은 세 칸을 바꾸지 않는다(조사만 함: `lib/auth/login_routes.ml:468`, `authz_state.ml:614`).
- 세 칸을 바꾸는 기록을 쓰는 서버 자리는 계정 route 셋, 검증 route 하나, Keeper route 둘과 MCP 도구 둘이다(조사만 함: `lib/server/server_login_http.ml:523-540`, `lib/server/server_person_mcp.ml:200-205`).
- 세 칸의 모듈은 Map 이고 `equal` 을 내보내지 않는다(조사만 함).

### 15.3 표 쪽

- 다계정에서 판정 모듈은 zone 을 든다(`lib/runtime/runtime_account_access.ml:70-74`). `runtime.ml` 은 이미 그 모듈을 부른다.
- 표를 다시 올릴 때 backpressure 칸을 이어받는 조건은 여섯이다. id, provider, model, binding, 계정 고르기, 후보 binding 이 같아야 한다(`runtime.ml:831-843`).
- `await_catalogue_change` 를 `runtime.ml` 밖에서 부르는 곳은 둘이다. 사용량 읽기와 배정 알림이다(`lib/runtime/runtime_provider_usage_read.ml:373-374`, `lib/server/server_runtime_assignment_broadcast.ml:2-5`). 엔진의 턴은 그 조건을 기다리지 않는다.
- 쉬는 경로에서 기다리는 턴은 불릴 때마다 `keeper_dispatch_snapshot` 을 다시 읽어 앞의 것과 견준다(`lib/keeper/keeper_direct_runtime_continuation.ml:76-96`). 부르는 곳은 owner 다(`lib/keeper/keeper_owner.ml:1623-1629`). 얼마나 자주 부르는지는 읽지 않았다.

## 16. 턴이 끝난 까닭이 사는 곳

`1677a1471` 에서 조사 agent 가 훑었다. 「조사만 함」이 없는 줄은 직접 열어 읽었다.

### 16.1 엔진의 실패 타입이 가르는 것

- 엔진의 실패 타입에서 이름 없는 원인은 `Core { category; message }` 다. `message` 는 문자열이다(`lib/keeper_runtime/keeper_request_failure_core.ml:1-4`).
- provider 의 인증 거절, 한도 소진, 쓸 수 없음, 시간 초과는 모두 그 갈래가 된다(`lib/keeper_runtime/keeper_request_failure.ml:103-156`).
- Claude Code 의 실패는 그 앞에서 agent-core 오류가 된다(`lib/keeper/keeper_claude_code_runtime.ml:388-494`). 구독이 없는 것과 401 은 둘 다 `AuthError` 다. 시작하지 못한 것과 전송이 끊긴 것은 둘 다 `ProviderUnavailable` 이다(조사만 함).
- 지금 사람의 턴 경로는 같은 실패를 한 함수로 일곱 종류에 나눈다(`lib/server/server_preview_keeper_turn.ml:140-164`). key 계정의 401 만 `Key_refused` 다.

| 지금 경로의 종류 | 엔진의 원인(조사만 함) |
|---|---|
| `Not_signed_in`, `Key_refused`, `Not_started` | `Core { category = provider }` |
| `No_quota` | 한도 소진은 `Core { category = provider }`, throttle 은 `Provider_rate_limited` |
| `Silent` | `Core { category = api }` |
| `Configuration_refused` | `Core { category = config }` |
| `No_answer` | 여러 갈래. 프로세스 종료와 예상 못 한 예외는 `Masc`, 창 초과는 `Context_overflow` |

- 그래서 엔진의 타입은 일곱 가운데 넷을 서로 가르지 못한다.
- MASC 오류를 나르는 값은 갈래가 열다섯이고 모두 JSON 으로 쓰고 읽는다. 그 가운데 여덟은 모르는 칸을 거르지 않는다(조사만 함: `lib/keeper/keeper_internal_error.ml:270-349, 385-516, 1028-1255`).

### 16.2 계정이 거절한 시도

- CLI 는 시작하지 않는다. 시도는 `Dispatched` 로 적힌다(§13.2).
- 그 오류는 다음 후보로 넘어갈 까닭이 되지 않는다(`lib/keeper/keeper_runtime_attempt.ml:199-204`). 실패의 길은 `Config_mismatch` 로 끝난다(조사만 함: `lib/keeper/keeper_runtime_failure_route.ml:442`).
- walk evidence 에는 `Core { category = config }` 와 거절의 글이 남는다(조사만 함).
- 연산의 `outcome_ref` 는 채워진다. 턴 ref 를 적는 자리가 Runtime 을 고르는 자리보다 앞이다(`lib/keeper/keeper_turn.ml:565-570`).

### 16.3 walk evidence 가 사는 곳

- Keeper 의 실행 영수증 줄의 `runtime.lane_evidence` 칸이다(`lib/keeper/keeper_execution_receipt.ml:452-460`). 영수증은 Keeper 마다 날짜별 JSONL 파일이다(조사만 함).
- 줄의 신원은 `trace_id` 와 `turn_count` 다. 연산의 `outcome_ref` 인 턴 ref 도 같은 둘로 만든다(조사만 함: `lib/keeper/keeper_agent_run_receipt.ml:155-156`).
- 읽는 곳은 가장 새 줄 하나만 읽는다(`keeper_execution_receipt.ml:615-630`). 턴 하나의 줄을 찾는 함수는 없다(조사만 함).
- 기본 30일 뒤에 지운다(`lib/config/env_config_core.ml:727`). 시작할 때와 24시간마다 지운다(조사만 함).

### 16.4 연산 저장소

- 실패를 적는 것은 UPDATE 한 번이다. 상태, 끝난 때, `outcome_ref`, 종류, 글을 같이 쓴다(`lib/keeper_chat_operations/keeper_chat_operation_store.ml:3509-3517`). 실패를 적는 곳이 둘 더 있다. 묶인 연산이 앞선 연산의 끝을 베끼는 곳과 재시작 정리다(`:3452`, `:3734`).
- 저장소는 열 때 `sqlite_master` 의 (type, name, sql) 목록이 기대와 정확히 같은지 본다. 다르면 거절한다(`:729-741`). 지금 schema 는 v3 다(`:86-88`).
- 그래서 칸이나 실패 종류를 더하면 지금의 저장소는 열리지 않는다. 런타임에 옮기는 길은 없다. v2 에서 v3 으로 갈 때 쓴 따로 도는 복사가 있다(조사만 함: `:1389-1625`).
- 단일 사용자 서버도 같은 저장소 코드를 쓴다. schema 를 바꾸면 운영자의 Keeper 의 저장소도 같이 걸린다.

## 17. 턴의 결과가 사는 곳

`c1b0475ab` 에서 조사 agent 가 훑었다. 「조사만 함」이 없는 줄은 직접 열어 읽었다.

### 17.1 저장소 넷

| 저장소 | 성공한 턴 | 실패한 턴 | 지우는 때 |
|---|---|---|---|
| 대화 기록 `.masc/keeper_chat/<Keeper>.jsonl` | `assistant` 줄. 답 전체, 턴 ref, 연산 id | `request_failure` 줄. 글 하나 | 기간으로 지우는 목록에 없다 |
| 연산의 event 기록(연산마다 파일 하나) | 답의 조각과 답 전체 | 글 하나 | 기본 30일 |
| 연산 저장소 | 턴 ref | 종류, 글, 턴 ref | 끝난 행은 지우지 못한다 |
| session history | 답 | 읽지 않음 | 읽지 않음 |

- 대화 기록의 경로는 `lib/keeper/keeper_chat_store_paths.ml:4-10` 이다. 기간으로 지우는 목록은 `lib/server/server_runtime_startup_maintenance.ml:66-88` 이고 대화 기록의 폴더는 거기에 없다. 나머지 칸은 조사만 했다.

### 17.2 연산이 끝날 때 대화 기록에 쓰는 줄

- 쓰는 값은 셋 가운데 하나다. `Runtime_deferred`, `Reply of string`, `Request_failed of string` 이다(`lib/server/server_keeper_operation_transcript.ml:1-4`). 실패는 글 하나다.
- 줄은 연산 id 를 든 `delivery_key` 와 자리 `Terminal_result` 를 든다(`lib/keeper/keeper_chat_store_message_append.ml:13-56`). 성공한 줄과 실패한 줄이 같은 자리다.
- 실패 줄의 글은 `"Keeper request failed: "` 뒤에 요약 글을 붙인 것이다(`lib/server/server_routes_http_keeper_stream.ml:1042-1048`). 요약 글은 엔진의 실패 타입에서 만든다(§13.2). 판정의 거절 글이 거기에 든다.
- 쓸 때 secret 만 가린다(`keeper_chat_store_message_append.ml:30-31`). 읽는 쪽은 줄의 글을 그대로 내준다(`lib/keeper/keeper_chat_projection.ml:180-186`).
- 실패 줄을 쓰는 함수는 하나다(`server_routes_http_keeper_stream.ml:1669-1690`). 부르는 곳이 여섯이다(`:1715, 1868, 1982, 2043, 2076, 2180`). 다섯은 엔진의 실패 값을 손에 들고 요약 글만 넘긴다. 하나(`:2043`)는 dispatch 가 실패로 돌려준 글과 실패 분류만 든다.
- 실패로 끝난 연산은 다른 자리 `Settled_failure` 의 줄을 하나 더 받는다(조사만 함). 그 글은 연산의 끝 종류마다 정해진 문장이다(`lib/keeper/keeper_chat_failure_projection.ml:18-24, 60`). 재시작이 끝낸 연산에는 이 줄만 있다.

### 17.3 줄의 타입

- 줄의 역할은 닫힌 다섯이다(`lib/keeper/keeper_chat_types.ml:28-34`). 실패는 `Request_failure` 하나다.
- 줄의 칸은 이름 스물넷의 목록에 있어야 한다. 목록에 없는 칸이 있으면 오류다(`lib/keeper/keeper_chat_store_row_codec.ml:119-127`). schema 버전 표시는 없다.
- 그 오류에서 느슨한 reader 는 read drop 을 적고 줄을 버린다(`lib/keeper/keeper_chat_store_line_decode.ml:236-245, 340-344`). 엄격한 reader 는 못 읽는 줄로 돌려준다(`lib/keeper/keeper_chat_store_transcript_rows.ml:68-79`).
- 값이 틀린 칸은 다르다. 턴 ref 와 출처는 read drop 을 적고 그 칸만 없는 것으로 읽는다. 줄은 남는다(`keeper_chat_store_line_decode.ml:246-294`).
- 칸 이름을 적은 파일은 셋이다. row codec, line decode, projection 이다(`"stream_lifecycle"` 로 셌다).

### 17.4 읽는 길

- 기다리는 stream 은 답 전체를 `KEEPER_REPLY_DETAILS` 로 받는다(조사만 함: `lib/server/server_keeper_chat_agui_projection.ml:86-92`).
- 연산 id 로 읽으면 답이 없고 턴 ref 만 온다(§13.3). 답은 대화 기록에서 찾는다. Keeper 의 위임 상태 도구가 그렇게 한다. 턴 ref, 연산 id, 자리가 맞는 `assistant` 줄을 고른다(`lib/keeper/keeper_tool_surface_ops.ml:1050-1072`).
- 대화를 읽는 route 는 모두 대화 기록을 읽는다(조사만 함).

### 17.5 엔진의 실패 값을 쓰는 다른 곳

- 엔진의 실패 값에는 JSON codec 이 있다(`lib/keeper_runtime/keeper_request_failure.mli:151, 156`). 엔진은 시도마다 그 JSON 을 walk evidence 에 쓴다(`lib/keeper_runtime/keeper_runtime_walk_evidence.ml:74-90`).
- walk evidence 와 실행 영수증을 쓰는 두 파일에는 글을 가리는 코드가 없다(`rg -i redact` 0건). 대화 기록은 줄의 글, 도구 호출, block 을 따로 가린다(`lib/keeper/keeper_chat_store_message_append.ml:30-33`).
- 줄을 한 번만 붙이는 함수, 줄을 쓰는 것과 연산의 끝 기록을 쓰는 것 사이에 서버가 죽었을 때의 길은 읽지 않았다.

## 18. 넷째 공격 리뷰 뒤에 읽은 것

공격 리뷰가 §15 와 §17 의 결정을 코드와 맞춰 봤다. 아래는 그 뒤에 직접 읽은 것이다. "조사만 함"은 리뷰어만 읽은 자리다.

### 18.1 값을 만드는 길이 읽는 것

- §15.1 은 `materialize_config` 의 본문만 봤다. 그 함수가 부르는 길은 디스크와 프로세스를 읽는다.
  - Claude Code 의 값은 만들 때 CLI 의 위치를 찾는다(`lib/runtime/runtime_adapter.ml:1128`). 찾는 함수는 파일의 실행 권한을 본다(`lib/runtime/runtime_official_cli_install.ml:22-25, 91-95`).
  - 봉인에 넣을 것을 만들 때 프로세스의 environment 를 읽는다(`lib/runtime/runtime_official_account.ml:133-134, 160`, 부르는 곳 `runtime_adapter.ml:1150, 1158`). Codex 는 홈의 `config.toml` 도 읽는다(`runtime_official_account.ml:86-91`).
  - 조사만 함: 전역 catalog snapshot 을 읽는다(`runtime_adapter.ml:23-29, 205-208`). boot 뒤에 그것과 environment 가 바뀌는지는 리뷰어도 읽지 않았다.
- 홈과 key 파일의 경로는 주인의 membership 기록이 든 namespace 로 적는다(`lib/runtime/runtime_account_access.ml:243-248`). membership 이 없으면 적지 못한다. 그래서 값이 기대는 기록은 Runtime, 계정, membership 셋이고 거기에 설정이 붙는다.
- 경로의 real root 는 `Unix.realpath` 로 읽는다(`lib/runtime/runtime_account_home_layout.ml:87-95`). 폴더가 없으면 실패한다. 지금 조회 쪽이 폴더를 만든다는 것은 조사만 했다(`lib/server/server_setup_account_login.ml:87-95`).
- 계정의 상태는 계정 기록이 아니라 삭제 기록에서 계산한다(`lib/auth/authz_state.ml:62-74`). 삭제가 시작돼도 계정 기록은 같은 물건이다. 판정은 membership, 홈, key 를 다시 본다(`runtime_account_access.ml:352-357`). 판정이 삭제 중인 계정을 거절하는 줄은 조사만 했다(`lib/auth/authz_keeper_turn.ml:74`).
- 조사만 함: zone 은 믿을 수 있을 때만 상태를 준다(`lib/auth/authz_zone.ml:207-216`). 설정을 기다리는 표는 빈 상태로 올라간다(`lib/runtime/runtime.ml:776, 824-827`). 값을 만들 때마다 inventory JSON 과 release catalog 를 읽는다(`lib/server/server_runtime_setup_actions.ml:361-384`, `lib/runtime/model_release_evidence.ml:207-256`).
- 리뷰어가 깨뜨리지 못한 것이다. 로그 상태에 가변 칸과 제자리 수정이 없다. zone 의 읽기는 `Atomic.get` 하나다.

### 18.2 실패 줄이 쓰이고 읽히는 길

- 엔진이 돌린 턴의 실패는 §17.2 의 여섯 가운데 값을 들지 않는 하나로 온다. 턴을 돌리는 함수는 글과 disposition 을 돌려주고(`lib/server/server_routes_http_keeper_stream.ml:755`), 턴의 실패 값을 그 안에서 글로 바꾼다(`:793-798`). 부르는 쪽은 그 글로 실패 줄을 쓴다(`:2042-2043`). 나머지 다섯이 stream route 가 턴 밖에서 만드는 실패라는 것은 조사만 했다.
- 위임 상태 도구는 대화 전체를 읽어 턴 ref 로 먼저 거른 뒤 연산 id 와 자리를 본다(`lib/keeper/keeper_tool_surface_ops.ml:1055-1069`, `lib/keeper/keeper_chat_projection.ml:318-337`). 실패 줄 여섯 가운데 넷에 턴 ref 가 없다는 것은 조사만 했다.
- 줄 하나를 붙일 때 그 Keeper 의 줄 전부의 칸 이름을 본다(`lib/keeper/keeper_chat_store_provenance_index.ml:11-19`, `lib/keeper/keeper_chat_store_transcript_index.ml:50-65`, `lib/keeper/keeper_chat_store_append_once.ml:160`). 모르는 칸이 든 줄이 하나 있으면 붙이기가 거절된다. 그래서 옛 빌드는 새 칸이 든 줄이 있는 Keeper 의 대화 기록에 더 쓰지 못한다.
- 조사만 함: 줄 없이 끝나는 길은 취소, 운영자의 멈춤, 턴 본문의 예외, 줄 쓰기 실패다(`server_routes_http_keeper_stream.ml:2099-2165`). 끝 줄의 자리는 연산마다 하나이고 먼저 쓴 줄이 남는다(`keeper_chat_store_append_once.ml:164-212`). 대화를 읽는 projection 은 줄의 글을 그대로 낸다(`keeper_chat_projection.ml:180-237`). 엔진의 실패 값 codec 은 갈래와 칸이 정확히 맞아야 풀리고 판 표시가 없다(`lib/keeper_runtime/keeper_request_failure.ml:727-742`).
- 그래서 줄에는 실패 값 전체가 아니라 사람이 읽는 종류를 둔다. 스물일곱 갈래의 타입이 지워지지 않는 기록의 형식이 되지 않고, 글이 없어서 가릴 것도 없다. 갈래 수는 조사만 했다.

## 19. 엔진을 다계정 프로세스에서 띄우기 전에 읽은 것

RFC §4 가 S1 앞에 남긴 읽지 않은 것을 읽었다. "조사만 함"은 조사 에이전트만 읽은 자리다. 줄 번호는 main `40b3ae4da` 의 것이다.

### 19.1 엔진 boot 가 단일 사용자 값을 읽는 곳

- `initialize_owner_state_blocking` 이 단일 사용자 값을 읽는 줄은 둘이다. 접근 값을 올리는 줄(`lib/server/server_runtime_bootstrap.ml:729`)과 base path 를 꺼내는 줄(`:733`)이다.
- 그 뒤의 경고(`:735-741`)는 base path 만 읽는다. 문장은 단일 사용자 규칙이다(`lib/runtime/runtime_account_access.ml:564-573`). 다계정은 native 도구를 무엇이 남았든 거절한다(`:558-562`).
- 부르는 곳은 둘이다. 단일 사용자 서버(`server_runtime_bootstrap.ml:1802`)와 stdio 서버(`bin/main_stdio_eio.ml:129`)다. #53670 이 위의 두 줄을 걷어 부르는 쪽으로 옮긴다. stdio 서버는 listener 없이 같은 순서를 스스로 짠다(`:125-176`).
- 조사만 함: `activate_owner_state`(`server_runtime_bootstrap.ml:1636-1677`)와 Keeper loop, 뒤 lane 을 띄우는 함수는 server state 만 받고 단일 사용자 값을 받지 않는다.

### 19.2 계정 서버가 서는 순서

`Server_accounts.run`(`lib/server/server_accounts.ml:194-367`)의 순서다.

| 순서 | 하는 일 | 줄 |
|---|---|---|
| 1 | zone 을 열고 다시 판정한다 | `:199-207` |
| 2 | 로그인 client 와 경로표를 만든다 | `:208-234` |
| 3 | http 설정을 읽고 socket 을 잡는다 | `:237-299` (조사만 함) |
| 4 | 포트를 host 에 알린다 | `:311-326` |
| 5 | 접근 값 `Multi_account` 를 올린다 | `:327-333` |
| 6 | `Eio_context` 에 environment 와 switch 를 놓는다 | `:340-341` |
| 7 | rate limit loop 와 멈춘 일을 끝내는 fiber 를 띄운다 | `:343-346` |
| 8 | serve. 돌아오지 않는다 | `:365` |

- 5 뒤로는 거절하는 단계가 없다(`:334-335` 의 주석). 4 는 boot 를 멈출 수 있는 검사를 다 지난 뒤에 온다(`:306-310` 의 주석).
- 이 함수는 server state 를 만들지 않는다. 인자에 `runtime_sw`, 입력 base path, store 격리 승인이 없다(`lib/server/server_accounts.mli:194-202`, 조사만 함).
- 엔진 boot 는 `Server_runtime_bootstrap` 에 있고, 그 모듈이 `Server_accounts.run` 을 부른다(`server_runtime_bootstrap.ml:2357-2359`). 둘은 같은 라이브러리다. 계정 서버가 엔진 boot 를 직접 부르면 두 모듈이 서로를 가리켜 컴파일되지 않는다.

### 19.3 한 프로세스에서 한 번만 되는 것

| 것 | 자리 | 두 번째 호출 | 계정 서버도 하는가 |
|---|---|---|---|
| 접근 값 | `runtime_account_access.ml:86-97` | 거절 | 한다(`server_accounts.ml:330`) |
| run registry 넷 | `lib/run_registry_core/run_registry_core.ml:1109-1118` | 거절 | 안 한다 |
| native 실행 runtime | `lib/runtime/runtime_agent_execution_runtime.ml:11-23` | 거절 | 안 한다 |
| `Eio_context` 의 switch | `lib/eio_context/eio_context.ml:99-126` | 덮어쓴다. 부를 때마다 dispatch daemon 을 하나 더 띄운다 | 한다(`server_accounts.ml:341`) |
| 포트 알림 | `lib/server/server_startup_takeover.ml:1705-1759` (조사만 함) | lease 하나에 하나 | 한다(`server_accounts.ml:311-326`) |

- 조사만 함: 엔진 boot 가 switch 를 놓는 줄(`server_runtime_bootstrap.ml:408-411`). 단일 사용자의 포트 알림은 serve 단계에 있고(`:2206`) 엔진 boot 안에 없다. rate limit loop 는 단일 사용자 서버 함수(`:1697`)가 띄우고 엔진 boot 는 띄우지 않는다.
- 그래서 엔진 boot 와 계정 서버가 겹치는 것은 접근 값과 `Eio_context` 의 switch 둘이다. 접근 값은 계정 서버가 올린 것을 엔진 boot 가 받으면 풀린다. switch 는 두 번 놓아도 거절되지 않는다. 먼저 뜬 daemon 은 아무도 넣지 않는 큐를 기다리며 남는다.

### 19.4 다계정 접근 값이 엔진에게 거절하는 것

- 엔진은 lane Keeper 의 턴에 `Operator_keeper_turn` 을, one-shot 호출에 `Operator_call` 을 만든다(`lib/keeper/keeper_turn_driver.ml:259-265`). 다계정 접근 값은 둘을 거절한다(`runtime_account_access.ml:329, 348`). 엔진 이름을 바꾸기 전에는 다계정 프로세스의 엔진이 어떤 Keeper 턴도 CLI 로 돌리지 못한다.
- host 의 계정은 나누지 않는다(`runtime_account_access.ml:465`).
- boot 는 exact-output 등록에 실패하면 경고를 남기고 등록표를 올리지 않은 채 계속한다(`server_runtime_bootstrap.ml:1020-1027`). 조사만 함: 다계정에서는 Agent_core runtime 이 하나라도 있으면 API 판정(`lib/runtime/runtime.ml:1275`)이 거절해 이 경고가 난다. 하나도 없으면 통과한다.
- 조사만 함: `lib/keeper` 에는 사람의 요청(`Keeper_turn`)을 만드는 곳이 없다. 만드는 곳은 계정 서버의 직접 호출 하나다(`lib/server/server_preview_keeper_turn.ml:386`).

### 19.5 아직 읽지 않은 것

§20 이 읽었다.

## 20. 다계정 프로세스에 엔진을 띄우는 길

§19.5 의 넷을 읽었다. "조사만 함"은 조사 에이전트만 읽은 자리다. 줄 번호는 main `40b3ae4da` 의 것이다.

### 20.1 stdio 서버와 단일 사용자 서버가 엔진을 띄우는 방식

- stdio 서버는 listener 없이 엔진만 조립한다(`bin/main_stdio_eio.ml:125-204`). 순서는 준비 상태 초기화, owner state 초기화, 활성화(`:161`), 준비 표시(`:182`), 준비 뒤 lane(`:189-194`), serve(`:204`)다. serve 앞까지는 그 자리에서 끝까지 돈다. 하나가 실패하면 `[FATAL]` 을 남기고 프로세스를 끝낸다(`:146-179, 183-188`).
- stdio 서버는 server state 를 전역에 올리지 않고, gateway, gRPC, WebSocket, Dashboard loop 를 띄우는 `Server_auxiliary_startup.run_all` 도 부르지 않는다. 준비 뒤 lane 을 띄우는 함수의 주석은 HTTP 와 stdio 가 같은 순서를 쓴다고 적는다(`lib/server/server_runtime_bootstrap.ml:1520-1522`).
- owner state 초기화(`:712`)가 부르는 `create_server_state`(`:392, 957`)가 `Eio_context` 의 switch, net, clock 을 놓는다(`:408-411`). environment 는 받았을 때만 놓는다(`:422`). stdio 서버는 초기화에 environment 를 넘기고(`bin/main_stdio_eio.ml:132`) 초기화는 그것을 그대로 넘긴다(`:966`).
- 계정 서버는 포트를 알린 뒤에 접근 값을 올린다(`lib/server/server_accounts.ml:311-333`). 주석은 알림이 boot 를 멈출 수 있는 검사 뒤에 온다고 적고, 알림 뒤에 거절할 수 있는 단계로 접근 값 올리기 하나를 든다(`:307-310`). 접근 값 올리기 뒤에는 거절하는 단계가 없다고 주석이 적는다(`:334-335`). 조사만 함: socket 은 그 앞에서 이미 잡혀 있다(`:246-253`).
- 계정 서버는 `Eio_context` 의 environment 와 switch 를 직접 놓는다(`:340-341`). 주석은 단일 사용자 boot 가 owner state 에서 놓는 것을 이 서버가 만들지 않아서라고 적는다(`:336-339`). 엔진을 띄우면 둘이 같은 것을 놓는다. 조사만 함: 같은 switch 로 두 번 놓으면 stream 과 daemon 이 둘 남고 일은 한 번만 돈다(`lib/eio_context/eio_context.ml:99-138`).
- 다계정 boot 는 계정 서버의 거절을 `[FATAL]` 로 남기고 `Config_error` 를 던진다(`server_runtime_bootstrap.ml:2356-2366`). 계정 서버에 넘기는 인자에는 runtime switch, store quarantine 수락, 입력 base path 가 없다(`:2359`). 엔진 조립은 셋을 받고(`bin/main_stdio_eio.ml:129-145`), 다계정 boot 는 셋을 인자로 갖고 있다(`server_runtime_bootstrap.ml:2344-2346`).
- 계정 서버 시험은 실행 파일 하나다. 접근 값을 올리는 case 가 하나이고 멈추는 case 는 올리기 전에 멈춘다는 전제에 기댄다(`test/test_server_accounts.ml:397-400, 760-779`, `test/stanzas/test_server_accounts.inc:3-4`).
- 단일 사용자 HTTP 서버는 같은 초기화를 fiber 에서 돌린다(`server_runtime_bootstrap.ml:1781`). 준비 전에 실패하면 `[FATAL]` 을 남기고 프로세스를 끝내고(`:1783-1792`), 준비 뒤의 실패는 degraded 로 남긴다(`:1793-1797`). 정해진 시간 안에 준비되지 않으면 watchdog 이 프로세스를 끝낸다(`:2160-2182`). serve 는 초기화를 기다리지 않는다(`:2184`). 조사만 함: 포트 알림은 serve 단계에 있다(`:2206`).
- 단일 사용자 HTTP boot 는 Keeper 가 뜨기 전에 파일을 지우는 정리 셋을 돈다. 다계정이면 건너뛰고, 주석은 계정 서버가 Keeper 를 띄우지 않아서라고 적는다(`bin/main_eio.ml:312-323, 604`). 조사만 함: stdio 서버는 초기화 앞에서 inventory 를 돈다(`bin/main_stdio_eio.ml:106-124`).

### 20.2 Keeper loop 가 띄우는 것

config root 와 `runtime.toml` 두 줄은 직접 읽었다. 나머지는 조사만 했다.

- 엔진 boot 는 config root 를 채운다(`lib/server/server_runtime_bootstrap.ml:427`). root 가 있으면 빠진 prompt 와 시작에 필요한 설정 파일을 채운다(`lib/server/server_runtime_config_root_bootstrap.ml:574-605`). root 가 없으면 seed 를 복사하고, 거기에 기본 Keeper 정의가 든다(`:139-168, 617-639`). 조사만 함: `masc auth bootstrap` 이 root 를 만든다(`bin/masc_cli_auth.ml:187-189`).
- `runtime.toml` 의 설정 값을 적용하는 단계가 실패하면 `Config_error` 가 올라온다(`server_runtime_bootstrap.ml:382-390, 434`). 실행 표를 만들지 못하면 설정을 기다리는 상태로 선다(`:974-997`).
- 띄울 이름은 정의 TOML 폴더에서 읽는다(`lib/server/server_bootstrap_loops.ml:2004`). 폴더가 없으면 경고 한 번을 남기고 빈 목록을 쓴다(`lib/keeper/keeper_types_profile_toml_io.ml:200-217`). 폴더 위치에는 config dir 환경 값이 든다(`lib/config_dir_resolver/config_dir_resolver.ml:374-386`).
- autoboot fiber 는 실행 표가 쓸 수 있게 될 때까지 기다린다(`server_bootstrap_loops.ml:1975`). 표가 설정을 기다리는 동안은 넘어가지 않는다.
- Keeper 가 하나도 없어도 fiber 아홉 종류가 남고 프로세스 전역이 여럿 놓인다(`:1593-1938`). SSE callback, Board hook 둘, Goal backend, 종료 hook 이 그 전역이다.
- persistence 준비는 base path 아래를 고친다(`:971-1094`). 못 읽는 Keeper store 를 옆으로 옮기고, 열린 tool cycle 과 열린 턴에 끝 줄을 쓴다. 실패는 owner state 초기화의 실패로 올라온다(`server_runtime_bootstrap.ml:1094-1098`). 준비는 프로세스에서 한 번이다(`server_bootstrap_loops.ml:630, 943-954`).

### 20.3 준비 뒤 lane

전부 조사만 했다.

- `start_post_ready_owner_lanes`(`server_runtime_bootstrap.ml:1514-1557`)는 모델 설정 재개, Librarian addon 깨우기, completion authority, goal verifier 둘, Candle payout, memory curator, maintenance 를 띄운다.
- 그 끝의 `start_background_maintenance`(`lib/server/server_bootstrap_maintenance.ml:454-1181`) 한 함수에 Keeper 의 턴이 지나는 것과 운영자가 보는 것이 섞여 있다. 앞의 것은 lane addon 등록(`:480-491`), 줄 선 Keeper 메시지 복구(`:513`), tool dispatch 관측(`:664, 750`), 일정 runner(`:678-719`), tool 기록 flush(`:721-739`), 깨우기 tick(`:795-899`)이다. 뒤의 것은 Dashboard snapshot, provider 사용량 기록, 저장소 sync, OTel 이다. stdio 서버도 이 함수를 통째로 부른다.
- 운영자의 요청으로 판정을 묻는 곳이 있다. 선언된 계정의 사용량 읽기는 `Operator_call` 과 host 계정으로 묻는다(`lib/runtime/runtime_provider_usage_read.ml:90-97, 121-125`). 다계정에서는 거절되고 프로세스를 띄우지 않는다. 거절이 얼마나 자주 로그에 남는지는 읽지 않았다. completion authority 와 goal verifier 가 넘기는 요청도 읽지 않았다(`lib/runtime/runtime_verification.ml:654-672`).

### 20.4 boot 의 token 과 credential

- owner state 초기화가 세 함수를 부른다(`server_runtime_bootstrap.ml:1031-1036`, 조사만 함). 셋 다 `<base>/.masc/auth/` 에 쓴다. 다계정의 authz log 와 같은 폴더다.
- 첫째는 Admin credential 이 없으면 만든다. 주인 이름은 기본이 `admin` 이다(`lib/auth/auth_credential_token.ml:487-534`). 운영자가 environment 에 준 admin token 은 그대로 credential 로 낸다(`:506-509`). 그 token 을 프로세스 environment 에 넣는다(`lib/server/server_runtime_startup_credentials.ml:12`).
- 둘째는 internal Keeper token 을 만들어 프로세스 environment 에 넣는다(`:28-29`). 셋째는 띄울 Keeper 마다 credential 을 만든다(`:49-135`, 조사만 함).
- 계정 모드 판정은 `<base>/.masc/auth/config.json`, authz log, 바깥 저장소를 읽는다(`lib/auth/authz_boot_mode_read.ml:50-64`, `lib/auth/authz_boot_mode.ml:34-40`). 첫째 함수는 읽은 범위에서 `config.json` 을 쓰지 않는다. `config.json` 을 쓰는 곳은 auth 켜기와 끄기, 로그인 준비, workspace secret 만들기다(`lib/auth/auth.ml:404, 425`, `auth_credential_token.ml:548, 554`, `lib/auth/auth_credential_base.ml:268`). 그 쓰기는 계정 모드와 로그인 client 를 든 record 를 다시 적으므로(`lib/types/types_auth.mli:151-166`) 두 칸을 지우지 않는다.
- 다계정 판정을 지난 설정은 auth 가 켜져 있고 token 을 요구한다(`lib/auth/authz_boot_mode.ml:132-145, 158-161`). 그 설정에서 로그인 준비는 아무것도 쓰지 않는다(`auth_credential_token.ml:544-545`).
- Claude Code 로 띄우는 CLI 는 프로세스 environment 에서 정해진 이름만 가져온다(`lib/runtime/runtime_official_account.ml:127-147`, `lib/runtime/runtime_claude_environment_projection.ml:7`). 두 token 의 이름(`lib/config/env_config_core.ml:692`, `server_runtime_startup_credentials.ml:29`)은 그 파일에 없다.
- Codex 로 띄우는 CLI 는 정해진 이름에 더해 계정 홈의 `config.toml` 이 provider 의 `env_key` 와 `env_http_headers` 로 적은 이름을 가져온다(`runtime_official_account.ml:96-120, 144-147`, `lib/runtime/runtime_codex_environment_projection.ml:7-27, 38-51`). 사람의 계정에는 Codex 홈이 있다(`lib/runtime/runtime_account_access.ml:225-229`).
- 사람이 Codex 로그인을 마치면 구독 확인이 그 홈으로 capture 한다(`lib/runtime/runtime_setup_login_client.ml:183-190`). 사람은 기존 홈을 지정하지 못한다(`lib/server/server_setup_account_login.ml:158-160`). 조사만 함: 서버는 사람 홈의 `config.toml` 을 쓰지도 검사하지도 않는다. #53704 가 이름을 요구하는 사람의 홈을 판정에서 거절한다.
- 읽지 않은 것이다. credential 을 내는 함수의 본문(`publish_requested_file_backed_token_in_transaction`).
- 조사만 함: 계정 서버의 경로는 작업 공간의 credential 로 여는 wrapper(`lib/server/server_auth.ml:1347-1467`)를 쓰지 않는다.

### 20.5 아직 읽지 않은 것

- 다계정에서 거절되는 운영자 요청이 남기는 로그의 양(§20.3).
- 엔진 초기화에 걸리는 시간.
- persistence 준비가 고치는 기록이 계정 서버가 지금 쓰는 사람의 대화 기록과 겹치는지.
- completion authority 와 goal verifier 가 판정에 넘기는 요청(§20.3).
- `Runtime_setup_batch` 가 프로세스 environment 전체를 자식에게 넘기는 길(`lib/runtime/runtime_setup_batch.ml:102-104`)이 사람의 요청에서 닿는지.
- 계정 서버의 로그인 경로가 작업 공간의 credential 로 여는 wrapper 를 쓰는지. §21.3 이 한 경로를 읽었다.

## 21. 엔진이 Keeper 없는 다계정 설치에서 하는 일

줄 번호는 main `62900e072` 기준이다. 조사 에이전트 둘이 엔진이 띄우는 것 일흔 개를 훑었다. "조사만 함" 이 붙지 않은 줄은 직접 읽었다. RFC 는 직접 읽은 줄에만 기댄다.

### 21.1 띄우는 것은 네 단계다

- stdio 서버와 단일 사용자 HTTP 서버는 같은 넷을 부른다. `initialize_owner_state_blocking`, `activate_owner_state`, `mark_owner_state_ready`, `start_post_ready_owner_lanes` 다(`bin/main_stdio_eio.ml:125-204`, `lib/server/server_runtime_bootstrap.ml:1836, 1840, 1860, 2055-2058`).
- 활성화는 prompt 상태, Gate 저장소, MCP session, lazy task 를 차례로 놓고 Keeper persistence 를 claim 해 시작한다(`:1660-1702`). 조사만 함: Keeper loop 는 그 마지막 단계에서 뜬다.
- 준비 뒤 lane 은 model setup resume, Candle, Librarian wake, completion authority, goal verifier, memory curator, 정리 넷, 보고 셋, background maintenance 다(`:1540-1581`).
- HTTP 서버에만 있는 것은 server state 공개(`:1854`), gateway·gRPC·WebSocket·Dashboard 를 띄우는 단계(`:2001`), watchdog(`:2198`)이다.

### 21.2 host 의 자격으로는 모델을 부르지 못한다

- 다계정 판정은 운영자 요청을 거절한다. `Operator_call` 은 `No_operator`, `Operator_keeper_turn` 은 `No_operator_keeper` 다(`lib/runtime/runtime_account_access.ml:357, 377`).
- host 의 API key provider 도 거절한다. `authorize_api` 는 `authorize_host` 를 지나고, 다계정이면 `Host_not_shared` 다(`:496-524`).
- 사용량 읽기는 `Operator_call` 로 판정을 지난다. 거절되면 process 를 띄우지 않는다(`lib/runtime/runtime_provider_usage_read.ml:90-103`).
- 조사만 함: completion authority, goal verifier, memory curator, Candle 은 남은 일이 있을 때만 모델을 부른다. 그 길은 `Operator_call` 이나 `authorize_api` 다. Dashboard runtime probe 도 `authorize_api` 를 지난다. timer 만으로 모델을 부르는 lane 은 없다.
- 조사만 함: `runtime.toml` 에 HTTP API runtime 이 있으면 다계정에서는 exact-output 등록표가 게시되지 않고 warn 이 남는다.

### 21.3 auth 폴더에 쓰는 것

- 엔진 boot 는 Admin credential 을 준비한다. owner 파일이 없으면 이름은 `admin` 이다. credential 과 token 이 둘 다 없으면 token 을 새로 만들어 Admin credential 로 낸다(`lib/server/server_runtime_startup_credentials.ml:6-19`, `lib/auth/auth_credential_token.ml:487-539`). 실패하면 boot 가 멈춘다(`server_runtime_bootstrap.ml:1031-1034`).
- 그 token 을 프로세스 environment 에 넣는다(`server_runtime_startup_credentials.ml:12`). environment 의 admin token 을 읽는 곳은 이 단계와 설정 snapshot 뿐이다(`lib/config/env_config_snapshot.ml:62`).
- 다계정 gate 는 이 bearer 와 internal token header 를 `Legacy_bearer` 로 읽는다. 다계정은 그것을 거절한다고 적혀 있다(`lib/auth/authz_credential_presentation.mli:44-50`, `lib/auth/authz_credential_presentation.ml:62-106`). 계정 서버의 사람 경로는 요청의 credential 을 이 모듈에 넘긴다(`lib/server/server_login_http.ml:268-281`).
- 하루 한 번 도는 정리가 만료된 agent credential 을 지운다. 첫 실행은 시작 뒤 첫 tick 이다(`lib/server/server_bootstrap_maintenance.ml:297-338, 1005-1016`). 다계정 코드(`lib/auth/authz_*`)에는 그 폴더(`auth/agents`)의 이름이 없다.
- 조사만 함: authz 로그(`auth/authz.jsonl`)와 사람 폴더(`accounts/`)를 고치는 lane 은 없다. JSONL 보존 정리는 닫힌 목록의 폴더만 지운다.

### 21.4 config root 와 Keeper 정의

- 초기 설정은 config root 가 없으면 만든다. 자기가 만들었을 때만 채운다(`server_bootstrap_maintenance.ml:412-425`). state 를 만드는 단계가 같은 함수를 한 번 더 부른다. 그때는 이미 있는 root 다(`server_runtime_bootstrap.ml:427`, `lib/server/server_runtime_config_root_bootstrap.ml:642-643`).
- 채우는 방식은 넷이다. `MASC_CONFIG_DIR` 가 있으면 쓰지 않는다. 자기가 방금 만든 root 가 아니면 빠진 것만 채운다. 새 root 는 mode 에 따라 빈 틀이거나 seed 다(`lib/server/server_runtime_config_root_bootstrap.ml:508-535`).
- 기본 Keeper 정의를 복사하는 것은 seed 뿐이다(`:139-168, 617-639`). 빠진 것만 채우는 쪽은 prompt 와 시작에 필요한 설정 파일을 채운다(`:574-605`). 그래서 root 는 있고 `runtime.toml` 이 없는 설치에는 boot 가 `runtime.toml` 을 쓴다(`:542-559`).
- 조사만 함: `masc auth bootstrap` 이 `runtime.toml` 을 놓으면서 config root 를 만든다. 내장된 기본 정의는 `imp.toml` 하나이고 `activation_mode = "manual"` 이라 autoboot 대상이 아니다.
- autoboot 는 Runtime 이 준비될 때까지 기다린다. `MASC_KEEPER_AUTONOMOUS_ENABLED` 가 꺼져 있으면 아무것도 하지 않는다(`lib/server/server_bootstrap_loops.ml:1974-1977`). 띄울 이름은 `Keeper_runtime.bootable_keeper_names` 에서 온다(`:2004`).
- 조사만 함: 그 함수는 config root 의 `keepers/*.toml` 을 읽는다. 폴더가 없거나 비면 빈 목록이고, 0개를 띄운 뒤 supervisor sweep 만 시작한다.

### 21.5 host 자원과 그 밖

- tool blob sweep 은 범위가 이름을 모르는 항목이 있으면 지울 수 있는 것을 표시하지 않고 warn 을 남긴다(`lib/server/server_tool_blob_sweep.ml:7-15`). 범위에 `auth` 는 있고 사람 폴더 `accounts` 는 없다(`lib/server/server_tool_blob_scope.ml:115`, `lib/runtime/runtime_account_home_layout.ml:16`).
- 볼륨 GC 는 보고만 한다(`lib/keeper/keeper_volume_gc_periodic.ml:15-23`).
- 조사만 함: Apple `container` 가 준비된 기계에서 볼륨 GC 는 host 의 Keeper 볼륨 전체를 나열한다. 볼륨 이름에 base path 가 없다. Keeper 선언이 없는 설치는 같은 기계의 다른 서버가 쓰는 볼륨에 helper container 를 붙여 marker 를 읽는다. 6시간마다 돈다.
- 조사만 함: microVM guest 정리는 `base_path_hash` label 이 같은 guest 만 지운다.
- 조사만 함: 단일 사용자 boot 가 Keeper 앞에 도는 정리 넷은 `<base>/.masc` 의 `keepers`, `traces`, `lane-addons` 를 본다. 엔진의 다른 lane 이 그 일을 대신하지 않는다.
- 조사만 함: 한 프로세스에서 한 번만 되는 것이 다섯이다. 접근 값 공개, run registry 넷, Keeper persistence, 실행 runtime, Board workspace 다. 두 번째는 boot 를 멈춘다.

### 21.6 읽지 않은 것

- 계정 서버의 모든 경로가 credential 을 다계정 gate 에 넘기는지.
- 판정을 지나지 않고 client 나 provider 를 부르는 길이 있는지. 판정 모듈의 주석은 설정이 `authorize_api` 로만 나간다고 적는다(`runtime_account_access.ml:510-513`).
- `create_server_state` 가 놓는 observer 들, run registry replay, Gate 저장소 설치, Lane Add-on attach 와 fleet recovery, schedule runner, maintenance 의 recovery pulse 본문. 조사 에이전트도 읽지 않았다.
- 사람의 Codex 홈 설정이 client 에게 명령을 실행시키는 항목(`mcp_servers`, `notify`). 판정은 environment 이름만 본다(#53704). 격리하지 않은 app-server 시작은 설정을 덮는 인자를 붙이지 않는다(`lib/runtime/runtime_codex_app_server.ml:2872-2881`).
- 사람의 로그인이 늘 새 홈에서 뜬다는 조건(`lib/server/server_setup_account_login.ml:158-160`)을 고정하는 시험이 없다.
