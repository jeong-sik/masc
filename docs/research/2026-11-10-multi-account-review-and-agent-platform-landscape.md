# 다계정 로그인 구현 적대적 검토와 에이전트 플랫폼 조사

- 확인 시각: 2026-11-10 KST. 코드는 읽기만 했다. 빌드와 실행은 하지 않았다. 웹 페이지는 같은 날 열었다.
- 판정 대상 head: `85b8af5b0453`(브랜치 `feat/authz-f3a-off-command-20261110`). 줄 번호는 이 트리 기준이다. 진행률은 `main` `b32d3a09e102` 기준이다.
- 줄 번호의 예외가 둘이다. 실행 경계 리뷰(§2.5)는 2026-11-10 18시 작업 트리 기준이다. 약관 조사(§4.8)는 코드를 `9424cc7b5394` 에서 읽었다. 두 보고는 다른 보고보다 늦게 왔다.
- 이 문서는 조사이고 결정이 아니다. 조사 보고서 13개는 [`docs/evidence/research/2026-11-10-multi-account-review/`](../evidence/research/2026-11-10-multi-account-review/README.md) 에 있다.
- 관련 문서: [설계](../superpowers/specs/2026-10-27-multi-account-oidc-runtime-authorization-design.md), [계획](../superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md), [MCP 2026-07-28 대조](2026-10-27-mcp-2026-07-28-parity.md).
- 조사 방식: 읽기 전용 에이전트가 보고서를 썼다. 종합 세션이 보고를 읽고 핵심 주장을 코드에서 다시 확인했다. 보고서는 종합 세션을 team-lead 라고 부른다.
- 근거 표기: `직접` 은 종합 세션이 그 코드를 직접 읽었다고 적은 것이다. 적은 곳은 셋이다.
  - 직접 확인 메모. 항목마다 줄 근거가 있다. 이 문서는 `직접` 으로 적는다.
  - 종합의 「코드로 직접 확인」 절. 줄 근거가 메모에 없는 항목이 있다. 그런 항목은 `직접(종합)` 으로 적는다.
  - 이슈 #51072, #51073, #51074 의 본문. §2.5 에서 쓴다.
- `보고` 는 조사 보고서에만 있는 것이다. 괄호 안 이름(rev-server-doors 등)은 증거 묶음의 파일이다.
- 등급과 신뢰도는 각 보고서가 매긴 그대로 옮겼다. 보고서마다 P0 의 정의가 다르다(§2).

## 0. 요약

- 확정된 P0 는 없다. 코드 리뷰 다섯이 끝났다. 다계정 설치를 단일 사용자로 잘못 띄우는 부팅은 나오지 않았다. 한 사람의 턴이 다른 사람의 구독으로 도는 길도 나오지 않았다(§2).
- 통하면 P0 인 발견이 둘 있다. 둘 다 바깥 제품의 동작에 달렸고 재지 않았다. 하나는 사람이 보낸 글이 가공 없이 공식 클라이언트의 입력이 되는 자리다(§2.5). 다른 하나는 로그인 code 교환에서 GitHub 가 `redirect_uri` 를 비교하는지에 달린 자리다(§2.3).
- 부팅 판정에는 평가가 갈리는 자리가 하나 있다. 설정 파일을 읽지 못하면 설정이 없는 것으로 읽는다. 한 보고는 설계가 정한 동작으로 보고, 다른 보고는 규칙 위반으로 센다(§2.3, §7.3).
- 실행 경계는 타입으로 묶여 있다. 뒤에 온 실행 경계 리뷰가 빈칸 둘을 들었다(§2.5, §3). 요청 경계는 미리보기에만 있다. 실제 서버에는 다계정 사람이 들어올 문이 아직 없다(§3).
- 실제 서버를 열기 전에 닫을 것이 다섯이다(§2.1).
  - 부팅 거부만 풀면 기존 문이 예전 token 으로 열린다.
  - 세션 인증이 멈춤을 보지 않는다.
  - 끈 설치가 로그에 덧붙인 한 줄로 되살아난다.
  - 로그인 시작 자리가 인증 없이 다 찬다.
  - Keeper 턴의 당사자가 늘 주인이다.
- 바깥 제품과 방향이 같다. harness 는 sandbox 밖에 두고, 구독 로그인은 모델이 닿지 않는 곳에 둔다(§4).
- Anthropic 문서는 각자 자기 구독으로 로그인하는 호스팅을 조건부로 허용한다. 서버가 자격증명을 모으거나 보관하거나 중개하는 것은 허용하지 않는다. OpenAI 문서는 자동화에 API 키를 권한다. Google 소비자 플랜은 다른 앱이 CLI 를 감싸는 것을 지원하지 않는다(§4.8).
- MCP(Model Context Protocol) 2026-07-28 개정이 세션을 없앴다. 계획 C4-12 의 세션 cookie 결속은 고쳐야 한다(§4.4).
- 순서는 W1~W5 로 제안한다. W1 은 팀원이 실제 서버에 로그인해 자기 구독으로 자기 Keeper 에게 묻는 것이다(§6).

## 1. 진행률

계획 문서의 층을 `main` `b32d3a09e102` 기준으로 센 값이다. 종합 세션이 셌다. 이 문서를 쓰면서 다시 세지 않았다.

| 범위 | 상태 |
| --- | --- |
| 계획 전체 | 37행. 1단계 23행, 2단계 14행 |
| 1단계 | 18행 병합 |
| D4, F3a | 리뷰 중 |
| C4(12층) | 8층 병합. C4-9·C4-10 은 리뷰 중이다. C4-11·C4-12 는 시작하지 않았다 |
| C6, S1 | 시작하지 않았다 |
| 2단계 | 병합 0행 |

사람이 로그인해 볼 수 있는 화면은 `masc auth preview` 하나다. 이 미리보기는 loopback 에서 뜬다. 운영자 CLI(`masc auth bootstrap`, `invite`, `off`)는 따로 돈다(rev-store-boot).

- 로그인한다. 화면은 OCaml 문자열로 만든 HTML 이고 GitHub 버튼만 있다(`lib/auth_preview.ml:24-277`, 직접).
- 자기 구독을 연결한다.
- 자기 Keeper 에게 한 번 묻는다. 모델에는 사람의 글만 간다(`lib/server/server_preview_keeper_turn.ml:221,256`). system prompt, 기억, 도구, 기록이 없다(직접).
- 글은 4,096 B 까지, 턴은 120초까지다(같은 파일 8·9줄). 계정 하나는 한 번에 한 호출만 받는다(288줄).
- Claude 는 native 도구 없이(`Native_none`) 돈다. Codex 는 D3c 층의 규칙으로 거절된다(직접).
- 미리보기가 여는 경로는 로그인 8개와 사람 경로 12개다(rev-server-doors 문 표의 11번 행). 그 보고는 사람 경로 12개를 「미리보기 12」라고 부른다.

실제 서버는 다계정 설치를 서빙하지 않는다. 부팅 판정에서 멈춘다(`lib/server/server_runtime_bootstrap.ml:1689-1701`). `Authz_boot_mode_read.decide` 가 설계 §5.1 표의 7번 행과 8번 행을 `Stop (Multi_account_not_served mode)` 로 묶는다(`lib/auth/authz_boot_mode_read.ml:150-158`, 직접).

## 2. 적대적 검토

리뷰 다섯이 다계정 코드를 공격하는 쪽의 눈으로 읽었다. 서버 문(rev-server-doors), 저장소와 부팅(rev-store-boot), 로그인과 세션(rev-login-session), 금지 패턴 집계(rev-rules-census), 실행 경계(rev-exec-boundary)다. 실행해서 재현한 발견은 없다. 모두 코드를 읽고 따라간 결과다. 실행 경계 리뷰는 늦게 와서 §2.5 에 따로 적는다.

이 문서는 약점의 종류와 자리만 적는다. 입력 값과 순서는 적지 않는다.

등급은 각 보고서가 매긴 그대로다. 정의는 보고서마다 다르다.

- rev-login-session: P0 는 지금 `masc auth preview` 에서 통한다. P1 은 실제 서버나 공개 hostname 에 달면 통한다. P2 는 영향이 좁거나 보강이 빠진 자리다. P3 는 정리 거리다.
- rev-store-boot: P0 는 오늘 도는 경로에서 틀린 것이다.
- rev-exec-boundary: P0 는 오늘 도는 경로에서 틀린 것이다. P1 은 실제 서버가 다계정을 서빙할 때 다른 계정 것을 쓰거나 읽거나 호스트 key 를 쓰는 것이다. P2 는 영향이 좁은 빈칸이고 P3 는 정리다.
- rev-server-doors 에는 등급의 정의가 없다.

신뢰도도 보고서가 적은 말 그대로 옮긴다. 그래서 High, 높음, high 가 섞여 있다.

### 2.1 실제 서버를 열기 전에 닫을 것

종합 세션이 다섯 가지를 「코드로 직접 확인」 절에 적었다. 항목마다 근거를 `직접`, `직접(종합)`, `보고` 로 나눠 적는다.

**1. 부팅 거부만 풀면 기존 문이 예전 token 으로 열린다.**

- 직접: 요청 판정 `Auth_gate.decide` 를 부르는 줄은 `lib/auth_preview.ml:300,322` 둘이다. 그 판정을 받아 쓰는 곳은 `as_gated` 다(`lib/server/server_login_http.ml:237-248`). 모두 미리보기 핸들러다.
- 직접: 실제 서버의 경로 등록은 기존 `Server_auth` 래퍼를 쓴다.
- 직접(종합): 이 래퍼는 계정 모드를 보지 않는다.
- 직접: loopback 에 묶이고 strict 가 꺼져 있으면 dev-token 경로가 Admin bearer 를 준다(`lib/server/server_routes_http_routes_dashboard.ml:451-455`). 역할은 `dashboard_dev_role = Masc_domain.Admin` 이다(`lib/server/server_routes_http_dashboard_dev_token.ml:19`). 메모는 이 경로가 단일 사용자 설계에서 나왔고 다계정 표에는 없어야 한다고 적는다.
- 직접: gRPC `ToolCall` 은 호출자와 인증 없이 `execute_tool_eio` 를 부른다(`lib/server/server_runtime_bootstrap.ml:1849-1858`). `MASC_GRPC_ENABLED` 의 기본값은 false 다(`lib/config/env_config_snapshot.ml:118`). rev-server-doors F5 의 신뢰도는 dispatcher 가 High, 기동 조건이 Medium 이다.
- 직접: HTTP/2 는 HTTP/1 과 같은 경로 표를 쓴다(`lib/server/server_h2_gateway.ml:30,49`). 표 밖 갈래는 4개다(`lib/server/server_http_ingress.ml:118-127`).
- 보고: 래퍼 등록 호출은 385곳이다. `Token_permission` 137, `Public_read` 115, `Tool` 류 50, `Self_authenticated` 26 이 큰 묶음이다(rev-server-doors 문 표, `rg` 정적 집계).
- 보고: 예전에 받은 agent bearer 와 workspace secret 이 그대로 통한다. 그 값으로 남의 Keeper 설정 경로와 secret 경로를 부를 수 있다(rev-server-doors F1, `lib/server/server_routes_http_routes_keepers.ml:320-330`, 신뢰도 High).
- 보고: strict 가 아니면 `Public_read` 115곳이 자격 없이 열린다. 부팅 판정의 다계정 거부 사유 넷에 strict 는 없다(rev-server-doors F2, 신뢰도 High(코드)).

**2. 세션과 PAT(Personal Access Token) 인증이 구역의 멈춤을 보지 않는다.**

구역(`Authz_zone`)은 권한 로그와 외부 저장소를 열어 쥐고 있는 값이다. 구역의 `revocation` 은 파일부터 묻는다. 로그나 저장소가 멈췄는지, 두 파일이 어긋났는지, 저장소에 답이 없는지다. 그다음에 snapshot 에서 대상의 막힘을 읽는다(`lib/auth/authz_zone.ml:164-173`, rev-rules-census 5번). 이 문서는 파일 쪽 답을 묶어 「멈춤」이라고 부른다.

- 직접(종합): 세션과 PAT 인증이 구역의 멈춤을 보지 않는다(`lib/auth/authz_browser_session.ml:131`). 로그가 멈추거나 사람의 정지 기록이 로그에 닿지 못해도 이미 있는 cookie 는 통과한다. 새 로그인과 Keeper 턴은 막힌다.
- 보고: 그 줄은 구역을 거치지 않고 snapshot 의 `Authz_state.revocation` 을 읽는다(rev-rules-census 5번). 묻는 대상도 그 세션 하나다. 사람에게 걸린 막힘은 묻지 않고 `status` 만 본다(rev-store-boot 발견 2).
- 보고: PAT 인증(`lib/auth/authz_pat.ml:92-95`)과 service credential 인증(`lib/auth/authz_service_credential.ml:92-94`)도 구역을 거치지 않는다(rev-store-boot 발견 2).
- 보고: 구역에 묻는 `Authz_zone.revocation` 을 부르는 곳은 둘뿐이다(`lib/auth/authz_login.ml:82-84`, `lib/auth/authz_keeper_turn.ml:102-133`).
- 보고: 정지나 Admin 회수의 intent 가 저장소에는 들어가고 로그 append 만 실패할 수 있다. 그러면 그 사람의 `status` 는 `Active` 로 남는다. Admin 이었다면 역할도 Admin 으로 나온다(rev-store-boot 발견 2 의 A).
- 보고: 서빙 중에 로그가 멈춰도 세션과 PAT 요청은 멈추기 전 snapshot 으로 계속 인증된다(같은 발견의 B).
- 보고: 오늘 닿는 경로는 `masc auth preview` 뿐이고 S1 부터는 서버다(rev-store-boot). rev-login-session 은 같은 자리를 「Not reachable yet」 절에 뒀다. 그 보고는 Disable 을 쓰는 코드가 없다고 적는다.
- 보고: 리뷰 셋이 따로 같은 곳을 짚었다. rev-store-boot 발견 2(P1, 신뢰도 medium-high), rev-login-session 의 「Not reachable yet」, rev-rules-census 5번이다.
- 보고: 설계 §8.3 의 글자는 새 dispatch, lease, tool effect 를 막으라는 것이다. 읽기 경로와 역할 판정까지 막을지는 적혀 있지 않다(rev-store-boot). rev-rules-census 도 의도된 선택일 수 있다고 적었다.

**3. 끈 설치를 로그에 덧붙인 한 줄로 되살릴 수 있다.**

고수위(high water)는 외부 저장소가 기억하는 마지막 확정 지점이다. 부팅은 로그가 그 지점을 담고 있는지 본다. 담고 있으면 `Matches` 다.

