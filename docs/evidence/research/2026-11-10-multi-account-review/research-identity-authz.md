> 파생본이다. 원본 조사 보고서를 [README](README.md)에 적은 대로 손질했다.

확인 시각 2026-11-10 KST. 신뢰도 기준: RFC·초안 상태 High(datatracker 직접), 벤더 출시 상태 Medium(벤더 문서), 사고·측정 수치 Medium~Low(표의 "확인" 열). 검색어에는 일반 용어만 썼다.

# 신원·인가 웹 조사 결과: 2026-11 기준 앞선 지점 12개, 기준선 10개, 함의 10개, 출처 표

## 1. 2026-11 앞선 지점

방향: 새 프로토콜을 만들기보다 OAuth와 workload identity를 조합한다(WIMSE AIMS, MCP 로드맵, NIST NCCoE 제안).

1. **MCP 서버는 OAuth resource server다.** MCP 2026-07-28이 프로토콜 세션을 없앴고 요청마다 Bearer token을 검증한다. RFC 9728 메타데이터, RFC 8707 `resource`, audience 검증이 MUST다. 받은 token을 upstream에 넘기면 안 된다. (공개 규격)
2. **Client 등록은 CIMD로 간다.** `client_id`가 HTTPS URL이다(draft-ietf-oauth-client-id-metadata-document-03, WG 문서). MCP는 DCR을 Deprecated로 내렸다. OAuth를 붙인 원격 MCP 서버 119대 중 96.6%에서 DCR 결함이 나왔다(프리프린트 한 편).
3. **Mix-up 방어는 RFC 9207 `iss`다.** MCP client는 검증이 MUST, authorization server 발급은 SHOULD(다음 개정에서 MUST 예고). client credential은 issuer별로 묶는다. 공식 Python SDK가 이 검사를 빠뜨려 CVE-2026-115563이 났다.
4. **사람 없는 에이전트는 client credentials로 들어온다.** MCP `oauth-client-credentials` 확장(stable)은 RFC 7523 JWT assertion을 권장하고 client secret을 허용한다. 플랫폼이 준 workload JWT를 쓰는 SEP-1933은 열린 초안, draft-ietf-oauth-spiffe-client-auth-03은 WG 문서다.
5. **조직 IdP가 위임을 관리한다(ID-JAG).** RFC 8693 token exchange + RFC 7523 JWT bearer(draft -06, WG 문서). MCP `enterprise-managed-authorization` 확장은 stable. Okta·Ping·Descope는 발급·수락 출시, Keycloak 26.7은 실험, Auth0·WorkOS는 early access.
6. **에이전트를 workload로 본다.** draft-ietf-wimse-aims-01(WG 문서): 식별자 하나, 짧은 수명 credential, static API key 는 antipattern 이라는 판단, LLM은 credential을 못 본다. 출시: Entra Agent ID(GA 2026-05-01), Google Agent Identity(SPIFFE ID, 24시간 X.509), AWS AgentCore Identity.
7. **"에이전트 본인"과 "사람 대신"은 token 모양이 다르다.** Entra: 자율이면 subject가 agent, 대리면 subject는 user이고 actor가 agent. GitLab composite identity(18.8 GA)는 service account와 사람 둘 다 권한이 있어야 통과시킨다. Google은 감사 로그에 둘을 같이 남긴다.
8. **Token을 키에 묶는다.** DPoP(RFC 9449), mTLS(RFC 8705). Google은 에이전트 credential에 둘을 기본 적용한다. MCP의 DPoP(SEP-1932)는 2026-11-06에도 열린 초안이고 로드맵이 마무리를 목표로 둔다.
9. **도구 호출은 에이전트 밖에서 판정한다.** AWS AgentCore Policy가 Gateway에서 Cedar로 허용·거절한다(GA 2026-03-03). OpenID AuthZEN의 MCP 도구 프로필(COAZ)과 승인 프로필(AARP)은 WG Draft다. OpenFGA는 CNCF incubating, Cedar는 sandbox다.
10. **사람 승인은 비동기 표준으로 받는다.** CIBA + RAR(RFC 9396)는 Auth0가 출시. draft-ietf-oauth-deferred-token-response-01은 WG 문서. MCP는 `input_required`, A2A 1.0은 `TASK_STATE_AUTH_REQUIRED`. AIMS는 로컬 UI 확인만으로는 승인이 아니라고 적는다(MUST NOT).
11. **하위 에이전트에 좁혀 넘기는 표준은 없다.** Biscuit·UCAN 1.0은 구현이 있다. IETF에는 개인 초안(Attenuating Agent Tokens -02, AAuth -11)만 있다. 표준에 가까운 것은 Transaction Tokens -11(WG consensus)과 identity chaining -17(RFC Editor queue)이다.
12. **브라우저 세션.** BFF가 RFC 10017(BCP 212, 2026-08)이 됐다. DBSC는 Chrome 146 Windows에 들어갔고 W3C는 첫 Working Draft다. 취소 신호는 CAEP 1.0(2025-08-29), Google은 RISC로 `sessions-revoked`를 보낸다. WebAuthn Level 3은 Recommendation(2026-08-25)이다.

