---
rfc: "0392"
title: "OAuth 교환이 필요한 서비스에 대한 Keeper 신원"
status: Draft
created: 2026-08-26
updated: 2026-08-26
author: claude
supersedes: []
superseded_by: null
related: ["per-keeper-github-cli-identity"]
implementation_prs: []
---

# RFC: OAuth 교환이 필요한 서비스에 대한 Keeper 신원

Status: Draft

## Problem

Keeper 가 외부 서비스 자격증명을 갖는 길은 이미 둘 있고, 셋째만 없다.

| 서비스 모양 | 필요한 것 | 지금 |
|---|---|---|
| 고정 토큰 (PAT, bot token) | 보관과 주입 | **있음** — `Keeper_secret_projection` |
| CLI 가 계정을 소유 (`gh`) | 설정 디렉터리 격리 | **있음** — `GH_CONFIG_DIR` |
| OAuth + refresh | 획득과 갱신 | **없음** |

`Keeper_secret_projection` 은 이미 `set_env_entry` 와 `set_file_entry` 로 환경변수와
파일을 모두 받고, `local_env_for_keeper` 와 `docker_args_for_keeper` 로 두 실행
경로에 주입하며, `dashboard_status_json` 으로 운영자에게 보이고,
`Keeper_secret_redaction` 이 값을 가린다. **Jira·Slack·Google 이 장기 토큰을
발급한다면 오늘 붙일 수 있다.** 붙이는 곳이 없어서가 아니라, 그 사실이 알려져
있지 않아서 안 붙는다.

없는 것은 **교환과 갱신**이다. masc 가 지금 이끄는 대화형 로그인은 GitHub 하나뿐이고,
그건 `gh` 에게 자기 `GH_CONFIG_DIR` 을 건네는 방식이다 — 교환도 보관도 CLI 가 한다.
`RFC-per-keeper-github-cli-identity` 는 그래서 "No provider/plugin facade in this
change" 를 비목표로 명시했다.

업무 서비스에는 그런 CLI 가 없다. 그러면 둘 중 하나다.

1. 운영자가 장기 토큰을 손으로 붙여넣는다 — 지금도 된다.
2. masc 가 OAuth 교환을 직접 하고 **refresh token 을 든다**.

이 RFC 는 2번만 다룬다.

## 무엇이 실제 비용인가

2번은 masc 에 없던 책임을 만든다. GitHub 설계는 **일부러** masc 가 토큰을 안 만지게
했다 — 값은 `gh` 안에 있고 masc 는 디렉터리만 가리켰다. refresh token 을 들면
masc 가 값의 보관자가 된다.

이 비용을 감수할 값어치는 대상 서비스가 **장기 토큰을 안 주는 경우에만** 생긴다.
Slack bot token, Atlassian API token 처럼 만료 없는 자격증명을 주는 서비스는
1번으로 충분하고, 이 RFC 를 적용하면 안 된다.

## Decision

### 저장은 새로 만들지 않는다

refresh token 은 `.masc/secrets/<keeper>` 의 **파일 항목**으로 둔다.
`Keeper_secret_projection.set_file_entry` 가 이미 그 자리를 소유하고,
`Keeper_secret_redaction` 이 이미 값을 가린다. 앞 RFC 의
"No duplicate secret store" 를 그대로 지킨다.

access token 은 **환경변수 항목**으로 투영한다. 이름은 provider 선언이 정한다.

### provider 는 TOML 이 선언한다

`config/tools/*.toml` 과 같은 자리, 같은 방식이다
(`RFC-prompts-and-tool-definitions-outside-ocaml`).

```toml
name = "atlassian"
authorize_url = "https://auth.atlassian.com/authorize"
token_url = "https://auth.atlassian.com/oauth/token"
scopes = ["read:jira-work", "write:jira-work"]
access_token_env = "ATLASSIAN_ACCESS_TOKEN"
```