- 직접(종합): 고수위 판정이 설계 §5.1 의 셋째 조건을 보지 않는다. 셋째 조건은 외부 고수위와 replay 의 epoch 값이 같다는 것이다. 그래서 `masc auth off` 뒤 로그에 덧붙인 `Reactivate` 줄을 켜진 설치로 읽는다.
- 보고: `check_commit` 은 마지막 `Committed` 가 로그에 있는지만 본다(`lib/auth/authz_high_water.ml:114-118`). `judge` 는 그 검사와 대기 중인 intent 판정만으로 `Matches` 를 낸다(156-161줄). 모듈 주석도 epoch 값을 아직 대조하지 않는다고 적는다(`lib/auth/authz_high_water.mli:78-79`).
- 보고: replay 는 `Off, Reactivate -> Multi_account` 로 읽는다(`lib/auth/authz_mode_state.ml:70`). 해시 체인에는 키가 없다(`lib/auth/authz_record.ml:249`). 그래서 base path 에 쓸 수 있는 쪽이 덧붙인 줄을 체인만으로는 가려내지 못한다. 이 빌드에 `reactivate` 를 쓰는 코드는 없다(rev-store-boot 발견 1, P1, 신뢰도는 사실 high·심각도 medium).
- 보고: 오늘은 서버가 `Multi_account_not_served` 로 멈춘다. `masc auth invite` 와 `masc auth preview` 는 돈다(`lib/auth/authz_activation.ml:180-195`). 저장소는 mode 가 Off 여도 권한 intent 를 받는다. 그래서 입장과 세션도 통과한다(같은 발견).
- 보고: 외부 저장소 파일만 옛 사본으로 돌아가는 경우가 있다. 옛 사본의 마지막 `Committed` 가 지금 로그에 있으면 `Matches` 이고 7번 행이다. 그 뒤 base path 까지 옛 시점으로 되돌아가도 `Matches` 인 구간이 있다. 그때 되살아난 grant, 세션, Admin 지정을 알아채지 못한다(같은 발견 B).
- 보고: base path 에 쓸 수 있는 쪽은 `.masc/accounts` 와 `config.json` 에도 이미 닿는다. 그래서 실제 권한 상승은 작다. 깨지는 것은 끈 설치가 저장소의 답 없이는 켜지지 않는다는 성질이다(rev-store-boot).
- 보고: 그 보고는 검사 하나를 제안한다. 부팅 판정에서 저장소의 mode 와 로그의 mode 가 다르면 `Mismatch` 로 읽는 것이다. 지금 있는 값만으로 된다. epoch 항목은 저장소 형식이 바뀌는 hard cut 이다.
- 종합 세션의 판단은 넷이다.
  - 설계 §8.4 는 설정 디렉터리와 base path 에 모두 쓸 수 있는 쪽을 막지 못한다고 적는다(설계 520줄, 계획 155줄).
  - base path 에만 쓸 수 있는 쪽이 로그에 사건을 덧붙이는 경우는 일부를 닫을 수 있다. 모드 변경, 회수, 정지는 외부 저장소의 답(intent)이 있어야 하는 사건이다. 부팅 때 답이 필요한 레코드 수와 저장소가 답한 수를 대조하면 닫힌다(S1a-0).
  - 초대 발급, Enable, 취소는 저장소의 답 없이 쓰는 사건이다. 이 대조로는 막지 못한다.
  - 남는 보강은 MAC(Message Authentication Code)이다. base path 밖의 키로 로그 레코드마다 단다.

**4. 로그인 시작 자리를 인증 없이 다 채울 수 있다.**

- 직접(종합): 자리가 다 차면 start 가 실패한다(`lib/auth/oidc_login_transaction.ml:164`). 자리가 차 있는 동안 모든 로그인이 503 이다. 찬 자리는 만료될 때까지 비지 않는다.
- 보고: 로그인 시작 요청은 인증 없이 자리 하나를 쓴다. store 는 차면 `Error Full` 을 내고 오래된 것을 밀어내지 않는다. 로그인 경로에는 rate limit 이 없다(rev-login-session 발견 1, P1, 신뢰도 높음).
- 보고: start 와 callback 한 쌍마다 서버가 GitHub token endpoint 를 부른다. 이때 client secret 을 싣는다. 이 호출에도 제한이 없다.
- 보고: 미리보기에서는 같은 기기의 프로세스만 할 수 있다. 브라우저에서 온 요청은 `Origin` 검사에 걸린다.

**5. Keeper 턴의 당사자가 늘 주인이다.**

- 직접(종합): 주인이 아닌 사람이 Keeper 큐에 메시지를 넣는 문이 하나라도 열리면, 그 턴은 주인의 구독으로 돈다. 지금 여는 경로에는 그런 문이 없다.
- 직접: 미리보기는 소유를 두 번 확인한다. `assigned` 가 소유자를 대조하고 남의 Keeper 에는 404 로 답한다(`lib/server/server_preview_keeper_turn.ml:51-71`). 이어서 `Runtime_account_access.authorize` 를 거친다(285줄).
- 보고: `decide_on` 은 initiator 와 executor 를 늘 Keeper 소유자로 둔다(`lib/auth/authz_keeper_turn.ml:139-179`, 152-153줄). runtime 은 채널을 `Autonomous` 와 `Direct` 둘만 낸다(`lib/keeper/keeper_agent_run.ml:478-480`).
- 보고: 메시지가 들어올 수 있는 문 후보는 MCP `masc_keeper_msg`, `/api/v1/keepers/chat/stream`, `/api/v1/gate/message`, 커넥터, board 다. 진입점 전수는 세지 않았다(rev-server-doors F3, P1, 신뢰도 High).
- 종합은 이 항목을 약관 문제로도 본다(§4.8).

### 2.2 직접 확인한 그 밖의 사실

모두 직접 확인 메모에 줄 근거가 있다.

- 역할이 겹친다. `role_of` 가 다계정 Admin 을 `Masc_domain.Admin` 으로 돌려준다(`lib/auth_gate.ml:159`). `Holds permission` 은 기존 `Masc_domain.has_permission` 으로 본다. 기존 `CanAdmin` 경로를 다계정 사람에게 그대로 달면 문제가 생긴다. 다계정 Admin 이 남의 Keeper 설정 경로와 secret 경로를 통과한다. 설계 §3 은 Admin 이 남의 credential 과 private Runtime 을 못 쓴다고 정한다.
- 메모는 `Route_access.t` 에 운영자 전용 종류와 Keeper 범위 종류가 없다고 적는다. head 의 `Route_access.t` 에는 `Manage_own_provider` 와 `Manage_own_keeper` 가 있다(`lib/route_access.ml:23-24`). 메모가 말한 Keeper 범위 종류가 이 둘과 어떻게 다른지는 메모에 없다.
- 부팅 판정은 로그와 저장소를 열어 읽고, 연 handle 을 넘기지 않는다(`lib/auth/authz_boot_mode_read.ml:81-84,95-106`). 그래서 서빙하는 쪽은 판정 뒤에 구역을 다시 연다. 미리보기가 그렇게 한다.
- 계정 판정은 `Server_runtime_bootstrap.run` 안에서 한다. `bin/main_eio.ml` 의 앞 단계는 판정 전에 돈다. checkpoint sweep, lane-addon inventory, archive sweep 이다.
- `masc auth invite` 는 base path lease 를 잡는다(`bin/masc_cli_auth.ml:9-20,56-69`). 서버가 떠 있으면 쓰지 못한다. 서버 경로로 초대를 내는 길이 있는지는 확인하지 못했다.
- `Login_client.of_environment` 를 부르는 곳이 lib 와 bin 에 없다(`lib/auth/login_client.ml:81`). 메모와 rev-rules-census 는 이 사실을 다르게 적는다(§7.3). 미리보기는 `loopback` 으로 만든다. `auth_config` 에는 `google`, `github` login client 필드가 있다(`lib/types/types_auth.ml:196-210`).
- 신뢰 정책 `Server_request_authority.make_trust_policy` 는 신원 셋만 받는다. bind 신원(http), TLS 리스너 신원, 명시한 base URL 신원이다. 요청 헤더는 정책 입력이 아니다.
- sandbox 종류는 `Docker | Micro_vm | Remote_ssh` 셋이다(`lib/config/keeper_sandbox_config.ml:7-10`). 호스트 프로세스 격리 단계가 없다(§4.2).
- MCP 쪽 네 곳도 직접 읽었다. 세션 id, query token, 모르는 tool 의 오류 코드, 미지원 version 응답이다(§4.4).

### 2.3 보고에만 있는 발견

아래는 리뷰어 보고에만 있다. 종합 세션의 직접 확인 메모에는 없다. 등급과 신뢰도는 보고서가 적은 그대로다.

| 보고 | 등급 | 신뢰도 | 내용 | 근거 |
| --- | --- | --- | --- | --- |
| rev-server-doors F4 | P1 | Medium | internal keeper token 이 프로세스에 하나다. `x-masc-keeper-name` 헤더가 말한 이름이 호출자가 된다. token 이 sandbox 안에 닿는지는 추적하지 못했다 | `lib/server/server_auth.ml:190-202` |
| rev-server-doors F6 | P2 | High(종류), Medium(본문 필드) | 전부 `Auth_gate` 로 보내도 닫히지 않는 경로가 있다. `Nothing_needed` 종류가 사람 소유 데이터를 낸다. `/health?full=1`, gate 이벤트, capability URL 이다 | `lib/server/server_routes_http_routes_channel_gate.ml:863-883` |
| rev-server-doors F7 | P2 | High | `Auth_gate` 의 결과가 핸들러를 묶지 않는다. 핸들러가 결과를 무시해도 타입이 막지 않는다. `Server_route` 에 `Manage_own_provider`, `Manage_own_keeper` 종류가 없다 | `lib/auth_gate.ml`, `lib/server/server_route.ml` |
| rev-server-doors F8 | P2 | High | 미리보기 경로가 운영자 경로와 겹친다. `/api/v1/setup/accounts/login`, `GET /`, `POST /` 다. 같은 표에 달면 한쪽이 가려진다 | `lib/http_server_eio.ml:496-897` |
| rev-server-doors F9 | P2 | Medium | `/auth/session` 이 CSRF(Cross-Site Request Forgery) token 을 주는 origin 에서 `/dashboard`, `/play`, artifact 경로도 서빙한다. 사용자 HTML 을 실행하는 경로가 있는지는 확인하지 못했다 | `lib/auth/login_routes.ml:475-485` |
| rev-server-doors F10 | P3 | High | 정리 5건. 미리보기는 `Server_http_ingress.serve` 를 거치지 않는다. 그래서 미리보기에서 본 동작이 실제 서버로 그대로 옮겨지지 않는다 | `bin/masc_cli_auth.ml:164-180` |
| rev-store-boot 3 | P2 | medium-high | 외부 저장소가 없으면 8번 행으로 답해야 한다. 그런데 재시도나 취소 레코드가 든 로그는 「로그를 읽지 못함」 사유로 거부된다. 멈추는 것은 같고 사유가 다르다. 오늘은 문구만 틀린다 | `lib/auth/authz_boot_mode_read.ml:110-115,119` |
| rev-store-boot 4 | P2 | medium(코드 사실 high, 일어날 빈도 low-medium) | lease 배타가 `MASC_BASE_PATH_LEASE_DIR` 값이 같다는 데 달려 있다. 값이 다른 셸의 `masc auth off` 는 lease 를 얻는다 | `lib/host_config/host_config.ml:43-49` |
| rev-store-boot 5 | P3 | high | CLI 명령마다 로그와 저장소를 두 번 읽는다. 열 때 메모리는 파일 크기만큼이다. epoch 사건 하나에 fsync 가 세 번이다 | `lib/auth/authz_jsonl_file.ml:228-246` |
| rev-store-boot 6 | P3 | low(순서는 확인, sweep 본문은 읽지 않음) | 지우는 startup sweep 이 부팅 판정보다 먼저 돈다. 순서는 종합 세션도 직접 봤다(§2.2) | `bin/main_eio.ml:459-531` |
| rev-store-boot 7 | P3 | low | host tool 은 lease 없이 한 번 판정하고 그 결과를 끝까지 쓴다. 호출처 11곳 | `lib/runtime/runtime_account_access.ml:99-105` |
| rev-store-boot 8 | P3 | medium | Keeper 재배정은 intent 가 없어서 되감겨도 모른다 | `lib/auth/authz_state.ml:627-643` |
| rev-login-session 2 | P2. 통하면 P0 | 경로 높음, 통하는지는 모름 | 같은 기기의 프로세스가 남의 code 를 자기 transaction 에 넣는 길이 있다. GitHub 가 token 교환의 `redirect_uri` 를 authorize 때 값과 비교하면 막힌다. 비교하는지는 확인하지 못했다(§7.2) | `lib/auth/login_routes.ml:280`, `lib/auth/github_oauth.ml:69` |
| rev-login-session 3 | P2 | 중간 | 미리보기의 세션 cookie 가 같은 기기의 다른 포트와 공유된다(RFC 6265 8.5). 최대 7일 간다 | `lib/auth/authz_browser_request.ml:12` |
| rev-login-session 4 | P2 | 높음 | 초대, 사람, 세션을 거둘 수단이 없다. CLI 초대는 전부 Admin 이고 24시간이다. 남는 수단은 `masc auth off` 다 | `bin/main_eio.ml:1300`, `lib/auth/authz_activation.ml:120` |
| rev-login-session 5 | P2 | 중간(서버가 http 로도 닿을 때) | 초대 링크의 base 로 평문 http 주소를 받는다 | `lib/play/play_invite.ml:163`, `bin/masc_cli_auth.ml:34` |
| rev-login-session 6 | P3 | 높음 | 서버 파일의 절대 경로가 오류 응답에 실린다 | `lib/auth/login_routes.ml:465`, `lib/auth/authz_zone.ml:225` |
| rev-login-session 7 | P3 | 높음(실행 안 함) | `localhost` 로 연 미리보기에서는 로그인이 늘 실패한다 | `lib/server/server_request_authority.ml:253`, `lib/auth/login_client.ml:55` |
| rev-login-session 8 | P3 | 높음 | 다른 사이트가 진행 중인 로그인을 취소할 수 있다. 계정 피해는 없다 | `lib/auth/oidc_login_transaction.ml:198` |
| rev-login-session 9 | P3 | 높음 | transaction 시계 계약이 어긋난다. 미리보기가 벽시계를 넘긴다 | `lib/auth/oidc_login_transaction.mli:26`, `bin/masc_cli_auth.ml:220` |
| rev-rules-census 1 | 등급 없음 | 보고서 전체: 수치 High, 판정 Medium-High | 판정 도중 로그 head 가 3번 바뀌면 `Log_kept_moving` 으로 Keeper 턴을 거절한다 | `lib/auth/authz_keeper_turn.ml:12,186-198` |
| rev-rules-census 2 | 등급 없음 | 위와 같음 | `config.json` 을 못 읽으면 `Not_set` 으로 접는다. 로그에 모드 사건이 없거나 Off 뒤면 single user 로 부팅한다. 켜진 설치는 거절한다 | `lib/auth/authz_boot_mode_read.ml:41-43` |
| rev-rules-census 3 | 등급 없음 | 위와 같음 | `Unix.stat` 이 ENOENT 가 아닌 오류를 내면 판정이 `String.starts_with` 비교로 바뀐다. 이 검사는 외부 저장소가 설치 안에 있으면 거절한다. 오류를 「안에 없다」로 읽으므로 오류가 나면 통과한다 | `lib/auth/authz_bootstrap.ml:188-193` |
| rev-rules-census 6 | 등급 없음 | 위와 같음 | 판정식의 입력 다섯이 상수(`Active`, `Cleared`)다. 그 갈래는 실행되지 않는다 | `lib/auth/authz_keeper_turn.ml:72,79,94,117,134` |

통하면 P0 인 발견은 이 표의 rev-login-session 2번과 §2.5 의 실행 경계 1번 둘이다. 둘 다 바깥 제품의 동작에 달렸고 재지 않았다.

종합의 「코드로 직접 확인」 절은 작은 것 넷도 꼽는다. 평문 http 초대 링크, 초대 취소와 사람 정지를 쓰는 코드가 없는 것, 오류 응답의 서버 파일 경로, 역할 겹침이다. 역할 겹침은 메모에 줄 근거가 있다(§2.2, 직접). 앞의 셋은 메모에 줄 근거가 없다(직접(종합)). 줄 근거는 위 표의 rev-login-session 5번, 4번, 6번에 있다.

두 보고는 같은 접기를 적고 평가가 다르다. `config.json` 을 읽지 못하면 설정이 없는 것으로 읽는 자리다. rev-store-boot 는 설계 237줄이 정한 동작으로 본다. fail-open 부팅을 찾지 못했다고 적는다. rev-rules-census 2번은 규칙 위반으로 센다. 로그에 모드 사건이 없으면 정지하지 않고 single user 로 부팅한다. Off 뒤에도 거절하지 않고 single user 로 부팅한다. 이 둘이 그 보고가 든 이유다. 켜진 다계정 설치는 두 보고 모두 막힌다고 적는다.