## 2. 새 시스템이 맞춰야 할 기준선

1. Authorization code + PKCE S256. password grant 금지, implicit 비권장, redirect URI는 exact match. (RFC 9700. OAuth 2.1은 아직 draft-17)
2. IdP가 둘 이상이면 `iss`를 검증하거나 IdP마다 redirect URI를 나눈다. (RFC 9700, RFC 9207)
3. Google 사용자 키는 `sub`다. 도메인 제한은 ID token의 `hd` claim으로 한다(요청 파라미터 `hd`는 UI 힌트). Google이 email을 보증하는 것은 gmail.com이거나 `email_verified`와 `hd`가 같이 있을 때뿐이다. (Google 문서)
4. GitHub는 GitHub App을 권장하고 PKCE는 S256만 받는다. OAuth app도 2026-08-14부터 8시간 access token과 6개월 refresh token을 쓴다(새 앱 기본). 사용자 이름은 남이 다시 가져갈 수 있어 키로 쓰지 않는다.
5. 세션 쿠키는 `__Host-`, Secure, HttpOnly, SameSite. 로그인·권한 변경 때 ID를 새로 만들고 idle·absolute timeout과 로그아웃 무효화는 서버에서 한다. token을 web storage에 두지 않는다. (OWASP, RFC 10017)
6. CSRF는 synchronizer token이나 signed double-submit으로 막는다. Fetch Metadata는 Origin 검증을 fallback으로 둘 때만 단독으로 쓴다. SameSite는 보조다. (OWASP)
7. Resource server는 자기 앞으로 발급된 token만 받는다. Open WebUI는 userinfo 응답만 보고 audience를 안 봐서 계정을 내줬다(CVE-2026-70482).
8. Public client의 refresh token은 rotation하거나 키에 묶고 access token은 짧게 둔다. (RFC 9700, MCP)
9. 권한 검사는 한 곳에서 한다. Open WebUI는 기능마다 따로 검사해 8개월에 CVE 6건이 났다(CSA). Coder는 정지된 사용자의 API key가 계속 통했다(CVE-2026-55435).
10. PAT는 만료, 자원 범위, 권한 범위를 갖고 주인 권한을 넘지 못한다(GitHub fine-grained PAT, Coder scope). 민감한 동작 전에는 재인증한다(GitHub sudo mode, passkey 허용).

## 3. self-hosted 다중 사용자 에이전트 서버에 주는 함의

