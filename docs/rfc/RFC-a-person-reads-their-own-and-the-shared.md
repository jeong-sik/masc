---
rfc: "a-person-reads-their-own-and-the-shared"
title: "초대받은 사람은 같은 서버에서 자기 Keeper 의 것과 같이 쓰는 것을 본다"
status: Draft
created: 2026-11-21
updated: 2026-11-21
author: claude
supersedes: []
superseded_by: null
related: ["a-persons-keeper-runs-on-the-engine", "board-has-one-writer-and-one-log"]
---

# 초대받은 사람은 같은 서버에서 자기 Keeper 의 것과 같이 쓰는 것을 본다 (a-person-reads-their-own-and-the-shared)

- [연구 기록](../design/people-into-a-running-installation.md) §8 의 빈 곳 ③(Board)과 ④(경로마다 누구의 것을 읽는지)를 정한다. [엔진 RFC](RFC-a-persons-keeper-runs-on-the-engine.md) 가 남긴 둘이다.
- 공유 원장(World Memory)을 누가 읽는지도 같은 말로 정한다(§3.8). Librarian lane 을 켜는 결정에서 넘어온 요구다.
- 사실의 근거는 main `4fe71e8782cd` 의 코드다. 서버는 띄우지 않았다.
  - 경로 목록은 정적 스크립트가 뽑았다.
  - 경로마다 handler 를 읽은 것은 조사 에이전트 다섯이다. 374개 가운데 343개는 읽기 호출까지 열었고, 31개는 중간에서 멈췄다.
  - 이 문서가 인용한 코드 줄은 쓴 세션이 모두 다시 열어 대조했다.

## 읽기 전에 — 말의 뜻

| 말 | 뜻 |
|---|---|
| 보는 이 | 요청이나 연결을 보낸 쪽. 판정이 정한다(§3.1) |
| 범위 | 경로나 사건이 읽고 쓰는 기록이 누구의 것인지. 넷이다(§3.2) |
| 주인 | 로그가 사람의 Keeper 마다 적은 사람(`Authz_keeper_state.keeper.owner`) |
| 엔진 이름 | 엔진이 Keeper 를 찾는 이름. 설치에서 하나뿐이다(엔진 RFC §3.2) |
| 다룰 수 있는 Keeper | 보는 이가 읽고 쓸 수 있는 Keeper 의 엔진 이름 집합(§3.4) |

## 0. 요약

- 다계정 프로세스는 지금 경로 42개만 연다. 단일 사용자 경로 374개는 단일 사용자의 자격으로 호출자를 정하고, 누구의 것을 읽는지 정해 두지 않았다.
- 경로와 사건은 등록할 때 읽고 쓰는 범위를 모두 적는다. 범위가 빠지면 컴파일되지 않는다. 문은 적은 범위의 규칙을 모두 통과해야 연다.
- 규칙은 보는 이와 범위의 표 하나다(§3.2). 단일 사용자 줄은 지금 검사를 그대로 옮긴다. 다계정 줄은 새로 정한다.
- Keeper 기록을 읽고 쓰는 함수는 「다룰 수 있는 Keeper」 값을 요구한다. 값은 판정에서만 생긴다. 사람의 Keeper 턴도 주인의 값을 쓴다.
- 다계정에서 자격 없이 열리는 것은 공개 범위뿐이다. handler 는 호출자를 단일 사용자의 자격에서 다시 찾지 않고 판정에서 받는다.
- Board 에서 사람과 Keeper 를 적는 칸은 모두 한 principal 타입이 된다. 다계정에서 Board 와 메시지는 다른 주인의 Keeper 를 깨우지 않고, 그 대화에 들어가지도 않는다.
- 공유 원장은 주인마다 나눈다. 다른 주인의 사실은 한 claim 에 들어가지 못한다. 그 전까지 다계정 엔진은 큐레이터를 띄우지 않는다.
- 사용자가 정할 것은 §6 에 일곱 있다.

## 1. 지금

### 1.1 다계정 프로세스가 여는 경로

- 다계정 boot 는 계정 서버의 경로표만 연다(`lib/server/server_accounts.ml:151-163`). 42개다.
- 계정 서버는 경로 종류 셋만 받는다(`lib/server/server_account_table.ml:20-41`). `Always_public`, `Self_authenticated Browser_session`, `Self_authenticated Person_mcp` 다. 주석이 까닭을 적었다. 나머지 경로는 단일 사용자의 자격을 읽는다.
- 엔진은 다계정 프로세스에서도 server state 를 만든다(`lib/server/server_runtime_bootstrap.ml:1811-1830`). 공개는 단일 사용자 길에만 있다(`:1951`). 그래서 단일 사용자 경로의 handler 는 다계정 프로세스에서 쓸 state 가 없다.

사람이 지금 쓰는 것은 셋이다.

| 무엇 | 자리 |
|---|---|
| 콘솔 화면 하나(`/accounts/console`). Dashboard bundle 의 따로 만든 entry 다 | `lib/server/server_account_console.ml:9-12` |
| 로그인, 초대, 허용 목록, 구성원, PAT, 구독, API key, 자기 Keeper 와 대화 | `lib/server/server_login_http.ml:244-259`, `:518-543` |
| MCP 도구 아홉. `masc_whoami` 와 `masc_my_*` 여덟이다. Board 도구는 없다 | `lib/server/server_person_mcp.ml:41-75` |

### 1.2 판정은 「부를 수 있는가」까지 답한다