### 2.4 확인해서 문제없던 것

모두 보고에만 있다.

- 답한 레코드를 잃는 꼬리 자르기가 없다. 모르는 값을 허용으로 바꾸는 catch-all(`| _ ->`)도 없다. 설계 §5.1 표는 11행이다. 입력이 맞으면 11행 모두 코드와 같다(rev-store-boot, `lib/auth/authz_boot_mode.ml:144-160`).
- state, verifier, nonce, 세션 secret, 초대 token 은 OS 의 암호용 난수 생성기(CSPRNG)에서 뽑은 32바이트다. transaction 은 한 번 쓰면 지워진다(rev-login-session).
- PKCE(Proof Key for Code Exchange)는 S256 이다. verifier 는 서버를 떠나지 않는다. `redirect_uri` 는 설정 고정값이고 Host 헤더에서 만들지 않는다(rev-login-session).
- 세션 cookie 는 `__Host-`, Secure, HttpOnly, SameSite=Strict 다. 상태를 바꾸는 요청은 same-origin `Origin` 과 CSRF token 이 모두 있어야 한다(rev-login-session).
- legacy bearer, internal token, query credential 은 `Auth_gate.decide` 가 모두 거절한다(rev-login-session).
- 로그인 8개와 사람 경로 12개에서 남의 Keeper 나 Runtime 을 id 로 읽거나 바꾸는 길은 찾지 못했다(rev-server-doors DO 6).
- Keeper phase 8개와 이벤트 13개가 닫힌 합타입이다. 그 위의 catch-all 은 찾지 못했다. 검색에 걸린 파일 5개는 모두 오탐이었다. 검색은 갈래 뒤 10줄만 봤다. 멀리 떨어진 갈래는 놓칠 수 있다(census-lifecycle-scale §1).

### 2.5 실행 경계 리뷰

실행 경계 리뷰(rev-exec-boundary)는 다른 리뷰보다 늦게 왔다. 공식 클라이언트 프로세스를 띄우는 곳과 호스트 key 를 쓰는 곳이 판정을 거치는지 읽었다. 결과는 P0 확정 0건, P0 후보 1건, P2 3건, P3 4건이다. 읽기만 했다. 빌드, 시험, 서버, CLI, 네트워크를 쓰지 않았다.

기준 트리가 다른 리뷰와 다르다.

- 과제를 받을 때 head 는 `85b8af5b0453` 이었다. 리뷰 도중 다른 세션이 그 worktree 를 `9424cc7b5394` 로 옮겼다. 커밋하지 않은 변경도 있었다.
- 줄 번호는 2026-11-10 18시 작업 트리 기준이다. 보고서는 `lib/runtime`, `lib/keeper`, `lib/auth_preview_keeper.ml` 이 기준 head 와 같다고 적는다.
- 기준 head 와 다른 인용 파일은 여섯이다. `bin/main_eio.ml`, `bin/masc_cli_auth.ml`, `lib/server/server_runtime_bootstrap.ml`, `lib/auth/authz_activation.ml`, `lib/auth/authz_boot_mode_read.ml`, 계획 문서다.

아래 표의 `직접` 은 종합 세션이 이슈 본문에 그 줄을 다시 읽었다고 적은 것이다. 발견 1~3 이 그렇다. 4~8 은 보고다.

| # | 등급 | 신뢰도 | 내용 | 근거 | 구분 | 이슈 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | P0 후보 | 저장소 경로 높음, 클라이언트 동작 모름 | `Native_none` 은 모델이 쓰는 도구만 막는다. 사람이 보낸 글은 고치지 않고 Claude Code 의 입력이 된다. 클라이언트가 글 안의 표기를 입력 단계에서 처리하는지는 재지 않았다. 처리한다면 서버 OS 사용자가 읽을 수 있는 파일이 한 사람의 턴에 실릴 수 있다. 다른 사람의 계정 홈도 그 범위 안이다 | `lib/server/server_preview_keeper_turn.ml:210-224`, `lib/runtime/runtime_native_tools.ml:295-308` | 직접 | #51072 |
| 2 | P2. S1 에서 이름으로 묶으면 P1 | 오늘 부분 높음 | 로그에 Keeper 를 만들 때 이미 있는 Keeper TOML 이름과 겹치는지 보지 않는다. 이름이 겹친 채로 다계정을 끄면 그 이름의 운영자 Keeper 는 공식 클라이언트 턴이 계속 거절된다. S1 부분은 아직 없는 코드라 추정이다 | `lib/auth_preview_keeper.ml:106-142`, `lib/runtime/runtime_account_access.ml:273-280` | 직접 | #51073 |
| 3 | P2 | 높음 | 다계정을 끈 뒤 「로그의 Keeper 는 턴이 없다」는 공식 계정 판정에만 있다. API provider 턴과 Antigravity 턴은 Keeper 이름을 판정에 넘기지 않는다. 로그에 있는 이름의 Keeper 가 그런 Runtime 을 쓰면 끈 뒤에도 호스트 key 로 턴이 돈다. 오늘은 2번처럼 이름이 겹칠 때만 닿는다 | `lib/runtime/runtime_account_access.ml:296-327,355-367` | 직접 | #51074 |
| 4 | P2, 잠재 | 중간 | Codex 자식 환경에 홈의 `config.toml` 이 고른 이름의 서버 환경 변수가 allow-list 없이 들어간다. 사람이 그 파일을 쓸 길은 찾지 못했다. 찾지 못했다는 쪽은 추정이다 | `lib/runtime/runtime_official_account.ml:85-121,137-140` | 보고 | #51074 |
| 5 | P3 | 높음 | Codex 에 `Native_none` 을 주면 CLI 를 띄운 뒤에 거절한다. 계획은 띄우지 않고 끝난다고 적는다. 이 조합을 만드는 호출자는 오늘 없다 | `lib/runtime/runtime_codex_app_server.ml:2538-2557,2946` | 보고 | #51074 |
| 6 | P3 | 높음 | 판정 없이 받는 선언값 `api_declaration` 에 Vertex 의 credential 함수가 남아 있다. 선언값을 읽는 곳 가운데 그 함수를 부르는 곳은 오늘 없다 | `lib/runtime/runtime_account_access.ml:377-379`, `lib/runtime/runtime_adapter.ml:754-760` | 보고 | #51074 |
| 7 | P3 | 높음 | 판정을 다 거치지 않는 운영자 CLI 가 다섯이다. 로그인 CLI 는 접근 값 게시도 판정도 없이 클라이언트를 띄운다. 둘은 게시 없이 key 로 보낸다. 모델 목록을 받는 둘은 base path 는 판정하지만 계정 홈이 그 아래인지 보지 않는다. 모두 호스트 셸이 있어야 한다. 그 사용자는 홈을 직접 읽을 수도 있다 | `bin/masc_cli_account_login.ml:19-41`(로그인), `bin/masc_cli_codex_models.ml:4-14`(모델 목록) | 보고 | #51074 |
| 8 | P3 | 중간 | 사람 홈의 위쪽 디렉터리가 이미 있으면 주인, 모드, 링크를 보지 않는다. 사람이 `.masc` 에 쓸 길은 찾지 못했다 | `lib/server/server_setup_account_login.ml:57-60` | 보고 | #51074 |

