> 파생본이다. 원본 조사 보고서를 [README](README.md)에 적은 대로 손질했다.

# 로그인·세션 경로 적대적 리뷰 (rev-login-session)

로그인·세션 경로 적대적 리뷰 결과: P0 확정 0건, P1 1건, P2 4건(1건은 GitHub 동작에 달려 있고 통하면 P0), P3 4건.

읽기만 했고 아무것도 실행하지 않았다. worktree `.worktrees/authz-d1-1-20261108`, branch `feat/authz-f3a-off-command-20261110`, head 85b8af5b0453. 아래 경로는 저장소 상대 경로다.

등급: P0 = 지금 `masc auth preview` 에서 통한다. P1 = 실제 서버나 공개 hostname 에 달면 통한다. P2 = 영향이 좁거나, 구체적인 시나리오가 있는 보강 빈칸. P3 = 정리.

## Findings

### 1. P1 — 로그인 transaction 자리를 인증 없이 다 채울 수 있다

- 근거: `lib/auth/oidc_login_transaction.ml:164`, `lib/auth/login_routes.ml:268`, `bin/masc_cli_auth.ml:159`
- 무엇이 틀렸나: 로그인 시작 요청은 인증 없이 transaction 자리 하나를 쓴다. 자리가 다 차면 모든 start 가 503 이고, 찬 자리는 만료될 때까지 비지 않는다. 그동안 로그인과 초대 사용이 막힌다. start→callback 한 쌍마다 서버가 client secret 을 실어 GitHub token endpoint 를 부르는데 이것도 제한이 없다. preview 에서는 같은 기기의 프로세스만 할 수 있다(브라우저는 Origin 을 못 속인다).
- 확인: store 는 차면 `Error Full` 이고 밀어내지 않는다. `Login_routes`·`Server_login_http` 에 rate limit 이 없다(rg). capacity 를 키워도 구조는 같다.
- 신뢰도: 높음.

### 2. P2, 통하면 P0 — 남의 code 를 자기 transaction 에 넣는 길. GitHub 동작 미확인

- 근거: `lib/auth/login_routes.ml:280`, `lib/auth/github_oauth.ml:69`, `lib/auth/login_client.mli:34`
- 무엇이 틀렸나: 같은 기기의 프로세스가 남이 승인한 code 를 자기 transaction 에 넣어 교환하게 하는 길이 있다. mli 는 GitHub 가 loopback redirect 를 어느 포트든 받는다고 적는다. 막는 것은 GitHub 가 token 교환의 `redirect_uri` 를 authorize 때 값과 정확히 비교하는지 하나다. 통하면 서버가 그 프로세스에게 code 를 승인한 사람의 세션 cookie 를 준다. 원본이 든 예는 Admin 이다.
- 확인: 코드 경로는 추적했다. GitHub 쪽은 네트워크 금지라 못 봤다. 시험용 OAuth App 에서 재 보면 된다.
- 신뢰도: 경로 높음, 통하는지는 모름.

### 3. P2 — preview 의 세션 cookie 가 같은 기기의 다른 포트와 공유된다

- 근거: `lib/auth/authz_browser_request.ml:12`, `bin/masc_cli_auth.ml:157`
- 무엇이 틀렸나: cookie 는 포트를 가리지 않는다(RFC 6265 8.5). 그래서 preview 의 세션 cookie 가 같은 기기의 다른 포트에서 도는 서버에도 간다. CSRF token 이 세션 secret 에서 나오므로 그 값만으로 최대 7일 그 사람으로 동작한다. 반대로 다른 포트의 페이지가 같은 이름의 cookie 를 심을 수도 있다. 그러면 그 브라우저가 다른 계정에 묶이고, 그 뒤 연결한 subscription 은 그 계정 것이 된다.
- 확인: cookie 속성과 `Authz_browser_session.csrf_token` 을 읽었다. 브라우저로 돌려 보지 않았다.
- 신뢰도: 중간. 다른 OS 사용자나 로컬 서비스가 전제라 P0 로 올리지 않았다.

### 4. P2 — 초대·사람·세션을 거둘 수단이 없다

- 근거: `bin/main_eio.ml:1300`, `lib/auth/authz_activation.ml:120`, `lib/auth/authz_session_state.ml:10`
- 무엇이 틀렸나: CLI 초대는 전부 Admin 이고 24시간이며 신원에 묶이지 않는다. 링크가 새면 먼저 쓴 GitHub 계정이 Admin 이 된다. 초대 취소, Disable, Admin 회수, 남의 세션 끊기를 쓰는 코드가 없다. 남는 것은 `masc auth off` 이고 이 빌드는 다시 켜지 못한다. 훔친 cookie 는 7일 간다.
- 확인: `Revoked`·`Disabled`·`Enabled`·`Deleted` 를 만드는 곳을 lib·bin 에서 rg 했고 fold 의 match 뿐이었다. `masc auth` 는 bootstrap·invite·off·preview 다.
- 신뢰도: 높음. preview 링크는 loopback 이라 지금은 원격에서 못 쓴다. 계획(`docs/superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md`) 216행이 같은 빈칸을 적어 두었다.