- `Auth_gate.decide` 는 경로 종류 열둘을 모두 판정한다(`lib/auth_gate.ml:138-160`, `:289-314`).
- 사람의 역할은 Admin 이거나 Worker 다. Service 자격도 Worker 로 본다(`lib/auth_gate.ml:161-167`). Worker 는 `CanReadState` 를 가진다(`lib/types/types_auth.ml:476-485`).
- 두 종류는 아무것도 요구하지 않는다. `Always_public` 과 `Public_read_open_when_strict` 다(`lib/auth_gate.ml:139-140`). 이 둘로 등록한 경로 가운데 11개는 공개 범위가 아니다. 예를 들어 `/api/v1/gate/events` 는 Keeper 이름을 준다.
- 하위 경로를 한 등록으로 받는 `Subpath_dispatch` 는 `CanReadState` 만 본다(`:156-158`). `/api/v1/keepers/` 의 GET 과 POST 가 그렇다. 그 아래에 설정, 대화 기록, trajectory 가 있다(`lib/server/server_routes_http_routes_keepers.ml:78-79`, `:217`).
- 그래서 판정만으로 경로를 열면 구성원 누구나 읽기 경로를 모두 부른다. 읽기 경로 다수는 설치의 모든 Keeper 를 돌려준다(§1.4).

### 1.3 주인을 찾는 재료는 로그에 있다

- 로그는 사람의 Keeper 를 (주인, id)로 적고 엔진 이름을 든다(`lib/auth/authz_keeper_state.mli:28-38`).
- 주인의 Keeper 목록은 `owned_by` 가 준다. 엔진 이름의 주인은 `find_by_engine_name` 이 찾는다(`:44-57`).
- 사람의 신원은 Google `sub` 이나 GitHub 숫자 id 다(`lib/auth/authz_external_identity.mli:24-26`). 남이 읽을 이름 칸은 없다. 구성원 목록도 id, 신원, 역할, 상태, 가진 권한만 준다(`lib/auth/login_member_routes.ml:41-45`).
- PAT 와 출처의 범위는 Runtime, 채널, effect 만 가진다(`lib/auth/authz_types.mli:169-175`). Keeper 축은 없다.

### 1.4 경로 374개가 읽는 것

경로 목록을 이렇게 뽑았다.

