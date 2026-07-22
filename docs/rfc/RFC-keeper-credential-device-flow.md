---
rfc: "keeper-credential-device-flow"
title: "OAuth Addon Plugin — Keeper별/MASC 전체 외부 서비스 Credential (GitHub, Figma, …)"
status: Draft
created: 2026-07-22
updated: 2026-07-22
author: vincent (drafted with Claude)
supersedes: []
superseded_by: null
related: ["0008", "0019", "0074", "0000"]
implementation_prs: []
---

# RFC: OAuth Addon Plugin — Keeper별 / MASC 전체 외부 서비스 Credential

Status: Draft · rev 4 (OAuth addon plugin) · 2026-07-22 · HEAD `70ae17bdda`

**결정 요청**: D2(`RFC-0000-MASTER-ROADMAP` §11)의 *"plain-text credential 입력을 GitHub App
device flow로 대체"* — **OAuth addon plugin**으로 일반화. GitHub가 첫 구현체, Figma 등 다른 OAuth
서비스가 같은 interface에 추가.

**연관**: D2 (RFC-0000 §11), RFC-0008/0019 (retired/withdrawn — 같은 실수 안 하려 함), PR #23528
(#24332에서 collateral delete)

---

## 1. 배경

### 1.1 요청

credential이 필요한 외부 서비스(GitHub, Figma, …)를 keeper 개별 또는 MASC 전체에 연결하고 싶다.
**"Connect GitHub" / "Connect Figma"** 버튼 → OAuth → 편하게 연결. messaging(외부 대화창)은 기존
**connector**(discord/slack/…)이 담당하고, **credential 서비스**는 별도의 **OAuth addon**으로.

### 1.2 두 "외부 연결" 축

| 축 | 담당 | 방향 | 예 |
|---|---|---|---|
| messaging channel | connector(`lib/gate/channel_gate_*`) | 외부 → keeper (inbound event) | discord, slack |
| credential 서비스 | **OAuth addon**(본 RFC) | keeper → 외부 (outbound 인증) | GitHub, Figma |

같은 "외부 연결" 큰 틀의 다른 타입. 본 RFC는 credential 축의 plugin 자리를 만든다.

### 1.3 역사와 교훈

이 영역은 세 번 폐기/삭제됐다(RFC-0008/0019, #23528). 교훈: (a) **무겁게 만들지 말 것**,
(b) GitHub만 보지 말 것(Figma 같은 credential 서비스들이 더 있다). 본 RFC는 OAuth라는 공통점으로
여러 서비스를 하나의 가벼운 interface에 묶는다.

### 1.4 핵심 관찰 — 다 OAuth다

GitHub(device flow), Figma(OAuth redirect), 모두 **OAuth 2.0**이다. device flow도 OAuth의 한
grant(RFC 8628 device authorization grant). 따라서 credential addon = **OAuth addon**으로
통일하고, 차이는 `grant_type` 하나로 표현한다. opaque payload가 아니라 OAuth 표준 용어로 typed.

---

## 2. 설계

### 2.1 `Oauth_addon` module type

```ocaml
(* lib/credential/oauth_addon.mli — provider-agnostic OAuth addon interface.
   특정 서비스(GitHub/Figma) 이름이 이 파일에 등장하면 안 된다. *)

type grant =
  | Device_code          (* RFC 8628 — GitHub *)
  | Authorization_code   (* redirect flow — Figma 등 *)

type connect_prompt =
  | Device_code_prompt of { user_code : string; verification_uri : string; expires_in : float; interval : float }
  | Redirect_prompt of { authorization_url : string }

type state =
  | Pending
  | Authorized of { identity : string; expires_at : float }
  | Expired
(* 종단 실패(access_denied, transport error 등)는 result의 string error 채널로
   단일화한다 — state에 Error variant를 두지 않는다(이중 에러 채널 방지). *)

module type S = sig
  val addon_id : string        (* "github" | "figma" — route, state dir, dashboard dispatch *)
  val display_name : string    (* "GitHub" | "Figma" *)
  val env_var : string         (* "GITHUB_TOKEN" | "FIGMA_TOKEN" — keeper env에 주입될 이름 *)
  val grant : grant
  val token_endpoint : string
  val default_scopes : string  (* "repo,read:org" / "file_read" 등 *)

  val start_connect :
    base_path:string -> ?keeper_name:string -> scope:Keeper_secret_projection.secret_scope ->
    client_id:string -> unit -> (string * connect_prompt, string) result
  (** OAuth 연결 시작. opaque connect_id 반환 + grant에 맞는 prompt(device code / redirect URL).
      dashboard가 grant로 렌더링. *)

  val poll : base_path:string -> connect_id:string -> (connect_prompt option * state, string) result
  (** state = Pending | Authorized of {identity; expires_at} | Expired. 종단/전송 실패는
      result의 string error 채널로 반환. Device_code만 poll; Redirect는 콜백으로 갱신. *)

  val revoke : base_path:string -> ?keeper_name:string -> scope:... -> unit -> (unit, string) result
end

val register : (module S) -> unit
val find : string -> (module S) option
```

token 획득 후 각 addon이 공통으로 `Keeper_secret_projection.set_env_entry ~scope ~name:addon.env_var`에
주입. 주입 로직은 공통 helper로 빼고, addon은 `addon_id`/`env_var`만 제공.

### 2.2 GitHub addon (`grant = Device_code`) — 첫 구현체

`lib/credential/github/github_oauth_addon.{ml,mli}` + `github_device_flow.{ml,mli}`. device flow 3
endpoint(`Masc_http_client.post_sync`): `/login/device/code` → `user_code`+`verification_uri` 표시 →
polling `/login/oauth/access_token`(`authorization_pending`/`slow_down`/`expired_token`/성공). 토큰 →
`set_env_entry ~name:"GITHUB_TOKEN"`.

### 2.3 Figma addon (`grant = Authorization_code`) — 두 번째 예정

`lib/credential/figma/...`. redirect flow: `authorization_endpoint`로 브라우저 이동 → MASC callback
`/oauth/callback/figma` → code → token 교환. 같은 `Oauth_addon.S`. 본 RFC는 **자리만** 잡고 Figma
구현은 후속 PR.

### 2.4 scope — keeper 개별 OR MASC 전체 (기존 `secret_scope` 재사용)

| 사용자 의도 | `secret_scope` | 저장 위치 | 효과 |
|---|---|---|---|
| keeper 개별 | `Keeper_secret` | `.masc/secrets/<keeper>/env/<ENV_VAR>` | 해당 keeper만 |
| MASC 전체 | `Shared_secret` | `.masc/secrets/base/env/<ENV_VAR>` | 모든 keeper 상속 |

overlay 규칙으로 keeper-level이 workspace-level override. **새 API 0**.

### 2.5 전파 — projection/scrub zero change

`local_env_for_keeper`: host env scrub(`:867`) → projected env overlay(`:868`). `Env_keeper_scrub`
수정 불필요(projected token은 scrub 경로 안 통과). keeper process가 `GITHUB_TOKEN`/`FIGMA_TOKEN`
상속 → `git`/`gh`/Figma API client 자동 감지.

### 2.6 외부 선행 — client_id (각 addon)

OAuth는 `client_id` 필수. 각 addon별 workspace config:
`MASC_OAUTH_<ADDON>_CLIENT_ID`(예: `MASC_OAUTH_GITHUB_CLIENT_ID`, `MASC_OAUTH_FIGMA_CLIENT_ID`) 또는
`config/credentials.toml`의 `[oauth.<addon>] client_id`. 각 addon의 OAuth App 사전 등록 필요.

### 2.7 refresh — 공통

대부분 OAuth service가 refresh token 회전을 지원. 공통 helper가 token_endpoint로 refresh. addon별
차이(refresh token field 유무 등)는 addon이 처리. 8h 만료 access token을 사전 갱신(Phase 3 fiber).

---

## 3. trade-offs

1. **8h access token 만료**: Phase 3 refresh fiber(공통)로 사전 갱신. revocation(사용자 권한 철회)은
   autonomous keeper가 자체 회복 불가 — dashboard "재연결 필요".
2. **grant_type 다형성**: device_code vs redirect의 dashboard UX 차이는 `connect_prompt` typed로
   흡수. addon이 자기 grant만 구현.
3. **Linux plaintext 0600**: cross-platform(Keychain 배제). 0600 + dir 0700 + symlink reject.
4. **client_id 외부 선행**: 각 addon OAuth App 등록. Phase 1 전 확보.
5. **redirect flow callback**: Figma 등 redirect grant는 MASC가 `/oauth/callback/<addon>` 엔드포인트
   가져야 함 — Phase 2에서 추가. device_code(GitHub)는 callback 불필요.

---

## 4. phasing

| Phase | 산출물 | test |
|---|---|---|
| 0 (본 RFC) | 이 문서 + D2 갱신 | RFC 게이트, 인덱스 |
| 1 | `Oauth_addon.S` interface + registry + GitHub addon(device_code) + 공통 주입 helper | mock HTTP: device flow 상태머신, scope별 저장, overlay override, interface에 서비스명 0건 |
| 2 | dashboard Connect widget + `/credentials/<addon>/*` routes + `/oauth/callback/<addon>`(redirect용) | GitHub Connect → poll → 연결; projected token이 keeper env |
| **D2 closure** | Phase 2 완료 시 | dashboard Connect → keeper git 인증 |
| 3 (optional) | refresh fiber(공통) | 8h 만료 사전 갱신 |
| 4 (후속) | Figma addon(Authorization_code) — interface 검증 | redirect flow, callback |

---

## 5. 비-목표

- **messaging connector와의 통합** — connector(inbound event)와 OAuth addon(outbound credential)은
  다른 축. 같은 plugin system으로 묶지 않는다(§1.2).
- **non-OAuth credential**(PAT 직접 입력, API key) — OAuth만. 기존 `KeeperSecretProjectionPanel`이
  수동 입력 담당.
- **per-repo identity** — keeper당/workspace당 단일 token.
- **at-rest 암호화** — Linux plaintext 수용.
- **installation token(bot attribution)** — user access token(OAuth)만.