### 5. P2 — 초대 링크의 base 로 평문 http 를 받는다

- 근거: `lib/play/play_invite.ml:163`, `bin/masc_cli_auth.ml:34`
- 무엇이 틀렸나: 초대 링크의 base 가 평문 http 여도 Admin 링크를 찍는다. 평문으로 온 초대 페이지는 전송 중에 바뀔 수 있고, 그러면 링크의 token 이 드러난다. 받은 사람의 로그인은 Secure cookie 가 저장되지 않아 끝나지 않고, 초대는 안 쓰인 채 남는다. redirect URI 는 https 만 받는 것과 어긋난다.
- 확인: `is_http_public_base_url` 을 읽었다.
- 신뢰도: 중간(서버가 http 로도 닿을 때).

### 6. P3 — 서버 파일 경로가 응답에 나간다

- 근거: `lib/auth/login_routes.ml:465`, `lib/auth/login_allowlist_routes.ml:95`, 문구는 `lib/auth/authz_zone.ml:225`
- 무엇이 틀렸나: external store 나 log 가 멈춘 동안 로그인한 사람이 logout 이나 allowlist 쓰기를 부르면 JSON error 에 두 파일의 절대 경로가 실린다.
- 확인: `lib/auth/authz_browser_session.ml:58` 과 `lib/auth/authz_allowlist.ml:21` 이 `Commit_failed` 를 `Authz_zone.error_to_string` 으로 넘기는 것을 읽었다.
- 신뢰도: 높음.

### 7. P3 — `localhost` 로 연 preview 에서는 로그인이 항상 실패한다

- 근거: `lib/server/server_request_authority.ml:253`, `lib/auth/login_client.ml:55`
- 무엇이 틀렸나: Host admission 은 loopback 별칭을 받는데 redirect 는 `127.0.0.1` 고정이다. `localhost` 로 연 preview 에서는 transaction cookie 가 `localhost` 에 남아 callback 이 401 이다. base 를 `localhost` 로 잡아 찍은 초대 링크가 이 경우다. 초대는 안 쓰인 채 남는다.
- 확인: `configured_identity_matches`, `Login_client.loopback`, `Login_routes.read_callback` 을 읽었다. 실행하지 않았다.
- 신뢰도: 높음(실행 안 함).

### 8. P3 — 다른 사이트가 진행 중인 로그인을 취소할 수 있다

- 근거: `lib/auth/oidc_login_transaction.ml:198`
- 무엇이 틀렸나: `take` 가 state 를 비교하기 전에 transaction 을 지우고, transaction cookie 는 SameSite=Lax 다. 그래서 다른 사이트가 진행 중인 로그인을 취소할 수 있다. 계정 피해는 없다. mli 는 의도라고 적는다.
- 확인: `take` 는 198행에서 지우고 204행에서 state 를 비교한다. `lib/auth/github_login_flow.mli` 가 "the transaction is gone after any callback, a refused one included" 라고 적는다.
- 신뢰도: 높음.

### 9. P3 — transaction 시계 계약이 어긋난다

- 근거: `lib/auth/oidc_login_transaction.mli:26`, `bin/masc_cli_auth.ml:220`
- 무엇이 틀렸나: mli 는 뒤로 가지 않는 시계를 요구하는데 preview 는 벽시계를 넘긴다. 시계가 뒤로 가면 transaction 이 10분 넘게 자리를 차지한다.
- 확인: mli 26~27행, `Ptime_clock.now` 를 넘기는 220행, `is_live`(`lib/auth/oidc_login_transaction.ml:140`)를 읽었다.
- 신뢰도: 높음.

## 경로

| Method · Path | 부를 수 있는 쪽 | 막는 곳 |
|---|---|---|
| POST `/auth/github/start`, `/auth/oidc/start` | 누구나, same-origin `Origin` 필수 | `Login_routes.start` |
| GET `/auth/github/callback`, `/auth/oidc/callback` | transaction cookie 와 state 를 가진 쪽 | `Login_routes.read_callback`, `Oidc_login_transaction.take` |
| POST `/auth/logout` | 세션 + Origin + CSRF | `Authz_browser_request.check` |
| GET `/auth/session` | 세션 | `Login_routes.acting` |
| POST `/api/v1/auth/allowlist`, DELETE `…/<id>` | Admin(세션 + Origin + CSRF) | `Login_routes.acting`, `Authz_registration_state.apply` |
| GET `/`, `/accounts/invite` | 누구나(고정 페이지) | `Always_public` |
| GET `/api/v1/auth/whoami` | 세션 | `Auth_gate.decide` `Read_auth` |
| GET `/api/v1/auth/provider-accounts`, POST `/api/v1/setup/accounts/login`·`/verify`, GET·POST `/api/v1/setup/accounts/login/…` | active Human, 자기 것 | `Auth_gate.decide` `Manage_own_provider`, `Runtime_setup_login_session.same_actor` |
| GET·POST `/api/v1/auth/keepers`, POST `…/assign`·`…/turn` | active Human, 자기 Keeper | `Auth_gate.decide` `Manage_own_keeper`, owner 비교 |

