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
| 호출자 alias | 토큰이 있고 이름이 Ephemeral인데 토큰 해석이 실패하면 경고와 카운터만 남기고 alias를 그대로 돌려준다. `Strict`와 `Dry_run`이 같은 갈래이고, `MASC_AUTH_STRICT`가 없거나 모르는 값이면 `Dry_run`이다. | `lib/mcp_server_eio_caller_identity.ml:157-194`, `lib/auth/auth_strict_mode.ml:8-20` | C4가 다계정에서 이 경로를 없앤다. 모드 값만 바꿔서는 이 경로가 사라지지 않는다. |
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

층은 모두 31개다. 크기가 20k token을 넘는 층은 시작할 때 쪼갠다. A4b도 도구가 만든 변환과 사람이 고친 부분의 인증·바인딩 diff를 함께 읽고, 작업 단위가 이 한도를 넘으면 나눈다.

### A. 측정과 기반

이 그룹의 층은 `Single_user` 동작을 바꾸지 않는다. A2는 B2 다음에 쌓고, `account_mode`를 읽는 층(C2, C3, C4, D2)보다 앞에 둔다. C2는 OIDC 경로를 `Multi_account`에서만 열고, C3은 설계 §5.2가 모드로 갈라 놓았다. C4와 D2도 모드를 읽는다.

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| A1 | 모든 경로가 지금 인증을 어떻게 처리하는지 실제 요청으로 잰 기준선. HTTP/1 경로는 라우터를 격리한 base path로 띄워 무인증 요청과 잘못된 bearer 요청을 보낸다. H2, `/mcp` 사전 처리, `/ws`는 실제 소켓으로 따로 친다. 결과는 `docs/evidence/`에 둔다. 동작은 바꾸지 않는다. | §5.3, §11-1 | - |
| A2 | `auth_config`에 닫힌 `account_mode`(`Single_user`, `Multi_account`)를 선택 필드로 두고, 부팅 때 모드를 한 번 정해 실행 중에 바꾸지 않는다. 파일이나 필드가 없으면 `Single_user`이고 알 수 없는 값은 부팅을 거부한다. 필드는 `save_auth_config`가 다시 쓰는 `auth_config` 레코드 안에 둔다. 설정을 `authz.jsonl`과 외부 고수위에 대조하는 판정은 설계 §5.1의 표가 정한다. `Multi_account`는 `enabled=false`, `require_token=false`, `MASC_ALLOW_ANONYMOUS_MUTATIONS=true`를 거부한다. 값을 써 넣는 단계는 없고, 변경 기록에 `Fresh state required`를 적지 않는다. 세부는 표 아래 A2 범위다. | §5.1, §5.3, §8.2~8.4 | B2 |
| A3 | 권한 도메인의 닫힌 타입(Principal, Effect, Channel, Runtime_scope, Authorization_scope, ExecutionContext, grant, policy, record의 author)과 판정식 `allowed`. I/O 없는 순수 코드다. 시험은 deny 기본, `Empty`, `Not_pat`, scope·channel·effects 교집합을 표로 확인한다. | §4, §6.2, §6.3 | - |
| A4a | 경로 인증 종류의 닫힌 타입을 만든다. `Route_access.t`는 라우터의 `route.access`가 들고 있는 데이터이고, `Server_route.auth`는 핸들러 타입을 나르는 GADT이며, 종류를 필수로 받는 등록 함수(`Server_route.get` 등)가 종류에 맞는 래퍼를 씌운다(`docs/rfc/RFC-typed-route-auth.md` §3). 옛 등록 함수는 이 스택 안에서만 `Unclassified` 종류로 이어 둔다. 변환 도구 `route_auth_codemod`를 함께 넣는다. 도구는 서버 코드와 닿지 않아 별도 PR로 낸다. 컴파일러 파서로 등록을 읽고 해당 글자 범위만 고쳐 쓰며(나머지 서식은 그대로), `--write`는 파일을 바꾸고 `--strict`는 바꾸지 못한 등록이 남으면 실패한다. 같은 경로라고 말할 수 있는 모양만 바꾸고 나머지는 이유와 함께 목록에 남긴다. 도구는 시험이 있다. 인벤토리 도구가 `access`를 출력한다. 동작은 바꾸지 않는다. | §5.3 | A1 |
| A4b | 도구로 만든 변환 한 층. 2026-10-28의 등록 383곳과 당시 도구 변환 296곳·수동 결정 87곳은 과거 집계다. 사용하려는 도구의 정확한 head에서 열린 변경 요청을 해소하고 독립 소스 리뷰를 받은 뒤, 고정한 서버 source와 도구 head에서 전체 등록·변환·보류 수를 다시 센다. 도구가 남긴 곳과 수동 변경은 결정표에 종류(`Self_authenticated`의 사유, `Always_public`, 도우미 안쪽 래퍼의 종류)와 사유를 적는다. 이름 붙은 핸들러는 다른 파일의 사용까지 확인하고, 모든 변환 diff에서 원래 래퍼와 인증 종류·식별자 바인딩을 검토한다. `--allow-early-evaluation`은 각 계산식의 호출 간 값 불변성, 부작용·예외 및 정의·등록 위치의 동일 바인딩 근거를 기록한 경우에만 쓴다. 근거가 없으면 자동 변환을 수락하지 않고 수동으로 결정한다. 바꾼 뒤 안 쓰게 된 `open Server_auth`를 지우고 A1 상태 코드를 다시 측정하며 인증된 허용·권한 부족 거부와 관련 prefix 및 H1/H2 시험을 확인한다. A1의 무자격 상태 코드 일치만으로 전체 권한 동등성을 주장하지 않는다. `GET /api/v1/board/flairs`(#46569)의 종류를 정하고, 병합 직전에 main 위에서 도구를 다시 돌려 새 등록을 반영한다. | §5.3 | A4a |
| A4c | HTTP/2 게이트웨이(`server_h2_gateway.ml`, `server_h2_gateway_routes_extra.ml`, 약 72곳)가 같은 종류 타입을 쓴다. HTTP/1과 HTTP/2가 같은 경로를 다른 종류로 등록하면 실패하는 시험을 둔다. 한쪽에만 있는 경로는 시험 안에 사유와 함께 이름으로 적는다. | §5.3 | A4b |
| A4d | 스택의 마지막 층. `Unclassified`, 옛 등록 함수, `is_public_read_path`, 결정표를 지운다. 이 층이 들어가면 main에는 종류 없는 등록이 없고 새 등록은 종류 없이 컴파일되지 않는다. 인벤토리의 route 표를 C4가 읽는다. A4a는 2026-10-28에 먼저 병합됐고(#46590), A4b~A4d는 가능하면 네이티브 스택으로 맨 위 PR에서 병합한다. 층마다 병합 시점에 컴파일되고 동작이 같아야 한다. 변환 도구는 이 스택에 들어가지 않고, 열려 있던 PR이 새 등록 함수로 옮겨진 뒤 따로 지운다. | §5.3, §11-1 | A4c |

**A2 범위**

- 판정은 설정, `authz.jsonl`의 마지막 모드 사건이 만든 모드, 외부 고수위(B2)를 모두 읽는 전체 함수이고 거부 사유를 모두 돌려준다. 결과와 마지막 모드 사건이 만든 모드는 닫힌 변형이다. 모드 사건은 종류 `Mode_event`(B2가 더한다)의 레코드다. 이 층의 만든 모드는 없음과 `Multi_account`(`Fresh_bootstrap`이 만든다)이고, F3이 `off`를 더하면 컴파일이 이 판정에서 멈춘다.
- 판정 결과가 활성화 전 요청(설계 §5.1 표의 `Multi_account`, 없음, 없음)이면 부팅 코드가 `Multi_account_not_activatable`로 거부한다. 호스트 로컬 bootstrap이 아직 없기 때문이다. B3이 이 거부를 거둔다(B3 범위).
- 부팅은 `config.json`을 JSON 파서로 통째로 읽고 최상위 객체의 `account_mode` 멤버만 보는 얇은 읽기를 둔다. 문자열이나 정규식으로 멤버를 떼어 내지 않는다. 파일이 JSON이 아니거나 최상위가 객체가 아니면 설정은 없는 것으로 읽고 경고 한 줄을 남긴다(지금 동작과 같고 요청 때 503이다). 파일이 JSON 객체이면 다른 필드가 틀려도 `account_mode` 멤버를 읽는다. 멤버는 정확히 `"Single_user"`나 `"Multi_account"` 문자열이어야 하고, `null`, 숫자, 객체, 다른 대소문자, 두 번 나온 멤버는 알 수 없는 값이다. 알 수 없는 값은 `auth_config` 디코더가 파일 전체를 거절하더라도 부팅을 거부한다. `Multi_account`의 흔적은 설계 §5.1 표의 다른 두 열이 거부한다.
- 설정의 `account_mode`를 읽는 곳은 이 부팅 판정 하나다. 다른 층은 판정 결과를 받고, 설정 파일을 다시 읽어 모드를 정하지 않는다.
- `authz.jsonl`이 없는 것과 있는데 읽지 못하는 것을 구분한다. 외부 저장소도 같다. `authz.jsonl`은 끝이 잘린 마지막 줄을, 외부 저장소는 끝이 잘린 마지막 항목을 열 때(판정 1~5를 돌리기 전에) 잘라 낸다(B1b, B2). 두 자르기는 서로 읽지 않아서 어느 쪽을 먼저 해도 결과가 같다. `authz.jsonl`에 남은 줄이 없으면 마지막 모드 사건이 만든 모드가 없는 것이다(설계 §5.1 표 둘째 열 `없음`). `Fresh_bootstrap`이 도중에 죽어 `Intent_pending`만 남은 외부 저장소의 외부 고수위는 `없음`이다(설계 §5.1).
- 부팅 코드가 `Authz_log.open_at_start`를 부르는 것은 BasePath lease를 쥔 뒤다. B1b는 lease 증거를 인자로 받지 않으므로 이 순서는 문장이 지킨다.
- 외부 고수위는 부팅이 설치 기록에서 외부 저장소의 위치를 읽을 수 있을 때만 `있음`으로 볼 수 있다. 설치 기록은 §6의 결정 2가 정했고, 읽고 쓰는 코드는 B2가 만든다. A2는 B2 다음에 쌓으므로 그 코드를 쓴다. 설치 기록을 잃은 설치의 구멍은 §7의 위험 2에 적었다.
- 시험은 A2가 `off`가 없는 행(1~3, 5~8, 11)을 하나씩 보고, `off`가 있는 행(4, 9, 10)은 F3이 본다. 5행은 B3 전까지 `Multi_account_not_activatable`로 나온다. 그 밖에 다섯 가지를 본다. 거부 사유가 둘 이상일 때 모두 돌려주는지, 필드가 든 `config.json`을 `enable_auth`·`disable_auth`·`prepare_login_auth`가 다시 써도 필드가 남는지, 잘린 `config.json`과 마지막 모드 사건이 만든 모드 `Multi_account`를 짝지어 3행 거부가 나오는지, `account_mode`가 알 수 없는 값인 `config.json`이 다른 필드가 틀려도 부팅을 거부하는지, `account_mode`의 입력 모양이다. 입력 모양은 멤버가 두 번 나오거나 `null`·숫자·객체거나 대소문자가 다르면 부팅을 거부하고, 최상위가 배열이나 `null`이면 설정 없음으로 읽는지 본다.

### B. 권한 저장소

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| B1 | `authz.jsonl`을 파일에 쌓는 저장소다. B1a는 한 줄의 형식과 author 짝 검사, B1b는 파일이다. 세부는 표 아래 B1 범위다. lease 계열 group commit은 E1에서 붙인다. | §6.3, §8.1 | A3 |
| B2 | backup 밖 append-only 저장소(설계의 외부 저장소·revocation ledger)와 `Intent_pending`/`Committed`. 저장소는 Intent 상태를 기록하고(B2a), 객체의 scoped epoch 최고값과 artifact별 `credential_generation`은 epoch를 올리는 사건을 처음 쓰는 층이 더한다. Intent가 가리키는 것은 `Grant`·`Credential`·`Principal`·`Runtime` 중 하나이거나 모드 사건의 workspace다(§4.5). 같은 writer lock 구역, 판정 1~5, `AuthorizationUncertain`, `Revocation_pending` 게이트, `Fresh_bootstrap`, 외부 저장소의 위치를 적은 설치 기록(§6의 결정 2). 세부는 표 아래 B2 범위다. | §4.5, §8.2~8.4 | B1 |
| B3 | Principal·Admin_assignment·WorkspaceMembership·초대 저장소, 마지막 Admin 보호, 호스트 로컬 bootstrap(`Fresh_bootstrap`을 부르고 A2의 `Multi_account_not_activatable` 거부를 거둔다), ID 발급 규칙, principal 삭제 사건. 세부는 표 아래 B3 범위다. | §4.1, §5.1 | B1, B2, A2 |
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

- 모드 사건용 레코드 종류 `Mode_event`를 `Authz_record.Kind`에 더하고 작성자는 `Local_operator`로 정한다(`Authz_record.admits`가 컴파일을 멈춘다). 설계 §6.3은 `Fresh_bootstrap`만 `Local_operator`에게 주었고 `off`와 `reactivate`의 작성자는 F3이 정한다. 본문은 `event`와 `workspace_id` 두 멤버이고 이 순서가 아니면 거절한다. `event`는 `fresh_bootstrap`, `off`, `reactivate` 중 하나이고 외부 저장소의 `Change.Mode`와 같은 낱말이다. 모듈 `Authz_mode_event`가 본문을 읽고 쓴다. 사건이 만드는 모드(`Multi_account`, `off`)는 부팅을 판정하는 A2가 정한다. 설계 §8.4는 `Fresh_bootstrap`이 빈 Recovery_manifest와 초기 generation도 같은 append로 확인한다고 하는데, 그 둘은 아직 없는 층의 것이라 본문에 넣지 않는다. 필드가 늘면 하드 컷이다.
- `Fresh_bootstrap`이 `Intent_pending`을 쓴 뒤 죽은 설치는 판정 3으로 닫고 `Fresh_bootstrap`을 다시 허용한다(설계 §5.1의 `없음`).
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
- `change`는 사건과 그 대상이 짝을 이루는 닫힌 변형이다. 권한 사건 `Authz {event, subject}`는 `event`가 `Grant`, `Revoke`, `Disable`, `Delete`, `Block`, `Purge`, `Policy_revoke`, `Credential_replace` 중 하나이고 `subject`는 `Grant`·`Credential`·`Principal`·`Runtime` 중 하나다. 모드 사건 `Mode {event, workspace_id}`는 `event`가 `Fresh_bootstrap`, `Off`, `Reactivate` 중 하나다. 설계 §8.2가 `subject`에 `Workspace`를 더한다고 한 것을 타입으로는 이렇게 나눈다. 모드 사건에 권한 사건의 대상이 붙거나 그 반대가 되는 짝을 만들 수 없게 하고, A3의 `Subject`는 건드리지 않는다. 권한 축소 사건(§8.3)인지는 `change`를 `match`로 가른다(`Grant`와 모드 사건은 축소가 아니다).
- 파일의 상태는 줄을 접어 만든다. 대기 중인 intent는 최대 하나이고, 마지막 `Committed`의 해시, `Aborted_intent` 목록, `Committed`가 된 `Fresh_bootstrap`의 workspace_id를 가진다.
- 줄이 이어야 할 것은 §8.2의 순서 그대로다. `Intent_pending`은 대기 중인 intent가 없을 때만 올 수 있다. `Committed.record_hash`는 대기 중인 intent의 `intended_next_record_digest`와 같아야 하고, `Aborted_intent`는 대기 중인 intent와 모든 필드가 같아야 한다. 하나 더, `Fresh_bootstrap`을 닫는 `Committed`는 이미 `Fresh_bootstrap`이 `Committed`로 닫혀 있으면 거절한다. 조용히 workspace_id를 덮어쓰지 않으려는 것이다. 규칙을 어기는 줄은 이을 때 `Rejected`이고 열 때 `Line_rejected`(§5.1의 `읽지 못함`)다.
- 한 줄의 바이트는 `Authz_external_store`가 직접 쓴다(`Authz_record`와 같다). 멤버 순서가 정해져 있고, 읽은 줄이 `to_line`이 쓰는 줄과 다르면 거절한다. `append`는 쓰기 전에 줄을 되읽어서 쓰려던 항목과 같은지 비교한다(`Authz_jsonl_file`의 `equal_record`). principal을 쓰는 방법은 `Authz_record`와 같은 것을 쓴다.
- epoch 최고값과 `credential_generation` 항목은 이 층이 정하지 않는다. 설계 §8.2의 `Intent_pending` 필드에 epoch 값이 없고, epoch를 올리는 사건을 쓰는 코드는 B3 전에 없다. 그 사건을 처음 쓰는 층(B3의 principal 사건)이 항목과 비교 판정을 같이 더한다. 그전까지 외부 고수위의 `맞음`은 마지막 `Committed`가 replay에 있는지와 대기 중인 intent의 판정(B2c)으로 정한다. 하드 컷이라 이전 형식을 읽는 코드는 두지 않는다.
- 시험은 줄의 바이트(모든 사건의 낱말 포함), 모든 `change`의 읽고 쓰기, 규칙을 어기는 파일과 줄, 끝이 잘린 마지막 항목의 자름, 다시 열었을 때의 상태를 본다.

**B3 범위**

- ID 발급(§4.1): Human `user_id`는 OS CSPRNG가 만든 128비트 이상의 값이고 `(iss, sub)`나 email에서 유도하지 않는다. 발급은 writer lock 안에서 현재 principal과 ledger의 `Delete` 기록을 대조한다. `user_id`가 겹치면 다시 뽑고, `service_id`가 겹치면 등록을 거부하고, ledger를 읽지 못하면 발급하지 않는다.
- 호스트 로컬 bootstrap이 `Fresh_bootstrap`(B2)을 부른다. 이 층이 A2의 `Multi_account_not_activatable` 거부를 거둔다. 부팅 코드의 거부 한 줄을 지우고, 활성화 전 요청일 때 호스트 로컬 bootstrap만 연다. 외부 저장소의 위치(§6의 결정 2)는 B2 전에 정해지므로 이 층이 열릴 때 이미 있다. 서버 밖 프로세스가 `Fresh_bootstrap`을 실행할 때 BasePath lease를 쥐는지는 이 층이 정한다.
- 삭제 사건(§4.1): `(iss, sub)`는 `authz.jsonl`의 사건에만 싣고 ledger의 `Delete` 기록에는 ID만 둔다.
- 표시가 붙은 상태는 D6에서 처음 생긴다. D6 전에는 삭제가 올릴 `Purge_pending` 대상이 없다.
- 접힌 상태 `Authz_state.t`는 층별 하위 상태를 필드로 가진 레코드다. replay의 적용 함수 `step`은 `Kind.t`를 빠짐없이 match해 하위 모듈로 보낸다. 층마다 필드 한 줄과 갈래 한 줄이 는다. 이 타입은 저장소(B1b)가 아니라 `Authz_state` 모듈이 붙인다.
- `step`은 replay가 줄마다 부르는 적용 함수다. append 전에 같은 `step`을 돌려 보면, 쓴 줄이 replay에서 거절되는 일이 없다. 바뀔 수 있는 정책은 판정(decide)에만 둔다. `step`을 엄격하게 바꾸면 hard cut이다.
- 모든 projection은 같은 head에서 읽는다. 상태 보관자가 `Authz_state.t` 하나를 불변 값으로 한 번에 발행한다. head가 다른 두 projection을 짝지으면 어느 head에도 없던 조합이 나온다. 예를 들어 Bob 비활성(100번 줄), grant G 회수(101번 줄), Bob 재활성(102번 줄)일 때 grant를 100에서, principal을 102에서 읽으면 "Bob 활성 + G 유효"가 된다.

### C. 인증

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| C1 | OIDC ID token 검증 의존성 결정. `jose`와 `jwto`를 현재 pin(x509 >= 1.0, < 1.2), OCaml 5.5, RS256, `alg=none` 거부, JWKS `kid` 선택으로 비교한 근거를 남기고 하나를 추가한다. 고정한 JWKS와 token 벡터로만 시험하고 네트워크를 쓰지 않는다. | §5.2 | - |
| C2 | Google OIDC code + PKCE 로그인, `(iss, sub)` 결속, 초대 소비(동시 소비는 409). 삭제된 principal의 `(iss, sub)`로 등록하거나 소비하면 Admin 화면과 감사 기록에 `previously_deleted`를 보인다. 입장을 막지 않는다. 이 표시는 `authz.jsonl`을 읽어 만들고 principal 레코드에는 저장하지 않는다(§5.1-6). 도메인 정책(`oidc.admission_request_domains`)이 있으면 미등록 `(iss, sub)`의 입장 요청 조건(`hd`·`email_verified`)과 입장 요청 기록·Admin 승인(§5.1-2c, §5.1-7)을 함께 낸다. 입장 요청의 개수 상한과 상한을 넘었을 때의 동작, 만료 시간, 종단 요청의 보존 기간을 이 층에서 정한다. 입장 요청까지 담으면 층이 크므로, 20k token을 넘으면 입장 요청을 C2b로 쪼갠다(§3 머리말 규칙). 시험 벡터에 `hd` 없음, `hd` 불일치, `email_verified=false`, 정책 아래에서 (a)나 (b)로 들어오는 `hd` 없는 사용자의 로그인 허용, `hd` 대소문자(`A.com`), 승인 때 요청의 도메인이 정책에 없거나 정책이 비어 있는 경우(승인 거부), `Pending` 중 재로그인(새 요청 없음), 두 Admin의 동시 승인(409)과 승인·거절이 겹친 경우(User가 생긴 쪽이 이김), (a)나 (b)로 User가 생긴 뒤 같은 `(iss, sub)`의 `Pending`이 `Superseded`로 읽히고 승인 대기 목록에 나오지 않는 경우, 거절 뒤 재로그인(새 요청 없음)과 (a)로의 입장, 만료된 요청의 승인 거부와 새 요청 허용, 시계가 되감겨 `Expired`가 `Pending`으로 돌아와도 승인 검사가 같은 시계를 쓰는 경우, 이미 입장한 요청에 거절을 누르면 409, 승인된 요청의 User 삭제 뒤 승인 대기 목록에 되살아나지 않는 경우와 새 요청 허용, `Superseded`였던 요청의 User 삭제 뒤 `previously_deleted`와 함께 `Pending`으로 보이는 경우, 복원으로 요청 저장소가 뒤처져 `Pending`이 남은 경우(User가 있으면 승인 대기 목록에 나오지 않는다), `previously_deleted` 표지가 있는 `(iss, sub)`의 입장 요청 화면, `Disabled` 등록 사용자의 로그인(정책 면제가 §4.1 Disabled 규칙을 덮지 않는다), 만료됐거나 취소된 초대 token을 넣는다. | §5.1, §5.2 | A2, B3, C1 |
| C3 | 다계정에서 `__Host-` 세션·transaction·mcp 쿠키, 세션에 결속한 CSRF 토큰, 출처 검사, cookie와 Bearer가 함께 오면 거부, WS/SSE 결속과 폐기 때 닫기, 원격 query credential 차단. | §5.2, §5.3 | A2, C2 |
| C4 | scoped PAT와 Service credential 레코드(principal + `Pat_scope`), 새 `Auth_gate.decide`로 HTTP strict와 MCP caller strict 통합, 다계정에서 caller alias 유지·workspace secret(HTTP 복구 grace 포함, `auth.ml:216`)·auth disabled 경로 제거, `agent_credential` 읽기 거부. `Mcp_oauth_token`은 C5 전까지 Reject. | §5.3 | A2, A3, A4d, C3 |
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
| E1 | `Lease_state`와 `with_lease` 출구 규칙(§7.1), `consume` 한 번, 재기동 규칙, attempt 종단 셋(`Failed(Outcome_unknown)`, `Failed(Not_started)`, `Cancelled_before_effect`, §9-5), lease 계열 group commit. group commit은 B2의 writer lock 구역(`Intent_pending`부터 `Committed`까지) 동안 끼지 않는다(§8.2-1). 메모리는 이력이 아니라 상태에 묶는다. lease는 자원별 단조 카운터라서(§7.1) 고수위와 열린 lease만 들고 있어도 종단 뒤의 두 번째 `consume`을 판정한다. 시간 기준 가지치기는 두지 않고, 상태는 줄 순서만의 함수다. 증가량(줄/일)과 기동 replay 시간은 Keeper 300 부하에서 잰다(§6의 결정 6). 위험 9의 결정(§7, `Single_user`의 lease record 위치)이 없으면 E1은 시작하지 않는다. | §7.1, §8.2-1, §9-3~9-5 | B1, D2 |
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

- `off`와 `reactivate`는 모드 사건(종류 `Mode_event`)으로 `authz.jsonl`과 외부 저장소에 남는다. 두 사건의 작성자는 이 층이 정한다. 작성자 검사는 레코드 종류 단위라서, `Local_operator`가 아닌 작성자가 필요하면 이 층이 종류를 더한다(`Authz_record.admits`가 컴파일을 멈춘다). A2의 부팅 판정이 마지막 모드 사건이 만든 모드를 읽는다. `off` 뒤 설정이 `Single_user`이면 multi-owned record를 읽기 전용으로 둔 `Single_user`로 부팅하고, 설정이 `Multi_account`이면 `reactivate` 요청이다. `reactivate`는 §10.5의 `Recovery_manifest`와 `Pending` 절차가 있어야 하고, 그 절차가 없으면 `Reactivation_not_ready`로 거부한다. 절차를 마치면 `reactivate` 사건을 `authz.jsonl`과 외부 저장소에 남긴다.
- on→off 전환은 multi-owned record를 읽기 전용으로 보존하고 legacy 공유 token·admin으로 실행하지 않는다. 진행 중인 multi dispatch는 §9-5에 따라 종결하고 session은 닫는다. account-home 점유는 `Release_pending`으로 바꿔 unmount를 확인한 뒤에만 Released로 한다. 다시 켜면 같은 `Recovery_manifest`와 `Pending` 절차를 거친다.
- `masc auth recovery --base-path <path>`는 인증 가능한 Admin이 0명이거나 IdP를 쓸 수 없을 때 연다. 호스트 관리자와 root 소유 일회용 recovery 파일이 필요하다. 실행자·사유·시각·결과·파일 digest·파기 결과를 append-only audit와 Board에 남긴다. 원격 break-glass는 없고 활성화 전에 리허설한다. 이 경로에서 Local_operator는 `Admin_assignment`를 새로 발급할 수 있고, 발급받은 principal의 grant와 `Cleared`에는 관여하지 않는다.

## 4. 순서와 첫 마일스톤

- A2, B3, B4를 뺀 A, B, C1은 서로 거의 독립이라 병렬 스택으로 쌓을 수 있다. 나머지 순서는 층 표의 선행 열을 따른다.
- D2와 D3은 `Single_user`에서 동작을 바꾸지 않도록 `Runtime.authorize`가 모드에 따라 근거를 달리 발급해야 한다. 설계 §6.1이 이 점을 정한다. 이 근거가 없으면 D2는 시작하지 않는다.
- 설계 §11의 readiness가 복구 리허설과 official lane 격리 증거를 요구하고, 설계 §10.5가 최초 활성화 때 미분류 0을 요구한다. 그래서 F1~F4와 E3 없이는 원격 다계정을 열 수 없다. 그 앞까지의 층은 다계정을 켜지 않은 채 main에 들어갈 수 있다.
- 첫 마일스톤은 A~D3이다(2026-10-27 사용자 결정). `Single_user` 동작은 그대로이고 타입과 저장소와 로그인 경로만 들어간다. C5는 OAuth 스택이 병합된 뒤에만 열리므로 병합 시점에 따라 이 마일스톤 안이나 밖에 놓인다. D4~D6, E, F는 이 마일스톤이 병합된 뒤에 연다.
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
| 복구 리허설 | F2, F3 |
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

- Goal은 이 계획이 승인된 뒤에 만든다. 성공조건은 층마다 병합된 PR이 하나씩 있는 것이다. 지표는 병합된 층 PR 수이고 목표값은 31이다.
- Task는 층마다 `goal_id`를 붙여 만든다. 층 하나가 Task 하나이고, PR 번호는 Task에 적는다.
