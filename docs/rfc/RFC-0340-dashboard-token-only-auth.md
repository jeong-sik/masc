# RFC-0340: Dashboard dev-token privilege reduction — demote from Admin, close the rebinding vector

- Status: Draft
- Author: Claude (Fable 5, 70-goal campaign — bug #69)
- Date: 2026-07-10
- Revised: 2026-07-10 (v2 — adversarial review wf_3d8a1444 refuted the v1 "delete the endpoint" design; see §7 revision log)
- Related: `auth-bootstrap-grace-token-proof.md` (2026-07-01, same auth neighborhood — proof-of-possession over self-assertion), RFC-0292 (lib/auth de-dup), RFC-0083 (dashboard system actor typed)
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

### 심각도 (배포 조건부 — 정직하게)

| 배포 형태 | 등급 | 근거 |
|---|---|---|
| **단일 사용자 기본**(문서화된 M3 laptop, 단일 `:8935`) | **Low / Info** | 같은 UID 프로세스는 이미 `0o600` 토큰 파일(`auth_credential_base.ml:62`)을 직접 읽는다 — dev-token이 주는 추가 능력 ≈ 0. |
| **멀티 유저 / 공유 호스트 / 공유-netns 컨테이너** | **Medium** | cross-UID 프로세스는 `0o600` 파일을 못 읽지만 HTTP로 Admin 토큰을 얻는다 = 실제 권한 상승. |
| **인터넷 노출 / 터널** | 이미 닫힘 | `http_auth_strict_enabled()`(`server_auth.ml:37-40`)가 non-loopback base URL에서 true → dev-token `404`. Cloudflare 터널(`masc.crying.pictures`)은 public base URL이라 strict. |

**종합 = P2 hardening.** #69 원문의 "시급함"은 노출면(strict가 이미 닫음)에는 해당하지 않는다. 다만 아래 **DNS rebinding 잔여 벡터**가 있어 완전한 low는 아니다.

### 놓쳤던 원격 벡터 (v1 대비 정정 — CORS는 완전 차단이 아님)

dev-token GET은 (a) CORS 헤더를 안 보내고 (b) **request `Host` 헤더를 검증하지 않으며** guard는 서버 *bind* host만 본다(`http_auth_bind_is_loopback`, request Host 아님). 따라서 `127.0.0.1`로 rebinding하는 악성 페이지는 `:8935`에 same-origin이 되어 무인증 GET으로 토큰을 읽어갈 수 있다. v1의 "CORS가 원격 탈취를 막는다"는 안이한 진술이었다. 이건 단일 사용자 laptop에서도 브라우저로 악성 사이트 방문 시 성립하는 실재 벡터다.

## 2. 설계 (v2 — 최소 침습 근본 수정)

### 2.1 mint 역할 강등 (핵심, escalation 차단)

`server_routes_http_dashboard_dev_token.ml:66`의 `~role:Masc_domain.Admin`을 **최소 권한으로 강등**한다. 현재 `agent_role = Worker | Admin` 뿐이며(`types_auth.ml:26`), Worker는 `CanAdmin`/`CanInit`/`CanReset`를 거부한다(`types_auth.ml:196-198`).

- **1차(즉시)**: `~role:Worker`. `~11`개 `CanAdmin` mutation 라우트(operator/action 등, `server_routes_http_routes_dashboard.ml:550,567,583,606,706,905,1083`)가 무인증 dev-token으로 도달 불가가 된다. 자동 부트스트랩 UX는 그대로 보존(삭제 아님).
- **열린 질문 → 구현 시 감사**: Worker가 대시보드의 *정당한* mutation(예: board post, schedule resolve)까지 403하는지 route-by-route 확인. Worker보다 넓지만 Admin보다 좁은 권한이 필요하면 **`agent_role`에 `Dashboard_operator` 변형을 추가**하고 `has_permission` 행을 exhaustive하게 채운다(typed work, 기존에 없는 변형이므로 초안 §에서 참조하지 않았던 것을 명시). 이 감사 없이 강등 폭을 확정하지 않는다.

### 2.2 DNS rebinding 방어 (원격 벡터 차단)

dev-token 라우트(그리고 같은 취약 클래스의 무인증 민감 GET)에 **request `Host` 헤더가 loopback인지** 검증을 추가한다. bind host가 아니라 요청 Host를 봐야 rebinding을 막는다. `server_auth.ml`에 `request_host_is_loopback` 헬퍼를 추가하고 dev-token 핸들러에서 gate.

### 2.3 typed `No_agent` fail-close (permissive default 봉합)

`server_auth.ml:846-869`의 `Option.value ~default:"dashboard"`(미해결 agent → 문자열 "dashboard")는 워크스페이스가 경고하는 `Unknown → Permissive Default` 안티패턴이다. dev-token을 강등해도 이 seam이 남으면 다음 회귀의 입구가 된다. 미해결 agent를 typed `No_agent`로 표현하고 fail-close(권한 요구 경로에서 거부)한다.

### 2.4 부팅 시 접속 URL 출력 (additive, 삭제 아님)

console `?token=` 모델은 **이미 대부분 구현돼 있다**: `auth_login.ml:64-164`가 required auth를 켜고 토큰을 mint·persist하며 `dashboard?agent=&token=` URL을 text/json으로 렌더하고, FE `core.ts`의 `initTokenFromUrl()`이 `?token=`을 소비(`source:'url'`)한 뒤 URL에서 제거한다. 유일한 신규 작업은 **부팅 시(loopback) 이 URL을 콘솔에 1회 출력**하는 것 — 터미널 접근자(= `.masc/` 소유 운영자)만 명시 토큰 경로를 얻는다. 강등된 dev-token과 **공존**한다(무인증 자동 경로 = Worker, 명시 경로 = 발급된 역할).

## 3. 비고찰 대상 (Non-goals)

- strict-auth(non-loopback)는 이미 dev-token을 404 → 변경 없음.
- CSRF Origin 검사(`ensure_same_origin_browser_request`)는 별개 계층 — 유지.
- **엔드포인트 삭제는 하지 않는다**(v1에서 철회). 토큰 재사용 경로(`classify_*`/`read_reusable_*`)를 보존한다.

## 4. 검증

- **강등 증명**: 무인증 dev-token(Worker)으로 `POST /operator/action`(CanAdmin) → `403 Forbidden`(현재 400 통과 → 403). read/허용 mutation은 `Ok`.
- **rebinding 방어**: `Host: evil.example`(비-loopback) 헤더로 dev-token GET → `403/404`.
- **No_agent fail-close**: 미해결 agent로 권한 요구 라우트 → `401/403`(문자열 "dashboard"로 defaulting 안 됨).
- **UX 회귀**: 강등 후에도 대시보드 정상 read + 허용 mutation 동작(FE E2E).
- **마이그레이션**: 기존 Admin-minted `dashboard.token`이 부팅 시 Worker(또는 새 역할)로 재발급(rotation)됨 — 보존된 Admin 토큰이 §의 보안 목표를 위반하지 않음.

## 5. 마이그레이션 / 롤백

- 기존 `.masc/auth/dashboard.token`은 **재발급 필요**(현재 Admin) — 부팅 시 감지해 강등 역할로 re-mint. 삭제 대신 rotation.
- 롤백 = mint 역할을 Admin으로 되돌리는 1줄 revert(보안 회귀이므로 freeze 시 명시).

## 6. 완료 기준

- [ ] 무인증 dev-token의 역할이 `Admin`이 아니다(`rg "~role:Masc_domain.Admin" server_routes_http_dashboard_dev_token.ml` = 0).
- [ ] 무인증 dev-token으로 `CanAdmin` mutation 라우트 100% → `403`.
- [ ] dev-token GET이 비-loopback `Host` 헤더에서 `403/404`(rebinding 차단).
- [ ] 미해결 agent가 문자열 "dashboard"로 defaulting되지 않고 typed fail-close.
- [ ] 기존 Admin-minted `dashboard.token`이 강등 역할로 재발급됨.
- [ ] 대시보드 정상 read + 허용 mutation이 강등 후에도 동작(회귀 0).

## 7. 개정 로그 (v1 → v2)

v1은 "dev-token 엔드포인트 삭제 + Jupyter ?token= 재구축"을 제안했다. 적대 검증(wf_3d8a1444, 3 렌즈 × opus, 397k tok)이 4개 CONFIRMED blocker로 반박:

1. **심각도 과장** — 단일사용자 기본에선 same-UID가 이미 `0o600` 파일을 읽으므로 델타 ≈ 0. P0 아닌 P2.
2. **근본원인 빗나감** — 결함은 엔드포인트 존재가 아니라 `~role:Admin`. 1줄 강등이 삭제 없이 escalation을 닫는다.
3. **삭제가 빌드를 깸** — dangling re-export 2쌍 + E2E 하네스(`test_sse_storm_e2e.ml`) + `release-evidence.sh` + FE 39 call site + 문서 2개.
4. **console 모델은 이미 ~80% 구현** — `auth_login.ml`+`core.ts`. 삭제 정당화 근거 못 됨, additive로 재프레임.

추가 정정: CORS는 원격을 **완전 차단하지 않음**(DNS rebinding 잔여 벡터 — §1). v1은 이를 과소평가했다. v2는 최소 침습(1줄 강등 + rebinding gate + typed fail-close)으로 재설계했다.
