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
- `Single_user`에서 달라지는 동작이 있으면 그 층의 PR 본문에 적는다.
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
| 호출자 alias | 토큰이 있고 이름이 Ephemeral인데 토큰 해석이 실패하면 경고와 카운터만 남기고 alias를 그대로 돌려준다. | `lib/mcp_server_eio_caller_identity.ml:157-180` | C4가 다계정에서 이 경로를 없앤다. |
| 인증 설정 | `auth_config`는 `enabled`, `workspace_secret_hash`, `require_token`, `token_expiry_hours` 네 필드이고 기본값은 `enabled=true`, `require_token=true`, 24시간이다. 파일은 `<base>/.masc/auth/config.json`이고 디코더는 모르는 필드와 중복 필드를 거부한다. 파일이 없으면 기본값을 쓴다. | `lib/types/types_auth.ml:182-194, 204-218, 290-300`, `lib/auth/auth_credential_base.ml:41, 236-251` | `account_mode`는 선택 필드이고 없으면 `Single_user`라서 기존 `config.json`과 파일이 없는 설치가 그대로 읽힌다. 필드를 모르는 옛 바이너리는 필드가 든 파일을 읽지 못한다. 디코더가 모르는 필드를 거부하기 때문이다. |
| 부팅 | `server_runtime_bootstrap.ml`과 `bin/main_eio.ml`에서 `load_auth_config`나 `is_auth_enabled` 호출을 찾지 못했다. 부팅은 환경변수를 읽고 `Server_auth.configure`를 부를 뿐이다. 깨진 `config.json`은 `load_auth_config`에 닿는 HTTP 요청에서 503이고, MCP JSON-RPC 핸들러에서는 `Internal_error`다. | `server_runtime_bootstrap.ml:1594-1609`, `server_auth.ml:567-578`, `bin/main_eio.ml:283-297, 387`, `server_h2_gateway.ml:1830-1835`, `mcp_server_eio_protocol.ml:1338, 1349` | A2의 부팅 판정은 새 검사다. 위 두 파일 밖의 간접 호출은 확인하지 못했다. |
| 설정 쓰기, 함수 | `auth_config`는 `prepare_login_auth`가 `save_auth_config`로 쓴다. `Auth_login.ensure_local_operator`나 `mint`에서 `create_file_backed_login_token`을 거쳐 이 함수로 온다. `save_auth_config`는 auth 켜기(`enable_auth`)·끄기(`disable_auth`)와 workspace secret 생성에서도 불린다. | `lib/auth/auth_credential_token.ml:526-554`, `lib/auth/auth_login.ml:69, 106-128`, `lib/auth/auth.ml:379, 400`, `auth_credential_base.ml:255-268` | `save_auth_config`가 레코드를 통째로 다시 쓰므로 `account_mode`는 `auth_config` 레코드 안에 둔다. 부팅 전용 디코더로 빼면 이 쓰기들이 필드를 지운다. |

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
| 원장 선례 | `Candle_ledger`는 프로세스 배타 lock을 쓰고, 다른 프로세스가 lock을 쥐고 있으면 기다리지 않고 `Lock_held_by_another_process`를 돌려준다. blocking 파일 작업은 system thread로 격리한다. `Fs_compat`에 atomic 저장과 stable lock이 있다. `Jsonl_writer.append_jsonl`은 `Fs_compat.append_jsonl`로 넘기고, 그쪽은 경로별 프로세스 내부 mutex와 flush만 쓴다. fsync와 프로세스 간 lock은 보이지 않는다. | `lib/candle_store/candle_ledger.ml:59-93, 219-227`, `candle_ledger.mli:6-7, 36-37, 60-61`, `lib/fs_compat/fs_compat.mli:408-481, 1244-1252, 1332-1337`, `lib/jsonl_writer/jsonl_writer.ml:15-16`, `fs_compat.ml:231-237, 5073-5087` | B1b가 `Candle_ledger`처럼 lock을 기다리지 않고 거절하고, blocking 파일 작업을 system thread로 보낸다. 보내는 곳은 `Systhread_host.run`이다. `Eio_unix.run_in_systhread`는 부른 domain에서 돌아서 main domain의 HTTP 처리를 막을 수 있다(`lib/core/systhread_host.mli:1-7`). `Candle_ledger`의 읽기는 lock을 잡고 파일 전체를 읽는다(`candle_ledger.ml:199-201`). 읽은 결과를 불변 값으로 발행해 두는 코드는 없다. `authz.jsonl`은 append와 fsync가 필요하므로(설계 §8.1) `Jsonl_writer`를 쓰지 않는다. |
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

층은 모두 34개다. 1단계(§4)에 드는 층과 2단계로 미룬 층은 §4가 나눈다. 크기가 20k token을 넘는 층은 시작할 때 쪼갠다. A4b도 도구가 만든 변환과 사람이 고친 부분의 인증·바인딩 diff를 함께 읽고, 작업 단위가 이 한도를 넘으면 나눈다.

### A. 측정과 기반

