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
- 공유 원장(World Memory)을 누가 읽는지도 같은 말로 정한다(§3.7). Librarian lane 을 켜는 결정에서 넘어온 요구다.
- 사실의 근거는 main `4fe71e8782cd` 의 코드다. 서버는 띄우지 않았다.
  - 경로 목록은 정적 스크립트가 뽑았다.
  - 경로마다 handler 를 읽은 것은 조사 에이전트 다섯이다. 374개 가운데 343개는 읽기 호출까지 열었고, 31개는 중간에서 멈췄다.
  - 이 문서가 인용한 코드 줄은 쓴 세션이 모두 다시 열어 대조했다.

## 읽기 전에 — 말의 뜻

| 말 | 뜻 |
|---|---|
| 범위 | 경로나 사건이 읽고 쓰는 기록이 누구의 것인지. 넷이다(§3.1) |
| 보는 이 | 요청을 보낸 쪽. 단일 사용자 서버에서는 운영자 하나다. 다계정에서는 사람이다 |
| 주인 | 로그가 사람의 Keeper 마다 적은 사람(`Authz_keeper_state.keeper.owner`) |
| 엔진 이름 | 엔진이 Keeper 를 찾는 이름. 설치에서 하나뿐이다(엔진 RFC §3.2) |

## 0. 요약

- 다계정 프로세스는 지금 경로 42개만 연다. 단일 사용자 서버의 경로 374개는 열지 않는다. 그 경로들은 단일 사용자의 자격을 읽고, 누구의 것을 읽는지 정해 두지 않았다.
- 이 RFC 는 경로마다 범위를 적게 한다. 범위는 넷이다. 공개, 같이 쓰는 것, Keeper 의 것, 호스트의 것이다.
- 범위는 경로를 등록할 때 적는다. 범위가 빠진 등록은 컴파일되지 않는다.
- Keeper 의 기록을 읽는 함수는 「볼 수 있는 Keeper」 값을 요구한다. 그 값은 보는 이를 판정해야만 생긴다.
- 다계정 프로세스는 엔진의 state 로 이 경로들을 연다. 구성원은 같이 쓰는 것과 자기 Keeper 의 것을 본다.
- SSE 사건도 보낼 때 범위를 적는다. JSON 칸을 글자로 읽어 가리는 지금 방식은 지운다.
- Board 는 같이 쓰는 것이다. 작성자는 닫힌 합타입이 된다. 다계정에서 Board 는 사람의 Keeper 를 깨우지 않는다.
- 공유 원장은 주인마다 나눈다. 거르지 않고 나눈다. 다른 주인의 사실은 한 claim 에 들어가지 못한다.
- 사용자가 정할 것은 §6 에 여섯 있다.

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
| MCP 도구 아홉. 모두 `masc_my_*` 다. Board 도구는 없다 | `lib/server/server_person_mcp.ml:41-75` |

### 1.2 판정은 「부를 수 있는가」까지 답한다

- `Auth_gate.decide` 는 경로 종류 열둘을 모두 판정한다(`lib/auth_gate.ml:138-160`, `:289-314`).
- 사람의 역할은 Admin 이거나 Worker 다(`lib/auth_gate.ml:161-167`). Worker 는 `CanReadState` 를 가진다(`lib/types/types_auth.ml:476-485`).
- 그래서 판정만으로 경로를 열면 구성원 누구나 읽기 경로를 모두 부른다. 읽기 경로 다수는 설치의 모든 Keeper 를 돌려준다(§1.4).

### 1.3 주인을 찾는 재료는 로그에 있다

- 로그는 사람의 Keeper 를 (주인, id)로 적고 엔진 이름을 든다(`lib/auth/authz_keeper_state.mli:28-38`).
- 주인의 Keeper 목록은 `owned_by` 가 준다. 엔진 이름의 주인은 `find_by_engine_name` 이 찾는다(`:44-57`).
- 사람의 신원은 Google `sub` 이나 GitHub 숫자 id 다(`lib/auth/authz_external_identity.mli:24-26`). 남이 읽을 이름 칸은 없다. 구성원 목록도 id, 신원, 역할, 상태만 준다(`lib/auth/login_member_routes.ml:41-45`).