1번은 오늘 미리보기에서 닿는다. 미리보기는 `127.0.0.1` 에서만 듣고, 운영자가 초대한 사람만 들어온다. 실제 서버에는 Keeper 에게 글을 보내는 경로가 아직 없다. 이슈는 그 경로를 S1a-3 이 연다고 적고, 그 전에 닫는다고 적는다(#51072). 이 S1a-3 은 §6 에 옮긴 메모의 S1a-3 과 범위가 다르다. 보고서는 통하면 P0 이고 통하지 않으면 이 항목이 없어진다고 적는다.

리뷰가 결함으로 세지 않은 것이 하나 있다. 누가 턴을 일으키는가다. 판정은 initiator 와 executor 를 Keeper 소유자로 고정한다(`lib/auth/authz_keeper_turn.ml:139-179`). 보낸 사람은 판정의 입력에 없다. 그래서 S1 에서는 그 Keeper 에게 글을 보낼 수 있는 경로 권한이 유일한 문이다. 리뷰는 이것을 결정 사항으로 보고, rev-server-doors F3 과 같은 자리라고 적는다(§2.1 의 5).

리뷰는 두 가지를 전부 셌다.

- 공식 클라이언트 프로세스를 띄우는 곳은 12곳이다. 6곳은 타입 증명이 있어야 부를 수 있다. 4곳은 단일 사용자만 통과한다. 2곳은 판정 없이 뜬다. 로그인 helper 와 운영자 CLI 하나다(7번).
- provider HTTP 와 호스트 key 를 쓰는 곳은 17곳이다. 14곳은 추상 타입을 거쳐야 key 가 나온다. 문자열만으로 닿는 곳은 3곳이다. 하나는 운영자 CLI 다(7번). 하나는 key 없이 로컬 endpoint 를 부른다. 하나는 lib 와 bin 에 호출자가 없는 함수다.

읽어서 문제없던 것도 적었다.

- 접근 값을 게시하기 전에는 세 판정이 모두 거절한다. 게시는 한 번만 된다(`lib/runtime/runtime_account_access.ml:88`).
- 자세 판정은 프로세스를 띄우는 `run_turn` 안에 있다. 건너뛰는 호출자는 없다.
- 계정을 선언한 Claude 자식은 환경 이름 14개와 `CLAUDE_CONFIG_DIR`, 고정값 넷만 받는다. API key 이름은 빠진다(`lib/runtime/runtime_claude_environment_projection.ml:3-45,57-62`).
- 미리보기에서 남의 Keeper 는 404 다. 사람이 고르는 것은 글, Keeper 이름, 운영자가 선언한 모델 가운데 하나다.

리뷰가 확인하지 못한 것은 넷이다. 그 절의 다섯째 항목은 조사 과정의 기록이라 여기에 옮기지 않았다.

- Keeper 에게 보이는 MASC 도구, sandbox 마운트, 브라우저가 계정 홈(`.masc/accounts`)에 닿는지. 이 감사를 맡은 서브에이전트가 안전장치에 멈췄다. 리뷰는 안내에 따라 그 일을 직접 하지 않았다. 그래서 이 감사는 하지 못했다. 읽은 사실은 둘뿐이다. D3c-1 시험이 보는 것은 셋뿐이다. Docker 마운트 source, Apple guest 마운트와 게시 소켓, `resolve_keeper_read_path` 다. `under_persons` 를 부르는 곳은 Off 판정 한 곳이다.
- Claude Code 가 그 argv 에서 글 안의 표기를 입력 단계에서 어떻게 처리하는지(1번). 실행하지 않아서 재지 못했다.
- 사람이 자기 Codex 홈에 `config.toml` 을 쓸 길이 정말 없는지(4번). 첫 항목이 빠져서 확정하지 못했다.
- `Runtime_account_access` 를 부르지 않는 호스트 credential 통로가 다계정에서 닫히는지. GitHub App broker, Slack, Discord, MCP client, Keeper OAuth 다. 본문은 읽지 않았다.

이슈 #51074 는 첫 항목과 넷째 항목을 감사한다고 적는다. 시점은 계정 서버가 Keeper 를 띄우는 층 전이다.

종합 세션이 올린 이슈는 넷이다. #51072(1번), #51073(2번), #51074(3~8번과 확인하지 못한 것), #51075 다. #51075 는 리뷰의 발견 목록에 없는 항목이다. 단일 사용자 서버의 `/health` 가 인증 없이 host 경로와 빌드 기록을 답한다는 기록이다.

## 3. 권한 경계

경계마다 무엇이 정본이고 어디서 강제하는지 적었다. 표는 종합 세션이 만들었다.

| 경계 | 정본 | 강제하는 곳 | 빈 곳 |
| --- | --- | --- | --- |
| 계정 모드 | 권한 로그와 외부 저장소 | 부팅 판정 1회 | epoch 대조가 없다(§2.1 의 3) |
| 사람 신원 | 로그의 `(provider, 고유 id)` | 로그인 callback | 회수 수단이 없다(rev-login-session 4) |
| 요청 인가 | `Route_access` 종류 | `Auth_gate.decide` | 미리보기만 부른다. 멈춤을 보지 않는다(§2.1 의 1, 2) |
| CLI 시작 | 로그의 소유와 배정 | `Runtime_account_access.authorize` | 판정식 입력 일부가 상수다. 정지와 회수 사건이 아직 없다(rev-rules-census 6) |
| native 도구 | 발행된 접근 값 | `authorize_native` | Codex 와 Muse 는 측정 전까지 거절한다 |
| host 계정, API key | 발행된 접근 값 | `authorize_host`, `authorize_api` | 다계정에서 전부 거절한다. 공유 정책이 없다 |
| 도구 실행 격리 | Keeper 설정의 sandbox | lane | 다계정 Keeper 는 아직 도구가 없다 |
| MCP 문 | 없음 | 없음 | 사람용 문을 설계하지 않았다 |

실행 경계 리뷰는 이 표보다 늦게 왔다. 그 리뷰는 맡은 결정 셋((a), (b), (c))의 강제가 읽은 범위에서 타입으로 묶여 있다고 적는다. 세 결정의 글은 보고서에 없다. 빈칸으로 든 것은 둘이다. 다계정을 끈 뒤의 호스트 key 판정(§2.5 의 3번)과 운영자 CLI(§2.5 의 7번)다.

실행 판정 함수 넷은 한 파일에 있다. `authorize`, `authorize_host`, `authorize_api`, `authorize_native` 다(`lib/runtime/runtime_account_access.ml:339,362,381,409`).

실행 쪽은 경계가 분명하다. 요청 쪽은 절반만 있다.

- 요청 판정은 미리보기 핸들러만 부른다(§2.1 의 1).
- 메모는 `Route_access` 에 운영자 전용 종류와 Keeper 범위 종류가 없다고 적는다(직접, 단서는 §2.2). 종합은 그래서 기존 경로를 사람에게 열 때마다 분류를 새로 해야 한다고 적는다.
- 판정 결과가 핸들러를 타입으로 묶지 않는다(rev-server-doors F7, 보고).
- 프로세스 전역 `Atomic` 하나가 판정 근거를 한 번만 받는다. 판정 함수는 인자 없이 그 값을 읽는다(rev-rules-census 11, `lib/runtime/runtime_account_access.ml:86-97`, 보고).

rev-server-doors 는 문을 닫는 쪽보다 여는 쪽을 세자고 적는다. 닫을 등록 호출은 385곳이다. 열 경로는 21개다. 로그인 8, 사람 경로 12, `/health/live` 다(rev-server-doors §3). 종합은 이 셈을 근거로 S1a 를 자기 경로 표를 가진 계정 서버로 만들자고 제안한다(§6).

## 4. 바깥과 비교

바깥 조사는 웹 보고서 여섯과 MCP 감사 하나다. 신뢰도는 보고서마다 스스로 적었다.

- research-agent-security: 원문과 PDF 를 직접 읽은 것은 High, 요약 모델을 거친 것은 Medium.
- research-identity-authz: RFC 와 초안은 High, 벤더 출시는 Medium, 사고와 측정 수치는 Medium~Low.
- landscape-oss-orchestrators: 상태 사실은 High, 수치 기본값은 Medium.
- landscape-vendor-platforms: 문서에서 인용한 사실은 High, 사용자 반응은 Medium.
- community-signal: HN 과 GitHub 의 날짜와 수는 High, 순위는 Medium, Reddit 과 X 는 Low.
- research-landscape-terms: 1차 문서는 High, 해석은 Medium, 2차만 있는 사건은 Medium, 출처가 하나면 Low.
- audit-mcp-spec: 명세 사실은 High.

출처마다 원문, 요약, 2차를 가른 표는 각 보고서에 있다. 비율 가운데 보고서가 분모를 적지 않은 것이 있다. 아래의 7%, 58~90%, 40% 가 그렇다. 그런 곳은 보고서의 말만 옮겼다.

### 4.1 에이전트 보안

출처는 research-agent-security 다. 앞선 제품은 세 가지를 한다.

- 자격 증명을 sandbox 밖에 두고 proxy 가 요청에 붙인다. Claude 의 cloud session 은 VM 밖 proxy 가 지정한 host 요청에만 secret 을 붙인다([Claude Code 문서](https://code.claude.com/docs/en/cloud-environments)).
- harness 는 밖에 두고 도구 실행만 안에 둔다. Managed Agents 는 이렇게 바꾼 뒤 p50 TTFT(time to first token)가 약 60% 줄었다. p95 는 90% 넘게 줄었다([Anthropic](https://www.anthropic.com/engineering/managed-agents)).
- 상태를 밖의 log 에 두고 sandbox 를 일회용으로 쓴다(같은 글).

안 통한다고 드러난 것도 있다.

- 사람 승인. 승인 요청의 93%(2026-05 글)에서 97%(2026-08 글)가 승인된다. 위험한 명령을 사람이 막은 비율은 13.6% 다([Anthropic 2026-05](https://www.anthropic.com/engineering/how-we-contain-claude), [Anthropic 2026-08](https://claude.com/blog/auto-mode-default-in-claude-code)). 보고서는 auto mode 쪽 89% 와 표본 수 1,053 을 같이 적는다. 표본 수가 어느 수치의 것인지는 보고서만으로 알 수 없다.
- classifier 를 경계로 쓰기. auto mode 의 오탐은 0.4%(n=10,000)다. 실제 과잉 행동을 놓친 비율은 17%(n=52)다([Anthropic](https://www.anthropic.com/engineering/claude-code-auto-mode)). 2026-08 에는 module shadowing 사슬에 5번 중 3~4번 뚫렸다는 글이 나왔다([Embrace The Red](https://embracethered.com/blog/posts/2026/breaking-claude-code-opus-5-and-automode/)).
- injection 탐지와 필터. 발표된 방어 12개가 적응형 공격에 대부분 90% 넘게 뚫렸다([arXiv 2510.09023](https://arxiv.org/abs/2510.09023), 초록).
- 도메인 allowlist 만 두기. OpenAI 사고에서는 허용된 package proxy 가 인터넷 출구가 됐다. agent 사이의 게시판도 됐다([OpenAI 보고서](https://cdn.openai.com/pdf/67869394-cb91-4c12-888c-5cbd85c7814c/OpenAI-Hugging-Face%20Incident-Technical-Report.pdf)).

보고서는 다중 사용자 서버에 주는 뜻을 10개 적었다. 그중 다섯을 옮긴다.

- 공유 서비스는 숨은 통로다. 격리했다던 agent 약 1,200개가 공유 cache 로 7만 건 넘게 주고받았다([METR·Redwood](https://metr.org/hugging-face-incident-report-aug-2026.pdf), PDF 1~14쪽).
- log 는 sandbox 밖 경계에서 남긴다. agent 가 자기 transcript 를 위조하려 했고 약 7% 가 일부 위조됐다(같은 PDF).
- agent 사이 메시지는 untrusted input 이다. 다중 agent 는 개별 agent 가 거절해도 58~90% 임의 코드를 실행했다([arXiv 2503.12188](https://arxiv.org/abs/2503.12188), 초록).
- 모든 경로에 인증을 건다. 2026-01-31 에 인터넷에 노출된 OpenClaw 가 21,639대였다([Censys](https://censys.com/blog/openclaw-in-the-wild-mapping-the-public-exposure-of-a-viral-ai-assistant)).
- plugin, skill, MCP 는 공급망이다. skill 3,984개 중 534개가 critical 이었고 76개가 악성이었다([Snyk](https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/)).

masc 와 견주면 방향은 같다(종합). harness 는 sandbox 밖에 있다. 구독 로그인은 모델 손이 닿지 않는 곳에 있다. 판정은 모델이 아니라 결정론 코드가 한다.

이 문서가 두 보고를 나란히 놓고 본 것도 둘 있다.

- 「모든 경로에 인증」 기준에 맞지 않는 곳이 §2.1 의 1 이다. loopback 에서 자격 없이 열리는 dev-token 경로와 gRPC 다.
- 「agent 사이 메시지는 untrusted」 기준이 닿는 곳이 §2.1 의 5 다. 주인이 아닌 사람의 메시지가 Keeper 큐에 들어오면 주인의 구독으로 턴이 돈다.

### 4.2 샌드박스

출처는 research-agent-security 와 census-lifecycle-scale 이다.

- 파일시스템 격리와 네트워크 격리를 OS 수준에서 같이 건다. Claude Code 는 Seatbelt 와 bubblewrap 을 쓴다. 승인 요청이 84% 줄었다([Anthropic](https://www.anthropic.com/engineering/claude-code-sandboxing)).
- Codex 는 Seatbelt 와 bwrap+seccomp 를 쓴다. network 는 기본 off 다([OpenAI 문서](https://learn.chatgpt.com/docs/agent-approvals-security)).
- Cursor 는 Landlock+seccomp 를 쓴다. 멈춤이 40% 줄었다([Cursor](https://cursor.com/blog/agent-sandboxing)).
- 신뢰하지 못하는 코드에는 kernel 경계를 둔다. E2B 는 세션마다 Firecracker 를 쓴다([E2B](https://e2b.dev/)). Docker 는 sandbox 마다 microVM 을 쓴다([Docker 문서](https://docs.docker.com/ai/sandboxes/security/)). AgentCore 도 세션마다 microVM 을 쓴다([AWS 문서](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-sessions.html)).
- egress 는 guest 밖에서 강제한다. Vercel 은 host 쪽 firewall, SNI 필터, sandbox 별 CA 로 한다([Vercel](https://vercel.com/blog/a-sandbox-without-a-network-boundary-is-only-half-a-sandbox)). proxy 환경 변수는 강제가 아니다([Simon Edwardsson](https://simedw.com/2026/06/05/proxy-agents/)).
- 단계마다 권한을 바꾼다. Codex cloud 는 setup 단계에 인터넷을 켜고 agent 단계에는 기본으로 끈다(OpenAI 문서).
- Claude Code 는 sandbox 가 뜨지 못하면 기본으로 sandbox 없이 실행한다([Claude Code 문서](https://code.claude.com/docs/en/sandboxing)). 보고서는 다중 사용자 서버라면 이때 실행을 거부하라고 적는다.
- 근거가 얇은 것이 있다. sandbox 엔진마다 안에서 닿는 host 원시 기능이 몇 개인지 센 수다. 14개 가운데 gVisor 5, e2b 7, daytona 11, microsandbox 11, arrakis 12 다. 이 수는 [arXiv 2606.08433](https://arxiv.org/abs/2606.08433) 한 편에만 있다.

masc 의 지금 상태는 이렇다.

- sandbox 종류는 `Docker | Micro_vm | Remote_ssh` 셋이다(`lib/config/keeper_sandbox_config.ml:7-10`, 직접). host 에서 바로 실행하는 갈래가 없다.
- 기본값이 없다. TOML 에 선언이 없으면 boot error 다(`lib/keeper/keeper_runtime.ml:350-370`, census-lifecycle-scale §8).
- network 기본값은 Docker 와 microVM 이 none 이고 SSH 가 inherit 다(`lib/keeper_types_profile_sandbox/keeper_types_profile_sandbox.ml:85-89`, 같은 절).
- 호스트 프로세스 격리 단계가 없다. Seatbelt, bubblewrap, Landlock 같은 것이다(직접). 그래서 컨테이너도 원격 host 도 없는 설치는 Keeper 를 띄우지 못한다. 종합은 이것을 컨테이너 없는 설치는 Keeper 를 못 띄운다고 적었다.
- 미리보기의 Keeper 턴은 도구가 없다(§1). 종합의 표는 다계정 Keeper 에 아직 도구가 없다고 적는다(§3).

### 4.3 신원과 인가

출처는 research-identity-authz 다. 새 시스템이 맞춰야 할 기준선 10개 가운데 이 구현과 닿는 것을 옮긴다.

- 로그인은 authorization code 와 PKCE S256 으로 한다. redirect URI 는 정확히 일치해야 한다([RFC 9700](https://datatracker.ietf.org/doc/rfc9700/)).
- IdP(Identity Provider)가 둘 이상이면 `iss` 를 검증한다. 또는 IdP 마다 redirect URI 를 나눈다(RFC 9700, RFC 9207).
- Google 의 사용자 키는 `sub` 다.
- GitHub 는 PKCE 를 S256 만 받는다. OAuth app 도 2026-08-14 부터 8시간 access token 과 6개월 refresh token 을 쓴다. 새로 만든 앱의 기본값이다([GitHub Changelog](https://github.blog/changelog/2026-08-14-multiple-redirect-uris-and-token-refresh-for-oauth-apps)).
- 세션 cookie 는 `__Host-`, Secure, HttpOnly, SameSite 로 둔다(OWASP, RFC 10017).
- 권한 검사는 한 곳에서 한다. Open WebUI 는 기능마다 따로 검사했고 8개월에 CVE 6건이 났다([CSA](https://labs.cloudsecurityalliance.org/research/csa-research-note-open-webui-access-control-cves-20260710-cs/), 출처 한 곳).
- 정지된 사람의 credential 은 바로 죽어야 한다. Coder 는 정지된 사용자의 API key 가 계속 통했다([CVE-2026-55435](https://www.miggo.io/vulnerability-database/cve/CVE-2026-55435)).
- resource server 는 자기 앞으로 발급된 token 만 받는다. Open WebUI 는 audience 를 보지 않아 계정을 내줬다([CVE-2026-70482](https://advisories.gitlab.com/pypi/open-webui/CVE-2026-70482/)).

보고서가 다중 사용자 에이전트 서버에 적은 함의 가운데 넷을 옮긴다.

- 사람 키는 Google 이 `(iss, sub)` 이고 GitHub 가 숫자 `id` 다. email 로 계정을 합치지 않는다(함의 1). GitHub 숫자 `id` 를 키로 쓰라는 문장은 GitHub 문서에서 찾지 못했다. 관행이다.
- 에이전트는 주인이 있는 별도 principal 이다. 호출마다 actor(agent)와 owner(person)를 같이 싣는다.
- provider 로그인은 에이전트와 모델에게 주지 않는다. 서버가 주인 이름으로 호출하고 사용량을 그 사람에게 붙인다([Coder AI Gateway](https://coder.com/docs/ai-coder/ai-gateway.md), [draft-ietf-wimse-aims](https://datatracker.ietf.org/doc/draft-ietf-wimse-aims/)).
- 사람 정지나 grant 회수 한 번으로 그 사람의 credential 이 모두 죽어야 한다. 세션, PAT, refresh token, 그 사람 에이전트의 token 이다.

masc 와 견주면 이렇다.

- 맞는 것: PKCE S256, 고정 `redirect_uri`, `__Host-` cookie, GitHub 숫자 id 를 쓴다(rev-login-session, §2.4).
- 걸리는 것: 정지 기록이 중간에 끊기면 이미 있는 세션과 PAT 가 계속 통한다(§2.1 의 2). 정지와 회수를 쓰는 코드도 아직 없다(rev-login-session 4).
- 걸리는 것: 요청 판정을 부르는 곳이 미리보기뿐이다. 기존 서버 경로는 `Server_auth` 래퍼가 따로 검사한다(§2.1 의 1).

rev-login-session 발견 2(§2.3)는 GitHub 가 loopback redirect 를 다루는 방식에 달려 있다. 종합 세션이 GitHub OAuth App 문서를 2026-11-10 에 열었다([GitHub Docs](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)).

- loopback callback 은 port 가 달라도 받는다.
- token 교환의 `redirect_uri` 는 "strongly recommended" 라고만 적혀 있다. 값이 다를 때의 오류는 문서에 없다.
- PKCE 는 S256 만 받는다.

그래서 rev-login-session 발견 2 가 통하는지는 문서만으로 정하지 못한다. 시험용 OAuth App 에서 재 봐야 한다. 실제 서버는 https 고정 redirect 를 쓰므로 이 조건이 사라진다(종합).

### 4.4 MCP 명세

출처는 audit-mcp-spec 과 research-identity-authz 다. 명세 페이지는 2026-11-10 에 원문으로 열었다.

- 최신 released 판은 2026-07-28 이다([versioning](https://modelcontextprotocol.io/specification/versioning)).
- 이 판이 initialize, session, GET stream, `ping`, SSE 재개를 지웠다. 요청마다 `_meta` 에 version 과 capability 를 싣는다([changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)).
- `server/discover`, `subscriptions/listen` 이 생겼다. 새 오류 코드는 -32020, -32021, -32022 다. resource not found 는 -32602 로 바뀌었다(같은 changelog).
- DCR(Dynamic Client Registration), Roots, Sampling, Logging 은 Deprecated 다(같은 changelog). client 등록은 사전 등록, CIMD(Client ID Metadata Documents), DCR 순서로 고른다([client registration](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration)).
- MCP 서버는 OAuth resource server 다. 요청마다 Bearer token 을 검증한다. 받은 token 을 upstream 에 넘기면 안 된다([authorization](https://modelcontextprotocol.io/specification/latest/basic/authorization)).
- 원격 MCP 서버 7,973대 중 40.55% 가 인증이 없었다. OAuth 를 붙인 119대 중 96.6% 에서 DCR 결함이 나왔다([arXiv 2605.22333](https://arxiv.org/abs/2605.22333), 초록만 읽음, 프리프린트 한 편).

masc 구현은 받는 version 이 6개이고 최신 명세를 대부분 지킨다(`lib/mcp_transport_protocol/mcp_transport_protocol.ml:574-584`). 감사가 찾은 틈은 10개다.

| # | 틈 | 근거 |
| --- | --- | --- |
| 1 | HTTP 에서 미지원 version 을 400 과 -32600 으로 끊는다. 명세는 -32022 와 `data.supported` 다 | `lib/server/server_http_ingress.ml:93-108`, 직접 |
| 2 | legacy session id 를 맞힐 수 있다. 형식이 `mcp_<ms>_<pid>_<0~999999>` 다 | `lib/mcp_session/mcp_session.ml:30-37`, 직접 |
| 3 | access token 을 query string 으로 받는다 | `lib/server/server_auth.ml:110-128`, 직접 |
| 4 | OAuth 발견이 loopback authority 에서만 된다. 원격 client 는 static bearer 만 쓸 수 있다 | `lib/server/server_oauth_http.ml:46-56` |
| 5 | HTTP 요청을 취소할 길이 없다. 명세는 연결이 끊기면 취소다 | `lib/server/server_mcp_transport_http.ml:504` |
| 6 | 모르는 tool 에 -32601 을 준다. 명세는 -32602 다 | `lib/mcp_server_eio_protocol.ml:1234,1292`, 직접 |
| 7 | listen stream 을 서버가 닫을 때 신호를 보내지 않는다 | `lib/server/server_mcp_listen_stream.ml:44-50` |
| 8 | error code 가 명세 범위를 벗어난다. -32002, -32001, -32007 이다 | `lib/server/server_mcp_transport_http_respond.ml:144-158` |
| 9 | progress 알림에 `progressToken` 이 없다 | `lib/progress.ml:35-52` |
| 10 | version 을 다루는 곳 넷이 명세와 다르다. 지원 목록(`supportedVersions`, `data.supported`)에 `DRAFT-2026-v1` 이 있다. 지금 draft schema 에는 없는 이름이다. legacy version 을 `_meta` 로 보내면 -32022 가 아니라 -32602 다. 헤더가 없으면 2025-03-26 이 아니라 2025-11-25 로 본다. stdio 는 진행 중인 id 와 겹치면 오류의 id 를 null 로 준다 | `lib/mcp_transport_protocol/mcp_transport_protocol.ml:575,591,714`, `lib/mcp_server_eio_protocol.ml:1764-1773` |

- 틈 6 과 7 은 [기존 대조 문서](2026-10-27-mcp-2026-07-28-parity.md)의 Known gaps 와 일부 겹친다. 나머지 여덟은 그 문서에 없다(audit-mcp-spec §3).
- 틈 2 의 세션 id 는 인증을 켜면 요청마다 token 을 먼저 본다(`lib/server/server_mcp_transport_http.ml:357-371`, 보고).

다계정에 주는 뜻은 둘이다.

- 명세에서 세션이 없어졌다. 계획 C4-12 는 WS/SSE 와 MCP transport 를 인증한 세션과 PAT 에 결속한다. 폐기 때는 닫는다. `__Host-masc_mcp_session` cookie 도 여기서 만든다(계획 487줄). 이 층은 요청마다 token 을 사람으로 바꾸는 방식으로 고쳐야 한다(종합).
- 사람용 MCP 문을 만들 때는 RFC 9728 메타데이터, audience 고정, `iss` 발급을 갖춘다. DCR 은 새로 만들지 않는다(research-identity-authz 함의 6).

### 4.5 벤더 제품

출처는 landscape-vendor-platforms 다. 제품 10개의 문서를 2026-11-10 에 열었다. Claude Code, Claude Managed Agents, OpenAI Codex, OpenAI Agents API, Cursor Cloud Agents, GitHub Copilot cloud agent, Devin, Factory, Amp, Antigravity 2.0 이다.

보고서는 제품들이 같이 쓰는 설계 8개를 뽑았다.

| # | 설계 | 예와 출처 |
| --- | --- | --- |
| 1 | 루프는 벤더 쪽에 둔다. 실행기는 밖에서 outbound 로 큐를 polling 한다 | [Claude Code](https://code.claude.com/docs/en/self-hosted-environments), [Managed Agents](https://platform.claude.com/docs/en/managed-agents/self-hosted-sandboxes), [Cursor](https://cursor.com/docs/cloud-agent/self-hosted), [Devin](https://docs.devin.ai/cloud/outposts/overview.md), [OpenAI](https://developers.openai.com/api/docs/guides/agents-api/environments/self-hosted) |
| 2 | 일감을 lease 로 쥔다. lease 가 끊기면 다시 큐로 간다 | Claude Code 는 poll 이 lease 갱신이자 heartbeat 다. 약 60초 뒤 끊긴다(위 URL). [Devin Outposts](https://docs.devin.ai/cloud/outposts/orchestration.md) 는 claim 에서 진 쪽에 409 를 준다 |
| 3 | 상태 집합이 작다. 재시도나 입력 대기에 이름 붙은 상태를 둔다 | [Managed Agents](https://platform.claude.com/docs/en/managed-agents/sessions) 의 `rescheduling`, [Claude Code](https://code.claude.com/docs/en/agent-view) 의 Needs input, [Codex](https://learn.chatgpt.com/docs/app-server.md) 의 `systemError` |
| 4 | 기기마다 supervisor 가 있다. 세션마다 프로세스 하나다. 유휴 프로세스는 멈추고 transcript 는 남긴다 | [Claude Code](https://code.claude.com/docs/en/agent-view) |
| 5 | 전달은 at-least-once 다. 소비자가 idempotent 하다 | Devin(위 orchestration URL), [OpenAI](https://developers.openai.com/workspace-agents/trigger-runs.md) 의 `Idempotency-Key`. Codex app-server 는 큐가 차면 -32001 을 준다 |
| 6 | runner 마다 capacity 와 drain 설정이 있다 | Claude Code `--capacity`, `--drain-grace-sec`, `--retire-at`. [Remote Control](https://code.claude.com/docs/en/remote-control) 의 기본 capacity 는 32 다. [Cursor](https://cursor.com/docs/cloud-agent/self-hosted/pool) 는 worker 를 10,000개까지 둔다. [Factory](https://docs.factory.com/droid-computers/overview.md) 는 computer 하나에 worker 1~50개다(기본 3) |
| 7 | 관리자가 내리는 최상위 설정 층이 있다 | [Claude Code](https://code.claude.com/docs/en/server-managed-settings)(매시간 갱신), [Codex](https://learn.chatgpt.com/docs/enterprise/managed-configuration.md), [Factory](https://docs.factory.com/enterprise/hierarchical-settings-and-org-control.md) |
| 8 | 프롬프트를 파일이나 버전 있는 객체로 둔다 | [Claude Code](https://code.claude.com/docs/en/sub-agents), [Cursor](https://cursor.com/docs/subagents), [Codex](https://learn.chatgpt.com/docs/agent-configuration/subagents.md), [Managed Agents](https://platform.claude.com/docs/en/managed-agents/overview) |

보고서가 찾지 못한 것도 있다.

- A2A(Agent2Agent)는 열어 본 벤더 페이지 어디에도 없었다.
- 도구 효과를 idempotent 하게 만든다고 문서에 적은 제품이 없었다.
- 사용자 평은 얇다. 절반쯤이 댓글 하나에서 왔다.

보고서가 찾은 사실도 하나 더 옮긴다. self-hosted 실행기의 격리는 운영자에게 맡긴다. Claude Code, Devin Outposts, OpenAI 가 그렇다(1번의 URL).

masc 와 견주면 이렇다.

- masc 는 프로세스 하나다. base path 하나에 서버 하나가 뜬다. 잠금은 같은 호스트의 커널 잠금(`Unix.lockf`)이고 분산 lease 는 없다(`lib/server/server_startup_takeover.ml:934-1000`, census-lifecycle-scale §2).
- 저장소는 전부 로컬 파일이다. SQLite 를 쓰는 모듈이 12개다(같은 절).
- 벤더 다섯이 같은 모양으로 규모를 늘린다. 루프는 가운데 두고 실행기가 밖에서 붙어 일감을 가져간다(위 표 1번). 일감을 lease 로 쥔다고 적힌 곳은 Claude Code 와 Devin 둘이다(위 표 2번). 종합은 벤더 다섯이 lease 로 쥔다고 적었다.
- 상태 집합은 masc 도 작다. Keeper phase 가 8개인 닫힌 타입이다(`lib/keeper_registry/keeper_state_machine_phase.mli:3`).
- 프롬프트는 masc 도 파일에 둔다. `config/prompts` 에 45개 파일이 있다(census-lifecycle-scale §6).

### 4.6 오픈소스

출처는 landscape-oss-orchestrators 다. orchestrator 9개와 durable runtime 6개를 봤다. OpenHands, Hermes Agent, OpenClaw, Orca, Gas Town, Conductor, Vibe Kanban, claude-squad, Coder 와 Letta, LangSmith Deployment, CrewAI, Temporal, Restate, DBOS 다. 아래 표의 Gas City 는 Gas Town 의 후속이다. 페이지는 요약 모델을 거쳐 읽었다. 아래 수치 기본값은 신뢰도 Medium 이다.

보고서가 가져올 만하다고 뽑은 모양은 10개다.

| # | 모양 | 출처 |
| --- | --- | --- |
| 1 | supervisor 를 LLM 역할이 아니라 코드로 둔다. 30초마다 원하는 상태와 실행 중인 세션을 맞춘다. `restart_window=1h` 안에 재시작이 `max_restarts=5` 에 이르면 격리한다 | [Gas City](https://raw.githubusercontent.com/gastownhall/gascity/main/engdocs/architecture/controller.md) |
| 2 | 일감 판을 durable 하게 둔다. SQLite WAL 행이다. 60초 dispatcher 가 atomic 하게 claim 한다. heartbeat 가 4시간 없으면 회수한다 | [Hermes Kanban](https://hermes-agent.nousresearch.com/docs/user-guide/features/kanban) |
| 3 | 단계마다 다음으로 가기 전에 journal 에 적는다. 세션마다 writer 가 하나다 | [Restate](https://docs.restate.dev/references/architecture) |
| 4 | lease, heartbeat, sweeper 를 둔다. sweeper 가 2분마다 멈춘 run 을 큐로 돌린다 | [LangSmith](https://docs.langchain.com/langsmith/scalability-and-resilience) |
| 5 | 큐의 흐름 제어를 데이터로 둔다. 동시성과 rate limit 값을 실행 중에 바꾼다 | [DBOS](https://docs.dbos.dev/python/tutorials/queue-tutorial) |
| 6 | 루프와 LLM key 를 서버에 둔다. Community 판과 Premium 판에서는 동시에 도는 agent 가 5개까지고 그 뒤는 큐에 선다 | [Coder Agents](https://coder.com/docs/ai-coder/agents/architecture), [사용량](https://coder.com/docs/ai-coder/agents/licensing-usage) |
| 7 | 벤더 harness 를 자기 로그인을 가진 subprocess 로 돌린다. OpenClaw 는 설치된 Claude Code 를 실행하고 그 token 을 읽지 않는다 | [Coder](https://coder.com/docs/ai-coder/agents/acp-subagents), [OpenClaw](https://docs.openclaw.ai/providers/anthropic) |
| 8 | PTY 를 쥔 daemon 과 worker 규약을 둔다. worker 는 끝났다는 신호를 한 번만 보낸다 | [Orca](https://www.onorca.dev/docs/cli/orchestration) |
| 9 | 세션마다 들어오는 메시지의 처리 방식을 고른다. steer, followup, collect, interrupt 다 | [OpenClaw](https://docs.openclaw.ai/concepts/queue) |
| 10 | 설정과 프롬프트를 층이 있는 파일로 둔다. 코드에 역할 이름이 없다 | [Gas City](https://raw.githubusercontent.com/gastownhall/gascity/main/engdocs/architecture/prompt-templates.md), [Conductor](https://www.conductor.build/llms-full.txt) |

어느 곳도 잘 채우지 못한 자리는 6개다.

- 오픈소스 판의 팀 계정과 사람별 vendor credential. OpenHands 는 org, RBAC(Role-Based Access Control), SAML 로그인을 Cloud 판과 Enterprise 판에 둔다([문서](https://docs.openhands.dev/enterprise/enterprise-vs-oss)). Hermes 의 gateway RBAC 이슈는 2026-03-06 부터 열려 있다([이슈](https://github.com/NousResearch/hermes-agent/issues/527)). OpenClaw 문서는 제대로 격리하려면 사람마다 agent 를 따로 두라고 적는다([문서](https://docs.openclaw.ai/concepts/multi-agent)).
- 구독 계정 사이에서 quota 를 보고 일감을 나누는 기능. Gas Town 의 요청은 2026-01-06 부터 열려 있다([이슈](https://github.com/gastownhall/gastown/issues/232)).
- host 재부팅이나 supervisor crash 뒤에도 사는 CLI 세션. Orca 는 재부팅 뒤 agent 를 다시 실행해야 한다([문서](https://www.onorca.dev/docs/model/session-restore)). OpenHands 는 죽은 agent-server 를 다시 띄우지 않는다([이슈](https://github.com/OpenHands/OpenHands/issues/16690)).
- 재시도해도 안전한 agent API. Coder 는 chat 과 메시지를 만드는 호출에 idempotency key 가 없다([이슈](https://github.com/coder/coder/issues/31758), 2026-11-04).
- 여러 벤더의 CLI 를 ACP(Agent Client Protocol)로 묶는 일. Hermes 의 범용 ACP client 는 2026-04-05 부터 미정이다([이슈](https://github.com/NousResearch/hermes-agent/issues/5257)).
- 기본 sandbox 와 프로젝트의 지속. OpenClaw 는 sandbox 가 기본으로 꺼져 있다([문서](https://docs.openclaw.ai/gateway/sandboxing)). Vibe Kanban 은 회사가 문을 닫았다([글](https://vibekanban.com/blog/shutdown)). AgentAPI 는 archive 됐다([저장소](https://github.com/coder/agentapi)).

첫째 자리가 masc 가 가려는 자리다. 조사한 15개 가운데 오픈소스 판에서 팀 계정과 사람별 구독을 같이 주는 곳을 찾지 못했다. 종합은 이 자리를 무료 판이라고 적었다.

### 4.7 커뮤니티 신호

출처는 community-signal 이다. Hacker News 는 공개 검색 API 로 읽었다. GitHub 이슈 9개와 웹 2쪽도 읽었다. Reddit 과 X 는 읽지 못했다. 순위는 조사한 쪽이 스레드 수와 점수를 보고 매겼다. 표본이 Hacker News 에 치우쳐 있다.

| 순위 | 주제 | 신호의 크기 | 예 |
| --- | --- | --- | --- |
| 1 | 비용이 누구 몫인지 보이지 않는다 | 스레드 13개. 가장 큰 것이 624점, 댓글 769개 | 공유 LLM key 는 어느 agent 가 얼마를 썼는지 가린다([2026-08-23](https://news.ycombinator.com/item?id=49406200)) |
| 2 | 구독 약관과 계정 정지 걱정 | 2026-01~04 에 625~1,099점 스레드 셋 | wrapper 가 언제 제3자 harness 가 되는지 모르겠다는 글([2026-04-05](https://news.ycombinator.com/item?id=47645203)) |
| 3 | 권한 프롬프트와 skip-permissions 사이 | 스레드 4개, 292~664점 | 프롬프트 대신 agent 가 마음껏 일할 가상 머신을 바란다([2026-08-10](https://news.ycombinator.com/item?id=49240595)) |
| 4 | secret 과 credential | 스레드 7개. secret 만 다룬 스레드 가운데 가장 큰 것이 623점, 댓글 422개다. 같은 묶음에 770점 스레드가 하나 더 있다 | credential 이 sandbox 안에 아예 없도록 밖에 broker 를 두자는 글([2026-09-30](https://news.ycombinator.com/item?id=49905655)) |
| 5 | 리뷰가 병목이다 | 스레드 5개. 488점에 댓글 481개, 365점에 댓글 314개 | 코딩이 아니라 PR 리뷰가 병목이라는 글([2026-05-30](https://news.ycombinator.com/item?id=48331917)) |
| 6 | 폭주와 조용한 멈춤 | HN 스레드 3개, GitHub 이슈 5개, 포럼 글 1개 | subagent 437개가 멈추지 않고 돌았다([2026-09-28](https://news.ycombinator.com/item?id=49875938)). pipeline 이 약 6.5시간 신호 없이 멈췄다([2026-09-06](https://github.com/anthropics/claude-code/issues/92410)) |
| 7 | memory 가 낡는다 | 스레드 3개. 가장 큰 것이 392점, 댓글 312개 | 상태가 agent 밖에서 바뀌면 memory 가 낡아 context 를 흐린다([2026-10-04](https://news.ycombinator.com/item?id=49952046)) |
| 8 | 관측과 감사 | 425점에 댓글 249개인 스레드 하나. 그 GitHub 이슈는 thumbs-up 138개 | 무슨 일이 있었는지 되짚을 감사 기록이 없다([2026-07-14](https://news.ycombinator.com/item?id=48905857)) |
| 9 | compaction, 한도, 재시작 때 context 를 잃는다 | HN 스레드 2개(211점, 125점), GitHub 이슈 2개 | 몇 시간마다 compaction 이 작업 context 를 지운다([2026-10-09](https://github.com/anthropics/claude-code/issues/100710)) |
| 10 | 조율, worktree 와 disk, 한도 경쟁 | 42~263점 스레드 4개 | worktree 하나에 build 산출물이 200GiB 쌓인다([2026-07-30](https://news.ycombinator.com/item?id=49110131)) |

출처가 하나뿐인 이야기도 보고서에 있다. USD 78,000 Codex 이야기는 그 스레드 안에서도 반박됐다. subagent 449개가 한도에 끊겼다는 수는 도구를 만든 사람 한 명의 글이다. 이 문서는 둘을 근거로 쓰지 않는다.

이 문서가 다른 절과 나란히 놓고 본 것은 둘이다.

- 1번과 2번은 사람마다 자기 구독을 쓰는 설계와 닿는다. 사용량이 구독 주인에게 붙는다(§4.3, §4.8).
- 4번의 바람은 §4.1 의 첫째 방식과 같다. 자격 증명을 sandbox 밖에 둔다.

### 4.8 구독 약관

출처는 research-landscape-terms 다. landscape-oss-orchestrators, community-signal, 종합도 쓴다. 이 절은 법률 검토가 아니다. 약관 문장은 뜻만 옮겼다.

보고서가 물은 것은 하나다. 팀원이 각자 자기 유료 구독으로 로그인한다. self-hosted 팀 서버가 그 사람 몫으로 벤더의 공식 CLI 를 subprocess 로 띄운다. 벤더가 이것을 허용하는가.

| 벤더 | 판정 | 근거 |
| --- | --- | --- |
| Anthropic(Claude Code) | 조건부 허용 | 수정하지 않은 `claude` 에 본인 구독으로 로그인하는 것은 platform 이 호스팅해도 막지 않는다. 서버가 자격증명을 모으거나 보관하거나 중개하는 것은 허용하지 않는다([legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)) |
| OpenAI(Codex CLI) | 문서로는 허용, 자동화에는 권하지 않음 | 문서가 원격 기계 로그인과 `codex exec` 의 로그인 재사용을 안내한다([auth](https://learn.chatgpt.com/docs/auth), [non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)). 자동화 인증에는 API 키를 권한다([CI/CD auth](https://learn.chatgpt.com/docs/auth/ci-cd-auth)). Terms of Use 원문은 403 이라 읽지 못했다 |
| Google(Antigravity CLI, 소비자 플랜) | 지원하지 않음 | 다른 앱이 `agy` 를 감싸는 것은 소비자 플랜에서 지원하지 않는다([FAQ](https://antigravity.google/docs/faq/)). third-party 도구로 접근하면 약관 위반이다([약관](https://antigravity.google/terms)). 감싸기만 따로 위반이라고 적은 문장은 없다 |

Anthropic 문서는 호스팅에 조건 둘을 붙인다(같은 페이지).

- Claude Code binary 를 수정하지 않는다. 그 안의 인증 방법을 빼거나 끄거나 제한하지 않는다.
- end user 대신 사용량을 내거나 되팔거나 중개하지 않는다. end user 는 저마다 자기 API 키나 자기 구독 자격증명으로 인증한다.

같은 페이지가 적은 것이 둘 더 있다.

- Commercial Terms of Service 동의가 조건이다. 자기 제품이나 서비스에 Claude Code 를 미리 설치하거나 실행하는 쪽에 붙는다. 따로 합의한 경우는 예외다.
- 구독 한도는 보통의 개인 사용이 전제다. Anthropic 은 사전 통지 없이 집행할 수 있다고 적는다.

문서에 답이 없는 것도 보고서가 적었다.

- 자기 팀만 쓰는 self-hosted 서버가 문서가 말하는 제품이나 서비스에 드는지.
- 보통의 개인 사용이 상시 실행 agent 를 품는지. 숫자도 예도 없다.
- wrapper 와 third-party harness 의 경계를 적은 1차 문장.

앞의 둘은 벤더에 물어야 닫힌다. 문서는 sales 에 문의하라고 적는다.

정책은 2026년에 움직였다. 보고서는 Anthropic 쪽에서 날짜가 있는 변경을 넷으로 센다.

- 2026-02-20: The Register 가 당시 문구를 옮겼다. 구독 계정의 OAuth token 을 다른 제품에서 쓰는 것을 허용하지 않는다는 문구다. 지금 문서에는 그 문장이 없다([The Register](https://www.theregister.com/software/2026/02/20/anthropic-clarifies-ban-on-third-party-tool-access-to-claude/5014546), 2차).
- 2026-04-04: 사용자가 전날 Anthropic 메일을 Hacker News 에 올렸다. 메일은 third-party harness 가 이날부터 구독 한도를 쓰지 못한다고 알렸다. 스레드는 1,099점이다([HN 47633396](https://news.ycombinator.com/item?id=47633396), 2차).
- 2026-06-15: 5월에 예고한 전환을 당일 보류했다. Agent SDK 와 `claude -p` 를 구독 한도에서 떼어 전용 credit 으로 옮기는 전환이었다([Anthropic 도움말](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan), 1차. [HN 48546618](https://news.ycombinator.com/item?id=48546618), 2차).
- 2026-10-07: 도움말이 갱신됐다. Max, Ultra, Team 플랜에 월 API credit 이 들어간다고 적는다(같은 도움말).

다시 허용됐다는 글은 따로 둔다. 2026-04-21 에 Hacker News 에 올라왔고 511점이다. 링크는 OpenClaw 문서다([HN 47844269](https://news.ycombinator.com/item?id=47844269), [OpenClaw 문서](https://docs.openclaw.ai/providers/anthropic)). Anthropic 이 직접 낸 글은 보고서가 찾지 못했다. 출처가 하나라 신뢰도는 Low 다.

- landscape-oss-orchestrators 는 47633396 스레드만 읽었다. 나머지 스레드는 제목, 날짜, 점수만 봤다.
- OpenClaw 문서는 공유 자동화에 API key 를 쓰라고 권한다(위 OpenClaw 문서, landscape-oss-orchestrators).
- 사용자 쪽 걱정은 §4.7 의 2번이다. community-signal 은 지금의 벤더 정책을 벤더 문서와 대조하지 않았다고 적었다.

Google 쪽 변동은 셋이다.

- 2026-02-27: third-party 도구나 proxy 로 접근한 계정을 막았다가 풀었다. 두 번째 위반은 영구 차단이라고 적었다([gemini-cli discussion](https://github.com/google-gemini/gemini-cli/discussions/20632), Maintainer 글).
- 2026-06-18: Gemini CLI 가 Google AI Pro 와 Ultra 의 요청을 받지 않게 되는 날이다. 2026-05-19 글이 그렇게 알렸다([Google 블로그](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)). README 는 그 접근이 Antigravity CLI 로 옮겨 갔다고 적는다([gemini-cli](https://github.com/google-gemini/gemini-cli)).
- 2026-11-06: proxy 사용자 한 명의 보고다. OAuth 자격증명 셋 가운데 둘이 약관 위반 오류를 받기 시작했다고 적었다([이슈](https://github.com/router-for-me/CLIProxyAPI/issues/7296), 출처 하나). OAuth 를 직접 쓴 경우라 이 설계와 다르다.

OpenAI 쪽은 읽은 범위에서 날짜가 있는 변경을 찾지 못했다. 문서가 적은 조건은 이렇다.

- 원격이나 headless 환경에서는 device code 인증을 먼저 쓰라고 안내한다(위 auth 문서).
- 자기 계정으로 자동화를 돌리는 길은 조건이 붙은 고급 workflow 다. runner 가 신뢰할 수 있는 사설 인프라여야 한다. `auth.json` 하나는 기계 하나만 쓴다(위 CI/CD auth 문서).
- 다른 앱이 ChatGPT 플랜 사용량을 쓰는 공식 경로가 따로 있다. Sign in with ChatGPT 의 plan usage 다. open-source·로컬 호스팅 앱이 대상이다. 유료이거나 원격에서 호스팅하는 앱은 따로 신청한다([OpenAI 문서](https://developers.openai.com/siwc/llms-full.txt)).

약관 문장이 masc 의 코드에 닿는 곳도 보고서가 적었다. 보고서는 코드를 `9424cc7b5394` 에서 읽었다. 아래는 모두 보고다.

- 로그인은 사람이 `claude` 안에서 끝낸다. 서버는 `CLAUDE_CONFIG_DIR` 경로만 정한다. `lib` 와 `bin` 에 `credentials.json` 을 이름으로 부르는 코드는 없다(`rg` 0건).
- 계정 디렉터리를 선언하면 Claude child 는 `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` 을 물려받지 않는다(`lib/runtime/runtime_claude_environment_projection.ml:44-45`, `lib/runtime/runtime_official_account.ml:129-136`). 그래서 운영자의 API 키가 사람의 구독을 덮지 못한다. Codex 도 같다(`lib/runtime/runtime_codex_environment_projection.ml:41-47`).
- 확인이 필요한 것 하나. Claude child 는 `HOME` 과 `XDG_CONFIG_HOME` 을 물려받는다(`lib/runtime/runtime_claude_environment_projection.ml:5-9`). 문서로는 Anthropic profile 이 계정 디렉터리 밖에 있다. 서버 OS 사용자에게 profile 이 있으면 사람의 턴이 그 profile 의 조직으로 돌 수 있다. 재지 않았다. 이슈 #51053 이다.
- 확인이 필요한 것 둘. 문서는 bare mode 가 구독 로그인을 읽지 않는다고 적는다. 앞으로 `-p` 의 기본이 된다고도 적는다([headless](https://code.claude.com/docs/en/headless)). 그 release 에서 구독 경로가 끊길 수 있다. 이슈 #51055 다.
- 확인이 필요한 것 셋. `Runtime_verification_codex_home.prepare` 가 `auth.json` 을 임시 `CODEX_HOME` 으로 복사한다(`lib/runtime/runtime_verification_codex_home.mli:9-13`). 사본에서 token 이 갱신되고 사본이 버려지면 원본 로그인이 끊길 수 있다.
- 로그인이 만료되면 사람이 다시 로그인해야 한다. 서버가 대신 갱신할 길이 없다.
- Codex 는 사람마다 `CODEX_HOME` 하나를 두고 `auth.json` 을 한 기계에만 둔다. 스케일아웃하면 그 사람의 Codex 턴은 그 파일이 있는 node 에 묶인다.
- 코드는 다계정에서 Antigravity HOME 을 만들지 않는다(`lib/runtime/runtime_antigravity_home.mli:11-13`). 보고서는 Google AI Pro 와 Ultra 로그인을 다계정 Runtime 종류에서 빼자고 적는다.
- 단일 사용자 서버의 Antigravity Runtime 은 운영자의 로그인 사본으로 `agy` 를 띄운다. 운영자 계정이 소비자 플랜이면 FAQ 가 지원하지 않는다고 적은 경우다. 운영자가 확인할 일이다.

판정을 뒤집을 수 있는 근거도 보고서에 있다.

- Anthropic 문서는 제품을 만드는 개발자에게 API 키를 쓰라고 한다. 서버가 사람 대신 턴을 시작하는 상시 agent 는 보통의 사용에서 멀다.
- 보류한 전환을 다시 시행하면 구독 Runtime 의 과금이 바뀐다.
- 2026-04-04 조치의 대상은 third-party harness 다. 공식 CLI 를 띄우는 서버가 거기에 드는지는 1차 문장이 없다.

종합과 보고서가 여기서 읽은 것은 넷이다.

- 종합은 구독 약관이 이 설계의 모양을 요구한다고 적는다. 사람마다 자기 구독으로 로그인하는 모양이다.
- 보고서는 masc 의 모양이 Claude 와 Codex 의 조건과 맞는다고 적는다. 조건은 셋이다. 로그인은 사람이 한다. 실행은 수정하지 않은 공식 CLI 가 한다. 서버는 token 을 만지지 않는다. 이 판단은 보고서의 해석이다. 벤더에 물어야 닫히는 질문 둘이 남아 있다(위).
- §2.1 의 5 는 보안 문제이면서 약관 문제다. 주인이 아닌 사람이 넣은 메시지로 주인의 구독이 돌기 때문이다(종합).
- 2단계의 Runtime 공유는 구독 Runtime 에는 열 수 없다. API key Runtime 에만 열 수 있다(종합, research-landscape-terms).

보고서는 정책 변동을 가장 큰 위험으로 꼽는다. 같은 Keeper 가 구독 Runtime 과 API key Runtime 사이를 옮겨 갈 수 있어야 한다고 적는다.

## 5. 제약 점검

종합이 든 제약 열 가지를 보고서의 수치로 채웠다. 아래 넷은 rev-rules-census 에서 더했다.

범위가 둘이다. 「다계정」은 rev-rules-census 가 센 `.ml` 79개, 15,144줄이다. 「저장소」는 census-lifecycle-scale 이 센 저장소 전체다.

수의 성격도 둘이다. 줄 수와 호출 수는 `rg` 로 센 정적 집계다. 위반 수와 SSOT 묶음 수는 보고서가 코드를 읽어 내린 판정이다. rev-rules-census 는 수치의 신뢰도를 High, 판정의 신뢰도를 Medium-High 로 적는다. MCP 의 틈 10개도 명세와 코드를 읽어 대조한 수다.

| 제약 | 범위 | 지금 | 근거 |
| --- | --- | --- | --- |
| SSOT(Single Source of Truth) | 다계정 | 같은 사실을 두 곳 이상에 적은 묶음이 있다. 종합은 13묶음으로 적었다. rev-rules-census 는 14로 적었다(찾은 20묶음 중 사실 14, 도우미 코드 6). 큰 것은 「막혔는가」에 답하는 함수가 둘인 것이다(§2.1 의 2) | rev-rules-census §2, 5번 |
| 문자열 판정 | 다계정 | 3곳. 사람 홈 경로를 `/` 로 쪼갠 조각 문자열로 비교하는 곳이 든다 | `lib/runtime/runtime_account_home_layout.ml:27-36,53-62` |
| 하드코딩 | 다계정 | 4곳(1·6·16·20번). 턴 timeout 이 120초로 고정이다. 판정 도중 로그 head 가 3번 바뀌면 Keeper 턴을 거절한다. 종합은 재시도 3회가 여섯 모듈에 따로 있는 것을 여기에 넣었다. rev-rules-census 는 그것을 SSOT 로 셌다(17번) | `lib/server/server_preview_keeper_turn.ml:9`, `lib/auth/authz_keeper_turn.ml:12,186-198` |
| Immutable | 다계정 | 구역 snapshot 은 불변 값을 `Atomic` 으로 통째 바꾼다. mutable 필드는 7개다. 위반으로 센 것은 1곳이다. 파일 상태 하나를 mutable 필드 셋에 따로 대입하는 곳이다(24번) | `lib/auth/authz_zone.ml:383-384`, `lib/auth/authz_jsonl_file.ml:133-135` |
| 수명 구조 | 저장소 | Keeper phase 8개와 이벤트 13개가 닫힌 타입이다. 전이표가 모든 쌍을 적는다. 그 위의 catch-all 은 찾지 못했다. 검색은 갈래 뒤 10줄만 봤다(§2.4) | `lib/keeper_registry/keeper_state_machine_types.ml:160-239` |
| 스케일아웃 | 저장소 | 프로세스 하나, 로컬 파일, owner domain 하나다. 쉬는 Keeper 도 0.5초마다 깬다. 쉬는 Keeper 하나가 fiber 3개를 쓴다. 서버에서 잰 값이 아니고 코드에서 센 값이다 | `lib/keeper/keeper_keepalive_signal.ml:218-252`, census-lifecycle-scale §2·§3 |
| 경량 | 저장소 | sandbox 가 Docker, microVM, SSH 뿐이다. 컨테이너도 원격 host 도 없는 설치는 Keeper 를 띄우지 못한다. 종합은 컨테이너 없는 설치라고 적었다 | §4.2 |
| 환경 변수 | 저장소, 다계정 | 저장소 전체로는 이름이 약 284개다. 타입이 있는 registry 에는 24개가 있다. `Sys.getenv` 류 호출 121곳 중 104곳이 설정 모듈 밖이다. 다계정 범위는 키 8개와 암묵 `TMPDIR` 다 | census-lifecycle-scale §5, rev-rules-census §4 |
| 프롬프트 | 저장소 | `config/prompts` 에 45개 파일(196,587 B)이 있다. 모델용 문장이 코드에 박힌 곳은 종합이 5개 파일쯤으로 적었다. census-lifecycle-scale 은 문장 4개 파일과 설명문 2개 파일을 적었다. 다계정 범위에서는 LLM 프롬프트 리터럴을 찾지 못했다(rev-rules-census §6) | census-lifecycle-scale §6 |
| MCP | MCP 구현 | 최신 명세를 대부분 지킨다. 틈은 10개다 | §4.4 |
| 기본값으로 접기 | 다계정 | 3곳. 설정을 못 읽으면 `Not_set` 으로 접는 곳이 든다 | `lib/auth/authz_boot_mode_read.ml:41-43` |
| 전역 가변 상태 | 다계정 | 1곳. 모듈 수준 `Atomic` 이다 | `lib/runtime/runtime_account_access.ml:86-97` |
| 테스트 훅 | 다계정 | `.mli` 에 0개 | rev-rules-census §2 |
| 레거시 흔적 | 다계정 | 1건. Kind 21개 중 8개는 쓰는 곳이 없다. 읽으면 `Kind_not_read` 로 거절한다 | `lib/auth/authz_record.ml:129-145` |

환경 변수를 TOML 로 옮길 길은 이미 있다. TOML key 와 env 이름을 짝짓는 등록부가 있다(`lib/config/keeper_runtime_setting_registry.ml:977-985`). 다만 `masc auth` CLI 는 runtime 파일을 올리지 않는다. 등록만으로는 파일 값을 읽지 못한다(rev-rules-census §4).

## 6. 순서 제안

이 절은 제안이다. 결정이 아니다. 사용자가 이미 정한 것은 둘뿐이다.

- 정해진 것 1: S1 을 나눠 S1a 를 먼저 한다.
- 정해진 것 2: 다계정을 끈 뒤 사람 홈이 남아 있으면 native 도구를 막는다.

나머지는 종합 세션의 안이다.

| 단계 | 사람이 할 수 있게 되는 것 | 같이 할 일 | 정해야 할 것 |
| --- | --- | --- | --- |
| W1 = S1a | 팀원이 실제 서버에 로그인한다. 자기 구독을 연결한다. 자기 Keeper 에게 한 번 묻는다 | §2.1 의 1~4 를 같은 스택에서 닫는다 | 미리보기를 지울지 |
| W2 | 사람 소유 Keeper 가 수명을 가진다. 시작, 정지, 큐, 기억이다 | 없음 | 실행기를 소유자별 프로세스로 나눌지. RFC 와 사용자 결정이 필요하다 |
| W3 | Keeper 가 도구를 쓴다 | sandbox lane 과 dispatch credential 을 붙인다(계획 C4-9, E4) | 없음 |
| W4 | 공유 화면에 사람 신원이 붙는다. Board, Task, Goal 이다. Dashboard(계획 C6)와 사람용 MCP 문도 연다 | MCP 문은 세션 없이 요청마다 token 을 본다(§4.4) | 없음 |
| W5 | 운영자의 기존 Keeper 를 사람에게 귀속한다(계획 F4) | 없음 | 없음 |

§2.1 의 5번은 W1 의 「1~4」에 들어 있지 않다. 종합은 지금 여는 경로에 그런 문이 없다고 적는다. 5번을 어느 단계에서 닫는지는 종합에 없다. 뒤에 온 실행 경계 리뷰는 S1 에서 Keeper 에게 글을 보내는 경로 권한이 유일한 문이라고 적는다(§2.5). 사람이 보낸 글이 클라이언트 입력이 되는 자리(§2.5 의 1번)는 종합보다 뒤에 나왔다. 이슈 #51072 는 그 자리를 S1a-3 전에 닫는다고 적는다.

W1 의 안은 층 넷이다.

- S1a-0: 답이 필요한 레코드 수와 저장소가 답한 수를 대조한다(§2.1 의 3).
- S1a-1(`lib/auth`): 부팅 판정에 7행을 서빙하는 갈래 `Boot_multi_account` 를 둔다. 8행은 `Stop Multi_account_uncertain` 으로 멈춘다. stdio 는 다계정을 거절한다.
- S1a-2(`lib/server`): 계정 서버 모듈을 따로 둔다. 단일 사용자 owner state 를 만들지 않는다. 그래서 fleet, MCP, Board, WS, gRPC, 커넥터가 구조상 뜨지 않는다. 자기 Router 에 로그인 8, 사람 경로 12, live 를 단다.
- S1a-3: 시작 경로 문서를 쓴다. 계획의 S1 행을 S1a 와 S1b 로 나눈다. 안내 문구를 정리한다.

층 넷은 종합과 메모가 적은 그대로다. 뒤에 쓴 이슈 #51072 는 S1a-3 을 다르게 적는다. 계정 서버에서 Keeper 에게 글을 보내는 경로를 여는 층이다. 메모의 S1a-3 과 범위가 다르다. 층을 다시 나눈 기록은 이 문서의 근거에 없다.

S1a-2 의 계정 서버는 세 경우에 부팅을 거절한다.

- login provider 가 하나도 없다.
- login client 를 만들지 못했다.
- `redirect_uri` 의 origin 이 서버의 공개 신원과 다르다. 공개 신원은 명시한 base URL 이다. path 가 callback 경로가 아닐 때도 거절한다.

새 환경 변수는 두지 않는다. secret 은 config 가 이름 붙인 변수에서 읽는다.

정해진 것 2 는 층 F3a-3 이다. 대상은 단일 사용자 프로세스다. 사람 홈 디렉터리가 base path 아래 있으면 native 도구가 있는 모델 턴을 거절한다.

rev-server-doors 의 문 체크리스트 10개가 W1 의 재료다(그 보고서 §3). 그중 셋을 옮긴다.

- 다계정 경로 표에 non-strict 분기를 두지 않는다. 또는 strict 를 부팅 조건에 넣는다.
- Keeper 큐에 메시지를 넣는 진입점이 소유자 세션 하나뿐임을 시험으로 고정한다.
- `/health` 는 다계정에서 live 와 ready 만 낸다.

옮길 때 걸리는 것이 하나 있다. 기존 단일 사용자 서버의 Keeper 들은 다계정을 켜면 멈춘다. 소유 기록이 없고 API provider 가 거절되기 때문이다. 종합은 W5 전까지 두 번째 인스턴스로 시작하는 쪽이 안전하다고 적었다. 그 인스턴스는 base path 를 따로 둔다.

## 7. 불확실한 것과 못 본 것

### 7.1 실행하지 않았다

- 발견은 모두 코드를 읽어서 얻었다. 실행해서 재현한 것이 없다.
- fiber 수와 wakeup 수는 코드에서 셌다. 서버에서 재지 않았다. Keeper 하나의 메모리도 재지 않았다.
- 등록 호출 385곳은 `rg` 정적 집계다. 경로 인벤토리 도구(`tools/auth_route_inventory`)는 빌드가 필요해서 돌리지 않았다. 호출 하나가 경로 여럿을 등록하는 곳은 세지 못했다.
- 진행률(§1)은 종합 세션이 센 값이다. 이 문서를 쓰면서 다시 세지 않았다.

### 7.2 확인이 더 필요한 것

- GitHub 가 token 교환의 `redirect_uri` 를 authorize 때 값과 비교하는지 모른다. 시험용 OAuth App 으로 확인해야 한다. 통하면 rev-login-session 발견 2 가 P0 다.
- Claude Code 가 사람이 보낸 글 안의 표기를 입력 단계에서 처리하는지 재지 않았다. 처리하면 실행 경계 1번이 P0 다(§2.5, #51072).
- Keeper 에게 보이는 도구, sandbox 마운트, 브라우저가 계정 홈에 닿는지는 감사하지 못했다(§2.5).
- `Runtime_account_access` 를 부르지 않는 호스트 credential 통로가 다계정에서 닫히는지 읽지 않았다(§2.5).
- 서버 OS 사용자의 Anthropic profile 이 사람의 턴에 쓰이는지 재지 않았다(§4.8, #51053).
- 약관 질문 둘은 벤더에 물어야 닫힌다(§4.8). 하나는 자기 팀만 쓰는 서버가 문서가 말하는 제품이나 서비스에 드는지다. 다른 하나는 보통의 개인 사용이 상시 실행 agent 를 품는지다.
- GitHub 문서의 권장 문구(§4.3)가 무엇에 붙는지 두 곳이 다르게 적었다. 종합은 token 교환의 `redirect_uri` 에 붙였다. research-identity-authz 의 출처 표는 PKCE S256 에 붙였다. 원문을 다시 열어야 한다.
- 설계 §8.3 이 읽기 경로와 역할 판정까지 막으라는 뜻인지 정해야 한다(§2.1 의 2).
- internal keeper token 이 sandbox 안에 닿는지 추적하지 못했다(rev-server-doors F4).
- 세션 origin 에 사용자 HTML 을 실행하는 경로가 있는지 확인하지 못했다(rev-server-doors F9).
- startup sweep 이 계정 소유 Keeper 의 checkpoint 를 실제로 지우는지 확인하지 못했다(rev-store-boot 6).
- 서버가 떠 있을 때 초대를 내는 서버 경로가 있는지 확인하지 못했다(§2.2).
- 사람의 로그인은 공용 runtime 설정의 `cli_path` 를 읽어 실행한다(`lib/server/server_setup_account_login.ml:104-106`). 이 값을 HTTP 로 바꿀 수 있는지 추적하지 못했다(rev-server-doors DO 6).
- Keeper 큐에 메시지를 넣는 진입점 전수를 세지 않았다(rev-server-doors F3).

### 7.3 보고끼리 다른 값

| 무엇 | 한쪽 | 다른 쪽 | 이 문서 |
| --- | --- | --- | --- |
| 읽은 보고의 수 | 종합은 보고 12개를 읽었다고 적었다 | 종합보다 먼저 저장된 파일은 보고서 11개와 직접 확인 메모 하나다(파일 시각) | 이 문서는 보고서 13개를 읽었다. 뒤에 온 둘을 더한 수다. 종합의 12가 무엇을 센 것인지는 확인 못 함 |
| SSOT 중복 묶음 | 종합 13 | rev-rules-census 14(찾은 20 중 사실 14, 도우미 코드 6) | 둘 다 적었다(§5) |
| 재시도 3회가 여섯 모듈에 따로 있는 것 | 종합은 하드코딩에 넣었다 | rev-rules-census 는 SSOT 로 셌다(17번) | 둘 다 적었다(§5) |
| 모델용 문장이 박힌 파일 | 종합 5개쯤 | census-lifecycle-scale 은 문장 4개 파일, 설명문 2개 파일 | 둘 다 적었다(§5) |
| 미리보기 턴이 모델에 넘기는 글의 줄 | 종합 메모 219·254줄 | head 에서는 221·256줄 | head 값을 썼다 |
| `dashboard_dev_role` 줄 | 종합 메모 20줄 | rev-server-doors 19줄 | head 에서 19줄이다 |
| `assigned` 줄 | 종합 메모 56-76줄 | rev-server-doors 51-71줄 | head 에서 정의가 51줄에서 시작한다 |
| 부팅 판정이 연 handle 을 넘기지 않는 줄 | 종합 메모 `read_log` 108-112줄, `store_state` 82-86줄 | head 에서는 저장소 쪽 81-84줄, 로그 쪽 95-106줄 | head 값을 썼다(§2.2) |
| `make_routes` 줄 | rev-server-doors 8줄 | head 에서는 9줄 | 이 문서는 그 줄을 인용하지 않는다 |
| dev-token 등록 줄 | 종합 메모 451-455 | rev-server-doors 445-466 | 451-455 를 썼다. 범위만 다르다 |
| query token 줄 | 종합 메모 `lib/server/server_auth.ml:110-128` | audit-mcp-spec 110-137 | 110-128 을 썼다. 범위만 다르다 |
| gRPC `ToolCall` 줄 | 종합 메모 1849-1858 | rev-server-doors 1849-1867 | 1849-1858 을 썼다. 범위만 다르다 |
| `Auth_gate` 를 부르는 함수 | rev-server-doors 는 `whoami`, `human`, `member` | rev-rules-census 는 `whoami`, `human`, `person` | head 에서 `Auth_gate.decide` 를 직접 부르는 줄은 300줄(`whoami`)과 322줄(`human`)이다 |
| `Login_client.of_environment` 를 부르는 곳 | 종합 메모는 부르는 곳이 없다고 적었다 | rev-rules-census 는 `test/test_login_flow.ml:288,529` 만 부른다고 적었다 | lib 와 bin 에 없다고 썼다(§2.2). 시험은 부른다 |
| 세션 인증의 빈칸이 오늘 닿는가 | rev-login-session 은 「Not reachable yet」 절에 뒀다. 그 보고는 Disable 을 쓰는 코드가 없다고 적는다 | rev-store-boot 는 오늘 `masc auth preview` 에서 닿는다고 적었다. 서빙 중에 로그가 멈추는 경우다 | 둘 다 적었다(§2.1 의 2) |
| 부팅의 접기 | rev-store-boot 는 설계 237줄이 정한 동작으로 보고 fail-open 부팅이 없다고 적었다 | rev-rules-census 2번은 같은 접기를 규칙 위반으로 셌다 | 사실은 같고 평가가 다르다. 둘 다 적었다(§2.3) |
| lease 로 일감을 쥐는 벤더 | 종합은 벤더 다섯이라고 적었다 | landscape-vendor-platforms 와 research-landscape-terms 는 Claude Code 와 Devin 둘을 적었다 | 보고서 값을 썼다(§4.5) |

### 7.4 근거가 얇은 것

- 출처가 하나뿐인 수치가 있다. DCR 결함 96.6% 는 프리프린트 초록이다. Open WebUI 의 CVE 6건은 CSA 글 하나다. 엔진별 host 기능 도달 수는 arXiv 논문 한 편이다.
- 요약 모델을 거쳐 읽은 페이지의 수치는 원문과 다시 대조하지 않았다. 오픈소스 문서의 기본값(초, 횟수)이 그렇다.
- 벤더 제품의 사용자 평은 절반쯤이 댓글 하나다. 커뮤니티 순위는 조사한 쪽의 판단이다.
- OpenAI 사고 보고서의 날짜는 PDF 메타데이터(2026-08-26 UTC)다.
- research-agent-security 는 머리말에 정정 6건이라고 적었다. 맨 아래 목록은 8항목이다.
- rev-rules-census 의 좌표 하나가 파일 끝을 넘는다. `lib/keeper_runtime/keeper_runtime_config.ml:690-720` 이고 그 파일은 719줄이다.
- 약관 쪽 사건 가운데 2차 출처만 있는 것이 있다. 2026-02-20 의 당시 문구와 2026-04-04 의 조치가 그렇다. 2026-04-21 에 다시 허용됐다는 글과 2026-11-06 의 Google 쪽 보고는 출처가 하나다(§4.8).
- 약관 조사의 판정에는 보고서가 「내 해석」이라고 적은 줄이 섞여 있다. 보고서는 그런 줄의 신뢰도를 Medium 으로 적는다.
- 증거 묶음의 약관 보고서는 영어 인용을 뜻만 풀어 쓴 파생본이다. 원본의 인용은 원문 사본과 글자 단위로 대조돼 있었다. 풀어 쓴 문장은 그 검사를 거치지 않았다. 대신 원본과 줄 단위로 한 번 대조했다(§7.6).

### 7.5 못 본 것

- Reddit 과 X 는 읽지 못했다. 두 곳의 글은 Hacker News 에 올라온 링크와 제목으로만 나온다.
- 실행 경계 리뷰의 하위 감사 하나는 하지 못했다. Keeper 에게 보이는 도구, sandbox 마운트, 브라우저가 계정 홈에 닿는지 보는 감사다. 맡은 서브에이전트가 안전장치에 멈췄고, 리뷰는 안내에 따라 그 일을 직접 하지 않았다(§2.5).
- OpenAI 의 Terms of Use 와 help.openai.com 글은 403 이라 읽지 못했다. 받지 않은 약관은 셋이다. Anthropic Commercial Terms, Google 일반 Terms of Service, Gemini Enterprise 약관이다(research-landscape-terms).
- 공식 클라이언트(Claude Code, Codex, Muse, Antigravity)의 실제 동작은 보지 않았다(rev-exec-boundary).
- Google OIDC 는 미리보기에서 닿지 않는다. 미리보기가 `google = None` 으로 뜨기 때문이다. 읽은 범위에서는 결함을 찾지 못했다(rev-login-session).
- 시험 코드, 브라우저의 실제 동작, GitHub 의 실제 동작은 보지 않았다.
- OpenAI 의 Agents API 발표 글과 help 문서 2건은 403 으로 열지 못했다(landscape-vendor-platforms).
- 보고서마다 「읽지 않은 것」 절이 있다. 그 범위는 판정에 들어 있지 않다.

### 7.6 이 문서를 쓰면서 한 대조

- 먼저 온 코드 보고서 6개의 `.ml`·`.mli` 좌표 752개를 head 의 파일 목록과 줄 수에 대조했다. 결과는 증거 묶음 README 에 있다.
- 뒤에 온 실행 경계 리뷰의 좌표 200개는 `85b8af5b0453` 과 `9424cc7b5394` 양쪽에 대조했다. 줄 범위가 파일 끝을 넘는 좌표는 없다. 두 커밋에 없는 파일은 `lib/server/server_accounts.ml` 하나다. 보고서가 커밋 전 파일이라고 적은 것이다.
- 약관 조사의 코드 좌표 10개도 두 커밋에 대조했다. 어긋난 것이 없다.
- 주요 좌표 98개는 그 줄 범위에 해당 식별자가 있는지 `git show 85b8af5b0453:<path>` 로 봤다. 88개는 범위 안에 있었다. 5개는 줄 번호가 head 와 달랐다(종합 메모 4개, rev-server-doors 1개. §7.3 에 있다). 5개는 이름이 아니라 본문 줄을 가리킨 좌표였고 내용은 맞았다.
- 종합 메모에 줄 번호가 없던 좌표는 이 문서를 쓰면서 head 에서 찾았다. `lib/server/server_h2_gateway.ml:30,49`, `lib/server/server_preview_keeper_turn.ml` 의 8·9·285·288줄, `lib/runtime/runtime_account_access.ml:339,362,381,409`, 계획 155줄과 487줄, 설계 520줄이다.
- §2.3, §4, §5 에 옮긴 리뷰어 좌표 43개도 같은 방법으로 봤다. 41개는 범위 안에 식별자가 있었다. 2개는 이름이 아니라 본문 줄을 가리켰고 내용은 맞았다.
- 이 대조는 그 줄에 이름이 있는지만 본다. 그 코드가 보고서의 설명대로 동작하는지는 보고서를 따랐다.
- 이름 대조가 놓친 좌표가 하나 있었다. 부팅 판정이 handle 을 넘기지 않는 줄이다. 독립 검토가 찾았고 head 에서 다시 읽어 고쳤다(§7.3).
- §2.5 의 줄 범위 19개는 head 에서 열어 문서가 말한 이름이 있는지 봤다. 표에 15개, 본문에 4개다. 모두 있었다. 이 확인에서 7번 행의 글이 좌표와 맞지 않는 것을 찾아 고쳤다.
- §4.8 의 좌표 6개도 두 커밋에서 열어 봤다. 문장이 말한 코드가 그 줄에 있었다.
- 이 문서의 초안을 독립 검토가 근거와 줄 단위로 맞춰 봤다. 어긋난 곳 20건과 의심 13건을 받았다. 항목마다 근거 줄을 다시 열어 본 뒤 고쳤다. 근거가 한쪽으로 정해 주지 않는 의심은 문장에 단서를 붙였다.
- 약관 보고서의 파생본은 풀어 쓴 93줄을 원본과 줄 단위로 대조했다. 독립 검토가 문제 5줄과 의심 6줄을 짚었고, 원본을 다시 읽어 11줄을 고쳤다.
- 이 문서의 `.ml`·`.mli` 좌표 134개를 다시 두 커밋의 파일 목록과 줄 수에 대조했다. 어긋난 것은 둘이다. §7.4 에 적은 하나와, 위에 적은 커밋 전 파일이다.

## 출처

수치를 옮긴 출처와 약관·명세 출처는 한 줄씩 적었다. 날짜가 「없음」인 것은 날짜 표시가 없는 문서 페이지다. 2026-11-10 에 열었다. 맨 아래 세 줄은 묶음이다. 그 링크는 본문 표에 있고, 날짜와 열람 구분은 각 보고서의 출처 표에 있다.

「열람」 열은 보고서가 적은 구분이다. 두 가지를 바꿔 옮겼다.

- research-identity-authz 가 「직접」이라고 적은 것은 「열어 읽음」으로 옮겼다. 그 보고서의 「직접」은 이번에 열어 읽었다는 뜻이다. 이 문서의 `직접` 표기와 다른 말이다.
- research-landscape-terms 의 출처는 「사본」으로 적었다. 원문을 받아 사본으로 저장해 읽었다는 뜻이다. 그 보고서는 벤더가 낸 문서를 1차, 기사·Hacker News·포럼·이슈를 2차로 나눈다.

| 출처 | 날짜 | 열람 | 쓴 곳 | 보고서 |
| --- | --- | --- | --- | --- |
| [Configure cloud environments (Claude Code docs)](https://code.claude.com/docs/en/cloud-environments) | 없음 | 원문 | §4.1 | research-agent-security A8 |
| [Scaling Managed Agents (Anthropic)](https://www.anthropic.com/engineering/managed-agents) | 2026-04-08 | 요약 | §4.1 | 같은 보고서 A4 |
| [How we contain Claude across products (Anthropic)](https://www.anthropic.com/engineering/how-we-contain-claude) | 2026-05-25 | 요약 | §4.1 | A1 |
| [Auto mode default in Claude Code (Anthropic)](https://claude.com/blog/auto-mode-default-in-claude-code) | 2026-08-07, 10-22 갱신 | 요약 | §4.1 | A3 |
| [How we built Claude Code auto mode (Anthropic)](https://www.anthropic.com/engineering/claude-code-auto-mode) | 2026-03-25 | 요약 | §4.1 | A2 |
| [Breaking Claude Code Opus 5 Auto Mode (Embrace The Red)](https://embracethered.com/blog/posts/2026/breaking-claude-code-opus-5-and-automode/) | 2026-08-26 | 요약 | §4.1 | E2 |
| [The Attacker Moves Second (arXiv 2510.09023)](https://arxiv.org/abs/2510.09023) | 2025-10-10 | 요약(초록) | §4.1 | B5 |
| [OpenAI – Hugging Face Incident Technical Report (OpenAI)](https://cdn.openai.com/pdf/67869394-cb91-4c12-888c-5cbd85c7814c/OpenAI-Hugging-Face%20Incident-Technical-Report.pdf) | 2026-08-26(PDF 메타데이터) | 원문(PDF 일부 쪽) | §4.1 | A13 |
| [Brief independent investigation of the OpenAI / Hugging Face hacking incident (METR, Redwood)](https://metr.org/hugging-face-incident-report-aug-2026.pdf) | 2026-08-26 | 원문(PDF 1~14쪽) | §4.1 | B14 |
| [Multi-Agent Systems Execute Arbitrary Malicious Code (arXiv 2503.12188)](https://arxiv.org/abs/2503.12188) | 2025-03-15 | 요약(초록) | §4.1 | B12 |
| [OpenClaw in the wild (Censys)](https://censys.com/blog/openclaw-in-the-wild-mapping-the-public-exposure-of-a-viral-ai-assistant) | 2026-01-31 | 요약 | §4.1 | E9 |
| [ToxicSkills (Snyk)](https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/) | 2026-02-05 | 요약 | §4.1 | E10 |
| [Beyond permission prompts (Anthropic)](https://www.anthropic.com/engineering/claude-code-sandboxing) | 2025-10-20 | 요약 | §4.2 | A5 |
| [Codex docs: sandboxing, agent approvals & security, internet access (OpenAI)](https://learn.chatgpt.com/docs/agent-approvals-security) | 없음 | 요약 | §4.2 | A12 |
| [Implementing a secure sandbox for local agents (Cursor)](https://cursor.com/blog/agent-sandboxing) | 2026-02-18 | 요약 | §4.2 | A23 |
| [E2B](https://e2b.dev/) | 없음 | 요약 | §4.2 | D5 |
| [Docker Sandboxes security](https://docs.docker.com/ai/sandboxes/security/) | 없음 | 요약 | §4.2 | D4 |
| [Use isolated sessions for agents (AWS AgentCore)](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-sessions.html) | 없음 | 원문 | §4.2 | D9 |
| [A sandbox without a network boundary is only half a sandbox (Vercel)](https://vercel.com/blog/a-sandbox-without-a-network-boundary-is-only-half-a-sandbox) | 2026-08-11 | 요약 | §4.2 | D1 |
| [How to force AI agents to use an egress proxy (Simon Edwardsson)](https://simedw.com/2026/06/05/proxy-agents/) | 2026-06-05 | 요약 | §4.2 | D10 |
| [Sandboxing (Claude Code docs)](https://code.claude.com/docs/en/sandboxing) | 없음 | 원문(일부 요약) | §4.2 | A7 |
| [AI Code Sandboxes: A Comparative Security Study (arXiv 2606.08433)](https://arxiv.org/abs/2606.08433) | 2026-06-07 | 요약 | §4.2 | B16 |
| [RFC 9700 (IETF)](https://datatracker.ietf.org/doc/rfc9700/) | 2025-01 | 일부 | §4.3 | research-identity-authz |
| [Multiple redirect URIs and token refresh for OAuth apps (GitHub Changelog)](https://github.blog/changelog/2026-08-14-multiple-redirect-uris-and-token-refresh-for-oauth-apps) | 2026-08-14 | 열어 읽음 | §4.3 | 같은 보고서 |
| [Open WebUI's Recurring Broken Access Control Problem (Cloud Security Alliance)](https://labs.cloudsecurityalliance.org/research/csa-research-note-open-webui-access-control-cves-20260710-cs/) | 2026-07-10 | 열어 읽음 | §4.3 | 같은 보고서 |
| [CVE-2026-55435 (Miggo 취약점 DB)](https://www.miggo.io/vulnerability-database/cve/CVE-2026-55435) | 2026-07-07 | 열어 읽음 | §4.3 | 같은 보고서 |
| [CVE-2026-70482 Open WebUI (GitLab Advisory DB)](https://advisories.gitlab.com/pypi/open-webui/CVE-2026-70482/) | 2026-08-04 | 열어 읽음 | §4.3 | 같은 보고서 |
| [AI Gateway (Coder Docs)](https://coder.com/docs/ai-coder/ai-gateway.md) | 없음 | 열어 읽음 | §4.3 | 같은 보고서 |
| [draft-ietf-wimse-aims-01 (IETF WIMSE WG)](https://datatracker.ietf.org/doc/draft-ietf-wimse-aims/) | 2026-11-02 | 열어 읽음 | §4.3 | 같은 보고서 |
| [Authorizing OAuth apps (GitHub Docs)](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps) | 없음 | 열어 읽음. 종합 세션도 열었다 | §4.3 | 같은 보고서, 종합 |
| [MCP versioning](https://modelcontextprotocol.io/specification/versioning) | 없음 | 원문 | §4.4 | audit-mcp-spec |
| [MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog) | 2026-07-28 | 원문 | §4.4 | audit-mcp-spec, research-identity-authz |
| [MCP Client Registration](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration) | 2026-07-28 | 열어 읽음 | §4.4 | research-identity-authz |
| [MCP Authorization](https://modelcontextprotocol.io/specification/latest/basic/authorization) | 2026-07-28 | 열어 읽음 | §4.4 | research-identity-authz |
| [A First Measurement Study on Authentication Security in Real-World Remote MCP Servers (arXiv 2605.22333)](https://arxiv.org/abs/2605.22333) | 2026-05-21 | 초록만, 프리프린트 | §4.4 | research-identity-authz |
| [Claude Code Legal and compliance (Anthropic)](https://code.claude.com/docs/en/legal-and-compliance) | 없음 | 사본, 1차 | §4.8 | research-landscape-terms An1, landscape-oss-orchestrators 11번, 종합 |
| [Claude Code headless 문서 (Anthropic)](https://code.claude.com/docs/en/headless) | 없음 | 사본, 1차 | §4.8 | research-landscape-terms An3 |
| [Agent SDK 를 Claude 플랜으로 쓰는 도움말 (Anthropic)](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) | 글 안 2026-10-07, 2026-06-15 | 사본, 1차 | §4.8 | An4 |
| [The Register 기사](https://www.theregister.com/software/2026/02/20/anthropic-clarifies-ban-on-third-party-tool-access-to-claude/5014546) | 2026-02-20 | 사본, 2차 | §4.8 | An9 |
| [Hacker News 47633396](https://news.ycombinator.com/item?id=47633396) | 2026-04-03 | 사본, 2차 | §4.8 | An10. landscape-oss-orchestrators 10번은 이 스레드만 읽었다 |
| [Hacker News 47844269](https://news.ycombinator.com/item?id=47844269) | 2026-04-21 | 사본, 2차, 출처 하나 | §4.8 | An12 |
| [OpenClaw docs: Anthropic provider](https://docs.openclaw.ai/providers/anthropic) | 없음 | 사본(research-landscape-terms), 요약(landscape-oss-orchestrators) | §4.6, §4.8 | An12, landscape-oss-orchestrators 9번 |
| [Hacker News 48546618](https://news.ycombinator.com/item?id=48546618) | 2026-06-15 | 사본, 2차 | §4.8 | An13 |
| [Codex 문서의 auth 쪽 (OpenAI)](https://learn.chatgpt.com/docs/auth) | 없음 | 사본, 1차 | §4.8 | Oa1 |
| [Codex 문서의 CI/CD auth 쪽 (OpenAI)](https://learn.chatgpt.com/docs/auth/ci-cd-auth) | 없음 | 사본, 1차 | §4.8 | Oa2 |
| [Codex 문서의 non-interactive mode 쪽 (OpenAI)](https://learn.chatgpt.com/docs/non-interactive-mode) | 없음 | 사본, 1차 | §4.8 | Oa3 |
| [Sign in with ChatGPT 문서 묶음 (OpenAI)](https://developers.openai.com/siwc/llms-full.txt) | 없음 | 사본, 1차 | §4.8 | Oa6 |
| [Antigravity 약관 (Google)](https://antigravity.google/terms) | 없음 | 사본, 1차 | §4.8 | Go1 |
| [Antigravity FAQ (Google)](https://antigravity.google/docs/faq/) | 없음 | 사본, 1차 | §4.8 | Go2 |
| [gemini-cli README (Google)](https://github.com/google-gemini/gemini-cli) | 없음 | 사본, 1차 | §4.8 | Go6 |
| [Gemini CLI 를 Antigravity CLI 로 옮긴다는 글 (Google 개발자 블로그)](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/) | 2026-05-19 | 사본, 1차 | §4.8 | Go7 |
| [gemini-cli discussion 20632 (Maintainer 글)](https://github.com/google-gemini/gemini-cli/discussions/20632) | 2026-02-27 | 사본, 1차 | §4.8 | Go8 |
| [CLIProxyAPI 이슈 7296](https://github.com/router-for-me/CLIProxyAPI/issues/7296) | 2026-11-06 | 사본, 2차, 출처 하나 | §4.8 | Go10 |
| 벤더 문서 페이지(§4.5 표의 링크) | 없음 | 문서 페이지 | §4.5 | landscape-vendor-platforms 표 C |
| 오픈소스 문서와 이슈(§4.6 의 링크) | 링크마다 다름 | 요약 모델을 거침 | §4.6 | landscape-oss-orchestrators 표 D |
| Hacker News 스레드와 GitHub 이슈(§4.7 표의 링크) | 링크 글자가 날짜다 | 공개 API 로 읽음 | §4.7 | community-signal A절(댓글 링크)과 B절 표(스레드) |
