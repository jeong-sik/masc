---
rfc: "0392"
title: "Keeper 신원을 provider 로 매개변수화 — provider 추가가 OCaml 을 늘리지 않는다"
status: Draft
created: 2026-08-26
updated: 2026-08-26
author: claude
supersedes: []
superseded_by: null
related: ["per-keeper-github-cli-identity"]
implementation_prs: []
---

# RFC: Keeper 신원을 provider 로 매개변수화

Status: Draft

## Problem

Keeper 별 외부 신원은 **이미 동작한다.** TUI 의 Keeper 상세에 `Info / Instructions /
GitHub` 탭이 있고, GitHub 탭에서 `L` 을 누르면 그 키퍼 하나의 device-flow 로그인이
돌고, 결과가 그 키퍼만의 `GH_CONFIG_DIR` 에 남는다. UX 도 경계도 맞다.

문제는 **"github" 라는 이름이 전 계층에 박혀 있다**는 것이다.

| 파일 | `github` 언급 |
|---|---|
| `bin/masc_tui.ml` | 50 |
| `lib/keeper/keeper_github_identity.ml` | 45 |
| `lib/server/server_dashboard_http_keeper_api_post.ml` | 14 |
| `bin/masc_tui_types.ml` | 7 |
| `bin/masc_tui_http.ml` | 7 |
| `bin/masc_tui_render.ml` | 4 |
| `bin/masc_tui_keys.ml` | 2 |

```ocaml
let keeper_detail_tabs = [ Detail_info; Detail_instructions; Detail_github ]
| Detail_github -> "GitHub"
| Detail_github -> "[ ]:tab  L:login"
| Github_identity_view_loaded of ... | Github_login_lines of ... | Github_login_finished of ...
launch_github_login state ~mailbox keeper_name
POST /api/v1/keepers/:name/github-login
```

Jira 를 붙이려면 129곳을 훑어 같은 모양을 한 벌 더 만들어야 한다. 기능이 없어서가
아니라 **이름이 상수라서** 안 붙는다.

곁들여, GitHub App 은 절반만 있다. `gh` device flow 는 사람 계정이고, App 설치
토큰은 키퍼마다 다른 신원을 줄 수 있는데 TUI 가 그 흐름을 모른다. 반대로 커밋
`6638226397` 에 그 흐름을 다 하는 144줄짜리 스크립트가 있는데 **병합되지 않았고
UI 가 없다.** 두 조각이 서로를 모른다.

## Decision

### 탭이 provider 를 받는다

```ocaml
| Detail_identity of provider_id     (* Detail_github 를 대체 *)
```

`keeper_detail_tabs` 는 상수 목록이 아니라 선언된 provider 에서 만들어진다. 라벨,
footer 힌트, 로딩 메시지, HTTP 경로가 전부 `provider_id` 를 지난다.

### provider 는 TOML 이 선언한다

`config/identity/*.toml`. `config/tools/` 와 같은 자리, 같은 방식
(`RFC-prompts-and-tool-definitions-outside-ocaml`).

```toml
id = "github-app"
label = "GitHub"
flow = "app_installation"     # gh_cli_device | app_installation | oauth_device
lands_in = "secrets_env"      # config_dir | secrets_env
env_name = "GH_TOKEN"
renew_before_sec = 600
```

`flow` 와 `lands_in` 은 **닫힌 variant** 다. 알 수 없는 값은 기본값으로 접히지 않고
설정 로드에서 거부된다.

지금의 `gh` 경로는 삭제되지 않고 **선언 하나가 된다.**

```toml
id = "github-cli"
label = "GitHub"
flow = "gh_cli_device"
lands_in = "config_dir"
```

### App 설치 토큰은 이미 쓴 코드를 쓴다

`6638226397` 의 스크립트가 하는 일이 그대로 `flow = "app_installation"` 이다.
openssl 로 App JWT 를 RS256 서명하고, 설치 토큰을 발급받고,
`secrets/<keeper>/env/<env_name>` 에 0600 으로 쓴다. 설치 토큰은 60분을 살고
스크립트는 50분마다 갱신한다 — `renew_before_sec` 이 그 값이다.

