# 다계정 Google OIDC·Runtime 권한 구현 계획

- 날짜: 2026-10-27
- 상태: 초안. 이 계획이 승인되기 전에는 코드 층을 시작하지 않는다.
- 설계: `docs/superpowers/specs/2026-10-27-multi-account-oidc-runtime-authorization-design.md` (PR #46428, 2026-10-27 병합)
- 코드 대조: main `d595f10978db`. 아래 사실은 이 커밋에서 읽은 것이고 줄 번호도 이 커밋 기준이다.

이 문서는 설계를 층(PR)으로 나누는 순서와 층마다의 범위만 정한다. 설계가 바뀌면 해당 층을 시작하기 전에 이 문서를 고친다.

용어는 설계를 따른다. 종단은 attempt나 lease가 끝나는 상태이고, 결속은 token이나 cookie를 세션이나 PAT 같은 한 대상에 묶는 것이다.

## 1. 방식

- 층 하나는 한 가지 결과만 낸다. 작업과 출력은 20k token 이하를 목표로 하고, 넘으면 쪼갠다.
- 층은 `gh stack`으로 쌓는다. 맨 아래만 main을 base로 삼고, 스택은 맨 위 PR로 한 번에 병합한다. 스택 브랜치에 main이나 다른 PR을 merge하지 않는다.
- 로컬 전체 빌드와 CI 대기를 하지 않는다. 필요한 검사는 층마다 이름을 적어 요청하고, 결과는 그 SHA에 대한 것으로만 쓴다.
- 시험은 기능 표면에서 한다. 판정식(§6.2)과 복구 상태기계(§8.2)처럼 갈래가 많은 순수 로직만 함수 단위로 시험한다. 화면 문구, 행 순서, 숫자 임계값을 확인하는 시험은 만들지 않는다.
- 호환 reader, converter, migration code를 만들지 않는다. 저장 형식이 바뀌는 층은 변경 기록에 `### Fresh state required`를 적는다.
- 인증·인가 코드에는 `(* HIGH-RISK-UNREVIEWED: 이유 *)`를 달고 사람이 검토한다.
- 한 층에서 다음 층으로 넘어가기 전에 이전 층에 적대적 리뷰어를 붙인다. 자기 변경을 자기가 승인하지 않는다.
- 각 층의 결과, 범위, 시험, 되돌리는 길은 그 층을 시작할 때 PR 본문에 적는다. 아래 표는 순서와 경계만 정한다.
- 층의 설계 열에 적힌 절의 의무는 모두 그 층의 범위다. 범위 목록은 구현 때 빠지기 쉬운 것만 적는다. 층 PR 본문의 시험 목록에는 그 절의 의무를 한 줄씩 적는다.
- `Single_user`에서 달라지는 동작이 있으면 그 층의 PR 본문에 적는다. 지금 알려진 것은 A2의 부팅 검사 하나다.
- 층을 시작할 때 §2에서 그 층이 기대는 개수와 줄 번호를 다시 세고, §5에서 그 층이 맡은 설계 문구 정리를 다시 읽는다. 병합된 설계 문서를 고치는 변경은 PR 본문에 따로 적는다.

## 2. 현재 코드에서 확인한 사실

### 인증과 경로

| 영역 | 사실 | 근거 | 층에 주는 영향 |
|---|---|---|---|
| HTTP/1 경로 표 | 경로는 `Router.routes` 하나에 `{kind; path; methods; handler}`로 모인다. 등록 호출은 35개 파일에 382곳이다. 호출 하나가 경로 여럿을 등록하는 곳도 있어 경로 수는 호출 수보다 많다. 경로 레코드에 인증 정보가 없다. 인증은 핸들러 안의 래퍼 클로저이고, 공개 읽기 여부는 경로 문자열 목록(`is_public_read_path`)으로 가른다. | `lib/http_server_eio.ml:641-646, 699`, `lib/server/server_auth.ml:1010, 1291-1396`, `lib/server/server_routes_http_routes_dos.ml:27, 106, 117` | 표만 읽어서는 경로의 인증 처리를 알 수 없다. A1이 실제 요청으로 기준선을 만든다. |
| H2·`/mcp` 표 | H2 게이트웨이는 `(method, path)` match를 따로 가지고 `Router`를 쓰지 않는다. 자기 match 밖의 경로는 `server_h2_gateway_routes_extra.ml`의 `dispatch`에 넘기고, 거기서도 못 찾으면 404다. `/mcp`는 HTTP/1에서 `dispatch_route`가 `Router.dispatch` 앞에서 처리하고(`try_mcp_validation_block` 포함), H2에서는 게이트웨이의 `/mcp` 갈래가 처리한다. | `lib/server/server_h2_gateway.ml:422-423, 606-610, 815-818, 1759-1778`, `lib/server/server_h2_gateway_routes_extra.ml:62`, `bin/main_eio.ml:202-236, 252-265, 372` | 인증 처리를 세는 표가 셋이다(HTTP/1 Router, H2 match, `/mcp` 사전 처리). |
| `token` 쿼리 | `token` 쿼리는 GET `/mcp?sse_kind=observer`와 `/events/presence`, GET `/api/v1/ide/lsp`에서만 읽는다. | `server_auth.ml:110-129, 151-162` | C3이 원격 query credential을 차단한다. |
| 쿠키 | 쿠키는 `mcp-session-id` 하나만 읽고 쓴다. `server_auth.ml`은 이 세션 ID를 참조하지 않는다. | `lib/server/server_mcp_transport_http_session.ml:661-679`, `server_mcp_transport_http_headers.ml:267-270` | C3이 `__Host-` 쿠키를 새로 만든다. |
| CSRF·Origin | CSRF 토큰 장치는 없고 Origin/Referer 검사만 있다. `allow_anonymous_mutations`가 켜져 있으면 Origin이 없는 요청이 같은 출처 검사를 통과한다. | `server_auth.ml:676-743`(Origin이 없을 때 `:688-690`) | C3이 세션에 결속한 CSRF 토큰과 출처 검사를 새로 만든다. |
| WebSocket | `/ws` upgrade는 bearer를 먼저 검사하고, 통과하지 못하면 같은 출처인지 본다. 이후 프레임은 `dispatch_ws_inbound_message`가 `auth_token` 없이 `Mcp_eio.handle_request`로 넘긴다. 인증이 켜져 있으면 인증이 필요한 요청에 `require_auth`가 `Missing_token`으로 답한다. `dashboard/hello`는 토큰을 따로 검증한다. | `lib/server/server_routes_http_routes_frontend.ml:104-155, 177`, `lib/server/server_runtime_bootstrap.ml:1754, 1816-1818`, `lib/mcp_server_eio_protocol.ml:59-67`, `lib/server/server_mcp_transport_ws.ml:444-466` | C3이 WS/SSE를 세션과 PAT에 결속하고 폐기 때 닫는다(설계 §5.2). |
| 호출자 alias | 토큰이 있고 이름이 Ephemeral인데 토큰 해석이 실패하면 경고와 카운터만 남기고 alias를 그대로 돌려준다. `Strict`와 `Dry_run`이 같은 갈래이고, `MASC_AUTH_STRICT`가 없거나 모르는 값이면 `Dry_run`이다. | `lib/mcp_server_eio_caller_identity.ml:157-194`, `lib/auth/auth_strict_mode.ml:8-20` | C4가 다계정에서 이 경로를 없앤다. 모드 값만 바꿔서는 이 경로가 사라지지 않는다. |
| 인증 설정 | `auth_config`는 `enabled`, `workspace_secret_hash`, `require_token`, `token_expiry_hours` 네 필드이고 기본값은 `enabled=true`, `require_token=true`, 24시간이다. 파일은 `<base>/.masc/auth/config.json`이고 디코더는 모르는 필드와 중복 필드를 거부한다. 파일이 없으면 기본값을 쓴다. | `lib/types/types_auth.ml:182-194, 204-218, 290-300`, `lib/auth/auth_credential_base.ml:41, 236-251` | `account_mode`를 필수로 만들면 기존 `config.json`이 디코드되지 않는다. 파일이 없는 설치는 기본값이 `account_mode`를 줄 수 없어 A2의 부팅 검사에서 거부된다. |
| 부팅 | `server_runtime_bootstrap.ml`과 `bin/main_eio.ml`에서 `load_auth_config`나 `is_auth_enabled` 호출을 찾지 못했다. 부팅은 환경변수를 읽고 `Server_auth.configure`를 부를 뿐이다. 깨진 `config.json`은 `load_auth_config`에 닿는 HTTP 요청에서 503이고, MCP JSON-RPC 핸들러에서는 `Internal_error`다. | `server_runtime_bootstrap.ml:1594-1609`, `server_auth.ml:567-578`, `bin/main_eio.ml:283-297, 387`, `server_h2_gateway.ml:1830-1835`, `mcp_server_eio_protocol.ml:1338, 1349` | 부팅 거부는 새 검사다. 위 두 파일 밖의 간접 호출은 확인하지 못했다. |
| 설정 쓰기, 함수 | `auth_config`는 `prepare_login_auth`가 `save_auth_config`로 쓴다. `Auth_login.ensure_local_operator`나 `mint`에서 `create_file_backed_login_token`을 거쳐 이 함수로 온다. `save_auth_config`는 auth 켜기(`enable_auth`)·끄기(`disable_auth`)와 workspace secret 생성에서도 불린다. | `lib/auth/auth_credential_token.ml:526-554`, `lib/auth/auth_login.ml:69, 106-128`, `lib/auth/auth.ml:379, 400`, `auth_credential_base.ml:255-268` | A2가 `Single_user`를 써 넣는 단계는 `prepare_login_auth`와 별도로 둔다. |
| 설정 쓰기, 호출자 | `mint`는 setup·restart 말고 `masc login`, `mcp-config`, TUI도 부른다. 재사용할 수 있는 admin token이 있으면 `ensure_local_operator`는 `mint`를 부르지 않아 아무것도 쓰지 않는다. `masc auth` 하위 명령은 없고 `login`과 `token` 그룹은 있다. | `bin/main_eio.ml:1109, 1261, 1270, 1327, 4396-4416, 4541, 4553`, `bin/masc_tui_http.ml:156`, `auth_login.ml:106-125` | 재사용 토큰이 있는 설치는 `prepare_login_auth`를 거치지 않는다. A2의 쓰기 단계가 따로 있어야 이런 설치도 부팅된다. |

### 실행 진입

| 영역 | 사실 | 근거 | 층에 주는 영향 |
|---|---|---|---|
| Runtime 조회 | 시험을 뺀 호출이 54곳이다. `get_runtime_by_id` 32, `resolve_assignment` 13, `runtime_id_for_keeper` 4, `get_runtime_ids` 3, `capability_of_runtime_id` 1, `keeper_assignments` 1이다. 모두 `Runtime.<fn>`으로 쓰여 별칭이 없다. `keeper_turn_driver.ml`에 12곳이 있다. `capability_of_runtime_id` 1곳은 기본 인자로 넘기는 참조다. | 정의 `lib/runtime/runtime.ml:1086, 1130, 1134, 1433, 1472, 3612`, 공개 `runtime.mli:477, 506, 515, 699, 716, 1264`, 참조 `lib/keeper/keeper_lane_cli_oneshot.ml:268` | 조회 54곳을 하나씩 고치지 않는다. D2가 실행 진입의 타입을 바꾸고 컴파일러가 호출자를 모은다. |
| Keeper 턴 | `run_named`가 `attempt_runtime_candidates`로 후보를 차례로 시도하고, 한 번의 시도(`~run_attempt`)는 provider 갈래 넷 중 하나를 실행한다. `run_codex`, `run_antigravity`, `run_muse`, `run_claude`다. 갈래마다 `Keeper_<provider>_runtime.run`이 Runtime 모듈의 `run_turn`을 부른다. Runtime 모듈의 `run_turn`은 넷이다. `server_routes_http_keeper_stream.ml`에 같은 이름의 지역 함수가 둘 있지만 HTTP 핸들러 안의 함수라 뺀다. | `lib/keeper/keeper_turn_driver.ml:586, 1695, 2211, 2550, 2559, 2715, 2724, 2839, 2857, 2975, 2987`, `keeper_codex_runtime.ml:1481`, `keeper_claude_code_runtime.ml:1330`, `keeper_antigravity_runtime.ml:1058`, `keeper_muse_runtime.ml:1441`, `lib/runtime/runtime_codex_app_server.ml:3177`, `runtime_claude_code.ml:3225`, `runtime_antigravity.ml:1174`, `runtime_muse_serve.ml:1523`, `lib/server/server_routes_http_keeper_stream.ml:2276, 3501` | D2는 Codex와 Claude Code 갈래, D3은 Antigravity와 Muse 갈래다. |
| Keeper 밖 | Runtime 모듈의 `run_turn`을 Keeper 밖에서 직접 부르는 곳이 있다. Fusion, verifier, capability probe다. | `lib/fusion/fusion_official_client.ml:633, 668, 720, 778`, `lib/runtime/runtime_verification.ml:912, 1012`, `runtime_verification_antigravity.ml:33`, `runtime_verification_muse.ml:55`, `lib/keeper/keeper_capability_probe.ml:457, 500, 652` | D2의 타입 변경이 Codex와 Claude Code 호출자를 모은다. Antigravity와 Muse 호출자는 D3이다. |
| 프로세스를 띄우는 조회, Codex·Claude Code | Codex는 `probe_subscription`, `list_models`, `read_rate_limits`가 `probe_metadata`를 거쳐 `with_spawned_client`로 프로세스를 띄운다. 호출자는 `probe_subscription`이 `bin/main_eio.ml`·로그인 클라이언트·대시보드 probe, `list_models`가 모델 갱신, `read_rate_limits`가 사용량 조회다. Claude Code는 `probe_auth_status`가 `claude auth status --json`을 실행한다. | `runtime_codex_app_server.ml:2891, 3136-3174`, `bin/main_eio.ml:2802`, `lib/runtime/runtime_setup_login_client.ml:104`, `lib/server/server_dashboard_official_client_probe.ml:138`, `lib/runtime/runtime_codex_model_refresh.ml:32`, `lib/runtime/runtime_provider_usage_read.ml:78`, `runtime_claude_code.ml:658` | D3이 이 호출자를 같은 타입으로 바꾼다. |
| 프로세스를 띄우는 조회, Muse | Muse에도 `with_spawned_client`가 따로 있고 `run_turn`, `read_usage`, `list_models`가 쓴다. 호출자는 `read_usage`가 사용량 조회, `list_models`가 모델 탐색이다. | `runtime_muse_serve.ml:658, 1523-1550, 1576, 1586`, `runtime_provider_usage_read.ml:101`, `lib/runtime/runtime_muse_model_discovery.ml:40` | D3이 같은 타입으로 바꾼다. |
| 로그인 | 로그인은 `codex login --device-auth`와 `claude auth login`을 실행한다. | `lib/runtime/runtime_setup_login_session.ml:138`, `runtime_setup_login_client.ml:83-84`, `bin/masc_cli_account_login.ml:30-32` | D1의 ProviderLink 검사에 속한다. |
| 따라가지 못한 곳 | vision 경로(`keeper_vision_tool.ml`이 `Runtime_claude_code`의 오류 타입을 쓴다), `masc_cli_prerequisites.ml`, `runtime_official_cli_install.ml`이 프로세스를 띄우는지 따라가지 않았다. `keeper_lane_cli_oneshot.ml`에서는 `Eio.Process`, `create_process`, `spawn`을 쓰는 줄을 찾지 못했고, 실제로 실행하는 모듈은 따라가지 않았다. | `lib/keeper/keeper_vision_tool.ml:544-549`, `bin/masc_cli_prerequisites.ml:93-102`, `lib/runtime/runtime_official_cli_install.ml:91-110` | D3의 첫 일이다. |
| API provider | API provider 실행 경로는 조사하지 않았다. `Keeper_agent_run.run_turn`이 `runtime_id`를 받는 별도 진입이지만 어떤 provider를 부르는지는 읽지 않았다. | `lib/keeper/keeper_agent_run.ml:632` | D4의 첫 일은 조사다. |
| 이름 겹침 | `before_dispatch_authority`는 dispatch 직전 검사다. Keeper가 있고, 멈추지 않았고, source batch가 아직 pending인지만 본다. 사용자 권한과 다른 개념이다. | `lib/keeper/keeper_unified_turn_execution.ml:42-49, 98`, `keeper_heartbeat_loop_cycle.ml:236-237`, `keeper_turn_dispatch_authority.ml:1-4`, `keeper_heartbeat_loop.ml:1032-1075` | 이름을 섞지 않고 합치지도 않는다. |

### 저장소·의존성·진행 중인 일

| 영역 | 사실 | 근거 | 층에 주는 영향 |
|---|---|---|---|
| 원장 선례 | `Candle_ledger`는 프로세스 배타 lock을 쓰고, 다른 프로세스가 lock을 쥐고 있으면 기다리지 않고 `Lock_held_by_another_process`를 돌려준다. blocking 파일 작업은 system thread로 격리한다. `Fs_compat`에 atomic 저장과 stable lock이 있다. `Jsonl_writer.append_jsonl`은 `Fs_compat.append_jsonl`로 넘기고, 그쪽은 경로별 프로세스 내부 mutex와 flush만 쓴다. fsync와 프로세스 간 lock은 보이지 않는다. | `lib/candle_store/candle_ledger.ml:59-93, 219-227`, `candle_ledger.mli:6-7, 36-37, 60-61`, `lib/fs_compat/fs_compat.mli:408-481, 1244-1252, 1332-1337`, `lib/jsonl_writer/jsonl_writer.ml:15-16`, `fs_compat.ml:231-237, 5073-5087` | B1이 `Candle_ledger`의 방식을 따른다. `authz.jsonl`은 append와 fsync가 필요하므로(설계 §8.1) `Jsonl_writer`를 쓰지 않는다. |
| OIDC 라이브러리 | JWT·JWKS 서명을 검증하는 코드와 JOSE 의존성이 없다. 후보는 opam의 `jose 0.11.0`(MIT, x509 >= 0.13.0·mirage-crypto >= 1.0.0·yojson 요구)과 `jwto 0.4.0`(MIT, digestif·fmt 요구)이다. 현재 pin은 `x509 >= 1.0 & < 1.2`이고 lock은 1.0.6이다. 서명을 만드는 코드(GitHub App용 RS256)와, 서명을 검증하지 않고 `id_token`의 클레임에서 이메일만 읽는 코드가 이미 있다. MCP OAuth는 토큰을 불투명 값으로 다루고 해시로 저장한다. | `dune-project:123-129`, `masc.opam:52-55`, `masc.opam.locked:201`, `opam show jose jwto`, `lib/keeper/keeper_github_app_broker.ml:54-66`, `lib/runtime/runtime_account_email.ml:72-91`, `lib/auth/auth_oauth.ml:57-58, 216` | C1이 고른다. 서명 없는 클레임 읽기는 C1의 검증기와 합치지 않는다. |
| 진행 중 스택 | MCP OAuth 스택은 #46336, #46337, #46340, #46343, #46356, #46379로 이어진 PR 6개이고 모두 열려 있다(draft 아님, 2026-10-27 확인). 맨 아래 #46336은 main을 base로 하고 병합되지 않았다. 이 스택이 `auth_oauth.ml`, `auth_oauth_client_metadata.ml`, `server_oauth_*.ml`을 바꾸고, `env_setting.ml`은 #46356만 바꾼다. | `gh pr view` 파일 목록 | 이 계획의 층은 그 파일을 건드리지 않는다. C5만 그 스택이 main에 들어간 뒤에 연다. |

센 방법은 아래와 같다.

```text
등록 호출: rg -n 'Router\.(get|post|put|delete|any|ws_get|prefix_get|prefix_post|prefix_delete|prefix_put|add|add_kind)\b' --glob '*.ml' lib bin
  385줄에서 주석에만 나오는 3줄(bin/main_eio.ml:247,315, server_mcp_transport_ws.ml:1190)을 뺀 382곳, 35개 파일.
Runtime 조회: rg -n --glob '*.ml' '\bRuntime\.(get_runtime_by_id|resolve_assignment|runtime_id_for_keeper|get_runtime_ids|capability_of_runtime_id|keeper_assignments)\b' lib bin
  정의 모듈 lib/runtime/runtime.ml을 빼면 58줄이고, 주석에만 나오는 4줄을 뺀 54곳.
```

## 3. 층 목록

층은 모두 27개다. 크기가 20k token을 넘는 층은 시작할 때 쪼갠다.

### A. 측정과 기반

이 그룹에서 A2를 뺀 층은 `Single_user` 동작을 바꾸지 않는다.

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| A1 | 모든 경로가 지금 인증을 어떻게 처리하는지 실제 요청으로 잰 기준선. HTTP/1 경로는 라우터를 격리한 base path로 띄워 무인증 요청과 잘못된 bearer 요청을 보낸다. H2, `/mcp` 사전 처리, `/ws`는 실제 소켓으로 따로 친다. 결과는 `docs/evidence/`에 둔다. 동작은 바꾸지 않는다. | §5.3, §11-1 | - |
| A2 | `auth_config.account_mode`를 필수 필드로 두고 부팅 때 검사한다. 값이 없거나 모르는 값이면 부팅을 거부한다. `Multi_account`는 `enabled=false`, `require_token=false`, `MASC_ALLOW_ANONYMOUS_MUTATIONS=true`를 거부한다. setup과 restart가 `Single_user`를 써 넣는 단계는 `prepare_login_auth`와 별도로 둔다(§2의 설정 쓰기). 기존 `config.json`으로 띄운 서버가 setup·restart 뒤 부팅되는지 재사용 토큰이 있는 설치까지 시험한다. 변경 기록에 `Fresh state required`를 적는다. | §5.1, §5.3 | - |
| A3 | 권한 도메인의 닫힌 타입(Principal, Effect, Channel, Runtime_scope, Authorization_scope, ExecutionContext, grant, policy, record의 author)과 판정식 `allowed`. I/O 없는 순수 코드다. 시험은 deny 기본, `Empty`, `Not_pat`, scope·channel·effects 교집합을 표로 확인한다. | §4, §6.2, §6.3 | - |

### B. 권한 저장소

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| B1 | `authz.jsonl`: append-only, 프로세스 배타 writer lock, lock-free snapshot, replay. `Candle_ledger`의 방식을 따른다. writer는 record 종류와 author 종류의 짝을 검사한다(§6.3). `RuntimeGrant`, `DelegatePolicy`, `Principal`, `InternalServiceCredential`, 명시적 permission revocation은 인증된 author가 필요하고, `System_cron`, `System_maintenance`, `System_migration`이 쓸 수 있는 record는 정해져 있다. lease 계열 group commit은 E1에서 붙인다. | §6.3, §8.1 | A3 |
| B2 | backup 밖 append-only 저장소(설계의 외부 고수위·revocation ledger)와 `Intent_pending`/`Committed`. 저장소는 객체의 scoped epoch 최고값, artifact별 `credential_generation`, Intent 상태를 기록한다. Intent의 subject는 grant·credential·principal·Runtime 중 하나다(§4.5). 같은 writer lock 구역, 판정 갈래 1~5, `AuthorizationUncertain`, `Revocation_pending` 게이트, `Fresh_bootstrap`. 갈래마다 고장 주입 시험을 둔다. 저장소의 위치를 받는 방식을 먼저 정한다(§6의 결정 2). | §4.5, §8.2~8.4 | B1 |
| B3 | Principal·Admin_assignment·WorkspaceMembership·초대 저장소, 마지막 Admin 보호, 호스트 로컬 bootstrap, ID 발급 규칙, principal 삭제 사건. 세부는 표 아래 B3 범위다. | §4.1, §5.1 | B1, B2 |
| B4 | `Purge_pending`, `Purged`, `Purge_failed` 사건과 현재 상태 판정(target의 마지막 사건이 현재 상태, target 단위 멱등), `Purge_pending` 대상의 읽기 거부, 재기동 때 남은 `Purge_pending` 목록. `Purge_pending` 지정은 §8.2의 scoped epoch 사건이라 `Intent_pending`/`Committed` 규칙을 따른다(initiator 삭제이면 `Delete` 사건). 삭제는 하지 않는다. 삭제 실행기는 F1이다. | §8.5 | B2, B3 |

**B3 범위**

- ID 발급(§4.1): Human `user_id`는 OS CSPRNG가 만든 128비트 이상의 값이고 `(iss, sub)`나 email에서 유도하지 않는다. 발급은 writer lock 안에서 현재 principal과 ledger의 `Delete` 기록을 대조한다. `user_id`가 겹치면 다시 뽑고, `service_id`가 겹치면 등록을 거부하고, ledger를 읽지 못하면 발급하지 않는다.
- 삭제 사건(§4.1): `(iss, sub)`는 `authz.jsonl`의 사건에만 싣고 ledger의 `Delete` 기록에는 ID만 둔다.
- 표시가 붙은 상태는 D6에서 처음 생긴다. D6 전에는 삭제가 올릴 `Purge_pending` 대상이 없다.

### C. 인증

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| C1 | OIDC ID token 검증 의존성 결정. `jose`와 `jwto`를 현재 pin(x509 >= 1.0, < 1.2), OCaml 5.5, RS256, `alg=none` 거부, JWKS `kid` 선택으로 비교한 근거를 남기고 하나를 추가한다. 고정한 JWKS와 token 벡터로만 시험하고 네트워크를 쓰지 않는다. | §5.2 | - |
| C2 | Google OIDC code + PKCE 로그인, `(iss, sub)` 결속, 초대 소비(동시 소비는 409). 삭제된 principal의 `(iss, sub)`로 등록하거나 소비하면 Admin 화면과 감사 기록에 `previously_deleted`를 보인다. 입장을 막지 않는다. 이 표시는 `authz.jsonl`을 읽어 만들고 principal 레코드에는 저장하지 않는다(§5.1-6). | §5.1, §5.2 | B3, C1 |
| C3 | 다계정에서 `__Host-` 세션·transaction·mcp 쿠키, 세션에 결속한 CSRF 토큰, 출처 검사, cookie와 Bearer가 함께 오면 거부, WS/SSE 결속과 폐기 때 닫기, 원격 query credential 차단. | §5.2, §5.3 | C2 |
| C4 | scoped PAT와 Service credential 레코드(principal + `Pat_scope`), 새 `Auth_gate.decide`로 HTTP strict와 MCP caller strict 통합, 다계정에서 caller alias 유지·workspace secret(HTTP 복구 grace 포함, `auth.ml:216`)·auth disabled 경로 제거, `agent_credential` 읽기 거부. `Mcp_oauth_token`은 C5 전까지 Reject. | §5.3 | A2, A3, C3 |
| C5 | MCP OAuth 승인을 OIDC session에 결속한다. OAuth 스택(#46336, #46337, #46340, #46343, #46356, #46379)이 main에 들어간 뒤에만 연다. 결속 전에는 C4의 Reject가 그대로다. | §5.3 | C3, C4, OAuth 스택 병합 |

### D. 소유권과 실행 게이트

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| D1 | ProviderAccount·Runtime owner 검사(setup, raw TOML, 부팅), Runtime 생성과 같은 append의 Self grant, `CanAdmin`에서 `ManageOwnProvider` 분리, ProviderLink의 membership·namespace 검사(로그인을 시작하는 `runtime_setup_login_session.ml:138` 포함). | §4.2~4.3, §5.4 | B3, C4 |
| D2 | `Runtime_view.t`와 abstract `Authorized_runtime.t`, `Runtime.authorize`. Codex와 Claude Code의 `run_turn`, 그 위의 Keeper 경로(`Keeper_codex_runtime`, `Keeper_claude_code_runtime`, `run_codex`·`run_claude` 갈래)가 `Authorized_runtime.t`를 요구하게 바꾼다. 직접 호출자(Fusion, verifier, capability probe)는 컴파일러가 모아 같이 바꾼다. | §6.1 | A3, D1 |
| D3 | 나머지 실행 진입을 같은 타입으로 바꾼다. Antigravity와 Muse의 `run_turn`, 그 Keeper 래퍼(`Keeper_antigravity_runtime`, `Keeper_muse_runtime`)와 `run_antigravity`·`run_muse` 갈래, 그 밖의 호출자(verifier, Fusion, capability probe), 프로세스를 띄우는 조회(Codex `probe_metadata`의 호출자, Claude `probe_auth_status`, Muse `with_spawned_client`의 호출자). 첫 일은 §2에서 따라가지 못한 곳을 조사하는 것이다. 두 Runtime을 공유 대상으로 열지는 §6의 결정 4가 정한다. | §6.1 | D2 |
| D4 | API provider 실행 경로를 조사하고 같은 타입으로 바꾼다. | §6.1 | D2 |
| D5 | Delegated grant, MachineSharePolicy, DelegatePolicy, channel, 영속 작업의 initiator/executor 재검사. 자동 만료는 `Preauthorized_expiry(cause_event_id)`로 닫는다(§6.3). §6.2 판정이 `Purge_pending`을 거부 사유로 쓴다. `Purge_pending` initiator의 새 dispatch와 새 shard 쓰기를 거부한다. | §4.3~4.4, §6.2, §6.3, §8.5-1, §8.5-3 | D2, B3, B4 |
| D6 | Keeper 지속 상태(컨텍스트·기억·산출 글)에 initiator 표시를 붙이고, `Read_state`가 허용되지 않으면 initiator별 분리 컨텍스트로 돌린다. 파생 상태는 원천 initiator를 표시하고 읽는 쪽에 `Source_sealed`·`Source_purged`를 돌려준다. principal 삭제 연산은 `Delete` 사건과 같은 append로 표시된 몫을 `Purge_pending`에 올린다. 세부와 첫 일은 표 아래 D6 범위다. | §3-11, §6.2, §8.5 | D2, D5, B3, B4 |

**D6 범위**

- 사람 initiator가 없는 dispatch(autonomous, system)가 만든 상태는 `Service(system)` 표시를 달고 `Read_state`가 허용된 initiator에게만 보인다(§3-11).
- 봉인은 읽을 때 원천 initiator의 현재 상태로 판정한다. 봉인 표시를 저장하지 않는다. 저장하면 initiator가 Active로 돌아와도 풀리지 않는다(§3-11).
- 표시를 붙이면 저장 형식이 바뀐다. 기존 상태를 어떻게 할지는 §6의 결정 5가 정한다.
- 첫 일은 조사이고 산출물은 표다. 칸은 다섯이다. ① 파생 상태를 만드는 자리(요약, 병합된 기억 등) ② 내용 주소로 공유되는 blob과 artifact ③ 이미 퍼진 복사본(산출 글, artifact 게시본, checkpoint, 백업, 로그와 trace) ④ 쓰기 경로의 미러와 이중 저장 ⑤ initiator 표시를 붙일 수 있는 키가 저장소에 있는지. 표시를 붙일 수 없는 저장소가 나오면 D6을 쪼개거나 이 계획을 고친 뒤 시작한다.

### E. official client 격리

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| E1 | `Lease_state`와 `with_lease` 출구 규칙(§7.1), `consume` 한 번, 재기동 규칙, attempt 종단 셋(`Failed(Outcome_unknown)`, `Failed(Not_started)`, `Cancelled_before_effect`, §9-5), lease 계열 group commit. group commit은 B2의 writer lock 구역(`Intent_pending`부터 `Committed`까지) 동안 끼지 않는다(§8.2-1). | §7.1, §8.2-1, §9-3~9-5 | B1, D2 |
| E2 | account-home single-flight, 점유 영속, 단일 FIFO, owner·Admin의 `Executor_teardown`, `account_busy`. mount와 spawn은 `Lease_dispatched` 기록 뒤에만 하고, 실행 전 실패와 `Effect_cancel`은 종단 기록(`Completed(Not_started)`)을 남긴다(§7.2). 효과가 나간 dispatch의 `Completed(Effected)`는 E1의 출구 규칙이 기록한다. | §7.2, §9.1~9.2 | E1 |
| E3 | credential/state 분리, lane 증명(저장소 종류와 `state_separation` 포함), attestation. | §5.4-6, §7.2, §9 | E2 |
| E4 | dispatch 전용 MCP credential. | §7.3 | E1 |

### F. 삭제·복원·준비

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| F1 | purge 삭제 실행기. 삭제는 대상에 쓸 수 있는 dispatch가 모두 종단에 이른 뒤에 시작하고, 종료를 확인하지 못하면 `Purge_failed {Writer_not_terminated}`로 끝낸다. 진행 중인 dispatch는 지정이 올리는 epoch가 회수하고(E1의 `Revoked(Grant_revoked)`) E2의 `Executor_teardown`이 끊는다. F1은 종료 확인만 기다린다. 대상 표시가 붙은 shard·transcript·credential을 writer lock 밖에서 ID 단위로 멱등하게 지우고, 남은 대상이 0이면 `Purged`를 append한다. 재기동 때 남은 `Purge_pending`을 이어서 지운다. `Purge_failed`는 Dashboard와 `/health`에 보인다. | §8.5, §10.4 | B4, D5, D6, E3 |
| F2 | 복원·전이 분류와 전이 창의 규칙. 복원 창, `Recovery_manifest`, `restore_disposition`(`Pending`, `Denied`, `Cleared`, `Quarantined`, `Purged`), `Integrity_carry_forward` 계승, 적격 Admin 규칙. 복원본에서 되살아난 principal 레코드를 ledger의 `Delete` 기록과 먼저 대조하고, 컨텍스트 shard와 파생 상태를 분류한다(분류 전 읽기는 `AuthorizationUncertain`). 세부는 표 아래 F2 범위다. | §10.1~10.5 | B2, B3, D5, F1 |
| F3 | 모드 전환(on→off)과 새 명령 `masc auth recovery`. 세부는 표 아래 F3 범위다. | §10.5 | F2 |
| F4 | 최초 활성화 전이와 귀속. initiator가 없는 기존 durable work는 `Denied(legacy_unattributed)`로, scope가 없는 것은 `legacy_scope_missing`으로 분류하고, 총계·`Denied`·`Cleared`·미분류를 Local_operator 이름으로 기록해 미분류 0을 확인한다. 소유자가 없는 자산은 dry-run 뒤 bootstrap principal에 `candidate_owner`와 `Self.status=Revoked(Attributed_unclaimed)`로 귀속하고, 후보 목록을 후보 본인·Admin·Local_operator에게 보인다. 후보가 현재 OIDC 인증과 `ManageOwnProvider`와 provider 재인증을 마치면 claim append가 새 grant_id의 Active Self를 만든다. 귀속하지 못한 자산은 Disabled로 두고 MachineShared로 올리지 않는다. | §10.3, §10.5 | D1, D5, F2 |
| F5 | `MultiAccountReadiness` 실행기와 증거 묶음. | §11 | 모든 층 |

**F2 범위**

- 실행은 그 record가 의존하는 모든 record의 `cleared_epoch`가 현재 `transition_epoch`와 같을 때만 허용한다. 과거 epoch의 `Cleared`는 현재 권한이 아니다(§10.1).
- 변경·누락·판정 불일치가 있는 record만 `Pending`으로 남는다. `Pending`은 Active인 원 owner, 원 승인자, 또는 Service를 이어받도록 Admin이 지정한 principal이 `Owner_revalidated`로 닫는다(§10.1).
- 창은 manifest 게시와 모든 record·artifact의 분류가 끝나는 시점에 닫는다. `Pending`이 0이라는 뜻이 아니다. 분류 도중 크래시하면 같은 `transition_epoch`와 manifest로 이어서 분류한다(§10.1).
- 분류할 수 없는 record는 `Denied(unclassifiable)`로 확정한다. credential을 품은 record는 `CredentialUncertain`으로 두고 Quarantined로 보낸다. 창 중 purge로 사라진 항목은 `Purged_during_window`로 센다(§10.1).
- Block record는 `cause`(`Security_incident` 또는 `Operational`)를 필수로 갖는다. `Security_incident`의 해제는 적격 Admin만 한다. 적격 Admin이 없으면 Local_operator가 `Quarantined(cause=No_eligible_admin)`로 기록한다. 부재가 확인된 owner의 `Pending`은 Local_operator의 `Quarantined`로만 끝낸다(§10.4).
- 복원·롤백 직후 모든 공유와 실행은 `AuthorizationUncertain`이다. 복원본에서 되살아난 account-home과 credential artifact는 `CredentialUncertain`이고, owner가 provider 재인증과 새 credential generation 검증을 마치기 전에는 mount하지 않는다. 일반 재기동은 generation이 같으면 재인증 없이 검증한다(§10.5).
- ledger 현재본은 backup과 분리된 저장소에 두고 backup 사본과 합집합으로 대조한다. T에 백업하고 T+1에 revoke한 뒤 T+2에 복원해도 revoke가 유지되고, 연결된 work가 `Denied`이고, 유효한 lease가 0임을 시험한다(§10.5).
- 전이를 시작하기 전에 새 dispatch·새 grant·새 durable work를 먼저 거부한다. 진행 중인 dispatch는 §9-5에 따라 종결한다(§10.2).
- 창 중에는 `Read_only` dispatch도 새로 받지 않는다. 긴급 Block·Disable·Revoke는 창 중에도 거부하지 않는다. 창 중 도착한 효과는 성공한 work로 적용하지 않고 새 record로 현재 epoch 검사를 받는다(§10.2).
- account-home은 unmount를 확인하기 전까지 `Release_pending`이다(§10.2).
- 복구 안내 Board 글은 typed `recovery_notice`로 표시한다. Keeper wake는 subscription 후보 생성 필터와 dispatch 진입 검사 양쪽에서 뺀다. 일반 Board 글에 문자열로 wake를 끄는 규칙은 두지 않는다. 작성자는 Local_operator와 manifest 게시 시스템 이벤트뿐이다. 창이 닫히면 `closed`로 바꾸되 wake 제외는 유지한다. Cleared 승인자에게는 wake 대신 Dashboard 배지와 별도 inbox로 자기 항목 수를 보여 준다(§10.2).
- 그 밖에 §10.1~§10.5가 정한 의무도 이 층의 범위다. 재검증 순서, `Recovery_manifest`의 접근 제한, Disabled·삭제·purged 주체의 durable work를 먼저 `Denied`로 확정하는 것, `Outcome_unknown` lease를 되살리지 않는 것, 창 중 도래한 `Preauthorized_expiry`를 분류 단계에서 다시 유도하는 것이다.
- 크기가 20k token을 넘으면 분류(§10.1, §10.4, §10.5)와 전이 창 규칙(§10.2)으로 쪼갠다.

**F3 범위**

- on→off 전환은 multi-owned record를 읽기 전용으로 보존하고 legacy 공유 token·admin으로 실행하지 않는다. 진행 중인 multi dispatch는 §9-5에 따라 종결하고 session은 닫는다. account-home 점유는 `Release_pending`으로 바꿔 unmount를 확인한 뒤에만 Released로 한다. 다시 켜면 같은 `Recovery_manifest`와 `Pending` 절차를 거친다.
- `masc auth recovery --base-path <path>`는 인증 가능한 Admin이 0명이거나 IdP를 쓸 수 없을 때 연다. 호스트 관리자와 root 소유 일회용 recovery 파일이 필요하다. 실행자·사유·시각·결과·파일 digest·파기 결과를 append-only audit와 Board에 남긴다. 원격 break-glass는 없고 활성화 전에 리허설한다. 이 경로에서 Local_operator는 `Admin_assignment`를 새로 발급할 수 있고, 발급받은 principal의 grant와 `Cleared`에는 관여하지 않는다.

## 4. 순서와 첫 마일스톤

- A, B, C1은 서로 거의 독립이라 병렬 스택으로 쌓을 수 있다. 나머지 순서는 층 표의 선행 열을 따른다.
- D2와 D3은 `Single_user`에서 동작을 바꾸지 않도록 `Runtime.authorize`가 모드에 따라 근거를 달리 발급해야 한다. 설계 §6.1이 이 점을 정한다. 이 근거가 없으면 D2는 시작하지 않는다.
- 설계 §11의 readiness가 복구 리허설과 official lane 격리 증거를 요구하고, 설계 §10.5가 최초 활성화 때 미분류 0을 요구한다. 그래서 F1~F4와 E3 없이는 원격 다계정을 열 수 없다. 그 앞까지의 층은 다계정을 켜지 않은 채 main에 들어갈 수 있다.
- 첫 마일스톤은 A~D3이다(2026-10-27 사용자 결정). A2의 부팅 검사를 빼면 `Single_user` 동작은 그대로이고 타입과 저장소와 로그인 경로만 들어간다. C5는 OAuth 스택이 병합된 뒤에만 열리므로 병합 시점에 따라 이 마일스톤 안이나 밖에 놓인다. D4~D6, E, F는 이 마일스톤이 병합된 뒤에 연다.
- readiness 증거는 층이 만든다. 각 층의 PR 본문이 자기 증거를 적고, F5는 그 증거를 모아 표면 digest에 결속하는 실행기만 만든다.

| 설계 §11 readiness 증거 | 만드는 층 |
|---|---|
| route inventory | A1 |
| `auth disabled`·`require_token=false` 부팅 거부 | A2 |
| 경로별 Reject·CSRF·credential 단일성 | C3, C4 |
| `legacy_workspace_secret_callers=[]`, `agent_credential_callers=[]` | C4 |
| C5 전의 `Mcp_oauth_token` Reject | C4 |
| string만으로 실행 객체를 얻는 경로의 잔존 0 | D2, D3, D4 |
| Provider 두 계정 호출과 제3자 거부 | D1, D5 |
| official lane 격리 | E3 |
| 복구 리허설 | F2, F3 |
| Single_flight 대기 시간(§11-6) | E2 |

계획이 더하는 증거가 셋 있다. 기존 설치가 업그레이드 뒤 부팅된다(A2), 과거 epoch의 `Cleared`가 실행되지 않는다(F2), 최초 활성화 때 미분류가 0이다(F4)다. 셋 다 F5의 묶음에 넣는다.

## 5. 설계 문구 정리

병합된 설계에 남은 문구와 빈칸 7건이다. 해당 설계를 구현하는 층의 PR이 설계 문서도 같이 고친다.

| 번호 | 설계 | 할 일 | 층 |
|---|---|---|---|
| 1 | §7.2, §12 | 실패 목록의 표현을 하나로 맞춘다. §7.2는 "연결이나 spawn", §12는 "mount나 spawn"이라 쓴다. | E2 |
| 2 | §9-5 | timeout으로 `Executor_teardown`된 `Issued` lease의 attempt 종단을 정한다. `Failed(Not_started)`인지 기존 `Timeout` 실패인지 문서에 없다. | E2 |
| 3 | §9.1 | owner가 취소한 대기 항목의 attempt 종단은 `Cancelled_before_effect`로 적고, 새 attempt를 만드는 일은 기존 failover 규칙에 맡긴다고 나눠 적는다. | E2 |
| 4 | §9-3, §9-4, §9.1 | `Outcome_unknown` 출구 괄호가 같은 말을 되풀이한다. §7.1을 가리키는 한 줄로 줄인다. | E1 |
| 5 | §9-5 | "attempt 종단 전체의 목록은 기존 dispatch 정책이 소유한다"의 코드 위치를 적는다. `duplicate_possible`은 설계 문서에만 있고 저장소의 코드에는 없다. 종단 타입을 찾는 일이 E1의 첫 일이다. | E1 |
| 6 | §12, §13 | 300 Keeper 성능 실측을 누가 어디에 남기는지 정한다. 각 층이 자기가 만든 경로의 값을 `docs/evidence/`에 측정 조건(커밋, 호스트, 부하 크기)과 함께 남기고 F5가 모은다. Single_user 기준선과 Single_flight 대기 시간은 E2가 잰다. 300 Keeper 부하 발생기가 이미 있는지는 확인하지 못했다. | E2, F5 |
| 7 | §6.2, §8.5-1, §8.5-3 | §8.5가 위임한 `Purge_pending` 거부를 §6.2의 거부 목록에 적는다. §6.2는 "Disabled이거나 삭제된 principal"만 거부한다고 말한다. | D5 |

## 6. 결정이 필요한 것

1. **OIDC 라이브러리.** C1이 비교한 근거를 PR 본문에 쓰고 하나를 고른다. 직접 구현하지 않는다. constitution이 보안·암호는 기존 라이브러리를 쓰라고 한다.
2. **외부 고수위 저장소의 위치.** 설계는 "backup 밖"만 요구한다. 경로를 코드에 박을 수 없으므로 설정 키나 설치 기록으로 받아야 하는데, 어느 쪽인지 정해지지 않았다. B2 전에 사용자에게 묻는다.
3. **경로별 인증 처리를 타입으로 붙일지.** A1이 측정한 결과를 보고 정한다. 타입으로 붙이면 등록 호출 382곳과 H2 표를 함께 바꿔야 하므로 층이 여럿 늘어난다. 측정기만 두면 새 경로가 생길 때 사람이 다시 측정해야 한다. A1 뒤에 사용자에게 묻는다.
4. **Antigravity·Muse Runtime의 공유.** 설계는 이 둘을 다루지 않는다. 설계 §3-10은 증명 없는 공유를 거부하므로, 공유 대상으로 열려면 §7.2 같은 lane 증명이 필요하다. D3이 두 Runtime의 credential 위치를 조사한 뒤, 공유를 거부로 둘지 설계를 넓힐지 사용자에게 묻는다.
5. **이전 형식 데이터.** 저장소 규칙은 호환 reader 없이 `Fresh state required`인데, 설계에는 이전 형식 데이터를 읽는 규칙이 있다. D6가 Keeper 상태에 initiator 표시를 붙이면 기존 컨텍스트·기억·산출 글이 표시 없는 상태가 되고, 설계 §10.5는 표시 없는 Keeper 상태를 읽을 수 있는지 정하지 않는다. `cause`가 없는 기존 Block을 `Security_incident`로 보는 규칙(§10.4-1)도 같은 문제다. 저장소 규칙대로면 D6 배포 때 기존 Keeper 상태를 따로 보관하고 새로 시작한다. D6의 조사 표가 나온 뒤와 F2를 시작할 때 사용자에게 묻는다.

## 7. 위험과 미확인

1. 경로 표가 셋(HTTP/1 Router, H2 match, `/mcp` 사전 처리)이다. 하나로 합치지 않으면 인증 처리를 한 곳에서 셀 수 없다.
2. `account_mode` 필수화는 기존 설치를 부팅 거부로 만든다. 값을 써 넣는 단계가 `prepare_login_auth` 밖에 있어야 하고(재사용 토큰이 있으면 그 함수를 거치지 않는다), 라이브 서버에는 배포 순서를 정해야 한다.
3. API provider 실행 경로를 조사하지 않았다. D2가 Codex와 Claude Code의 `run_turn`만 막으면 다른 경로로 우회할 수 있다. D3과 D4 전에는 `Multi_account`를 열지 않는다.
4. JOSE 후보를 현재 pin과 함께 풀어 보지 않았다. `jose`는 x509 >= 0.13.0을 요구하고 lock은 1.0.6이라 하한은 맞다. 상한과 다른 의존성은 opam 해결기로 확인하지 않았다.
5. A1의 실제 요청은 열려 있는 변경 경로를 실행할 수 있다. 격리한 base path, Keeper 없음, loopback만 쓴다. 경로 인자는 형식이 맞는 존재하지 않는 값을 쓴다.
6. 이 조사는 코드를 읽은 것이다. 빌드와 실행은 하지 않았다. 줄 번호는 `d595f10978db` 기준이라 main이 움직이면 어긋난다.

## 8. MASC 등록

- Goal은 이 계획이 승인된 뒤에 만든다. 성공조건은 층마다 병합된 PR이 하나씩 있는 것이다. 지표는 병합된 층 PR 수이고 목표값은 27이다.
- Task는 층마다 `goal_id`를 붙여 만든다. 층 하나가 Task 하나이고, PR 번호는 Task에 적는다.