1. 사람 키는 Google (`iss`,`sub`), GitHub 숫자 `id`. email로 계정을 합치지 않는다. 입장 자격(`hd`, org 소속)은 로그인마다 서버에서 다시 본다.
2. 에이전트는 주인이 있는 별도 principal이다. 호출마다 actor(agent)와 owner(person)를 같이 싣는다. 유효 권한은 "주인의 지금 권한 ∩ 에이전트가 받은 grant"이고 호출 시점에 계산한다. 권한 로그가 authority이면 이 값을 따로 저장하지 않는다.
3. Provider 로그인은 에이전트와 모델에게 주지 않는다. 서버가 주인 이름으로 호출하고 사용량을 그 사람에게 붙인다(Coder AI Gateway, AIMS). HN 검색에서도 호응은 credential proxy(110~156점)에 몰렸고 신원·위임 프로토콜 제안은 24점 이하였다(거친 신호).
4. PAT는 해시로 저장하고 만료 상한을 둔다. scope는 `resource:action`과 자원 allow-list, 이 서버 audience 전용, 관리자 권한 제외. 발급 전에 passkey로 재인증한다.
5. 에이전트 credential은 공유 secret보다 `private_key_jwt`나 workload JWT로 받고 access token은 분 단위로 둔다. DPoP는 MCP 규격이 닫히면 켤 수 있게 token에 `cnf` 자리를 둔다.
6. MCP 문은 RFC 9728 메타데이터, audience 고정, `iss` 발급을 갖춘다. CIMD를 받으면 SSRF 방어와 도메인 정책을 같이 둔다. DCR은 새로 만들지 않는다.
7. 사람 정지나 grant 회수 한 번으로 세션, PAT, refresh token, 그 사람 에이전트의 token이 모두 죽어야 한다. 열린 stream(`subscriptions/listen`)과 진행 중인 도구 호출도 끊는다(규격에 문장이 없어 내 추론). Google RISC 이벤트도 같은 길로 넣는다.
8. 도구 호출 판정은 모델 밖 한 곳에서 하고 기본은 거절이다. 위험한 호출은 인자까지 고정한 요청을 사람이 승인하고 한 번만 실행한다. 요청한 사람이 자기 에이전트의 결과를 승인하지 못하게 한다(GitHub Copilot agent).
9. 비상 관리자는 Google·GitHub와 무관한 계정 2개 이상, FIDO2, 90일마다 점검(Entra 지침). 호스트 CLI 복구도 둔다. 복구는 로그를 고치지 않고 새 항목과 알림으로 남긴다.
10. 감사 항목: 사람, 에이전트, `client_id`, token id, grant 사슬, 도구와 인자 digest, 판정과 정책 버전, 승인 참조, 결과 digest. Hash chain이 같은 호스트에만 있으면 통째로 다시 쓴 것을 못 잡는다(내 추론). 서명한 checkpoint(origin, tree size, root hash)를 밖으로 내보낸다(C2SP, CloudTrail).

## 4. 출처 표

"확인" 열: 직접 = 이번에 열어 읽음, 일부 = 긴 문서의 앞부분만, 2차 = 2차 기사만 읽음, 요약만 = 검색 요약만 봄(not read first-hand).