새로 만드는 것이 아니라 **자리를 옮기는 것**이다.

## 제약을 테스트로 만든다

"provider 를 붙여도 OCaml 이 늘지 않는다" 는 약속이면 다음 사람이 안 지킨다.
이 저장소에 이미 같은 모양의 가드가 있다 — `test_keeper_toml.ml` 의
`concrete Keeper identities remain in OCaml source` 는 인벤토리를 읽고
`bin/ lib/ packages/ test/` 의 OCaml 을 훑어 **첫 하나가 아니라 전부** 보고한다.

같은 모양으로 하나 더 둔다.

```
선언된 provider id 는 OCaml 소스에 나타나면 안 된다.
```

이 가드는 **오늘 빨갛다** — `github` 이 129번 있다. 그리고 마지막 하드코딩이
사라지는 순간 초록이 된다. 즉 **이 테스트가 곧 완료 조건이다.** 별도의 "다 했나"
판단이 필요 없다.

실패 메시지는 위반한 파일과 id 를 전부 대고, 선언 파일 경로를 가리킨다.

## Explicit non-goals

- provider 별 OCaml 분기. 그게 이 RFC 가 없애려는 것이다.
- `gh` 흐름의 삭제. 선언 하나로 남는다.
- masc core 에 GitHub 전용 자격증명 분기. #24332 가 이미 지웠고 되살리지 않는다.
- 새 비밀 저장소. `secrets/<keeper>/` 와 `keepers/<keeper>/<config_dir>/` 가 그대로다.
- 배경 갱신 워커. 갱신은 그 키퍼의 신원을 쓰는 시점이나 운영자가 탭에서 누를 때 돈다.
- 호스트 계정 폴백.
- Keeper lifecycle 진입 게이트. 신원 없음은 관측 대상이지 실행 차단이 아니다.

## Failure behavior

신원이 없거나 갱신이 거부돼도 Keeper 는 계속 돈다. 그 서비스를 부르는 도구가
타입 있는 오류로 실패한다.

상태는 네 가지를 구분한다.

```ocaml
| Fresh          (* 유효 *)
| Renewed        (* 방금 갱신 *)
| Renew_rejected of { detail : string }
| Never_authorized
```

`Never_authorized`(한 번도 로그인 안 함) 와 `Renew_rejected`(취소됐거나 만료됨) 는
운영자에게 다른 사실이다. 앞 RFC 의 "Malformed or unsafe identity state is a typed
execution error and is not collapsed into absence" 와 같은 축이다.

교환 중 취소(`Eio.Cancel.Cancelled`)는 삼키지 않는다. 갱신 실패와 종료는 다른
사실이고, 이 저장소가 TLA+ 로 모델링한 `CancelledAbsorbed` 가 그 혼동이다.

자격증명 값은 어디에도 노출하지 않는다. 탭은 provider 이름, 마지막 갱신 시각,
위 네 상태 중 하나만 보여준다.

## Open questions

1. **한 provider 에 두 흐름이 필요한가.** GitHub 은 `gh_cli_device`(사람 계정)와
   `app_installation`(키퍼별 봇)이 둘 다 쓸모 있다. 탭을 두 개로 두는지, 한 탭에서
   고르는지.
2. **`oauth_device` 를 이번에 넣는가.** Jira·Slack 이 필요로 하는 흐름인데, 그건
   masc 가 refresh token 을 드는 첫 사례가 된다. `app_installation` 만 먼저 하고
   미루는 선택지가 있다.
3. **client secret 과 PEM 을 어디에 두는가.** TOML 에 넣으면 저장소에 들어간다.
   `secrets/` 의 워크스페이스 스코프가 맞아 보이지만, 그러면 TOML 은 선언만 하고
   값은 다른 곳을 가리킨다.
