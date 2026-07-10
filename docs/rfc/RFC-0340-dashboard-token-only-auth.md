# RFC-0340: Dashboard dev-token privilege reduction — demote from Admin, close the rebinding vector

- Status: Draft
- Author: Claude (Fable 5, 70-goal campaign — bug #69)
- Date: 2026-07-10
- Revised: 2026-07-11 (v3 — threat-boundary, rotation, and fail-closed ordering correction; see §7 revision log)
- Priority: P1 until request-Host admission and Admin-token rotation land; residual least-privilege work is P2
- Related: issue #24031 (implementation tracker), `auth-bootstrap-grace-token-proof.md` (2026-07-01, same auth neighborhood — proof-of-possession over self-assertion), RFC-0292 (lib/auth de-dup), RFC-0083 (dashboard system actor typed)
- Subsystem: credential / identity / auth (RFC-mandatory per CLAUDE.md agent_delegation + workflow-pr §11)

## 원문 (#69)

> "드더 Auth 기능 살려서 인증 토큰만 접근하게 바꿔야함. 지금 웹에서 명령 아무렇게나 다 내림. 문제임. 보안 문제 시급함"

## 1. 실측된 문제 (라이브 재현, 2026-07-10)

라이브 인스턴스(`localhost:8935`, `enabled:true require_token:true`)에서 전체 사슬을 재현했다:

1. **무인증 Admin 토큰 발급**: `GET /api/v1/dashboard/dev-token`이 서버가 loopback에 바인딩되고 strict-auth env override가 꺼져 있을 때(= 기본 로컬 실행) 아무 인증 없이 **Admin 역할** 토큰을 반환한다.
   - `server_routes_http_dashboard_dev_token.ml:66` `Auth.create_token ~agent_name:"dashboard" ~role:Masc_domain.Admin`.
   - 라우트 `server_routes_http_routes_dashboard.ml:498` `with_public_read` (무인증). `server_auth.ml:929-937` — non-strict 경로는 handler를 auth·origin 검사 없이 직접 호출.
   - 실측: `curl http://127.0.0.1:8935/api/v1/dashboard/dev-token` → `200 {"token":"3737dd42..."}`, 그 토큰으로 `POST /operator/action` → `400`(인증 통과, 검증만 실패).

### 근본원인 (정정)

결함은 엔드포인트의 *존재*가 아니라 발급되는 **역할이 `Admin`이라는 것**이다. 대시보드는 read + 특정 mutation만 필요한데 최상위 권한(`CanAdmin`/`CanInit`/`CanReset`)을 무인증으로 나눠준다. v1 초안은 이를 "엔드포인트를 삭제"로 오진했으나, 적대 검증(§7)이 삭제는 근본원인을 빗나가고 빌드를 깨뜨림을 확인했다.

### 심각도 (공격자 경계별 분리)

| 공격자 / 배포 형태 | 등급 | 근거 |
|---|---|---|
| **같은 UID의 로컬 프로세스** | Low / Info | 이미 `0o600` 토큰 파일을 읽을 수 있다. 이 행은 로컬 프로세스 위협만 설명한다. |
| **기본 loopback 서버 + 공격자 웹 origin을 연 브라우저** | **P1** | 브라우저 sandbox 때문에 원격 페이지는 `0o600` 파일을 읽지 못하지만, DNS rebinding 뒤에는 무인증 HTTP로 Admin bearer를 읽을 수 있다. 같은 UID 비교로 이 원격 웹 경계를 낮출 수 없다. |
| **멀티 유저 / 공유 호스트 / 공유-netns 컨테이너** | **P1** | cross-UID 주체가 파일 권한을 우회해 HTTP로 Admin bearer를 얻는다. |
| **non-loopback strict-auth 배포** | 닫힘(설정 의존) | `http_auth_strict_enabled()`가 true인 현재 계약에서는 dev-token이 404다. loopback 경로의 방어를 대신하지 않는다. |

따라서 **request-Host admission과 기존 Admin credential rotation은 P1**이다. 그 뒤 Worker 권한을 더 줄이는 least-privilege 감사는 P2로 분리한다.

### 놓쳤던 원격 벡터 (v1 대비 정정 — CORS는 완전 차단이 아님)

dev-token GET은 (a) CORS 헤더를 안 보내고 (b) **request `Host` 헤더를 검증하지 않으며** guard는 서버 *bind* host만 본다(`http_auth_bind_is_loopback`, request Host 아님). 따라서 `127.0.0.1`로 rebinding하는 악성 페이지는 `:8935`에 same-origin이 되어 무인증 GET으로 토큰을 읽어갈 수 있다. v1의 "CORS가 원격 탈취를 막는다"는 안이한 진술이었다. 이건 단일 사용자 laptop에서도 브라우저로 악성 사이트 방문 시 성립하는 실재 벡터다.

## 2. 설계 (v3 — fail-closed 순서 고정)

### 2.1 W0: request Host admission을 mint/read보다 먼저 수행

dev-token handler는 토큰 파일을 읽거나 credential을 mint하기 전에 request `Host`를 parse한다. host가 없거나 malformed이거나 exact loopback(`localhost`, `127.0.0.1`, `[::1]`)이 아니면 typed rejection으로 404/403을 반환한다. suffix/substring 판정은 금지하고 기존 network host parser의 closed result를 재사용한다. bind host 검사는 방어의 한 층으로 유지하지만 request Host를 대신하지 않는다.

### 2.2 W1: mint 역할 강등과 route-permission 행렬

`server_routes_http_dashboard_dev_token.ml`의 `~role:Masc_domain.Admin`을 `Worker`로 강등한다. 현재 `agent_role = Worker | Admin`이고 Worker는 `CanAdmin`/`CanInit`/`CanReset`를 거부한다(`lib/types/types_auth.ml:26,194-199`).

강등 전에 dashboard가 호출하는 mutation을 route의 typed permission 기준으로 전수 투영한다. Worker가 허용해야 할 기능은 기존 permission으로 설명하고, 필요한 capability가 없다면 먼저 permission variant를 추가한다. 단지 UI를 통과시키기 위한 broad `Dashboard_operator` 역할이나 path 문자열 allowlist는 만들지 않는다.

### 2.3 W2: 기존 Admin credential을 role-aware하게 교체

현재 `classify_dashboard_dev_token_candidate`는 token owner가 `"dashboard"`인지 확인할 뿐 role을 확인하지 않아 기존 Admin token을 영구 재사용한다. reusable 조건을 **owner + 기대 role + 유효기간**으로 묶는다.

role mismatch는 기존 credential hash와 raw `dashboard.token`을 일관되게 교체하는 explicit rotation 경계를 지난다. credential write와 raw-token write 사이 crash/I/O 실패는 typed `Rotation_indeterminate`로 남기고 endpoint는 500으로 fail-close한다. 예외를 로그한 뒤 `Ok None`으로 바꿔 새 token을 반복 mint하는 현재 read 경로는 제거한다. 완료 후에는 이전 Admin bearer가 반드시 401이어야 한다.

### 2.4 W3: typed `No_agent` fail-close

`server_auth.ml`의 `Option.value ~default:"dashboard"`(미해결 agent → 문자열 "dashboard")를 제거한다. token-bound 권한 경로는 resolved credential identity를 요구하고, 미해결 상태는 closed variant로 거부한다. public read의 실제 unauthenticated 계약은 이 변경과 섞지 않는다.

### 2.5 부팅 URL은 비차단 후속

`lib/auth/auth_login.ml:81-159`와 dashboard URL-token 소비 경로는 이미 있다. 부팅 시 bearer URL을 출력하는 기능은 이 취약점의 수정 조건이 아니며, 로그/프로세스 목록/referrer 노출 검토 없이 W0-W3에 섞지 않는다.

## 3. 비고찰 대상 (Non-goals)

- strict-auth(non-loopback)는 이미 dev-token을 404 → 변경 없음.
- CSRF Origin 검사(`ensure_same_origin_browser_request`)는 별개 계층 — 유지.
- **엔드포인트 삭제는 하지 않는다**(v1에서 철회). 토큰 재사용 경로(`classify_*`/`read_reusable_*`)를 보존한다.
- bearer query URL 자동 출력은 W0-W3의 non-goal이다.

## 4. 검증

- **admission 우선 증명**: invalid/missing/non-loopback Host 요청에서는 token read/mint hook 호출 횟수 0.
- **rebinding 방어**: `Host: evil.example`로 dev-token GET → `403/404`; `localhost`, `127.0.0.1`, `[::1]`의 지원 여부는 parser 계약대로 typed test.
- **강등 증명**: 새 dev-token(Worker)으로 `POST /operator/action`(CanAdmin) → `403 Forbidden`; route-permission 행렬의 허용 mutation만 성공.
- **rotation 증명**: 기존 Admin dashboard token은 reusable이 아니고 rotation 뒤 401, 새 Worker token만 유효.
- **rotation fault 증명**: credential/raw-token write 사이 fault injection이 explicit degraded 결과를 남기며 Admin token을 다시 활성화하지 않음.
- **No_agent fail-close**: 미해결 agent로 권한 요구 라우트 → `401/403`(문자열 "dashboard"로 defaulting 안 됨).
- **UX 회귀**: 강등 후에도 대시보드 정상 read + 허용 mutation 동작(FE E2E).

## 5. 마이그레이션 / 롤백

- 기존 `.masc/auth/dashboard.token`은 owner뿐 아니라 role을 검사해 rotation한다. 파일 overwrite만으로 완료를 주장하지 않고 credential hash 교체와 old-token rejection을 함께 증명한다.
- rotation이 indeterminate이면 기존 값을 재사용하거나 추가 mint하지 않고 endpoint를 degraded로 유지한다. 운영자가 typed 상태를 보고 exact retry할 수 있어야 한다.
- 롤백은 Admin mint 복원이 아니다. 문제가 생기면 dev-token endpoint를 fail-closed로 끄고 명시적 `masc login` token 경로를 사용한다.

## 6. 완료 기준

- [ ] request Host가 token read/mint 전에 exact loopback으로 검증된다.
- [ ] 무인증 dev-token의 역할이 `Admin`이 아니다(`rg "~role:Masc_domain.Admin" server_routes_http_dashboard_dev_token.ml` = 0).
- [ ] 무인증 dev-token으로 `CanAdmin` mutation 라우트 100% → `403`.
- [ ] dashboard route-permission 행렬로 Worker 허용/거부 기능이 전수 검증된다.
- [ ] 기존 Admin dashboard bearer가 rotation 후 401이고 새 Worker bearer만 유효하다.
- [ ] token read/rotation I/O 실패가 `Ok None`/재-mint로 붕괴하지 않는다.
- [ ] 미해결 agent가 문자열 "dashboard"로 defaulting되지 않고 typed fail-close.
- [ ] 대시보드 정상 read + 허용 mutation이 강등 후에도 동작(회귀 0).

## 7. 개정 로그 (v1 → v3)

v1은 "dev-token 엔드포인트 삭제 + Jupyter ?token= 재구축"을 제안했다. 적대 검증(wf_3d8a1444, 3 렌즈 × opus, 397k tok)이 4개 CONFIRMED blocker로 반박:

1. **초기 심각도 분석 오류** — same-UID 로컬 프로세스와 browser sandbox 안의 원격 웹 origin을 같은 공격자로 취급했다. v3는 DNS rebinding 경계를 P1로 분리한다.
2. **근본원인 빗나감** — 결함은 엔드포인트 존재가 아니라 `~role:Admin`. 1줄 강등이 삭제 없이 escalation을 닫는다.
3. **삭제가 빌드를 깸** — dangling re-export 2쌍 + E2E 하네스(`test_sse_storm_e2e.ml`) + `release-evidence.sh` + FE 39 call site + 문서 2개.
4. **console 모델은 이미 ~80% 구현** — `auth_login.ml`+`core.ts`. 삭제 정당화 근거 못 됨, additive로 재프레임.

추가 정정: CORS는 원격을 **완전 차단하지 않음**(DNS rebinding 잔여 벡터 — §1). v3는 Host admission을 모든 token I/O보다 앞에 두고, role-aware rotation과 typed fail-close까지 하나의 보안 완료 조건으로 고정한다.