| 제목 | 발행처 | 날짜 | URL | 한 줄 | 확인 |
|---|---|---|---|---|---|
| RFC 9700 Best Current Practice for OAuth 2.0 Security (BCP 240) | IETF | 2025-01 | https://datatracker.ietf.org/doc/rfc9700/ | PKCE, exact redirect, password grant 금지, refresh rotation, mix-up 방어 | 일부 |
| draft-ietf-oauth-v2-1-17 | IETF OAuth WG | 2026-10-30 | https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/ | 아직 WG 문서 | 일부 |
| RFC 10017 OAuth 2.0 for Browser-Based Applications (BCP 212) | IETF | 2026-08 | https://datatracker.ietf.org/doc/draft-ietf-oauth-browser-based-apps/ | BFF를 가장 안전한 구조로 권고 | 일부 |
| OAuth WG 문서 목록 | IETF | 2026-11-10 열람 | https://datatracker.ietf.org/wg/oauth/documents/ | RFC 9207(2022-03), 8693·8705·8707(2020), 9396(2023-05), 9449·9470(2023-09), 9728(2025-04), 10027(2026-08), 10070(2026-11) 발행일. identity-chaining-17은 RFC Ed Queue, spiffe-client-auth-03은 WG 문서 | 직접(목록만, 각 본문은 안 읽음) |
| MCP Authorization (rev 2026-07-28) | MCP 프로젝트 | 2026-07-28 | https://modelcontextprotocol.io/specification/latest/basic/authorization | resource server 모델, RFC 9728·8707·9207 요구 | 직접 |
| MCP Key Changes | MCP 프로젝트 | 2026-07-28 | https://modelcontextprotocol.io/specification/2026-07-28/changelog | 세션 삭제, DCR Deprecated, SEP-2468·2352 | 직접 |
| MCP Client Registration | MCP 프로젝트 | 2026-07-28 | https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration | 사전 등록 → CIMD → DCR 순서 | 직접 |
| MCP Authorization Security Considerations | MCP 프로젝트 | 2026-07-28 | https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations | audience 검증, refresh rotation, token passthrough 금지 | 직접 |
| MCP Security Best Practices | MCP 프로젝트 | 2026-07-28 | https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices | per-client consent, SSRF, state handle은 인증이 아님 | 직접 |
| Enterprise-Managed Authorization 확장 | MCP 프로젝트 | rev 2026-07-28 | https://modelcontextprotocol.io/extensions/auth/enterprise-managed-authorization.md | ID-JAG 흐름과 벤더별 출시 상태 표 | 직접 |
| OAuth Client Credentials 확장 | MCP 프로젝트 | rev 2026-07-28 | https://modelcontextprotocol.io/extensions/auth/oauth-client-credentials.md | JWT assertion 권장, issuer 고정 | 직접 |
| MCP Roadmap | MCP 프로젝트 | 2026-08-22 | https://modelcontextprotocol.io/development/roadmap.md | Agent Identity WG 결성 중, DPoP 마무리, WIF·ID-JAG·RFC 8693 | 직접 |
| SEP-1932 DPoP Profile for MCP | MCP GitHub | 2025-12-05 열림, 2026-11-06 최근 댓글 | https://github.com/modelcontextprotocol/modelcontextprotocol/pull/1932 | 열린 초안 | 직접 |
| SEP-1933 Workload Identity Federation | MCP GitHub | 2025-12-05 열림, 2026-11-02 최근 활동 | https://github.com/modelcontextprotocol/modelcontextprotocol/pull/1933 | 열린 초안, RFC 7523 JWT bearer 사용 | 직접 |
| draft-ietf-oauth-identity-assertion-authz-grant-06 | IETF OAuth WG | 2026-10-30 | https://datatracker.ietf.org/doc/draft-ietf-oauth-identity-assertion-authz-grant/ | ID-JAG = RFC 8693 + RFC 7523 | 일부 |
| draft-ietf-oauth-client-id-metadata-document-03 | IETF OAuth WG | 2026-11-02 | https://datatracker.ietf.org/doc/draft-ietf-oauth-client-id-metadata-document/ | URL을 `client_id`로 | 직접 |
| draft-ietf-oauth-transaction-tokens-11 | IETF OAuth WG | 2026-07-30 | https://datatracker.ietf.org/doc/draft-ietf-oauth-transaction-tokens/ | WG Consensus: Waiting for Write-Up | 직접 |
| draft-ietf-oauth-deferred-token-response-01 | IETF OAuth WG | 2026-11-01 | https://datatracker.ietf.org/doc/draft-ietf-oauth-deferred-token-response/ | token endpoint가 승인 대기를 돌려줌 | 일부 |
| draft-ietf-wimse-aims-01 AI Identity Management System | IETF WIMSE WG | 2026-11-02 | https://datatracker.ietf.org/doc/draft-ietf-wimse-aims/ | 에이전트 = workload, static API key는 antipattern | 직접 |
| WIMSE WG 문서 목록 | IETF | 2026-11-10 열람 | https://datatracker.ietf.org/wg/wimse/documents/ | http-signature-08 IESG 제출, 에이전트 위임 개인 초안 10여 개 | 직접(목록만) |
| draft-niyikiza-oauth-attenuating-agent-tokens-02 | 개인 초안 | 2026-10-26 | https://datatracker.ietf.org/doc/draft-niyikiza-oauth-attenuating-agent-tokens/ | offline으로 좁히기 + PoP. WG 채택 아님 | 일부 |
| draft-hardt-oauth-aauth-protocol-11 | 개인 초안 | 2026-09-25 | https://datatracker.ietf.org/doc/draft-hardt-oauth-aauth-protocol/ | HTTP Message Signatures로 에이전트 신원 | 일부 |
| OpenID Connect (Google Identity) | Google | 표시 없음 | https://developers.google.com/identity/openid-connect/openid-connect | `sub` 사용, `hd` claim 검증 | 직접 |
| Verify the Google ID token | Google | 표시 없음 | https://developers.google.com/identity/gsi/web/guides/verify-google-id-token | Google이 email을 보증하는 조건 | 직접 |
| Cross-Account Protection (RISC) | Google | 표시 없음 | https://developers.google.com/identity/protocols/risc | sessions-revoked, account-disabled 이벤트 | 직접 |
| Authorizing OAuth apps | GitHub Docs | 표시 없음 | https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps | PKCE S256 을 강하게 권장 | 직접 |
| Multiple redirect URIs and token refresh for OAuth apps | GitHub Changelog | 2026-08-14 | https://github.blog/changelog/2026-08-14-multiple-redirect-uris-and-token-refresh-for-oauth-apps | 8시간/6개월, 새 앱 기본 | 직접 |
| Differences between GitHub Apps and OAuth apps | GitHub Docs | 표시 없음 | https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps | GitHub App 을 권장한다고 적음 | 직접 |
| Managing your personal access tokens | GitHub Docs | 표시 없음 | https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens | fine-grained PAT 속성, 1년 미사용 자동 삭제 | 직접 |
| About authentication to GitHub | GitHub Docs | 표시 없음 | https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/about-authentication-to-github | token 접두어 6종 | 직접 |
| Sudo mode | GitHub Docs | 표시 없음 | https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/sudo-mode | PAT 생성 등에서 재인증, 2시간 | 직접 |
| Username changes | GitHub Docs | 표시 없음 | https://docs.github.com/en/account-and-profile/concepts/username-changes | 옛 이름을 남이 가져갈 수 있음 | 요약만 |
| Session Management Cheat Sheet | OWASP | 표시 없음 | https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html | 쿠키 속성, 재발급, 서버 쪽 timeout | 직접 |
| CSRF Prevention Cheat Sheet | OWASP | 표시 없음 | https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html | Fetch Metadata는 Origin 검증 fallback 필수 | 직접 |
| Device Bound Session Credentials | W3C WebAppSec WG | 2025-08-21 | https://www.w3.org/TR/dbsc/ | First Public Working Draft | 직접 |
| DBSC 개발자 문서 | Chrome for Developers | 표시 없음 | https://developer.chrome.com/docs/web-platform/device-bound-session-credentials | 등록·갱신 endpoint, 짧은 쿠키 | 직접 |
| DBSC GA in Chrome for Windows | Google Workspace Updates | 2026-05-28 | https://workspaceupdates.googleblog.com/2026/05/prevent-account-takeovers-with-DBSC-now-generally-available-in-the-Chrome-browser-for-Windows.html | Workspace 기본 켜짐 | 직접 |
| Chrome ships device-bound session credentials | Help Net Security | 2026-04-10 | https://helpnetsecurity.com/2026/04/10/google-chrome-device-bound-session-credentials | Chrome 146 Windows, macOS 예정 | 2차 |
| Web Authentication Level 3 | W3C | 2026-08-25 | https://www.w3.org/TR/webauthn-3/ | Recommendation | 일부 |
| OpenID CAEP 1.0 | OpenID Foundation | 2025-08-29 | https://openid.net/specs/openid-caep-1_0-final.html | session-revoked 등 이벤트 8종 | 직접 |
| What's new in Microsoft Entra Agent ID | Microsoft Learn | 2026-05-01 | https://learn.microsoft.com/en-us/entra/agent-id/whats-new-agent-id | GA, OBO·자율 정책 템플릿 | 직접 |
| Overview of agent identities | Microsoft Learn | 2026-03-30 | https://learn.microsoft.com/en-us/entra/agent-id/agent-identities | blueprint가 credential 보유, subject/actor 구분, sponsor | 직접 |
| Manage emergency access admin accounts | Microsoft Learn | 2026-06-04 | https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/security-emergency-access | 2개 이상, FIDO2, 90일마다 점검, 사용 때마다 알림 | 직접 |
| Overview of AgentCore Identity | AWS Docs | 표시 없음 | https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/identity-overview.html | 에이전트 = workload identity | 직접(개요만) |
| Policy in AgentCore GA | AWS | 2026-03-03 | https://aws.amazon.com/about-aws/whats-new/2026/03/policy-amazon-bedrock-agentcore-generally-available | Gateway에서 Cedar로 도구 호출 판정 | 직접 |
| Agent identity overview | Google Cloud | 표시 없음 | https://docs.cloud.google.com/iam/docs/agent-identity-overview | SPIFFE ID, 24시간 X.509, mTLS + DPoP | 직접 |
| Cross App Access partners | Okta | 2026-06-23 | https://www.okta.com/newsroom/press-releases/okta-announces-cross-app-access-partners/ | 참여사 목록. GA 문장은 없음 | 직접 |
| Asynchronous Authorization | Auth0 Docs | 표시 없음 | https://auth0.com/ai/docs/intro/asynchronous-authorization | CIBA + RAR, push 승인 | 직접 |
| AuthZEN WG drafts | OpenID Foundation | 2026-06-15 | https://openid.net/openid-foundation-advances-authorization-for-the-agent-era-with-new-authzen-working-group-drafts/ | COAZ(MCP 도구), AARP(승인) | 직접 |
| A2A Specification 1.0.0 | A2A 프로젝트 | 표시 없음 | https://a2a-protocol.org/latest/specification/ | securitySchemes, auth-required, 서명한 Agent Card | 일부 |
| Composite identity | GitLab Docs | 18.8 GA | https://docs.gitlab.com/user/duo_agent_platform/composite_identity/ | 사람과 service account 중 좁은 쪽 | 직접 |
| Risks and mitigations for Copilot cloud agent | GitHub Docs | 표시 없음 | https://docs.github.com/en/copilot/concepts/agents/cloud-agent/risks-and-mitigations | 요청자는 승인 불가, `copilot/` 브랜치만 | 직접 |
| API & session tokens | Coder Docs | 표시 없음 | https://coder.com/docs/admin/users/sessions-tokens | scope, allow-list, 자식 token은 부모보다 오래 못 감 | 직접 |
| AI Gateway | Coder Docs | 표시 없음 | https://coder.com/docs/ai-coder/ai-gateway.md | provider 호출을 서버가 대신하고 사용자에게 귀속 | 직접 |
| CVE-2026-55435 | Miggo 취약점 DB | 2026-07-07 | https://www.miggo.io/vulnerability-database/cve/CVE-2026-55435 | 정지된 사용자의 API key가 유효 | 직접(취약점 DB) |
| MCP server portals | Cloudflare Docs | 표시 없음 | https://developers.cloudflare.com/cloudflare-one/access-controls/ai-controls/mcp-portals/ | 도구별 노출, direct URL은 portal 정책을 우회 | 직접 |
| CVE-2026-70482 Open WebUI | GitLab Advisory DB | 2026-08-04 | https://advisories.gitlab.com/pypi/open-webui/CVE-2026-70482/ | audience·client 미검증으로 계정 탈취 | 직접 |
| Open WebUI's Recurring Broken Access Control Problem | Cloud Security Alliance | 2026-07-10 | https://labs.cloudsecurityalliance.org/research/csa-research-note-open-webui-access-control-cves-20260710-cs/ | CVE 6건, 기능마다 따로 검사 | 직접 |
| GHSA-qx49-fqc8-xw99 (CVE-2026-115563) | MCP python-sdk | 2026-09-28 | https://github.com/modelcontextprotocol/python-sdk/security/advisories/GHSA-qx49-fqc8-xw99 | issuer 미검증으로 credential 유출 | 직접 |
| A First Measurement Study on Authentication Security in Real-World Remote MCP Servers | arXiv 2605.22333 | 2026-05-21 | https://arxiv.org/abs/2605.22333 | 7,973대 중 40.55% 무인증, 119대 중 96.6% DCR 결함 | 직접(초록만, 프리프린트) |
| Vercel–Context.ai incident | The Register | 2026-04-20 | https://www.theregister.com/2026/04/20/vercel_context_ai_security_incident/ | AI 도구가 쌓아 둔 OAuth token이 털려 Workspace 계정 탈취 | 2차(Vercel 공지는 안 읽음) |
| New whitepaper tackles AI agent identity challenges | OpenID Foundation | 2025-10-07 | https://openid.net/new-whitepaper-tackles-ai-agent-identity-challenges/ | 단일 조직은 기존 표준으로 충분, 재귀 위임은 공백 | 직접(공지만, PDF는 안 읽음) |
| New Concept Paper on Identity and Authority of Software Agents | NIST NCCoE | 2026-02-05 | https://www.nist.gov/news-events/news/2026/02/new-concept-paper-identity-and-authority-software-agents | 기존 표준을 에이전트에 적용하는 실증 제안 | 직접(보도문만) |
| OpenFGA becomes a CNCF incubating project | CNCF | 2025-11-11 | https://www.cncf.io/blog/2025/11/11/openfga-becomes-a-cncf-incubating-project/ | Zanzibar 계열, incubating | 직접 |
| Cedar joins CNCF as a sandbox project | AWS Open Source Blog | 2025-12-15 | https://aws.amazon.com/blogs/opensource/cedar-joins-cncf-as-a-sandbox-project | sandbox, AgentCore Policy가 사용 | 직접 |
| Validating CloudTrail log file integrity | AWS Docs | 표시 없음 | https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html | 시간마다 서명한 digest, 앞 digest의 서명을 포함 | 직접 |
| tlog-checkpoint | C2SP | editor's copy | https://github.com/C2SP/C2SP/blob/main/tlog-checkpoint.md | origin, tree size, root hash 세 줄 + 서명·cosignature | 직접 |
| Rekor v2 GA | Sigstore | 2025-10-10 | https://blog.sigstore.dev/rekor-v2-ga/ | tile 기반 로그, witnessing은 예정 | 직접 |
| Biscuit introduction | Eclipse Biscuit | 표시 없음 | https://doc.biscuitsec.org/getting-started/introduction.html | 공개키 서명, offline으로 좁히기만 가능 | 직접 |
| UCAN spec 1.0.0 | UCAN WG | 표시 없음 | https://github.com/ucan-wg/spec | 위임마다 같거나 좁게, 호출에 replay 방지 | 직접 |
| Show HN: Agent Vault (156점) | Hacker News | 2026-04-22 | https://hn.algolia.com/api/v1/items/47865822 | credential을 에이전트 밖 proxy에 둠 | 직접 |
| Launch HN: Alter (69점) | Hacker News | 2026-10-21 | https://hn.algolia.com/api/v1/items/50176908 | 공유 key, 위임 사슬, 고정한 요청 승인 논의 | 직접 |
| HN 댓글 검색 "MCP OAuth" | Hacker News | 2026-06~09 | https://hn.algolia.com/api/v1/search?query=MCP%20OAuth&tags=comment | Entra ID 가 DCR 을 지원하지 않는다는 불만, 누가 호출했는지 답해야 한다는 요구 | 일부 |
| OWASP Top 10 for Agentic Applications 2026 | OWASP GenAI | 2025-12-09 | https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/ | 목록은 PDF에 있어 항목 문구를 못 읽음. 본문에 안 씀 | 직접(안내 페이지만) |