이 그룹의 층은 `Single_user` 동작을 바꾸지 않는다. A2는 B2 다음에 쌓고, `account_mode`를 읽는 층(C2, C3, C4, D2)보다 앞에 둔다. C2는 OIDC 경로를 `Multi_account`에서만 열고, C3은 설계 §5.2가 모드로 갈라 놓았다. C4와 D2도 모드를 읽는다.

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| A1 | 모든 경로가 지금 인증을 어떻게 처리하는지 실제 요청으로 잰 기준선. HTTP/1 경로는 라우터를 격리한 base path로 띄워 무인증 요청과 잘못된 bearer 요청을 보낸다. H2, `/mcp` 사전 처리, `/ws`는 실제 소켓으로 따로 친다. 결과는 `docs/evidence/`에 둔다. 동작은 바꾸지 않는다. | §5.3, §11-1 | - |
| A2 | `auth_config`에 닫힌 `account_mode`(`Single_user`, `Multi_account`)를 선택 필드로 두고, 부팅 때 모드를 한 번 정해 실행 중에 바꾸지 않는다. 파일이나 필드가 없으면 `Single_user`이고 알 수 없는 값은 부팅을 거부한다. 필드는 `save_auth_config`가 다시 쓰는 `auth_config` 레코드 안에 둔다. 설정을 `authz.jsonl`과 외부 고수위에 대조하는 판정은 설계 §5.1의 표가 정한다. `Multi_account`는 `enabled=false`, `require_token=false`, `MASC_ALLOW_ANONYMOUS_MUTATIONS=true`를 거부한다. 값을 써 넣는 단계는 없고, 변경 기록에 `Fresh state required`를 적지 않는다. 세부는 표 아래 A2 범위다. | §5.1, §5.3, §8.2~8.4 | B2 |
| A3 | 권한 도메인의 닫힌 타입(Principal, Effect, Channel, Runtime_scope, Authorization_scope, ExecutionContext, grant, policy, record의 author)과 판정식 `allowed`. I/O 없는 순수 코드다. 시험은 deny 기본, `Empty`, `Not_pat`, scope·channel·effects 교집합을 표로 확인한다. | §4, §6.2, §6.3 | - |
| A4a | 경로 인증 종류의 닫힌 타입을 만든다. `Route_access.t`는 라우터의 `route.access`가 들고 있는 데이터이고, `Server_route.auth`는 핸들러 타입을 나르는 GADT이며, 종류를 필수로 받는 등록 함수(`Server_route.get` 등)가 종류에 맞는 래퍼를 씌운다(`docs/rfc/RFC-typed-route-auth.md` §3). 변환 도구 `route_auth_codemod`를 함께 넣는다. 도구는 서버 코드와 닿지 않아 별도 PR로 낸다. 컴파일러 파서로 등록을 읽고 해당 글자 범위만 고쳐 쓰며(나머지 서식은 그대로), `--write`는 파일을 바꾸고 `--strict`는 바꾸지 못한 등록이 남으면 실패한다. 같은 경로라고 말할 수 있는 모양만 바꾸고 나머지는 이유와 함께 목록에 남긴다. 도구는 시험이 있다. 인벤토리 도구가 `access`를 출력한다. 동작은 바꾸지 않는다. | §5.3 | A1 |
| A4b | 도구로 만든 변환 한 층. 2026-10-28의 등록 383곳과 당시 도구 변환 296곳·수동 결정 87곳은 과거 집계다. 사용하려는 도구의 정확한 head에서 열린 변경 요청을 해소하고 독립 소스 리뷰를 받은 뒤, 고정한 서버 source와 도구 head에서 전체 등록·변환·보류 수를 다시 센다. 도구가 남긴 곳과 수동 변경은 결정표에 종류(`Self_authenticated`의 사유, `Always_public`, 도우미 안쪽 래퍼의 종류)와 사유를 적는다. 이름 붙은 핸들러는 다른 파일의 사용까지 확인하고, 모든 변환 diff에서 원래 래퍼와 인증 종류·식별자 바인딩을 검토한다. `--allow-early-evaluation`은 각 계산식의 호출 간 값 불변성, 부작용·예외 및 정의·등록 위치의 동일 바인딩 근거를 기록한 경우에만 쓴다. 근거가 없으면 자동 변환을 수락하지 않고 수동으로 결정한다. 바꾼 뒤 안 쓰게 된 `open Server_auth`를 지우고 A1 상태 코드를 다시 측정하며 인증된 허용·권한 부족 거부와 관련 prefix 및 H1/H2 시험을 확인한다. A1의 무자격 상태 코드 일치만으로 전체 권한 동등성을 주장하지 않는다. `GET /api/v1/board/flairs`(#46569)의 종류를 정하고, 병합 직전에 main 위에서 도구를 다시 돌려 새 등록을 반영한다. | §5.3 | A4a |
| A4c | HTTP/2 게이트웨이(`server_h2_gateway.ml`, `server_h2_gateway_routes_extra.ml`)가 갈래마다 인증 래퍼를 고르지 않고, HTTP/1 라우터가 같은 요청에 돌려주는 종류(`Router.resolve`의 `route.access`)를 읽어 종류에 맞는 H2 게이트를 건다(`docs/rfc/RFC-typed-route-auth.md` §3.3). 종류를 적는 곳이 HTTP/1 등록 하나라서 둘이 어긋날 수 없다. H2가 구현하지 않은 종류와 갈래 모양이 맞지 않는 경우는 거절한다. HTTP/1에 없는 경로는 404, 없는 메서드는 405다. `/api/v1/keepers/`의 `Subpath_dispatch`는 하위 경로의 종류가 표에 없어서 열지 않고, 그 아래 H2 갈래 5곳은 권한을 갈래가 직접 적는다(§3.3). HTTP/2 응답이 HTTP/1에 맞춰 바뀌는 첫 층이라, A1 기준선의 HTTP/2 전체를 변환 전후로 돌려 바뀐 응답 목록을 근거로 남기고(#46675, #46676) 모든 줄이 HTTP/1과 같아지는 쪽인지 읽는다. | §5.3 | A4b |
| A4d | 두 번에 나눠 낸다. 앞부분은 옛 등록 함수와 `Unclassified`를 지운다. HTTP/2 게이트웨이는 이 함수들을 부르지 않아서 A4c를 기다리지 않고, 이 부분이 들어가면 새 등록은 종류 없이 컴파일되지 않는다. 뒷부분은 `is_public_read_path`와 결정표를 지운다. A4c 뒤에도 `is_public_read_path`를 부르는 곳은 HTTP/1 `with_public_read`와 HTTP/2 `with_h2_public_read` 둘이라서 같이 고친다. 엄격 설정에서도 열리는 `Public_read` 등록은 133개 중 15개를 쟀고(`docs/evidence/2026-10-29-h2-route-gate/public-read-open-in-strict.txt`), 유효한 id에만 열리는 published-artifacts 하나를 목록에서 읽어 더하면 16개이다. 이 16곳은 `Always_public`이 아니라 `Public_read`의 "엄격에서도 열림" 구분으로 옮긴다. 2026-11-07에 다시 재면 13곳이다(아래 A4d 뒷부분 범위). 인벤토리의 route 표를 C4가 읽는다. A4a는 2026-10-28에 먼저 병합됐다(#46590). 층마다 병합 시점에 컴파일되고 동작이 같아야 한다. 변환 도구는 열려 있던 PR이 새 등록 함수로 옮겨진 뒤 따로 지운다. | §5.3, §11-1 | A4b (뒷부분은 A4c) |

**A2 범위**

- 판정은 설정, `authz.jsonl`의 마지막 모드 사건이 만든 모드, 외부 고수위(B2)를 모두 읽는 전체 함수이고 거부 사유를 모두 돌려준다. 결과와 마지막 모드 사건이 만든 모드는 닫힌 변형이다. 모드 사건은 종류 `Mode_event`(B2가 더한다)의 레코드다. 이 층의 만든 모드는 없음과 `Multi_account`(`Fresh_bootstrap`이 만든다)이고, F3a가 `off`를 더하면 컴파일이 이 판정에서 멈춘다.
- 판정 결과가 활성화 전 요청(설계 §5.1 표의 `Multi_account`, 없음, 없음)이면 부팅 코드가 `Activation_requested`로 거부하고, 문구가 서버를 멈춘 채 `masc auth bootstrap`을 돌리라고 말한다(B3d-3).
- 부팅은 `config.json`을 JSON 파서로 통째로 읽고 최상위 객체의 `account_mode` 멤버만 보는 얇은 읽기를 둔다. 문자열이나 정규식으로 멤버를 떼어 내지 않는다. 파일이 JSON이 아니거나 최상위가 객체가 아니면 설정은 없는 것으로 읽고 경고 한 줄을 남긴다(지금 동작과 같고 요청 때 503이다). 파일이 JSON 객체이면 다른 필드가 틀려도 `account_mode` 멤버를 읽는다. 멤버는 정확히 `"Single_user"`나 `"Multi_account"` 문자열이어야 하고, `null`, 숫자, 객체, 다른 대소문자, 두 번 나온 멤버는 알 수 없는 값이다. 알 수 없는 값은 `auth_config` 디코더가 파일 전체를 거절하더라도 부팅을 거부한다. `Multi_account`의 흔적은 설계 §5.1 표의 다른 두 열이 거부한다.
- 설정의 `account_mode`를 읽는 곳은 이 부팅 판정 하나다. 다른 층은 판정 결과를 받고, 설정 파일을 다시 읽어 모드를 정하지 않는다.
- `authz.jsonl`이 없는 것과 있는데 읽지 못하는 것을 구분한다. 외부 저장소도 같다. `authz.jsonl`은 끝이 잘린 마지막 줄을, 외부 저장소는 끝이 잘린 마지막 항목을 열 때(판정 1~5를 돌리기 전에) 잘라 낸다(B1b, B2). 두 자르기는 서로 읽지 않아서 어느 쪽을 먼저 해도 결과가 같다. `authz.jsonl`에 남은 줄이 없으면 마지막 모드 사건이 만든 모드가 없는 것이다(설계 §5.1 표 둘째 열 `없음`). `Fresh_bootstrap`이 도중에 죽어 `Intent_pending`만 남은 외부 저장소의 외부 고수위는 `없음`이다(설계 §5.1).
- 부팅 코드가 `Authz_log.open_at_start`를 부르는 것은 BasePath lease를 쥔 뒤다. B1b는 lease 증거를 인자로 받지 않으므로 이 순서는 문장이 지킨다.
- 외부 고수위는 부팅이 설치 기록에서 외부 저장소의 위치를 읽을 수 있을 때만 `있음`으로 볼 수 있다. 설치 기록은 §6의 결정 2가 정했고, 읽고 쓰는 코드는 B2가 만든다. A2는 B2 다음에 쌓으므로 그 코드를 쓴다. 설치 기록을 잃은 설치의 구멍은 §7의 위험 2에 적었다.
- 시험은 A2가 `off`가 없는 행(1~3, 5~8, 11)을 하나씩 보고, `off`가 있는 행(4, 9, 10)은 F3a와 F3b가 본다. 5행은 `Activation_requested`로 나온다. 그 밖에 다섯 가지를 본다. 거부 사유가 둘 이상일 때 모두 돌려주는지, 필드가 든 `config.json`을 `enable_auth`·`disable_auth`·`prepare_login_auth`가 다시 써도 필드가 남는지, 잘린 `config.json`과 마지막 모드 사건이 만든 모드 `Multi_account`를 짝지어 3행 거부가 나오는지, `account_mode`가 알 수 없는 값인 `config.json`이 다른 필드가 틀려도 부팅을 거부하는지, `account_mode`의 입력 모양이다. 입력 모양은 멤버가 두 번 나오거나 `null`·숫자·객체거나 대소문자가 다르면 부팅을 거부하고, 최상위가 배열이나 `null`이면 설정 없음으로 읽는지 본다.


**A4d 뒷부분 범위** (strict 설정의 공개 읽기, 2026-11-07)

- 지금 strict 설정의 `with_public_read`(HTTP/1)와 `with_h2_public_read`(HTTP/2)는 `Server_auth.is_public_read_path`가 참인 경로만 자격 없이 연다. 경로가 열리는지 정하는 곳이 등록의 종류와 이 목록 둘이다.
- 2026-11-07 main(`82ef0dcb730`)에서 소스를 읽어 다시 쟀다. `Public_read` 등록 130개 중 13개가 strict에서도 열린다(`docs/evidence/2026-11-07-public-read-open-in-strict/`). 10-29의 16개 중 multimodal 세 경로는 그 사이 목록에서 빠져 strict에서 닫힌다.
- 종류. `Route_access.Public_read`가 strict 설정에서 요구하는 것을 데이터로 든다. `Credential_when_strict`는 read 자격이고, `Open_when_strict`는 자격 없음이다. 등록 종류는 `Public_read`(자격), `Public_read_open_when_strict`, `Public_read_on_canonical_host { port; when_strict }`다. 경로 표 JSON은 `{"kind":"public_read","when_strict":"credential"}`이나 `"open"`이다. `Always_public`으로는 옮기지 않는다. 그 종류의 핸들러는 서버 상태를 받지 않고 준비 확인(503)도 거치지 않는다.
- published-artifacts prefix(`GET /api/v1/published-artifacts/<id>`)는 strict에서도 연다(2026-11-07 사용자 결정). 지금 목록은 형식이 맞는 artifact id만 연다. 처리기는 스스로 인증한다(선택 token, 비공개 artifact는 401). 바뀌는 것은 형식이 틀린 id를 자격 없이 보낼 때 401 대신 처리기의 400이 나오는 것 하나다. 데이터는 나가지 않는다.
- 층.
  - b0 이 범위와 측정.
  - b1 `Route_access.Public_read`가 구분을 든다. 지금 등록 종류는 모두 `Credential_when_strict`로 적히고, HTTP/2 게이트가 구분을 받는다. `Open_when_strict`는 바로 열고, `Credential_when_strict`는 아직 목록을 본다. 이 구분을 쓰는 등록이 없어서 동작은 같다.
  - b2 등록 종류 `Public_read_open_when_strict`와 정규 호스트의 `when_strict`, HTTP/1 래퍼. 동작은 같다.
  - b3 published-artifacts를 뺀 12곳을 `Open_when_strict`로 옮긴다. 목록이 여는 `Credential_when_strict` 등록이 published-artifacts 하나뿐이라는 시험을 둔다. 동작은 같다.
  - b4는 15개 파일이라 셋으로 나눈다.
    - b4a published-artifacts를 옮긴다. 목록이 붙이던 "왜 여는지" 주석은 등록 자리로 간다. b3의 시험은 목록이 여는 credential 등록이 없다고 본다.
    - b4b 목록을 부르던 시험은 실제 경로 표에서 경로가 닿는 등록의 종류를 읽는 시험 하나로 모은다.
    - b4c 목록과 b3의 시험을 지운다. `Credential_when_strict`는 strict에서 늘 자격을 요구한다.
- 하지 않는 것: 다른 경로의 종류 바꾸기, `Subpath_dispatch` 하위 경로 나누기, 서버를 띄운 A1 재측정.

### B. 권한 저장소

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| B1 | `authz.jsonl`을 파일에 쌓는 저장소다. B1a는 한 줄의 형식과 author 짝 검사, B1b는 파일이다. 세부는 표 아래 B1 범위다. lease 계열 group commit은 E1에서 붙인다. | §6.3, §8.1 | A3 |
| B2 | backup 밖 append-only 저장소(설계의 외부 저장소·revocation ledger)와 `Intent_pending`/`Committed`. 저장소는 Intent 상태를 기록하고(B2a), 객체의 scoped epoch 최고값과 artifact별 `credential_generation`은 epoch를 올리는 사건을 처음 쓰는 층이 더한다. Intent가 가리키는 것은 `Grant`·`Credential`·`Principal`·`Runtime` 중 하나이거나 모드 사건의 workspace다(§4.5). 같은 writer lock 구역, 판정 1~5, `AuthorizationUncertain`, `Revocation_pending` 게이트, `Fresh_bootstrap`, 외부 저장소의 위치를 적은 설치 기록(§6의 결정 2). 세부는 표 아래 B2 범위다. | §4.5, §8.2~8.4 | B1 |
| B3 | Principal·Admin_assignment·WorkspaceMembership·초대 저장소, 마지막 Admin 보호, 호스트 로컬 bootstrap(`Fresh_bootstrap`을 부르는 CLI, A2의 5행 거부가 그 CLI를 가리키게 한다), ID 발급 규칙, principal 삭제 사건. 세부는 표 아래 B3 범위다. 신원 키는 닫힌 합타입 `External_identity.t = Google of {sub} \| Github of {user_id}`다. 설계의 `(iss, sub)`는 이 값을 말하고, issuer 문자열을 비교해 갈래를 고르지 않는다(§6 결정 8). | §4.1, §5.1 | B1, B2, A2 |
| B4 | `Purge_pending`, `Purged`, `Purge_failed` 사건과 현재 상태 판정(target의 마지막 사건이 현재 상태, target 단위 멱등), `Purge_pending` 대상의 읽기 거부, 재기동 때 남은 `Purge_pending` 목록. `Purge_pending` 지정은 §8.2의 scoped epoch 사건이라 `Intent_pending`/`Committed` 규칙을 따른다(initiator 삭제이면 `Delete` 사건). 삭제는 하지 않는다. 삭제 실행기는 F1이다. | §8.5 | B2, B3 |

**B1 범위**

- B1a(줄 형식): 앞 줄의 해시를 품은 체인, 평범한 JSON 본문 타입, 줄의 바이트를 `Authz_record`와 `Authz_body`가 직접 쓰는 것, record 종류와 author 종류의 짝 검사(§6.3). `RuntimeGrant`, `DelegatePolicy`, `Principal`, `InternalServiceCredential`, 명시적 permission revocation은 인증된 author가 필요하고, `System_cron`, `System_maintenance`, `System_migration`이 쓸 수 있는 record는 정해져 있다.
- B1b(파일): 파일은 `<base>/.masc/auth/authz.jsonl`이고 권한은 0600이다. `config.json`과 같은 디렉터리다(`auth_credential_base.ml:38`).
- 프로세스 사이의 배타는 서버를 base path마다 하나만 뜨게 하는 BasePath lease가 맡는다. 이 lease는 `lib/server/server_startup_takeover.ml`에 있고 `masc.server`가 `masc.auth`에 의존하므로, `masc.auth`가 부르지 못한다. 그래서 B1b는 lease 증거를 인자로 받지 않고, 로그를 여는 층이 lease를 쥔 서버에서 연다. lease 없이 열린 두 번째 writer는 첫 쓰기에서 `Diverged`로 드러나 멈춘다. 프로세스 안은 `Eio.Mutex` 하나가 맡는다. `Fs_compat`의 cursor 계열 잠금은 작업 하나 동안만 건다.
- 기동 때 줄을 모두 검증하면서 호출자가 넘긴 접기 함수(줄을 하나씩 받아 상태를 만드는 함수)로 접는다(replay). 결과는 파일 없음, 빈 파일, 줄 있음, 열지 못함 네 가지로 나뉜다. A2의 판정이 이 구분에 의존한다. 끝이 잘린 마지막 줄(꼬리)은 보고하고, 자르는 것은 기동 때만 한다.
- 잇는 일은 writer 구역 하나 안에서만 한다. 다른 프로세스가 쥐고 있으면 기다리지 않고 열 때는 `Locked`, 이을 때는 `Write_locked`를 돌려준다. 한 구역에서 여러 줄을 한 번의 fsync로 잇는다. 잇는 목록은 구역의 head에서 이어져야 하고, 아니면 쓰기 전에 거절한다.
- 구역 안에서 파일 끝이 예상과 다르면 재시도 없이 `Diverged`다. `Diverged` 뒤와, 쓰기가 어디까지 됐는지 확인하지 못한 실패 뒤에는 재기동할 때까지 append를 거절한다.
- blocking 파일 작업은 `Systhread_host.run`으로 보낸다. 접힌 상태를 불변 값으로 발행하는 일(snapshot)은 B3이 정한다.

**B2 범위**

- 모드 사건용 레코드 종류 `Mode_event`를 `Authz_record.Kind`에 더하고 작성자는 `Local_operator`로 정한다(`Authz_record.admits`가 컴파일을 멈춘다). 설계 §6.3은 `Fresh_bootstrap`만 `Local_operator`에게 주었고 `off`의 작성자는 F3a가, `reactivate`의 작성자는 F3b가 정한다. 본문은 `event`와 `workspace_id` 두 멤버이고 이 순서가 아니면 거절한다. `event`는 `fresh_bootstrap`, `off`, `reactivate` 중 하나이고 외부 저장소의 `Change.Mode`와 같은 낱말이다. 모듈 `Authz_mode_event`가 본문을 읽고 쓴다. 사건이 만드는 모드(`Multi_account`, `off`)는 부팅을 판정하는 A2가 정한다. 설계 §8.4는 `Fresh_bootstrap`이 빈 Recovery_manifest와 초기 generation도 같은 append로 확인한다고 하는데, 그 둘은 아직 없는 층의 것이라 본문에 넣지 않는다. 필드가 늘면 하드 컷이다.
- `Fresh_bootstrap`이 `Intent_pending`을 쓴 뒤 죽은 설치는 판정 3으로 닫고 `Fresh_bootstrap`을 다시 허용한다(설계 §5.1의 `없음`).
- `Fresh_bootstrap`의 `Intent_pending`은 `previous_record_hash`로 genesis를 적고, 쓰기 전에 `authz.jsonl`이 비었는지 본다(설계 §8.4의 빈 `authz.jsonl`). 외부 저장소 파일의 규칙(B2a)은 이 값을 보지 않는다. `Fresh_bootstrap`을 처음 쓰는 층(B2d)이 보지 않으면, 비어 있지 않은 로그 위의 `Fresh_bootstrap` intent가 판정 3으로 닫혀 외부 고수위 `없음`으로 읽힌다.
- 외부 저장소는 끝이 잘린 마지막 항목(마지막 줄바꿈 뒤의 바이트)을 열 때(판정 1~5를 돌리기 전에) 잘라 내고, 잘라 낸 바이트 수와 남긴 바이트 수를 경고로 남긴다(B1b의 `Cut` 경고와 같은 모양).
- `Authz_log`가 멈추면(`Authz_log.stopped`) 새 쓰기를 거절하고 `AuthorizationUncertain`으로 다룬다.
- 설치 기록(설계 §8.4)은 `$XDG_CONFIG_HOME/masc/`(없으면 `~/.config/masc/`) 아래에 있고, 파일 이름은 canonical base path(`Unix.realpath`)의 해시로 정한다. 같은 OS 사용자가 base path를 둘 쓰면 파일도 둘이다. 기록 안에도 canonical base path와 외부 저장소의 경로를 적고, 읽을 때 canonical base path를 대조한다(다르면 읽지 못함). 설정 디렉터리를 알 수 없으면 설치 기록이 없는 것으로 읽고, `Fresh_bootstrap`은 기록을 쓸 수 없어 거부한다.
- 설치 기록은 임시 파일에 쓰고 fsync한 뒤 rename하고 부모 디렉터리를 fsync한다. 읽는 쪽이 보는 파일은 없거나 온전하고, 온전하지 않은 기록은 손상이다. 남은 임시 파일은 읽지 않는다. 기록 디렉터리는 0700, 파일은 0600으로 만들고, 읽을 때 심볼릭 링크를 따라가지 않는다. `Fresh_bootstrap`은 설치 기록을 먼저 쓴 뒤 외부 저장소를 만든다. 기록이 없는데 외부 저장소를 만들 경로에 파일이 이미 있으면 그 파일을 열지 않고 실패한다(`O_EXCL`). 외부 고수위가 `없음`일 때만 열리므로 기록이 이미 있어도 그 기록이 가리키는 저장소는 `없음`이고, 이때 기록을 같은 방식으로 새 경로로 교체한다(같은 경로면 내용이 같다).
- 기록을 읽을 때 파일이 없는 것(ENOENT)과 읽지 못하는 것(`EACCES`, 다른 I/O 오류, 손상)을 구분한다. 앞은 `없음`이고 뒤는 `AuthorizationUncertain`이다.
- 시험은 `XDG_CONFIG_HOME`을 임시 디렉터리로 돌려 쓰고 운영자의 설치 기록을 읽거나 쓰지 않는다(`default-base-path`가 시험 실행 파일에 거는 규칙과 같다).
- 갈래마다 고장 주입 시험을 두고, `Intent_pending`만 남긴 것, 마지막 항목이 잘린 것, 설치 기록을 쓰다 죽은 것(기록 없음 또는 온전함)을 한 건씩 더한다. 설정 디렉터리를 알 수 없는 경우, 기록의 canonical base path가 다른 경우, 기록이 이미 있는 채 `Fresh_bootstrap`이 다시 도는 경우, 기록 없이 같은 경로에 옛 외부 저장소가 있는 경우도 한 건씩 본다.

**B2a 범위** (외부 저장소 파일)

- 외부 저장소는 설치 기록(B2b)이 가리키는 경로의 JSONL 파일이다. 한 줄이 항목 하나이고, `Authz_log`와 같은 공용 파일 기계 `Authz_jsonl_file`로 열고 잇는다. 줄을 읽고 쓰는 규칙은 `Authz_external_store`가 정한다. `authz.jsonl`과 달리 줄이 해시 사슬을 이루지 않는다. 이 파일을 되감거나 고쳐 쓸 수 있는 쪽은 설치 기록과 base path에 모두 쓸 수 있는 쪽이고, 그 쪽은 막지 못한다고 이미 정했다(§8.4).
- 항목은 닫힌 변형 셋이다. `Intent_pending {previous_record_hash, intended_next_record_digest, change}`, `Committed {record_hash}`, `Aborted_intent`(대기 중인 intent를 그대로 되풀이한다). 설계 §8.2의 `aborted_intent`는 `previous_record_hash`를 빼고 적었는데, 되풀이하면 한 줄만 읽어도 무엇을 포기했는지 알 수 있어서 intent 전체를 싣는다.
- `change`는 권한 사건과 모드 사건으로 나뉘는 닫힌 변형이다. 권한 사건 `Authz {event, subject}`는 `event`가 `Grant`, `Revoke`, `Disable`, `Delete`, `Block`, `Purge`, `Policy_revoke`, `Credential_replace` 중 하나이고 `subject`는 `Grant`·`Credential`·`Principal`·`Runtime` 중 하나다. 모드 사건 `Mode {event, workspace_id}`는 `event`가 `Fresh_bootstrap`, `Off`, `Reactivate` 중 하나다. 설계 §8.2가 `subject`에 `Workspace`를 더한다고 한 것을 타입으로는 이렇게 나눈다. 모드 사건에 권한 사건의 대상이 붙거나 그 반대가 되는 짝을 만들 수 없게 하고, A3의 `Subject`는 건드리지 않는다. 어느 권한 사건이 어느 대상에 쓰이는지는 설계가 정하지 않는다. 이 층은 모든 짝을 허용하고, 사건을 처음 쓰는 층이 쓰는 짝을 정한다. 권한 축소 사건(§8.3)인지는 `change`를 `match`로 가른다(`Grant`와 모드 사건은 축소가 아니다).
- 파일의 상태는 줄을 접어 만든다. 대기 중인 intent는 최대 하나이고, 마지막 `Committed`의 해시, `Aborted_intent` 목록, `Committed`가 된 `Fresh_bootstrap`의 workspace_id를 가진다.
- 줄이 이어야 할 것은 §8.2의 순서 그대로다. `Intent_pending`은 대기 중인 intent가 없을 때만 올 수 있다. `Committed.record_hash`는 대기 중인 intent의 `intended_next_record_digest`와 같아야 하고, `Aborted_intent`는 대기 중인 intent와 모든 필드가 같아야 한다. 하나 더, 파일은 `Fresh_bootstrap`으로 시작한다(§8.4). `Fresh_bootstrap`이 `Committed`가 되기 전에는 `Fresh_bootstrap`이 아닌 `Intent_pending`을 거절한다(`Intent_before_bootstrap`). 그 뒤에는 `Fresh_bootstrap`의 `Intent_pending`을 거절하고(`Bootstrap_already_committed`), `Off`·`Reactivate`의 `Intent_pending`이 `Committed`가 된 `Fresh_bootstrap`의 workspace가 아닌 것을 적으면 거절한다(`Workspace_mismatch`). 파일은 되돌릴 수 없는 append-only라서 순서가 어긋난 항목은 쓰기 전에 막고, workspace_id를 조용히 덮어쓰는 일도 없다. 규칙을 어기는 줄은 이을 때 `Rejected`이고 열 때 `Line_rejected`(§5.1의 `읽지 못함`)다.
- 한 줄의 바이트는 `Authz_external_store`가 직접 쓴다(`Authz_record`와 같다). 멤버 순서가 정해져 있고, 읽은 줄이 `to_line`이 쓰는 줄과 다르면 거절한다. `append`는 쓰기 전에 줄을 되읽어서 쓰려던 항목과 같은지 비교한다(`Authz_jsonl_file`의 `equal_record`). principal을 쓰는 방법은 `Authz_record`와 같은 것을 쓴다.
- epoch 최고값과 `credential_generation` 항목은 이 층이 정하지 않는다. 설계 §8.2의 `Intent_pending` 필드에 epoch 값이 없고, epoch를 올리는 사건을 쓰는 코드는 B3 전에 없다. 그 사건을 처음 쓰는 층(B3의 principal 사건)이 항목과 비교 판정을 같이 더한다. 그전까지 외부 고수위의 `맞음`은 마지막 `Committed`가 replay에 있는지와 대기 중인 intent의 판정(B2c)으로 정한다. 하드 컷이라 이전 형식을 읽는 코드는 두지 않는다.
- 시험은 줄의 바이트(모든 사건의 낱말 포함), 모든 `change`의 읽고 쓰기와 다시 열었을 때의 상태, 규칙을 어기는 파일과 줄(순서 규칙과 부트스트랩 규칙), 끝이 잘린 마지막 항목의 자름을 본다.

**B2c 범위** (외부 고수위 판정)

- 판정 1~5(설계 §8.2)와 외부 고수위 값(§5.1)을 순수 함수로 만든다. 입력은 외부 저장소의 상태(`Authz_external_store.State.t`)와 `authz.jsonl` 레코드의 열이고, 출력은 둘이다. 하나는 대기 중인 intent를 닫는 일(`settle`: `Promote`·`Abort`, 닫지 못하면 그 사유)이고, 다른 하나는 값(`Absent`·`Matches`·`Mismatch`)이다. §5.1이 판정을 먼저 돌리고 값을 읽으므로 둘은 서로 기다리지 않는다. 값이 `Mismatch`여도 `settle`은 같은 답을 준다. 판정 3이 서면 §8.3의 차단을 바로 세우기 때문이다. 이 층은 파일을 열지도 쓰지도 않는다. 쓰기와 그 성공 여부는 값을 바꾸지 않는다(§5.1). `Mismatch`일 때 어떤 쓰기를 하는지는 위 층이 정한다.
- 로그에서 읽는 사실은 셋이다. 마지막 레코드의 해시, 대기 중인 intent의 `previous_record_hash` 바로 뒤 레코드의 해시, 마지막 `Committed`의 해시가 로그에 있는지. 해시 둘을 먼저 알아야 해서 외부 저장소를 먼저 열고 그 상태로 `Probe`를 만든 뒤 `Authz_log.open_at_start`의 접기 함수로 레코드를 먹인다. 메모리는 로그 길이와 상관없이 일정하다.
- 판정 2·3·5는 `previous_record_hash` 뒤 레코드로 가른다. 그 레코드가 intent가 적은 해시이면 판정 2(`Promote`)다. 다른 해시이면 판정 2·5의 `Digest_differs`이고 `AuthorizationUncertain` 사유다. 뒤 레코드가 없고 로그가 `previous_record_hash`에서 끝나면 판정 3(`Abort`)이다. 뒤 레코드가 없는데 로그가 다른 곳에서 끝나면 `previous_record_hash`가 로그에 없는 것이고 판정 5(`Intent_unplaced`)다. 설계는 "intended record와 일치하는 record"라고 적었다. 레코드 해시는 seq와 이전 해시를 덮으므로, 쓰는 쪽이 제대로 만든 intent라면 해시로 찾으나 자리로 찾으나 같은 레코드다. 이 층은 자리로 찾고, 둘이 갈리는 intent(digest가 그 자리에 설 수 없는 레코드의 해시)는 `Digest_differs`로 읽는다. 로그의 head가 그 사이 lease 같은 로그 전용 레코드로 앞서 가도 판정 2는 선다.
- `Abort`는 `previous_record_hash` 뒤에 레코드가 없는 동안만 선다. 뒤에 레코드(lease 포함)가 붙으면 같은 intent가 `Digest_differs`가 되고 닫히지 않는다. 그래서 구역에 들어올 때마다, 무엇을 붙이기 전에 판정해야 한다(§8.2-1). 그 순서는 B3가 정한다.
- 판정 4는 마지막 `Committed`의 해시가 로그에 없을 때다(`Commit_not_in_log`). 마지막 `Committed`는 쓰기 전에 저장소가 가진 것이고, 승격될 intent가 대신하지 않는다. 대기 중인 intent의 판정과 따로 보고 `Mismatch`는 사유를 모두 돌려준다(§5.1).
- 값은 §5.1의 `없음`·`맞음`·`안 맞음`에 대응한다. `읽지 못함`은 외부 저장소를 열지 못한 오류에서 나오므로 이 층이 아니라 A2가 만든다. `없음`은 `Committed`가 없고 남은 intent가 없거나 `Abort`로 닫히는 `Fresh_bootstrap`뿐인 저장소다. 저장소 규칙(B2a)상 첫 `Committed` 전의 intent는 `Fresh_bootstrap`뿐이다. 로그가 그 intent를 얻었으면(`Promote`) 승격되는 intent는 `Committed`에 든다는 §5.1에 따라 `맞음`이다. `맞음`은 마지막 `Committed`가 로그에 있고 남은 intent가 풀린 것이다. 외부 고수위와 replay의 epoch 값을 맞추는 일은 epoch 값을 처음 기록하는 층(B3)이 더한다.
- `settlement_entry`는 `Promote`·`Abort`가 외부 저장소에 쓸 항목(`Committed`, `Aborted_intent`)을 한 곳에서 만든다. 부팅과 구역 진입이 같은 항목을 쓰게 한다. 그 항목을 `apply`한 상태가 쓰기 뒤의 저장소이고, 승격된 `Fresh_bootstrap`의 workspace는 그 상태에서 읽는다.
- `Authz_external_store.apply`(한 항목을 상태에 접고 어긴 규칙을 돌려주는 순수 함수)를 공개한다. 판정 시험이 파일 없이 저장소 상태를 만들고, 열 때의 접기 함수가 쓸 수 있다.
- 이 층이 하지 않는 것: 같은 writer lock 구역 안에서 `Intent_pending` 쓰기, 레코드 append, `Committed` 갱신을 잇는 순서(§8.2-1)와, 구역에 들어올 때마다 남은 intent를 다시 판정하는 일. 구역 안에서 판정에 쓸 사실(뒤 레코드, head)을 어디서 얻는지는 접힌 상태(`Authz_state.t`)가 생기는 B3가 사건을 처음 쓰면서 정한다. 이 층의 `Probe`는 열 때의 재생에 쓴다. 한 묶음의 append(설계 §10.1)에서 intent가 어느 레코드를 적는지도 묶음을 쓰는 층이 정한다. 이 층은 `previous_record_hash` 뒤 첫 레코드를 본다.
- 시험은 저장소 상태와 로그의 조합마다 값과 닫는 일을 고정한다(없음, 맞음, 안 맞음의 갈래마다 한 건). 마지막 `Committed`가 로그에 없는데 intent가 닫히는 경우, head가 앞서 간 경우, 이미 포기한 intent를 다시 판정하지 않는 것, 사유가 둘인 경우의 순서도 본다. 닫는 항목을 저장소가 받아 intent가 비는 것과, 진짜 `authz.jsonl`을 `Authz_log.open_at_start`로 열어 먹인 결과가 목록으로 먹인 결과와 같은 것(끝이 잘린 마지막 줄 포함)도 본다.

**B2d 범위** (`Fresh_bootstrap`)

- B2d-1은 모드 사건 레코드다(#46686). 레코드 종류 `Mode_event`와 본문 `Authz_mode_event`를 더했고 병합됐다.
- B2d-2는 `Authz_bootstrap`이다. 새 설치를 세우는 함수이고 파일만 안다. 서버가 떠 있는지, 누가 부를 수 있는지, workspace id를 어디서 받는지는 모른다. 부르는 쪽(B3)이 정해서 인자로 넘긴다. 설정 디렉터리도 환경 변수를 읽지 않고 인자로 받는다. 일이 `prepare`(확인하고 열기)와 `write`(쓰기) 두 단계이고 `fresh_bootstrap`은 둘을 잇는다. 단계를 나눈 까닭은 시험이다. 로그에 붙일 때 실패하는 상황은 두 단계 사이에 파일을 바꿔야 만들 수 있다.
- `prepare`는 쓰기 전에 확인하고, 하나라도 어긋나면 아무것도 쓰지 않는다. 파일을 열 때 하는 일은 한다. 끝이 잘린 마지막 줄을 자르고, 잠금 파일과 `.masc/auth` 디렉터리를 만든다(부팅 때마다 하는 일이다). (1) 외부 저장소 경로가 절대 경로이고 NUL 바이트가 없고 정규 형태다(빈 구간, `.`, `..`, 끝의 `/`가 없다). 설치 기록 파일이 아니고, base path 안이나 로그 디렉터리 안도 아니다. 로그와 잠금 파일이 거기 있고, base path의 백업은 그 안의 저장소까지 되돌린다. 경로는 파일의 정체(device와 inode)로 비교한다. 그래서 링크, 같은 디렉터리를 두 번 보여 주는 마운트(macOS의 firmlink), 이미 있는 이름의 대소문자에 속지 않는다. 아직 없는 설치 기록은 적힌 대로 비교하고, 없는 이름의 대소문자 철자는 통과한다. 설정 디렉터리가 base path 안인지는 보지 않는다. 설정 디렉터리를 안다. (2) 설치 기록이 없거나 온전하다. (3) 새 저장소 경로에 아무것도 없다. 기록이 그 경로를 가리킬 때만 일반 파일을 연다. 디렉터리, 링크(가리키는 곳이 없는 것 포함), 기록이 가리키지 않는 파일은 열지 않는다(설계 §8.4). (4) `authz.jsonl`에 레코드가 없다. (5) 기록이 가리키는 저장소가 있으면 일반 파일이고 `없음`으로 읽힌다. 로그가 빈 채로 `Committed`가 있으면 `Commit_not_in_log`라서 되감긴 설치로 보고 거절한다(§5.1 표의 `Multi_account | 없음 | 있음`).
- 쓰는 순서(`write`)는 설치 기록, 저장소 만들기, 남은 intent 포기, `Intent_pending`, 로그 레코드, `Committed`다. 기록은 쓰기 직전에 다시 읽어서 `prepare`가 읽은 것과 같을 때만 쓴다. 다르면 다른 bootstrap이 먼저 쓴 것이라 아무것도 쓰지 않고 멈춘다. 기록이 같은 경로를 가리켜도 다시 쓴다. `Replaced_but_not_durable`로 끝난 쓰기 뒤의 재호출이 쓰기를 마쳐야 하기 때문이다. 저장소는 빈 파일을 `O_EXCL`로 0600에 만들고 파일과 디렉터리 항목을 fsync한다. `Fs_compat.create_file_exclusive`는 쓰지 않는다. 그 함수는 파일 옆에 레지스트리를 만드는데, 처음 만드는 도중에 프로세스가 죽으면 같은 owner의 이후 호출이 모두 막힌다(#46718). `Committed`는 로그에 붙이기가 성공한 뒤에만 쓴다. 저장소 구역 안에 로그 구역을 둔다.
- 죽는 자리마다 다시 부르면 이어지는지 본다. 기록만 쓴 것, 빈 저장소만 만든 것, `Intent_pending`만 쓴 것(로그에 레코드가 없다), 남은 intent를 포기하고 새 intent는 쓰지 않은 것은 다시 부르면 이어진다. 남은 intent는 판정 3으로 `Aborted_intent`를 써서 닫고 새 intent를 쓴다. 남은 intent가 다른 workspace를 적었어도 같다(§5.1: `Committed`가 된 것의 workspace만 유효하다). 레코드가 로그에 들어갔는데 `Committed`가 없으면 다시 부를 때 `Log_not_empty`로 거절하고, 다음 부팅이 판정 2로 승격한다.
- 이 층이 하지 않는 것: BasePath lease 확인(로그 파일의 잠금은 작업 하나 동안만 걸려서 서버가 떠 있어도 열린다. 서버의 다음 append가 `Diverged`로 멈춘다. 기록을 다시 읽고 쓰는 사이에도 배타가 없어서, 서로 다른 저장소 경로로 동시에 도는 두 bootstrap은 부르는 쪽이 막아야 한다. 두 프로세스를 4ms 안에 시작한 300회 중 44회에서 설치 기록이 진 쪽을 가리켰고 되돌릴 수 없었다), 저장소가 백업 밖인지 확인(백업 범위를 알 수 없다), 빈 Recovery_manifest와 초기 generation(없는 층의 것), A2의 5행 거부가 CLI를 가리키게 하는 일(B3d-3).
- 남은 intent 포기, `Intent_pending`, 로그 레코드, `Committed`는 `Authz_zone.install`이 쓴다(B3b의 둘째 층). 구역의 commit과 같은 순서이고, append 전에 `Authz_state.apply`를 돌린다(`Authz_log.append`는 접기 함수를 돌리지 않는다).
- 시험은 첫 실행이 남긴 것(설치 기록, 저장소 줄의 바이트와 0600, 로그 줄의 바이트, 값 `맞음`), 거절마다 파일이 그대로인 것(링크, 디렉터리, 설치 기록과 로그와 base path 안의 경로, 링크를 거친 경로, 정규 형태가 아닌 경로, NUL 포함), 죽은 상태마다 다시 불렀을 때의 결과(기록만, 빈 저장소, 남은 intent, 포기만 한 것, 잘린 intent 줄, 잘린 레코드 줄, 다른 저장소를 가리키는 기록), 두 단계 사이에 파일이 바뀐 경우(로그, 저장소의 intent, 저장소의 포기 줄, 설치 기록, 새로 생긴 저장소 파일)의 오류와 쓰는 순서(intent가 레코드보다 먼저다), 만들 수 없는 저장소와 쓸 수 없는 기록의 고장, 되감긴 로그의 거절(잃은 `Committed`의 해시)을 본다. `Committed`를 쓸 때만 실패하는 경우는 시험하지 못한다. 같은 구역 안이라 두 단계 사이에 끼어들 수 없다.

**B2e 범위** (`Revocation_pending` 게이트, 2026-11-06)

- B3c가 권한 축소 사건(Admin 회수, principal 비활성·삭제, 초대 취소)을 더했다. 구역은 들어올 때 포기한 축소 intent의 subject를 이미 막는다(`Authz_zone.Replay`, `Authz_state.hold_revocations`). 남은 것은 셋이다. 막힘을 푸는 출구가 없다. 쓰기가 실패한 직후에는 막지 않는다. 막힘을 묻는 공개 함수가 없다.
- 실행 경로는 D2 전에 이 값을 읽지 않는다. lib과 bin에서 `Authz_decision`을 부르는 곳은 없다. 그래서 이 층에서 보이는 것은 구역의 거절, 게이트 값, `Authz_decision.allowed`의 `Revocation_pending` 거부까지다. `Single_user`는 구역을 열지 않으므로 동작이 같다.
- 두 층으로 낸다.
  - B2e-1: 게이트 값, 즉시 차단, 재시도 출구. 1a(digest로 든 막힘, 게이트 값, 즉시 차단)와 1b(`closes` 출구)로 나눠 낸다. 1b는 레코드 줄 형식(`Authz_record`)에 `closes`를 더한다.
    - 막힘은 subject 목록이 아니라 포기한 intent마다 한 항목(`intended_next_record_digest`와 change)이다. 어느 intent가 닫혔는지 가려야 해서다.
    - 게이트 값은 구역의 함수로 묻는다. 그 subject의 항목이 남아 있으면 `Pending`이다. 로그나 외부 저장소가 멈춘 구역(`Log_stopped`, `Store_stopped`)은 모든 subject에 `Uncertain`으로 답한다(B2 범위의 "`Authz_log`가 멈추면 `AuthorizationUncertain`"). 저장소와 로그가 어긋난 구역(설계 §8.2-4·5)과, 부트스트랩한 로그인데 저장소에 답이 하나도 없는 구역도 모든 commit을 거절하므로 같게 답한다. snapshot은 파일이 멈춘 것을 담지 않아서(B3b), 값을 snapshot에서 바로 읽지 않는다. D2가 이 값을 `facts.revocation`에 넣는다.
    - 재시도 출구(설계 §8.3): 레코드에 닫는 digest 목록 `closes`를 더한다. 본문이 아니라 `seq`·`previous_hash`·`at_ms`처럼 구역이 채우는 겉 필드다. 부른 쪽은 본문만 주고 `closes`를 채우지 않는다. 줄에서는 `body`와 `hash` 사이에 오고, 비면 쓰지 않는다. 그래서 닫는 것이 없는 레코드의 줄과 해시는 전과 같다. 빈 목록, 순서가 틀리거나 겹친 digest는 거절한다.
    - 구역은 레코드를 한 번 읽어 change를 얻는다. 같은 change(사건과 subject)의 남은 항목이 있으면 그 digest로 레코드를 다시 만들고 다시 읽는다. 그래서 intent의 digest와 해시가 `closes`를 덮는다. `apply`는 `closes`가 가리키는 항목만 지운다. 그 change의 남은 항목이 아닌 digest(`Closes_not_held`)와, 축소가 아닌 레코드의 `closes`(`Closes_without_reduction`)는 거절한다. replay도 같은 `step`을 쓰므로 재기동한 결과가 같다. 로그를 되감으면 닫는 레코드도 사라져 막힘이 돌아온다.
    - 같은 change가 두 번 막히는 길은 잠긴 로그로 첫 시도가 실패하고, 둘째 시도가 첫 시도를 포기하고 쓰기에 실패해 로그가 멈춘 뒤 재기동하는 경우다. 재시도는 둘을 다 닫는다.
    - 즉시 차단(설계 §8.2 판정 3): 축소의 `Intent_pending`을 쓴 뒤 append가 실패하면(`Record_not_appended`) 구역은 그 자리에서 subject를 막은 상태를 발행한다. 다음 진입의 판정 3이 같은 intent를 포기하면 같은 항목이 된다. 그 사이에 재기동하면 replay가 끝날 때 같은 판정으로 막는다.
    - replay는 로그가 더는 닿지 않는 머리에서 시작한 막힘을 로그를 다 읽은 뒤 세운다. 그 막힘을 닫는 레코드를 만나면 그 레코드 앞에서 세운다. 그 레코드를 쓴 구역은 열 때부터 막힘을 들고 있었기 때문이다. 레코드는 자기보다 뒤에서 시작하는 intent를 가리킬 수 없다(intent digest가 시작 머리의 해시를 덮는다).
  - B2e-2: 적격 Admin의 취소. 2a(초대를 쓴 사람 기록)와 2b(취소 Kind·본문·판정)로 나눠 낸다.
    - 2a: 초대는 그것을 쓴 사람(`issuer`: 로컬 운영자이거나 그 Admin)을 기록한다. 초대를 쓸 수 있는 쪽이 이 둘뿐이라 닫힌 타입으로 둔다.
    - 2b: 새 Kind `Revocation_cancel`과 본문 `{ aborted; subject }`를 더한다. `admits`는 인증된 principal만 받는다. 네 층으로 낸다.
      - 2b-1: principal이 들어온 초대를 찾는 함수(`Authz_invite_state.find_consumed_by`). 원 승인자를 여기서 읽는다.
      - 2b-2: 본문(`Authz_cancel_event`). subject는 외부 저장소가 change에 쓰는 모양과 같다. 저장소 없이 로그만 읽어도 무엇을 풀었는지 보인다.
      - 2b-3: Kind. 판정이 들어오기 전에는 `Kind_not_read`로 거절한다.
      - 2b-4: 판정과 replay. replay는 취소가 가리키는 막힘도 재시도의 `closes`처럼 그 레코드 앞에서 세운다. 그러지 않으면 로그가 더는 닿지 않는 머리에서 시작한 막힘을 푼 로그가 열리지 않는다.
    - 적격(설계 §4.1 98줄)은 활성 Admin이고, 자신이 막히지 않았고, 그 항목의 subject·owner·원 grant 승인자가 아닌 사람이다.
      - subject가 초대면 owner는 그 초대를 쓴 Admin이다.
      - subject가 principal이면 그 principal이 들어온 초대를 쓴 Admin이 원 승인자다.
      - 1단계에는 manager 관계가 없어 더 뺄 사람이 없다. beneficiary는 subject인 principal 자신이거나, 아직 들어오지 않은 초대의 주인이라 따로 뺄 사람이 없다.
    - 적격 Admin이 없으면 막힌 채 둔다. Local_operator가 쓰는 `Quarantined(No_eligible_admin)`는 2단계 F2다.
    - 취소는 intent를 쓰지 않는다. 되감기면 막힘이 돌아오는 쪽이라서다.
- 막힌 subject가 author인 레코드는 모두 거절한다(B3c, `Authz_state`). 설계 §8.3은 실행만 말한다. 막힌 Admin이 다른 사람의 권한을 바꾸는 것도 같은 회수를 무르는 일이라 같이 막는다. 이 결정을 여기 적는다.
- 시험은 구역 표면(`commit`, `snapshot`, `open_at_start`)에서 한다. append가 실패한 직후의 막힘, 로그가 멈춘 뒤의 `Uncertain`, 재시도가 성공한 뒤의 풀림과 재기동 결과의 일치, 다른 change로는 풀리지 않음, 부적격 취소의 거절을 본다. `Authz_state`의 갈래는 단위 시험으로 본다. 게이트 값을 `Authz_decision.allowed`의 `facts.revocation`으로 옮기는 adapter는 D2가 만들므로, 그 둘을 잇는 시험도 D2가 한다. 판정식의 `Revocation_pending` 거부는 `test_authz_decision`이 이미 subject마다 본다.
- 남은 질문: 1단계 근거로 든 Admin의 사용자 `Disable`을 서버에서 쓰는 층이 표에 없다. C6 ③은 초대 발급·취소와 allowlist뿐이다. 그 길을 C6에 더할지는 C6을 시작할 때 정한다.

**B3 범위**

- 층은 넷이다(2026-11-05).
  - B3a: 접힌 상태 `Authz_state`(지금은 `mode` 필드 하나)와 mode event 순서 `Authz_mode_state`(상태 3개 × 사건 3개, 9쌍을 모두 적는다). 외부 저장소도 mode 변경을 같은 순서로 받는다. 부팅 판정이 이 `step`으로 로그를 읽는다.
  - B3b: 쓰기 구역. 구역에 들어갈 때 남은 intent를 판정하고(§8.2 규칙 1~5), append 전에 `step`을 돌리고, `Intent_pending` → append → `Committed` 순서로 쓰고, 새 상태를 불변 값으로 발행한다. 둘째 층에서 `Authz_bootstrap`이 첫 레코드를 구역의 `install`로 쓴다.
  - B3c: principal과 `External_identity`, CSPRNG `user_id`, Admin_assignment, WorkspaceMembership, 초대, 마지막 Admin 보호, 삭제 사건, 외부 고수위의 epoch 항목. 저마다 `Authz_state` 필드 하나와 `step` 갈래 하나로 들어온다.
  - B3d: 구역이 읽는 시계, CLI bootstrap 하위 명령, 한 번 쓰는 Admin 초대 링크, 5행 거부가 CLI를 가리키게 하는 일.
- B3b 쓰기 구역 `Authz_zone`.
  - 구역은 외부 저장소의 구역 안에 로그의 구역을 둔다. `Authz_bootstrap`과 같은 순서다.
  - 열기: 구역이 두 파일을 직접 열고, 로그를 `Authz_zone.Replay.step`(`Authz_state.step`과 `Probe.add`)으로 접는다. 손잡이는 구역 밖으로 내놓지 않는다. 그래서 그 손잡이로 쓰는 쪽은 구역뿐이다. 다른 손잡이나 다른 프로세스가 쓰면 파일 끝이 움직이고, 구역이 다음에 그 파일에 쓸 때 `Diverged`로 그 파일을 멈춘다. 같은 inode 에서 크기가 그대로인 쓰기는 알아채지 못한다. 경로로 여는 구역은 `Fresh_bootstrap`이 없는 로그를 열지 않는다. 로그의 첫 레코드는 `install`이 쓰고, `Authz_bootstrap`은 설치 기록에 저장소를 적은 뒤에만 그것을 부른다. 그래서 설치 기록이 가리키지 않는 저장소에 구역이 쓰는 일이 없다(§8.4). 로그가 없으면 `Authz_presence`로 먼저 보고 두 파일 모두 열지 않는다. 파일을 열면 디렉터리와 잠금 파일이 생기기 때문이다.
  - 구역에 들어올 때마다 `Authz_high_water.settle_on_entry`로 남은 intent를 판정한다(§8.2-1). 재기동 때 쓰는 판정과 같다. 맞지 않으면 아무것도 쓰지 않고 거절한다. 맞아도 저장소에 답이 하나도 없으면(§5.1 없음) 거절한다. bootstrap 된 로그 옆의 빈 저장소는 비워졌거나 이 로그의 저장소가 아니다. 판정이 바뀌지 않는 한 다음 진입도 거절한다.
  - 다음으로 레코드를 만들고 `Authz_state.apply`를 돌린다. 둘 중 하나가 거절하면 아무것도 쓰지 않는다. 판정이 `Promote`·`Abort`이면 그 항목은 새 `Intent_pending` 바로 앞에 쓴다(§8.2-1은 새 intent를 쓰기 전에 판정하라고 한다). `Abort`는 "로그가 intent 가 시작한 곳에서 끝난다"는 말이다. 이 말을 probe 만 믿고 쓰지 않고, 쓰기 전에 `Authz_log.confirm_end`로 로그 끝을 파일에서 확인한다. 구역이 abort 할 intent 는 append 가 실패하고 남은 것인데, 그때는 다른 프로세스가 로그를 쥐고 있었을 수 있다. 끝이 움직였으면 로그를 멈추고, 다음 기동이 파일로 판정한다. 로그나 잠금 파일이 이름 하나에 일반 파일 하나가 아니어도 append 처럼 멈춘다(`Fs_compat` 오류가 둘 중 어느 파일인지 말하지 않는다). 잠금을 남이 쥐었거나 읽기 자체가 실패하면 아무것도 쓰지 않았으니 로그를 멈추지 않고, 다음 commit 이 다시 묻는다. 다른 커밋은 나중 판정이 로그에서 다시 찾지만(`Commit_not_in_log`) abort 는 아무도 다시 확인하지 않는다. 그래서 확인과 abort 사이에 남이 붙인 레코드는 구역의 다음 append 가 `Diverged`로 잡을 때만 드러난다. 그 append 없이 프로세스가 끝나면 다음 기동은 두 파일이 맞는다고 읽는다.
  - `apply`는 새 상태와 함께 고수위에 쓸 변경을 돌려준다. 지금 받는 레코드는 mode 사건뿐이라 모두 변경이 있고, 구역은 늘 `Intent_pending` → append → `Committed`로 쓴다. 변경 없는 종류는 그 종류를 읽는 층이 타입을 바꿔 더한다.
  - 판정에 쓰는 `Probe`는 구역이 들고 있다. 로그에 붙인 레코드는 `Probe.add`로, 저장소에 쓴 항목은 새 함수 `Probe.store_moved`로 넣는다. 구역은 intent를 언제나 로그 head에서 쓰고, 저장소는 `Committed`가 intent의 digest(그 append의 첫 레코드)와 같아야 받는다. 그래서 로그를 다시 읽지 않고도 probe가 저장소와 로그를 함께 따라간다.
  - 상태는 `Atomic`에 든 불변 값 `{ state; head }` 하나로 발행한다. 읽는 쪽은 잠금 없이 읽는다. append가 성공하면 `Committed`를 쓰지 못해도 그 레코드를 넣은 상태를 발행한다. 로그에 있는 레코드를 빼면 다음 `apply`가 틀린 상태 위에서 돈다. 이때 부른 쪽은 실패를 받고, 다음 진입의 `Promote`가 `Committed`를 채운다. 그 실패로 저장소가 멈췄으면 다음 기동이 채운다.
  - 발행한 상태는 파일이 멈췄다는 것을 담지 않고, 구역에는 그것을 읽는 함수도 아직 없다. `/health`의 `Recovery_store_unavailable`(§8.4)과, 권한 축소 사건의 intent가 남았을 때 바로 세우는 §8.3 차단이 필요한 층이 그 함수를 구역에 더한다. §8.3 차단은 B2e가 더한다.
  - 이 층의 append는 레코드 하나다. 한 레코드에 사건 여럿을 담을지, 여러 레코드를 한 intent로 묶을지는 처음 필요한 층(B3c의 초대 소비)이 정한다. `Authz_log.append`는 중간에 끊기면 앞 레코드만 남을 수 있다.
  - B3b의 둘째 층: `Authz_bootstrap`이 첫 레코드를 `Authz_zone.install`로 쓴다. `install`은 부른 쪽이 연 두 손잡이 위에 그 호출 동안만 구역을 세우고, `commit`과 같은 함수로 쓴다. 다른 것은 들어갈 때의 판정 하나다. `commit`은 저장소에 답이 있어야 하고(`Answered`), `install`은 답이 없어야 한다(`Nothing_answered`). `Nothing_answered`는 포기할 `Fresh_bootstrap` intent를 함께 돌려준다. 그래서 bootstrap도 append 전에 `Authz_state.apply`를 돌리고(빈 상태는 `Fresh_bootstrap`만 받는다), 남은 intent를 포기하기 전에 `confirm_end`로 로그 끝을 확인한다. 확인하기 전에 그 intent의 레코드가 로그에 들어왔으면 포기하지 않고 로그를 멈춘다. 다음 부팅이 그 intent를 승격한다. 손잡이가 아는 로그에 레코드가 있으면(`Log_holds_records`) 아무것도 쓰지 않는다. bootstrap의 쓰기 오류는 구역 오류 하나(`Zone_failed`)로 받는다.
  - 부팅 판정은 지금 두 파일을 구역과 같은 접기(`Authz_zone.Replay`)로 읽고 손잡이를 버린다. 다계정이 된 로그는 `Multi_account_not_served`로 멈추므로 구역을 쥘 곳이 없다. 구역의 열기는 두 파일이 다 있을 때만 구역을 만들고, 부팅은 하나가 없는 경우(설치 기록 없음, 로그 없음, 빈 로그)도 판정한다. 그 경우들을 구역의 열기가 어떤 값으로 돌려줄지는 S1이 `Multi_account_uncertain`에서 무엇을 서빙할지와 함께 정하고, S1이 부팅에서 연 구역을 쥔다.
- 첫 Admin(2026-11-05 사용자 결정): bootstrap 명령이 한 번 쓰는 Admin 초대 링크를 찍는다. 그 링크로 로그인한 사람의 초대 소비, User 생성, Admin 지정은 append 한 번이다. Principal 레코드는 인증된 author만 쓴다(설계 §6.3). `Local_operator`는 초대 기록만 쓴다. 그래서 초대는 Principal과 다른 Kind다.
- ID 발급(§4.1): Human `user_id`는 OS CSPRNG가 만든 128비트 이상의 값이고 `(iss, sub)`나 email에서 유도하지 않는다. 발급은 writer lock 안에서 현재 principal과 ledger의 `Delete` 기록을 대조한다. `user_id`가 겹치면 다시 뽑고, `service_id`가 겹치면 등록을 거부하고, ledger를 읽지 못하면 발급하지 않는다.
- B3c 층(2026-11-05). 층마다 Kind 하나나 사건 하나를 읽고, `Authz_state`에 필드 하나와 `apply` 갈래 하나를 더한다. B3c는 초대(§5.1-2의 (b))로 입장하는 길만 다룬다. 입장 요청 (c)는 2단계다(§1.1). allowlist (a)는 첫 Admin에 필요 없어서 B3c 뒤 층으로 두고, 자리는 그 층을 시작할 때 정한다.
  - 입장은 레코드 하나다. 초대 소비, `(iss, sub)` 결속, User 생성, 첫 Admin 지정을 새 Kind `Admission`의 본문 하나에 담는다. 여러 레코드를 한 append로 쓰다 죽으면 앞 레코드만 남는다. 남은 줄은 하나하나 온전해서 replay가 잘린 묶음인지 모른다. 판정 2도 intent의 digest가 첫 레코드라서 그 앞부분을 승격한다. 레코드가 하나면 줄이 통째로 있거나, 끝이 잘려서 열 때 잘린다.
  - 사건이 외부 고수위를 바꾸는지는 층을 시작할 때 §8.1·§8.2의 epoch 목록을 다시 읽고 정한다. 바꾸지 않는 사건이 처음 들어오는 층에서 `Authz_state.applied.high_water`가 option이 된다(B3b가 남긴 자리).
  - B3c-1 초대. Kind `Invite`, 사건은 `Issued { invite_id; token_digest; expires_at_ms; role }`와 `Revoked { invite_id }`다. `role`은 `Member | Admin`이다. token은 싣지 않고 SHA-256 digest만 싣는다(§5.1-4). `admits`는 `Local_operator`와 `Authenticated`를 받는다. 이 층의 `apply`는 `Local_operator`가 쓴 `role = Admin` 초대만 받는다. Admin이 쓰는 초대는 Admin 상태를 읽는 B3c-3이 연다. 만료 시간 값은 쓰는 쪽(B3d의 CLI)이 정한다.
  - B3c-2 입장과 `External_identity`. 본문은 `{ user_id; identity; invite_id }`이고 `identity`는 `External_identity.t = Google of { sub } | Github of { user_id }`다(§5.2.1). author는 입장하는 사람 자신(`Authenticated (Human user_id)`)이다. `apply`는 author와 본문의 `user_id`가 같은지 본다. 없는 초대, 취소된 초대, 이미 쓴 초대, User가 이미 있는 `identity`, 이미 쓰였거나 삭제된 `user_id`도 거절한다. 만료는 입장 레코드의 `at_ms`(구역이 잠금 안에서 읽는 현재 시각, B3d-0)가 `expires_at_ms`보다 앞서는지로 fold가 본다. replay는 시계를 읽지 않으므로 같은 로그는 언제나 같은 답이다. `role = Admin`인 초대를 쓰면 같은 레코드가 그 사람을 Admin으로 지정한다. `user_id`는 쓰는 쪽이 구역 안에서 OS CSPRNG로 128비트를 뽑는다. 겹치면 다시 뽑는다. ledger(D층)가 생기기 전에는 삭제된 id를 `authz.jsonl`의 삭제 사건에서 읽는다.
  - B3c-3 Admin_assignment. 회수 사건(`cause = Security_incident | Operational`, §4.1)과 `role_epoch`, 마지막 Admin 보호, Admin이 쓰는 초대다.
  - B3c-4 WorkspaceMembership. `membership_epoch`와 account-home namespace를 다룬다. 이 층이 입장 본문에 membership을 더한다. S1 전이라 입장 레코드가 든 라이브 로그가 없어서 hard cut 비용이 없다. 입장 본문의 `membership`은 `{ workspace_id; account_home_namespace }`다. `workspace_id`는 bootstrap의 workspace여야 한다. 설계는 namespace 값을 정하지 않으므로, 쓰는 쪽이 `user_id`처럼 OS CSPRNG로 뽑고, fold는 한 번 준 namespace를 다시 주지 않는다. 두 사람이 한 account-home 디렉터리를 쓰면 credential이 섞이기 때문이다. namespace에는 대문자를 쓰지 않는다. APFS는 기본으로 대소문자를 가리지 않아서, 대소문자만 다른 두 이름이 한 디렉터리가 된다. 입장은 membership을 만들어 `membership_epoch`를 올리므로 모든 입장이 그 principal의 `Grant` intent다.
  - B3c-5 비활성·삭제. Kind `Principal`의 `Disabled`·`Enabled`·`Deleted` 사건이다. `(iss, sub)`는 삭제 사건에만 싣는다(§4.1). 마지막 Admin의 비활성·삭제는 거절한다(§5.1-5). 사건은 활동 중인 Admin만 쓴다. 비활성은 `Disable`, 삭제는 `Delete` intent다. 재활성은 epoch를 올리지 않아 intent가 없다. 그래서 재활성 앞으로 되돌린 로그는 그 사람을 비활성으로 둔다. 삭제는 principal·`(iss, sub)` 결속·membership·Admin 지정을 지운다. `user_id`와 namespace는 다시 주지 않고, `(iss, sub)`는 새 초대로 새 principal이 되어 다시 들어올 수 있다. 비활성이거나 삭제된 principal은 레코드를 쓰지 못한다. 마지막 Admin을 셀 때는 비활성 Admin과, store가 회수를 포기해 막힌(§8.3) Admin을 빼고 센다.
- B3d 층(2026-11-05). 호스트 로컬 bootstrap은 `Fresh_bootstrap`(B2)을 부르는 CLI 하위 명령이다. 서버를 멈추고 돌리고 BasePath lease를 쥔다(2026-11-05 사용자 결정). 그래서 서버와도, 다른 bootstrap과도 동시에 돌지 않는다(B2d의 한계 참고). loopback 엔드포인트는 쓰지 않는다. 터널이 localhost로 들어와서 원격 요청과 구분할 수 없다. 외부 저장소의 위치(§6의 결정 2)는 B2 전에 정해지므로 이 층이 열릴 때 이미 있다. 서버에는 열어 줄 bootstrap 경로가 없다. 그래서 활성화 전 요청(§5.1 표 5행)에서 부팅은 계속 멈추고, 멈춤 문구가 CLI 명령을 가리킨다. 원격 경로와 실행을 열지 않는다는 5행과 맞는다.
  - B3d-0 시계(#48716). 구역이 두 잠금 안에서 시계를 읽어 레코드의 `at_ms`를 정한다. draft에는 `at_ms`가 없다. 시계는 구역을 열 때(`open_at_start ~now_ms`, `install ~now_ms`) 함수로 받는다. 잠금을 기다리기 전에 읽은 시각이 레코드에 들어가지 않는다. `Authz_state`는 읽은 레코드의 가장 늦은 `at_ms`를 들고, 그보다 이른 입장 레코드를 `Admission_behind_log`로 거절한다. 그래서 되감긴 시계는 로그의 마지막 기록 앞으로 시각을 돌려 그때 이미 만료된 초대를 쓰지 못한다. replay도 같은 접기라 같은 검사를 한다. 다른 종류는 시각으로 판정하지 않으므로 이 검사에 걸지 않는다. 앞서 간 시계가 쓴 레코드가 있어도 회수·비활성·`off`는 시계가 따라잡기를 기다리지 않는다. 입장은 기다린다. 실제 시계가 그 시각을 지날 때까지 모든 입장이 거절되고, 운영자가 풀 길은 없다. 마지막 기록 뒤의 되감김(만료 뒤 기록이 없는 동안)은 막지 못한다. 그 경우는 시계를 믿는 수밖에 없다. `Authz_bootstrap`의 요청도 시각 대신 시계를 받는다.
  - B3d-1 `masc auth bootstrap --external-store PATH`. BasePath lease를 쥔다(`Server_startup_takeover.acquire_base_path_lock`, 선례 `Released_workspace_upgrade.apply`). 서버가 떠 있으면 lease를 얻지 못해 아무것도 쓰지 않고 끝난다. 로직은 `Authz_activation`(lib)에 두고 시험한다. lease와 출력만 `bin/masc_cli_auth`가 한다. 쓰기 전에 부팅과 같은 판정(`Authz_boot_mode_read.input`·`decide`)을 돌리고, 5행일 때만 쓴다. 설정이 `Single_user`인 채로 `Fresh_bootstrap`을 쓰면 다음 부팅이 3행으로 멈추고, 이미 멈추는 줄에 쓰면 멈춤만 늘기 때문이다. 5행이 아니면 아무것도 쓰지 않고 이유를 나눠 말한다. 설정이 다계정을 묻지 않으면 `Not_asked`, `config.json`을 못 읽으면 그 이유를 단 `Config_unreadable`, 이미 켜진 설치(7행)면 `Already_active`, 나머지는 부팅이 찍는 문구 그대로인 `Boot_stops`다. 판정에 넣는 익명 쓰기 설정은 이 명령을 부른 셸의 환경 변수다. 서버는 자기 환경을 읽으므로, 다른 환경에서 띄운 서버와는 다를 수 있다. workspace id·invite id·token은 `Authz_activation`이 OS `getrandom`으로 뽑는다(`Random_id.hex`, §8.4 "새 workspace_id"). token은 32바이트의 hex 64자이고, 디스크에는 SHA-256 digest만 남는다(§5.1-4). token은 추상 타입 안에 있고 `Authz_activation.link`로만 꺼낸다. 외부 저장소 경로는 운영자가 정한다. 백업 범위를 masc가 알 수 없기 때문이다. `Fresh_bootstrap` 다음 같은 lease 안에서 구역을 열고 첫 Admin 초대를 `Local_operator`로 쓴다. 초대 만료는 24시간이다(§5.1-4가 계획에 맡긴 값). 링크 모양은 `<base url>/accounts/invite#<token>`이고, 화면(C6 ②)과 소비(C2a)가 이 경로(`Authz_activation.invitation_path`)를 쓴다. 링크는 한 번만 화면에 찍는다. base url은 `MASC_HTTP_BASE_URL`만 쓴다. Play 초대와 같은 검사(`Play_invite.is_http_public_base_url`)를 통과해야 한다. 셸의 `MASC_HOST`·`MASC_HTTP_PORT`로 만든 주소는 서버가 실제로 듣는 주소와 다를 수 있어서 쓰지 않는다. 이 값은 쓰기 전에 읽어서, 없거나 틀리면 아무것도 쓰지 않는다. 검사 자체는 `test_play_invite`가 본다. 거절 문구는 값을 찍지 않는다. 비밀번호가 든 URL일 수 있기 때문이다. 링크가 표준 출력에 닿지 못하면(flush 실패) 종료 코드 1로 알린다. bootstrap 뒤 초대 커밋이 실패하면 로그에는 bootstrap만 남고 초대는 B3d-2로 다시 쓴다. S1 전에 이 명령이 성공하면 그 설치에서 서버가 부팅을 멈추고(7행 `Multi_account_not_served`), 되돌리는 명령이 없다(`off`는 F3a). 도움말과 성공 문구가 이 사실과 지워서 되돌리는 길(B3d-3)을 말한다. §11의 readiness는 원격 다계정을 여는 부팅(S1)이 본다. 이 명령은 기록만 쓰고 서버를 열지 않는다. F5가 readiness를 만들면 §11-3에 따라 이 명령도 오래된 readiness에서 거부한다(F5 범위).
  - B3d-2 `masc auth invite`. 서버가 멈춘 상태에서 `Local_operator`가 Admin 초대를 하나 더 쓴다. 첫 초대가 쓰이기 전에 만료되거나 링크를 잃었을 때 쓴다. 초대를 하나 더할 뿐 취소하지 않으므로, 잃어버린 링크도 쓰이거나 만료될 때까지 열려 있다. 초대 취소와 Member 초대는 C6 ③에서 Admin이 서버로 한다. 이 빌드에는 둘 다 없다. 부팅 판정이 `Multi_account`이고 외부 저장소가 로그와 맞을 때만 쓴다(§5.1 표 7행). 저장소 경로는 설치 기록에서 읽는다. lease, base url(`MASC_HTTP_BASE_URL`), 링크 출력은 B3d-1과 같다(`Authz_activation.invite`, `masc auth invite`).
  - B3d-3 부팅 문구. 5행 거부의 이름은 판정이 내는 모드와 같은 `Activation_requested`다. 문구는 세 가지를 말한다. 이 빌드는 다계정을 서빙하지 않는다. `config.json`에서 `account_mode`를 빼면 단일 사용자로 뜬다. 서버를 멈춘 채 `masc auth bootstrap --external-store PATH`를 돌리면 활성화되지만, 그 뒤 이 빌드의 서버는 부팅을 멈추고 되돌리는 명령이 없다. CLI도 부팅 문구를 찍으므로 "this server"라고 쓰던 문구는 "this build"라고 쓴다. 거부는 S1 뒤에도 남는다. 5행에서 서버가 열 경로가 없기 때문이다.
  - B3d-3의 되돌리는 길(2026-11-08 사용자 결정, §6 결정 10). 되돌리는 명령은 없지만 S1 전에는 단일 사용자로 돌아갈 수 있다. masc 프로세스를 모두 멈추고 세 가지를 지운다. `authz.jsonl`, 외부 저장소, 이 base path를 적은 설치 기록이다. 그리고 `config.json`에서 `account_mode`를 뺀다. 그러면 부팅은 이 base path를 활성화한 적 없는 설치와 가르지 못하고 1행대로 단일 사용자로 뜬다. 로그만 지우면 복원으로 보고 거부한다(2행). 로그와 외부 저장소만 지워도 1행이 되지만, 설치 기록까지 지워야 찌꺼기가 남지 않는다. 로그의 잠금 파일은 부팅이 다시 만드니 남아도 된다. 이 문장은 `Authz_boot_mode_read.single_user_again` 하나이고, bootstrap 도움말·성공 문구와 5행·`Multi_account_not_served` 부팅 문구가 같이 쓴다. 시험은 실제 `Fresh_bootstrap` 뒤 세 가지를 지우고 1행을 확인한다(`single user again`). S1 전에는 계정이 가진 Keeper·Runtime 기록이 없어서 지워도 잃는 것은 로그인 기록뿐이다.
- 삭제 사건(§4.1): `(iss, sub)`는 `authz.jsonl`의 사건에만 싣고 ledger의 `Delete` 기록에는 ID만 둔다.
- 표시가 붙은 상태는 D6에서 처음 생긴다. D6 전에는 삭제가 올릴 `Purge_pending` 대상이 없다.
- 접힌 상태 `Authz_state.t`는 층별 하위 상태를 필드로 가진 레코드다. replay의 적용 함수 `step`은 `Kind.t`를 빠짐없이 match해 하위 모듈로 보낸다. 층마다 필드 한 줄과 갈래 한 줄이 는다. 이 타입은 저장소(B1b)가 아니라 `Authz_state` 모듈이 붙인다.
- `step`은 replay가 줄마다 부르는 적용 함수다. append 전에 같은 `step`을 돌려 보면, 쓴 줄이 replay에서 거절되는 일이 없다. 바뀔 수 있는 정책은 판정(decide)에만 둔다. `step`을 엄격하게 바꾸면 hard cut이다.
- 모든 projection은 같은 head에서 읽는다. 상태 보관자가 `Authz_state.t` 하나를 불변 값으로 한 번에 발행한다. head가 다른 두 projection을 짝지으면 어느 head에도 없던 조합이 나온다. 예를 들어 Bob 비활성(100번 줄), grant G 회수(101번 줄), Bob 재활성(102번 줄)일 때 grant를 100에서, principal을 102에서 읽으면 "Bob 활성 + G 유효"가 된다.

### C. 인증

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| C1 | OIDC ID token 검증 의존성 결정. `jose`와 `jwto`를 현재 pin(x509 >= 1.0, < 1.2), OCaml 5.5, RS256, `alg=none` 거부, JWKS `kid` 선택으로 비교한 근거를 남기고 하나를 추가한다. 고정한 JWKS와 token 벡터로만 시험하고 네트워크를 쓰지 않는다. | §5.2 | - |
| C2a | Google OIDC code + PKCE 로그인, `External_identity.Google` 결속, 입장 (b) 초대 소비(동시 소비는 409). (a) allowlist는 C2d다. 삭제된 principal의 `(iss, sub)`로 초대를 소비하면 Admin 화면과 감사 기록에 `previously_deleted`를 보인다. 입장을 막지 않는다. 이 표시는 `authz.jsonl`을 읽어 만들고 principal 레코드에는 저장하지 않는다(§5.1-6). 1단계에는 입장 요청(c)이 없어서 미등록 사용자의 로그인은 상태를 만들지 않고 거절한다. 시험 벡터에 잘못된 서명·`iss`·`aud`·`nonce`·`state`, 만료됐거나 취소된 초대 token, 초대 동시 소비(409), `Disabled` 등록 사용자의 로그인, 미등록 사용자의 거절을 넣는다. | §5.1, §5.2 | A2, B3, C1 |
| C2b | GitHub 로그인(설계 §5.2.1). OAuth App의 code + PKCE(S256) + `state`이고, code를 서버에서 client secret으로 바꾼 access token으로 `GET /user`를 한 번 읽어 숫자 `id`를 `External_identity.Github`로 결속한다. scope 없이 요청하고 access token은 저장하지 않는다. `login`과 email은 표시 자료다. 입장은 (b)다. (a)는 C2d가 두 흐름에 함께 더하고, (c)는 없다. 시험은 고정한 응답을 내는 전송 함수로 하고 GitHub에 접속하지 않는다(아래 C2b 범위). 시험 벡터에 `state` 불일치, 토큰 교환 오류 응답, `GET /user` 실패와 `id` 없는 응답, 같은 사람의 Google·GitHub 로그인이 서로 다른 principal로 남는 경우(계정 링크 금지, 설계 §5.1-5), 만료됐거나 취소된 초대 token을 넣는다. | §5.1, §5.2.1 | A2, B3, C2a |
| C2d | 입장 (a) allowlist(2026-11-06 사용자 결정으로 C2a에서 떼어 C2b 뒤에 둔다). Admin이 `External_identity.t`를 등록하고 지우는 사건, 등록된 신원의 첫 로그인이 입장 레코드 하나로 User를 만드는 갈래(초대 대신 등록 항목을 가리킨다)다. 입장은 §5.1-3의 같은 구역에서 같은 신원의 User가 있는지 보고, 있으면 409다. 등록을 지우는 사건은 intent를 쓰고, 등록은 쓰지 않는다(아래 C2d 범위, 2026-11-06 사용자 결정). 삭제된 principal의 신원을 등록하면 `previously_deleted`를 보인다(§5.1-6). 등록한 신원은 purge 대상이 아닌 `authz.jsonl`에 남는다. masc Admin은 개인 Gmail의 `sub`를 미리 알 수 없어서, Google 쪽은 주로 삭제된 신원을 다시 들일 때 쓴다. GitHub 숫자 `id`는 공개 API로 알 수 있다. 시험 벡터에 등록 안 된 신원의 거절, 등록을 지운 뒤의 로그인 거절, 같은 신원의 등록 입장과 초대 입장이 겹친 경우(409), 삭제된 신원의 재등록을 넣는다. | §5.1 | B3, C2a, C2b |
| C2c | 2단계. 입장 요청(c). 도메인 정책(`oidc.admission_request_domains`)이 있으면 미등록 `(iss, sub)`의 입장 요청 조건(`hd`·`email_verified`)과 입장 요청 기록·Admin 승인(§5.1-2c, §5.1-7)을 함께 낸다. 입장 요청의 개수 상한과 상한을 넘었을 때의 동작, 만료 시간, 종단 요청의 보존 기간을 이 층에서 정한다. 시험 벡터에 `hd` 없음, `hd` 불일치, `email_verified=false`, 정책 아래에서 (a)나 (b)로 들어오는 `hd` 없는 사용자의 로그인 허용, `hd` 대소문자(`A.com`), 승인 때 요청의 도메인이 정책에 없거나 정책이 비어 있는 경우(승인 거부), `Pending` 중 재로그인(새 요청 없음), 두 Admin의 동시 승인(409)과 승인·거절이 겹친 경우(User가 생긴 쪽이 이김), (a)나 (b)로 User가 생긴 뒤 같은 `(iss, sub)`의 `Pending`이 `Superseded`로 읽히고 승인 대기 목록에 나오지 않는 경우, 거절 뒤 재로그인(새 요청 없음)과 (a)로의 입장, 만료된 요청의 승인 거부와 새 요청 허용, 시계가 되감겨 `Expired`가 `Pending`으로 돌아와도 승인 검사가 같은 시계를 쓰는 경우, 이미 입장한 요청에 거절을 누르면 409, 승인된 요청의 User 삭제 뒤 승인 대기 목록에 되살아나지 않는 경우와 새 요청 허용, `Superseded`였던 요청의 User 삭제 뒤 `previously_deleted`와 함께 `Pending`으로 보이는 경우, 복원으로 요청 저장소가 뒤처져 `Pending`이 남은 경우(User가 있으면 승인 대기 목록에 나오지 않는다), `previously_deleted` 표지가 있는 `(iss, sub)`의 입장 요청 화면, `Disabled` 등록 사용자의 로그인(정책 면제가 §4.1 Disabled 규칙을 덮지 않는다), 만료됐거나 취소된 초대 token을 넣는다. | §5.1, §5.2 | C2a, C6 |
| C3 | Google·GitHub 로그인 HTTP 경로(`POST /auth/oidc/start`, `GET /auth/oidc/callback`, `POST /auth/github/start`, `GET /auth/github/callback`, 비공개 데이터가 없는 200 HTML 완료 화면, `Masc_http_client` 연결), 로그아웃, 세션 조회, Admin allowlist 경로. 경로 등록은 구역을 받는 함수 하나이고 S1이 부팅에서 연 구역으로 부른다. 브라우저 세션 레코드(발급 뒤 7일). 다계정에서 `__Host-` 세션·transaction 쿠키, 세션에 결속한 CSRF 토큰, 출처 검사, cookie와 Bearer가 함께 오면 거부, 원격 query credential 차단(아래 C3 범위). | §5.2, §5.3 | A2, C2a, C2b, C2d |
| C4 | scoped PAT와 Service credential 레코드(principal + `Pat_scope`), 다계정 요청을 판정하는 새 `Auth_gate.decide`, 다계정에서 caller alias 유지·workspace secret(HTTP 복구 grace 포함, `auth.ml:185`)·auth disabled 경로를 쓰지 않음, `agent_credential` 읽기 거부. `Mcp_oauth_token`은 C5 전까지 Reject. C3의 요청 검사 함수를 요청 경로에 건다. WS/SSE·MCP transport를 세션이나 PAT에 결속하고(`__Host-masc_mcp_session`), 폐기 때 닫는다(2026-11-07 C3에서 옮김). Single_user 요청은 지금 함수가 판정한다. 세부는 표 아래 C4 범위다. | §5.3 | A2, A3, A4d, C3 |
| C5 | MCP OAuth 승인을 OIDC session에 결속한다. OAuth 스택(#46336, #46337, #46340, #46343, #46356, #46379)이 main에 들어간 뒤에만 연다. 결속 전에는 C4의 Reject가 그대로다. | §5.3 | C3, C4, OAuth 스택 병합 |
| C6 | Dashboard 화면(이슈 #46828). 다계정에서만 켜지고 `Single_user`의 bearer 방식은 그대로다. ① 인증이 필요한 요청이 거부되면 Google·GitHub 로그인 화면으로 보내고, 다계정에서는 저장한 bearer를 `Authorization`에 붙이지 않는다. ② 초대 링크 화면. fragment의 초대 token을 폼 POST로 보낸다(설계 §5.1-4). ③ Admin의 초대 발급·취소와 allowlist 등록 화면. 삭제된 principal의 신원에는 `previously_deleted`를 함께 보인다. 입장 대기 화면과 입장 요청 목록은 C2c와 함께 2단계다. 서버 API와 응답 형태는 C2a·C2b·C2d·C3가 정하고 이 층은 호출만 한다. 시험은 화면 문구나 행 순서가 아니라 상태 전이로 한다(요청 거부 → 로그인 이동, 초대 소비 → 세션 발급, 초대 취소 → 소비 거부). 20k token을 넘으면 ①②와 ③으로 쪼갠다. | §5.1, §5.2 | C2a, C2b, C2d, C3 |

**C2a 범위** (Google 로그인과 초대 입장, 2026-11-06)

- 지금 있는 것.
  - C1의 `Oidc_id_token_signature.verify_signature_and_expiry`는 서명과 `exp`만 본다. `iss`·`aud`·`nonce`·`sub`는 로그인 흐름이 본다. JWKS를 가져와 새로 두는 일도 부르는 쪽 몫이다(그 mli).
  - 바깥으로 나가는 HTTPS는 `Masc_http_client`(piaf, TLS)가 한다. PKCE S256은 `Auth_oauth.pkce_s256`이 있다. 진행 중인 흐름을 만료와 함께 메모리에 두는 선례는 `Keeper_oauth_pending`이다. 둘 다 nonce와 ID token이 없다.
  - 입장 레코드(`Authz_admission_event`)와 그 판정(`Authz_principal_state.admit`)은 있고, 그것을 쓰는 코드는 없다. 시험 밖에서 `Authz_zone.commit`을 부르는 곳은 `Authz_activation.write_invitation` 하나다.
  - 서버는 S1 전에 구역을 쥐지 않는다. 그래서 이 층의 코드는 시험이 구역을 직접 열어 부른다(4절). 쿠키(`__Host-masc_oidc_txn`, `__Host-masc_session`)는 C3이 만든다.
  - 삭제된 신원은 상태에 남지 않는다. `Authz_principal_state`는 삭제된 `user_id`만 들고, `Deleted` 사건의 신원은 버린다.
- Google 규칙(https://developers.google.com/identity/openid-connect/openid-connect, 2026-11-06 확인).
  - `iss`는 `https://accounts.google.com`이나 `accounts.google.com`이고, `aud`는 앱의 client ID다.
  - `sub`는 모든 Google 계정에서 하나뿐이고 다시 쓰이지 않는다. 대소문자를 가리는 ASCII 255자 이하다. email은 키로 쓰지 않는다.
  - 인가·token 엔드포인트와 `jwks_uri`는 discovery 문서(`https://accounts.google.com/.well-known/openid-configuration`)에서 읽는다. 문서는 이 주소를 코드에 고정하라고 한다. 키는 응답의 HTTP 캐시 헤더대로 둔다.
  - 위 두 `iss` 값과 discovery 주소는 Google이 정한 값이라 추측이 아니다. 한 곳(`Oidc_google` 선언)에만 두고, `iss`는 검증에만 쓴다. issuer 문자열로 갈래를 고르지 않는다(§6 결정 8). 신원 갈래는 어느 흐름이 돌았는지가 정한다. 엔드포인트 주소는 코드에 두지 않고 discovery에서 읽는다.
  - 만료 10분과 저장소 상한은 정책 값이다. 이름 있는 상수로 두고 이유를 주석에 적는다.
- 층은 다섯이다. 1~3은 구역과 닿지 않는다.
  - C2a-1 claim 판정. C1이 돌려준 payload를 읽어 `External_identity.Google { sub }`를 돌려준다. 네트워크와 시계를 쓰지 않고, 실패는 닫힌 합타입이다.
    - `iss`는 위 두 값 중 하나와 정확히 같아야 한다.
    - `aud`는 문자열이고 client ID와 같아야 한다. 목록이면 거절한다. 이 앱은 자기 client ID로만 요청하므로 목록이 올 일이 없고, 거절하면 `azp`를 따질 일도 없다.
    - `nonce`는 transaction의 값과 같아야 한다(`Eqaf.equal`). `sub`는 1~255자 ASCII 문자열이다.
    - `iat`·`nbf`는 보지 않는다. Google 문서의 검증 단계에 없다.
  - C2a-2 로그인 transaction. 시작할 때 `state`·`nonce`·PKCE verifier를 OS CSPRNG로 뽑아 메모리 저장소에 둔다.
    - 저장소의 키는 transaction ID다. C3이 이 ID를 `__Host-masc_oidc_txn`에 싣는다. callback은 키로 꺼낸 뒤 `state`를 `Eqaf.equal`로 비교한다.
    - 꺼내기는 한 번이다. 맞든 틀리든 꺼낸 항목은 지운다. 만료는 10분이고 꺼낼 때 본다.
    - 저장소에 든 항목 수에 상한을 둔다. 가득 차면 새 시작을 503으로 거절한다. 오래된 항목을 밀어내면 다른 사람이 진행 중인 로그인이 사라진다. 상한 값은 이 층이 정한다.
    - 초대 링크(B3d-1의 `/accounts/invite#<token>`)가 폼 POST로 보낸 token은 transaction 안에만 둔다. token은 추상 타입이고, 밖으로 내는 함수는 digest뿐이다. 그래서 로그와 오류 문구에 실리지 않는다(§5.1-4).
    - `return_to`는 접두어로 거르지 않고 RFC 3986 상대 참조로 파싱해 닫힌 타입 `Local_path.t`로 바꾼다(§5.2). scheme과 authority가 없고 path가 `/`로 시작해야 한다. RFC 3986 path에 없는 글자(`\` 등)는 파싱에서 거절한다. 브라우저가 `\`를 `/`로 읽어 `/\host`를 다른 호스트로 보내기 때문이다. 리다이렉트는 `Local_path.t`로만 만든다.
  - C2a-3 Google과 주고받기. discovery 문서, JWKS, token 교환이다. token 교환은 code·verifier·client ID·client secret·redirect URI를 보내 `id_token`을 받는다.
    - 전송은 함수로 받는다. `lib/auth`는 HTTP 클라이언트에 의존하지 않는다. 서버(C3)가 `Masc_http_client` 호출을 넘긴다(선례 `Keeper_oauth_flow.post`). 시험은 그 함수가 고정 응답을 내고 Google에 접속하지 않는다.
    - ID token은 브라우저에서 받지 않는다. 서버가 TLS로 받은 token 엔드포인트 응답에서만 받는다.
    - JWKS는 `Cache-Control: max-age` 동안 쓴다. token의 `kid`가 그 JWKS에 없으면 한 번 다시 가져온다. `kid`는 Google 응답에서 오므로 밖에서 다시 가져오기를 부추길 수 없다.
  - C2a-4 입장 쓰기. callback의 마지막 판정이다. 구역의 한 snapshot에서 읽는다.
    - 신원이 활성 principal이면 그 `user_id`로 로그인한다. `Disabled`이면 거절한다(§4.1). 초대 token이 함께 오면 409다. 이미 결속된 신원으로 새 User를 만드는 것은 sub 재결속이기 때문이다(§5.1-3). 아무것도 쓰지 않는다.
    - 신원이 없고 초대 token이 있으면 digest로 초대를 찾는다(`find_by_token_digest`). `user_id`와 namespace를 OS CSPRNG로 뽑아 입장 레코드 하나를 `Authz_zone.commit`으로 쓴다.
    - snapshot과 쓰기 사이에 다른 입장이 들어오면 `Authz_state.apply`가 거절한다. 같은 초대의 동시 소비와 같은 신원의 동시 입장은 409로 답한다.
    - 뽑은 `user_id`가 현재 principal이나 삭제된 id와 겹치면(`User_id_taken`) 새로 뽑아 다시 쓴다(§4.1). 만료됐거나 취소됐거나 없는 초대는 거절하고, 아무것도 쓰지 않는다.
    - 구역이 멈췄거나 `Uncertain`이면 입장시키지 않는다(§4.1 "ledger를 읽지 못하면 principal을 만들지 않는다").
    - 신원도 초대 token도 없으면 아무것도 쓰지 않고 거절한다. 1단계에는 입장 요청 (c)가 없다.
    - `previously_deleted`: `Authz_principal_state`가 `Deleted` 사건의 신원을 모은다. `authz.jsonl`을 읽어 만드는 값이고 principal 레코드에는 없다(§5.1-6). 입장 결과가 이 표지를 싣고, 화면은 C6 ③이 보인다.
  - C2a-5 설정과 흐름. `auth_config.google` 설정과, 로그인 하나를 시작부터 입장 판정까지 도는 함수다. HTTP 경로는 C3이 만든다(2026-11-06 범위 조정). 경로는 transaction ID를 `__Host-masc_oidc_txn` 쿠키로 주고받는데 그 쿠키가 C3의 것이라, 이 층에 경로를 두면 callback이 transaction을 찾지 못한다.
    - 설정은 `auth_config.google`다. client ID, redirect URI, client secret을 담은 환경 변수의 이름을 둔다. 멤버 이름은 프로토콜이 아니라 provider다. C2b의 GitHub client는 같은 모양의 `github` 멤버다. secret 값은 `config.json`에 두지 않는다. `save_auth_config`가 그 파일을 다시 쓰고, 백업에도 들어가기 때문이다. 이 필드를 쓰는 곳은 다계정 경로뿐이다.
    - client는 이 설정과 환경 변수로 만든다. redirect URI는 `https` URL이어야 한다. `__Host-` 쿠키는 `Secure`라서 다계정 로그인은 `https`에서만 돈다.
    - start는 초대 token(선택)과 `return_to`를 받는다. discovery를 먼저 읽고 transaction을 만든다. discovery가 실패하면 저장소에 아무것도 남지 않는다. 결과는 transaction ID와 Google 인가 URL이다.
    - callback은 C2a-2, 3, 1, 4 순서로 돈다. transaction을 먼저 꺼내므로, Google이 거절을 돌려보낸 callback도 transaction을 지운다. 결과는 입장 판정과 `return_to`다.
    - 시험은 Google을 흉내 낸다. 인가 URL에서 `nonce`와 `code_challenge`를 읽고, 시험이 만든 RSA 키로 ID token에 서명하고, token 엔드포인트에서 `code_verifier`의 S256을 확인한다.
- 시험 벡터는 표의 C2a 행을 따른다. C1이 서명을, C2a-1이 `iss`·`aud`·`nonce`를, C2a-2가 `state`를 맡는다. 만료됐거나 취소된 초대 token, 초대 동시 소비(409), `Disabled` 등록 사용자의 로그인, 미등록 사용자의 거절은 C2a-4가 맡는다.
- 하지 않는 것: HTTP 경로·세션·쿠키·CSRF·완료 화면(C3), GitHub(C2b), 입장 요청(C2c), 화면(C6), 서버가 구역을 쥐는 일(S1).
- allowlist (a)는 C2d다(2026-11-06 사용자 결정). masc Admin은 Google `sub`를 미리 알기 어렵다. 개인 Gmail은 email로 `sub`를 찾는 공개 방법이 없다. Workspace 계정은 그 도메인 관리자가 Directory API로 알 수 있을 수 있다(확인 필요). 1단계에는 미등록 로그인이 아무것도 남기지 않는다. 그래서 masc 안에서 Admin이 고를 수 있는 Google 신원은 `Deleted` 사건에 남은 것뿐이다. 초대 (b)만으로도 모두 들일 수 있어서, C2a는 (b)만 다룬다.

**C2b 범위** (GitHub 로그인과 초대 입장, 2026-11-06)

- 지금 있는 것.
  - 신원 `Authz_external_identity.Github { user_id }`가 있다. 양수이고 2^53-1 이하다. 입장 판정 `Authz_login.sign_in`(C2a-4)은 신원 갈래를 가리지 않는다. C2b는 GitHub 신원을 만들어 넘기면 된다.
  - C2a의 transaction 저장소(`Oidc_login_transaction`)는 `state`, PKCE verifier, 초대 token, `return_to`, Google의 `nonce`를 둔다. 설계 §5.2.1은 `__Host-masc_oidc_txn` 하나가 GitHub 흐름의 `state`와 PKCE도 결속한다고 한다. 지금 저장소는 어느 흐름이 시작한 transaction인지 모른다.
  - C2a의 전송 함수 `get`은 헤더를 받지 않는다. GitHub `GET /user`는 `Authorization` 헤더가 있어야 한다.
  - `Masc_http_client`는 `User-Agent`가 없으면 `masc/<버전>`을 붙인다(`lib/masc_http_client/masc_http_client.ml:129`). `lib/keeper/keeper_github_app_broker.ml:126`은 `X-GitHub-Api-Version: 2022-11-28`을 보낸다.
- GitHub 규칙(2026-11-06 확인).
  - 인가는 `https://github.com/login/oauth/authorize`이고 `client_id`, `redirect_uri`, `state`, `code_challenge`, `code_challenge_method=S256`을 보낸다. GitHub은 `plain`을 받지 않는다. `scope`를 보내지 않으면 처음 승인하는 사용자의 scope는 비어 있다([Authorizing OAuth apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)).
  - code는 10분 뒤 만료된다. transaction 수명(C2a-2, 10분)과 같다.
  - redirect URI는 등록한 callback URL과 정확히 같아야 한다. 새 앱은 wildcard 일치가 꺼져 있다.
  - token 교환은 `POST https://github.com/login/oauth/access_token`이다. `client_id`, `client_secret`, `code`, `redirect_uri`, `code_verifier`를 보낸다. 응답 형식은 `Accept` 헤더가 정하므로 `application/json`을 보낸다. 오류 응답은 `error` 멤버를 가진다(`bad_verification_code`, `incorrect_client_credentials`, `redirect_uri_mismatch`, `unverified_user_email`; [token 오류](https://docs.github.com/en/apps/oauth-apps/maintaining-oauth-apps/troubleshooting-oauth-app-access-token-request-errors)).
  - 오류 응답의 HTTP 상태는 문서에 없다(확인 필요). 그래서 상태 코드만으로 성공을 판정하지 않는다. 200이고 `access_token` 문자열이 있을 때만 성공이고, 그 밖은 상태와 `error` 멤버를 담아 거절한다.
  - `GET https://api.github.com/user`는 `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version`을 보낸다. scope 없는 token도 그 주인으로 인증되고 공개 응답을 받는다. `id`는 int64 정수다([users](https://docs.github.com/en/rest/users/users#get-the-authenticated-user)).
  - `User-Agent`가 없는 요청은 거절된다([getting started](https://docs.github.com/en/rest/using-the-rest-api/getting-started-with-the-rest-api)).
  - 버전 헤더가 없으면 `2022-11-28`이고, 이 버전은 2028-03-10에 지원이 끝난다. 최신은 `2026-03-10`이고 종료일이 없다([API versions](https://docs.github.com/en/rest/about-the-rest-api/api-versions)). 이 층은 `2026-03-10`을 보낸다.
  - 세 주소와 API 버전은 GitHub이 정한 값이라 추측이 아니다. GitHub에는 discovery 문서가 없다. 네 값은 한 곳(`Github_oauth` 선언)에만 둔다.
- 층은 셋이다. C2b-1과 C2b-2는 구역에 닿지 않는다. HTTP 경로는 셋 다 만들지 않는다(C3).
  - C2b-1 공용 transaction과 전송.
    - transaction이 시작한 흐름을 타입으로 든다(GADT `_ flow = Google : google flow | Github : unit flow`). Google transaction은 nonce를 들고, GitHub transaction은 들지 않는다. 꺼낼 때 부르는 쪽이 흐름을 대고, 다른 흐름이면 지우고 `Other_flow`로 거절한다.
    - 모듈 이름 `Oidc_login_transaction`은 그대로 둔다. 설계(§5.2.1)가 GitHub 흐름의 쿠키도 `__Host-masc_oidc_txn`이라고 부르기 때문이다.
    - 전송 함수 `get`이 헤더를 받는다. Google의 discovery와 JWKS는 빈 헤더로 부른다. 전송 타입은 두 흐름이 함께 쓰는 모듈 `Login_transport` 하나에 둔다.
    - PR은 둘로 나눈다. C2b-1a가 전송, C2b-1b가 transaction이다.
  - C2b-2 GitHub과 주고받기. 인가 URL, token 교환, `GET /user` 한 번이다.
    - access token은 이 함수 안에서만 쓴다. 저장하지 않고, 로그와 오류 문구에 싣지 않는다.
    - `id`가 정수가 아니거나 `Authz_external_identity.github`가 거절하면(0 이하, 2^53-1 초과) 거절한다. `login`과 email은 읽지 않는다.
    - `User-Agent: masc`를 직접 보낸다. 전송을 바꿔도 GitHub이 거절하지 않게 하기 위해서다.
    - 응답 크기 상한은 C2a-3의 `max_document_bytes`(64 KiB)를 같이 쓴다.
  - C2b-3 설정과 흐름. `auth_config.github`(타입 `login_client`, C2a-5a)와 `Github_login_flow`의 start·callback이다. callback은 transaction(C2b-1), 교환(C2b-2), 입장(C2a-4) 순서로 돈다. transaction을 먼저 꺼내므로, GitHub이 거절을 돌려보낸 callback도 transaction을 지운다.
- 시험은 표의 C2b 행을 따른다. GitHub은 C2a처럼 시험의 전송 함수가 흉내 낸다. `lib/auth`는 HTTP 클라이언트에 의존하지 않아서, 표의 "로컬 HTTP 서버"는 전송 함수로 바꾼다.
  - C2b-1: 다른 흐름의 transaction, `state` 불일치.
  - C2b-2: token 오류 응답(200과 400 모두), `GET /user` 실패, `id` 없는 응답, `id`가 문자열인 응답, 큰 `id`, 오류 문구에 token과 secret이 없음.
  - C2b-3: 같은 사람의 Google·GitHub 로그인이 서로 다른 principal로 남는다(설계 §5.1-5). 만료됐거나 취소된 초대는 C2a-4의 판정으로 거절된다.
- 하지 않는 것: HTTP 경로 `/auth/github/start`·`/auth/github/callback`과 쿠키(C3), allowlist(C2d), GitHub Enterprise Server, `keeper_github_app_broker.ml`의 버전 헤더 변경.

**C2d 범위** (allowlist 입장, 2026-11-06)

- 사용자 결정(2026-11-06).
  - 등록으로 들어온 사람은 Member다. 등록에는 역할이 없다. Admin은 초대 (b)로만 들인다.
  - 등록을 지우는 사건은 그 등록을 subject로 한 `Revoke`로 쓰고 Intent/Committed를 남긴다. 복원이 지우기를 되감으면 그 신원이 다시 들어올 수 있어서다. 초대 취소와 같은 까닭이다.
  - 등록은 intent를 쓰지 않는다. 되감으면 등록이 사라져서 막히는 쪽이 된다.
  - 초대로 들어와도 그 신원의 열린 등록을 같이 쓴다. 그래서 나중에 삭제된 사람이 옛 등록으로 다시 들어오지 못한다. 다시 들이려면 Admin이 새로 등록한다.
  - Admin이 등록하고 지우는 서버 함수는 C2d가 만든다. C6은 이 함수를 부르기만 한다.
- 지금 있는 것.
  - 초대 입장은 `Kind.Invite`, `Authz_invite_event`(`Issued`·`Revoked`), `Authz_invite_state`, 입장 레코드의 `invite_id`로 이어진다. `Authz_login.sign_in`은 초대 token도 결속도 없으면 `Not_invited`로 거절한다.
  - 초대 취소는 이미 `Revoke`(subject는 초대)로 intent를 쓰고, 발급은 쓰지 않는다(설계 §8.2).
  - 다계정 부팅은 아직 `Multi_account_not_served`로 멈춘다. 그래서 어느 로그에도 입장 레코드가 없다. 입장 본문을 바꾸는 일은 hard cut이고, 옛 본문을 읽는 코드를 두지 않는다.
- 새로 두는 것.
  - Kind `Registration`. 쓰는 이는 인증된 principal이고, 그중 Admin만 받는다. 로컬 운영자는 등록하지 않는다. 로컬 운영자의 길은 `masc auth invite` 하나다.
  - 사건은 `Registered { registration_id; identity }`와 `Removed { registration_id }`다. id는 `Authz_types.Registration_id`다.
  - 등록 상태. 한 신원에 열린 등록은 하나다. 이미 결속된 신원은 등록하지 않는다. 등록은 열림, 지워짐, 쓰임(누가 썼는지) 중 하나다.
  - Subject `Registration of registration_id`(설계 §4.5). intent의 subject는 신원이 아니라 id다. 신원은 `authz.jsonl` 사건에만 둔다(설계 §4.1).
  - 입장 본문의 `invite_id`를 `through : Invite of invite_id | Registration of registration_id`로 바꾼다.
  - `sign_in`의 시그니처는 그대로다. 초대 token이 없고 결속도 없을 때, 열린 등록이 있으면 그 등록으로 입장한다. 같은 신원의 등록 입장과 초대 입장이 겹치면 먼저 쓴 쪽이 들어가고 뒤의 것은 409다(§5.1-3).
  - Admin의 `register`·`remove`. 등록할 신원이 삭제된 principal의 것이면 `previously_deleted`를 함께 돌려준다(§5.1-6).
- 층. 층마다 Kind 하나나 사건 하나를 더한다(B3c와 같은 방식).
  - C2d-1 id와 사건 본문.
  - C2d-2 Kind `Registration`. 상태는 아직 `Kind_not_read`로 거절한다.
  - C2d-3 Subject `Registration`과 설계 §4.5·§8.2의 문장.
  - C2d-4 등록 상태.
  - C2d-5 `Authz_state`가 Kind를 읽는다. 등록은 intent가 없고 지우기는 있다. 지우기의 append가 실패하면 그 등록은 잡혀 있다(§8.3).
  - C2d-6 입장이 등록을 쓴다. 입장 본문을 hard cut으로 바꿔서 파일이 10개를 넘는다. 시작할 때 범위를 다시 알린다.
  - C2d-7 `sign_in`의 등록 갈래.
  - C2d-8 Admin의 `register`·`remove`.
- 시험은 표의 C2d 행을 따른다.
  - C2d-4·5: 한 신원의 두 번째 열린 등록은 거절, 결속된 신원의 등록은 거절, 삭제 뒤 재등록은 받음, 지우기의 intent.
  - C2d-6·7: 등록 안 된 신원은 거절되고 아무것도 쓰지 않음, 지운 뒤의 로그인은 거절, 등록 입장과 초대 입장이 겹치면 409, 초대 입장이 열린 등록을 같이 씀.
  - C2d-8: 삭제된 신원을 다시 등록하면 `previously_deleted`가 보인다.
- 하지 않는 것: HTTP 경로(C3), 화면(C6), 입장 요청(C2c), Google `sub`를 email로 찾기.

**C3 범위** (로그인 HTTP 경로와 브라우저 세션, 2026-11-07)

- 사용자 결정(2026-11-07).
  - 브라우저 세션은 `authz.jsonl` 레코드다. 발급과 폐기를 레코드로 쓴다. 서버가 다시 시작해도 로그인이 남는다.
  - 세션은 발급하고 7일 뒤 끝난다. 쓰는 동안 늘리지 않는다.
- 지금 있는 것.
  - 로그인 흐름은 `Google_login_flow`(C2a-5)와 `Github_login_flow`(C2b-3c)다. 둘 다 start와 callback을 내고 쿠키는 보지 않는다. transaction 저장소(`Oidc_login_transaction`)는 흐름을 가린다. 다른 흐름이 시작한 transaction은 `Other_flow`로 거절한다.
  - 세션 레코드는 없다. `Authz_records.Auth_binding_status`(Active·Revoked) 타입만 있다.
  - 경로는 `Http_server_eio`의 router에 `Server_route.get`·`post`로 단다(`lib/server/server_routes_http.ml:15-47`). 로그인 전에 오는 경로의 접근 표시는 `Self_authenticated Oauth_protocol`이다. 선례는 Keeper OAuth callback이다(`server_keeper_oauth_http.ml:30-39, 216`). HTML은 `Http.Response.html`로 낸다.
  - HTTP/2는 router의 `dispatch`를 거치지 않는다. `server_h2_gateway.ml`에 경로마다 손으로 쓴 갈래가 있고, 갈래가 없는 경로는 404다(`:2084-2085`).
  - 쿠키는 `get_cookie_value`(`server_mcp_transport_http_session.ml:654-664`)가 읽는다. 쓰는 곳은 `mcp-session-id` 하나다(`server_mcp_transport_http_headers.ml:336-339`).
  - 바깥 HTTPS는 `Masc_http_client.get_response_sync`·`post_response_sync`다. 이것을 `Login_transport.get`·`post`로 바꾸는 서버 함수는 없다.
  - 서버는 S1 전에 구역을 쥐지 않는다. 다계정 부팅은 `Authz_boot_mode_read.decide`가 멈춘다. 그래서 이 층의 경로는 시험이 구역을 열고 router에 달아 부른다.
- 세션 레코드.
  - Kind `Session`. 쓰는 이는 인증된 Human이다.
  - 사건은 `Issued { session_id; user_id; secret_digest; replaces }`와 `Revoked { session_id }`다. `secret_digest`는 쿠키 secret의 SHA-256이다. secret은 쿠키에만 있고 레코드와 로그에 싣지 않는다.
  - 발급은 그 세션의 `user_id`가 쓴다. `replaces`는 로그인을 시작한 브라우저의 기존 세션이다. 새 발급과 옛 세션 폐기가 레코드 하나라서 한 번에 일어난다(설계 §5.2). 옛 세션은 다른 사람의 것이어도 된다. 서버는 쿠키의 secret을 맞춰 본 세션만 `replaces`에 넣는다. 세션 쿠키가 `SameSite=Strict`라서 provider에서 돌아오는 callback에는 실리지 않는다. 그래서 같은 출처 `POST`인 start가 세션을 맞춰 보고 transaction에 넣는다(C3-8a).
  - 폐기는 그 세션의 `user_id`가 쓴다(로그아웃). Admin이 남의 세션을 끊는 길은 principal `Disable`이다. 세션을 읽을 때 principal이 Active인지 본다.
  - 폐기와 `replaces`가 있는 발급은 끊는 세션을 subject로 한 `Revoke` intent를 쓴다(설계 §8.1 `auth_binding_epoch`, §8.2). 복원이 폐기를 되감으면 끊은 세션이 다시 살아나기 때문이다. `replaces`가 없는 발급은 intent를 쓰지 않는다. 되감기면 그 세션이 사라져 로그아웃될 뿐이다.
  - 만료는 레코드에 쓰지 않는다. 발급 레코드의 `at_ms`에 7일을 더한 시각이 지나면 읽을 때 거절한다.
  - Subject `Session of session_id`(설계 §4.5).
- 쿠키와 요청 검사.
  - 쿠키 둘은 설계 §5.2의 속성을 따른다. `__Host-masc_session`의 값은 session ID와 secret이다. secret은 OS CSPRNG의 32바이트다. 서버는 ID로 세션을 찾고 digest를 `Eqaf.equal`로 비교한다.
  - CSRF token은 저장하지 않고 secret에서 만든다(용도 이름을 붙인 SHA-256). 쿠키가 HttpOnly라서 화면은 secret을 읽지 못한다. 화면은 `GET /auth/session`의 답에서 CSRF token을 받는다.
  - 요청 검사는 함수 하나다. 다계정에서 세션 쿠키와 bearer가 함께 오면 401이다. 세션 쿠키가 있는 GET·HEAD 밖의 요청은 Origin이 같은 출처이고 CSRF 헤더가 맞아야 한다. Origin이 없으면 거절한다. 원격 query credential(`token`, `sse_kind=observer`, IDE LSP)은 다계정에서 401이다.
  - 이 함수를 요청 경로에 거는 일은 C4의 `Auth_gate.decide`가 한다.
- 경로. 등록 함수 하나가 구역, transaction 저장소, 두 login client, 전송, 시계, 뽑기를 받는다. S1이 부팅에서 부른다.
  - `POST /auth/oidc/start`, `POST /auth/github/start`. 폼으로 초대 token(선택)과 `return_to`를 받는다. 같은 출처 Origin을 요구한다. 남의 초대 token을 담은 로그인을 피해자 브라우저에서 시작시키지 못하게 하려는 것이다. transaction ID를 `__Host-masc_oidc_txn`에 싣고 인가 URL로 303을 보낸다.
  - `GET /auth/oidc/callback`, `GET /auth/github/callback`. transaction 쿠키만 인증 입력이다. 다른 흐름의 transaction은 401이다.
    - 입장 판정이 로그인이면 세션을 발급한다. start가 transaction에 넣은 기존 세션이 아직 동작하면 `replaces`로 같이 끊는다.
    - 답은 비공개 데이터가 없는 200 HTML 완료 화면이다. 거절은 일반 문구의 HTML이고, 409(`Authz_login.is_conflict`)와 401·403·503을 가린다.
    - transaction 쿠키는 어느 답에서나 지운다.
  - `POST /auth/logout`. CSRF 검사를 받고, 폐기를 쓰고, 세션 쿠키를 지운다.
  - `GET /auth/session`. 세션의 `user_id`, 끝나는 시각, CSRF token을 JSON으로 낸다. 캐시하지 않는다.
  - Admin allowlist 경로 `POST /api/v1/auth/allowlist`, `DELETE /api/v1/auth/allowlist/<id>`. 세션과 CSRF를 검사하고 Admin인지 본 뒤 `Authz_allowlist.register`·`remove`(C2d-8)를 부른다.
  - 전송은 `Masc_http_client`를 `Login_transport`로 바꾸는 서버 함수다.
- 층. C3-1~5는 C2d처럼 한 층에 하나씩 더한다.
  - C3-1 session ID와 사건 본문.
  - C3-2 Kind `Session`. 상태는 아직 `Kind_not_read`로 거절한다.
  - C3-3 Subject `Session`과 설계 §4.5·§5.2·§8.2 문장.
  - C3-4 세션 상태.
  - C3-5 `Authz_state`가 Kind를 읽는다.
  - C3-6 세션 발급·인증·폐기와 CSRF token(`lib/auth`).
  - C3-7 쿠키와 요청 검사 함수.
  - C3-8 로그인 경로. 8a는 transaction이 기존 세션을 든다. 8b는 start·callback·logout·session의 답과 완료 화면(`Login_routes`)이다. 8c는 서버 쪽 연결이다(`Masc_http_client` 전송, 요청 읽기, 답 쓰기).
  - C3-9 Admin allowlist 경로의 답(`Login_allowlist_routes`). C2d가 main에 들어간 뒤 쌓았다(2026-11-07).
- 옮긴 것.
  - WS/SSE의 세션 결속과 폐기 때 닫기는 C4로 옮긴다. 연결은 C4의 `Auth_gate.decide`가 요청을 세션으로 인증한 뒤에야 세션을 안다. C3에 두면 아무도 채우지 않는 필드가 남는다. `__Host-masc_mcp_session`도 transport 결속과 함께 C4가 만든다.
  - 경로를 `make_routes`에 다는 일과 HTTP/2 갈래는 S1이 한다. S1 전에는 서버에 구역이 없다.
- 시험.
  - C3-4·5: 남의 세션 폐기 거절, 두 번 폐기 거절, 끝난 세션을 `replaces`로 받지 않음, 폐기와 `replaces` 발급의 intent, 7일 만료.
  - C3-6·7: secret이 틀린 쿠키, 만료된 세션, Disable된 principal의 세션, cookie와 bearer가 함께 온 요청, Origin 없는 POST, CSRF 불일치, 원격 query credential.
  - C3-8: 시험이 Google과 GitHub을 흉내 내고 구역을 직접 연다. 다른 흐름의 transaction 쿠키는 401, callback이 기존 세션을 끊음, 같은 초대의 동시 소비는 409, 거절 화면에 token과 secret이 없음.
- 하지 않는 것: `Auth_gate.decide`와 요청 경로 연결(C4), MCP OAuth 결속(C5), 화면(C6), 경로 등록과 HTTP/2(S1).

**C4 범위** (다계정 credential 판정, 2026-11-07)

- 사용자 결정(2026-11-07).
  - `Auth_gate.decide`는 다계정 요청만 판정한다. Single_user 요청은 지금 함수가 그대로 판정한다. 그래서 C4 동안 Single_user 서버의 인증 동작은 바뀌지 않는다. 두 모드를 한 함수로 합치는 일은 Single_user의 legacy 경로를 지울 때 한다(설계 §5.3을 고쳤다).
  - Service credential(`Internal_service_credential`)은 호스트 CLI가 `Local_operator`로 발급하고 폐기한다. Keeper가 다계정에서 쓰는 credential이다(설계 §6.3을 고쳤다).
  - scoped PAT는 본인이 브라우저 세션으로 부르는 HTTP 경로가 본인 작성으로 발급하고 폐기한다. C4는 그 경로의 답까지 만든다. 화면은 C6이 만든다.
- 지금 있는 것(main `3519bd8c658`).
  - HTTP 판정은 `Server_auth`의 함수 아홉 개다. `ensure_strict_http_token_auth`(:37), `dashboard_actor_resolution_for_request`(:470), `authorize_permission_request`(:1108), `authorize_read_request`(:1129), `authorize_tool_request_with_actor`(:1132), `request_credential_standing`(:1167), `authorize_tool_request`(:1199), `authorize_token_bound_permission_request`(:1208), `authorize_optional_token_bound_permission_request`(:1247)다. credential은 `request_auth_credential_from_request`(:62)가 `Authorization: Bearer`와 `x-masc-internal-token`에서 읽는다. token이 없으면 actor 이름을 header와 query(`x-masc-agent` 등)에서 받는다.
  - MCP 판정은 `verify_mcp_auth_unscoped`(:242)와 그 변형(seat, authority, observer stream, operator), WS의 `verify_dashboard_token`, stdio(`mcp_server_eio.ml`), 프로토콜의 `require_auth`(`mcp_server_eio_protocol.ml:61`)다. 호출자 이름은 `Mcp_server_eio_caller_identity.resolve`가 정한다. token 해석이 실패해도 경고만 남기고 alias를 쓴다(`resolve_auth_fallback_agent_name`, `:157`).
  - 역할은 `Auth.resolve_role_with_auth_config`(`auth.ml:185`)가 정한다. auth disabled와 workspace secret(HTTP recovery grace)은 Admin이다. Keeper 내부 token은 Worker다. 그 밖에는 `agent_credential`의 role이다.
  - 다계정 부팅은 `Authz_boot_mode_read.decide`(`:149`)가 멈춘다. 부팅은 auth disabled, `require_token=false`, 익명 mutation 설정도 거부한다(`authz_boot_mode.ml`). 판정한 모드는 요청 시점 코드로 넘어가지 않는다.
  - `Pat_scope`와 `Pat_binding`은 `Authz_types`에 있고 §6.2 판정(`Authz_decision`)만 쓴다. Kind `Internal_service_credential`은 있지만 본문이 없고 상태가 읽지 않는다. principal 사건은 Human만 다룬다. PAT Kind와 `Auth_gate`는 없다.
  - 브라우저 세션 요청 검사는 `Authz_browser_request.check`(C3-7)다. 아직 요청 경로에 걸리지 않았다.
  - strict 설정에서 경로가 열리는지는 A4d 뒷부분(스택 #49656) 뒤에 `Route_access` 종류 하나가 정한다. C4는 그 위에 쌓는다.
- credential 표시.
  - 요청에서 credential을 하나 읽는다. 닫힌 합타입이다. 없음, 세션 쿠키, PAT, Service credential, MCP OAuth token, legacy bearer(workspace secret, `agent_credential`, Keeper 내부 token), query credential, 둘 이상, 읽지 못함.
  - 새 token은 종류 접두사, ID, secret을 든다. 레코드는 secret의 digest만 든다. 서버는 ID로 레코드를 찾고 digest를 `Eqaf.equal`로 비교한다. 새 형식이 아닌 bearer는 legacy로 읽는다.
- 판정 `Auth_gate.decide`.
  - credential 표시, 경로의 `Route_access.t`, 구역 상태, 시각을 받는다. `Allow`나 `Reject of 사유`를 돌려준다. `Log_only`는 없다. Single_user가 이 함수를 쓰지 않아서 타입에 두지 않는다.
  - `Allow`는 인증 투영(principal, auth_binding, `Pat_scope`)을 든다. auth_binding은 세션·PAT·Service credential의 ID다. Service credential의 `Pat_scope`는 `Not_pat`이다. 범위는 grant와 DelegatePolicy가 정한다(설계 §5.3).
  - 자격이 필요 없는 종류(`Always_public`, `Public_read Open_when_strict`)는 credential 없이 연다. 그 밖의 종류는 경로 종류마다 다계정 처분을 표로 정한다. Admin은 `Admin_assignment`에서만 온다.
  - 거절 사유. legacy bearer는 `Legacy_credential_forbidden`이다. MCP OAuth token은 C5 전까지 Reject다. query credential과 세션 쿠키·bearer 동시 제시는 401이다(C3-7). 폐기됐거나 만료된 PAT·Service credential과 Disable된 principal도 Reject다.
  - Actor_hint(agent query·header, `x-masc-keeper-name`)는 신원을 바꾸지 않는다. Service credential에 다른 service hint가 오면 Reject다.
- 레코드.
  - Kind `Pat`(새 종류)와 `Internal_service_credential`의 본문이다. 사건은 발급과 폐기다. 발급은 ID, principal, secret digest, 범위를 든다. PAT의 principal은 Human이고 `Pat_scope`를 든다. Service credential의 principal은 `Service(service_id)`다.
  - PAT는 그 PAT의 Human이 쓴다. Service credential은 `Local_operator`가 쓴다.
  - 폐기는 그 credential을 subject로 한 `Revoke` intent를 쓴다(설계 §8.1 `auth_binding_epoch`, §8.2). 복원이 폐기를 되감으면 끊은 credential이 다시 살아나기 때문이다.
  - PAT 만료는 `Pat_scope.expires_at`이다. 레코드에 따로 쓰지 않고 읽을 때 거절한다.
  - Service principal은 Service credential의 첫 발급이 만든다. Service principal의 Disable과 삭제 사건은 이 층에 없다. 끊는 일은 credential 폐기로 한다.
- 층. C4-1~5는 C3처럼 한 층에 하나씩 더한다.
  - C4-1 PAT·Service credential ID, token 형식, 사건 본문. 넷으로 나눈다. C4-1a는 두 ID와 token 형식(`mpat_`·`msvc_` 접두사, secret digest)이다. C4-1b는 `Authorization_scope`의 본문이다. C4-1c는 PAT 사건, C4-1d는 Service credential 사건이다.
  - C4-2 Kind `Pat`와 `Internal_service_credential` 작성자 규칙. 상태는 아직 `Kind_not_read`로 거절한다.
  - C4-3 Subject `Pat`·`Service_credential`과 설계 §4.5·§8.2 문장.
  - C4-4 두 credential의 상태(목록, 폐기, 만료).
  - C4-5 `Authz_state`가 두 Kind를 읽는다.
  - C4-6 발급·인증·폐기(`lib/auth`).
  - C4-7 credential 표시 읽기(HTTP 요청에서 닫힌 합타입으로).
  - C4-8 `Auth_gate.decide`와 경로 종류별 처분 표.
  - C4-9 Service credential CLI(발급, 폐기, 목록). token은 발급할 때 한 번만 보인다.
  - C4-10 PAT 경로의 답(발급, 폐기, 목록). 세션과 CSRF를 검사하고, 범위를 명시해야 발급한다. C3-9처럼 HTTP 없는 답과 서버 연결을 나눈다.
  - C4-11 MCP 호출자. 다계정에서는 token 해석이 실패하면 alias를 쓰지 않고 Reject한다.
  - C4-12 WS/SSE와 MCP transport를 인증한 세션·PAT에 결속하고 폐기 때 닫는다(C3에서 옮긴 일). `__Host-masc_mcp_session`도 여기서 만든다.
- 시험.
  - C4-4·5: 남의 PAT 폐기 거절, 두 번 폐기 거절, 만료, 폐기의 intent.
  - C4-6·7: secret이 틀린 token, 폐기된 token, Disable된 principal, legacy bearer, 둘 이상의 credential, query credential.
  - C4-8: 경로 종류와 credential 표시의 모든 쌍. credential이 없으면 자격이 필요한 모든 종류가 Reject한다(설계 §5.3의 다계정 개시 조건).
  - C4-11: token 해석 실패, Actor_hint와 다른 service.
- 하지 않는 것: Single_user 경로 바꾸기, MCP OAuth 결속(C5), 화면(C6), 경로 등록·HTTP/2 갈래·부팅에서 모드 넘기기(S1), Service principal의 Disable·삭제, legacy 호출자를 Service credential로 옮기는 일(S1 전 개시 증거에서 목록으로 센다).

**미리보기 범위** (localhost 다계정 확인, 2026-11-08)

- 사용자 결정(2026-11-08).
  - C4-8 뒤에 사람이 브라우저로 다계정 로그인을 해 보는 길을 먼저 연다.
  - redirect는 loopback 전용 타입으로 연다. 실제 서버의 https 규칙은 그대로 둔다.
- 하는 일. 사람이 자기 컴퓨터에서 이 순서를 해 본다.
  1. GitHub으로 로그인한다.
  2. 세션이 생긴다.
  3. 서버가 그 사람을 누구로 보는지 확인한다.
  4. 로그아웃한다.
- 서버(`masc serve`)는 바꾸지 않는다. 다계정 설치에서 부팅이 멈추는 것도 그대로다(S1). S1이 D1~D4 뒤인 이유는 소유권 검사 없이 Keeper와 Runtime을 서빙하면 안 되기 때문이다. 미리보기는 Keeper, Runtime, MCP, Board 경로를 하나도 열지 않는다.
- 명령은 `masc auth preview --port N --github-client-id ID`다.
  - `masc auth invite`처럼 다계정이 활성인 설치에서만 간다(`Authz_activation`의 판정).
  - BasePath lease를 쥔다. 그래서 같은 base path에서 서버와 함께 돌지 않는다.
  - 설치 기록이 가리키는 외부 저장소로 구역을 연다.
  - `127.0.0.1:N`에만 bind한다. 요청 authority는 `http://127.0.0.1:N` 하나만 믿는다(`Server_request_authority.make_trust_policy`).
  - GitHub client secret은 환경 변수 `MASC_GITHUB_CLIENT_SECRET`에서 읽고 출력하지 않는다. Google 경로는 client가 없어서 404다.
- loopback client.
  - `Login_client.loopback ~client_id ~client_secret ~port ~path`가 redirect `http://127.0.0.1:<port><path>`를 직접 만든다. host는 인자로 받지 않는다.
  - `make`와 `of_environment`는 지금처럼 https만 받는다. S1의 부팅은 `of_environment`만 부른다.
- 여는 경로.
  - `Server_login_http.add_routes`의 8개. 로그인 시작·callback, 로그아웃, 세션, allowlist다.
  - `GET /accounts/invite`. 초대 링크(`Authz_activation.link`)가 여는 페이지다. fragment의 token을 form에 넣어 `POST /auth/github/start`로 보낸다. token은 요청 줄에 실리지 않는다.
  - `GET /`. 세션을 보여 주고, 로그아웃 버튼이 있다. CSRF token은 `GET /auth/session`에서 읽는다.
  - `GET /api/v1/auth/whoami`. `Auth_gate.decide`가 `Read_auth`로 판정한다. principal, 역할, binding을 JSON으로 답하거나 401·403으로 답한다. `decide`를 부르는 첫 실제 경로다.
- 확인한 사실(2026-11-08).
  - GitHub OAuth App은 loopback redirect `http://127.0.0.1:<port>/path`를 받는다. 등록한 callback URL과 포트가 달라도 된다([GitHub 문서 Loopback redirect urls](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#loopback-redirect-urls)). 문서는 RFC 8252를 따라 `localhost`보다 `127.0.0.1`을 권한다.
  - Chromium 148(Playwright 1.60 headless)은 `__Host-` 접두사, `Secure`, `HttpOnly`, `SameSite=Strict`가 붙은 쿠키를 http://127.0.0.1과 http://localhost에서 저장했다. 같은 출처 fetch에도 실어 보냈다. Firefox와 WebKit은 실행 파일이 없어 확인하지 못했다.
  - MDN은 localhost의 `Secure` 예외만 적는다. `__Host-` 접두사와 127.0.0.1에도 같은 예외가 적용되는지는 적지 않는다.
- 층.
  - P1 `Login_client.loopback`과 그 시험.
  - P2 미리보기 페이지와 whoami의 답. `Login_routes`처럼 HTTP 없는 답과 서버 연결을 나눈다.
  - P3 `masc auth preview` 명령. 사람이 실제 브라우저로 한 확인을 PR 본문에 적는다.
- 시험.
  - P1: redirect 문자열, port 범위, `make`가 여전히 http를 거절함.
  - P2: whoami가 세션이면 principal과 역할을, credential이 없으면 401을, legacy bearer면 401을 답함.
- 하지 않는 것: Google 미리보기, loopback 밖 bind, `masc serve` 바꾸기, Keeper·Runtime 경로. S1이 로그인 경로를 서버에 달면 이 명령을 지운다.

### D. 소유권과 실행 게이트

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| D1 | ProviderAccount·Runtime owner 검사(setup, raw TOML, 부팅), Runtime 생성과 같은 append의 Self grant, `CanAdmin`에서 `ManageOwnProvider` 분리, ProviderLink의 membership·namespace 검사(로그인을 시작하는 `runtime_setup_login_session.ml:138` 포함). 1단계에서 Keeper를 만들면 만든 사람을 owner로 기록하고, Keeper에 배정할 수 있는 Runtime은 owner가 Self grant를 가진 것뿐이다(설계 §4.3의 1단계 문단). | §4.2~4.3, §5.4 | B3, C4-8 |
| D2 | `Runtime_view.t`와 abstract `Authorized_runtime.t`, `Runtime.authorize`. Codex와 Claude Code의 `run_turn`, 그 위의 Keeper 경로(`Keeper_codex_runtime`, `Keeper_claude_code_runtime`, `run_codex`·`run_claude` 갈래)가 `Authorized_runtime.t`를 요구하게 바꾼다. 직접 호출자(Fusion, verifier, capability probe)는 컴파일러가 모아 같이 바꾼다. 1단계의 Keeper 턴은 Keeper owner의 Self grant로 인가한다(executor = owner). 다른 사람의 Board 글이 Keeper를 깨워도 실행하는 쪽은 owner다. | §6.1 | A3, D1 |
| D3 | 나머지 실행 진입을 같은 타입으로 바꾼다. Antigravity와 Muse의 `run_turn`, 그 Keeper 래퍼(`Keeper_antigravity_runtime`, `Keeper_muse_runtime`)와 `run_antigravity`·`run_muse` 갈래, 그 밖의 호출자(verifier, Fusion, capability probe), 프로세스를 띄우는 조회(Codex `probe_metadata`의 호출자, Claude `probe_auth_status`, Muse `with_spawned_client`의 호출자). 첫 일은 §2에서 따라가지 못한 곳을 조사하는 것이다. 두 Runtime을 공유 대상으로 열지는 §6의 결정 4가 정한다. 1단계 개시 증거로 Keeper 실행 lane 종류(호스트 프로세스, container, microVM)마다 다른 owner의 account-home을 읽으려다 거절되는 시험을 하나씩 남긴다(설계 §11.1). 1단계에서 Antigravity·Muse Runtime은 공유하지 않는다. | §6.1 | D2 |
| D4 | API provider 실행 경로를 조사하고 같은 타입으로 바꾼다. | §6.1 | D2 |
| D5 | Delegated grant, MachineSharePolicy, DelegatePolicy, channel, 영속 작업의 initiator/executor 재검사. 자동 만료는 `Preauthorized_expiry(cause_event_id)`로 닫는다(§6.3). §6.2 판정이 `Purge_pending`을 거부 사유로 쓴다. `Purge_pending` initiator의 새 dispatch와 새 shard 쓰기를 거부한다. | §4.3~4.4, §6.2, §6.3, §8.5-1, §8.5-3 | D2, B3, B4 |
| D6 | Keeper 지속 상태(컨텍스트·기억·산출 글)에 initiator 표시를 붙이고, `Read_state`가 허용되지 않으면 initiator별 분리 컨텍스트로 돌린다. 파생 상태는 원천 initiator를 표시하고 읽는 쪽에 `Source_sealed`·`Source_purged`를 돌려준다. principal 삭제 연산은 `Delete` 사건과 같은 append로 표시된 몫을 `Purge_pending`에 올린다. 세부와 첫 일은 표 아래 D6 범위다. | §3-11, §6.2, §8.5 | D2, D5, B3, B4 |

**D1 범위** (구독 계정과 Runtime의 주인, 2026-11-08)

- 사용자 결정(2026-11-08).
  - D1을 C4-9~12보다 먼저 한다. D1이 C4에서 쓰는 것은 C4-8의 `Auth_gate`뿐이다. C4-9~12와 C6은 D층과 나란히 하거나 S1 직전에 한다.
  - 다계정에서 Runtime 배정이 없는 Keeper는 전역 default로 떨어지지 않는다. `NoAuthorizedRuntime`으로 거절한다. 남의 구독을 모르고 쓰는 길을 두지 않는다.
  - 구독 연결은 새로 만들지 않는다. 지금 있는 연결 경로에 주인을 붙이고, 그 경로를 localhost 미리보기에 달아 사람이 브라우저로 확인한다.
- 사용자 결정(2026-11-09). 다계정 Keeper 배정은 `authz.jsonl`의 Keeper 기록(`assigned` 사건)에 둔다. 사람의 Runtime은 `runtime.toml`에 없고 로그와 provider 템플릿에서 만들어진다(`Runtime_account_runtime.of_template`). 그래서 TOML에 배정을 쓰면 TOML이 선언하지 않은 Runtime을 가리킨다. `[runtime.assignments]`는 단일 사용자 전용이다.
- 지금 있는 것(main `ef87beded86`).
  - Runtime 층에는 주인이 없다. Runtime은 provider와 model의 binding이고 id는 `provider.model`이다(`Runtime_schema.binding_key`). 구독 계정은 `runtime.toml`의 `[providers.<id>]`와 그 `account-home`이다(`runtime_schema.mli:141`). Keeper 배정은 `[runtime.assignments]` 하나다. keeper TOML에는 runtime 키가 없다.
  - Runtime과 배정을 쓰는 경로는 모두 `CanAdmin`이다. HTTP는 setup·runtime config 경로들이다(`server_routes_http_routes_dashboard.ml`). MCP는 `masc_keeper_up`, HTTP keeper `/up`·`/config`다. CLI `runtime-setup-batch`·`runtime-default-set`·`config set`·`runtime-account-login`은 서버가 없으면 검사 없이 쓴다. raw `runtime.toml`은 부팅이 검사 없이 읽는다.
  - 구독 연결은 `POST /api/v1/setup/accounts/login`이 `Runtime_setup_login_session`으로 `codex login --device-auth`나 `claude auth login`을 띄우는 흐름이다(`server_setup_account_login.ml:138`). 세션은 legacy token의 agent 이름과 workspace 문자열로 가른다. membership·namespace 검사가 없다. account-home은 모두가 쓰는 `<base>/.masc/official-clients/<client>/<login_id>`다.
  - `lib/auth`에는 `Runtime_row`(owner, provider_account), `Runtime_grant`(`Self`, `Delegated`), `Effect.Manage_own_provider`가 있다. 부르는 곳은 시험뿐이다. Kind `Runtime_grant`는 `Authz_state`가 `Kind_not_read`로 거절한다. 구독 계정, Runtime, Keeper 주인을 담는 Kind는 없다.
  - Keeper의 Runtime을 고르는 곳은 70곳쯤이다(`Runtime.get_runtime_by_id` 38곳, `resolve_assignment` 23곳, `Keeper_meta_contract.runtime_id_of_meta` 22파일 39곳). 이것을 타입으로 묶는 일은 D2·D3이다.
- 결정.
  - 주인은 `authz.jsonl`에 둔다. 다계정 Keeper의 배정도 로그에 둔다(2026-11-09 결정). `runtime.toml`은 설정으로 남고, 다계정에서는 로그와 맞는지 검사한다. raw TOML은 작성자 없이 고칠 수 있다. 설계 §4.2는 raw 저장과 부팅 때 검사를 요구한다. 회수와 복원 판정(§8)은 로그 위에서만 선다.
  - provider 항목 하나가 ProviderAccount 하나다. binding 하나가 Runtime 하나다. Runtime의 주인은 그 provider의 ProviderAccount 주인과 같아야 한다(§4.2). 기록을 쓸 때와 상태에 넣을 때 둘 다 검사한다.
  - Runtime 기록 하나가 Self grant를 함께 싣는다. 구역의 커밋은 기록 하나라서(`Authz_zone`의 "One record"), 이것이 "Runtime 생성과 같은 append"(§4.3)를 지키는 길이다. Runtime 기록은 Self grant의 id를 든다. D2의 `Stored_grant of Grant_id.t`가 그 id를 쓴다.
  - Keeper 주인은 새 Kind `Keeper`로 쓴다. 만든 사람이 쓴다. 회수 대상이 아니라서 intent subject가 아니다.
  - account-home은 주인의 namespace 아래에 둔다. namespace는 입장 때 정한 `account_home_namespace`다.
  - `runtime.toml` 대조 함수는 `masc_runtime`에 둔다. `masc_runtime`은 `masc.auth`를 보지만 거꾸로는 못 본다.
- 층.
  - D1-1 기록. Kind `Provider_account`, `Runtime`(Self grant 포함), `Keeper`의 본문과 작성자다. 작성자는 주인 본인이다. `Authz_state`가 셋을 읽는다. Runtime 주인과 구독 계정 주인이 다르면 상태가 거절한다.
  - D1-2 대조. `runtime.toml`의 provider와 binding을 하나씩 기록과 맞춘다. 다계정에서 `[runtime.assignments]`가 로그의 Keeper를 가리키면 거절한다. 배정은 로그에 있다. lane이면 모든 구성원이 Keeper 주인의 것이어야 한다. 배정이 없으면 default로 가지 않고 거절한다. Single_user는 이 함수를 부르지 않는다.
  - D1-3 `ManageOwnProvider`. 구독 연결 경로를 위한 `Route_access` 종류다. Single_user는 지금처럼 `CanAdmin`으로 판정한다. 다계정 `Auth_gate`는 활동 중인 Member와 Admin 본인에게 연다. PAT는 범위에 `Manage_own_provider`가 있어야 한다.
  - D1-4 구독 연결(ProviderLink, §5.4). 세션 키를 legacy 이름에서 principal로 바꾼다. 시작, 상태, 코드 입력, 취소마다 저장소의 membership과 namespace를 대조한다. account-home을 namespace 아래에 만든다. 연결이 끝나면 `Provider_account`와 `Runtime` 기록을 쓴다.
  - D1-5 Keeper 만들기와 배정. 다계정에서 Keeper를 만들면 `Keeper` 기록(`made`)을 쓴다. 배정은 같은 종류의 `assigned` 기록이고, 주인의 Runtime만 받는다. 미리보기에 "My Keepers"(만들기, 배정, 목록)를 달아 사람이 브라우저로 확인한다. Keeper TOML 쓰기와 턴 실행은 S1과 D2다.
  - D1-6 미리보기 연결. 미리보기에 D1-4의 구독 연결 경로와 "내 구독과 Runtime" 목록을 단다. 사람이 브라우저에서 자기 Claude Code나 Codex 구독으로 로그인한다. 그러면 자기 namespace의 account-home과 자기 기록이 생긴다. 사람이 한 확인을 PR 본문에 적는다.
- 시험(설계 §12 소유권).
  - A가 B의 provider id로 Runtime을 만들면 거절한다. Admin도 남의 구독으로 Runtime을 만들지 못한다.
  - 남의 Runtime을 Keeper에 배정하면 거절한다. lane에 남의 Runtime이 섞여도 거절한다. 배정 없는 Keeper는 default로 가지 않는다.
  - 남의 구독 연결 세션의 상태, 코드 입력, 취소를 거절한다.
  - 일반 Member가 Admin 없이 자기 구독을 연결한다.
- 하지 않는 것: 실행 진입의 타입(D2·D3), 공유(Delegated·MachineShared, 2단계), lane별 account-home 격리 증거(D3), 부팅에 대조를 다는 일(S1).

**D2 범위** (Keeper 턴 인가, 2026-11-09)

- 사용자 결정(2026-11-09). 조건은 "휴리스틱 구현이나 SSOT 위반이 아니어야 하고, 명시적이고 선명해야 한다"이다.
  - `run_turn`까지 타입으로 막는다. `Runtime.authorize`가 준 값이 있어야 Codex와 Claude Code의 `run_turn`이 돌고, account-home은 그 값에서만 나온다.
  - 판정은 `Authz_decision.allowed`(A3) 위에 세운다. 새로 쓰는 것은 로그 상태를 `facts`로 옮기는 adapter뿐이다. 검사를 새로 쓰지 않는다.
  - Keeper 턴의 initiator와 executor는 둘 다 Keeper 주인이다. Board 글을 쓴 사람은 턴의 입력이지 당사자가 아니다.
  - 채널 정책은 Keeper `made` 기록에 둔다. 기록은 policy id와 범위(`turn_scope`)를 적고, adapter가 그것을 주인→주인 `Delegate_policy`로 넘긴다.
  - Self grant의 효과는 Runtime `made` 기록에 둔다(`self_effects`). verify가 만드는 Runtime은 `read_state`, `invoke_model`, `use_tool`을 허용한다.
  - Keeper 턴의 `auth_binding`은 그 Keeper 기록이다. 기록이 있고 그 주인이 initiator일 때만 `Active`다.
  - verify는 Runtime 기록 전에 모델을 부르므로 `Stored_grant`가 없다. 설계 §6.1의 `Authorization_basis`에 "자기 구독 계정 확인" 근거를 하나 더한다.
- 왜: A3 판정은 요청(세션, PAT)을 위해 설계됐다. 자율 턴, Board 턴, 예약 턴에는 정책, binding, Self 효과가 비어 있었다. 빈칸을 코드 기본값으로 채우면 휴리스틱이 된다. 그래서 빈칸을 모두 로그의 데이터로 채운다.
- 근본 원인(2026-11-09 사용자 요청 "근본 작업 개선은?"). 실행 테이블이 자격 증명을 나눠 준다. `Runtime.get_runtime_by_id`가 돌려주는 `Runtime_instance.t`의 `execution.account_home`에는 부팅 때 잡은(capture) 계정 홈과 그 환경이 들어 있다. id 문자열만 알면 어떤 코드든 그 계정으로 공식 CLI를 띄운다. 이 필드를 읽어 CLI를 띄우는 곳이 `run_turn` 8곳과 그 밖의 조회 10곳쯤이다. 증명을 호출처마다 나르는 것은 N-of-M 패치다.
- 설계(2026-11-09 사용자 승인).
  - `Runtime_account_access` 모듈 하나가 봉인, 인가, 권한 게시를 맡는다. 클라이언트보다 아래 층(lib/runtime)에 있어서 Codex와 Claude Code 클라이언트가 그 타입을 받는다. `Runtime_authority`라는 이름은 쓰지 않는다. `Sse.runtime_authority`가 이미 작업 공간 경로의 신원이라는 다른 뜻으로 쓰인다.
  - 테이블은 봉인된 계정(`'client sealed`)만 든다. 봉인된 값은 환경을 내주지 않는다. 홈 경로는 식별(quota 창, 다시 읽기 비교)에만 읽는다.
  - 인가된 계정(`'client authorized`)은 `authorize`만 만든다. 생성자를 공개하지 않는다. 근거(`basis`: `Stored_grant of Grant_id.t`, `Single_user_operator`, `Own_account_check of Provider_account_id.t`)는 아직 두지 않는다. 읽는 곳이 없다. 근거를 lease record에 적는 E1에서 더한다.
  - 프로세스 권한은 한 번 게시한다(`publish`). 모드는 부팅 때 정해지고 바뀌지 않는다(설계 §6.1). 서버와 stdio 서버는 owner state를 열 때(`initialize_owner_state_blocking`) 부팅 판정의 `single_user`를 게시한다. 두 서버가 판정을 넘기는 곳이 여기 하나다. CLI는 자기 호출처를 바꾸는 층(D2-4~D2-6)에서 `tool` 판정 뒤에 게시한다(`publish_host_tool`). 미리보기는 구역을 연 뒤 구역과 base path를 게시한다(D2-4). 두 번째 게시는 거절한다. 게시 전의 `authorize`는 거절한다. `Runtime.init_default`가 게시를 맡지 않는 까닭은 시험 호출 247곳(108파일)과 설정만 읽는 CLI까지 판정을 요구하게 되기 때문이다.
  - host CLI(bin)는 서버처럼 로그를 열면 안 된다. 서버가 쓰는 중인 로그의 끝나지 않은 줄을 자르기 때문이다. 그래서 CLI의 판정(`Authz_boot_mode_read.tool`)은 파일이 있는지만 본다. 로그, 설치 기록, 외부 저장소 중 하나라도 있으면 거절한다. 없을 때만 같은 판정 규칙에 "로그 없음, 저장소 없음"을 넣어 묻는다.
  - 단일 사용자의 `authorize`는 요청을 가리지 않고 봉인된 계정을 그대로 준다. 지금 동작과 같다.
  - 다계정의 `authorize`는 요청(`request`)에 따라 판정한다. 요청은 `Keeper_turn {keeper_name; channel; runtime_id}`, `Own_account {user_id; provider_account_id}`, `Operator_call`이다. Keeper 턴은 `Authz_keeper_turn.decide`가 정하고, 배정된 Runtime이 아니면 거절한다. 자기 계정은 로그에 활성 principal과 membership이 있어야 한다. 둘 다 CLI를 띄울 홈을 그 사람(Keeper 턴이면 주인)의 namespace와 구독 계정 id로 만든 홈과 철자까지 비교한다. 선언된 홈이 아니면(상속된 홈은 프로세스 환경의 자격 증명을 든다) 거절한다. 홈 경로는 `Runtime_account_home_layout` 하나가 만들고 login·verify·authorize가 같이 쓴다. Claude는 keychain 항목을 그 경로 철자로 가른다. 그 밖의 목적(Fusion, capability probe, dashboard probe, librarian, vision)은 `Operator_call`이고 다계정에서 거절한다. D5·S1이 연다.
  - 자기 계정 확인은 로그의 구독 계정 기록을 요구하지 않는다. 로그인 확인(`observe`)은 계정을 로그에 연결(`link`)하기 전에 돌기 때문이다. 홈이 그 사람의 namespace 아래 있으면 그 사람 것이다. namespace는 한 사람에게만 주어진다.
  - CLI를 띄우는 클라이언트 함수(Claude Code `run_turn`·`probe_subscription`, Codex `run_turn`·`probe_subscription`·`list_models`·`read_rate_limits`·`delete_threads`)가 모두 `authorized`를 받는다. `validate_turn`은 CLI를 띄우지 않으므로 받지 않는다. client `config`에는 계정 칸이 없다. login은 계정을 만드는 흐름이라 따로 둔다(`login_environment`).
- 층.
  - D2-0 기록. Runtime 본문에 `self_effects`를, Keeper 본문에 `policy_id`와 `turn_scope`를 더한다. 두 본문은 미리보기에서만 쓰였으므로 hard cut이다. 미리보기 Keeper는 `autonomous`와 `direct` 채널을 허용하는 정책으로 만든다. Runtime과 효과는 배정과 Self grant가 제한한다.
  - D2-1 adapter. 한 snapshot에서 Keeper 턴의 `facts`를 만든다. 배정이 없으면 `NoAuthorizedRuntime`이다. 1단계에는 Runtime과 ProviderAccount의 상태 기록이 없어서 둘 다 `Active`다. 회수는 구역의 게이트 값(`revocation_pending`)이다. 의존은 `Cleared`다. 1단계에는 복원 창이 없고(F2는 2단계), A2가 복원된 로그를 거절한다.
  - D2-2 CLI 판정 `Authz_boot_mode_read.tool`.
  - D2-3 `Runtime_account_access`(봉인, 인가, 게시)와 게시 지점(owner state). 단일 사용자만 연다.
  - D2-4 다계정 인가(Keeper 턴, 자기 계정)와 홈 경로 하나(`Runtime_account_home_layout`). 미리보기가 `Multi_account`를 게시한다. 로그인 확인과 verify가 요청을 넘긴다(단일 사용자 setup은 `Operator_call`, 사람은 `Own_account`). `runtime-verify`와 setup의 모델 확인은 검증을 시작하는 함수(`verify_runtime_execution`) 한 곳에서 `tool` 판정 뒤 게시한다. 처음에는 `runtime-verify`만 게시해서 setup의 확인이 공식 CLI 런타임에서 늘 `Not_published`로 끝났다(#50421 리뷰). 클라이언트가 아직 config로 계정을 받으므로 인가된 계정을 그 칸에 넣는다(D2-5·D2-6에서 지운다). 2026-11-09 순서를 바꿨다. 클라이언트를 먼저 바꾸면 미리보기가 게시하지 않아 사람의 로그인 확인과 verify가 중간 층에서 멈춘다.
  - D2-5 Claude Code 클라이언트가 `authorized`를 받는다. 호출처(Keeper 갈래, Fusion, capability probe, verify, dashboard probe, CLI probe, login)를 같이 바꾼다. Keeper 턴 드라이버는 시도마다 인가를 받는다.
    - client `config`에 계정 칸이 없다. CLI를 띄우는 함수(`run_turn`, `probe_subscription`)가 인가된 계정을 받고, 환경은 그 값에서만 나온다. 부를 때 환경을 고르던 선택은 Claude Code에 없다. login은 `login_environment ~account_home`으로 홈을 받는다.
    - 드라이버의 `walk_owner`가 누구의 턴인지 든다. `Fleet_keeper_turn {keeper_name; channel}`은 `Keeper_turn`, `One_shot_walk`(완료 리뷰 등)는 `Operator_call`로 묻는다. 실패 표시의 recorder는 Keeper 이름에서 만든다(`keeper_recorder`). 같은 값을 두 번 들지 않는다.
    - 채널은 `Turn_record.turn_kind`에서 온다. Keeper에게 온 메시지(`handle_keeper_msg`)는 `Direct`, 나머지 턴은 `Autonomous`다. 런타임이 그 밖의 종류를 가르지 않는다.
    - 드라이버가 거절하면 그 시도는 `Agent_core.Error.Config (InvalidConfig {field = "account"})`로 끝난다. `provider_config_transform` 거절과 같은 모양이다. 분류는 `Config_mismatch`라서 다른 후보로 넘기지 않고, 공급자 증거(실패 표시, 계정 거절)를 남기지 않는다. 다계정에서는 배정된 Runtime 하나만 허용되므로 넘겨도 다른 후보는 거절된다.
    - Fusion 패널, capability probe, dashboard probe, `masc runtime-probe`는 `Operator_call`이다. 거절은 각자 이미 있는 "프로세스를 띄우지 않음" 결과로 낸다(Fusion `Setup_failure`, capability probe `Account_not_authorized`, `runtime-probe`는 `account-not-authorized`와 종료 코드 5). dashboard probe의 로그인 상태는 대시보드가 닫힌 목록으로 읽으므로 `invalid_config`에 거절 이유를 붙인다. 단일 사용자 서버는 owner state를 열 때 게시하고 모든 요청을 허용하므로 거기서는 거절이 나오지 않는다.
    - 서버 밖에서 CLI를 띄우는 bin은 base path를 정한 뒤 `publish_host_tool`로 게시한다: `masc runtime-probe`, `masc-fusion-run`, `masc-lane-cli-probe`, `masc-keeper-capability-probe`, `masc-librarian-continuity`. 시험 실행 파일은 `Masc_test_deps.publish_single_user_access`로 게시한다.
  - D2-6 Codex 클라이언트가 같은 일을 한다.
    - client `config`에 계정 칸이 없다. app-server를 띄우는 함수 다섯 개(`run_turn`, `probe_subscription`, `list_models`, `read_rate_limits`, `delete_threads`)가 인가된 계정을 받는다. 호출할 때 계정을 고르던 선택(`Current`)은 Codex에서도 없어졌다. login은 `login_environment ~account_home`으로 홈을 받는다.
    - verify와 모델 목록 갱신의 private home은 인가된 계정의 환경에 CODEX_HOME만 private home으로 바꾼 것이다(`Runtime_official_account.private_codex_environment`). 계정 홈의 연결 설정은 그 계정 값에서 복사한다.
    - 드라이버는 Claude Code 시도와 같은 요청으로 Codex 시도마다 인가를 받는다. Codex Keeper 런타임은 턴, 스레드 지우기, 쿼터 소진 뒤 사용량 읽기, 도구 표면 해시, 쿼터 창을 모두 그 계정 값에서 읽는다.
    - 운영자 호출: Fusion 패널, capability probe, dashboard probe, `masc runtime-probe`, 서버 시작 때의 사용량 읽기, 모델 목록 갱신. 거절은 각자 이미 있는 결과로 낸다. 사용량 읽기는 읽기 실패로 로그에 남는다.
    - `masc runtime-codex-models`는 base path를 받지 않았다. 다른 host tool처럼 작업 공간을 정하고(`--base-path`, 환경 변수, 현재 디렉터리) 게시한다. 다계정 작업 공간이거나 거절되면 종료 코드 1로 끝나고, setup은 이것을 이미 "갱신 불가"로 읽는다. 서버의 setup 동작과 설치 wizard가 base path를 넘긴다.
  - D2-7 테이블이 봉인을 든다(`Runtime_execution`). 호출처는 테이블의 자격 증명을 더 꺼내지 못한다.
  - D2-8 미리보기 "내 Keeper 한 번 돌리기". 사람이 브라우저로 확인한다. 2026-11-09 D2-6·D2-7보다 먼저 했다. Claude Code는 D2-5부터 인가된 계정으로만 뜨므로, Codex를 기다리지 않고 사람의 구독으로 Keeper 턴이 도는지 먼저 확인할 수 있다.
    - 라우트는 `POST /api/v1/auth/keepers/turn`이다. 본문은 `{"keeper_id","message"}`이고 메시지는 4096바이트까지다. 게이트는 `Manage_own_keeper`에 membership을 더한다(`Auth_preview.keeper_owner_person`). 턴이 그 사람 namespace 아래 홈에서 CLI를 띄우기 때문이다.
    - 라우트는 기록만 읽는다. Keeper 기록이 Runtime을, Runtime 기록이 계정을 정한다. 런타임은 그 계정의 login receipt가 이름 붙인 workspace provider에 그 계정 홈과 binding 하나를 얹은 것이다(`Server_setup_account_login.person_runtime`). binding은 이 계정에서 만드는 Runtime id가 Keeper 기록의 id와 같은 것이다(`Runtime_account_runtime.Runtime`). id를 자르지 않고 binding마다 만든 id와 통째로 비교한다.
    - 판정은 `authorize (Keeper_turn {channel = Direct; ...})` 하나다. 로그로 판정하고, 인가된 계정만 CLI를 띄운다. 남의 Keeper는 다른 Keeper 라우트처럼 404다.
    - 한 계정에서는 한 호출만 돈다(`Server_setup_account_login.one_call_of`). verify와 턴이 같은 잠금을 쓴다. 한 홈의 자격 증명을 두 CLI가 동시에 갱신하지 않게 하기 위해서다. 다른 계정의 호출은 기다리지 않는다.
    - CLI는 `default_config`의 자세로 뜬다. 턴은 로그에 기록을 남기지 않는다.
      - Claude Code: 내장 도구는 deferred tool 조회(`--tools ToolSearch`)뿐이고 MASC의 MCP 서버는 없다.
      - Codex(D2-6b): `Ephemeral` 스레드로 돈다. Codex는 그 스레드의 rollout도 기록도 남기지 않는다. 자세는 Codex 기본값 `Native_read`다(권한 `:read-only`, shell 꺼짐). Codex에는 `Native_none`이 없다. MASC 도구는 넘기지 않는다.
      - 실패 답은 두 클라이언트가 같은 문장을 쓴다. Codex는 구독 소진을 턴 실패로 보내므로(`refused_for_spent_usage`) 실패 종류보다 먼저 보고 429로 답한다.
  - 하지 않는 것: 다계정 Keeper 턴의 후보를 로그의 배정에서 고르는 드라이버 쪽 일(S1 전), Antigravity·Muse(D3), API provider(D4).

**D6 범위**

- 사람 initiator가 없는 dispatch(autonomous, system)가 만든 상태는 `Service(system)` 표시를 달고 `Read_state`가 허용된 initiator에게만 보인다(§3-11).
- 봉인은 읽을 때 원천 initiator의 현재 상태로 판정한다. 봉인 표시를 저장하지 않는다. 저장하면 initiator가 Active로 돌아와도 풀리지 않는다(§3-11).
- 표시를 붙이면 저장 형식이 바뀐다. 기존 상태를 어떻게 할지는 §6의 결정 5가 정한다.
- 첫 일은 조사이고 산출물은 표다. 칸은 다섯이다. ① 파생 상태를 만드는 자리(요약, 병합된 기억 등) ② 내용 주소로 공유되는 blob과 artifact ③ 이미 퍼진 복사본(산출 글, artifact 게시본, checkpoint, 백업, 로그와 trace) ④ 쓰기 경로의 미러와 이중 저장 ⑤ initiator 표시를 붙일 수 있는 키가 저장소에 있는지. 표시를 붙일 수 없는 저장소가 나오면 D6을 쪼개거나 이 계획을 고친 뒤 시작한다.

### S. 1단계 개시

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| S1 | 부팅이 `Multi_account_not_served` 거부를 거두고 다계정 로그를 서빙한다. 활성화 전 요청(§5.1 표 5행)의 거부는 남는다(B3d). `masc auth bootstrap`의 도움말·성공 문구와 5행 부팅 문구(`Activation_requested`)에서 서버가 부팅을 멈춘다는 문장을 고친다. 지워서 되돌리는 문장(`single_user_again`)은 지우고 F3a의 `off`를 안내한다. 부팅이 구역(`Authz_zone.open_at_start`)을 열어 쥐고, 그 구역을 C2a~C4의 다계정 경로와 D1~D4의 실행 게이트에 넘긴다. C3의 로그인 경로를 `make_routes`에 달고, 같은 경로의 HTTP/2 갈래를 `server_h2_gateway.ml`에 더한다(HTTP/2는 router의 `dispatch`를 거치지 않아 갈래가 없으면 404다). 설치 기록이 없거나 로그가 없거나 비었을 때 구역의 열기가 무엇을 돌려줄지, `Multi_account_uncertain`에서 무엇을 서빙할지 이 층이 정한다. 설계 §11.1의 1단계 개시 증거를 이 층에서 모은다. | §5.1, §8.2, §11.1 | B3, C4, C6, D4, F3a |

- S1이 1단계의 맨 끝인 까닭: 계정 층 없이 부팅하면 여러 사람이 소유한 기록을 한 사용자처럼 서빙하기 때문에 이 거부가 있다(`Authz_boot_mode_read`). 그 계정 층의 마지막이 D4다. D1이 소유권을, D2~D4가 실행 진입마다 인가를 검사하고, D3이 lane마다 다른 owner의 account-home을 읽지 못하는 증거를 남긴다. 그 전에 거부를 거두면 C4를 통과한 사용자가 다른 사람의 Runtime과 Keeper를 쓴다.
- S1이 F3a 뒤인 까닭: S1부터 다계정 설치는 계정이 가진 Runtime·Keeper 기록을 쌓는다. 그때 "지우고 설치"는 그 기록을 지운다. 끄는 길 없이 켜는 길만 열면 실제 설치가 되돌릴 수 없이 다계정으로 넘어간다(§6 결정 10).
- S1 전에는 다계정 설치로 서버가 뜨지 않는다. C2a~D4의 코드는 시험이 구역을 직접 열어 부르고, 실제 서버에서 로그인부터 Keeper 실행까지 잇는 확인은 S1에서 처음 한다.

### E. official client 격리

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| E1 | `Lease_state`와 `with_lease` 출구 규칙(§7.1), `consume` 한 번, 재기동 규칙, attempt 종단 셋(`Failed(Outcome_unknown)`, `Failed(Not_started)`, `Cancelled_before_effect`, §9-5), lease 계열 group commit. group commit은 B2의 writer lock 구역(`Intent_pending`부터 `Committed`까지) 동안 끼지 않는다(§8.2-1). 메모리는 이력이 아니라 상태에 묶는다. lease는 자원별 단조 카운터라서(§7.1) 고수위와 열린 lease만 들고 있어도 종단 뒤의 두 번째 `consume`을 판정한다. 시간 기준 가지치기는 두지 않고, 상태는 줄 순서만의 함수다. 증가량(줄/일)과 기동 replay 시간은 Keeper 300 부하에서 잰다(§6의 결정 6). 위험 9의 결정(§7, `Single_user`의 lease record 위치)이 없으면 E1은 시작하지 않는다. | §7.1, §8.2-1, §9-3~9-5 | B1, D2 |
| E2 | account-home single-flight, 점유 영속, 단일 FIFO, owner·Admin의 `Executor_teardown`, `account_busy`. mount와 spawn은 `Lease_dispatched` 기록 뒤에만 하고, 실행 전 실패와 `Effect_cancel`은 종단 기록(`Completed(Not_started)`)을 남긴다(§7.2). 효과가 나간 dispatch의 `Completed(Effected)`는 E1의 출구 규칙이 기록한다. | §7.2, §9.1~9.2 | E1 |
| E3 | credential/state 분리, lane 증명(저장소 종류와 `state_separation` 포함), attestation. | §5.4-6, §7.2, §9 | E2 |
| E4 | dispatch 전용 MCP credential. | §7.3 | E1 |

### F. 삭제·복원·준비

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| F1 | purge 삭제 실행기. 삭제는 대상에 쓸 수 있는 dispatch가 모두 종단에 이른 뒤에 시작하고, 종료를 확인하지 못하면 `Purge_failed {Writer_not_terminated}`로 끝낸다. 진행 중인 dispatch는 지정이 올리는 epoch가 회수하고(E1의 `Revoked(Grant_revoked)`) E2의 `Executor_teardown`이 끊는다. F1은 종료 확인만 기다린다. 대상 표시가 붙은 shard·transcript·credential을 writer lock 밖에서 ID 단위로 멱등하게 지우고, 남은 대상이 0이면 `Purged`를 append한다. 재기동 때 남은 `Purge_pending`을 이어서 지운다. `Purge_failed`는 Dashboard와 `/health`에 보인다. | §8.5, §10.4 | B4, D5, D6, E3 |
| F2 | 복원·전이 분류와 전이 창의 규칙. 복원 창, `Recovery_manifest`, `restore_disposition`(`Pending`, `Denied`, `Cleared`, `Quarantined`, `Purged`), `Integrity_carry_forward` 계승, 적격 Admin 규칙. 복원본에서 되살아난 principal 레코드를 ledger의 `Delete` 기록과 먼저 대조하고, 컨텍스트 shard와 파생 상태를 분류한다(분류 전 읽기는 `AuthorizationUncertain`). 세부는 표 아래 F2 범위다. | §10.1~10.5 | B2, B3, D5, F1 |
| F3a | 1단계의 모드 끄기(on→off). 세부는 표 아래 F3a 범위다. | §10.5 | B3, D4 |
| F3b | 다시 켜기(`reactivate`), lease가 있는 설치의 끄기, 새 명령 `masc auth recovery`. 세부는 표 아래 F3b 범위다. | §10.5 | E1, F2, F3a |
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

**F3a 범위**

- 1단계의 끄기다(§6 결정 10). bootstrap처럼 서버가 없을 때 BasePath lease를 쥐고 `off` 사건을 쓴다. 서버가 멈추면 진행 중이던 Keeper 턴도 끝나므로, 끄는 순간 진행 중인 다계정 실행이 없다. 그래서 §9-5의 lease 종결은 이 층에 없다. 1단계에는 lease 저장소가 없다(E1).
- `off` 뒤 설정이 `Single_user`이면 multi-owned record를 읽기 전용으로 둔 `Single_user`로 부팅한다(4행). legacy 공유 token·admin으로 multi-owned record를 실행하지 않는다. 남은 account-home 점유는 `Release_pending`으로 바꾸고 unmount를 확인한 뒤에만 Released로 한다. 설정이 `Multi_account`이면 `reactivate` 요청이고, F3b 전에는 `Reactivation_not_ready`로 거부한다(9행).
- 시험은 `off`가 있는 4·10행과, F3b 전의 9행 거부를 본다.

**F3b 범위**

- `off`와 `reactivate`는 모드 사건(종류 `Mode_event`)으로 `authz.jsonl`과 외부 저장소에 남는다. `off`의 작성자는 F3a가, `reactivate`의 작성자는 이 층이 정한다. 작성자 검사는 레코드 종류 단위라서, `Local_operator`가 아닌 작성자가 필요하면 이 층이 종류를 더한다(`Authz_record.admits`가 컴파일을 멈춘다). A2의 부팅 판정이 마지막 모드 사건이 만든 모드를 읽는다. `off` 뒤 설정이 `Single_user`이면 multi-owned record를 읽기 전용으로 둔 `Single_user`로 부팅하고, 설정이 `Multi_account`이면 `reactivate` 요청이다. `reactivate`는 §10.5의 `Recovery_manifest`와 `Pending` 절차가 있어야 하고, 그 절차가 없으면 `Reactivation_not_ready`로 거부한다. 절차를 마치면 `reactivate` 사건을 `authz.jsonl`과 외부 저장소에 남긴다.
- lease가 있는 설치(E1 뒤)의 on→off 전환은 서버가 떠 있는 채로도 받는다. multi-owned record를 읽기 전용으로 보존하고 legacy 공유 token·admin으로 실행하지 않는다. 진행 중인 multi dispatch는 §9-5에 따라 종결하고 session은 닫는다. account-home 점유는 `Release_pending`으로 바꿔 unmount를 확인한 뒤에만 Released로 한다. 다시 켜면 같은 `Recovery_manifest`와 `Pending` 절차를 거친다.
- `masc auth recovery --base-path <path>`는 인증 가능한 Admin이 0명이거나 IdP를 쓸 수 없을 때 연다. 호스트 관리자와 root 소유 일회용 recovery 파일이 필요하다. 실행자·사유·시각·결과·파일 digest·파기 결과를 append-only audit와 Board에 남긴다. 원격 break-glass는 없고 활성화 전에 리허설한다. 이 경로에서 Local_operator는 `Admin_assignment`를 새로 발급할 수 있고, 발급받은 principal의 grant와 `Cleared`에는 관여하지 않는다.

## 4. 순서와 첫 마일스톤

- A2, B3, B4를 뺀 A, B, C1은 서로 거의 독립이라 병렬 스택으로 쌓을 수 있다. 나머지 순서는 층 표의 선행 열을 따른다.
- D2와 D3은 `Single_user`에서 동작을 바꾸지 않도록 `Runtime.authorize`가 모드에 따라 근거를 달리 발급해야 한다. 설계 §6.1이 이 점을 정한다. 이 근거가 없으면 D2는 시작하지 않는다.
- 1단계 개시 조건은 설계 §11.1이다. 백업 복원은 A2의 부팅 판정이 거부하거나 `AuthorizationUncertain`으로 시작한다. 복원 뒤 이어 쓰는 절차(F2)와 복구 리허설, official lane attestation(E3)은 2단계이고, 2단계 층이 들어오면 그 층의 증거가 설계 §11의 요구 목록에 다시 들어간다.
- 1단계(2026-11-04 사용자 결정, §6 결정 9). 순서는 A2 → B3 → B2e → C2a → C2b → C2d → C3 → A4d 뒷부분 → C4 → C6 → D1 → D2 → D3 → D4 → F3a → S1이다(S1은 2026-11-05, F3a는 2026-11-08 사용자 결정). 이 층이 들어오고 설계 §11.1의 증거가 모이면, 초대한 사람이 Google이나 GitHub으로 로그인해 자기 Runtime으로 자기 Keeper를 쓴다. `Single_user` 동작은 층마다 그대로다. B2e(`Revocation_pending` 게이트)가 1단계에 드는 까닭은 1단계에도 Admin의 사용자 `Disable`과 초대 취소 같은 회수가 있어서다. 회수 기록이 중간에 끊기면 실행을 막아야 한다(설계 §3-5).
- 2단계는 B4, C2c, C5, D5, D6, E1~E4, F1, F2, F3b, F4, F5다. Runtime 공유(Delegated·MachineShared), 입장 요청, MCP OAuth 결속, purge, 복원 창, 다시 켜기를 맡는다. 1단계를 실제로 쓴 뒤 연다.
- C6은 C2의 로그인 경로와 C3의 세션·CSRF만 쓰고 `Auth_gate.decide`(C4)를 호출하지 않는다. 그래서 C4와 C6은 서로의 선행이 아니고, 둘 다 C3 뒤에 어느 쪽을 먼저 열어도 된다. 다만 다계정을 켜려면 C4가 필요하다(설계 §11 readiness의 `legacy_workspace_secret_callers=[]`·`agent_credential_callers=[]`가 C4 몫이다). 화면만 먼저 병합돼도 다계정은 켜지지 않는다.
- C6 ①의 "거부"는 HTTP 401이다. 현재 `server_auth.ml`의 strict 경로는 자격이 없는 요청을 `Missing_token` 등으로 거절하고 `www-authenticate: Bearer`를 붙인다(`http_status_of_auth_error`, `auth_error_headers`). HTTP strict는 `MASC_HTTP_AUTH_STRICT`가 켜져 있거나, 비 loopback으로 바인드하거나, `MASC_HTTP_BASE_URL`이 비 loopback 주소일 때 켜진다. A2가 `Multi_account`에서 `enabled=false`, `require_token=false`, `MASC_ALLOW_ANONYMOUS_MUTATIONS=true`를 부팅 때 거부해도 strict가 항상 켜지는 것은 아니다. `with_public_read`는 strict에서도 `is_public_read_path`의 공개 경로를 열고, strict가 꺼진 loopback에서는 다른 읽기에도 인증 검사를 하지 않는다. 자격 없는 요청의 401 여부는 경로와 C3·C4의 구현에 따라 확인한다. Dashboard의 기존 401 처리(`dashboard/src/api/core.ts`의 `reportRejectedCredential`)는 bearer를 보낸 요청에만 반응하므로, 자격 없는 요청이 401을 받으면 로그인으로 이동하는 부분은 C6이 새로 만든다. C4가 들어오기 전 C6의 상태 전이 시험은 서버 fixture 응답으로 하고, 실제 서버의 Reject 경로와 엮은 증거는 C4 뒤에 만든다.
- readiness 증거는 층이 만든다. 각 층의 PR 본문이 자기 증거를 적고, F5는 그 증거를 모아 표면 digest에 결속하는 실행기만 만든다.

| 설계 §11 readiness 증거 | 만드는 층 |
|---|---|
| route inventory | A1, A4a |
| `auth disabled`·`require_token=false` 부팅 거부 | A2 |
| 경로별 Reject·CSRF·credential 단일성 | A4d, C3, C4 |
| `legacy_workspace_secret_callers=[]`, `agent_credential_callers=[]` | C4 |
| C5 전의 `Mcp_oauth_token` Reject | C4 |
| string만으로 실행 객체를 얻는 경로의 잔존 0 | D2, D3, D4 |
| Provider 두 계정 호출과 제3자 거부 | D1, D5 |
| official lane 격리 | E3 |
| 복구 리허설 | F2, F3b |
| Single_flight 대기 시간(§11-6) | E2 |

계획이 더하는 증거가 셋 있다. 필드가 없는 기존 설정으로 업그레이드한 뒤에도 `Single_user`로 부팅된다(A2), 과거 epoch의 `Cleared`가 실행되지 않는다(F2), 최초 활성화 때 미분류가 0이다(F4)다. 셋 다 F5의 묶음에 넣는다.

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
2. **외부 고수위 저장소의 위치.** 설치 기록에 적는다(사용자 결정, 2026-10-28). `$XDG_CONFIG_HOME/masc/`(없으면 `~/.config/masc/`) 아래에 base path 단위로 기록 파일을 두고 외부 저장소의 경로를 적는다. `default-base-path`가 이미 같은 디렉터리를 쓴다. `config.json`이나 base path를 잃어도 기록이 남아서 §7 위험 2의 셋째 구멍이 좁아진다. 기록을 읽고 쓰는 코드와 쓰는 방식은 B2가 만든다(B2 범위).
3. **경로별 인증 처리.** 등록할 때 타입으로 적는다(2026-10-28 사용자 결정). 설계는 `docs/rfc/RFC-typed-route-auth.md`이고, 층은 A4a~A4d다.
4. **Antigravity·Muse Runtime의 공유.** 설계는 이 둘을 다루지 않는다. 설계 §3-10은 증명 없는 공유를 거부하므로, 공유 대상으로 열려면 §7.2 같은 lane 증명이 필요하다. D3이 두 Runtime의 credential 위치를 조사한 뒤, 공유를 거부로 둘지 설계를 넓힐지 사용자에게 묻는다.
5. **이전 형식 데이터.** 저장소 규칙은 호환 reader 없이 `Fresh state required`인데, 설계에는 이전 형식 데이터를 읽는 규칙이 있다. D6가 Keeper 상태에 initiator 표시를 붙이면 기존 컨텍스트·기억·산출 글이 표시 없는 상태가 되고, 설계 §10.5는 표시 없는 Keeper 상태를 읽을 수 있는지 정하지 않는다. `cause`가 없는 기존 Block을 `Security_incident`로 보는 규칙(§10.4-1)도 같은 문제다. 저장소 규칙대로면 D6 배포 때 기존 Keeper 상태를 따로 보관하고 새로 시작한다. D6의 조사 표가 나온 뒤와 F2를 시작할 때 사용자에게 묻는다.
6. **기동 replay 시간 상한과 checkpoint.** 기동 때 `authz.jsonl`의 체인 해시를 줄 수에 비례해 다시 검증한다. 줄이 늘어나는 속도는 아직 재지 않았다. E1이 Keeper 300 부하에서 증가량과 기동 replay 시간을 잰 뒤, 상한과 checkpoint 도입 여부를 사용자에게 묻는다.
7. **C6.** 1단계에 넣는다(결정 9). C2a·C2b·C2d·C3 뒤에 연다.
8. **GitHub 로그인.** Google과 함께 GitHub 로그인을 받는다(2026-11-04 사용자). 신원 키는 `External_identity.t = Google of {sub} | Github of {user_id}`이고 B3이 만든다. GitHub 사용자 로그인은 OIDC가 아니라서 ID token이 없고 C2b가 따로 낸다. github.com의 OAuth App과 GitHub App은 2025-07-14부터 PKCE(S256)를 받는다([GitHub changelog](https://github.blog/changelog/2025-07-14-pkce-support-for-oauth-and-github-app-authentication/), 2026-11-04 확인). GitHub Enterprise Server는 대상이 아니다.
9. **1단계와 2단계.** 실제로 쓰는 길을 먼저 연다(2026-11-04 사용자). 1단계와 2단계의 층은 §4가 나눈다.
10. **끄는 길은 켜는 길과 같이 연다.** (2026-11-08 사용자) 결정 9가 2단계에 둔 모드 끄기 가운데 `off`(F3a)를 1단계 S1 앞으로 옮긴다. S1 전에는 지우고 설치가 끄는 길이다(B3d-3). 다시 켜기와 recovery(F3b)는 2단계에 남는다.

## 7. 위험과 미확인

1. 경로 표가 셋(HTTP/1 Router, H2 match, `/mcp` 사전 처리)이다. 하나로 합치지 않으면 인증 처리를 한 곳에서 셀 수 없다.
2. `account_mode`는 선택 필드라 기존 설치를 막지 않는다. 남는 위험이 셋이다. 첫째, 필드를 모르는 옛 바이너리가 필드가 든 `config.json`을 읽으면 `Auth_config_error`가 난다. 되돌릴 때 필드를 지워야 하고, 이 오류를 키퍼 컨트롤러 권한 확인이 "검사 안 함"으로 받는 갈래는 #46540이 따로 추적한다. 둘째, 설정과 `authz.jsonl`이 어긋나면 부팅을 거부하므로 설정을 잃은 `Multi_account` 설치는 설정 한 줄을 복구해야 부팅된다. 셋째, 설치 기록을 잃은 설치다. 기록은 OS 사용자의 설정 디렉터리에 있어서 `config.json`이나 base path를 잃어도 남는다. 기록까지 잃으면 부팅은 외부 고수위를 `없음`으로 읽는다. `authz.jsonl`에 모드 사건이 있으면 표에 따라 부팅을 거부하거나 `AuthorizationUncertain`으로 시작한다. 모드 사건이 없으면 설정이 `Single_user`일 때 `Single_user`로 부팅하고, `Multi_account`일 때 활성화 전 요청이라 호스트 로컬 bootstrap(`Fresh_bootstrap`)이 열린다. 후자는 `Local_operator`의 명시 결정이 있어야 열린다(설계 §8.4). 기록과 `authz.jsonl`을 함께 잃으면 새 설치와 구분할 수 없다. 이 한계는 이 설계로 닫을 수 없다. 설치 기록과 외부 저장소는 백업 복원이 되돌린 것을 알아채려는 장치이고, 설정 디렉터리와 base path에 모두 쓸 수 있는 쪽은 막지 못한다. `Fresh_bootstrap`을 여는 B3은 B2 다음에 쌓는다.
3. API provider 실행 경로를 조사하지 않았다. D2가 Codex와 Claude Code의 `run_turn`만 막으면 다른 경로로 우회할 수 있다. D3과 D4 전에는 `Multi_account`를 열지 않는다.
4. JOSE 후보를 현재 pin과 함께 풀어 보지 않았다. `jose`는 x509 >= 0.13.0을 요구하고 lock은 1.0.6이라 하한은 맞다. 상한과 다른 의존성은 opam 해결기로 확인하지 않았다.
5. A1의 실제 요청은 열려 있는 변경 경로를 실행할 수 있다. 격리한 base path, Keeper 없음, loopback만 쓴다. 경로 인자는 형식이 맞는 존재하지 않는 값을 쓴다.
6. 이 조사는 코드를 읽은 것이다. 빌드와 실행은 하지 않았다. 줄 번호는 `d595f10978db` 기준이라 main이 움직이면 어긋난다.
7. `Fs_compat`에는 Darwin `F_FULLFSYNC`를 부르는 곳이 없다(`fs_compat.mli:451-454`). `authz.jsonl`의 fsync는 프로세스가 재시작해도 남는 수준이고, 정전 뒤까지 남는다는 보장은 아니다.
8. 서버 밖 프로세스가 같은 파일을 `Fs_compat`의 cursor 계열로 읽는 동안 서버의 append는 `Locked`가 된다. 이 파일을 읽는 도구는 B1b 뒤에 정한다.
9. `Single_user`의 lease record가 어디에 쓰이는지 설계가 말하지 않는다. 설계 §6.1은 근거 값 `Single_user_operator`를 lease record와 durable work record에 남긴다고 하고, §8.2는 lease record를 `authz.jsonl`에만 쓴다고 하고, §8.4는 `Multi_account`를 거친 적 없는 `Single_user`가 `authz.jsonl`을 쓰지 않는다고 한다. 셋이 함께 서려면 `Single_user`의 lease record가 다른 저장소에 있어야 한다. 아니면 `Single_user` 설치의 `authz.jsonl`이 비어 있지 않아서 `Fresh_bootstrap`의 빈 `authz.jsonl` 조건이 서지 않는다. `Single_user`의 lease record를 `authz.jsonl`에 쓰기로 정하면 §8.4의 "`authz.jsonl`을 쓰지 않는다"와 `Fresh_bootstrap`의 빈 `authz.jsonl` 조건을 같은 PR에서 고친다. E1이 lease 저장소를 정할 때 함께 정하고, 그 결정이 없으면 E1은 시작하지 않는다.

## 8. MASC 등록

- Goal은 이 계획이 승인된 뒤에 만든다. 성공조건은 층마다 병합된 PR이 하나씩 있는 것이다. 지표는 병합된 층 PR 수이고 목표값은 32이다.
- Task는 층마다 `goal_id`를 붙여 만든다. 층 하나가 Task 하나이고, PR 번호는 Task에 적는다.