- 정적 스크립트가 `Server_route` 등록 호출 423곳을 읽었다. 계정 서버 42곳, 단일 사용자 381곳이다. DOS 경로 넷은 반복문에서 펼쳤다.
- 부르는 곳이 없는 등록 7곳을 뺐다(#54026). 단일 사용자 경로는 374개다.
- 같은 스크립트를 `467cfe8e8373` 에 돌렸다. 연구 기록 §6 의 386개, 종류별 수 열 개, `/api/v1/dashboard` 89개가 모두 같았다.

경로마다 handler 가 읽고 쓰는 대상을 적었다. 아래 표는 대상 가운데 가장 좁은 범위 하나로 센 것이다.

| 범위 | 경로 | Dashboard 가 부르는 것 | 쓰는 경로 |
|---|---|---|---|
| 공개 | 20 | 0 | 0 |
| 같이 쓰는 것 | 56 | 42 | 25 |
| Keeper 의 것 | 50 | 31 | 23 |
| 호스트의 것 | 227 | 140 | 83 |
| 단일 사용자의 자격 | 21 | 4 | 10 |

- 호스트의 것 227개 가운데 49개는 Keeper 기록도 읽는다. Dashboard 가 그중 37개를 부른다.
- 「Dashboard 가 부르는 것」은 `dashboard/src` 가 경로를 글자로 적은 곳이다. 시험 파일은 뺐다. 구멍(`${}`)이 든 호출은 여러 경로에 걸려서, 이 수는 위쪽 한계다.
- 「단일 사용자의 자격」은 MCP OAuth, play 초대, 개발용 token 처럼 단일 사용자의 자격을 만들거나 쓰는 경로다.
- 177개 경로의 기록에 주인 칸이 있다. 값은 Keeper 이름이거나 token 에 붙은 agent 이름이다. 다계정의 사람을 적는 칸은 없다.
- 예외가 하나 있다. `POST /api/v1/gate/message` 는 요청 몸에서 받은 채널 사용자 id 를 적는다.
- 읽기를 보는 이로 거르는 곳은 둘이다. Board 의 읽기 규칙(`lib/board/board_access.ml:16-26`)과 호출자마다 나뉜 artifact app data(`lib/artifact_app_data_store.ml:18`)다.
- 쓰기에서 호출자를 저장된 이름과 견주는 곳은 여섯이다. 여섯 모두 agent 이름 글자를 견준다.
  - run-next(`lib/server/server_routes_http_keeper_control.ml:394-395`)
  - 일정 바꾸기(`lib/tool_schedule.ml:842-846`)
  - sub-board 바꾸기와 지우기(`lib/server/server_routes_http_routes_activity.ml:521-522`)
  - sub-board 에 글쓰기(`lib/board/board_access.ml:30-38`)
  - artifact draft presence(`lib/artifact_draft_live.ml:49-55`)
  - MCP session 지우기(`lib/server/server_mcp_transport_http.ml:1278-1284`)
- Keeper 기록을 쓰는 경로 가운데 `CanBroadcast` 만 요구하는 것이 있다. 일정 만들기, 바꾸기, 취소가 그렇다(`lib/tool/tool_catalog.ml:455-459`). Worker 는 `CanBroadcast` 를 가진다.
- 승인 대기에 답하는 경로는 `CanAdmin` 이다. 주인이 없어서 Worker 가 남의 Keeper 에 답하지 못하게 막은 것이다(`lib/tool/tool_catalog.ml:292-297`).
- 다계정을 가르는 handler 는 둘이다. setup 의 models·context 가 `authorize_host` 를 부르고(`lib/runtime/runtime_account_access.ml:737-744`), setup 의 account login 이 `judge` 를 부른다(`:499`).
- 모든 Keeper 를 나열하며 내용까지 주는 경로가 있다. operator snapshot 의 최근 메시지와 승인 대기 항목, execution 과 briefing 의 메시지 미리보기, telemetry 의 tool 입출력, 공유 원장의 claim 본문이다.

### 1.5 Board

- 쓰기는 글, 댓글, 투표, 반응, sub-board 만들기·바꾸기·지우기, 글 지우기와 고정이다. 글과 댓글의 권한은 tool 목록의 정의를 따른다(`lib/auth_gate.ml:131-135`).
- 작성자는 인증에서 나온 이름으로 덮어쓴다(`lib/server/server_routes_http_routes_activity.ml:1311-1312`).
- 사람과 Keeper 를 적는 칸은 모두 `Agent_id.t` 다. 작성자(`lib/board_types/board_types.mli:181`, `:212`), Direct 대상(`:125-126`), sub-board 주인과 구성원, 투표한 이, 반응한 이다.
- 읽기 규칙은 한 곳이다(`lib/board/board_access.ml:16-26`). Public·Unlisted·Internal 은 누구나 읽는다. Direct 는 운영자, 작성자, 대상만 읽는다.
- 요청의 읽는 이는 단일 사용자의 자격에서 정한다(`lib/server/server_auth.ml:1234-1246`). bearer token 이 없으면 strict 가 꺼졌을 때 운영자, 켜졌을 때 익명이다.
- strict 는 env 를 켰거나, bind 나 base URL 이 loopback 이 아닐 때 켜진다(`lib/server/server_auth.ml:23-26`).
- 글이 Keeper 를 깨우는 길은 `emit_board_signal`(`lib/board/board_dispatch.ml:486`)에서 시작한다. hook(`lib/server/server_bootstrap_loops.ml:1724`)을 지나 Keeper 마다 길을 정해 깨운다(`lib/keeper/keeper_keepalive_signal.ml:448-780`).
- 깨울 Keeper 의 주인은 보지 않는다. Keeper 정의에 주인 칸이 없다. `@이름` 과 `@@all` 은 누구든 부른다.
- 승인 대기 목록(`GET /api/v1/dashboard/gate`)은 설치의 모든 승인 대기를 tool 입력 전체와 함께 준다(`lib/keeper/keeper_approval_queue_projection.ml:33-46`).
- Keeper 의 Docker sandbox 는 Board 의 글, 댓글, 투표, 반응 파일을 읽기 전용으로 건다(`lib/keeper/keeper_sandbox_runtime_setup.ml:430-441`).

### 1.6 사건 스트림과 메시지

- SSE 로 보내는 길은 셋이다.
  - `Sse.broadcast` 계열(`lib/sse.mli:228-257`)
  - `Mcp_server.sse_broadcast`. callback 으로 `Sse.broadcast` 에 닿는다(`lib/server/server_runtime_bootstrap.ml:586`)
  - 진행 알림. 같은 방식이다(`lib/server/server_bootstrap_loops.ml:1593`)
- 대상은 연결의 종류와 작업 공간으로만 고른다(`lib/sse.mli:33-40`).
- Board 알림은 보내는 쪽에서 공개 글만 보낸다(`lib/mcp_tool_runtime_board.ml:264-276`).
- SSE 층에서 가리는 사건은 lane add-on dataset 사건뿐이다. JSON 칸 `type`, `dataset`, `visibility` 를 글자로 읽는다(`lib/sse.ml:368-383`).
  - `operator` 는 Admin 만 받는다.
  - `keeper` 는 Admin 과 그 이름의 Worker 만 받는다(`:384-395`).
- operator snapshot 사건은 모든 Keeper 를 담은 값 하나를 한 번 만들어 보낸다(`lib/server/server_dashboard_http_core_snapshot_refresh.ml:33-38`).
- 작업 공간 메시지는 등록된 모든 Keeper 의 대화로 들어간다(`lib/server/server_bootstrap_loops.ml:1876-1884`).
- `@이름` 이 metadata 없는 Keeper 를 부르면 `Target_not_configured` 로 거절한다(`:215-297`). 그래서 Keeper 가 있는지 알 수 있다.

### 1.7 공유 원장

- 사실은 출처 Keeper 를 든다(`fact_ref`, `lib/workspace_memory/workspace_memory_ledger.mli:14-26`).
- claim 은 받친 Keeper 목록을 든다(`:147-153`). 여러 Keeper 가 받친 claim 은 `Consolidated` 나 `Crystallized` 단계가 된다(`:140-143`).
- 원장 폴더는 함수 하나가 정한다(`Workspace_memory_ledger.directory ~base_path`, `:72`). 폴더에는 원장, 바뀐 기록, briefing 이 든다.
- 원장을 읽는 자리다.
  - Keeper 도구 `keeper_workspace_memory_read`. 부른 Keeper 를 받지 않고 원장 전체를 읽는다(`lib/keeper/keeper_workspace_memory_read.ml:5-38`).
  - host recall. 그 도구를 못 쓰는 턴에 원장에서 찾은 글을 붙인다(`lib/keeper/keeper_run_tools_hooks.ml:430-446`).
  - 턴마다 싣는 원장 글. 읽는 방법과 함께 `ledger_sha256`, claim·conflict·분류 건수, briefing 상태를 싣는다(`lib/keeper/keeper_unified_prompt.ml:1327-1353`). 턴 입력은 Keeper 이름을 받아 읽는다(`lib/keeper/keeper_turn_shared_inputs.ml:7`, `:21`).
  - Dashboard 경로 둘. ledger 와 inventory 다(`lib/server/server_routes_http_routes_dashboard.ml:696`, `:703`). inventory 응답 캐시의 키는 `base_path` 뿐이다(`lib/server/server_dashboard_http_core_cache.ml:14`).
  - Dashboard Keeper snapshot 의 prompt preview(`lib/dashboard/dashboard_http_keeper_snapshot.ml:292-293`).
  - MCP resource 둘. `masc://world-memory/claims` 와 `masc://world-memory/log` 다(`lib/mcp_server.ml:246-262`, `lib/mcp_server_eio_resource.ml:265-266`).
- 바뀜 알림은 폴더 하나를 전제한다. MCP 알림은 두 URI 의 구독자 모두에게 간다(`lib/mcp_server_eio_resource.ml:140-142`). memory health 방송도 같다(`lib/server/server_memory_health_broadcast.ml:29-32`, `:64`).
- 관측 metric 은 프로세스에 하나다(`lib/keeper/keeper_workspace_memory_observation_metrics.ml:9-12`).
- `GET /api/v1/dashboard/workspace-memory-context` 는 원장이 아니라 모든 Keeper 의 기억 저장소를 준다(`lib/server/server_routes_http_routes_dashboard.ml:718`, `lib/server/server_dashboard_http_keeper_memory_health.ml:947`). 범위로는 Keeper 의 것이다.
- 원장을 쓰는 것은 큐레이터 하나다. 원장(`lib/server/server_workspace_memory_curator.ml:640`, `:739`), 바뀐 기록(`:650`), briefing(`:806`, `:867`)을 쓴다.
- 큐레이터는 준비 뒤 lane 에서 뜬다(`lib/server/server_runtime_bootstrap.ml:1576`). 다계정 엔진도 같은 길로 띄운다(`:1835`).
- 큐레이터는 Librarian 기억 lane 을 `Exact.start_flow` 로 직접 부른다(`lib/server/server_workspace_memory_curator.ml:56`, `:280`). 주체 인자는 없고, slot 은 프로세스에 하나인 lane 표(registry)에서 푼다(`:37-38`). Draft #54088 은 큐레이터가 자기 표 `workspace_memory_curator` 로만 묻게 한다.
- 분류 pass 는 lane 을 보기 전에 reconcile 을 돈다(`:624-666`). reconcile 은 모든 Keeper 의 저장소를 읽고, 사라진 사실이 있으면 원장과 바뀐 기록을 쓴다. 그래서 lane 표를 비워도 원장은 바뀐다.
- reconcile 은 목록에 없는 Keeper 의 사실을 사라진 것으로 적는다(`vanished_keepers`, `lib/workspace_memory/workspace_memory_ledger.mli:161`).

## 2. 목표와 하지 않는 것

목표다.

- 구성원은 Dashboard 에서 Board, task, goal, artifact 를 본다.
- 구성원은 자기 Keeper 의 상태, 대화, 작업, 승인 대기를 보고 다룬다.
- 남의 Keeper 는 이름도 보이지 않는다. 있는지도 알 수 없다. 지운 설계는 Runtime 에 같은 규칙을 정했다. 「다른 사람의 ID 존재·이름·오류는 projection으로 제한한다」(설계 `281edab19d1c` 125행).
- handler 하나가 두 모드를 맡는다. 사람용 사본을 두지 않는다.

하지 않는 것이다.

- 남의 Keeper 와 Runtime 을 쓰기. 2단계다(연구 기록 §7 의 「Runtime 공유」와 「Keeper 상태의 주인 표시」 줄).
- 다른 주인의 Keeper 를 Board 나 메시지로 깨우기. 바깥에서 온 BoardTrigger 는 DelegatePolicy 가 든다(설계 396행). 2단계다.
- 운영 중인 단일 사용자 설치를 다계정으로 옮기기. 따로 정한다.
- 단일 사용자 서버의 인증 기본값 바꾸기.

## 3. 설계

### 3.1 보는 이

- 판정이 보는 이를 정한다. 보는 이는 닫힌 합타입이다.

| 모드 | 보는 이 |
|---|---|
| 단일 사용자 | 운영자, Agent(Worker token 의 이름), Player, 자격 없음 |
| 다계정 | 사람(역할, PAT 범위), Service, 자격 없음 |

- 단일 사용자에서는 지금의 인증 wrapper 가 보는 이를 만든다. 만드는 규칙은 지금과 같다.
- handler 는 보는 이를 판정에서 받는다. 단일 사용자의 자격에서 호출자를 다시 찾지 않는다.
- 지금 `token_handler` 와 `actor_handler` 는 agent 이름 글자를 받는다(`lib/http_server_eio.ml:762-763`). 이 글자는 행위자 타입으로 바뀐다. 단일 사용자의 agent 이름과 사람은 다른 갈래다.
- Board 의 읽는 이도 보는 이에서 만든다. bearer token 에서 다시 정하지 않는다(§1.5).

### 3.2 범위와 규칙

- 경로와 사건은 읽고 쓰는 범위를 모두 적는다. 하나로 줄이지 않는다.
- 범위는 넷이다. 공개, 같이 쓰는 것, Keeper k 의 것, 호스트의 것이다.
- 문은 적은 범위의 규칙을 모두 통과해야 연다.
- 하나로 줄이지 않는 까닭이 있다. Admin 은 호스트를 읽을 수 있다(결정 2). 그래도 남의 Keeper 내용은 못 읽을 수 있다(결정 3). 두 규칙은 순서를 매길 수 없다. 그리고 호스트의 것 가운데 49개가 Keeper 기록도 읽는다(§1.4).

대상에서 범위를 정하는 표다.

| 대상 | 범위 |
|---|---|
| Board, task, goal, artifact, play, message | 같이 쓰는 것 |
| keeper, 대화, 작업, 기억, 승인, 일정, ask, event queue | Keeper k 의 것 |
| runtime, `runtime.toml`, provider, lane, sandbox, 작업 폴더, 저장소, 로그, 지표, fusion, 검증, 에뮬레이터, voice, language server, MCP session, skill, connector, preset, Candle, 공유 원장 | 호스트의 것 |
| 정적 파일, health, server 정보 | 공개 |

- 공유 원장은 §3.8 이 들어갈 때까지 호스트의 것이다.
- 「단일 사용자의 자격」 경로는 호스트의 것으로 둔다. 다계정은 그 자격을 만들지 않는다.
- 이 표는 첫 판이다. 경로마다 범위를 정하는 일은 L0 이 한다(§7).

다계정의 규칙이다.

| 범위 | Worker | Admin | Service | 자격 없음 |
|---|---|---|---|---|
| 공개 | 연다 | 연다 | 연다 | 연다 |
| 같이 쓰는 것 | 연다 | 연다 | 닫는다 | 닫는다 |
| Keeper k 의 것 | k 의 주인이면 연다 | k 의 주인이면 연다. 결정 3 | 닫는다 | 닫는다 |
| 호스트의 것 | 닫는다 | 결정 2 | 닫는다 | 닫는다 |

- 판정의 need 도 함께 본다. 다만 다계정의 Keeper k 의 것은 `CanAdmin` 대신 k 의 주인인지 본다. `CanAdmin` 은 주인이 없어서 둔 것이기 때문이다(§1.4).
- 단일 사용자의 규칙은 지금 검사를 옮긴다.
  - 경로는 지금처럼 권한만 본다.
  - SSE 의 Keeper k 사건은 Admin 과 이름이 k 인 Agent 만 받는다. 호스트 사건은 Admin 만 받는다(`lib/sse.ml:384-395`).
  - Board 는 지금 읽기 규칙을 쓴다.
- 규칙은 (보는 이, 범위) 쌍마다 적는다. catch-all 을 쓰지 않는다. 새 갈래를 더하면 컴파일러가 빠진 쌍을 찾는다.

### 3.3 등록이 범위를 적는다

- 등록 함수가 범위 묶음을 요구한다. 빠지면 컴파일되지 않는다. 등록은 416곳이다(단일 사용자 374, 계정 서버 42).
- 범위는 닫힌 합타입이다. 표 파일이나 글자로 두지 않는다.
- `Subpath_dispatch` 등록 둘(`/api/v1/keepers/` 의 GET·POST)은 하위 경로마다 나눈다. 나눈 경로가 각자 범위와 need 를 적는다.
- 두 경로표에 같은 경로가 있다. `/`, `/health`, `/health/live`, `/health/ready` 다. 하나만 남긴다.
- 계정 서버의 `served`(`lib/server/server_account_table.ml:22-41`)는 범위 규칙으로 바뀐다. `Oauth_protocol` 과 `Loopback_dev_token` 은 지금처럼 열지 않는다.
- auth GADT 가 handler 모양을 정하는 방식은 그대로다(`lib/http_server_eio.ml:760-780`).

### 3.4 다룰 수 있는 Keeper 는 값이다

- 보는 이에서 「다룰 수 있는 Keeper」 값을 만든다.
  - 다계정의 사람: 그 사람이 주인인 Keeper 의 엔진 이름 집합이다(`owned_by`).
  - 단일 사용자: 모두다.
- 값은 판정이 읽은 로그 snapshot 에서 만든다. 판정과 값이 다른 상태를 보지 않는다.
- Keeper 기록을 읽는 함수와 쓰는 함수가 모두 이 값을 요구한다.
  - 목록은 값에 든 Keeper 만 준다.
  - 이름 조회와 쓰기는 값에 없는 Keeper 를 「없음」으로 답한다. 경로는 404 로 답한다.
- `@이름` 찾기와 메시지 배달도 이 값을 거친다. 값에 없는 Keeper 를 부르면 없는 Keeper 와 같은 답을 준다.
- 값의 타입은 private 이다. 만드는 함수는 판정과 엔진 시작에만 있다.
- 사람의 Keeper 턴은 주인의 값을 쓴다. 턴 안의 MASC 도구는 주인이 보는 것만 본다. 모든 Keeper 를 보는 엔진의 값은 엔진 자신의 일에만 쓴다.
- PAT 는 Runtime, 채널, effect 를 줄인다. Keeper 축이 없어서 값은 줄이지 않는다(§1.3).
- 값을 handler 에 넘기지 않고 읽고 쓰는 함수가 요구하게 했다. snapshot worker, SSE 처럼 경로가 아닌 곳도 같은 값을 거쳐야 하기 때문이다.

### 3.5 다계정 프로세스가 경로를 연다

- 계정 서버가 엔진의 state 를 받는다. 엔진이 준비될 때 이루어지는 promise 로 받는다(`lib/server/server_runtime_bootstrap.ml:1813`).
- 받기 전에는 엔진의 경로가 503 으로 답한다. 로그인 경로는 지금처럼 엔진을 기다리지 않는다.
- 문은 §3.2 의 다계정 규칙과 판정의 need 를 함께 본다.
- 자격 없이 열리는 것은 공개 범위뿐이다. 판정이 아무것도 요구하지 않는 종류(§1.2)도 같다. 그래서 §1.2 의 11개는 다계정에서 자격을 요구한다.
- Dashboard 는 보는 이의 범위로 화면을 고른다. Worker 에게는 호스트 경로를 부르는 화면이 없다.

### 3.6 사건 스트림

- 보내는 함수가 범위를 요구한다. §1.6 의 세 길이 모두 이 함수를 거친다. 빠진 자리는 컴파일러가 찾는다.
- Keeper 의 것 사건은 그 Keeper 의 엔진 이름을 든다. 연결마다 §3.2 의 규칙으로 거른다.
- operator snapshot 처럼 모든 Keeper 를 한 값에 담는 사건은 연결마다 그 연결의 값으로 다시 만든다.
- 값은 연결할 때 정한다. 다시 보내는 사건에도 그 연결의 값을 쓴다.
- 구성원이 빠지거나 PAT 가 회수되면 서버가 그 연결을 닫는다.
- lane add-on 의 JSON 가시성 읽기(`lib/sse.ml:368-395`)를 지운다. `shared`, `operator`, `keeper` 는 같이 쓰는 것, 호스트, Keeper k 범위로 옮긴다. 단일 사용자의 결과는 §3.2 의 단일 사용자 규칙과 같다.

### 3.7 Board

- 같이 쓰는 것이다. Direct 는 지금처럼 운영자, 작성자, 대상만 읽는다.
- 사람과 Keeper 를 적는 Board 칸은 모두 한 principal 타입이 된다. 작성자, Direct 대상, sub-board 주인과 구성원, 투표한 이, 반응한 이다.
- principal 타입은 두 갈래다. 단일 사용자의 agent 이름과 엔진 이름이 한 갈래, 사람이 한 갈래다.
- sub-board 에 글을 쓸 수 있는지 보는 검사(`lib/board/board_access.ml:30-38`)도 이 타입을 견준다.
- [Board RFC](RFC-board-has-one-writer-and-one-log.md) 의 사건에는 이 타입이 없다. hard cut 이 두 번 생기지 않게 Board RFC 를 먼저 고친다. 그 뒤 두 RFC 가 같은 hard cut 을 쓴다. 옛 Board 파일을 옮기는 코드는 없다.
- 다계정에서 사람의 읽는 이에는 그 사람과 그 사람의 Keeper 엔진 이름이 든다. 그래서 자기 Keeper 에게 온 Direct 글을 읽는다.
- 읽기 규칙의 「운영자」 자리를 Admin 에게 주는지는 결정 3 을 따른다. 주면 Admin 이 모든 Direct 글을 읽는다.
- 다계정에서 Board 신호는 사람의 Keeper 를 깨우지 않는다. 엔진 RFC 의 S2 는 Direct 만 받는다.
- 다계정에서 작업 공간 메시지는 같은 주인의 Keeper 대화에만 들어간다.
- 사람의 Keeper sandbox 에는 Board 파일을 걸지 않는다. 그 Keeper 는 주인의 값으로 tool 을 거쳐 Board 를 읽는다.
- 남에게 보이는 이름은 결정 4·5 를 따른다.

### 3.8 공유 원장은 주인마다 나눈다

- 요구는 이것이다. 사실을 나누는 범위는 같은 주인의 Keeper 와 운영자로 한정한다.
- 주인은 닫힌 합타입이다. 운영자와 사람 두 갈래다.
- 갈래는 프로세스 종류로 먼저 정한다.
  - 단일 사용자 프로세스의 Keeper 는 모두 운영자 갈래다. 운영자의 Keeper 는 로그에 없어서, 로그로 찾으면 모두 「없음」이 된다(`lib/auth/authz_keeper_state.mli:19-23`).
  - 다계정 프로세스만 엔진 이름으로 로그에서 주인을 찾는다(`find_by_engine_name`). 다계정에는 운영자 Keeper 가 없다(연구 기록 §7 의 「운영자 Keeper」 줄).
- 원장 폴더를 정하는 함수가 주인을 필수 인자로 받는다. 원장, 바뀐 기록, briefing 이 모두 그 폴더에 든다. 읽고 쓰는 곳은 컴파일러가 모두 짚는다.
- 그래서 다른 주인의 사실은 한 claim 에 들어가지 못한다. 걸러서 막지 않고, 섞일 자리를 없앤다.
- 한 요청에는 한 주인의 글만 싣는다. 분류 요청은 밀린 사실과 이웃 claim 을 같이 싣고, briefing 요청도 그렇다. 두 주인의 글이 한 요청에 들면 모델이 쓴 claim 글에서 섞인다.
- claim id 는 주인 안에서만 유일하다고 본다. id 를 키로 쓰는 곳은 주인을 같이 쓴다.
- 큐레이터는 사실을 출처 Keeper 의 주인 원장에만 넣는다. 주인을 찾지 못한 사실은 받지 않는다.
- 주인의 Keeper 목록을 만들지 못한 pass 는 통째로 실패한다. 빈 목록으로 가면 reconcile 이 그 Keeper 들의 사실을 모두 사라진 것으로 적는다(§1.7).
- 큐레이터의 메모리 상태도 주인마다 둔다. 밀린 사실, 진행 중인 요청, 재시도 예약이다. 코드의 `owner` 레코드는 이 RFC 의 「주인」과 이름이 겹쳐서 L6 에서 이름을 바꾼다.
- 읽는 쪽은 모두 읽는 이를 받는다.
  - Keeper 도구, host recall, 턴 글은 부른 Keeper 를 받는다.
  - Dashboard 경로 둘, Keeper snapshot preview, MCP resource 둘은 보는 이를 받는다.
  - inventory 응답 캐시 키에 주인을 넣는다.
  - 바뀜 알림은 그 원장을 읽을 수 있는 구독자에게만 간다. 관측 metric 은 주인마다 센다.
- 새 폴더는 blob sweep 의 「참조 없음」 목록에도 넣는다(`lib/server/server_tool_blob_scope.ml:206`).
- 운영자가 사람의 원장을 제품 화면에서 읽는지는 결정 3 을 따른다. 호스트에 들어가는 운영자는 어느 쪽이든 파일을 읽는다.
- 단일 사용자에서 주인은 운영자 하나다. 원장은 지금처럼 하나다.
- 다계정 프로세스는 운영자 갈래 원장을 읽지도 쓰지도 않는다. 단일 사용자로 쓰던 base path 를 다계정으로 띄우면 그 파일은 그대로 남는다. 옮기는 코드는 없다.
- 이 층이 들어가기 전에는 다계정 엔진이 큐레이터를 띄우지 않는다.
  - `Server_workspace_memory_curator.start` 를 부르지 않는 코드로 막는다. lane 표를 비우는 것으로는 막지 못한다(§1.7).
  - 이 코드는 사람의 Keeper 가 엔진에서 도는 단계(엔진 RFC 의 S2)보다 늦게 들어가면 안 된다.
- 사람의 Keeper 사실을 어느 provider 계정으로 모델에 보내는지는 결정 7 이다.
- 한 주인 안에서 더 나누는지는 결정 6 이다.

### 3.9 고르지 않은 길

| 길 | 고르지 않은 까닭 |
|---|---|
| 사람용 경로를 따로 만든다 | handler 가 둘이 되고 서로 어긋난다. Dashboard 를 다시 만들어야 한다 |
| 경로마다 범위를 하나만 고른다 | Admin 의 호스트 규칙과 주인의 Keeper 규칙은 순서를 매길 수 없다. 섞인 경로 49개가 어느 쪽으로든 샌다 |
| 응답 JSON 에서 남의 Keeper 칸을 지운다 | 칸 이름을 글자로 읽는다. 새 칸이 생기면 샌다 |
| 경로마다 범위를 표 파일에 적는다 | 코드와 표가 따로 논다. 새 경로가 표 없이 들어온다 |
| 원장을 하나로 두고 읽을 때 거른다 | 여러 주인의 사실이 한 claim 에 섞인다. 섞인 claim 은 누구에게 보일지 정할 수 없다 |

## 4. 남는 위험

- 31개 경로는 handler 를 중간까지만 읽었다. 범위가 틀릴 수 있다. L0 이 경로마다 다시 읽는다.
- 대상 규칙은 첫 판이다. `message` 는 같이 쓰는 것으로 두었지만 Keeper 에게 간 메시지일 수 있다. `task` 에도 Keeper 에 매인 것이 있다.
- 대화나 tool 인자를 담은 기록 가운데 Keeper 이름 대신 token 의 agent 이름만 든 것이 있다. 그 기록은 주인을 찾지 못한다. 그런 기록은 호스트의 것으로 둔다.
- Dashboard 는 호스트 경로 140개를 부른다. 그 화면을 Worker 에게서 빼는 일이 프론트엔드에 든다.
- 「다룰 수 있는 Keeper」 값을 만들려면 요청마다 로그 snapshot 을 읽는다. 판정이 이미 읽는 snapshot 을 같이 쓴다.
- 모든 Keeper 를 담는 사건을 연결마다 다시 만들면 연결 수만큼 일이 는다. 구성원이 적다는 가정이다. L2 에서 잰다.

## 5. 증명

| 주장 | 시험 |
|---|---|
| 범위 없는 등록이 없다 | 등록 함수의 타입이 범위를 요구한다. 컴파일이 증명이다 |
| 규칙에 빠진 쌍이 없다 | (보는 이, 범위) match 에 catch-all 이 없다. 컴파일이 증명이다 |
| 단일 사용자는 그대로다 | 지금 검사와 새 규칙을 같은 요청 묶음에 돌려 결과를 견준다. 경로, SSE, Board 읽기마다 한다 |
| 남의 Keeper 는 읽지도 쓰지도 못한다 | 두 사람이 각자 Keeper 를 만든다. 목록, 이름 조회, SSE, 중단, 대화, ask 답, 일정, 승인에서 서로의 Keeper 는 404 다 |
| 있는지도 알 수 없다 | 남의 Keeper 를 `@` 로 부른 답과 없는 이름을 부른 답이 같다 |
| 자격 없이 열리는 것은 공개뿐이다 | 다계정에서 §1.2 의 11개를 자격 없이 부르면 거절된다 |
| Board 읽는 이는 판정에서 온다 | 세션 cookie 만 든 요청이 남의 Direct 글을 읽지 못한다. strict 가 꺼져도 같다 |
| 같이 쓰는 것은 함께 본다 | 두 사람이 서로의 Board 글을 읽는다 |
| 호스트의 것은 Worker 에게 닫힌다 | Worker 가 호스트 경로를 부르면 거절된다 |
| 메시지와 Board 는 다른 주인의 Keeper 에 닿지 않는다 | 한 사람의 메시지, `@`, Board 글이 다른 사람의 Keeper 대화와 턴을 만들지 않는다 |
| 원장은 주인마다 나뉜다 | 두 주인의 Keeper 가 같은 사실을 내도 claim 은 주인마다 따로 생긴다 |
| 다계정 엔진은 큐레이터를 띄우지 않는다 | 다계정 boot 뒤 Keeper 기억이 바뀌어도 원장 폴더의 파일이 그대로다 |
| 목록을 못 만든 pass 는 원장을 바꾸지 않는다 | 로그 snapshot 읽기가 실패하는 pass 뒤에 원장과 바뀐 기록이 그대로다 |
| 한 요청에 한 주인 | 분류와 briefing 요청에 실린 사실의 주인이 모두 같다 |

## 6. 사용자가 정할 것

1. **경로표를 하나로 두나.**
   추천: 하나로 두고 경로마다 범위를 적는다(§3.3).
   다른 안: 사람용 경로를 따로 만든다. §3.9 의 까닭으로 고르지 않았다.
2. **다계정에서 호스트의 것을 누구에게 여나.**
   추천: Admin 에게 연다. Keeper 기록이 섞인 경로는 Admin 에게도 「다룰 수 있는 Keeper」 값으로 거른다.
   비밀값을 내주는 호스트 경로 9개는 열지 않는다. `runtime.toml` 원문, Keeper 설정 내보내기, sandbox 로그 같은 경로다. 그중 쓰기 다섯은 응답에 비밀값이 실려서 걸렸다. 응답을 고치면 연다(L7).
   다른 안: 누구에게도 열지 않는다. 그러면 다계정 설치의 설정은 호스트에서 파일과 CLI 로만 바꾼다.
   조사가 비밀값을 내준다고 적은 경로는 16개다. 나머지 7개 가운데 다섯은 단일 사용자의 자격이라 다계정에서 열지 않는다. 둘은 Keeper 턴을 멈추는 token 이라 그 Keeper 의 주인만 받는다.
3. **Admin 이 남의 Keeper 의 것을 보나.**
   추천: 내용은 주인만 본다. 지운 설계는 dispatch 의 prompt·output·transcript 를 initiator 의 것으로 정했다. 다른 initiator 의 dispatch 에 대해서는 「owner와 Admin은 사용량·시각·dispatch_id·결과 종류만 읽는다」(설계 `281edab19d1c` 67행). 남의 Keeper 를 보는 Admin 은 다른 initiator 의 자리에 선다.
   다른 안: Admin 도 내용을 본다. 다른 제품 둘은 이렇게 적는다.
   - [Open WebUI](https://docs.openwebui.com/security/chat-data-privacy-and-encryption): 「Admins control the instance, so treat every admin as able to read every chat.」 화면에서 감추는 설정(`ENABLE_ADMIN_CHAT_ACCESS=false`)도 화면에서만 감춘다고 적는다.
   - [LibreChat Admin Insights](https://www.librechat.ai/docs/features/insights): 켜면 사용자 이름, email, 대화 id, 최근 대화의 첫 메시지를 관리자에게 보인다. 기본은 꺼져 있다(`ENABLE_INSIGHTS=true` 로 켠다).
   - 두 문서는 2026-11-21 02:59 KST 에 원문을 내려받아 문장을 대조했다.
   어느 쪽이든 호스트에 들어가는 사람은 파일을 읽는다. 이 결정은 제품 화면의 경계다.
4. **사람을 남에게 무엇으로 보이나.** 로그에는 사람의 이름 칸이 없다(§1.3).
   추천: 사람이 정하는 표시 이름을 로그에 적는다.
   다른 안: 로그인 공급자가 주는 이름을 입장할 때 적는다. GitHub 은 사용자 API 에서 login 을 준다. Google 은 지금 `openid` 범위만 요청한다(`lib/auth/oidc_google_exchange.ml:151`). 이름을 받으려면 `profile` 범위를 더 요청해야 하고, 그 값은 대개 실명이다.
   다른 안: id 를 그대로 보인다. 사람이 읽기 어렵다.
5. **사람의 Keeper 가 쓴 Board 글의 작성자를 무엇으로 보이나.**
   추천: 「주인의 표시 이름 / Keeper id」.
   다른 안: 엔진 이름. 서버가 뽑은 이름이라 누구의 Keeper 인지 알 수 없다.
6. **공유 원장을 한 주인 안에서 더 나누나.** 예: 회사 일 Keeper 와 개인 일 Keeper.
   추천: 주인 단위로만 나눈다. 지금 Keeper 정의에는 묶음을 적는 칸이 없다.
   다른 안: Keeper 정의에 묶음을 적고, 묶음마다 원장을 나눈다. 단일 사용자에서도 원장이 나뉜다.
   단일 사용자에서도 같은 질문이다. 지금도 Keeper 들이 원장 하나를 같이 쓴다.
7. **사람의 Keeper 사실을 누구의 provider 계정으로 큐레이트하나.** 지금 큐레이터는 설치의 lane slot 을 쓴다(§1.7).
   추천: 주인의 계정으로 한다. 엔진 RFC 는 곁에서 부르는 호출을 사람의 Keeper 에게 거절했다. 필요하면 「Librarian 을 주인의 계정으로 돌리는 규칙」을 둔다고 적었다(엔진 RFC 265행).
   추천을 고르면 큐레이터 lane 을 주인마다 푸는 길이 L6 에 같이 든다. 지금 lane 표는 프로세스에 하나다.
   다른 안: 설치의 slot 으로 한다. 운영자가 비용을 내고, 운영자의 provider 가 사람의 사실을 받는다.

## 7. 층

| 층 | 하는 일 | 끝나면 보이는 것 |
|---|---|---|
| 먼저 | 다계정 엔진이 큐레이터를 띄우지 않는다. 엔진 RFC 의 S2 보다 늦지 않게 넣는다 | 다계정에서 원장이 바뀌지 않는다 |
| L0 | 범위 타입. 등록 416곳이 범위를 적는다. `Subpath_dispatch` 둘을 나누고 겹친 경로 넷을 하나로 둔다. 한 PR 은 파일 10개 이하다 | 없다. 동작이 그대로다 |
| L1 | 보는 이 타입과 「다룰 수 있는 Keeper」 값. Keeper 기록을 읽고 쓰는 함수가 값을 요구한다. handler 는 행위자 타입을 받는다. 단일 사용자 규칙을 지금 검사와 견주는 시험 | 없다 |
| L2 | SSE 의 세 길이 범위를 적는다. 연결마다 거르고, 모든 Keeper 를 담는 사건은 연결마다 다시 만든다. JSON 가시성 읽기를 지운다 | 없다 |
| L3 | 다계정 프로세스가 공개, 같이 쓰는 것, Keeper 의 것을 읽기로 연다. 자격 없는 접근은 공개만. Board 읽는 이는 보는 이에서 온다. Dashboard 가 범위로 화면을 고른다 | 구성원이 Board, task, goal 과 자기 Keeper 를 본다 |
| L4 | Board RFC 를 고친 뒤 Board 의 principal 타입과 쓰기. 사람의 Keeper sandbox 에서 Board 파일을 뺀다 | 구성원이 Board 에 쓴다 |
| L5 | Keeper 쓰기를 주인으로 연다. 중단, 대화, ask 답, 일정, 승인, 지시, run-next 다. 메시지와 `@` 는 같은 주인의 Keeper 에게만 간다 | 구성원이 자기 Keeper 를 Dashboard 에서 다룬다 |
| L6 | 원장 폴더 함수가 주인을 받는다(원장, 바뀐 기록, briefing). 한 요청에 한 주인. 목록을 못 만든 pass 는 실패한다. 캐시 키, 알림, metric 을 주인마다 둔다. 결정 7 의 계정으로 큐레이트한다. 주인의 계정이면 큐레이터 lane 을 주인마다 푼다 | 다계정에서 큐레이터를 켤 수 있다 |
| L7 | 결정 2 를 따라 호스트의 것을 연다. 비밀값이 실리는 쓰기 응답을 고친다 | Admin 이 Dashboard 로 설정을 바꾼다 |

- 「먼저」 줄은 다계정의 동작만 바꾼다. 큐레이터를 끈다.
- L0~L2 는 동작을 바꾸지 않는다. L1 과 L2 의 견주는 시험이 이를 보인다. 엔진 RFC 의 S2 와 따로 간다.
- L3 의 Keeper 의 것은 S2 가 사람의 Keeper 를 엔진에 띄운 뒤에 쓸모가 있다.

## 8. 이력

- 2026-11-21: 처음 쓴다. 경로 374개를 조사하고 범위 규칙을 세웠다. 공유 원장 범위를 §3.8 로 넣었다.
- 2026-11-21: 반박 리뷰 한 번을 반영했다. 범위를 하나로 줄이지 않는다. 쓰기와 메시지, 사람의 Keeper 턴도 값을 거친다. 자격 없는 접근과 Board 읽는 이를 판정에 묶었다. 단일 사용자 규칙은 지금 검사를 옮기고 시험으로 견준다.
- 2026-11-21: 공유 원장 리뷰를 반영했다. 큐레이터가 운영자 주체로 부른다는 줄은 틀려서 지웠다(그 모듈을 부르는 코드가 없다). 읽는 자리 넷, 쓰는 자리, reconcile 의 위험, 다계정 엔진에서 큐레이터를 끄는 코드 줄, 결정 7 을 더했다.