### 1.4 경로 374개가 읽는 것

경로 목록을 이렇게 뽑았다.

- 정적 스크립트가 `Server_route` 등록 호출 423곳을 읽었다. 계정 서버 42곳, 단일 사용자 381곳이다. DOS 경로 넷은 반복문에서 펼쳤다.
- 부르는 곳이 없는 등록 7곳을 뺐다(#54026). 단일 사용자 경로는 374개다.
- 같은 스크립트를 `467cfe8e8373` 에 돌렸다. 연구 기록 §6 의 386개, 종류별 수 열 개, `/api/v1/dashboard` 89개가 모두 같았다.

경로마다 handler 가 읽고 쓰는 대상을 적었다. 대상에서 범위를 정하는 규칙(§3.1)을 적용하면 이렇다.

| 범위 | 경로 | Dashboard 가 부르는 것 | 쓰는 경로 |
|---|---|---|---|
| 공개 | 20 | 0 | 0 |
| 같이 쓰는 것 | 56 | 42 | 25 |
| Keeper 의 것 | 50 | 31 | 23 |
| 호스트의 것 | 227 | 140 | 83 |
| 단일 사용자의 자격 | 21 | 4 | 10 |

- 「Dashboard 가 부르는 것」은 `dashboard/src` 가 경로를 글자로 적은 곳이다. 시험 파일은 뺐다. 구멍(`${}`)이 든 호출은 여러 경로에 걸려서, 이 수는 위쪽 한계다.
- 「단일 사용자의 자격」은 MCP OAuth, play 초대, 개발용 token 처럼 단일 사용자의 자격을 만들거나 쓰는 경로다.
- 177개 경로의 기록에 주인 칸이 있다. 값은 Keeper 이름이거나 token 에 붙은 agent 이름이다. 다계정의 사람을 적는 칸은 없다.
- 예외가 하나 있다. `POST /api/v1/gate/message` 는 요청 몸에서 받은 채널 사용자 id 를 적는다.
- 읽기를 보는 이로 거르는 곳은 둘이다. Board 의 읽기 규칙(`lib/board/board_access.ml:16-26`)과 호출자마다 나뉜 artifact app data(`lib/artifact_app_data_store.ml:18`)다.
- 쓰기에서 호출자를 저장된 이름과 견주는 곳은 다섯이다. 다섯 모두 token 의 agent 이름을 견준다.
  - run-next(`lib/server/server_routes_http_keeper_control.ml:394-395`)
  - 일정 바꾸기(`lib/tool_schedule.ml:842-846`)
  - sub-board 바꾸기와 지우기(`lib/server/server_routes_http_routes_activity.ml:521-522`)
  - artifact draft presence(`lib/artifact_draft_live.ml:49-55`)
  - MCP session 지우기(`lib/server/server_mcp_transport_http.ml:1278-1284`)
- 다계정을 가르는 handler 는 둘이다. setup 의 models·context 가 `authorize_host` 를 부르고(`lib/runtime/runtime_account_access.ml:737-744`), setup 의 account login 이 `judge` 를 부른다(`:499`).
- 모든 Keeper 를 나열하며 내용까지 주는 경로가 있다. operator snapshot 의 최근 메시지와 승인 대기 항목, execution 과 briefing 의 메시지 미리보기, telemetry 의 tool 입출력, 공유 원장의 claim 본문이다.

### 1.5 Board

- 쓰기는 `POST /api/v1/tools/masc_board_post` 와 `/masc_board_comment` 다. 필요한 권한은 tool 목록의 정의를 따른다(`lib/auth_gate.ml:131-135`).
- 작성자는 인증에서 나온 이름으로 덮어쓴다(`lib/server/server_routes_http_routes_activity.ml:1311-1312`). 저장 칸은 `Agent_id.t` 다(`lib/board_types/board_types.mli:181`, `:212`).
- 읽기 규칙은 한 곳이다(`lib/board/board_access.ml:16-26`). Public·Unlisted·Internal 은 누구나 읽는다. Direct 는 운영자, 작성자, 대상만 읽는다.
- 글이 Keeper 를 깨우는 길은 `emit_board_signal`(`lib/board/board_dispatch.ml:486`)에서 시작한다. hook(`lib/server/server_bootstrap_loops.ml:1724`)을 지나 Keeper 마다 길을 정해 깨운다(`lib/keeper/keeper_keepalive_signal.ml:448-780`).
- 깨울 Keeper 의 주인은 보지 않는다. Keeper 정의에 주인 칸이 없다. `@이름` 과 `@@all` 은 누구든 부른다.
- 승인 대기 목록(`GET /api/v1/dashboard/gate`)은 설치의 모든 승인 대기를 tool 입력 전체와 함께 준다(`lib/keeper/keeper_approval_queue_projection.ml:33-46`). 처리하는 경로는 `CanAdmin` 이고 대상 Keeper 를 묻지 않는다.

### 1.6 사건 스트림

- `Sse.broadcast` 계열을 부르는 자리는 `lib` 아래 72곳이다(56개 파일). 값은 `Yojson.Safe.t` 다(`lib/sse.mli:228-257`).
- 보낼 대상은 연결의 종류와 작업 공간으로만 고른다(`lib/sse.mli:33-40`). 보는 이로 고르는 대상은 없다.
- lane add-on dataset 사건만 가린다. JSON 칸 `type`, `dataset`, `visibility` 를 글자로 읽는다(`lib/sse.ml:368-395`). 갈래는 `shared`, `operator`, `keeper` 다.

### 1.7 공유 원장

- 사실은 출처 Keeper 를 든다(`fact_ref`, `lib/workspace_memory/workspace_memory_ledger.mli:14-26`).
- claim 은 받친 Keeper 목록을 든다(`:147-153`). 여러 Keeper 가 받친 claim 은 `Consolidated` 나 `Crystallized` 단계가 된다(`:140-143`).
- 원장을 읽는 문은 다섯이다.
  - Keeper 도구 `keeper_workspace_memory_read`. 부른 Keeper 를 받지 않고 원장 전체를 읽는다(`lib/keeper/keeper_workspace_memory_read.ml:5-38`).
  - host recall. 그 도구를 못 쓰는 턴에 원장에서 찾은 글을 붙인다(`lib/keeper/keeper_run_tools_hooks.ml:430-446`).
  - 턴마다 싣는 「읽는 방법」 글(`lib/keeper/keeper_unified_prompt.ml:1327-1353`).
  - Dashboard 경로 `GET /api/v1/dashboard/workspace-memory-context`. `Permission CanReadState` 다(`lib/server/server_routes_http_routes_dashboard.ml:718`).
  - `CanReadState` 로 읽는 MCP resource 하나.
- 큐레이터는 준비 뒤 lane 에서 뜬다(`lib/server/server_runtime_bootstrap.ml:1576`). 다계정 프로세스도 이 lane 을 띄운다.
- 큐레이터의 모델 호출은 lane add-on export 를 운영자 주체로 부른다(`lib/server/server_workspace_memory_addon.ml:140`). 엔진 RFC §4 는 lane add-on 길을 읽지 않았다고 적었다.

## 2. 목표와 하지 않는 것

목표다.

- 구성원은 Dashboard 에서 Board, task, goal, artifact 를 본다.
- 구성원은 자기 Keeper 의 상태, 대화, 작업, 승인 대기를 본다.
- 남의 Keeper 의 기록은 이름도 보이지 않는다. 지운 설계가 이렇게 정했다. 「다른 사람의 ID 존재·이름·오류는 projection으로 제한한다」(설계 `281edab19d1c` 125행).
- handler 하나가 두 모드를 맡는다. 사람용 사본을 두지 않는다.

하지 않는 것이다.

- 남의 Keeper 와 Runtime 을 쓰기. 2단계다(연구 기록 §7 의 「Runtime 공유」와 「Keeper 상태의 주인 표시」 줄).
- Board 가 사람의 Keeper 를 깨우기. 바깥에서 온 BoardTrigger 는 DelegatePolicy 가 든다(설계 396행). 2단계다.
- 운영 중인 단일 사용자 설치를 다계정으로 옮기기. 따로 정한다.
- 단일 사용자 서버의 인증 기본값 바꾸기.

## 3. 설계

### 3.1 범위 넷

| 범위 | 무엇 | 단일 사용자 | 다계정 Worker | 다계정 Admin |
|---|---|---|---|---|
| 공개 | health, 정적 파일, 로그인 화면 | 누구나 | 누구나 | 누구나 |
| 같이 쓰는 것 | Board, task, goal, artifact, play room | 운영자 | 구성원 모두 | 구성원 모두 |
| Keeper 의 것 | 대화, 작업, 기억, 승인 대기, 일정, ask | 운영자 | 그 Keeper 의 주인 | 결정 3 |
| 호스트의 것 | 설정, `runtime.toml`, lane, sandbox, 작업 폴더, 저장소, 로그, 지표, provider | 운영자 | 열지 않는다 | 결정 2 |

- 「단일 사용자의 자격」 경로는 호스트의 것으로 둔다. 다계정은 그 자격을 만들지 않는다.
- 범위는 경로가 읽고 쓰는 대상에서 나온다. 대상이 여럿이면 가장 좁은 범위를 고른다. 좁은 순서는 호스트, Keeper, 같이 쓰는 것, 공개다.

| 대상 | 범위 |
|---|---|
| Board, task, goal, artifact, play, message | 같이 쓰는 것 |
| keeper, 대화, 작업, 기억, 승인, 일정, ask, event queue | Keeper 의 것 |
| runtime, `runtime.toml`, provider, lane, sandbox, 작업 폴더, 저장소, 로그, 지표, fusion, 검증, 에뮬레이터, voice, language server, MCP session, skill, connector, preset, Candle, 공유 원장 | 호스트의 것 |
| 정적 파일, health, server 정보 | 공개 |

- 공유 원장은 §3.7 이 들어갈 때까지 호스트의 것이다.
- 이 표는 첫 판이다. 경로마다 범위를 정하는 일은 L0 이 한다(§7).

### 3.2 등록이 범위를 적는다

- `Server_route` 의 등록 함수가 범위를 인자로 요구한다. 범위가 빠지면 컴파일되지 않는다.
- 범위는 닫힌 합타입이다. 표 파일이나 글자로 두지 않는다.
- 계정 서버의 `served`(`lib/server/server_account_table.ml:22-41`)는 경로 종류와 범위를 함께 본다. `Oauth_protocol` 과 `Loopback_dev_token` 은 지금처럼 열지 않는다.
- 등록 함수의 auth GADT 가 handler 모양을 정하는 방식은 그대로다(`lib/http_server_eio.ml:760-780`).

### 3.3 볼 수 있는 Keeper 는 값이다

- 판정을 지난 요청은 보는 이를 갖는다. 다계정에서는 사람(`User_id`), 역할, PAT 범위다. 단일 사용자에서는 운영자다.
- 보는 이에서 「볼 수 있는 Keeper」 값을 만든다. 다계정에서는 그 사람이 주인인 Keeper 의 엔진 이름 집합이다(`owned_by`). PAT 범위가 더 좁으면 겹치는 쪽만 남긴다. 단일 사용자에서는 모두다.
- 이 값은 판정이 읽은 로그 snapshot 에서 만든다. 판정과 값이 다른 상태를 보지 않는다.
- Keeper 의 기록을 읽는 함수는 이 값을 인자로 요구한다. 목록은 이 값에 든 Keeper 만 돌려준다. 이름 조회는 값에 없는 Keeper 를 「없음」으로 답한다. 경로는 404 로 답한다.
- 값의 타입은 private 이다. 만드는 함수는 판정과 엔진 시작에만 있다. handler 는 이 값을 직접 만들지 못한다.
- 엔진 안의 턴은 엔진의 값을 쓴다. 엔진은 모든 Keeper 를 본다.
- 값을 handler 에 넘기는 대신 읽는 함수가 요구하게 했다. 경로가 아닌 곳(snapshot worker, SSE)도 같은 값을 거쳐야 하기 때문이다.

### 3.4 다계정 프로세스가 경로를 연다

- 계정 서버가 엔진의 state 를 받는다. 엔진이 준비될 때 이루어지는 promise 로 받는다(`lib/server/server_runtime_bootstrap.ml:1813`).
- 받기 전에는 엔진의 경로가 503 으로 답한다. 로그인 경로는 지금처럼 엔진을 기다리지 않는다.
- 여는 것은 공개, 같이 쓰는 것, Keeper 의 것이다. 호스트의 것은 결정 2 를 따른다.
- 판정은 `Auth_gate.decide` 그대로다. 다계정 판정은 `Public_read` 도 `CanReadState` 로 본다(`lib/auth_gate.ml:141-142`). 그래서 다계정에서는 자격 없이 읽히는 경로가 공개 범위뿐이다.
- 쓰는 경로의 행위자는 닫힌 합타입이 된다. 단일 사용자의 agent 이름과 사람을 한 글자 칸에 섞지 않는다. §1.4 의 견주기 다섯도 이 타입을 견준다.
- 쓰기는 L4·L5 에서 연다.
- Dashboard 는 보는 이의 범위로 화면을 고른다. Worker 에게는 호스트 경로를 부르는 화면이 없다.

### 3.5 Board

- 같이 쓰는 것이다. 구성원은 모두 읽는다. Direct 는 지금처럼 운영자, 작성자, 대상만 읽는다.
- 다계정에서 읽는 이는 이름 하나가 아니라 이름 묶음이다. 그 사람과 그 사람의 Keeper 엔진 이름이 든다. 그래서 자기 Keeper 에게 온 Direct 글을 읽는다.
- 읽기 규칙의 「운영자」 자리를 다계정의 Admin 에게 주는지는 결정 3 을 따른다. 주면 Admin 이 모든 Direct 글을 읽는다.
- 작성자는 닫힌 합타입이다. 단일 사용자의 agent 이름과 엔진 이름이 한 갈래, 사람이 한 갈래다.
- 작성자 칸은 [Board RFC](RFC-board-has-one-writer-and-one-log.md) 의 사건 모양에 넣는다. 두 RFC 가 같은 hard cut 을 쓴다. 옛 Board 파일을 옮기는 코드는 없다.
- 다계정에서 Board 신호는 사람의 Keeper 를 깨우지 않는다. 엔진 RFC 의 S2 는 Direct 만 받는다. 깨우기는 DelegatePolicy 를 정하는 문서가 연다.
- 남에게 보이는 이름은 결정 4·5 를 따른다.

### 3.6 사건 스트림

- 사건을 보내는 함수가 범위를 요구한다. 72곳이 범위를 적는다.
- Keeper 의 것 사건은 그 Keeper 의 엔진 이름을 든다. 연결마다 보는 이의 「볼 수 있는 Keeper」 값으로 거른다.
- 호스트의 것 사건은 Worker 연결에 보내지 않는다. Admin 연결은 결정 2 를 따른다.
- lane add-on 의 JSON 가시성 읽기(`lib/sse.ml:368-395`)를 지운다. 같은 일을 타입이 한다.

### 3.7 공유 원장은 주인마다 나눈다

- 요구는 이것이다. 사실을 나누는 범위는 같은 주인의 Keeper 와 운영자로 한정한다.
- 주인은 닫힌 합타입이다. 운영자와 사람 두 갈래다.
- 단일 사용자의 Keeper 는 모두 운영자 갈래다. 다계정에는 운영자 Keeper 가 없다(연구 기록 §7 의 「운영자 Keeper」 줄). 다계정의 Keeper 는 모두 로그가 적은 주인의 갈래다.
- 원장을 주인마다 따로 둔다. 같은 주인의 Keeper 사실끼리만 합친다.
- 그래서 다른 주인의 사실은 한 claim 에 들어가지 못한다. 걸러서 막지 않고, 섞일 자리를 없앤다.
- 큐레이터는 사실을 출처 Keeper 의 주인 원장에만 넣는다. 주인은 엔진 이름으로 로그에서 찾는다(`find_by_engine_name`).
- 읽는 문 다섯은 읽는 쪽을 받는다. Keeper 도구, host recall, 턴 글은 부른 Keeper 를 받는다. Dashboard 와 MCP resource 는 보는 이를 받는다. 모두 그 주인의 원장만 읽는다.
- 운영자가 사람의 원장을 제품 화면에서 읽는지는 결정 3 을 따른다. 호스트에 들어가는 운영자는 어느 쪽이든 파일을 읽는다.
- 단일 사용자에서 주인은 운영자 하나다. 원장은 지금처럼 하나다.
- 이 층이 들어가기 전에는 다계정에서 큐레이터를 띄우지 않는다. 사람의 Keeper 턴도 큐레이터 입력에 넣지 않는다.
- 한 주인 안에서 더 나누는지는 결정 6 이다.

### 3.8 고르지 않은 길

| 길 | 고르지 않은 까닭 |
|---|---|
| 사람용 경로를 따로 만든다 | handler 가 둘이 되고 서로 어긋난다. Dashboard 를 다시 만들어야 한다 |
| 응답 JSON 에서 남의 Keeper 칸을 지운다 | 칸 이름을 글자로 읽는다. 새 칸이 생기면 샌다 |
| 경로마다 범위를 표 파일에 적는다 | 코드와 표가 따로 논다. 새 경로가 표 없이 들어온다 |
| 원장을 하나로 두고 읽을 때 거른다 | 여러 주인의 사실이 한 claim 에 섞인다. 섞인 claim 은 누구에게 보일지 정할 수 없다 |

## 4. 남는 위험

- 31개 경로는 handler 를 중간까지만 읽었다. 범위가 틀릴 수 있다. L0 이 경로마다 다시 읽는다.
- 대상 규칙은 첫 판이다. `message` 는 같이 쓰는 것으로 두었지만 Keeper 에게 간 메시지일 수 있다. `task` 에도 Keeper 에 매인 것이 있다.
- 대화나 tool 인자를 담은 기록 가운데 Keeper 이름 대신 token 의 agent 이름만 든 것이 있다. 그 기록은 주인을 찾지 못한다. 그런 경로는 호스트의 것으로 둔다.
- Dashboard 는 호스트 경로 140개를 부른다. 그 화면을 Worker 에게서 빼는 일이 프론트엔드에 든다.
- 「볼 수 있는 Keeper」 값을 만들려면 요청마다 로그 snapshot 을 읽는다. 판정이 이미 읽는 snapshot 을 같이 쓴다. 따로 읽지 않는다.

## 5. 증명

| 주장 | 시험 |
|---|---|
| 범위 없는 등록이 없다 | 등록 함수의 타입이 범위를 요구한다. 컴파일이 증명이다 |
| 남의 Keeper 는 보이지 않는다 | 두 사람이 각자 Keeper 를 만든다. 목록, 이름 조회, SSE 에 서로의 Keeper 가 없다. 이름 조회는 404 다 |
| 같이 쓰는 것은 함께 본다 | 두 사람이 서로의 Board 글을 읽는다. Direct 글은 대상만 읽는다 |
| 호스트의 것은 Worker 에게 닫힌다 | Worker 가 호스트 경로를 부르면 403 이다. 결정 2 에서 아무에게도 열지 않기로 하면 404 다 |
| Board 는 사람의 Keeper 를 깨우지 않는다 | 다른 사람이 `@` 로 부른 글이 그 Keeper 의 턴을 만들지 않는다 |
| 원장은 주인마다 나뉜다 | 두 주인의 Keeper 가 같은 사실을 내도 claim 은 주인마다 따로 생긴다 |
| 단일 사용자는 그대로다 | 기존 경로 시험이 그대로 통과한다 |

## 6. 사용자가 정할 것

1. **경로표를 하나로 두나.**
   추천: 하나로 두고 경로마다 범위를 적는다(§3.2).
   다른 안: 사람용 경로를 따로 만든다. §3.8 의 까닭으로 고르지 않았다.
2. **다계정에서 호스트의 것을 누구에게 여나.**
   추천: Admin 에게 연다. 다만 비밀값을 내주는 호스트 경로 9개는 열지 않는다. `runtime.toml` 원문, Keeper 설정 내보내기, sandbox 로그 같은 경로다. 그중 쓰기 다섯은 응답에 비밀값이 실려서 걸렸다. 응답을 고치면 연다(L7).
   다른 안: 누구에게도 열지 않는다. 그러면 다계정 설치의 설정은 호스트에서 파일과 CLI 로만 바꾼다.
   조사가 비밀값을 내준다고 적은 경로는 16개다. 나머지 7개 가운데 다섯은 단일 사용자의 자격이라 다계정에서 열지 않는다. 둘은 Keeper 턴을 멈추는 token 이라 그 Keeper 의 주인만 받는다.
3. **Admin 이 남의 Keeper 의 것을 보나.**
   추천: 내용은 주인만 본다. 지운 설계는 dispatch 의 prompt·output·transcript 를 initiator 의 것으로 정했다. Admin 은 「사용량·시각·dispatch_id·결과 종류만 읽는다」(설계 `281edab19d1c` 67행).
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

## 7. 층

| 층 | 하는 일 | 끝나면 보이는 것 |
|---|---|---|
| L0 | 범위 타입. 등록 374곳이 범위를 적는다. 한 PR 은 파일 10개 이하다 | 없다. 동작이 그대로다 |
| L1 | 보는 이와 「볼 수 있는 Keeper」 값. Keeper 기록을 읽는 함수가 그 값을 요구한다 | 없다. 단일 사용자는 운영자 하나다 |
| L2 | SSE 72곳이 범위를 적는다. 연결마다 거른다. JSON 가시성 읽기를 지운다 | 없다 |
| L3 | 다계정 프로세스가 공개, 같이 쓰는 것, Keeper 의 것을 읽기로 연다. Dashboard 가 범위로 화면을 고른다 | 구성원이 Board, task, goal 과 자기 Keeper 를 본다 |
| L4 | Board 쓰기. 작성자 합타입은 Board RFC 의 hard cut 과 같이 간다 | 구성원이 Board 에 쓴다 |
| L5 | 같이 쓰는 것의 나머지 쓰기와 Keeper 의 것 쓰기(지시, 중단, 승인) | 구성원이 자기 Keeper 를 Dashboard 에서 다룬다 |
| L6 | 공유 원장을 주인마다 나눈다. 읽는 문 다섯이 읽는 쪽을 받는다 | 다계정에서 큐레이터를 켤 수 있다 |
| L7 | 결정 2 를 따라 호스트의 것을 연다. 비밀값이 실리는 쓰기 응답을 고친다 | Admin 이 Dashboard 로 설정을 바꾼다 |

- L0~L2 는 동작을 바꾸지 않는다. 엔진 RFC 의 S2 와 따로 간다.
- L3 의 Keeper 의 것은 S2 가 사람의 Keeper 를 엔진에 띄운 뒤에 쓸모가 있다.

## 8. 이력

- 2026-11-21: 처음 쓴다. 경로 374개를 조사하고 범위 규칙을 세웠다. 공유 원장 범위를 §3.7 로 넣었다.