### 근거가 약한 주장

- 출처 한 곳: 96.6%(프리프린트), Open WebUI CVE 6건(CSA), WebAuthn L3 날짜(w3.org), Entra GA 날짜(문서 front matter), Chrome 146(2차 기사).
- 검색 요약만(본문에 쓴 것): GitHub 사용자 이름 재사용, Coder `create-admin-user`(함의 9의 "호스트 CLI").
- 검색 요약만(본문에 안 쓴 것): Auth0 for AI Agents GA 2025-11-19, SSF·CAEP 승인 발표 2025-09, LibreChat MCP OAuth CVE 묶음, n8n CVE-2026-21858, Coder CVE-2026-55075, Open WebUI CVE-2026-88005·88006.
- 문서로 확인 못 함: "GitHub 숫자 `id`를 키로"는 관행이다. GitHub 문서에서 그 문장을 찾지 못했다.
- 어긋나는 정보: 한 벤더 글은 TypeScript SDK 2.1.0이 DPoP를 넣었다고 하고, SEP-1932 PR은 아직 열려 있다. PR 쪽을 따랐다.
- 못 본 것: X는 읽지 못했다. Reddit은 미러 요약만 봤다. MCP client matrix는 칸이 비어 보여 client별 확장 지원을 확인하지 못했다. Zanzibar·macaroons 논문, OPA, SpiceDB, OpenHands·Dify·n8n의 로그인·역할 설계는 이번에 열지 않았다.
