# 다계정 Google OIDC·Runtime 권한 구현 계획

- 날짜: 2026-10-27
- 상태: 초안. 설계의 P0~P2 해소와 독립 판정이 끝나기 전에는 코드 층을 시작하지 않는다.
- 설계: `docs/superpowers/specs/2026-10-27-multi-account-oidc-runtime-authorization-design.md` (PR #46428)
- 코드 대조: main `90dd18193c8`. 아래 사실은 이 커밋에서 읽은 것이다.

이 문서는 설계를 층(PR)으로 나누는 순서와 층마다의 범위만 정한다. 설계가 바뀌면 이 문서를 먼저 고친다.

## 1. 방식

- 층 하나는 한 가지 결과만 낸다. 작업과 출력은 20k token 이하를 목표로 하고, 넘으면 쪼갠다.
- 층은 `gh stack`으로 쌓는다. 맨 아래만 main을 base로 삼고, 스택은 맨 위 PR로 한 번에 병합한다. 스택 브랜치에 main이나 다른 PR을 merge하지 않는다.
- 로컬 전체 빌드와 CI 대기를 하지 않는다. 필요한 검사는 층마다 이름을 적어 요청하고, 결과는 그 SHA에 대한 것으로만 쓴다.
- 시험은 기능 표면에서 한다. 판정식(§6.2)과 복구 상태기계(§8.2)처럼 갈래가 많은 순수 로직만 함수 단위로 시험한다. 화면 문구, 행 순서, 숫자 임계값을 확인하는 시험은 만들지 않는다.
- 호환 reader, converter, migration code를 만들지 않는다. 저장 형식이 바뀌는 층은 변경 기록에 `### Fresh state required`를 적는다.
- 인증·인가 코드에는 `(* HIGH-RISK-UNREVIEWED: 이유 *)`를 달고 사람이 검토한다.
- 한 층에서 다음 층으로 넘어가기 전에 이전 층에 적대적 리뷰어를 붙인다. 자기 변경을 자기가 승인하지 않는다.
- 각 층의 결과, 범위, 시험, 되돌리는 길은 그 층을 시작할 때 PR 본문에 적는다. 아래 표는 순서와 경계만 정한다.

## 2. 현재 코드에서 확인한 사실

| 영역 | 사실 | 근거 | 층에 주는 영향 |
|---|---|---|---|
| 경로 표 | HTTP/1 경로는 `Router.routes` 하나에 `{kind; path; methods; handler}`로 모인다. 등록 호출은 약 350개이고 모듈은 약 35개다. 경로 레코드에 인증 정보가 없고, 인증은 핸들러 안의 래퍼 클로저다. | `lib/http_server_eio.ml:699`, `lib/server/server_auth.ml:1291-1416` | 표만 읽어서는 경로의 인증 처분을 알 수 없다. A1이 실제 요청으로 잰다. |
| 다른 표 | H2 게이트웨이는 손으로 쓴 (method, path) 매치를 따로 가진다. `/mcp` 사전 처리는 router 앞에 있다. | `lib/server/server_h2_gateway.ml:422-1760`, `bin/main_eio.ml:252-265` | 처분을 세는 표가 셋이다. |
| 인증 입력 | `token` 쿼리는 GET `/mcp?sse_kind=observer`, `/events/presence`, `/api/v1/ide/lsp`에서만 읽는다. 쿠키는 `mcp-session-id` 하나이고 credential이 아니다. CSRF 토큰 장치는 없고 Origin/Referer 검사만 있다. | `server_auth.ml:110-162, 676-743`, `server_mcp_transport_http_session.ml:632-679` | C3이 쿠키, CSRF, query 차단을 새로 만든다. |
| WebSocket | `/ws` upgrade는 bearer 또는 같은 출처면 통과한다. 이후 JSON-RPC 프레임은 `auth_token` 없이 처리된다. | `lib/server/frontend.ml:104-141`, `server_mcp_transport_ws.ml:444-466` | 세션을 폐기해도 소켓을 닫는 장치가 없다. C3 범위다. |
| 호출자 alias | 토큰 해석이 실패해도 alias를 유지한다. 기본 모드는 Dry_run이라 로그만 남긴다. | `lib/mcp_server_eio_caller_identity.ml:176-189`, `lib/auth/auth_strict_mode.ml:17-20` | C4가 다계정에서 이 경로를 없앤다. |
| 인증 설정 | `auth_config`는 `enabled`, `workspace_secret_hash`, `require_token`, `token_expiry_hours`다. 파일은 `<base>/.masc/auth/config.json`이고 디코더는 모르는 필드를 거부한다. 파일이 없으면 기본값이다. | `lib/types/types_auth.ml:182-187`, `lib/auth/auth_credential_base.ml:41, 236-251` | `account_mode`를 필수로 만들면 기존 `config.json`이 디코드되지 않는다. |
| 부팅 | 부팅 경로에서 `load_auth_config` 호출을 찾지 못했다. 깨진 `config.json`은 요청마다 503이다. | `lib/server/server_runtime_bootstrap.ml:1595-1609`, `lib/server/server_h2_gateway.ml:1830` | "부팅 거부"는 새 검사다. |
| 설정 쓰기 | `prepare_login_auth`가 쓰고 `Auth_login.ensure_local_operator`로 setup·restart에서 불린다. `masc auth` 하위 명령은 없다. | `lib/auth/auth_credential_token.ml:526-541`, `bin/main_eio.ml:4389-4409, 4534, 4546` | A2가 이 경로에서 `Single_user`를 써 넣는다. |
| Runtime 조회 | 비시험 호출이 54곳이다. `get_runtime_by_id` 32, `resolve_assignment` 13, `runtime_id_for_keeper` 4, `get_runtime_ids` 3, `capability_of_runtime_id` 1, `keeper_assignments` 1이다. 모두 `Runtime.<fn>`으로 쓰여 별칭이 없다. | `lib/keeper/keeper_turn_driver.ml`(12곳) 외 | 조회 54곳을 하나씩 고치지 않는다. 실행 진입의 타입을 바꿔 컴파일러가 호출자를 찾게 한다(D2). |
| 실행 진입 | Keeper 턴은 `Keeper_turn_driver.run_named`에서 `attempt_runtime_candidates`를 거쳐 `Runtime_codex_app_server.run_turn`이나 `Runtime_claude_code.run_turn`에 닿는다. official client 프로세스는 이 두 곳에서만 시작된다. Fusion, vision, verifier, one-shot lane, probe, model refresh는 별도 진입이다. | `keeper_turn_driver.ml:576, 1685`, `runtime_codex_app_server.ml:2899`, `runtime_claude_code.ml:2986` | D2는 두 `run_turn`부터, D3이 나머지를 바꾼다. |
| API provider | API provider 실행 경로는 조사하지 않았다. | - | D4의 첫 일은 조사다. |
| 이름 겹침 | `before_dispatch_authority`는 턴 admission token 검증이다. 사용자 권한과 다른 개념이다. | `lib/keeper/keeper_unified_turn_execution.ml:42`, `keeper_heartbeat_loop_cycle.ml:236` | 이름을 섞지 않고 합치지도 않는다. |
| 원장 선례 | `Candle_ledger`는 프로세스 배타 lock을 쓰고 blocking 파일 작업을 system thread로 격리한다. `Fs_compat`에 atomic 저장과 stable lock이 있다. `Jsonl_writer`에서는 lock·fsync 호출이 보이지 않는다. | `lib/candle_store/candle_ledger.ml:35-79`, `lib/fs_compat/fs_compat.mli:407-476` | B1이 `Candle_ledger`의 방식을 따른다. |
| OIDC 라이브러리 | JWT/JWKS 검증 코드와 JOSE 의존성이 없다. 후보는 opam의 `jose 0.11.0`(MIT)과 `jwto 0.4.0`이다. | `dune-project`, `opam show` | C1이 고른다. |
| 진행 중 스택 | MCP OAuth 스택(#46336~#46379)이 `auth_oauth*.ml`, `server_oauth_*.ml`, `env_setting.ml`을 바꾼다. | `gh pr view` 파일 목록 | 이 계획의 층은 그 파일을 건드리지 않는다. 설계 §5.3의 OAuth 결속 층(C5)만 그 스택이 main에 들어간 뒤에 연다. |

## 3. 층 목록

층은 모두 23개다. 크기가 20k token을 넘는 층은 시작할 때 쪼갠다.

### A. 측정과 기반 — Single_user 동작을 바꾸지 않는다

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| A1 | 모든 경로의 현재 인증 처분을 실제 요청으로 잰 기준선. HTTP/1 경로는 라우터를 격리한 base path로 띄워 무인증 요청과 잘못된 bearer 요청을 보낸다. H2, `/mcp` 사전 처리, `/ws`는 실제 소켓으로 따로 친다. 결과는 `docs/evidence/`에 둔다. 동작은 바꾸지 않는다. | §5.3, §11-1 | - |
| A2 | `auth_config.account_mode`를 필수 필드로 두고 부팅 때 검사한다. 값이 없거나 모르는 값이면 부팅을 거부한다. `Multi_account`는 `enabled=false`, `require_token=false`, `MASC_ALLOW_ANONYMOUS_MUTATIONS=true`를 거부한다. setup·restart가 `Single_user`를 써 넣는다. 변경 기록에 `Fresh state required`를 적는다. | §5.1, §5.3 | - |
| A3 | 권한 도메인의 닫힌 타입(Principal, Effect, Channel, Runtime_scope, Authorization_scope, ExecutionContext, grant, policy)과 판정식 `allowed`. I/O 없는 순수 코드다. 시험은 deny 기본, `Empty`, `Not_pat`, scope·channel·effects 교집합을 표로 확인한다. | §4, §6.2 | - |

### B. 권한 저장소

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| B1 | `authz.jsonl`: append-only, 프로세스 배타 writer lock, lock-free snapshot, replay. `Candle_ledger`의 방식을 따른다. lease 계열 group commit은 E1에서 붙인다. | §8.1 | A3 |
| B2 | 외부 고수위와 `Intent_pending`/`Committed`. 같은 writer lock 구역, 판정 갈래 1~5, `AuthorizationUncertain`, `Revocation_pending` 게이트, `Fresh_bootstrap`. 갈래마다 고장 주입 시험을 둔다. 외부 저장소의 위치를 정하는 방식을 먼저 정한다(§5의 결정 3). | §8.2~8.4 | B1 |
| B3 | Principal·Admin_assignment·WorkspaceMembership·초대 저장소, tombstone, 마지막 Admin 보호, 호스트 로컬 bootstrap. | §4.1, §5.1 | B1, B2 |

### C. 인증

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| C1 | OIDC ID token 검증 의존성 결정. `jose`와 `jwto`를 현재 pin(x509 < 1.2), OCaml 5.5, RS256, `alg=none` 거부, JWKS `kid` 선택으로 비교한 근거를 남기고 하나를 추가한다. 고정한 JWKS와 token 벡터로만 시험하고 네트워크를 쓰지 않는다. | §5.2 | - |
| C2 | Google OIDC code + PKCE 로그인, `(iss, sub)` 결속, 초대 소비(동시 소비는 409). | §5.1, §5.2 | B3, C1 |
| C3 | `__Host-` 세션·transaction·mcp 쿠키, 세션에 결속한 CSRF 토큰, 출처 검사, cookie와 Bearer가 함께 오면 거부, WS/SSE 결속과 폐기 때 닫기, 원격 query credential 차단. | §5.2, §5.3 | C2 |
| C4 | scoped PAT와 Service credential 레코드(principal + `Pat_scope`), `Auth_gate.decide` 통합, 다계정에서 caller alias 유지·workspace secret·auth disabled 경로 제거, `agent_credential` 읽기 거부. | §5.3 | A2, A3, C3 |
| C5 | MCP OAuth 승인을 OIDC session에 결속한다. 진행 중인 스택이 main에 들어간 뒤에만 연다. 그 전까지 `Mcp_oauth_token`은 Reject다. | §5.3 | C3, OAuth 스택 병합 |

### D. 소유권과 실행 게이트

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| D1 | ProviderAccount·Runtime owner 검사(setup, raw TOML, 부팅), Runtime 생성과 같은 append의 Self grant, `CanAdmin`에서 `ManageOwnProvider` 분리, ProviderLink의 membership·namespace 검사. | §4.2~4.3, §5.4 | B3, C4 |
| D2 | `Runtime_view.t`와 abstract `Authorized_runtime.t`, `Runtime.authorize`. 두 `run_turn`(Codex, Claude Code)과 그 위의 Keeper 턴 경로가 `Authorized_runtime.t`를 요구하게 바꾼다. | §6.1 | A3, D1 |
| D3 | 나머지 실행 진입을 같은 타입으로 바꾼다. Fusion, vision, verifier, one-shot lane, probe, model refresh. | §6.1 | D2 |
| D4 | API provider 실행 경로를 조사하고 같은 타입으로 바꾼다. | §6.1 | D2 |
| D5 | Delegated grant, MachineSharePolicy, DelegatePolicy, channel, 영속 작업의 initiator/executor 재검사. | §4.3~4.4, §6.2 | D2, B3 |

### E. official client 격리

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| E1 | `Lease_state`, `with_lease`, `consume` 한 번, 재기동 규칙, lease 계열 group commit. | §7.1 | B1, D2 |
| E2 | account-home single-flight, 점유 영속, 단일 FIFO, owner·Admin의 `Executor_teardown`, `account_busy`. | §9.1~9.2 | E1 |
| E3 | credential/state 분리, 저장소 종류와 `state_separation`을 포함한 lane 증명, attestation. | §5.4-6, §7.2, §9 | E2 |
| E4 | dispatch 전용 MCP credential. | §7.3 | E1 |

### F. 복원과 준비

| 층 | 결과 | 설계 | 선행 |
|---|---|---|---|
| F1 | 복원 창, Recovery_manifest, `Cleared`/`Denied`/`Quarantined`/`Purged`, 적격 Admin 규칙. | §10.1~10.4 | B2, B3 |
| F2 | 모드 전환(on→off)과 새 명령 `masc auth recovery`. | §10.5 | F1 |
| F3 | `MultiAccountReadiness` 실행기와 증거 묶음. | §11 | 모든 층 |

## 4. 순서와 첫 마일스톤

- A, B, C1은 서로 거의 독립이라 병렬 스택으로 쌓을 수 있다. C2부터는 B3 뒤에 온다.
- D2와 D3은 Single_user에서 동작을 바꾸지 않도록 `Runtime.authorize`가 모드에 따라 근거를 달리 발급해야 한다. 설계 §6.1이 이 점을 정한다. 이 근거가 없으면 D2는 시작하지 않는다.
- 설계 §11의 readiness가 복구 리허설과 official lane 격리 증거를 요구하므로, F1과 E3 없이는 원격 다계정을 열 수 없다. 그 앞까지의 층은 모두 `Single_user`를 바꾸지 않고 main에 들어갈 수 있다.
- 따라서 첫 마일스톤은 둘 중 하나다. (가) A~D3까지: 동작은 그대로이고 타입과 저장소와 로그인 경로만 들어간다. (나) 전부(F3까지): 원격 다계정을 연다. 결정 1이다.

## 5. 결정이 필요한 것

1. **첫 마일스톤.** (가) A~D3까지를 먼저 병합하고 이후 층을 이어서 연다. (나) F3까지 한 번에 스택으로 쌓는다. 추천은 (가)다. 되돌리기 쉽고 `Single_user`가 매 층 그대로인 것을 확인할 수 있다.
2. **OIDC 라이브러리.** C1이 비교한 뒤 정한다. 직접 구현하지 않는다. constitution이 보안·암호는 기존 라이브러리를 쓰라고 한다.
3. **외부 고수위 저장소의 위치.** 설계는 "backup 밖"만 요구한다. 경로를 코드에 박을 수 없으므로 설정 키나 설치 기록으로 받아야 하는데, 어느 쪽인지 정해지지 않았다. B2 전에 정한다.
4. **경로 처분을 타입으로 붙일지.** A1이 측정한 결과를 보고 정한다. 타입으로 붙이면 등록 호출 약 350곳과 H2 표를 함께 바꿔야 하므로 층이 여럿 늘어난다. 측정기만 두면 새 경로가 생길 때 사람이 다시 측정해야 한다.

## 6. 위험과 미확인

1. 경로 표가 셋(HTTP/1, H2, `/mcp` 사전 처리)이다. 하나로 합치지 않으면 인증 처분을 한 곳에서 셀 수 없다.
2. `account_mode` 필수화는 기존 설치를 부팅 거부로 만든다. 값을 써 넣는 경로(setup, restart)를 같은 층에 넣고, 라이브 서버(Keeper 42명)에는 배포 순서를 정해야 한다.
3. API provider 실행 경로를 조사하지 않았다. D2가 official client 두 진입만 막으면 API provider로 우회할 수 있다. D4 전에는 Multi_account를 열지 않는다.
4. JOSE 후보를 현재 pin과 함께 풀어 보지 않았다. `jose`는 x509 >= 0.13을 요구하고 현재 pin은 < 1.2라서 겹치는 범위가 있어 보이지만 확인하지 않았다.
5. A1의 실제 요청은 열려 있는 변경 경로를 실행할 수 있다. 격리한 base path, Keeper 없음, loopback만 쓴다. 경로 인자는 형식이 맞는 존재하지 않는 값을 쓴다.
6. 이 조사는 코드를 읽은 것이다. 빌드와 실행은 하지 않았다.

## 7. MASC 등록

- Goal은 설계 승인 뒤에 만든다. 성공조건은 이 문서의 층 표에 적힌 병합된 PR 번호로 읽는다. 지표는 이 문서의 층 표이고 목표값은 23개 층 모두에 병합된 PR 번호가 하나씩 적힌 상태다.
- Task는 층마다 `goal_id`를 붙여 만든다. 층 하나가 Task 하나다.