router 는 이 경로들에 아무것도 씌우지 않는다. 막는 일은 전부 handler 안에서 한다.

## Checked and found correct

- state·verifier·nonce·transaction id·세션 secret·초대 token 은 OS CSPRNG 32바이트다. transaction 은 한 번 쓰면 지워지고 state 는 상수 시간 비교다.
- PKCE 는 S256 이고 verifier 는 서버를 떠나지 않는다.
- `redirect_uri` 는 설정 고정값이다. Host 헤더나 `MASC_HTTP_BASE_URL` 에서 만들지 않는다.
- Google transaction 을 GitHub callback 에 넣으면 `Other_flow` 로 401 이다.
- GitHub 신원은 교환으로 받은 token 의 `GET /user` 숫자 id 다. scope 가 없고 token 은 저장·로그·error 에 없다. 나가는 TLS 는 Piaf 기본값(peer·host 검증, redirect 안 따름)이다.
- 초대는 256-bit, log 에 digest 만, 24시간이다. 입장이 레코드 하나라 "소비"와 "principal 생성" 사이가 없다. 동시 사용은 `Authz_zone.commit` 의 lock 안 apply 가 하나만 통과시킨다.
- 세션 cookie 는 `__Host-`·Secure·HttpOnly·SameSite=Strict 다. 로그인마다 id 와 secret 이 새로 나오고, 브라우저가 들고 있던 옛 세션은 같은 레코드에서 닫힌다. 요청마다 principal 이 active 인지 본다.
- 상태를 바꾸는 요청은 same-origin Origin 과 CSRF token 이 모두 있어야 한다. preview 의 POST 경로가 전부 이 검사를 거친다.
- cookie+bearer, credential 둘 이상, legacy bearer, internal token, `mat_`, query credential 은 모두 거절된다. legacy 가 `Auth_gate.decide` 를 통과하는 갈래는 없다.
- `return_to` 는 `//` 로 시작하지 않는 로컬 경로만 받고 escape 뒤 href 에 들어간다. 페이지는 고정 문구와 CSP nonce 다. IdP 의 이름·이메일은 읽지 않는다.
- Host admission 은 bind 와 loopback 별칭만 받는다. Origin 은 admit 된 authority 와 scheme·host·port 가 같아야 same-origin 이다. 다른 Host 는 400 이다.
- 로그인 모듈의 로그는 body 읽기 실패 한 줄이고, 요청 target 을 찍는 로그는 없다.

## Not reachable yet

- Google OIDC 전체(preview 는 `google = None`). 읽은 범위에서는 결함을 못 찾았다(RS256 만, kid·exp 필수, aud 단일 문자열, nonce).
- `Login_client.make`·`of_environment`, PAT 과 Service credential 의 발급·폐기, 초대 취소, Disable·Enable·Delete, Admin 회수.
- 숨은 결함: `Authz_browser_session.authenticate`(`lib/auth/authz_browser_session.ml:131`)와 `Authz_pat.authenticate`(`lib/auth/authz_pat.ml:92`)는 principal 의 held revocation 을 보지 않는다. Disable 기록이 끊기면 새 로그인은 막히는데 이미 있는 세션과 PAT 은 계속 통한다. 계획 805행의 "회수 기록이 중간에 끊기면 실행을 막아야 한다"와 어긋난다. Disable 을 쓰는 층보다 먼저 고쳐야 한다.
- Disable 은 세션 레코드를 닫지 않는다. Enable 하면 7일 안의 옛 세션이 다시 통한다.
- 실제 서버 mount(S1), HTTP/2 갈래, 폐기 때 WS·SSE 닫기(C4-12).

## Did not read

- `Authz_zone` 의 open·복구, `Authz_external_store`, `Authz_log`, `Authz_body`, `Authz_id`.
- .mli 여섯 개(admission_event, pat_event, service_credential_event, service_credential_state, registration_event, registration_state). .ml 은 읽었다.
- `Server_auth` 는 Origin 분류 부분만, `Runtime_setup_login_*` 는 actor 범위만, jose 는 `Jws`·`Jwt` 만, Piaf 는 기본 config 와 verify 설정만 봤다.
- 시험 코드. 브라우저와 GitHub 의 실제 동작.
