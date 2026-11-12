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
- epoch 최고값과 `credential_generation` 항목은 두지 않는다. 설계 §8.2의 `Intent_pending` 필드에 epoch 값이 없다. 외부 고수위와 replay의 epoch를 맞추는 일(§5.1 `맞음`의 셋째 조건)은 값이 아니라 수로 한다(S1a-0). 저장소 상태는 `Committed`의 수(`answered`)를 가진다. 하드 컷이라 이전 형식을 읽는 코드는 두지 않는다.
- 시험은 줄의 바이트(모든 사건의 낱말 포함), 모든 `change`의 읽고 쓰기와 다시 열었을 때의 상태, 규칙을 어기는 파일과 줄(순서 규칙과 부트스트랩 규칙), 끝이 잘린 마지막 항목의 자름을 본다.

**B2c 범위** (외부 고수위 판정)

- 판정 1~5(설계 §8.2)와 외부 고수위 값(§5.1)을 순수 함수로 만든다. 입력은 외부 저장소의 상태(`Authz_external_store.State.t`)와 `authz.jsonl` 레코드의 열이고, 출력은 둘이다. 하나는 대기 중인 intent를 닫는 일(`settle`: `Promote`·`Abort`, 닫지 못하면 그 사유)이고, 다른 하나는 값(`Absent`·`Matches`·`Mismatch`)이다. §5.1이 판정을 먼저 돌리고 값을 읽으므로 둘은 서로 기다리지 않는다. 값이 `Mismatch`여도 `settle`은 같은 답을 준다. 판정 3이 서면 §8.3의 차단을 바로 세우기 때문이다. 이 층은 파일을 열지도 쓰지도 않는다. 쓰기와 그 성공 여부는 값을 바꾸지 않는다(§5.1). `Mismatch`일 때 어떤 쓰기를 하는지는 위 층이 정한다.
- 로그에서 읽는 사실은 셋이다. 마지막 레코드의 해시, 대기 중인 intent의 `previous_record_hash` 바로 뒤 레코드의 해시, 마지막 `Committed`의 해시가 로그에 있는지. 해시 둘을 먼저 알아야 해서 외부 저장소를 먼저 열고 그 상태로 `Probe`를 만든 뒤 `Authz_log.open_at_start`의 접기 함수로 레코드를 먹인다. 메모리는 로그 길이와 상관없이 일정하다.
- 판정 2·3·5는 `previous_record_hash` 뒤 레코드로 가른다. 그 레코드가 intent가 적은 해시이면 판정 2(`Promote`)다. 다른 해시이면 판정 2·5의 `Digest_differs`이고 `AuthorizationUncertain` 사유다. 뒤 레코드가 없고 로그가 `previous_record_hash`에서 끝나면 판정 3(`Abort`)이다. 뒤 레코드가 없는데 로그가 다른 곳에서 끝나면 `previous_record_hash`가 로그에 없는 것이고 판정 5(`Intent_unplaced`)다. 설계는 "intended record와 일치하는 record"라고 적었다. 레코드 해시는 seq와 이전 해시를 덮으므로, 쓰는 쪽이 제대로 만든 intent라면 해시로 찾으나 자리로 찾으나 같은 레코드다. 이 층은 자리로 찾고, 둘이 갈리는 intent(digest가 그 자리에 설 수 없는 레코드의 해시)는 `Digest_differs`로 읽는다. 로그의 head가 그 사이 lease 같은 로그 전용 레코드로 앞서 가도 판정 2는 선다.
- `Abort`는 `previous_record_hash` 뒤에 레코드가 없는 동안만 선다. 뒤에 레코드(lease 포함)가 붙으면 같은 intent가 `Digest_differs`가 되고 닫히지 않는다. 그래서 구역에 들어올 때마다, 무엇을 붙이기 전에 판정해야 한다(§8.2-1). 그 순서는 B3가 정한다.
- 판정 4는 마지막 `Committed`의 해시가 로그에 없을 때다(`Commit_not_in_log`). 마지막 `Committed`는 쓰기 전에 저장소가 가진 것이고, 승격될 intent가 대신하지 않는다. 대기 중인 intent의 판정과 따로 보고 `Mismatch`는 사유를 모두 돌려준다(§5.1).
- 값은 §5.1의 `없음`·`맞음`·`안 맞음`에 대응한다. `읽지 못함`은 외부 저장소를 열지 못한 오류에서 나오므로 이 층이 아니라 A2가 만든다. `없음`은 `Committed`가 없고 남은 intent가 없거나 `Abort`로 닫히는 `Fresh_bootstrap`뿐인 저장소다. 저장소 규칙(B2a)상 첫 `Committed` 전의 intent는 `Fresh_bootstrap`뿐이다. 로그가 그 intent를 얻었으면(`Promote`) 승격되는 intent는 `Committed`에 든다는 §5.1에 따라 `맞음`이다. `맞음`은 마지막 `Committed`가 로그에 있고, 남은 intent가 풀리고, 로그와 저장소의 수가 같은 것이다(아래 S1a-0).
- `settlement_entry`는 `Promote`·`Abort`가 외부 저장소에 쓸 항목(`Committed`, `Aborted_intent`)을 한 곳에서 만든다. 부팅과 구역 진입이 같은 항목을 쓰게 한다. 그 항목을 `apply`한 상태가 쓰기 뒤의 저장소이고, 승격된 `Fresh_bootstrap`의 workspace는 그 상태에서 읽는다.
- `Authz_external_store.apply`(한 항목을 상태에 접고 어긴 규칙을 돌려주는 순수 함수)를 공개한다. 판정 시험이 파일 없이 저장소 상태를 만들고, 열 때의 접기 함수가 쓸 수 있다.
- 이 층이 하지 않는 것: 같은 writer lock 구역 안에서 `Intent_pending` 쓰기, 레코드 append, `Committed` 갱신을 잇는 순서(§8.2-1)와, 구역에 들어올 때마다 남은 intent를 다시 판정하는 일. 구역 안에서 판정에 쓸 사실(뒤 레코드, head)을 어디서 얻는지는 접힌 상태(`Authz_state.t`)가 생기는 B3가 사건을 처음 쓰면서 정한다. 이 층의 `Probe`는 열 때의 재생에 쓴다. 한 묶음의 append(설계 §10.1)에서 intent가 어느 레코드를 적는지도 묶음을 쓰는 층이 정한다. 이 층은 `previous_record_hash` 뒤 첫 레코드를 본다.
- S1a-0(수 대조)이 §5.1 `맞음`의 셋째 조건을 더한다. replay는 intent를 받는 레코드를 센다(`asked`). `Authz_state.apply`가 `high_water`를 돌려주는 레코드다. 저장소는 `Committed`를 센다(`answered`). 승격될 intent는 `Committed`로 친다. 다른 사유가 없는데 두 수가 다르면 `Mismatch(Answers_differ {asked; answered})`다.
  - 이 대조가 epoch 일치와 같은 까닭: scoped epoch와 모드는 intent를 받는 레코드만 바꾼다. 마지막 `Committed`의 해시가 로그에 있으면 그 앞 레코드는 해시 사슬로 정해진다. 그래서 두 수가 같으면 로그에서 epoch나 모드를 바꾸는 레코드는 모두 저장소가 답한 것이다.
  - 닫는 것: base path에만 쓸 수 있는 쪽이 구역 밖에서 덧붙인 모드 사건과 축소 사건. `masc auth off` 뒤에 `Reactivate` 한 줄을 덧붙여도 부팅은 다계정으로 뜨지 않는다. 다계정 설치에 `Off` 한 줄을 덧붙여도 단일 사용자로 뜨지 않는다.
  - 닫지 않는 것: intent를 받지 않는 레코드(초대 발급, 재활성, 취소, 등록, provider account 연결, Runtime·Keeper 기록)를 덧붙이는 일. 이 레코드는 저장소에 흔적이 없다. 막으려면 base path 밖의 키로 레코드를 인증해야 한다(이슈로 남긴다).
  - 어느 사건이 intent를 받는지는 로그가 생긴 뒤에 바꾸지 않는다. 바꾸면 전에 쓴 로그의 `asked`가 달라져 그 설치의 부팅이 멈춘다. 바꿔야 하면 하드 컷이다.
  - 수는 `Probe`가 레코드를 받을 때 같이 받는다(`Probe.add ~high_water`). 재생(`Authz_zone.Replay.step`)과 구역의 append가 같은 함수로 센다. `Authz_state.step`은 부르는 곳이 재생 하나라서 지우고 재생이 `apply`를 직접 부른다.
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
  - 부팅 판정은 두 파일을 구역과 같은 접기(`Authz_zone.Replay`)로 읽고 손잡이를 버린다. 구역의 열기는 두 파일이 다 있을 때만 구역을 만들고, 부팅은 하나가 없는 경우(설치 기록 없음, 로그 없음, 빈 로그)도 판정한다. 구역은 판정이 7행(`Multi_account`)일 때만 계정 서버가 연다(S1a-1). 7행은 저장소를 읽었고 로그가 다계정을 만든 경우라서 두 파일이 다 있다. 다른 행에서는 구역을 열지 않는다.
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
  - B3d-1 `masc auth bootstrap --external-store PATH`. BasePath lease를 쥔다(`Server_startup_takeover.acquire_base_path_lock`, 선례 `Released_workspace_upgrade.apply`). 서버가 떠 있으면 lease를 얻지 못해 아무것도 쓰지 않고 끝난다. 로직은 `Authz_activation`(lib)에 두고 시험한다. lease와 출력만 `bin/masc_cli_auth`가 한다. 쓰기 전에 부팅과 같은 판정(`Authz_boot_mode_read.input`·`decide`)을 돌리고, 5행일 때만 쓴다. 설정이 `Single_user`인 채로 `Fresh_bootstrap`을 쓰면 다음 부팅이 3행으로 멈추고, 이미 멈추는 줄에 쓰면 멈춤만 늘기 때문이다. 5행이 아니면 아무것도 쓰지 않고 이유를 나눠 말한다. 설정이 다계정을 묻지 않으면 `Not_asked`, `config.json`을 못 읽으면 그 이유를 단 `Config_unreadable`, 이미 켜진 설치(7행)면 `Already_active`, 나머지는 부팅이 찍는 문구 그대로인 `Boot_stops`다. 판정에 넣는 익명 쓰기 설정은 이 명령을 부른 셸의 환경 변수다. 서버는 자기 환경을 읽으므로, 다른 환경에서 띄운 서버와는 다를 수 있다. workspace id·invite id·token은 `Authz_activation`이 OS `getrandom`으로 뽑는다(`Random_id.hex`, §8.4 "새 workspace_id"). token은 32바이트의 hex 64자이고, 디스크에는 SHA-256 digest만 남는다(§5.1-4). token은 추상 타입 안에 있고 `Authz_activation.link`로만 꺼낸다. 외부 저장소 경로는 운영자가 정한다. 백업 범위를 masc가 알 수 없기 때문이다. `Fresh_bootstrap` 다음 같은 lease 안에서 구역을 열고 첫 Admin 초대를 `Local_operator`로 쓴다. 초대 만료는 24시간이다(§5.1-4가 계획에 맡긴 값). 링크 모양은 `<base url>/accounts/invite#<token>`이고, 화면(C6 ②)과 소비(C2a)가 이 경로(`Authz_activation.invitation_path`)를 쓴다. 링크는 한 번만 화면에 찍는다. base url은 `MASC_HTTP_BASE_URL`만 쓴다. Play 초대와 같은 검사(`Play_invite.is_http_public_base_url`)를 통과해야 한다. 셸의 `MASC_HOST`·`MASC_HTTP_PORT`로 만든 주소는 서버가 실제로 듣는 주소와 다를 수 있어서 쓰지 않는다. 이 값은 쓰기 전에 읽어서, 없거나 틀리면 아무것도 쓰지 않는다. 검사 자체는 `test_play_invite`가 본다. 거절 문구는 값을 찍지 않는다. 비밀번호가 든 URL일 수 있기 때문이다. 링크가 표준 출력에 닿지 못하면(flush 실패) 종료 코드 1로 알린다. bootstrap 뒤 초대 커밋이 실패하면 로그에는 bootstrap만 남고 초대는 B3d-2로 다시 쓴다. 이 명령이 성공한 설치를 서버는 다계정 설치로 띄운다(7행, S1a-1). 도움말과 성공 문구가 이 사실과 끄는 명령(`masc auth off`, F3a)을 말한다. §11의 readiness는 원격 다계정을 여는 부팅(S1)이 본다. 이 명령은 기록만 쓰고 서버를 열지 않는다. F5가 readiness를 만들면 §11-3에 따라 이 명령도 오래된 readiness에서 거부한다(F5 범위).
  - B3d-2 `masc auth invite`. 서버가 멈춘 상태에서 `Local_operator`가 Admin 초대를 하나 더 쓴다. 첫 초대가 쓰이기 전에 만료되거나 링크를 잃었을 때 쓴다. 초대를 하나 더할 뿐 취소하지 않으므로, 잃어버린 링크도 쓰이거나 만료될 때까지 열려 있다. 초대 취소와 Member 초대는 Admin이 서버로 한다(`Login_invite_routes`, 아래 S1a-3b 범위). 부팅 판정이 `Multi_account`이고 외부 저장소가 로그와 맞을 때만 쓴다(§5.1 표 7행). 저장소 경로는 설치 기록에서 읽는다. lease, base url(`MASC_HTTP_BASE_URL`), 링크 출력은 B3d-1과 같다(`Authz_activation.invite`, `masc auth invite`).
  - B3d-3 부팅 문구. 5행 거부의 이름은 판정이 내는 모드와 같은 `Activation_requested`다. 문구는 두 가지를 말한다. 서버를 멈춘 채 `masc auth bootstrap --external-store PATH`를 돌리면 활성화되고, 그 뒤 서버는 이 설치를 다계정 설치로 띄운다. `config.json`에서 `account_mode`를 빼면 단일 사용자로 뜬다. CLI도 이 문구를 찍는다. 거부는 S1 뒤에도 남는다. 5행에서 서버가 열 경로가 없기 때문이다.
  - B3d-3 지우고 설치(2026-11-08 사용자 결정, §6 결정 10). masc 프로세스를 모두 멈추고 세 가지를 지운다. `authz.jsonl`, 외부 저장소, 이 base path를 적은 설치 기록이다. 그리고 `config.json`에서 `account_mode`를 뺀다. 그러면 부팅은 이 base path를 활성화한 적 없는 설치와 가르지 못하고 1행대로 단일 사용자로 뜬다. 로그만 지우면 복원으로 보고 거부한다(2행). 로그와 외부 저장소만 지워도 1행이 되지만, 설치 기록까지 지워야 찌꺼기가 남지 않는다. 로그의 잠금 파일은 부팅이 다시 만드니 남아도 된다. 시험은 실제 `Fresh_bootstrap` 뒤 세 가지를 지우고 1행을 확인한다(`everything deleted`). 문구는 이 길을 안내하지 않는다. 로그를 지우면 계정이 가진 Runtime·Keeper 기록과 로그인 기록이 같이 지워지기 때문이다. 문구가 안내하는 끄는 길은 `masc auth off`다(F3a).
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
  - C2a-2 로그인 transaction. 시작할 때 `state`·`nonce`·PKCE verifier를 OS CSPRNG로 뽑아 프로세스의 키로 봉인한다(S1a-3a-1). 서버는 진행 중인 로그인을 저장하지 않는다.
    - C3이 봉인한 값을 `__Host-masc_oidc_txn`에 싣는다. callback은 그 값을 열고 `state`를 `Eqaf.equal`로 비교한다.
    - 만료는 10분이고 열 때 본다. 같은 값은 만료 전까지 다시 열린다. 재사용은 provider의 일회용 code와 로그의 일회용 초대가 막는다.
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
  - C2a-5 설정과 흐름. `auth_config.google` 설정과, 로그인 하나를 시작부터 입장 판정까지 도는 함수다. HTTP 경로는 C3이 만든다(2026-11-06 범위 조정). 경로는 봉인한 transaction을 `__Host-masc_oidc_txn` 쿠키로 주고받는데 그 쿠키가 C3의 것이라, 이 층에 경로를 두면 callback이 transaction을 찾지 못한다.
    - 설정은 `auth_config.google`다. client ID, redirect URI, client secret을 담은 환경 변수의 이름을 둔다. 멤버 이름은 프로토콜이 아니라 provider다. C2b의 GitHub client는 같은 모양의 `github` 멤버다. secret 값은 `config.json`에 두지 않는다. `save_auth_config`가 그 파일을 다시 쓰고, 백업에도 들어가기 때문이다. 이 필드를 쓰는 곳은 다계정 경로뿐이다.
    - client는 이 설정과 환경 변수로 만든다. redirect URI는 `https` URL이어야 한다. `__Host-` 쿠키는 `Secure`라서 다계정 로그인은 `https`에서만 돈다.
    - start는 초대 token(선택)과 `return_to`를 받는다. discovery를 먼저 읽고 transaction을 만든다. 결과는 봉인한 transaction과 Google 인가 URL이다. `return_to`가 길어 봉인이 쿠키 하나에 들어가지 않으면 시작을 거절한다.
    - callback은 C2a-2, 3, 1, 4 순서로 돈다. transaction을 먼저 열므로, 열리지 않는 callback은 Google에 묻지 않는다. 결과는 입장 판정과 `return_to`다.
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
    - transaction이 시작한 흐름을 타입으로 든다(GADT `_ flow = Google : google flow | Github : unit flow`). Google transaction은 nonce를 들고, GitHub transaction은 들지 않는다. 열 때 부르는 쪽이 흐름을 대고, 다른 흐름이면 `Other_flow`로 거절한다.
    - 모듈 이름 `Oidc_login_transaction`은 그대로 둔다. 설계(§5.2.1)가 GitHub 흐름의 쿠키도 `__Host-masc_oidc_txn`이라고 부르기 때문이다.
    - 전송 함수 `get`이 헤더를 받는다. Google의 discovery와 JWKS는 빈 헤더로 부른다. 전송 타입은 두 흐름이 함께 쓰는 모듈 `Login_transport` 하나에 둔다.
    - PR은 둘로 나눈다. C2b-1a가 전송, C2b-1b가 transaction이다.
  - C2b-2 GitHub과 주고받기. 인가 URL, token 교환, `GET /user` 한 번이다.
    - access token은 이 함수 안에서만 쓴다. 저장하지 않고, 로그와 오류 문구에 싣지 않는다.
    - `id`가 정수가 아니거나 `Authz_external_identity.github`가 거절하면(0 이하, 2^53-1 초과) 거절한다. `login`과 email은 읽지 않는다.
    - `User-Agent: masc`를 직접 보낸다. 전송을 바꿔도 GitHub이 거절하지 않게 하기 위해서다.
    - 응답 크기 상한은 C2a-3의 `max_document_bytes`(64 KiB)를 같이 쓴다.
  - C2b-3 설정과 흐름. `auth_config.github`(타입 `login_client`, C2a-5a)와 `Github_login_flow`의 start·callback이다. callback은 transaction(C2b-1), 교환(C2b-2), 입장(C2a-4) 순서로 돈다. transaction을 먼저 열므로, 열리지 않는 callback은 GitHub에 묻지 않는다.
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
  - 실제 서버는 아직 로그인 경로를 열지 않는다(S1a-3). 그래서 서버가 쓴 입장 레코드는 어느 로그에도 없다. 입장 본문을 바꾸는 일은 hard cut이고, 옛 본문을 읽는 코드를 두지 않는다.
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
  - 로그인 흐름은 `Google_login_flow`(C2a-5)와 `Github_login_flow`(C2b-3c)다. 둘 다 start와 callback을 내고 쿠키는 보지 않는다. 봉인한 transaction(`Oidc_login_transaction`)은 시작한 흐름을 싣는다. 다른 흐름이 시작한 transaction은 `Other_flow`로 거절한다.
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
- 경로. 등록 함수 하나가 구역, transaction을 봉인하는 키, 두 login client, 전송, 시계, 뽑기를 받는다. S1이 부팅에서 부른다.
  - `POST /auth/oidc/start`, `POST /auth/github/start`. 폼으로 초대 token(선택)과 `return_to`를 받는다. 같은 출처 Origin을 요구한다. 남의 초대 token을 담은 로그인을 피해자 브라우저에서 시작시키지 못하게 하려는 것이다. 봉인한 transaction을 `__Host-masc_oidc_txn`에 싣고 인가 URL로 303을 보낸다.
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
  - 경로를 서버의 표에 다는 일은 S1a-3이 한다. 그 전에는 실제 서버에 이 경로가 없다.
- 시험.
  - C3-4·5: 남의 세션 폐기 거절, 두 번 폐기 거절, 끝난 세션을 `replaces`로 받지 않음, 폐기와 `replaces` 발급의 intent, 7일 만료.
  - C3-6·7: secret이 틀린 쿠키, 만료된 세션, Disable된 principal의 세션, cookie와 bearer가 함께 온 요청, Origin 없는 POST, CSRF 불일치, 원격 query credential.
  - C3-8: 시험이 Google과 GitHub을 흉내 내고 구역을 직접 연다. 다른 흐름의 transaction 쿠키는 401, callback이 기존 세션을 끊음, 같은 초대의 동시 소비는 409, 거절 화면에 token과 secret이 없음.