**provider 를 하나 더 붙이는 일이 TOML 파일 하나여야 한다.** OCaml 에
provider 별 분기가 생기면 이 RFC 는 목적을 잃는다.

### 갱신은 쓰는 시점에 한다

배경 갱신 워커를 두지 않는다. 자격증명을 해석하는 그 순간, 만료가 가까우면
그 자리에서 교환한다.

앞 RFC 가 "No login lease, claim, settlement, registry, TTL, polling worker, or
confirmation gate" 를 비목표로 적었고, 그 판단이 여기서도 맞다. 배경 워커는
**아무도 안 쓰는 자격증명을 계속 갱신하고**, 실패했을 때 알릴 자리가 없다.
쓰는 시점 갱신은 실패가 곧 그 호출의 실패라 운영자에게 도달한다.

### 실패는 타입으로 가른다

```ocaml
type resolution =
  | Fresh of string                  (* 유효한 access token *)
  | Refreshed of string              (* 교환해서 얻음 *)
  | Refresh_rejected of { detail : string }
  | Never_authorized
```

`Never_authorized` (한 번도 로그인 안 함) 와 `Refresh_rejected` (refresh 가
거부됨 — 취소됐거나 만료됨) 는 운영자에게 **다른 사실**이다. 앞 RFC 의
"Malformed or unsafe identity state is a typed execution error and is not
collapsed into absence" 와 같은 축이다. `option` 으로 뭉개지 않는다.

## Explicit non-goals

- provider 별 OCaml 코드. provider 추가는 TOML 하나다.
- 배경 갱신 워커, 만료 스캐너, 갱신 큐.
- 새 비밀 저장소. `.masc/secrets/<keeper>` 가 그대로 유일한 자리다.
- 호스트 계정으로의 폴백.
- 캐시된 인증 판정. 상태는 물어볼 때 읽는다.
- `gh` 경로 변경. GitHub 은 지금 방식을 그대로 둔다.
- **장기 토큰을 주는 서비스에 이 경로를 쓰는 것.** 그건 오늘 있는 투영으로 한다.
- Keeper lifecycle 진입 게이트. 자격증명 없음은 관측 대상이지 실행 차단이 아니다.

## Failure behavior

자격증명이 없거나 갱신이 거부돼도 Keeper 는 계속 돈다. 그 서비스를 부르는 도구가
타입 있는 오류로 실패하고, 그 오류가 어느 provider 의 무엇인지 말한다.

교환 중 취소(`Eio.Cancel.Cancelled`)는 삼키지 않는다 — 갱신 실패와 종료는
다른 사실이고, 이 저장소가 TLA+ 로 모델링한 `CancelledAbsorbed` 가 정확히 그
혼동이다.

refresh token 은 값으로 절대 노출하지 않는다. 대시보드는 provider 이름과
마지막 갱신 시각, 그리고 위 네 상태 중 하나만 보여준다.

## Open questions

1. **redirect URI 를 어디서 받나.** masc 서버가 이미 HTTP 를 연다
   (`server_routes_http_*`). 거기에 콜백 경로를 하나 더 두는 게 자연스럽지만,
   그러면 서버가 외부에서 도달 가능해야 한다. device flow 를 지원하는
   provider 는 그쪽이 낫다 — provider TOML 이 어느 방식인지 선언해야 할 수 있다.
2. **키퍼별인가 워크스페이스별인가.** GitHub 은 키퍼별이다. Jira 계정을
   키퍼마다 따로 두는 게 실제로 필요한지, 아니면 하나를 공유하는지는
   운영 쪽 판단이 필요하다. 공유라면 `.masc/secrets/` 의 상위 스코프를 쓴다
   (`secret_scope` 가 이미 있다).
3. **client secret 은 누가 갖나.** provider TOML 에 넣으면 저장소에 들어간다.
   `.masc/secrets/` 의 워크스페이스 스코프가 맞아 보이지만, 그러면 TOML 은
   선언만 하고 값은 다른 곳을 가리키게 된다.
