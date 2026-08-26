---
status: runbook
---

# 업무 서비스를 Keeper 에 붙이기

[English](KEEPER-IDENTITY-MANUAL.md)

Keeper 하나에 Jira 나 Notion 같은 서비스를 붙이면, 그 서비스의 도구가 그 Keeper
표면에 올라옵니다. 붙이는 건 브라우저에서 한 번 승인하는 일이고, 승인하고 나면
토큰은 그 Keeper 전용 시크릿으로 들어갑니다. 다른 Keeper 는 못 씁니다.

`config/identity/` 에 선언된 서비스가 54개입니다. 목록은 화면이 보여주니 여기
적지 않습니다.

## 두 가지 경우

| | 서비스 | 준비 |
|---|---|---|
| **바로 됨** | 43개 — Atlassian, Linear, Notion, Sentry, Stripe … | 없음 |
| **앱을 먼저** | Slack, GitHub, Figma, Google 8개 | 각 서비스에서 앱 하나 |

갈리는 이유는 하나입니다. 앞쪽은 masc 가 필요할 때 스스로 클라이언트를 등록할 수
있고, 뒤쪽은 그 창구를 안 열어 둡니다. Google 은 아예 안 하고, Figma 는 열어는
뒀는데 아무나 쓰면 403 을 냅니다.

## 바로 되는 것

**TUI**

```
Keepers → 키퍼 고르고 → 오른쪽 pane 에서 [ 또는 ] 로 Identity 탭
화살표로 서비스 고르고 → enter
```

브라우저가 열립니다. 안 열리면 화면에 주소가 그대로 찍혀 있습니다. 승인하고
돌아오면 탭이 알아서 바뀝니다 — 새로고침 안 눌러도 됩니다.

숫자 `1`~`9` 는 앞쪽 아홉 개로 바로 뛰는 단축키입니다. 열 번째부터는 화살표로만
닿습니다.

**대시보드**

Keeper 화면의 `업무 서비스 연결` 에서 `연결` 을 누릅니다.

## 앱을 먼저 만들어야 하는 것

만들 때 **redirect URI** 를 이 masc 의 콜백 주소로 넣어야 합니다.

```
<이 서버의 base URL>/api/v1/keepers/oauth/callback
```

만든 다음 id 와 secret 을 넣습니다.

- 대시보드: 그 서비스 줄의 `내 앱 쓰기`
- 직접: `POST /api/v1/keepers/oauth/client`
  `{"provider":"slack","client_id":"…","client_secret":"…"}`

이 값은 Keeper 하나가 아니라 **이 masc 전체**가 씁니다. 한 번 넣으면 끝입니다.
응답은 비밀키가 저장됐는지만 알려주고 값은 돌려주지 않습니다.

**Google 은 여덟 개가 앱 하나를 같이 씁니다.** Cloud 프로젝트에서 OAuth 클라이언트를
하나 만들고 어느 한 곳에 넣으면 Gmail·Drive·Docs·Sheets·Slides·Calendar·Chat·
Contacts 가 다 그걸 읽습니다. 클라이언트는 원래 서비스가 아니라 인증 서버에 속하는
것이고, 여덟 개가 같은 `accounts.google.com` 을 쓰기 때문입니다.

**Slack 과 GitHub 은 한 가지가 더 필요합니다.** masc 는 만료 시각과 refresh token 이
없는 응답을 거절합니다. Slack 은 앱의 token rotation 을, GitHub 은 token expiration 을
켜 두세요. 안 켜면 승인까지는 되고 마지막 교환에서 막힙니다.

## 붙고 나면

도구 이름은 `<서비스>_<원래이름>` 입니다. Jira 이슈 조회는 `atlassian_getJiraIssue`
가 됩니다. 서비스가 이름을 겹쳐 써도 섞이지 않습니다.

도구 목록은 붙는 순간 한 번 받아 옵니다. 그 뒤로는 자동으로 안 봅니다 — 서비스가
도구를 늘렸으면 `R` (대시보드는 `도구 새로고침`) 을 누르세요.

토큰은 만료 전에 알아서 갱신합니다. 선언에 적힌 여유 시간만큼 미리 바꿉니다.

읽기 전용이라고 표시하지 않은 도구는 승인 대기로 갑니다. 서비스가 그 표시를 안
달아 두면 전부 대기에 걸리니, 그 Keeper 를 어떤 승인 태세로 둘지 같이 보세요.

## 안 될 때

메시지가 원인을 말합니다.

| 메시지 | 뜻 | 할 일 |
|---|---|---|
| `offers no registration endpoint` | 앱을 직접 만들어야 하는 서비스 | 위 절차 |
| `publishes no S256` | 이 서버는 PKCE 를 안 씀 | 붙일 수 없음 |
| `could not find out where authorization lives` | 서비스가 안내 문서를 안 냄 | 주소가 맞는지 확인 |
| `the provider refused the exchange` | 서비스가 거절함 | 뒤에 붙은 서비스 쪽 이유를 읽기 |
| `returned no refresh token` | 토큰 회전이 꺼진 앱 | 앱 설정에서 켜기 |
| `callback echoed a state this exchange did not send` | 승인 창을 너무 오래 두었거나 서버가 재시작됨 | 다시 누르기 |

## 어디에 저장되나

| 무엇 | 자리 |
|---|---|
| access token / 만료 시각 | 그 Keeper 시크릿의 환경 항목 (선언이 이름을 정함) |
| refresh token | 그 Keeper 시크릿의 파일 항목 |
| 클라이언트 id / secret | `.masc/identity/<client_group>/` — masc 전체 공용 |
| 도구 목록 | `.masc/identity/catalogs/<keeper>/<서비스>.json` |

## 서비스를 하나 더 넣으려면

`config/identity/` 에 TOML 한 장을 놓고 다시 빌드하면 됩니다. OCaml 은 건드리지
않습니다. 파일 이름과 `id` 는 같아야 합니다.

| 항목 | |
|---|---|
| `id` | 경로 한 칸. 파일 이름과 같아야 함 |
| `label` | 화면에 뜨는 이름 |
| `mcp_url` | MCP 종단점. https 만 |
| `access_token_env` / `expires_at_env` | 토큰이 들어갈 환경 항목 이름 |
| `refresh_token_file` | refresh token 이 들어갈 컨테이너 절대 경로 |
| `renew_before_sec` | 만료 몇 초 전에 갱신할지 |
| `client_group` | 앱을 나눠 쓸 이름. 안 적으면 `id` |
| `[authorize_params]` | 그 서비스가 추가로 요구하는 항목 |

여기 적지 않는 것: authorize·token·등록 주소, 권한 목록, 비밀키가 필요한지 여부.
전부 서비스가 스스로 내놓는 문서에서 가져오니 이 파일에서 낡을 수가 없습니다.

## 같이 볼 문서

| 문서 | 용도 |
|---|---|
| [`docs/KEEPER-USER-MANUAL.ko.md`](KEEPER-USER-MANUAL.ko.md) | Keeper 를 만들고 운영하기 |
| [`docs/rfc/RFC-0392-keeper-identity-for-oauth-services.md`](rfc/RFC-0392-keeper-identity-for-oauth-services.md) | 왜 이렇게 설계했는지 |
| [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | 대시보드 쓰기 권한 |