- 하지 않는 것: `Auth_gate.decide`와 요청 경로 연결(C4), MCP OAuth 결속(C5), 화면(C6), 경로 등록(S1a-3).

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
- 하지 않는 것: Single_user 경로 바꾸기, MCP OAuth 결속(C5), 화면(C6), 경로 등록(S1a-3)·부팅에서 모드 넘기기(S1a-1), Service principal의 Disable·삭제, legacy 호출자를 Service credential로 옮기는 일(S1 전 개시 증거에서 목록으로 센다).

**미리보기 범위** (localhost 다계정 확인, 2026-11-08)

- 사용자 결정(2026-11-08).
  - C4-8 뒤에 사람이 브라우저로 다계정 로그인을 해 보는 길을 먼저 연다.
  - redirect는 loopback 전용 타입으로 연다. 실제 서버의 https 규칙은 그대로 둔다.
- 하는 일. 사람이 자기 컴퓨터에서 이 순서를 해 본다.
  1. GitHub으로 로그인한다.
  2. 세션이 생긴다.
  3. 서버가 그 사람을 누구로 보는지 확인한다.
  4. 로그아웃한다.
- 서버(`masc serve`)는 바꾸지 않는다. 서버가 다계정 설치를 띄우는 일은 S1이 한다. S1이 D1~D4 뒤인 이유는 소유권 검사 없이 Keeper와 Runtime을 서빙하면 안 되기 때문이다. 미리보기는 Keeper, Runtime, MCP, Board 경로를 하나도 열지 않는다.
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
  - D2-1 adapter. 한 snapshot에서 Keeper 턴의 `facts`를 만든다. 배정이 없으면 `NoAuthorizedRuntime`이다. 1단계에는 Runtime과 ProviderAccount의 상태 기록이 없어서 둘 다 `Active`다. 회수는 그 snapshot이 가진 보류다(`revocation_pending`). 의존은 `Cleared`다. 1단계에는 복원 창이 없고(F2는 2단계), A2가 복원된 로그를 거절한다.
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
    - Codex와 Claude Code 실행 레코드의 `account_home`은 `'client Runtime_account_access.sealed`다. 잡은 계정을 봉인하는 곳은 테이블을 만드는 `Runtime_adapter` 하나다.
    - 봉인된 값은 홈 문자열(`Runtime_account_access.home`)과 같은 캡처인지(`Runtime_account_access.same`)만 내준다. quota 창과 다시 읽기 비교가 이것을 쓴다. 환경은 인가된 계정에서만 나온다.
    - 테이블을 읽는 호출처는 봉인된 값을 그대로 `authorize`에 넘긴다. 읽자마자 봉인하던 일이 없어졌다. 계정을 잡자마자 인가받는 곳(setup의 로그인 확인, `masc runtime-codex-models`)만 직접 봉인한다.
  - D2-8 미리보기 "내 Keeper 한 번 돌리기". 사람이 브라우저로 확인한다. 2026-11-09 D2-6·D2-7보다 먼저 했다. Claude Code는 D2-5부터 인가된 계정으로만 뜨므로, Codex를 기다리지 않고 사람의 구독으로 Keeper 턴이 도는지 먼저 확인할 수 있다.
    - 라우트는 `POST /api/v1/auth/keepers/turn`이다. 본문은 `{"keeper_id","message"}`이고 메시지는 4096바이트까지다. 게이트는 `Manage_own_keeper`에 membership을 더한다(`Auth_preview.keeper_turn_caller`). 턴이 그 사람 namespace 아래 홈에서 CLI를 띄우기 때문이다. 게이트는 요청을 인증한 PAT도 넘긴다. 턴 판정(`Authz_keeper_turn.decide`)이 그 PAT의 범위를 `pat_scope`로 읽어서, 범위에 그 Runtime, `Direct` 채널, 턴이 청하는 effect(`invoke_model`, `use_tool`)가 모두 있어야 턴이 돈다(2026-11-12 사용자 결정). 세션으로 온 요청과 서버가 스스로 시작하는 턴은 PAT가 없다.
    - 라우트는 기록만 읽는다. Keeper 기록이 Runtime을, Runtime 기록이 계정을 정한다. 런타임은 그 계정의 login receipt가 이름 붙인 workspace provider에 그 계정 홈과 binding 하나를 얹은 것이다(`Server_setup_account_login.person_runtime`). binding은 이 계정에서 만드는 Runtime id가 Keeper 기록의 id와 같은 것이다(`Runtime_account_runtime.Runtime`). id를 자르지 않고 binding마다 만든 id와 통째로 비교한다.
    - 판정은 `authorize (Keeper_turn {channel = Direct; ...})` 하나다. 로그로 판정하고, 인가된 계정만 CLI를 띄운다. 남의 Keeper는 다른 Keeper 라우트처럼 404다.
    - 한 계정에서는 한 호출만 돈다(`Server_setup_account_login.one_call_of`). verify와 턴이 같은 잠금을 쓴다. 한 홈의 자격 증명을 두 CLI가 동시에 갱신하지 않게 하기 위해서다. 다른 계정의 호출은 기다리지 않는다.
    - CLI는 `default_config`의 자세로 뜬다. 턴은 로그에 기록을 남기지 않는다.
      - Claude Code: 내장 도구는 deferred tool 조회(`--tools ToolSearch`)뿐이고 MASC의 MCP 서버는 없다.
      - Codex(D2-6b): `Ephemeral` 스레드로 돈다. Codex는 그 스레드의 rollout도 기록도 남기지 않는다. 자세는 Codex 기본값 `Native_read`다(권한 `:read-only`, shell 꺼짐). Codex에는 `Native_none`이 없다. MASC 도구는 넘기지 않는다.
      - 실패 답은 두 클라이언트가 같은 문장을 쓴다. Codex는 구독 소진을 턴 실패로 보내므로(`refused_for_spent_usage`) 실패 종류보다 먼저 보고 429로 답한다.
  - 하지 않는 것: 다계정 Keeper 턴의 후보를 로그의 배정에서 고르는 드라이버 쪽 일(S1 전), Antigravity·Muse(D3), API provider(D4).

**D3 범위** (나머지 실행 진입, 2026-11-09)

- 조사(main `9d67e41d` 위 D2-7).
  - Muse는 사람이 다계정에서 로그인할 수 있다(`server_setup_account_login.ml`의 `Person _, Muse`). 홈은 `Runtime_account_home_layout.Muse_home`으로 사람 namespace 아래에 생긴다. 그래서 Muse는 Codex·Claude Code처럼 사람의 계정이다.
  - Antigravity는 사람이 다계정에서 로그인하지 못한다(`person_antigravity_refused`). 자격 증명은 주인 없는 setup registry의 사본이다. Vibe는 호스트 사용자의 설정을 읽는다. 둘은 호스트 계정이다.
  - Codex `probe_metadata`와 Claude `probe_auth_status`는 D2-5·D2-6에서 이미 인가된 계정만 받는다.
  - Vibe Keeper 턴은 이미 거절된다(`vibe_keeper_turn_refused`). Vibe는 Fusion과 `masc lane-cli-probe`에서만 뜬다.
- 층.
  - D3a Muse. 실행 테이블이 Muse 홈을 선언된 홈(`Runtime_account_access.muse_home`)으로 든다. Muse 클라이언트(`run_turn`, `read_usage`, `list_models`)는 config에 홈이 없고 인가된 계정만 받는다.
    - 판정은 Codex·Claude Code와 같은 함수다. 다계정에서는 요청한 사람 namespace 아래에 선언된 홈이어야 한다. 프로세스 환경의 홈(`Process_environment`)은 거절한다.
    - 선언된 홈이 꼭 있어야 하는 호출(Keeper 턴, verify)은 타입 인자 `declared`로 그 홈만 받는다. 프로토콜 fixture만 프로세스 환경을 쓴다.
    - 호출처: 턴 드라이버(시도마다 Keeper 턴 요청), verify, Fusion, capability probe, 사용량 읽기(실패한 턴의 계정), `masc runtime-muse-models`(작업 공간 판정 뒤 운영자 호출), setup의 모델 조회.
  - D3b Antigravity·Vibe. 호스트 계정은 1단계에서 공유하지 않으므로 다계정에서 시작을 모두 거절한다. 단일 사용자에서는 지금처럼 뜬다.
    - `Runtime_account_access.authorize_host`가 단일 사용자 프로세스에만 `host_account`를 준다. 다계정은 `Host_account`로 거절한다. 판정에 요청은 쓰지 않는다. 1단계에서는 누가 묻든 같다.
    - 토큰을 받는 곳은 호스트 자격 증명에 닿는 함수 전부다. Antigravity 턴(`run_turn`), 홈 준비(`prepare`, `prepare_account`, `prepare_native`, `prepare_for_login`), `/usage` 읽기, readiness 턴, 컨텍스트 관찰, Vibe 호출(`Runtime_vibe_cli.run`), vibe-acp readiness.
    - 홈 준비도 토큰을 받는다. 홈에는 호스트 자격 증명의 사본이 들어가므로, 거절된 시작은 사본도 만들지 않는다.
    - 호출처: 턴 드라이버(시도마다), verify, capability probe, Fusion, 사용량 읽기, setup 로그인, `masc runtime-antigravity-{account,models,context}`(작업 공간 판정 뒤), `masc lane-cli-probe`.
  - D3c 다른 사람의 홈. 설계 §11.1의 lane 종류마다 다른 owner의 account-home을 읽지 못한다는 증거다. 세 조각으로 나눈다(사용자 결정 2026-11-09).
    - D3c-2 규칙. 공식 CLI는 서버 프로세스의 사용자로 돈다. 그 CLI의 native 도구(Claude Code의 Read, Codex의 read-only 샌드박스, Muse의 내장 도구)는 그 사용자가 읽는 곳을 모두 읽는다. 다계정에서는 거기에 다른 사람의 홈과 로그인 자격 증명이 있다.
      - 그래서 다계정 프로세스는 모델 턴을 native 도구 없이(`Native_none`)만 돌린다.
      - `Runtime_account_access.authorize_native`가 판정한다. 단일 사용자는 모든 자세를 허용한다. 다계정은 `Native_none`만 허용하고, 나머지는 `Native_tools_reach_other_homes`로 거절한다.
      - 판정은 클라이언트마다 모델 턴의 입구 한 곳에서 한다(`Runtime_claude_code.run_turn`, `Runtime_codex_app_server.run_turn`, `Runtime_muse_serve.run_turn`). 거절된 턴은 CLI를 띄우지 않고 `Invalid_config`로 끝난다.
      - Codex와 Muse에는 `Native_none`이 없다. 그래서 두 클라이언트의 다계정 모델 턴은 D3c-3이 자세를 열 때까지 거절된다. 미리보기의 Codex 턴은 CLI를 띄우기 전에 403으로 거절된다.
      - 모델 턴이 아닌 호출(계정 확인, 사용량 읽기, 모델 목록)은 native 도구를 쓰지 않는다. 그래서 판정하지 않는다.
    - D3c-1 lane 증거. Keeper 컨테이너 lane(docker, Apple)과 MASC Read 도구가 다른 owner의 홈을 마운트하지도 읽지도 못한다는 시험이다.
    - D3c-3 측정. 실제 CLI에게 다른 owner의 홈에 둔 표지 파일을 읽게 시키는 스크립트다. 표지를 못 읽는다고 나온 자세만 D3c-2의 허용 목록에 더한다. 구독을 쓰므로 사용자가 돌린다.

**D4 범위** (API provider, 2026-11-10)

- 조사(main `11d29814fddd`).
  - Agent_core Runtime은 실행 표에 provider 설정(`Llm_provider.Provider_config.t`)을 통째로 든다(`Runtime_execution.Agent_core`). 그 안의 `api_key`는 운영자가 선언한 자격 증명이다. 선언, 환경 변수, setup registry, 파일 중 하나에서 온다. `Secret.t`는 `private string`이라 coercion으로 원문을 읽을 수 있다.
  - 이 설정을 꺼내는 곳은 lib 26곳이다. 요청을 보내는 곳이 8곳이다.
    - Keeper 턴(`keeper_turn_driver.ml`의 `run_named`), verify(`runtime_verification.ml`), Agent_core runner(`runtime_agent_core_runner.ml`)는 Fusion, capability probe, `masc runtime-token-sample`, `masc-librarian-continuity`가 거쳐 간다.
    - exact-output 등록표(`Runtime.exact_output_targets`)는 HITL 요약, Board attention, librarian, lane exact가 쓴다.
    - lane add-on sampling, vision 도구, 사용량 읽기(`runtime_provider_usage_read.ml`), dashboard probe.
  - 나머지 18곳은 읽기만 한다. capability, 요청 모양, `kind`·`model_id`·`base_url`을 읽는다. 원문 key, `headers`, `auth_scheme`, `credential_source`를 읽는 곳은 없다.
  - 읽는 곳 중 세 곳은 key의 identity(SHA-256)를 쓴다. binding identity(`runtime_instance.ml`의 materialize), admission 허용치(`Runtime.materialize_config`), dashboard의 admission snapshot이다. 보낼 때의 admission과 같은 key여야 한다.
  - 계정 인가를 하는 곳은 없다. `validate_dispatch_credential`은 key가 비었는지만 본다. vision, 사용량 읽기, exact-output은 그것도 하지 않는다.
  - 실행 표 밖에서 호스트 key로 보내는 곳은 일곱 곳이다. D4b를 시작하며 D4a `3cd6d619bcc9`에서 key 변수 이름과 `api_key_env` 필드를 모두 세었다.
    - 모델 목록 조회와 serving window 관찰(`runtime_model_discovery.ml`, `runtime_serving_context.ml`). 서버의 setup 경로(`POST /api/v1/setup/models`, `POST /api/v1/setup/context`)가 부른다.
      - setup 경로는 HTTP 연결을 모두 거절한다.
      - credential이 없는 `Anonymous_endpoint` 연결은 호스트 key를 쓰지 않는다. 그래도 같이 거절한다.
      - 그런 로컬 연결을 열려면 판정을 연결의 credential로 나눈다.
    - `masc_file_*` 도구의 `DEEPSEEK_API_KEY`(`keeper_tool_in_process_runtime.ml`).
    - 교체 카탈로그(`AGENT_CORE_MODEL_CATALOG`). 카탈로그 파일이 provider와 key를 따로 들고, exact-output 등록표가 그 key로 보낸다.
    - TypeSafe AI lane(`typesafeai_config.ml`). destination마다 key를 담은 변수 이름을 적는다.
    - web search 도구(`tool_misc_web_search.ml`). Brave, Tavily, Exa, Bing, Ollama, Z.AI key를 쓴다.
    - SystemOne 도구의 cloud backend(`tool_local_runtime_systemone.ml`, `OLLAMA_CLOUD_API_KEY`).
    - voice endpoint(`voice_bridge_transport.ml`의 `resolve_api_key`). endpoint마다 `api_key_env`를 적고, ElevenLabs가 기본이다.
  - 호스트 key로 보내지 않는 곳.
    - GitHub token은 Keeper에게 넘어가지 않는다. exec는 token 변수를 지우고, 선언도 거절한다. Keeper마다 자기 로그인(`GH_CONFIG_DIR`)을 쓴다.
    - MASC 자신의 token(`MASC_TOKEN`, admin token, internal MCP token)과 GitHub 로그인 앱 secret은 MASC의 인증이다. 호스트 계정이 아니다.
    - official CLI 환경에서 지우는 변수 목록(Claude Code, Codex)은 보내는 곳이 아니다.
    - Keeper OAuth token은 Keeper마다 따로 든다.
    - Slack, Discord, Telegram bot token은 서버의 채널이다. 채널로 턴을 시작할 권한은 Keeper 턴 판정의 channel이 맡는다.
  - `masc runtime-discover-models`와 `masc runtime-serving-context`는 판정하지 않는다. 운영자의 셸에서 운영자의 환경 변수와 절대 경로 파일로만 key를 읽고, 작업 공간을 읽지 않는다. 사람이 부를 수 있는 것은 서버의 setup 경로다.
- 결정.
  - 실행 표의 provider 자격 증명은 호스트 계정이다. 사람의 계정이 아니므로 D3b처럼 다계정 프로세스는 아무것도 보내지 않는다. 단일 사용자에서는 지금처럼 보낸다. 판정에 요청은 쓰지 않는다. 1단계에서는 누가 묻든 같다.
  - `Runtime_execution.Agent_core`가 봉인한 설정(`Runtime_account_access.api_sealed`)을 든다.
    - 보내는 곳은 `Runtime_account_access.authorize_api`로만 설정을 꺼낸다. 다계정은 `Host_account Api_provider`로 거절한다.
    - 읽는 곳은 `api_declaration`을 읽는다. `api_key`와 `headers`를 비운 설정이다.
    - identity를 쓰는 세 곳은 봉인 모듈이 계산한 값만 받는다(`api_binding_identity`, `api_admission_allowances`, `api_admission_snapshot`). 값에 비밀이 없다.
  - 실행 표가 만들어지는 때에는 판정하지 않는다. 시험은 publish 없이 실행 표를 만든다. 판정은 보내기 직전에 한다. exact-output 등록표는 만들 때 판정한다. 서버는 publish 뒤에 등록표를 만든다.
- 층.
  - D4a 실행 표 봉인. 위 26곳과 시험이다. 시험은 실제 경로(`masc runtime-token-sample`, verify)에서 다계정이면 요청이 나가지 않는다는 것을 본다.
  - D4b 모델 목록 조회(서버 setup 경로), `masc_file_*`, 교체 카탈로그.
  - D4c TypeSafe AI lane. lane을 쓸 수 없는 이유에 둘을 더한다.
    - `Access_unpublished`: 프로세스가 접근을 아직 게시하지 않았다.
    - `Host_account_not_shared`: 다계정 프로세스는 호스트 계정을 나누지 않는다.
    - 판정은 `host_access` 하나다. lane은 그 거절을 자기 이유로 옮긴다. key를 읽는 함수(`arm`)는 `host_account`를 받는다.
    - 이유를 받는 곳은 둘을 lane의 이유로 묶는다. 흡수 gate는 흡수를 미룬다. Board attention은 Jev에게 묻지 않는다. memory recall 보기와 TUI는 이유를 따로 보여 준다. Jev readiness와 health는 꺼짐으로 본다.
  - D4d MASC 도구의 호스트 key. web search, SystemOne cloud, voice.
    - 판정은 `authorize_host`다. `host_client`에 `Web_search`, `Systemone_cloud`, `Voice_endpoint`를 더한다.
    - key를 읽는 함수가 `host_account`를 받는다. web search는 `Tool_misc_web_search.credential`, SystemOne은 `cloud_headers`, voice는 `Voice_endpoint_key`의 `read`다.
    - key가 없는 곳은 판정하지 않는다. SearXNG, SystemOne local, key 변수를 적지 않은 voice endpoint다.
    - web search는 순서에 key 없는 provider가 없으면 `Policy_rejection`으로 끝난다. 있으면 그 provider로 찾고, key 있는 provider는 `account:` 오류로 남는다.
    - voice transport(`masc.voice_bridge_core`)는 key를 읽지 않고 `~api_key`를 받는다. add-on 경계 아래 라이브러리가 판정 모듈에 기대지 않는다.
  - D4a, D4b, D4d의 판정은 `authorize_host`다. 대상마다 `host_client`에 닫힌 variant를 더해서, 거절 문장이 무엇을 막았는지 말한다. D4c는 lane의 이유가 이미 닫힌 variant라서 같은 결정(`host_access`)을 그 이유로 받는다.
- D4a에서 남긴 것.
  - 시험 프로세스는 시작할 때 단일 사용자 접근을 게시한다(하네스 #50867). 그래서 D4a는 시험에 게시 호출을 더하지 않는다. 다계정 시험은 실행 표가 만든 API 런타임으로 verify를 불러, 거절(`account_not_authorized`)과 연결 0건을 본다.
  - 다계정 서버 부팅: exact-output 대상 하나가 거절되면 등록표를 만들지 않고 설정 오류로 멈춘다. 다계정 설치의 계정 서버는 owner 상태를 만들지 않아서(S1a-1) 이 경로에 닿지 않는다. 다계정 설치가 owner 상태를 띄우는 층에서 정한다. 거절된 대상을 본문 시간 제한이 없는 slot처럼 gap으로 내리면, 그 slot만 가진 lane은 비고 부팅은 계속된다.

**D6 범위**

- 사람 initiator가 없는 dispatch(autonomous, system)가 만든 상태는 `Service(system)` 표시를 달고 `Read_state`가 허용된 initiator에게만 보인다(§3-11).
- 봉인은 읽을 때 원천 initiator의 현재 상태로 판정한다. 봉인 표시를 저장하지 않는다. 저장하면 initiator가 Active로 돌아와도 풀리지 않는다(§3-11).
- 표시를 붙이면 저장 형식이 바뀐다. 기존 상태를 어떻게 할지는 §6의 결정 5가 정한다.
- 첫 일은 조사이고 산출물은 표다. 칸은 다섯이다. ① 파생 상태를 만드는 자리(요약, 병합된 기억 등) ② 내용 주소로 공유되는 blob과 artifact ③ 이미 퍼진 복사본(산출 글, artifact 게시본, checkpoint, 백업, 로그와 trace) ④ 쓰기 경로의 미러와 이중 저장 ⑤ initiator 표시를 붙일 수 있는 키가 저장소에 있는지. 표시를 붙일 수 없는 저장소가 나오면 D6을 쪼개거나 이 계획을 고친 뒤 시작한다.

### S. 1단계 개시

S1은 둘로 나눈다(2026-11-10 사용자). 다 만든 뒤에 여는 대신 돌아가는 상태부터 올린다. S1a는 미리보기가 하던 범위(로그인, 구독 연결, Runtime·Keeper, Keeper에게 묻기)를 실제 서버에 연다. S1b는 사람에게 MCP·Board·WebSocket을 연다. S1b도 MCP(S1b-1)부터 연다(2026-11-12 사용자).

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| S1a-0 | 외부 저장소와 로그를 답의 수로도 맞춰 본다. 세부는 B2c 범위의 S1a-0 항목이다. | §5.1, §8.2 | B3, F3a |
| S1a-1 | 서버 부팅이 7행(`Multi_account`)을 계정 서버로 넘긴다. 계정 서버는 구역을 열어 쥐고 자기 표만 서빙한다. 이 층의 표는 `GET /health` 하나다. 세부는 표 아래 S1a-1 범위다. | §5.1, §8.2 | S1a-0, D4 |
| S1a-2 | 구역을 읽는 곳이 구역의 멈춤을 본다. 로그가 멈췄거나 저장소와 어긋난 구역에서는 세션·PAT 인증과 나머지 읽기가 거절한다. | §5.1, §8.2 | S1a-1 |
| S1a-2b | 계정 서버가 연 구역을 한 번 더 읽고, 믿을 수 없으면 부팅을 멈춘다. 준비 상태를 probe로 답한다. 표는 검사를 거친 타입으로만 ingress에 간다. 세부는 표 아래 S1a-2b 범위다. | §5.1, §8.2 | S1a-2 |
| S1a-2b-1 | 구역이 기록하지 못한 사유를 사람에게 답할 때 서버의 파일 경로를 싣지 않는다. 사유는 구역이 로그에 쓴다. 세부는 표 아래 S1a-2b-1 범위다. | §5.1, §8.2 | S1a-2b |
| S1a-2c | 부팅이 계정 mode를 단일 사용자의 시작 정리보다 먼저 판정한다. 다계정 설치의 부팅과 거절된 부팅은 단일 사용자의 Keeper 상태를 정리하는 코드를 지나지 않는다. 세부는 표 아래 S1a-2c 범위다. | §5.1 | S1a-2b-1 |
| S1a-2d | 계정 서버가 자기가 듣는 포트를 host에 알린다. `masc restart`가 그 알림으로 계정 서버를 알아보고, 멈추고, 바꾼다. 세부는 표 아래 S1a-2d 범위다. | §5.1 | S1a-2c |
| S1a-2e | 나머지 운영 명령(`masc setup-server`, `masc setup`, `masc setup-stop-previous-owner`)과 설치 스크립트가 계정 서버를 알아본다. 그 전까지 `masc setup-server`는 계정 서버가 듣는 포트를 `unknown_server`로 답하고, 설치 스크립트는 그 답을 다른 서비스로 읽어 다른 포트를 권한다. | §5.1 | S1a-2d |
| S1a-3a | C3의 로그인 경로(로그인 시작·callback, 로그아웃, 세션, allowlist, PAT)를 계정 서버의 표에 단다. login client는 부팅이 판정한 `config.json`에서 읽는다. 세부는 표 아래 S1a-3a 범위다. | §5.1 | S1a-2e, F3a-3 |
| S1a-3a-1 | 진행 중인 로그인을 서버에 저장하지 않고 transaction 쿠키에 봉인한다. 인증 없는 로그인 시작이 다른 사람의 로그인을 막지 못한다(#51394). 세부는 표 아래 S1a-3a-1 범위다. | §5.2 | S1a-3a |
| S1a-3b | 사람의 화면과 경로(초대 입장, 구독 연결, Runtime·Keeper, Keeper에게 묻기)를 계정 서버의 표에 단다. 설계 §11.1의 1단계 개시 증거를 이 층에서 모은다. | §5.1, §11.1 | S1a-3a-1 |
| S1b-1a | 계정 서버가 사람의 MCP endpoint(`POST /mcp`)를 연다. 요청마다 PAT나 세션을 판정하고 MCP 세션을 만들지 않는다. 도구는 내 정보 하나다. 세부는 표 아래 S1b 범위다. | §5.2, §5.3 | S1a-3b |
| S1b-1b | MCP 도구에 내 Runtime 목록과 내 Keeper 목록·만들기·배정을 더한다. | §5.3 | S1b-1a |
| S1b-1c | MCP 도구에 내 Keeper의 한 턴을 더한다. | §5.3 | S1b-1b |
| S1b-1d | 실제 MCP client로 붙여 본 기록과 사용 안내를 남긴다. | §11.1 | S1b-1c |
| S1b-2 | 사람에게 Board·WebSocket 경로를 연다. 누가 읽고 쓰는지는 설계 절을 먼저 써서 정한다. | §11.1 | S1b-1d, C4-11, C4-12, C6 |

- S1이 D4 뒤인 까닭: 계정 층 없이 다계정 설치를 서빙하면 여러 사람이 소유한 기록을 한 사용자처럼 서빙한다. 그 계정 층의 마지막이 D4다. D1이 소유권을, D2~D4가 실행 진입마다 인가를 검사하고, D3이 lane마다 다른 owner의 account-home을 읽지 못하는 증거를 남긴다. 그 전에 다계정 설치를 서빙하면 C4를 통과한 사용자가 다른 사람의 Runtime과 Keeper를 쓴다.
- S1이 F3a 뒤인 까닭: S1부터 다계정 설치는 계정이 가진 Runtime·Keeper 기록을 쌓는다. 그때 "지우고 설치"는 그 기록을 지운다. 끄는 길 없이 켜는 길만 열면 실제 설치가 되돌릴 수 없이 다계정으로 넘어간다(§6 결정 10).
- S1a-3 전에는 실제 서버에 사람이 들어올 경로가 없다. C2a~D4의 코드는 시험과 `masc auth preview`가 구역을 직접 열어 부르고, 실제 서버에서 로그인부터 Keeper 실행까지 잇는 확인은 S1a-3에서 처음 한다.

**S1a-1 범위**

- 판정과 넘기기. `Authz_boot_mode_read.boot`가 `Single_user`나 `Multi_account`를 돌려준다. `Multi_account`는 base path와, 판정이 읽은 외부 저장소의 경로를 싣는다. `Server_runtime_bootstrap.run`이 그 값으로 갈라, 단일 사용자는 `run_single_user`로, 다계정은 `Server_accounts.run`으로 보낸다.
- 계정 서버가 따로인 까닭. 단일 사용자 서버의 경로는 `Server_auth`의 래퍼로 인증하고, 그 래퍼는 단일 사용자의 credential을 읽는다. 부팅 거부만 거두면 그 경로가 전부 단일 사용자의 token으로 열린다. 경로 등록 호출이 `lib/server`에 409개라서(2026-11-10 `rg` 집계) 하나씩 닫으면 빠뜨린 곳을 컴파일러가 잡지 못한다. 계정 서버는 표를 따로 가진다. 달지 않은 경로는 router의 404다.
- 표에 들어가는 종류. `Always_public`과 `Self_authenticated Browser_session`뿐이다. 나머지 종류는 단일 사용자의 credential을 읽는다(`Server_auth`의 래퍼를 거치거나 handler가 직접 읽는다). `Server_accounts.run`은 듣기 전에 표를 검사하고(`Server_account_table.checked`), 다른 종류가 있으면 부팅을 멈춘다. 검사는 `Route_access.t`의 생성자를 모두 적은 `match`다. 종류가 늘면 컴파일러가 이 판정을 다시 묻는다.
- 요청이 지나는 길. HTTP/1.1과 HTTP/2가 같은 표를 같은 ingress로 거친다(`Server_http_ingress.serve_table`). Host 검사와 주소별 rate limit은 단일 사용자 서버와 같은 코드다. agent별 rate limit, MCP 검사, workspace 전제 검사는 걸지 않는다. 셋 다 단일 사용자의 credential이나 owner 상태를 읽는다. 처리 중 예외가 나면 500의 본문에 예외 글을 싣지 않는다. 예외 글에 서버의 파일 경로가 들어갈 수 있다.
- 띄우지 않는 것. owner 상태(`Mcp_server.server_state`), Keeper, 단일 사용자 서버의 경로다. 그래서 단일 사용자로 쓰던 설치를 다계정으로 켜면 그 설치의 Keeper는 돌지 않는다. 운영자의 Keeper를 사람에게 귀속하는 층이 생기기 전에는 base path를 따로 둔 설치로 다계정을 시작한다.
- 8행(`Multi_account_uncertain`)은 부팅을 멈춘다(`Authorization_uncertain`). 설계 §5.1 표는 이 행을 "`AuthorizationUncertain`으로 시작한다"고 적는다. 그 상태에서 서빙할 것은 recovery(F3b)이고 2단계다. 그때까지는 열 경로가 없어서 듣지 않는다.
- 구역의 열기. 구역은 7행에서만 연다. 판정과 열기 사이에 파일이 바뀌어 열기가 실패하면(`Zone_not_opened`) 부팅을 멈춘다.
- stdio는 다계정 설치를 거절하고 끝난다. stdio runtime은 단일 사용자의 owner 상태다.
- `/health`는 `server`, release 버전(`version`), `account_mode` 세 칸만 답한다. 인증 없이 누구나 부르므로 빌드 기록(`Build_identity`: 실행 파일과 checkout의 경로, commit, 시작 시각), workspace의 경로, Keeper 수는 싣지 않는다. 실제 바이너리로 띄워 본 첫 답에 빌드 기록의 경로가 실려 있어서 뺐다(2026-11-10).
- 문구. `masc auth bootstrap`의 도움말·성공 문구와 5행 부팅 문구(`Activation_requested`)가, 활성화한 설치를 서버가 다계정 설치로 띄운다고 말한다.
- 시험.
  - `test_server_accounts`: 실제 `Fresh_bootstrap`으로 만든 설치를 부팅 진입(`boot`)에 넣고, 그 값으로 계정 서버를 loopback 포트에 띄워 HTTP/1.1로 부른다. `GET /health`는 200이고 `account_mode`가 `Multi_account`다. 답의 칸은 `account_mode`·`server`·`version` 셋뿐이고 값은 모두 문자열이다. 단일 사용자 서버의 경로 여섯(dev-token, status, MCP의 POST·DELETE, WebSocket, 루트)은 404다. 표에 없는 메서드는 405, listener가 아닌 Host는 400이다.
  - 같은 파일의 표 검사: 계정 서버의 표와 `Browser_session` 경로는 통과하고, `Read_auth` 경로와 dev-token 종류는 거절한다.
  - `test_authz_boot_mode_read`: 7행은 `Boot_multi_account`다. 진입은 판정이 읽은 저장소 경로를 싣는다. 익명 쓰기가 켜져 있으면 거절한다. 8행은 `Authorization_uncertain`으로 멈춘다.
- 하지 않는 것: 구역의 멈춤을 읽는 일(S1a-2), 로그인 경로와 사람의 경로(S1a-3), `masc auth preview`를 계정 서버 코드로 옮기는 일(S1a-3), Keeper lane, MCP(S1b).

**S1a-2 범위**

- 믿을 수 있는 읽기. `Authz_zone.read`는 구역을 믿을 수 있을 때만 snapshot을 준다(`Authz_zone.trusted`). 로그나 외부 저장소가 멈췄을 때, 두 파일이 어긋날 때, 저장소에 답이 없을 때는 그 사유(`uncertain`)를 준다. `commit`이 진입에서 하는 판정을 구역이 메모리에 가진 값으로 한다. 파일은 읽지 않는다.
- 타입으로 묶은 곳. 세션·PAT·Service credential 인증(`authenticate`), 브라우저 요청 검사(`Authz_browser_request.check`), gate(`Auth_gate.decide`), Keeper 턴 판정(`Authz_keeper_turn.decide`)이 `Authz_zone.trusted`를 받는다. `trusted`는 `read`만 만든다. 그래서 이 함수들에는 멈춘 구역의 상태를 넘길 수 없다.
- 거절하는 곳과 답.
  - 로그인(`Authz_login.sign_in`)은 `Uncertain`으로 거절한다. 이미 묶인 사람의 로그인도, 초대나 allowlist로 들어오는 입장도 같은 답이다.
  - 사람의 경로(who-am-I, 세션 읽기, 로그아웃, 구독 연결·검증, Runtime·Keeper, Keeper에게 묻기)는 503과 고정 문장 하나로 답한다(`Login_routes.zone_uncertain`). credential을 읽기 전에 답한다. 사유에는 서버의 파일 경로가 들어 있어서 로그에만 쓴다. 이 문장은 구역을 읽고 거절하는 답의 것이다. commit이 실패한 답은 S1a-2b-1이 같은 규칙으로 맞춘다. 로그아웃의 503은 쿠키를 지우지 않는다. 파일을 다시 읽은 뒤에는 그 세션이 살아 있을 수 있다.
  - CLI 시작(`Runtime_account_access`의 `Own_account`와 `Keeper_turn`)은 `Zone_uncertain`으로 거절한다. 요청 하나를 snapshot 하나에서 판정한다. 사람, 턴, 홈을 같은 상태에서 읽는다. 상태를 읽지 않는 거절(`No_operator`, `Not_a_keeper_id`)은 전과 같다.
- Keeper 턴 판정은 snapshot 하나에서 끝난다. 상태와 회수 보류를 같은 snapshot에서 읽으므로 둘 사이에 레코드가 끼지 않고, 다시 판정하는 고리가 없다. 회수 보류는 `Authz_state.revocation`이 답한다.
- 세션과 PAT 인증은 사람의 회수 보류도 본다(`Principal_revocation_pending`). 사람에게 보류를 거는 레코드는 셋이다. 정지, 삭제, Admin 지정 회수다(`Authz_state`의 `principal_event`와 `admin_assignment`). 셋 중 하나가 로그에 닿지 못하고 포기되면 그 사람은 상태에서 아직 활성이다. 로그인은 이 보류로 거절하고(`Blocked`), 그 사람의 세션과 PAT도 같은 보류로 거절한다. Admin 지정 회수는 기록되면 Admin 권한만 거둔다. 포기된 동안에는 그 사람의 로그인·세션·PAT이 모두 막힌다. 막는 쪽으로 넓다.
- `Authz_zone.snapshot`은 쓰는 쪽이 본다. 제품 코드에 남은 호출은 9곳이다. 9곳 모두 읽은 값만으로 무언가를 허용하지 않는다. 읽은 값은 뒤따르는 `commit`이 다시 판정한다. 그 `commit`은 같은 함수에 있거나, 그 함수를 부른 쪽이나 그 함수가 부르는 쪽에 있다. `commit`이 진입에서 다시 판정하므로 멈춘 구역에서는 거절이나 commit 실패로 끝난다. 이 규칙을 지키는 것은 타입이 아니라 아래 확인 명령이다.
  - 입장 2곳(`Authz_login`의 `admission`과, commit 실패 뒤 로그가 움직였는지 보는 곳)
  - 세션 교체(`Login_routes.still_acting`)
  - id 다시 뽑기 4곳(`Authz_allowlist`, `Authz_browser_session`, `Authz_service_credential`, `Authz_pat`)
  - Keeper 쓰기 전 검사(`Authz_keeper.write`)
  - 끄기(`Authz_off.turn_off`)
  - 확인 명령: `rg -n "(Authz_zone|Z)\.snapshot [a-z(]" lib bin --type ocaml`. 이 목록에 없는 줄이 나오면 그 줄이 `commit` 없이 무엇을 허용하는지 본다.
- 시험.
  - `test_authz_zone`: `read`가 네 사유를 하나씩 낸다(로그가 멈춘 구역, 저장소가 멈춘 구역, 두 파일이 어긋난 구역, 저장소에 답이 없는 구역). 믿을 수 있는 구역에서는 회수 보류를 그 snapshot의 상태에서 읽는다.
  - `test_authz_browser_session`, `test_authz_credential_auth`: 로그가 멈춘 구역에서는 이미 받은 세션 쿠키, PAT, Service credential이 판정에 닿지 못한다. 사람을 정지하는 레코드가 포기되면 그 사람의 세션이 `Principal_revocation_pending`으로 거절된다. PAT 쪽의 같은 거절은 시험하지 않는다. PAT를 발급하는 제품 경로가 아직 없다.
  - `test_authz_login`: 멈춘 로그에서는 이미 묶인 사람도, 유효한 초대를 든 새 사람도 `Uncertain`이다.
  - `test_server_login_http`: Admin이 로그인한 설치의 로그를 멈춘다. who-am-I, 세션 읽기, 구독 목록, Keeper 목록과 만들기, 로그아웃, 새 로그인이 503이다. credential이 없는 who-am-I도 503이다. 답의 본문에 서버의 경로가 없고, 브라우저의 세션 쿠키는 남는다.
  - `test_runtime_account_access_multi`: 멈춘 구역에서 자기 계정 요청과 Keeper 턴이 `Zone_uncertain`이고, 운영자 호출은 전처럼 `No_operator`다.
  - 실제 바이너리(2026-11-10): 임시 설치에 `masc auth preview`를 띄워 믿을 수 있는 구역의 답이 전과 같은지 봤다. credential 없는 사람의 경로는 401, 첫 화면은 200, 다른 Host는 400이다. 멈춘 구역은 실제 바이너리로 만들지 못했다. 구역은 자기가 쓸 때 멈춤을 알고, 로그인 없이는 쓰게 할 길이 없다.
- 남는 한계. 다른 프로세스가 파일에 쓴 것은 구역이 그 파일에 다음으로 쓸 때 안다. 그 전까지 `read`는 snapshot을 준다. 읽을 때마다 파일을 보는 일은 이 층이 하지 않는다.
- 하지 않는 것: `commit`이 읽기·판정·쓰기를 한 잠금 안에서 하게 바꾸는 일(읽은 뒤 commit까지의 경합은 지금처럼 다시 읽어서 푼다), 계정 서버의 표에 경로를 다는 일(S1a-3).

**S1a-2b 범위**

- 연 구역을 한 번 더 읽는다. 부팅 판정은 파일을 읽고 손잡이를 버린다. 계정 서버는 같은 경로로 구역을 다시 연다. 그 사이에 외부 저장소나 로그가 바뀌면, 다시 판정했을 때 멈출 설치가 그대로 듣는다. `Server_accounts.run`은 구역을 연 뒤 `Authz_zone.read`로 읽는다. 믿을 수 없으면 `Zone_not_trusted`로, 로그의 모드가 `Multi_account`가 아니면 `Zone_not_multi_account`로 멈춘다. 포트를 묶기 전이고 access를 발행하기 전이다. 다시 보는 것은 로그와 외부 저장소다. install record와 `config.json`은 다시 읽지 않는다. 구역은 판정이 읽은 저장소 경로로 열고, 모드는 로그의 모드를 따른다.
- 없는 저장소는 열지 않는다. 로그는 있고 저장소가 없으면 `Authz_zone.open_at_start`가 `Store_not_there`로 거절한다. 파일을 여는 쪽은 폴더와 lock 파일을 만들기 때문에, 열기 전에 `Authz_presence`에 묻는다. 빠진 볼륨의 mount point에 아무것도 남기지 않는다. 비어 있는 저장소는 열리고 `Zone_not_trusted`로 멈춘다. 물어본 뒤 여는 사이에 저장소가 사라지면 여는 쪽이 폴더와 lock 파일을 만든다. 그 구역은 빈 저장소로 열리고 같은 사유로 멈춘다. 이 틈은 함수 호출 몇 번 길이이고, 부팅 판정의 읽기에도 있다.
- `run`의 순서. HTTP mode 읽기 → 구역 열기 → 구역 다시 읽기 → 표 검사 → HTTPS 재료 → 포트 묶기 → access 발행 → HTTPS 포트 묶기 → trust policy → 포트 기록 → 준비 알림 → 받기 시작. `refusal`의 생성자 순서가 이 순서다. 거절은 모두 연결을 받기 전이고 포트를 기록하기 전이다. access는 요청을 처리하기 전에 발행된다. 묶인 포트에 먼저 온 연결은 받기 시작할 때까지 backlog에서 기다린다. 거절된 부팅이 디스크에 남기는 것은 하나다. 표 검사 뒤의 HTTPS 재료 단계는 HTTPS listener가 켜져 있고 인증서 파일을 지정하지 않았을 때, `<base>/.masc/tls/`의 자체 서명 짝이 없거나 읽을 수 없거나 갱신할 때가 됐으면 새로 만들어 쓴다. 프로세스에 남는 것은 넷이다. HTTP 설정 단계가 쓴 환경 변수(`MASC_HOST`, `MASC_HTTP_PORT`, `MASC_URL`, 없거나 공백뿐이면 `MASC_HTTP_BASE_URL`), HTTPS listener의 metrics, 스위치가 끝날 때까지 묶여 있는 소켓, `Trust_policy_refused`일 때 이미 발행된 access다. 부르는 쪽은 거절에서 프로세스를 끝낸다.
- 표의 타입. `Server_account_table.t`는 검사를 통과한 표이고 `checked`만 만든다. router는 등록이 제자리에서 바꾸는 공용 표이고, 등록 함수는 받은 router를 쥘 수 있다. 그래서 `checked`는 경로를 본 뒤 router의 사본(`Http_server_eio.Router.copy`)을 표로 삼는다. 사본은 이 모듈 밖에서 쥔 곳이 없다. 검사 뒤에 등록한 경로는 종류가 무엇이든 표에 없고, 표의 경로를 바꾸지도 못한다. 종류는 등록이 적은 값이다. 받는 종류로 적은 handler가 다른 router로 다시 dispatch하면, 그 router의 경로는 검사를 지나지 않는다. 표 ingress(`Server_http_ingress.serve_table`, `http1_table_handler`, `Server_h2_gateway.make_table_request_handler`)는 이 타입을 받고, 단일 사용자 ingress는 router를 받는다. listener를 다른 쪽 ingress에 묶은 코드는 컴파일되지 않는다.
- probe. 표에 `GET /health/live`와 `GET /health/ready`가 더해진다. live는 listener가 답하면 200이다. ready는 구역을 믿을 수 있으면 200이고 아니면 503이다. 구역을 믿을 수 없으면 사람의 경로가 전부 503이므로(S1a-2), probe를 읽는 쪽이 이 서버를 빼게 한다. 두 답은 host나 프로세스의 것을 싣지 않는다. 단일 사용자 서버의 ready가 싣는 pid도 없다.
- 설정 오류의 자리. HTTP mode(`MASC_USE_H2`)를 `run` 첫머리에서 읽는다. 어휘에 없는 값이면 파일을 열기 전에 `Http_mode_refused`로 멈춘다.
- listener. cleartext listener가 묶이지 않으면 `Listener_not_bound`로 멈춘다. Eio의 posix backend와 linux backend는 TCP bind의 `Unix.Unix_error`를 그대로 올린다(설치된 `eio_posix/net.ml`과 같은 소스의 `eio_linux.ml`에서 확인). 그래서 그 예외를 잡는다. Eio의 인터페이스는 어떤 예외를 올리는지 약속하지 않는다. 그래서 잡는 곳을 함수 하나(`Server_bootstrap_http.listen_tcp_result`)에 두고, `masc auth preview`의 bind도 그 함수를 지난다. 포트가 쓰이는 중인 사례가 그 함수를 지나므로, Eio가 올리는 예외가 바뀌면 그 사례가 실패한다. 거절이 다 지난 뒤 포트를 기록한다(`Workspace_connection.save`). workspace의 CLI가 포트를 받지 않아도 찾는다. `Trust_policy_refused`는 묶은 뒤에 난다. 정책이 실제로 묶인 HTTPS 포트를 이름으로 삼는다.
- 문구. bootstrap의 성공 문구와 도움말이 문장 하나(`Masc_cli_auth.account_server_line`)를 같이 쓴다. 계정 서버와 단일 사용자 서버가 같이 쓰는 것(listener 코드, Host·Origin 입장, 주소별 제한, HTTP 설정)을 `Server_accounts`의 인터페이스가 이름으로 적는다.
- 시험.
  - `test_server_accounts`: 판정이 끝난 설치로 계정 서버를 띄운다.
    - `MASC_USE_H2`가 어휘 밖이면 `Http_mode_refused`로 멈추고, 포트가 기록되지 않는다. 저장소를 지운 설치로 재서, 구역을 열기 전에 멈추는 것을 본다. 이 값은 한 번 읽히면 프로세스에 고정되고(`configure_h2_from_env`), 어휘 밖의 값은 고정되지 않는다. 그래서 이 사례가 mode를 읽는 사례들보다 앞에 온다.
    - 외부 저장소가 없으면 `Zone_not_opened`(저장소가 없음)로 멈추고, 그 자리에 폴더가 생기지 않는다.
    - 외부 저장소가 비어 있으면 `Zone_not_trusted`(저장소에 답이 없음)로 멈춘다.
    - 멈춰야 할 부팅이 듣기 시작하면 기다림이 30초에 끝나고 시험이 실패한다.
    - Off를 기록하면 `Zone_not_multi_account`(off)로 멈춘다.
    - 다른 소켓이 듣는 포트면 `Listener_not_bound`로 멈추고, 포트가 기록되지 않는다.
    - 뜬 서버는 `/health/live`에 `{"live":true}`, `/health/ready`에 `{"ready":true}`로 답하고, 답 전체를 비교한다. workspace가 기록한 포트가 listener의 포트다.
    - 표 종류 검사는 `Server_account_table.checked`로 본다. 검사 뒤에 router에 등록한 경로는 표에 없다. 그 경로는 `GET`도 `POST`도 404이고, 표의 경로와 같은 자리에 등록해도 표의 경로가 그대로 답한다.
  - `test_authz_boot_mode_read`: 단일 사용자 진입은 `Single_user`이고 꺼진 계정이 없다. 거절은 사유의 글을 비교한다(활성화 요청, 익명 쓰기). 8행은 `boot` 진입으로도 판정이 내는 줄 전부로 멈춘다. 8행의 문구는 어긋난 사유마다 한 줄이다.
  - `test_authz_zone`: 저장소 파일이나 그 폴더가 없으면 `Store_not_there`로 거절하고, 그 자리와 로그가 그대로다. 저장소 경로를 볼 수 없으면 `Store_not_checked`다. 비운 저장소는 열리고 commit을 모두 거절한다.
- 남는 한계. ready의 503은 이 층의 계정 서버에서 나지 않는다. 구역은 자기가 쓸 때 멈춤을 알고, 이 층의 표에는 쓰는 경로가 없다. 쓰는 경로는 S1a-3이 단다.
- 하지 않는 것.
  - listener 오류 처리기가 예외 글을 본문에 싣는 것. 두 서버가 같이 쓰는 코드이고, HTTP/2 쪽은 `test_h2_response_window`가 그 글의 길이에 기댄다. 계정 서버는 handler 예외에 고정 문구를 답하므로, 남는 길은 입장 단계에서 난 예외다. 이슈 #50613에 적었고, S1a-3 전에 정한다.
  - 연결 수 상한과 첫 바이트 제한 시간(#51096).
  - `Boot_multi_account`가 저장소 경로를 싣게 하는 일. 판정표가 파일 값을 알게 된다. 표가 내지 않는 짝(`Multi_account`인데 저장소를 못 읽음)은 부팅 거절로 남는다.
  - 부팅 순서(S1a-2c)와 운영 명령(S1a-2d).
  - 받기 고리와 포트 기록을 한 벌로 합치는 일. `Server_accounts`의 `serve`·`record_port`는 단일 사용자 부팅의 `run_serving`과 같은 줄이다. 단일 사용자 쪽은 HTTP 서빙을 다른 도메인으로 옮기는 작업이 고치는 중이라 지금 합치지 않는다. 연결 수 상한(#51096)을 넣을 때 한 함수로 합친다.
  - 설정만으로 아는 trust policy 거절(`MASC_HTTP_BASE_URL`의 형식)을 포트를 묶기 전에 보는 일.

**S1a-2b-1 범위**

- 고치는 것. commit이 실패한 요청의 답에 서버의 파일 경로가 실렸다. 다른 writer가 로그를 움직인 뒤 처음 쓰는 요청이 그 답을 받았다. 로그아웃(`Login_routes.logout`), allowlist 등록·삭제(`Login_allowlist_routes`), 구독 연결(`Server_setup_account_login`) 세 곳이다. 그 사유는 로그에도 남지 않았다. Keeper 만들기와 Runtime 기록 두 곳은 호출처가 따로 막고 있었다. 다섯 곳 중 둘만 막은 상태였다.
- 문장은 구역이 정한다. `Authz_zone.error_to_string`은 사람에게 줄 수 있는 문장이다. 레코드가 거절된 경우(`Refused`, `Record_not_built`, `Log_holds_records`)는 사유를 말한다. 그 밖은 구역의 실패이고 고정 문장 하나다("The server could not finish recording this. Try again later."). 사람은 그 사유로 할 수 있는 일이 없고, 사유에는 서버 경로가 들어갈 수 있다. `Authz_zone.error_detail`은 경로가 든 전체 사유다. 운영자가 읽는다. 둘을 가르는 판정은 `error`의 생성자를 모두 적은 `match` 하나다(`cause`). 생성자가 늘면 컴파일러가 이 판정을 다시 묻는다.
- `uncertain`도 같다. `uncertain_to_string`은 네 사유 가운데 무엇인지만 말한다. `uncertain_detail`이 경로와 파일 오류를 싣는다. `Runtime_account_access`의 `Zone_uncertain` 거절 문장은 `uncertain_to_string`을 쓴다. 그 문장을 쓰는 곳들도 경로를 싣지 않게 됐다.
- 사유는 구역이 로그에 쓴다. `Authz_zone.commit`이 실패를 돌려주면 두 잠금을 나온 뒤 `error_detail`을 WARN 한 줄로 쓴다. 거절된 레코드는 쓰지 않는다. 예외가 그 호출을 빠져나가는 경우도 쓰지 않는다. 구역은 자기가 쓸 때 파일의 멈춤을 안다. 그래서 멈춘 사유가 그 commit의 줄에 남는다. 로그인 콜백처럼 사유를 버리는 호출처에서도 남는다.
- 운영자가 읽는 곳은 전체 사유를 쓴다. `masc auth off`(`Authz_off`), `masc auth bootstrap`과 `invite`(`Authz_bootstrap`, `Authz_activation`), 계정 서버의 부팅 거절(`Server_accounts`의 `Zone_not_trusted`), 요청 거절의 로그 줄(`Login_routes.zone_uncertain_message`)이다. Keeper 만들기와 Runtime 기록의 로그 줄도 같다. 두 모듈의 문장은 서버 로그에서만 읽는다. 그래서 `Authz_keeper`와 `Authz_runtime`은 `error_to_string`을 두지 않고 `error_detail`만 낸다. 사람에게는 호출처가 자기 고정 문장을 답한다.
- 사람 쪽 여섯 모듈은 고치지 않았다(`Authz_login`, `Authz_allowlist`, `Authz_browser_session`, `Authz_service_credential`, `Authz_provider_account`, `Authz_pat`). `Commit_failed`의 문장을 `Authz_zone.error_to_string`에서 받는다. 새로 생기는 호출처도 같은 문장을 받는다.
- 시험.
  - `test_authz_zone`: 거절된 레코드는 두 문장이 같고, 구역은 그 거절을 로그에 쓰지 않는다. 다른 손잡이가 로그를 움직인 뒤의 commit은 `Record_not_appended Diverged`다. `error_to_string`은 고정 문장이고 `error_detail`에 로그 경로가 있다. 그 commit 뒤에 구역이 쓴 WARN이 한 줄 있고 경로를 싣는다. `read`의 사유는 `uncertain_to_string`에 경로가 없고 `uncertain_detail`에 있다.
  - `test_authz_zone`: `error`의 생성자 13개를 손으로 만든다. 실패 10개는 고정 문장이다. 그중 경로를 싣는 7개는 `error_detail`에 그 경로가 있다. 거절 둘(`Log_holds_records`, `Record_not_built`)은 두 문장이 같다. 남은 거절(`Refused`)은 위 사례가 실제 commit으로 본다.
  - `test_server_login_http`: Admin이 로그인한 뒤 로그에 다른 writer의 바이트를 붙인다. 그 뒤 첫 요청인 로그아웃이 503과 고정 문장으로 답하고, 본문에 서버 경로가 없다. 새 설치에서 allowlist 등록도 같다. 구독 연결이 사람에게 주는 문장(`Authz_provider_account.error_to_string`)에 경로가 없다.
  - 시험 fixture가 실패를 알릴 때는 `error_detail`을 출력한다(30곳). 고정 문장으로는 왜 실패했는지 알 수 없다.
- S1a-2 리뷰에서 나온 나머지.
  - 요청마다 남는 WARN(`zone_uncertain_message`)은 그대로다. 멈춘 사유는 이제 commit의 줄에 한 번 남는다. 어긋난 채 열린 구역에서 로그인만 시도한 거절은 미리보기에서 여전히 로그에 없다. 계정 서버는 그런 구역으로 뜨지 않는다(S1a-2b).
  - 타입이 묶지 않는 자리와 시험이 없는 분기는 이슈 #51170에 적었다.
- 하지 않는 것.
  - 문장의 타입을 둘로 나눠 응답 본문이 `error_detail`을 못 받게 하는 일. 지금은 기본값이 안전한 쪽이고(`error_to_string`), 전체 사유는 이름을 골라 불러야 받는다.
  - `Login_allowlist_routes.error_status`가 `cause`를 쓰게 하는 일. 상태 코드는 셋으로 갈린다. 거절은 사유별이고, 만들 수 없는 레코드는 500이고, 실패는 503이다. 둘로 가르는 `cause`를 쓰면 나머지를 한 갈래로 묶는 `match`가 생긴다. 지금은 생성자를 모두 적는다. 생성자가 늘면 컴파일러가 두 곳에서 묻는다.

**S1a-2c 범위**

- 고치는 것. 서버 부팅(`masc start`)은 base path lease를 쥔 뒤 단일 사용자의 시작 정리를 먼저 돌리고, 그 뒤 서버 loop 안에서 계정 mode를 판정했다. 시작 정리는 넷이다. 보존 checkpoint 정리, checkpoint object 정리, 원본 요청 본문 목록, settled archive 정리다. 셋은 단일 사용자의 Keeper 상태에서 파일을 지우고, 원본 요청 본문 목록은 세기만 한다. 다계정 설치의 부팅과 거절된 부팅도 그 코드를 지났다.
  - 고치기 전 측정(2026-11-10 23:37Z, 트리 `67f56fb30a53`, 임시 설치): 다계정 부팅과 외부 저장소가 옮겨진 부팅 둘 다 `[Startup]` 정리 줄 넷이 판정보다 먼저 찍혔다. 거절된 부팅은 그 뒤에 줄 넷을 더 찍었다. FATAL, "the server stopped with an exception", "Unhandled exception", backtrace다.
- 순서. lease, 로그 파일 sink, 판정, 콘솔 mirror, 시작 정리(단일 사용자일 때만), 서버 순이다. 판정은 `Server_runtime_bootstrap.judge`다. auth 환경 설정(`Server_auth_config`)을 읽고 `Authz_boot_mode_read.boot`를 부른다. 한 부팅에 한 번 부른다.
- 판정은 자기 event loop 하나에서 돈다. `Authz_boot_mode_read.boot`의 인터페이스가 event loop 안에서 부르라고 적는다. 그 loop는 시작 정리와 서버의 loop보다 먼저 끝난다. 판정 결과는 값뿐이다. base path, 꺼진 계정의 상태, 저장소 경로다. 열어 둔 파일이나 잠금을 서버 loop로 넘기지 않는다.
  - 택하지 않은 길: 시작 정리를 서버 loop 안으로 옮기기. 정리 넷은 loop 밖에서 도는 코드다. 옮기면 지금 돌고 있는 단일 사용자 서버의 부팅 경로가 바뀐다.
- 타입 둘이 순서를 지킨다.
  - `judge`만 `judged`를 만든다(`private`). `run`은 `judged`를 받고 서버가 뜰 base path를 따로 받지 않는다. 판정을 건너뛴 부팅은 컴파일되지 않는다. 판정이 읽은 것과 다른 base path로 서버를 띄울 수도 없다. `?input_base_path`는 운영자가 친 경로 그대로다. 단일 사용자의 진단 정보에만 쓰고 아무것도 열지 않는다. 계정 서버는 쓰지 않는다.
  - 시작 정리(`sweep_single_user_state`)도 `judged`를 받고 그 안의 base path를 읽는다. 판정 전에는 넘길 값이 없고, 다른 base path를 넘길 수도 없다. 다계정 판정이면 아무것도 하지 않는다. 단일 사용자 판정값(`Authz_boot_mode_read.single_user`)을 받지 않는 까닭이 있다. host 도구용 판정(`Authz_boot_mode_read.tool`)도 그 값을 만든다.
- 거절. 판정이 멈추면 `[FATAL]` 한 줄을 쓰고 exit 1로 끝난다. 서버 loop에 들어가지 않는다. auth 환경 설정의 형식 오류(`MASC_ALLOW_ANONYMOUS_MUTATIONS`, `MASC_HTTP_DEV_MUTATION_ORIGINS`)도 같은 자리에서 한 줄로 멈춘다. 전에는 둘 다 서버 loop 안에서 예외로 나왔다.
  - 판정이 예외를 내도 `[FATAL]` 줄(예외 글과 backtrace)을 쓰고 exit 1로 끝난다. 서버 loop 안에서 판정하던 때와 같은 결과다. 잡지 않으면 명령줄 파서가 예외를 받아 stderr에 찍고 exit 125로 끝나며 로그에는 남지 않는다.
- Antigravity panelist의 임시 HOME 정리(`sweep_stale_antigravity_panel_roots`)는 옮기지 않았다. 전처럼 서버 loop 안에서 돌고 두 서버가 다 돌린다. 그 HOME은 base path 밖 호스트 임시 폴더에 있고, 죽은 프로세스가 남긴 OAuth 파일 사본을 담는다. 어느 서버가 뜨든 지워야 한다. 달라진 점은 하나다. 거절된 부팅은 서버 loop에 들어가지 않아서 이 정리를 돌리지 않는다. 다음에 뜨는 서버가 지운다.
- 판정보다 먼저 도는 것은 두 서버가 같이 쓴다. base path 만들기, lease, runtime events 준비, build identity, 로그 파일 sink, 오래된 로그 파일 정리다. 거절된 부팅이 새 base path에 남기는 파일은 둘이다. lease 파일과 그날의 로그 파일이다. 폴더는 `.masc/logs`, `.masc/runtime/events`, `.masc-owner/masc-base-path-leases-v1-<uid>`가 생긴다.
- 신호. SIGTERM·SIGINT 처리기는 서버 loop 안에서 단다. 판정과 시작 정리 동안 온 신호는 기본 동작으로 프로세스를 끝낸다. 시작 정리 동안은 전에도 그랬다. 판정 동안은 이 층에서 새로 그렇다. 전에는 판정이 처리기를 단 뒤에 돌았다. 판정이 쓰는 것은 `open_at_start`가 쓰는 둘뿐이다. 끝나지 않은 마지막 줄을 자르고, 로그와 저장소 옆에 lock 파일을 둔다.
- 할당 샘플러(`Alloc_profile`)는 자리를 그대로 뒀다. 시작 정리 뒤, 서버 loop 앞이다. 판정이 그 앞으로 갔으니 판정의 할당은 표에 없다. 서버가 계속 쥐는 판정값도 live 표에 나오지 않는다. 샘플러를 판정 앞으로 올리지 않은 까닭이 있다. 올리면 시작 정리의 할당이 단일 사용자 서버의 누적 표에 새로 섞인다. 계정 서버에는 그 표를 읽는 경로(`/api/v1/diagnostics/memprof`)가 아직 없다.
- stdio runtime(`bin/main_stdio_eio.ml`)은 이미 lease 바로 뒤에 판정한다. 바꾸지 않았다.
- 확인(실제 바이너리, 임시 폴더, 비운 환경, 2026-11-11 03:17~03:23Z, OCaml 5.5.2, 시험 묶음을 같이 돌려 부하가 있는 실행).
  - 다계정 설치: `[Startup]` 줄 0, probe 셋 200, `/api/v1/status` 404, SIGTERM 뒤 exit 0. 심어 둔 낡은 panelist HOME이 지워진다.
  - 외부 저장소가 옮겨진 부팅 40번: 모두 exit 1, 정리 줄 0, 콘솔에 FATAL 한 줄, 예외와 backtrace 줄 0이다. 설치의 파일 목록이 그대로다. 다시 심은 낡은 panelist HOME도 그대로다.
  - 거절 넷 더: auth 환경 설정이 boolean이 아닌 부팅(다계정 설치와 새 base path), bootstrap 전에 `Multi_account`를 청한 부팅, Off 뒤에 `Multi_account`를 청한 부팅. 모두 exit 1, 정리 줄 0, 콘솔에 FATAL 한 줄이다.
  - 판정이 예외를 낸 부팅: 연 파일 수 한도를 6과 7로 낮추면 판정의 event loop가 pipe를 못 만든다(`EMFILE`). 둘 다 `[FATAL]` 두 줄(예외 글, backtrace)을 쓰고 exit 1로 끝났다. 한도 5에서는 판정보다 앞선 로그 파일 sink가 같은 예외를 내고, 명령줄 파서가 받아 exit 125로 끝났다. 이 층이 고치지 않은 자리다.
  - 새 base path의 단일 사용자: 정리 줄 넷(경고 줄 0), `/health`·`/health/ready`·`/api/v1/status` 200이다. 낡은 panelist HOME이 지워진다. SIGTERM 뒤 exit 0이다.
  - `masc auth off` 뒤 `account_mode`를 뺀 설치: 단일 사용자로 뜨고 정리 줄 넷이다.
- 시험. 이 층의 새 시험은 없다. `judge`의 단위 시험도 없다. 순서는 `bin/main_eio.ml`의 `run_cmd`가 정하고, 그 함수는 프로세스 하나를 통째로 쓴다(lease, exec, 로그 sink, exit). 순서는 위 두 타입이 지키고, 실제 순서는 실제 바이너리로 봤다. `judge`가 부르는 `Authz_boot_mode_read.boot`에는 시험이 있다(`test_authz_boot_mode_read`).
- 콘솔. 콘솔 mirror(`Console_sink`)는 시작한 뒤부터 다른 thread가 줄을 쓰고, 프로세스가 끝날 때 남은 줄을 마저 쓰지 않는다. 그래서 mirror를 판정 뒤에 시작한다. 그때까지는 줄을 부른 쪽이 바로 쓴다. 거절 줄은 프로세스가 끝나기 전에 콘솔에 있다.
  - mirror를 판정 앞에서 시작한 트리로 재면 거절된 부팅 24번 중 3번이 콘솔에 줄을 못 썼다(2026-11-11 02:35~02:37Z, 같은 부하 조건). 로그 파일에는 24번 다 있었다. 부하가 없던 실행(01:28~01:30Z)에서는 24번 다 콘솔에 있었다.
  - 옮긴 뒤에는 같은 부하 조건에서 거절된 부팅 44번이 모두 콘솔에 줄을 썼다.
- 남는 한계. 서버 loop 안의 `[FATAL]` 자리들은 mirror를 지나므로 같은 유실이 날 수 있다. 계정 서버가 뜨지 못한 때의 줄이 그렇다. 로그 파일에는 exit 때 남은 줄을 마저 쓴다(`at_exit`).
- 하지 않는 것: 운영 명령(S1a-2d), 판정보다 먼저 도는 로그 파일 정리를 옮기는 일, 시작 정리 넷을 `bin` 밖으로 옮기는 일, 신호 처리기와 샘플러를 판정 앞으로 옮기는 일.

**S1a-2d 범위**

- 고치는 것. `masc restart`가 다계정 설치의 계정 서버를 알아보지 못했다.
  - 고치기 전 측정(2026-11-11 01:58~01:59Z, 임시 설치). 계정 서버가 떠 있으면 "Port N is held by a process that is not this workspace's MASC server."로 거절했다(exit 1). 서버가 없으면 계정 서버를 띄운 뒤 끝나지 않았다. 띄운 서버는 `/health/ready`에 200으로 답하고 있었다.
  - 까닭. `masc restart`는 `/health`가 싣는 workspace로 서버를 알아보고, `/health/ready`가 싣는 pid로 대체 서버가 떴는지 본다. 계정 서버의 probe는 둘 다 싣지 않는다(S1a-1, S1a-2b). 누구나 닿는 답이기 때문이다.
- 알림. 계정 서버는 자기가 듣는 포트를 kernel의 잠금 표로 host에 알린다.
  - 모양. lease 파일 옆의 파일(`<lease>.account-server`)에서 바이트 하나를 잠근다. 잠근 자리가 포트 번호다. 파일은 비어 있다. 다른 프로세스는 `F_GETLK`으로 그 포트의 바이트를 누가 쥐었는지 묻는다(`Owner_process_identity.byte_holder`, `Server_startup_takeover.account_server_port_holder`).
  - 묻는 범위. 판정에 쓰는 읽기는 포트 하나의 바이트만 묻는다. 쓰기 잠금은 바이트마다 주인이 하나다. 그래서 다른 프로세스가 다른 바이트에 건 잠금은 답을 가리지도 바꾸지도 못한다. 파일 전체를 묻는 읽기(`held_byte`, `account_server_announcement`)는 kernel이 잠금 하나만 말해 준다. 여러 프로세스가 잠갔을 때 어느 것을 말하는지는 정해져 있지 않다. 이 읽기는 "다른 포트를 알린다"는 안내에만 쓴다.
  - 기록이 곧 잠금이다. 쥔 프로세스가 끝나면 kernel이 잠금을 푼다. 디스크에 남아서 낡는 숫자가 없다. lease 모듈이 이미 같은 원칙을 쓴다. lease 파일에 적힌 pid는 참고이고 kernel의 잠금이 사실이다. 알림은 프로세스가 끝나거나, lease를 놓거나, exec할 때 끝난다. 알림의 fd는 exec를 건너지 않는다. exec로 넘기는 것은 lease 하나다. 지금 `masc start`의 exec는 계정 서버가 알리기 전에만 있다. 빈 파일은 남는다.
  - 실험(macOS 27.2 arm64, 2026-11-11). 읽기 전용으로 연 다른 프로세스가 잠근 pid와 자리를 받았다. 파일 크기는 0으로 남았다. 쥔 프로세스를 SIGKILL로 끝낸 직후에는 잠금이 없다고 답했다.
  - 계정 서버만 알린다. 단일 사용자 서버는 `/health`가 workspace를 싣고 admin credential로 멈춘다. 그 길은 바꾸지 않았다.
  - 알리는 자리. `Server_accounts.run`에서 부팅을 멈출 수 있는 검사가 모두 끝난 뒤다. 순서는 포트 묶기, HTTPS listener, trust policy, 알림, access publish다. 알림을 읽은 명령은 곧 serve할 서버를 읽는다. 알림 뒤에 거절할 수 있는 것은 publish 하나이고, publish는 이미 publish한 프로세스만 거절한다. 부팅은 한 번만 publish한다. 알리지 못하면 `Port_not_announced`로 부팅을 멈춘다. 알리지 못한 서버는 명령으로 바꿀 수 없다. access를 publish하기 전에 알리므로, 알림 거절은 다른 거절처럼 같은 시험 실행 파일 안에서 잰다.
  - 다른 프로세스가 그 포트의 바이트를 먼저 잠갔으면 알리지 못한다. 부팅이 `Port_not_announced`로 멈춘다.
  - 알림의 거절은 사유마다 타입이 있다. 포트가 아닌 수(`Announcement_port_invalid`), 두 번째 알림(`Announcement_already_made`), 놓은 lease(`Announcement_lease_not_active`), 다른 프로세스가 잠근 바이트(`Announcement_port_locked`)다. 마지막 것은 kernel이 말한 pid를 싣는다. 거절된 호출은 알림을 더하지도 거두지도 않는다.
  - 한 프로세스가 그 파일의 fd를 하나라도 닫으면 POSIX 잠금이 풀린다. 그래서 알린 프로세스는 그 파일을 다시 열지 않는다. 읽기는 경로의 문자열이 아니라 파일의 정체(장치와 inode)로 자기 알림을 찾고, 잠금을 쥔 그 fd로 묻는다. macOS는 한 폴더에 철자가 둘이다(`/private/tmp/X`와 `/System/Volumes/Data/private/tmp/X`). 문자열로 찾으면 다른 철자로 물은 읽기가 그 파일을 열고 닫아 알림을 떨어뜨린다. lease를 놓을 때는 알림을 먼저 거둔다.
  - 알림 파일은 lease 파일의 검사를 받는다. 읽는 쪽은 lease 파일을 열 때의 검사를 그대로 쓰고 파일을 만들지 않는다. 알리는 쪽은 자기가 쥔 lease 파일이 지금도 그 경로의 파일인지 본 뒤, 이 사용자의 이름 하나짜리 보통 파일만 받는다.
- 타입. `judged`가 lease를 싣는다(`judge ~lease`). `run`은 그 lease를 계정 서버에 넘긴다. 판정받은 부팅의 lease 없이는 알릴 수 없다.
- `masc restart`.
  - 관찰(`Server_upgrade_preparation.account_server`). kernel에 먼저 묻는다. lease 주인의 pid를 읽고, 청한 포트의 바이트를 쥔 pid와 맞춘다. 같고 `/health`가 200이면 멈출 계정 서버다. `/health`의 답은 떠 있는지 보고 버전을 읽는 데만 쓴다. 다르면 파일 전체를 물어 lease 주인이 다른 포트를 알리는지 본다. 알리면 거절하고 그 포트를 말해 준다. 청한 포트에서 답이 없으면 거절하고 pid를 말해 준다. lease 주인이 아무것도 알리지 않으면 전과 같은 단일 사용자의 길이다. lease 주인이 아닌 프로세스의 잠금은 어느 바이트에 있든 계정 서버로 읽지 않는다.
    - "이 포트의 계정 서버"라는 답은 포트의 바이트에서만 나온다. 파일 전체를 묻는 읽기는 다른 포트를 말하는 데만 쓴다.
    - kernel이 먼저인 까닭. 어느 정지 경로를 탈지는 lease 주인이 무엇을 알리는지가 정한다. 포트의 답이 정하지 않는다. 포트부터 물으면, 계정 서버가 주인인 설치에서도 그 포트에서 답하는 쪽이 단일 사용자의 로그인과 토큰 경로를 고르게 된다.
    - 대가. lease를 읽으면 private lease 폴더와 빈 lease 파일이 없을 때 생긴다. 그래서 거절로 끝난 명령도 그 파일을 남긴다. `masc start`가 만드는 파일이다. 그 위의 폴더(`.masc-owner`)는 이 층 전에도 이 명령이 만들었다. 잰 값은 아래 확인에 있다.
  - 멈춤(`Server_upgrade_preparation.stop_account_server`). kernel이 증명하는 lease 주인을 잡는다(`capture_existing_owner`). 청한 포트의 바이트를 쥔 pid가 그 주인의 pid인지 본다. 그 프로세스에 묶인 SIGTERM을 보낸다. pid가 다시 쓰였으면 보내지 않는다.
  - 준비. `/health/ready`가 200이고, 청한 포트의 바이트를 쥔 pid가 `masc restart`가 띄운 자식의 pid일 때다. 단일 사용자의 판정(답이 싣는 pid가 자식의 pid)은 그대로다. 규칙은 함수 하나(`Server_upgrade_preparation.replacement_sighting`)에 있다. 답이 pid를 실으면 kernel에 묻지 않는다.
- 결정: 계정 서버를 멈추는 권한은 host다.
  - 계정 서버에는 명령줄이 낼 admin credential이 없다. 계정은 브라우저로 로그인하는 사람이다. 그래서 `masc auth`의 명령들과 같은 권한을 쓴다. private lease 폴더를 가진 effective UID다. kernel이 lease 파일을 열 때와 신호를 보낼 때 그 UID를 검사한다.
  - `capture_existing_owner`의 계약은 "admin으로 인증한 뒤에 쓴다"였다. 서버 종류별로 고쳐 적었다. 단일 사용자 서버는 admin 인증, 계정 서버는 host 권한이다.
  - 대가. host에서 같은 UID로 도는 프로세스는 이 명령으로 계정 서버를 멈춘다. 그 프로세스는 이 명령 없이도 신호를 보낼 수 있다. 사람의 계정으로는 서버를 멈추지 못한다. Admin role도 같다. 그런 경로가 표에 없다.
- 택하지 않은 길.
  - `connection.toml`의 포트를 믿기. 그 값은 운영자가 바라는 포트이고, 지금 듣는 포트의 증거가 아니다.
  - lease 폴더에 pid와 포트를 적은 파일. 쓴 프로세스가 죽어도 내용이 남는다. 읽는 쪽이 낡았는지 다시 판정해야 한다.
  - `/health`에 base path의 digest를 싣기. 누구나 닿는 답에 workspace의 것을 싣게 된다.
  - 요청마다 nonce 파일을 증명하는 경로. 표에 경로가 하나 늘고, 그 경로가 요청마다 파일을 읽는다.
  - control Unix socket. 멈춤·상태·drain을 한 통로로 내는 장기 방향이다. 지금 넣으면 프로토콜 하나와 `sun_path` 길이 한도가 같이 든다.
  - 어느 프로세스가 어느 포트를 듣는지 kernel에서 열거하기. 플랫폼마다 방법이 다르다.
- 같은 UID의 프로세스. 같은 UID의 다른 프로세스도 그 파일의 바이트를 잠글 수 있다. 그래서 잠금 하나만으로는 아무것도 증명하지 않는다. 읽는 쪽은 잠근 pid를 다른 길로 아는 프로세스와 맞춰 본다. 관찰하고 멈출 때는 kernel의 lease 주인과, 준비를 볼 때는 자기가 띄운 자식과 맞춘다. 신호는 kernel의 lease 주인에게만 간다.
  - 다른 바이트의 잠금은 판정을 바꾸지 못한다. 판정은 청한 포트의 바이트만 묻는다.
  - 청한 포트의 바이트를 다른 프로세스가 먼저 잠갔으면 계정 서버가 그 포트로 뜨지 못한다(`Port_not_announced`). `masc restart`는 그 잠금을 계정 서버로 읽지 않고, 대체 서버의 거절을 로그의 마지막 줄로 보여 준다.
  - 처음 구현은 파일 전체를 물었다. 독립 리뷰가 짚었고(2026-11-11), 그 트리의 바이너리로 쟀다(06:04~06:06Z). 서버가 알린 뒤에 다른 프로세스가 바이트 7000을 잠그면 `masc restart`는 서버를 멈추고 대체 서버를 띄운 뒤 끝나지 않았다(60초 알람으로 끝냄). 대체 서버는 그동안 `/health/ready`에 200으로 답하고 있었다. 서버가 없을 때 그 잠금이 있으면 그 프로세스를 계정 서버로 읽어 "serves port 7000 … pass --port 7000"으로 거절했다. 포트의 바이트만 묻도록 바꾼 뒤에는 같은 순서에서 "Ready after 1.8 s"로 끝난다(exit 0).
- 남는 한계.
  - `masc restart`는 대체 서버가 뜰 수 있는지 미리 보지 않는다. 대체 서버의 부팅이 거절되면 서버가 없는 채로 끝난다. 명령은 exit 1로 끝나고 로그의 마지막 줄들을 보여 준다. 단일 사용자 서버도 같다.
  - 답하지 않는 계정 서버는 멈추지 않는다. 문구가 pid를 말해 준다.
  - 이 층 전의 바이너리로 뜬 계정 서버는 알림이 없다. `masc restart`는 전과 같은 문장으로 거절한다. 그 서버는 신호로 한 번 멈춘다.
  - "다른 포트를 알린다"는 안내는 가려질 수 있다. lease 주인이 아닌 프로세스가 그 파일에 잠금을 걸어 두면 kernel이 그 잠금을 먼저 말할 수 있다. 그때 명령은 단일 사용자의 길로 가서 그 길의 문장으로 거절한다. 멈추거나 띄우는 판정은 바뀌지 않는다.
  - 준비 판정의 200은 127.0.0.1에서 읽는다. `--host 0.0.0.0`으로 띄운 대체 서버는, host가 두 묶기를 다 받아 주면, 127.0.0.1의 같은 포트를 듣는 다른 프로세스와 포트를 나눠 쓸 수 있다. 그때 200은 그 프로세스의 답이다. 준비는 "대체 서버가 알렸고 포트가 답한다"까지를 말한다.
  - 한 프로세스가 lease를 쥔 채 그 lease 파일을 다른 철자로 다시 열면 lease의 잠금이 풀린다. lease의 표는 경로의 문자열로 찾는다. 이 층은 알림의 표만 파일의 정체로 찾게 했다. lease를 쥔 프로세스가 다른 철자로 묻는 호출은 지금 없다. `masc start`가 exec 뒤에 lease를 다시 잡는 길에도 자기 lease 파일을 열고 닫는 읽기가 있다. 둘 다 이 층 전의 코드다(#51285).
  - 단일 사용자 설치를 다계정으로 바꾼 직후의 `masc restart`는 코드로만 읽었다. 단일 사용자 서버를 그 서버의 credential로 멈추고, 띄운 계정 서버를 알림으로 준비 판정한다. 실제 바이너리로는 재지 않았다.
  - pid가 1인 프로세스는 주인으로 잡지 않는다. 기존 lease 주인 판정과 같다.
- 답을 기다리는 시간. HTTP client는 받은 시간 창만 건다. `masc restart`의 GET은 창을 주지 않았다. 연결은 받고 답은 하지 않는 서버에서 명령이 끝나지 않았다. 고치기 전 바이너리로 SIGSTOP으로 멈춰 둔 단일 사용자 서버에 재면 60초 뒤에도 끝나지 않았다(2026-11-11 04:25Z). 이 층은 이 명령의 GET 다섯 자리를 창 10초짜리 함수 하나(`get`)로 모았다. 단일 사용자의 관찰과 준비 확인도 그 함수를 쓴다. 그래서 단일 사용자 설치에서도 `/health`에 10초 안에 답하지 못한 서버는 "답하지 않는다"로 거절한다. `masc setup-server`와 단일 사용자 서버를 멈추는 요청에는 아직 창이 없다(#51253).
- 확인(실제 바이너리, 임시 폴더, 비운 환경, 2026-11-11 06:01~06:06Z, OCaml 5.5.2, 다른 빌드가 같이 돌던 실행).
  - 알림. 뜬 계정 서버의 알림 파일에 kernel이 답한 잠금은 한 바이트다. 자리가 포트이고 pid가 서버의 pid다. 파일 크기는 0이다.
  - 다른 포트를 청하면 "serves port P, not port Q"로 거절하고(exit 1) 서버는 그대로 돈다.
  - 떠 있는 계정 서버를 바꾼다. "Asked the account server masc 0.70.0 (pid N) on port P to stop." 뒤에 "Ready after 4.7 s"로 끝난다(exit 0). 멈춘 서버는 exit 0으로 끝났다. 포트의 바이트를 쥔 pid가 새 서버의 pid다.
  - SIGSTOP으로 멈춰 둔 계정 서버는 "announces port P and does not answer there"로 거절한다(exit 1). SIGCONT 뒤 그 서버는 그대로 답한다.
  - SIGKILL로 끝낸 직후 lease와 알림의 잠금이 둘 다 없다. 그 뒤 `masc restart`는 서버를 띄우고 "Ready after 5.9 s"로 끝난다(exit 0). 이 층 전에는 끝나지 않았다.
  - 알림 자리에 폴더를 두면 부팅이 "the port is not announced to the host"로 멈춘다(exit 1). 포트는 듣지 않는다. 폴더를 치우면 다시 뜨고 알린다.
  - 이 층 전의 바이너리로 띄운 계정 서버는 알림이 없다. `masc restart`는 전과 같은 문장으로 거절하고(exit 1) 그 서버는 그대로 돈다.
  - 단일 사용자 설치. 서버가 없을 때 띄우고(Ready 4.7 s), 떠 있는 서버를 바꾼다(Ready 7.6 s). 이 층 전의 바이너리와 같은 줄들이다(04:02Z, 5.1 s와 3.5 s). 알림 파일은 생기지 않는다. SIGSTOP으로 멈춰 둔 서버에는 11초 만에 "does not answer"로 거절한다.
  - 다른 프로세스의 잠금 옆. 같은 사용자의 프로세스가 알림 파일의 바이트 하나를 잠가 둔 채로 쟀다.
    - 다른 바이트(7000)를 먼저 잠근 때. 서버가 없으면 띄우고 "Ready after 4.1 s"로 끝난다(exit 0). 떠 있으면 바꾸고 "Ready after 3.1 s"로 끝난다(exit 0). 파일 전체를 물으면 kernel은 그 프로세스의 잠금을 말한다. 포트의 바이트만 물으면 서버의 pid를 말한다.
    - 서버가 알린 뒤에 다른 바이트를 잠근 때. 바꾸고 "Ready after 1.8 s"로 끝난다(exit 0).
    - 그 옆에서 다른 포트를 청하면 단일 사용자의 길의 문장("A process holds … but does not answer on port Q")으로 거절한다(exit 1). 서버는 그대로 돈다.
    - 포트의 바이트를 잠근 때. 계정 서버의 부팅이 "the byte of port P is locked by pid N"으로 멈춘다(exit 1). 포트는 듣지 않는다. `masc restart`는 띄운 서버가 exit 1로 끝난 것과 로그의 마지막 줄을 보여 주고 exit 1로 끝난다. 잠금이 사라지면 다시 뜬다(Ready 4.3 s).
    - 단일 사용자 설치에서 포트의 바이트를 잠근 때. `masc restart`는 평소처럼 서버를 바꾼다(Ready 4.7 s).
  - Ready까지의 시간은 부하에 따라 달랐다. 문구 둘만 다른 중간 트리로 잰 05:52~05:54Z 실행에서는 다계정 2.0~2.9 s, 단일 사용자 3.5~5.1 s였다.
- 시험.
  - `test_owner_process_identity`: 잠기지 않은 파일은 `None`이다. 자식이 바이트 9000을 잠그면 그 pid와 자리를 받는다. 자식을 끝내면 `None`이다. 파일 크기는 0이다. 두 프로세스가 서로 다른 바이트를 잠그면 바이트마다 그 주인을 받고, 그 사이의 바이트는 `None`이다. 파일 전체를 물으면 둘 중 하나를 받는다. 읽기 잠금과 두 바이트짜리 잠금은 바이트 잠금이 아니다(`None`). 음수 자리는 `Unavailable`이다. 잡은 주인의 `pid`는 자식의 pid다.
  - `test_server_startup_takeover`: 다른 프로세스가 알린 포트와 pid를 읽고, 그 프로세스가 끝나면 알림이 없다. 포트 65536과 두 번째 알림은 거절한다. 알린 프로세스가 자기 알림을 읽어도 잠금이 남는다. lease를 놓으면 알림이 없다. 알림 자리에 폴더가 있으면 알리는 쪽과 읽는 쪽 둘 다 거절한다. 읽기는 파일을 만들지 않는다. 서버보다 먼저 걸린 잠금과 나중에 걸린 잠금 옆에서 포트의 바이트는 서버의 pid를 답한다. 다른 프로세스가 먼저 잠근 포트는 알리지 못한다. 이름이 둘인 알림 파일은 알리는 쪽과 읽는 쪽 둘 다 거절한다. lease 경로가 다른 파일을 가리키면 알리지 않는다. 다른 철자로 물어도 자기 알림을 찾고 잠금이 남는다(철자가 하나인 host에서는 건너뛴다).
  - `test_server_accounts`: 뜬 계정 서버의 알림이 그 포트와 그 pid다. 알림 자리에 폴더가 있으면 `Port_not_announced`로 멈추고 포트가 기록되지 않는다. `/health`의 답에서 버전을 읽는다.
  - `test_server_upgrade_preparation`: lease를 쥔 프로세스가 없으면 `Owner_unavailable`이다. 주인이 알리지 않았거나 다른 포트를 알리면 `Incumbent_changed`이고 그 프로세스는 계속 돈다. 청한 포트를 알리면 SIGTERM으로 끝난다. lease 없는 프로세스가 포트의 바이트를 잠그면 계정 서버로 읽지 않고, lease 주인에게 신호를 보내지 않는다.
  - 변이. 자기 알림을 경로 문자열로 찾게 되돌리면 "다른 철자" 시험이 실패한다("no process holds the byte of the port").
  - `masc restart`의 흐름은 실제 바이너리로 봤다. 그 명령은 프로세스를 띄우고 기다린다.
  - 두 번째 리뷰(2026-11-11, 고친 트리). P2 둘과 P3 여섯이었고 모두 코드에서 확인했다.
    - 단일 사용자 설치에서 달라진 것 둘을 적지 않았다. 포트의 답을 10초까지만 기다린다. 포트에 묻기 전에 lease를 읽어서 거절로 끝난 명령도 빈 lease 파일을 남긴다. 순서는 위에 적은 까닭으로 그대로 두고 글을 고쳤다.
    - 거절이 남기는 것을 쟀다(07:23Z). 한 번도 뜬 적 없는 workspace에서, 다른 workspace의 서버가 듣는 포트로 `masc restart`를 불렀다. 이 층 전의 바이너리와 이 층의 바이너리 둘 다 "Port N serves another workspace"로 거절한다(exit 1). 전의 바이너리는 `.masc-owner` 폴더만 남긴다. 이 층은 그 안에 lease 폴더와 0바이트 lease 파일을 남긴다.
    - 실제로 쓰는 단일 사용자 서버 한 대는 `/health?full=1`에 0.006~0.137초에 답했다(세 번, 07:20Z). 창 10초의 70분의 1 아래다.
    - 시험을 더했다. trust policy가 거절한 부팅은 알리지 않는다(lease를 쥔 채 kernel에 묻는다). 다른 포트로 물으면 주인의 pid와 알린 포트를 답한다. 준비 판정은 표 일곱 줄로 보고 kernel에 묻는 횟수도 본다. 알림 거절은 사유를 맞춰 본다. 거절된 두 번째 알림 뒤에 첫 잠금이 남고 둘째 포트에 잠금이 없는 것을 다른 프로세스에서 묻는다.
    - 변이 둘. 알림을 trust policy 앞으로 옮기면 그 시험이 실패한다("pid N holds the announcement of the port of a boot that stopped"). 준비 판정에서 "잠근 pid가 자식인가"를 빼면 표 시험이 실패한다.
    - "다른 철자" 시험은 철자가 하나인 host에서 건너뛴다. Linux가 그렇다. CI의 Linux 실행은 파일 정체로 찾는 읽기를 시험하지 않는다.
  - 결과(코드 끝 `b3de411568e1`, 07:13~07:22Z). 빌드 exit 0. 13묶음 278개 중 274개가 통과했다. 실패 넷은 기존 것이다. `test_server_startup_takeover`의 `EINTR` 셋(#51254)과 `test_h2_gateway_http`의 `Fusion workspace admission` 하나(#51058)다. 이 층의 묶음은 3/3, 10/10, 11/11, 35/38이다. 지적을 반영한 커밋 넷은 하나씩 `@lib/check`, `@bin/check`와 시험 실행 파일 넷이 exit 0이다.
  - 그 바이너리로 흐름을 다시 쟀다(07:22~07:23Z, 다른 작업이 많이 돌던 때, load average 127).
    - 다계정. 바꿈 2.1 s, 서버가 없을 때 2.1 s. SIGSTOP으로 멈춘 서버, 다른 포트, 이 층 전의 바이너리로 뜬 서버는 전과 같은 문장으로 거절한다.
    - 다른 프로세스의 잠금 옆. 띄움 1.8 s, 바꿈 1.8 s, 서버가 알린 뒤에 걸린 잠금 옆의 바꿈 2.0 s. 포트의 바이트가 잠겨 있으면 부팅이 "the byte of port P is locked by pid N"으로 멈춘다.
    - 단일 사용자. 띄움 4.8 s, 바꿈 3.6 s. SIGSTOP으로 멈춘 서버는 10초 만에 거절한다.
  - 결과(06:00~06:01Z). 묶음 넷 중 셋이 통과했다(시험 3, 9, 9개). `test_server_startup_takeover`는 38개 중 36개가 통과했다. 알림 시험 여덟은 모두 통과했다. 실패 둘은 기존 시험이고 macOS에서 `EINTR`로 실패한다. 실행마다 둘이나 셋이다. 이 층 전의 트리에서도 같다(#51254).
- 하지 않는 것: `masc setup-server`의 상태, `masc setup-stop-previous-owner`, `masc setup`의 거절, 설치 스크립트(S1a-2e). 답하지 않는 계정 서버를 멈추는 일. 대체 서버의 판정을 미리 보는 일.

**S1a-2e 범위**

- 고치는 것. `masc restart`와 `masc auth` 밖의 운영 명령이 다계정 workspace를 단일 사용자 workspace로 읽었다.
  - 고치기 전 측정(2026-11-11 08:06~08:07Z, S1a-2d 끝의 바이너리와 스크립트, 임시 설치).
    - `masc doctor`는 `opening: needs_journey`와 imp의 점검 다섯을 답했다. 계정 서버가 떠 있어도 같았다.
    - 설치 journey는 그 workspace에 "Welcome. Let's make a home for you and imp."와 Quick setup 계획을 보여 줬다.
    - `masc setup --no-tui`는 `masc init`으로 파일 414개를 쓴 뒤 모델 검증에서 멈췄다(exit 1). 멈춘 까닭은 D2-2의 host 도구 거절이다.
    - `masc setup-server`는 계정 서버가 듣는 포트를 `unknown_server`로 답하고 다른 포트를 권했다. SIGSTOP으로 멈춘 계정 서버 앞에서는 30초 안에 끝나지 않았다.
    - `masc setup-stop-previous-owner`는 "The selected port did not return a valid workspace identity."로 거절했다(exit 1). 서버는 그대로였다.
  - 까닭. 이 명령들은 `/health`가 싣는 workspace로 서버를 알아보고, config의 `account_mode`도 lease의 주인도 읽지 않는다.
- 읽는 것은 둘이고 서로 다른 물음에 답한다.
  - 지금 누가 workspace를 쥐고 있나. kernel에서 읽는다(`Server_upgrade_preparation.holder`). `masc setup-server`, `masc setup-stop-previous-owner`, `masc restart`가 묻는다. config가 무엇을 청하든 같다.
  - 다음 부팅이 무엇을 띄우나. config에서 읽는다(`Authz_boot_mode_read.asks_for_multi_account`). `masc doctor`, `masc setup`, 설치 journey의 시작이 묻는다.
    - `config.json`이 `Multi_account`를 청할 때만 `true`다. 부팅 판정 표(`Authz_boot_mode.judge`)는 그 요청에 단일 사용자를 답하지 않는다. 활성화 요청, 계정 서버, 불확실, 거절 가운데 하나다.
    - 활성화됐는지는 읽지 않는다. 로그와 외부 저장소는 lease를 쥔 부팅만 연다(파일을 열며 끝줄을 자르고 lock 파일을 둔다).
    - 값이 없거나, `Single_user`이거나, 표가 모르는 값이면 `false`다. 파일이 있는데 읽지 못하거나 JSON 객체가 아니어도 `false`다. 부팅도 그런 config를 아무것도 청하지 않는 config로 판정한다.
    - 안내 문장은 한 곳에 있다(`account_installation_line`). config 파일 경로와 명령 둘(`masc auth bootstrap`, `masc restart`)을 싣는다. doctor의 점검과 `masc setup`의 거절이 같은 문장을 쓴다.
- 읽기만 하는 명령은 아무것도 만들지 않는다.
  - lease의 주인을 읽으면(`capture_existing_owner`) run 폴더, private lease 폴더, 빈 lease 파일이 없을 때 생긴다. journey는 아직 아무것도 없는 폴더의 포트부터 살핀다.
  - `Server_startup_takeover.lease_file_present`가 먼저 본다. lease 파일이 한 번도 만들어지지 않은 workspace는 아무도 쥔 적이 없다. 그러면 주인을 읽지 않는다. 파일이 있으면 주인을 읽어도 더 만들 것이 없다.
  - 가는 길에 폴더가 아닌 것이 있으면 `true`를 답한다. 뒤따르는 읽기가 그것을 자기 문장으로 거절하고, 거절은 아무것도 만들지 않는다.
- `Server_upgrade_preparation.holder`의 답은 셋이다.
  - `Held_by_nobody`. lease 파일이 없거나, 있어도 쥔 프로세스가 없다.
  - `Held_without_announcement`. 주인이 포트를 알리지 않는다. 단일 사용자 서버이거나, 알리기 전의 계정 서버다.
  - `Held_by_account_server { port }`. 주인이 알린 포트다. 물은 포트와 달라도 알린 포트를 답한다.
  - 그 아래의 `account_server`는 네 갈래를 답한다. 전에는 "주인 없음", "알리지 않음", "다른 프로세스의 lock 뒤에서 놓침"을 `No_account_server` 하나로 답했다.
- `masc doctor`(`Onboarding_status`).
  - `opening`에 `account_installation`이 생겼다. 점검은 둘이다. `workspace`와 `multi_account_request`(needs_verification)다.
  - imp의 모델·선언·sandbox·history는 읽지 않는다. 단일 사용자 서버가 쓰는 것이고 그 서버는 여기서 뜨지 않는다.
- `masc setup-server`.
  - 주인이 계정 서버의 포트를 알리면 `status: "account_server"`다. `server_port`(알린 포트), `server_answers`(그 포트의 `/health`가 10초 안에 200을 답했는지), 답이 버전을 실었으면 `server_version`을 싣는다. `suggested_port`는 싣지 않는다.
  - 주인이 없거나 알리지 않으면 전과 같이 포트의 답으로 판정한다.
  - 주인을 읽지 못하면 config가 가른다. 다계정을 청하면 상태를 답하지 않는다. `masc.setup_server_unread.v1` 문서에 사유를 싣고 exit 1로 끝난다. 계정 서버가 도는지 모르는 채로 `free`를 답하면 서버가 없는 workspace로 읽힌다. 청하지 않으면 전처럼 포트의 답으로 판정한다. `pidfd_open`이 없는 Linux의 단일 사용자 설치가 전과 같이 돈다.
- `masc setup-stop-previous-owner`.
  - 로컬 운영자로 로그인하기 전에 `holder`에 묻는다. 그 명령은 로그인한 bearer를 포트로 보낸다.
  - `Held_by_nobody`면 거절한다. 포트에서 무엇이 답하든 이 명령이 멈출 주인이 아니다. lease를 다른 곳에 두던 옛 버전 서버(#48858 전)도 여기에 든다. 전에도 그 서버는 멈추지 못했다(주인 확인 실패). 지금은 로그인과 bearer 전송이 없다.
  - `Held_by_account_server`면 거절하고 `masc restart`를 말한다.
  - `Held_without_announcement`면 전과 같다.
  - 남는 틈. 계정 서버가 lease를 쥐고 아직 알리기 전에는 단일 사용자 서버와 구분되지 않는다. 그 구간의 명령은 포트의 답까지 간다. 단일 사용자 서버의 정지가 kernel 확인보다 먼저 bearer를 보내는 순서는 이 층이 바꾸지 않았다(#51321).
- `masc setup`(스크립트 없이 도는 길). config가 다계정을 청하면 초기화 전에 거절한다(exit 1). 파일을 쓰지 않고 서버를 띄우지 않는다.
- 설치 journey(`scripts/install-runtime-setup.py`).
  - doctor 문서가 `account_installation`이면 묻지 않고 끝난다(exit 0). workspace 경로, 만족되지 않은 점검의 문장, 계정 서버의 상태 한 줄, 다른 workspace를 고르는 명령을 찍는다. `masc init`, 모델 wizard, sandbox 단계, `masc-tui`를 부르지 않고 포트를 저장하지 않는다.
  - 아직 어떤 doctor 문서도 말하지 않은 폴더는 무엇을 권하거나 점검하거나 초기화하기 전에 doctor로 읽는다. 셋이다. workspace 화면에서 친 폴더(점검이 푸는 것과 같게 경로를 먼저 푼다), 첫 실행이 제안하는 기본 폴더(`~/MASC`), 저장해 둔 sandbox 단계의 workspace다. 이미 있는 workspace라면 doctor 한 번(sandbox 점검 포함)만큼 더 걸린다.
  - `masc setup-server`의 문서는 받는 자리에서 통째로 해석한다(`setup_server_observation`). journey가 찍는 필드가 없는 문서는 관찰이 아니다.
  - `select_setup_server`가 `account_server`를 받으면 `masc restart`를 말하고 끝난다. 정지를 이미 청한 뒤라면 그 사실을 함께 말한다.
  - `note_running_server`는 `account_server`에서 아무 말도 하지 않는다. 계정 서버는 Keeper를 띄우지 않아 browser 설정을 읽지 않는다.
  - exit code는 다르다. journey는 안내라서 0, `masc setup --no-tui`는 거절이라 1이다.
- 호환. 스크립트는 바이너리에 들어 있다. 새 값(`account_installation`, `account_server`, `masc.setup_server_unread.v1`)은 hard cut으로 넣는다.
- 고친 뒤 측정(2026-11-11 09:59Z, rebase한 스택 위의 바이너리, 임시 설치, 비운 환경).
  - 아무것도 없는 폴더. `masc setup-server`는 `free`, `masc setup-stop-previous-owner`는 "No process holds the lease this MASC reads for this workspace…"로 거절한다(exit 1). 폴더는 빈 채다. 이 층 전의 바이너리는 같은 정지 명령 뒤에 `.masc-owner`를 남겼다.
  - config만 청하는 workspace. doctor는 `account_installation`과 점검 둘, `masc setup-server`는 `free`이고 아무것도 만들지 않는다. journey는 "No account server announces itself for this workspace."를 찍고 exit 0, `masc setup --no-tui`는 exit 1이다. 끝난 뒤 폴더에는 `config.json` 하나다.
  - 계정 서버가 도는 workspace(Ready 1.5 s). 물은 포트가 맞든 다르든 `account_server`, `server_port`는 알린 포트, `server_answers: true`다. 정지 명령은 거절하고 서버는 계속 돈다(`/health/ready` 200).
  - SIGSTOP으로 멈춘 계정 서버. 10초 뒤 `server_answers: false`를 답한다. journey는 "announces port P and did not answer its health probe there"를 찍는다.
  - 계정 서버가 도는 중에 config에서 `account_mode`를 지웠다. doctor는 `needs_journey`로 읽고(다음 부팅의 물음), `masc setup-server`는 `account_server`로 답하고(지금의 물음), 정지 명령은 거절한다.
  - config가 청하는데 lease 폴더 자리에 파일이 있다. `masc setup-server`는 `masc.setup_server_unread.v1`과 exit 1, journey는 그 문장으로 exit 1이다. 같은 폴더에서 config의 요청을 지우면 `free`를 답한다.
  - 첫 실행. `~/MASC`가 다계정을 청하면 journey는 "Welcome"을 찍지 않고 그 안내로 끝난다(exit 0). 폴더는 그대로다.
  - 단일 사용자 workspace. `free` → `masc restart` → `same_workspace` → 정지(`replacement_can_start`)의 순서를 이 층 전의 바이너리와 줄 단위로 맞춰 봤다. 포트, pid, 시간을 빼면 같다.
- 시험.
  - `test_server_startup_takeover`: lease 파일은 BasePath, lease root, private lease 폴더가 없을 때와 폴더만 있을 때 없다고 답하고 아무것도 만들지 않는다. 주인이 쥐면 있다고 답한다. lease root 자리에 파일이 있으면 있다고 답하고, 획득은 그것을 거절하며 아무것도 만들지 않는다.
  - `test_server_upgrade_preparation`: `holder`는 아무도 시작한 적 없는 workspace에서 `Held_by_nobody`를 답하고 lease root를 만들지 않는다. 단일 사용자 주인은 `Held_without_announcement`, 계정 서버는 물은 포트와 무관하게 알린 포트를 답한다. 주인이 끝난 뒤의 lease 파일은 `Held_by_nobody`다. lease root가 파일이면 `Owner_lease_rejected`다. 읽기는 주인에게 신호를 보내지 않는다.
  - `test_onboarding_journey.py`(바이너리 없이): 계정 설치에서 `setup-server` 하나만 부르고 포트를 저장하지 않는다. 관찰마다 맞는 상태를 말한다(답한 서버, 버전 없는 답, 답 없는 알림, 남의 포트). 필드가 빠지거나 형이 다른 문서 열아홉 가지는 상태를 말하지 않는다. 친 폴더와 첫 실행의 기본 폴더는 점검·계획보다 먼저 읽는다. 물결표와 `..`이 든 경로는 점검이 푸는 폴더로 읽는다. sandbox 단계는 doctor를 먼저 읽는다. 리뷰 전의 스크립트에 같은 시험을 돌리면 여덟 시험이 실패한다.
  - `test_setup_cli.py`(바이너리, 서버 없음): 아무것도 없는 폴더에서 `setup-server`와 정지 명령이 아무것도 만들지 않는다. lease root를 읽지 못할 때 config가 청하면 `masc.setup_server_unread.v1`과 exit 1, 아니면 `free`다.
  - `test_onboarding_journey.py --binary`: 실제 bootstrap과 `masc restart`로 계정 서버를 띄우고 `setup-server`, journey, 정지 명령을 본다. CI는 이 파일을 바이너리 없이 돌린다. 이 시험은 손으로 돌린다.
- 독립 리뷰(2026-11-11, 첫 구현). P1은 없었고 P2 셋, P3 열이었다. 모두 코드에서 확인했다.
  - P2. 정지 명령의 거절이 알림 뒤에만 섰고 `No_account_server`가 세 상태를 합쳤다. `account_server`를 네 갈래로 나누고 `holder`를 뒀다.
  - P2. 읽지 못하는 config에서 `asks_for_multi_account`가 `false`인 것을 적지 않았다. 적었고, `masc setup-server`가 config와 무관하게 kernel을 읽게 했다.
  - P2. 바이너리의 새 갈래에 native 시험이 없었고 스텁 시험 둘은 옛 코드에서도 통과했다. 시험을 다시 썼다.
  - P3. 친 폴더를 점검 뒤에 읽었다(점검은 upgrade와 restore를 권할 수 있다). 앞으로 옮겼다. 경로를 풀지 않고 doctor에 넘기던 것도 고쳤다(`~/x`를 `./~/x`로 읽었다).
  - P3. 200이지만 버전을 못 읽은 답을 "답하지 않았다"고 말했다. `server_answers`를 따로 실었다.
  - P3. `read_only: true`인 명령이 lease 파일을 만들었다. `lease_file_present`로 막았다.
  - P3. 필드가 빠진 문서에서 `KeyError`가 났다. 받는 자리에서 해석한다.
  - P3. 정지를 청한 뒤에도 "nothing was started or stopped"라고 말할 수 있었다. 문장을 갈랐다.
  - P3. 주인을 못 읽은 사유를 버렸다. `owner_capture_error_to_string`으로 싣는다.
  - P3. 안내 문장이 "부팅이 계정 서버를 띄운다"고만 했다. 부팅은 멈출 수도 있다.
  - P3. sandbox 단계가 doctor를 읽지 않았다. 읽는다.
  - 그대로 둔 것. journey와 `--no-tui`의 exit code 차이, doctor를 한 번 더 읽는 비용. 위에 적었다.
- 결과(2026-11-11 09:49~10:01Z, OCaml 5.5.2). 빌드 exit 0. `test_authz_boot_mode_read` 31/31, `test_onboarding_status` 15/15, `test_server_upgrade_preparation` 12/12, `test_server_startup_takeover` 36/39다. 실패 셋은 macOS의 `EINTR`이고 이 층의 시험이 아니다(#51254). Python은 journey 231(바이너리 없이, 25 건너뜀), 설치 149(29 건너뜀), `test_setup_cli.py --binary` 23, 설치 `--binary` 149가 통과했다. journey `--binary`는 231 중 하나가 실패했다. 이 장비에서 기본 포트를 다른 서버가 쥐고 있어서이고 이 층 전에도 같다.
- 하지 않는 것.
  - `masc-tui`를 직접 띄우는 길은 계정 서버를 알아보지 못한다.
  - `account_mode`가 표에 없는 값인 config와, 로그는 다계정인데 config가 청하지 않는 workspace는 doctor가 전처럼 읽는다. 둘 다 부팅이 자기 문장으로 거절한다. 앞의 것은 #51320이다.
  - 다른 포트를 물었을 때 주인이 알린 포트를 읽는 길은 같은 사용자의 다른 프로세스가 건 lock 뒤에서 주인을 놓칠 수 있다(S1a-2c의 한계). 그때는 `Held_without_announcement`다.
  - `scripts/install.sh`는 journey 전에 `masc init --config-only`로 config를 심고, journey가 exit 0이면 "Setup finished"라고 적는다. 계정 설치에서도 같다(#51362).

**S1a-3a 범위**

- 목표. 계정 서버가 로그인 경로를 연다. 그 전까지 계정 서버의 표는 probe 셋뿐이고, 로그인 경로는 `masc auth preview`만 열었다.
- 표. `Server_accounts.register`가 probe 셋 뒤에 `Server_login_http.add_routes`를 단다. 더해지는 경로는 `POST /auth/oidc/start`, `GET /auth/oidc/callback`, `POST /auth/github/start`, `GET /auth/github/callback`, `POST /auth/logout`, `GET /auth/session`, allowlist 둘, PAT 셋이다. 모두 `Self_authenticated Browser_session`이라 표의 검사(`Server_account_table.checked`)를 지난다.
- login client.
  - 부팅 판정(`Authz_boot_mode_read.boot`)이 읽은 `config.json`의 `google`·`github` member를 `multi_account` 값에 싣는다(`multi_account_login_clients`). 파일을 두 번 읽지 않는다. 판정한 config와 사람을 로그인시키는 config가 같은 바이트다.
  - client는 `Login_client.of_environment`로 만든다. secret은 member가 이름을 적은 환경 변수에서 읽고, redirect는 `https` URL이어야 한다.
  - member가 있는데 client를 만들 수 없으면 부팅이 멈춘다(`Login_client_refused`). 그 provider만 빼고 뜨면 운영자가 설정한 로그인이 404로 답한다.
  - member가 없는 provider는 설정되지 않은 것이고, 그 시작과 callback은 404다. 둘 다 없으면 아무도 로그인하지 못한다. 부팅은 그 사실을 로그에 경고로 적고 뜬다. probe와 `masc restart`는 login client 없이도 돌아야 한다.
- 조립. `Server_account_login.routes`가 `Login_routes.t`를 만든다(transaction을 봉인하는 키, provider로 가는 전송, 벽시계, 32바이트 난수). 계정 서버와 `masc auth preview`가 같은 함수를 쓴다. 미리보기의 client는 전처럼 loopback(`Login_client.loopback`)이다.
- 프로세스 준비. 로그인은 `Masc_http_client`로 provider에 닿는다. 그 client는 프로세스의 env와 switch(`Eio_context`)를 읽는다. 단일 사용자 부팅은 owner state를 만들며 둘을 채우고, 계정 서버는 owner state를 만들지 않는다. 그래서 `Server_accounts.run`이 마지막 거절 뒤에 채운다. 거절된 부팅은 둘을 남기지 않는다.
- 거절 순서. `Login_client_refused`는 구역을 다시 읽은 뒤, 표를 만들기 전이다. 포트를 묶기 전이라 CLI가 읽는 포트 기록과 host에 알리는 포트가 남지 않는다.
- 시험(`test_server_accounts`).
  - secret 변수가 없는 `github` member와 redirect가 `http`인 member에서 부팅이 `Login_client_refused`로 멈춘다.
  - `github` member가 있는 설치를 띄운다. Origin 없는 `POST /auth/github/start`는 403(경로까지 닿는다), member가 없는 `POST /auth/oidc/start`는 로그인 경로의 404다(라우터의 404와 본문이 다르다).
- 독립 리뷰(2026-11-11). P0 없음.
  - P1(S1a-3a-1이 고친다). 로그인 시작은 credential 없이 받고, 대기 중 로그인 저장소는 16자리다. 자리가 차면 빠질 때까지(callback 또는 10분) 새 로그인이 503이다. 실제 바이너리에서 16번 시작한 뒤의 시작이 503이었다(15:10Z). 가용성 문제이고 저장소 설계(§5.2)를 바꾸는 일이라 #51394로 올렸다. 저장소가 요구하는 뒤로 가지 않는 시계 대신 벽시계를 넘기는 것도 같은 이슈에 적었다.
  - P2. provider 교환 실패가 로그에 남지 않았다. `Login_routes`가 상태로 바꾸는 세 곳에서 사유를 로그에 남긴다.
  - P2. 시험이 같은 origin의 시작과 전송 준비를 보지 않았다. 303·`Location`·거래 cookie와 `Eio_context`의 env·switch를 단언한다.
  - P3. env·switch 준비가 거절 여섯보다 앞이었다. 마지막 거절 뒤로 옮겼고, 전송이 읽지 않는 net과 난수원 준비는 뺐다.
- 결과(2026-11-11 15:10~15:12Z, OCaml 5.5.2). 빌드 exit 0. `test_server_accounts` 11/11, `test_login_routes` 6/6, `test_authz_boot_mode_read` 31/31.
- 실제 바이너리(임시 폴더, 비운 환경, loopback 포트, 15:12Z).
  - login client 없는 설치: 서버가 뜨고 `/health/ready` 200이다. `POST /auth/github/start`와 `POST /auth/oidc/start`는 로그인 경로의 404, `GET /auth/session`과 `GET /api/v1/auth/pats`는 401, `GET /`와 `POST /mcp`는 라우터의 404다. 서버 로그에 경고 한 줄이 남는다.
  - `github` member와 secret 변수가 있는 설치: Origin이 서버 주소인 `POST /auth/github/start`는 303이고 `Location`이 GitHub의 authorize URL(config의 `client_id`와 `redirect_uri`, `state`, PKCE)이며 거래 cookie가 온다. Origin이 없거나 다른 host면 403, cookie 없는 callback은 401, 16 KiB를 넘는 본문은 413이다. secret 값은 답과 로그 어디에도 없다.
  - secret 변수가 없는 설치와 redirect가 `http`인 설치: `masc restart`가 exit 1이고, 서버 로그의 `[FATAL]` 줄이 변수 이름 또는 redirect 규칙을 말한다.
- 하지 않는 것.
  - 화면(`GET /`, 초대 입장)과 사람의 경로는 S1a-3b다. 이 층만으로는 브라우저에서 로그인을 시작할 화면이 없다.
  - redirect가 이 서버의 주소·경로를 가리키는지는 보지 않는다. 다른 host나 경로를 적은 redirect는 provider에서, 또는 첫 callback에서 실패한다.
  - provider까지 가는 로그인(실제 GitHub·Google 왕복)은 시험하지 않는다.
  - HTTP/2로 온 로그인 요청은 시험하지 않는다. handler는 `Http_reqd`로 읽고 쓰므로 두 프로토콜이 같은 코드를 지난다.

**S1a-3a-1 범위**

- 고치는 문제(#51394). 로그인 시작은 credential 없이 받는다. 서버가 진행 중인 로그인을 16자리 저장소에 두었으므로, 시작만 16번 보내면 자리가 빌 때까지(callback 또는 10분) 다른 사람의 로그인이 503이었다. 사람의 화면을 여는 S1a-3b보다 먼저 고친다(2026-11-11 사용자 결정: 봉인 쿠키).
- 방법. 서버는 진행 중인 로그인을 저장하지 않는다. 시작할 때 만든 값(흐름, 시작 시각, `state`, PKCE verifier, Google의 `nonce`, 초대 token의 digest, `return_to`, 대체할 세션 ID)을 봉인해 `__Host-masc_oidc_txn`의 값으로 준다. callback은 쿠키를 열어 그 값을 얻는다.
  - 봉인은 ChaCha20-Poly1305다(`Mirage_crypto.Chacha20`, RFC 8439). 키는 프로세스가 뜰 때 OS CSPRNG에서 뽑은 32바이트이고 파일에 쓰지 않는다. 서버가 다시 시작하면 그 전의 봉인은 열리지 않고, 그 로그인은 다시 시작해야 한다.
  - nonce 12바이트는 0 넷과 8바이트 counter다. counter는 `Atomic.fetch_and_add`로 올리므로 한 키에서 같은 nonce가 두 번 나오지 않는다. 난수 nonce는 96비트라 충돌 한계를 따져야 하고, counter는 따질 것이 없다.
  - 연관 데이터는 용도 문자열(`masc-login-transaction-v1`)이다. 같은 키로 다른 용도의 봉인을 만들게 되어도 서로 열리지 않는다.
  - 쿠키 값은 nonce, 암호문, tag를 이어 붙인 것의 base64url이고 4000자 이하다. 브라우저는 쿠키 하나에 4096바이트를 보장한다(RFC 6265 §6.1). `return_to`가 길어 넘으면 시작이 400이다.
  - 초대 token은 digest로만 봉인한다. 입장 판정은 digest만 쓴다.
- 달라지는 동작.
  - 시작은 자리를 기다리지 않는다. 503(가득 참)이 없어졌다.
  - 봉인한 값은 만료(10분) 전까지 여러 번 열린다. 서버에서 소비되는 것이 없다. 다만 callback의 답은 전처럼 어느 경우에나 브라우저의 쿠키를 지운다. 그래서 브라우저에서는 `state`가 틀린 callback 한 번으로 그 로그인이 끝나고, 이 점은 전과 같다.
  - 같은 callback이 두 번 오면 서버는 두 번 다 provider에 묻고, provider가 일회용 code를 거절한다(RFC 6749 §4.1.2, RFC 9700 §2.1.2 권고와 같은 방향). 초대는 로그에서 한 번만 소비되고(같은 초대의 두 번째 소비는 409), 세션 대체는 레코드 하나라 두 번 쓰이지 않는다.
  - 열리지 않는 쿠키(다른 키, 바뀐 글자, 잘린 값, 다른 흐름, 만료)는 provider에 묻기 전에 401이다.
- 시계. 만료는 봉인 안의 시작 시각과 지금의 벽시계를 비교한다. 시계가 뒤로 가면 그만큼 더 오래 열리고, 앞으로 가면 일찍 닫힌다. 여는 것만으로는 로그인이 되지 않으므로(code와 `state`가 맞아야 한다) 만료는 쿠키 수명(`Max-Age=600`)을 서버에서 한 번 더 보는 것이다.
- 지운 것. `Oidc_login_transaction`의 저장소(`Id`, `create ~capacity`, `Full`, `take`, `live`)와 `Server_account_login`의 16.
- 시험.
  - `test_oidc_login_transaction`: 2000번 시작한 것이 전부 열린다. 두 번 열린다. 다른 키, 한 글자 바뀐 값(모든 자리), 한 글자 붙은 값, 잘린 값, 다른 흐름, 만료는 열리지 않는다. 봉인한 바이트에 `state`·nonce·`return_to`·token·필드 이름이 보이지 않는다. domain 넷이 500번씩 봉인한 nonce 2000개가 서로 다르다. 2048자 `return_to`는 들어가고 4096자는 `Too_long`이다.
  - `test_login_flow`: 틀린 `state` 뒤에 맞는 `state`로 로그인된다. 같은 callback의 두 번째는 provider가 거절하고 로그에 쓰인 것이 없다.
  - `test_login_routes`: 시작 64번이 모두 303이다. 쿠키에 안 들어가는 `return_to`는 두 흐름 모두 400이다.
  - `test_authz_browser_request`: 가장 긴 봉인으로 만든 `Set-Cookie` 값이 4096바이트 이하다.
- 독립 리뷰(2026-11-11). P0~P2 없음. P3 넷.
  - 쿠키 글자열이 하나로 정해지지 않았다. 패딩 없는 base64 해석기는 읽지 않는 끝 글자와 끝 글자의 남는 비트를 그냥 지나간다. 그래서 같은 바이트로 읽히는 다른 글자열도 열렸다. 다시 인코딩한 것과 같은 글자열만 연다.
  - HTTP/1 listener는 header 한 줄을 4096바이트까지 읽는다. callback의 `Cookie` 줄에는 브라우저가 이 host로 보내는 쿠키가 모두 실린다. 실제 바이너리에서 4089바이트 줄은 답을 받고 4099바이트 줄은 400이며 서버는 계속 답한다. 봉인은 `return_to`가 `/`일 때 400~650자다. `return_to`가 수천 자이고 브라우저가 다른 쿠키도 보내는 로그인은 callback에서 400이다. 고치지 않고 인터페이스 문서에 적었다. 세션 쿠키는 `SameSite=Strict`라 provider에서 돌아오는 callback에 실리지 않는다.
  - nonce가 봉인 횟수라, 로그인을 시작한 사람은 이 프로세스가 시작한 로그인 수를 읽는다. 난수 nonce로 바꾸면 수는 가려지지만 같은 nonce가 두 번 나올 확률이 생긴다. 그대로 두고 인터페이스 문서에 적었다.
  - 낡은 주석 넷을 고쳤다.
- 결과(2026-11-11 16:01~16:22Z, OCaml 5.5.2). 빌드 exit 0. `test_oidc_login_transaction` 15/15, `test_login_flow` 16/16, `test_login_routes` 6/6, `test_server_login_http` 8/8, `test_server_accounts` 11/11, `test_oidc_google_exchange` 11/11, `test_github_oauth` 5/5, `test_authz_browser_request` 4/4, `test_login_pat_routes` 3/3, `test_login_allowlist_routes` 3/3.
- 실제 바이너리(임시 폴더, 비운 환경, loopback 포트, 2026-11-11 16:22Z).
  - 시작 40번이 모두 303이다(같은 서버가 S1a-3a에서는 17번째부터 503이었다).
  - 쿠키 값은 이름까지 411바이트, `Set-Cookie` 줄은 476바이트다. 쿠키 값에 `state`가 보이지 않는다.
  - `state`가 틀린 callback, 한 글자 바꾼 쿠키, 잘린 쿠키는 401이다. 서버를 다시 띄운 뒤 그 전의 쿠키와 맞는 `state`도 401이다.
  - 4001자 `return_to`는 400, `/keepers`는 303이다.
  - S1a-3a의 smoke가 본 답(404·401·403·413, 거절되는 부팅 둘, secret 값 0곳)은 그대로다.
- 하지 않는 것.
  - 키를 파일에 두거나 여러 프로세스가 나누지 않는다. 계정 서버는 프로세스 하나다. 재시작이 끊는 것은 그때 진행 중이던 로그인(최대 10분 치)뿐이고 세션은 로그에 있어 남는다.
  - provider까지 가는 로그인 왕복은 시험하지 않는다(S1a-3a와 같다).

**S1a-3b 범위**

- 목표. 초대받은 사람이 계정 서버에서 로그인하고, 자기 구독을 연결하고, 자기 Keeper를 만들어 한 턴을 돈다. 그 전까지 이 화면과 경로는 `masc auth preview`만 열었다.
- 표. `Server_accounts.register`가 로그인 경로 뒤에 `Server_login_http.add_person_routes`를 단다. 더해지는 것은 화면 둘(`GET /`, `GET /accounts/invite`, `Always_public`)과 사람의 경로 열(who-am-I, 구독 목록, 구독 연결과 그 상태·조작, 구독 확인, Keeper 목록·만들기·배정·한 턴, 모두 `Self_authenticated Browser_session`)이다. 표의 검사를 지난다.
- 이름. 이 경로를 다는 함수의 이름을 `add_person_routes`로 바꾼다. 전 이름은 미리보기를 가리켰고, 이제 계정 서버가 부른다. 모듈 이름(`Auth_preview`, `Auth_preview_keeper`, `Server_preview_keeper_turn`)은 그대로 둔다.
- 화면.
  - 화면은 GitHub 로그인만 시작한다. 서버에 GitHub client가 없으면 버튼이 눌리지 않고 화면이 그 사실을 말한다. 전에는 눌러서 404를 받았다.
  - Google 로그인은 경로만 있고 화면에 버튼이 없다. 화면의 CSP `form-action`에 Google 인가 주소의 origin이 들어가야 하는데, 그 주소는 discovery가 준다.
  - Admin 세션이면 화면에 allowlist 등록·삭제 칸이 보인다(`whoami`의 `role`이 `admin`일 때만. 판정은 서버가 한다). C6의 Admin 화면이 생기기 전에 일반 Member를 들이는 길이다(#51483). allowlist를 읽는 경로가 없어서 방금 등록한 id만 보이고, C6가 서면 이 칸을 지운다.
  - Admin이 초대를 발급하고 취소하는 경로(C6 ③ 가운데 서버 쪽, #51483). `POST /api/v1/auth/invites`의 본문은 `{"role":"member"}`나 `{"role":"admin"}`이다. 답은 `{"invite_id","role","expires_at_ms","link"}`이다. `link`는 `/accounts/invite#<token>`이고 서버 주소가 없다. 부른 화면이 자기 origin을 앞에 붙인다. 서버는 자기 공개 주소를 추측하지 않는다. token은 이 답에만 있고 로그에는 digest만 남는다. 링크를 잃으면 취소하고 다시 발급한다. `DELETE /api/v1/auth/invites/<id>`는 열린 초대를 취소한다(204, 없는 id는 404, 취소됐거나 쓰인 초대는 409). 둘 다 브라우저 세션과 CSRF token으로 부르고, Admin인지는 상태가 판정한다(Admin이 아니면 403). 수명은 운영자의 초대와 같은 24시간이다. 기록 층(`Authz_invite_state`)은 처음부터 Admin의 두 역할 발급과 취소를 받았고, 이 층은 그 기록을 쓰는 서버 함수(`Authz_invite`)와 경로를 더한다. 열린 초대를 읽는 경로와 화면은 이 층에 없다.
  - 로그인 전에는 로그인 칸만, 로그인 뒤에는 구독·Keeper·PAT 칸만 보이고 목록 조회는 로그인 뒤에만 보낸다. 칸은 `<section>`과 제목으로 이어지고 동작 결과는 `role="status"`로 낭독된다. `Account`와 `Runtime`은 서버가 준 목록에서 고르고, PAT 만료는 날짜·시간 선택이다. 스타일은 CSP에 `style-src`가 없어서 없다.
  - 제목은 `MASC accounts`다.
- 프로세스 준비. 사람의 경로가 읽는 전역은 `Eio_context`의 env와 switch이고 S1a-3a가 이미 채운다. 턴은 official client를 서버의 프로세스로 띄운다(`Server_preview_keeper_turn`). net 전역을 읽는 경로는 없다(읽어서 확인).
- 다른 사람의 Runtime. 턴은 `Runtime_account_access.authorize`가 허락한 계정에서만 시작한다. 다계정 프로세스에서 native 도구를 쓰는 자세는 `authorize_native`가 거절한다(D3c). 이 층은 그 판정을 바꾸지 않는다.
- 안내문. `masc auth bootstrap`과 `masc auth invite`의 도움말이 "계정 서버는 아직 로그인 경로를 열지 않는다"고 적었다. 계정 서버가 여는 것으로 고친다.
- 시험.
  - `test_server_accounts`: 띄운 계정 서버에서 화면 둘이 200이고 답마다 script nonce가 있으며 GitHub 버튼이 눌린다. who-am-I, 구독 목록, Keeper 목록은 credential 없이 401이다. 단일 사용자 경로(`/api/v1/keepers` 등)는 404다.
  - `test_server_login_http`: GitHub client 없는 표의 화면 둘은 버튼이 막혀 있고 그 사실을 말한다.
  - `test_auth_gate`: `mat_` bearer는 `Read_auth`·`Manage_own_provider`·`Manage_own_keeper`에서 `Mcp_oauth_token_not_bound`다. 세션과 PAT이 같이 오면 `Manage_own_*`에서도 `Several_credentials`다.
  - `test_authz_boot_mode_read`: `config.json`이 `enabled:false`이거나 `require_token:false`인 다계정 부팅은 파일에서 읽어 거절한다.
- 설계 §11.1 증거(2026-11-11 조사, 코드와 시험을 읽음). 일곱 항목 가운데 문구 그대로 다 모인 것은 없다.
  - 1항(경로 목록과 거절·CSRF·credential 단일성): 일부. 표 검사와 게이트·세션 검사의 거절은 시험이 있다. 로그인 경로 쪽은 세션 쿠키 둘을 거절하지 않는다(#51420). 구독 연결·확인·배정 경로를 HTTP로 거절까지 본 시험은 없고, 게이트 함수의 시험이 그 판정을 본다.
  - 2항(legacy·agent credential 호출자 목록, 부팅 거부): 부팅 거부는 판정 표와 파일 경유 모두 시험이 있다(이 층이 파일 경유를 더했다). 호출자 목록 둘은 센 적이 없다. 계정 서버의 표에는 단일 사용자 종류의 경로가 없어서 그 credential로 닿는 경로가 없다는 것이 지금의 근거다.
  - 3항(`Mcp_oauth_token` 거절): 있다(이 층이 게이트 시험을 더했다).
  - 4항(`lib/runtime`의 string만으로 실행 객체를 얻는 경로 0): 일부. 실행 진입은 `authorize*`가 준 봉인 값만 받는다(타입). 남은 수를 세는 검사는 없다.
  - 5항(두 계정 호출과 제3자 거부): 일부. 남의 Runtime 배정·실행 거부와 두 사람의 턴은 시험이 있다(client는 대역). 실제 Provider 계정 둘로 부른 기록은 없다.
  - 6항(lane 종류마다 남의 account-home 읽기 시도): 일부. 호스트 프로세스는 시도한 결과가 있고, container와 microVM은 mount 목록을 본 것이지 시도가 아니다.
  - 7항(통과 못 한 lane은 턴을 시작하지 못함): 있다. 설계 문구가 "배정하지 못한다"였는데 구현은 배정을 받고 턴 시작에서 거절한다. 문구를 구현에 맞췄다(2026-11-12 사용자 결정). 시험: `test_runtime_account_access_multi`(다계정에서 native 도구 자세는 `Native_tools_reach_other_homes`), `test_server_preview_keeper_turn`(Codex Keeper의 턴은 거절되고 Codex가 돌지 않는다).
- 결과(2026-11-11 16:56~16:58Z, OCaml 5.5.2). 빌드 exit 0. `test_server_accounts` 11/11, `test_server_login_http` 8/8, `test_login_routes` 6/6, `test_auth_gate` 2/2, `test_authz_boot_mode_read` 31/31, `test_server_preview_keeper_turn` 1/1.
- 실제 바이너리(임시 폴더, 비운 환경, loopback 포트, 2026-11-11 16:55Z).
  - 서버 로그가 표의 경로를 26개로 적는다(probe 셋, 로그인 경로 열하나, 화면 둘, 사람의 경로 열).
  - login client 없는 설치: `GET /`와 `GET /accounts/invite`는 200이고 버튼이 막혀 있다. 사람의 경로 아홉(who-am-I, 구독 목록, Keeper 목록·만들기·배정·턴, 구독 연결·상태·확인)은 credential 없이 모두 401이다. `Authorization` 둘은 401(credential 여럿), 모르는 bearer는 401(legacy bearer 거절)이다. `POST /mcp`는 라우터의 404다.
  - `github` member가 있는 설치: 화면의 버튼이 눌리고, 사람의 경로는 같은 401이다. S1a-3a-1의 측정(시작 40번 303, 열리지 않는 쿠키 401, 긴 `return_to` 400)은 그대로다.
  - HTTPS listener(`MASC_HTTPS_PORT`)를 켠 같은 설치: TLS 1.3과 HTTP/2로 `GET /`·`GET /accounts/invite`는 200, who-am-I는 401이다. `https` origin에서 온 로그인 시작은 303과 쿠키 하나이고, cleartext origin을 댄 시작은 403이다.
- 하지 않는 것.
  - 화면의 Google 로그인 버튼.
  - provider까지 가는 로그인 왕복과 실제 구독으로 도는 턴. 사용자가 직접 써 볼 대상이다.
  - #51413(redirect가 이 서버의 callback인지), #51420, #51421.

**S1b 범위** (사람에게 MCP를 연다, 2026-11-12)

- 사용자 결정(2026-11-12).
  - S1b는 MCP부터 연다. 도구는 사람의 화면이 하는 일만 준다. 내 정보, 내 Keeper 목록·만들기·배정, 내 Keeper의 한 턴이다.
  - Board는 S1b-1에서 열지 않는다. 다계정에서 Board를 누가 읽고 쓰는지, 남의 글이 Keeper를 깨우는지는 설계에 없다. 설계 절을 따로 써서 정한다(S1b-2).
  - WebSocket과 Dashboard(C6)도 따로 정한다.
- 확인한 사실(main `93db247b1108`).
  - 단일 사용자의 MCP(`Server_mcp_transport_http`, `Mcp_server_eio_protocol`), Board(`Board_dispatch`, `Mcp_tool_runtime_board`), WebSocket(`Server_mcp_transport_ws`)은 `Mcp_server.server_state`와 단일 사용자의 credential 저장소(`Auth`)를 읽는다. 계정 서버는 그 state를 만들지 않는다.
  - 사람의 경로는 handler 안에서 `Auth_gate.decide`를 부른다. 세션과 PAT를 같은 판정으로 받는다. PAT는 범위에 `Manage_own_keeper`가 있어야 Keeper 경로를 지난다.
  - JSON-RPC codec(`Mcp_transport_protocol`)과 2026-07-28 header 검사(`Server_mcp_transport_http_headers.validate_2026_request_headers`)는 state 없이 쓸 수 있다.
  - Board 글의 작성자는 agent 이름 문자열(`Agent_id.t`)이다. 읽기 규칙은 Direct 수신자만 강제한다(`Board_access`).
- 하는 일.
  - 계정 서버가 `POST /mcp`를 연다. 경로의 종류는 `Self_authenticated Person_mcp`다. 계정 서버의 표(`Server_account_table.served`)가 이 종류를 받는다.
  - 요청마다 credential을 `Auth_gate.decide`로 판정한다. 본문을 읽기 전에 `Read_auth`로 한 번 판정하고, 도구는 자기가 대신하는 경로의 종류로 다시 판정한다. 호출자는 그 판정의 principal이다. agent 이름, header, 세션 id는 호출자를 정하지 않는다.
  - 서버는 MCP 세션을 만들지 않는다. `Mcp-Session-Id`를 주지 않고, 받은 값을 읽지 않는다. 그래서 PAT를 폐기하거나 사람을 Disable하면 다음 요청부터 거절된다.
  - 답은 JSON 하나다. 긴 연결(SSE)을 열지 않는다. `GET /mcp`는 405다. notification은 본문 없는 202다.
  - method는 `server/discover`, `initialize`, `ping`, `tools/list`, `tools/call`이다. 메시지 검사(`Mcp_request_admission.admit`)는 단일 사용자의 MCP와 같은 함수를 쓴다. 그래서 두 endpoint가 같은 메시지를 같은 답으로 거절한다.
  - 도구는 사람의 경로와 같은 함수를 부른다. 경로의 답이 2xx가 아니면 도구 결과가 `isError`다. 도구 정의에 없는 인자도 `isError`다.
  - 도구의 이름과 설명은 `config/tools/` 아래 TOML에 둔다. 단일 사용자의 도구 목록(`Config.visible_tool_schemas`)에는 넣지 않는다.
- C4-11과 C4-12.
  - C4-11(token 해석이 실패하면 alias를 쓰지 않고 Reject)은 이 경로에서 구조로 선다. 계정 서버의 MCP는 `Mcp_server_eio_caller_identity`를 지나지 않고, 이름을 정하는 다른 길이 없다.
  - C4-12(transport를 세션·PAT에 결속하고 폐기 때 닫기)는 닫을 연결이 없어서 S1b-1에 일이 없다. SSE나 WebSocket을 여는 층(S1b-2)이 C4-12를 한다. `__Host-masc_mcp_session`도 그때 만든다.
- 층.
  - S1b-1a 경로 종류와 뼈대. `Mcp_request_admission`을 단일 사용자의 처리기에서 뽑는다. `POST /mcp`가 위 method를 답한다. 도구는 내 정보(`masc_whoami`) 하나다.
  - S1b-1b Runtime과 Keeper 도구. `masc_my_runtimes`(구독과 Runtime 목록, `Manage_own_provider`), `masc_my_keepers`, `masc_my_keeper_create`, `masc_my_keeper_assign`(`Manage_own_keeper`)이다. Runtime 목록은 배정에 넣을 `runtime_id`를 MCP만으로 알 수 있게 하려고 넣는다. 사람의 화면이 `GET /api/v1/auth/provider-accounts`로 읽는 것과 같다. 도구는 인자를 경로 함수가 읽는 본문으로 다시 써서 넘긴다. 인자의 순서는 답을 바꾸지 않는다.
  - S1b-1c Keeper의 한 턴. `masc_my_keeper_turn`이 `Server_preview_keeper_turn.run`을 부른다. 판정은 경로와 같은 `Auth_preview.keeper_turn_caller`이고, 요청을 인증한 PAT의 범위가 턴을 제한한다(D2-8). 시간 제한, 메시지 길이, 계정마다 한 번에 한 호출은 그 함수의 것이다. 요청은 Runtime이 답할 때까지 열려 있다. 답을 나눠 보내는 일(progress, SSE)은 하지 않는다.
  - S1b-1d 사용 안내와 실제 MCP client로 붙여 본 기록. 안내는 `docs/guides/account-server-mcp.md`다. 기록은 GitHub 로그인과 구독 로그인이 있는 설치에서만 남길 수 있다. PAT를 받으려면 로그인한 세션이 있어야 하고, 한 턴은 실제 구독으로 돈다. 그래서 안내를 먼저 넣고, 기록은 사람이 로그인한 설치에서 잰 뒤에 더한다. 잴 것은 `initialize`부터 `masc_my_keeper_turn`까지의 답과, client의 요청 timeout이 턴보다 짧을 때의 동작이다.
- 시험(S1b-1a).
  - credential 없음, 단일 사용자의 bearer, 폐기된 PAT가 각각 who-am-I 경로와 같은 답으로 거절된다.
  - 세션 cookie로 온 요청은 same-origin과 CSRF token이 있어야 한다.
  - 지원하지 않는 protocol version, JSON이 아닌 본문, batch, 모르는 method, 모르는 도구, 도구에 없는 인자, 본문 상한을 넘는 메시지.
  - 요청마다 protocol을 고르는 개정(2026-07-28)의 요청은 답 header에 그 개정을 받고, routing header가 본문과 다르면 400이다.
- 시험(S1b-1b).
  - 범위에 `Manage_own_keeper`가 없는 PAT는 Keeper 도구에서, `Manage_own_provider`가 없는 PAT는 Runtime 도구에서 경로와 같은 말로 거절된다.
  - Keeper를 만들고, 다시 만들고, Runtime을 배정하고, 목록을 읽은 답이 사람의 경로가 내는 JSON과 같다.
  - 다른 사람은 그 Keeper의 이름을 가져가지 못하고 Runtime을 배정하지 못한다.
- 시험(S1b-1c).
  - 범위에 `Manage_own_keeper`가 없는 PAT, 아무도 만들지 않은 Keeper, 다른 사람의 Keeper, 빈 메시지가 경로와 같은 말로 거절된다. 모두 client가 시작하기 전이다.
  - 실제 client가 답하는 턴은 시험에 없다. S1b-1d에서 실제 구독으로 본다.
- 하지 않는 것: Board, WebSocket, Dashboard 화면(C6), MCP OAuth(C5), SSE와 `subscriptions/listen`, resources와 prompts, 단일 사용자 MCP의 동작 바꾸기, dispatch 전용 MCP credential(설계 §7.3). 401 답에 `WWW-Authenticate`와 protected resource metadata를 싣는 일은 C5가 한다.

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
- F3a는 세 층으로 나눈다. F3a-1은 끈 설치의 부팅과 실행 판정이고, F3a-2는 `masc auth off` 명령이고, F3a-3은 사람 홈이 남은 동안의 native 도구 판정이다. 부팅부터 하는 까닭은 명령의 성공 문구가 끈 뒤의 부팅을 한 번에 말하게 하려는 것이다. 앞의 두 층은 따로 들어가도 안전하다. F3a-1만 있으면 `off`를 쓰는 길이 없다.
- F3a-1(2026-11-10).
  - 4행 판정은 로그를 다시 읽은 상태(`Authz_state.t`)를 싣고 온다(`Made_off`, `Single_user_after_off`). 그래서 끈 설치인데 기록이 없는 단일 사용자 값은 만들 수 없다. `Off_mode_not_supported`는 지운다.
  - 부팅은 그 상태를 `Authz_boot_mode_read.single_user`에 싣는다(`turned_off`). 서버와 stdio는 그 값으로 접근을 게시한다.
  - `Runtime_account_access`가 끈 상태의 시작을 판정한다. 로그의 Keeper 턴(`Off_keeper`), 로그의 Runtime으로 도는 턴(`Off_runtime`), 사람 본인 계정(`Off_own_account`)을 거절한다. 사람 runtime root(`.masc/accounts`) 아래 홈 위의 시작도 거절한다(`Off_person_home`). 운영자 홈과 상속 홈은 운영자 것이다.
  - 운영자 호출(probe, verification, Fusion)은 Runtime id를 싣지 않는다. 그래서 사람 Runtime은 홈으로 막는다. 1단계의 사람 계정은 공식 클라이언트 로그인(`server_setup_account_login`의 `Person`)으로만 생기고, 그 홈은 늘 `.masc/accounts/<namespace>` 아래다.
  - 홈은 적힌 철자와 실제 경로를 둘 다 본다(`Runtime_account_home_layout.under_persons`). 실제 경로는 있는 가장 깊은 조상을 풀고 그 아래를 적힌 대로 붙인다. 링크, 대소문자만 다른 철자, 아직 없는 홈도 사람 쪽으로 읽힌다.
  - `masc auth bootstrap`(`Turned_off`)과 `masc auth invite`(`Accounts_turned_off`)는 끈 설치에 아무것도 쓰지 않는다.
  - account-home 점유: 1단계 코드에는 점유 기록이 없다(lease 저장소는 E1). `Release_pending`으로 바꿀 대상이 없다.
  - 끈 뒤 단일 사용자 Keeper의 native 도구는 `.masc/accounts`를 읽을 수 있다. D3c가 다계정에서 막은 경로와 같고, 지우고 설치(B3d-3)도 같은 상태다. 결정(2026-11-10 사용자): 사람 홈이 `.masc/accounts` 아래 남아 있는 동안 Keeper 턴은 native 도구 없이(`Native_none`)만 돈다(F3a-3). 그동안 운영자 Keeper가 native 도구를 못 쓰는 비용은 받아들였다. 사람 홈은 S1a-3 전에는 `masc auth preview`의 로그인으로만 생긴다.
- F3a-2(2026-11-10).
  - `masc auth off`는 bootstrap처럼 BasePath lease를 쥐고 `Authz_off.turn_off`를 부른다. 공개 주소와 익명 쓰기 설정은 읽지 않는다. 끄기는 로그와 외부 저장소만 본다.
  - 로그의 마지막 모드 사건이 `Multi_account`를 만들었고 외부 저장소가 로그와 맞을 때만 쓴다. 설정은 보지 않는다. 운영자가 `account_mode`를 먼저 뺐으면 부팅은 3행으로 멈추고, 거기서도 끌 수 있다.
  - 모드 사건이 없으면 `Never_activated`, 이미 껐으면 `Already_off`다. 저장소가 답하지 않으면 `Store_absent`, 맞지 않으면 `Store_mismatch`다. 맞지 않는 저장소 위에 `off`를 쓰면 다음 부팅이 10행으로 멈추기 때문이다. 이때는 아무것도 쓰지 않는다.
  - 기록은 구역(`Authz_zone.commit`)으로 쓴다. 작성자는 `Local_operator`, 종류는 `Mode_event`다. 그래서 외부 저장소가 같은 기록을 받는다.
  - 판정 뒤 연 구역의 모드가 `Multi_account`가 아니면 `Mode_moved`로 끝난다. lease 아래에서는 판정과 구역이 같은 로그를 읽는다. 타입이 허락하는 갈래라 오류로 돌려준다.
  - `config.json`은 쓰지 않는다. 설정은 운영자의 요청이다(§5.1). 끈 뒤에도 설정이 `Multi_account`를 물으면 9행이다. 성공 문구가 `account_mode`를 빼라고 말한다.
  - bootstrap 도움말과 성공 문구는 `masc auth off`를 안내한다. 3행 거부 문구도 `masc auth off`를 말한다. 8행은 저장소를 믿을 수 없어 끌 수 없으므로 말하지 않는다.
  - 시험은 실제 활성화(`Authz_activation.activate`)로 만든 설치에서 7행과 3행의 끄기, 끈 뒤의 4행·9행, 두 번째 끄기, 쓰지 않는 네 경우를 본다. F3a-1의 시험 셋도 손으로 쓰던 `off` 기록 대신 `Authz_off.turn_off`를 부른다.
- F3a-3(2026-11-11).
  - 판정은 `Runtime_account_access.authorize_native` 한 곳이다. `Native_none`은 어느 mode에서나 돈다. 단일 사용자 프로세스의 `Native_read`·`Native_full`은 workspace에 `.masc/accounts`가 없을 때만 돈다. 있으면 `Native_tools_reach_person_homes`로 거절한다.
  - 있는지는 턴을 시작할 때마다 그 이름을 읽는다(`Runtime_account_home_layout.persons_remain`, `lstat` 한 번). 로그의 끈 상태는 보지 않는다. 그래서 끈 설치와 로그만 지운 설치가 같은 답을 받는다. 운영자가 `.masc/accounts`를 지우면 다음 턴부터 native 도구가 돈다. 다시 부팅하지 않는다.
  - 안은 읽지 않는다. 빈 디렉터리, 링크, 같은 이름의 파일도 남은 것으로 센다. 목록을 읽으면 읽기 오류와 목록의 끝을 가릴 수 없어서(OCaml의 `readdir`은 둘 다 `End_of_file`이다) 오류가 "비었다"로 읽힌다. 그 디렉터리는 사람의 로그인만 만든다(`server_setup_account_login`).
  - 이름이 없으면 남은 것이 없다. 거기까지의 경로를 읽을 수 없으면 답하지 않고 거절한다(`Person_homes_unread`).
  - Keeper 턴은 자세를 정하는 자리(`Keeper_official_client_host.resolve_native_posture`)에서 세션을 잡기 전에 판정한다. 네 클라이언트(Claude Code, Codex, Antigravity, Muse)가 이 함수를 지난다. 거절은 `keeper.tools.native`의 config 오류이고, Keeper의 도구 화면에는 `native_posture_rejected`로 보인다. 클라이언트가 뜨는 자리의 판정(D3c)은 그대로 둔다. 그 자리의 거절은 `Invalid_config`라서 Keeper runtime이 `Protocol_failed`(모호함)로 적고 세션을 복구 대기로 보낸다. 앞의 판정이 없으면 뜨지도 않은 턴마다 세션이 갈린다.
  - Antigravity와 Vibe의 모델 턴도 이 판정을 지난다. 두 클라이언트는 다계정에서 host 계정 판정(D3b)이 통째로 막아서 native 판정을 부르지 않았고, 단일 사용자에서는 그대로 돌았다. Antigravity는 native 설정을 쓰는 `Runtime_antigravity_home.prepare_native_tools`가 규칙을 쓰기 전에 판정한다. Keeper 턴, Fusion 패널, verify, capability probe가 턴마다 이 함수를 거친 뒤 `run_turn`을 부른다. Vibe는 `Runtime_vibe_cli.run`이 판정한다. Vibe agent의 도구는 MASC가 정하지 않으므로 가장 넓은 자세(`Native_full`)로 판정한다.
  - `.masc/accounts`가 있는 동안 돌지 않는 것: Codex와 Muse의 모델 턴(두 클라이언트에는 `Native_none`이 없다), `keeper.tools.native`가 `none`이 아닌 Claude Code·Antigravity Keeper, Fusion의 Antigravity 패널(`Native_read`)과 Vibe 패널. 도는 것: `Native_none`인 Claude Code·Antigravity Keeper, API provider Runtime, 모델 턴이 아닌 호출(계정 확인, 사용량, 모델 목록).
  - MASC 도구 쪽은 이 층이 바꾸지 않는다. Keeper 컨테이너 lane과 MASC Read가 `.masc/accounts`에 닿지 못한다는 D3c-1의 시험(`test_keeper_account_home_reach`)은 계정 mode를 읽지 않으므로 단일 사용자에서도 같다. `Remote_ssh`가 같은 host를 가리키는 경우는 그 시험 밖이고 결정 대기다.
  - 시험: `test_runtime_account_access`가 실제로 게시한 단일 사용자 프로세스 하나에서 이름 없음, 빈 디렉터리, 사람 root 하나, root만 지운 뒤, 디렉터리를 지운 뒤, 같은 이름의 파일, 읽을 수 없는 경로를 차례로 본다. `Native_none`은 모든 경우에 돈다. Vibe는 사람 root 옆에서 프로세스를 띄우지 않고 `Native_tools_refused`로 끝난다.
  - 독립 리뷰(2026-11-11, 이 층의 diff만 본 새 맥락): P0·P1 없음, P2 셋, P3 둘. 지적은 코드에서 확인했다.
    - P2. 목록 읽기가 실패하면 "없음"으로 답했다. 목록을 읽지 않게 바꿨다(위).
    - P2. Keeper 턴의 거절이 모호한 실패로 기록됐다. 세션을 잡기 전에 판정한다(위).
    - P2. Antigravity의 판정이 프로세스를 띄우는 `run_turn`이 아니라 설정을 쓰는 자리에 있다. 지금 호출처 넷은 턴마다 설정을 다시 쓴다. 거절하면 앞 턴의 설정이 디스크에 남고 아무것도 뜨지 않는다. `run_turn`이 설정을 쓴 증명을 받게 하는 일은 하지 않았다.
    - P3. 주석과 `.mli`가 "아무것도 준비하지 않는다"고 했는데 Keeper 턴은 workspace를, `prepare_native`는 계정 세대를 먼저 고른다. 문장을 고쳤다.
    - P3. 판정은 프로세스가 게시한 base path의 `.masc/accounts`만 읽는다. 다른 base path에 게시한 host 도구(`masc` CLI의 Fusion, probe)는 같은 OS 사용자가 읽을 수 있는 다른 workspace의 사람 홈을 보지 못한다.
  - 시험하지 않은 것: Antigravity의 거절(홈 준비가 macOS 로그인 keychain에 기댄다), Keeper 쪽 판정의 거절(시험 실행 파일이 게시하는 base path를 시험이 고르지 못한다).

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
