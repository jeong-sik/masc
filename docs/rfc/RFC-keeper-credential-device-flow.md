---
rfc: "keeper-credential-device-flow"
title: "Keeper별 GitHub Credential (Device Flow) — 약결합 Credential Provider Plugin"
status: Draft
created: 2026-07-22
updated: 2026-07-22
author: vincent (drafted with Claude)
supersedes: []
superseded_by: null
related: ["0008", "0019", "0074", "0000"]
implementation_prs: []
---

# RFC: Keeper별 GitHub Credential (Device Flow) — 약결합 Credential Provider Plugin

Status: Draft · slug-only (README §정책) · 2026-07-22 · HEAD `70ae17bdda` 기준
(rev 2 — 5차원 적대 셀프 리뷰 23건 반영)

**결정 요청**: D2(`RFC-0000-MASTER-ROADMAP` §11, line 957)의 *"plain-text credential 입력을
GitHub App device flow로 대체"* 절반을 **(a) typed device flow**로 추진한다.

**연관**: D2 (RFC-0000 §11), RFC-0008 (retired 2026-06-02), RFC-0019 (withdrawn 2026-06-02),
RFC-0074 (retired), PR #23528 (RFC-0236 §10, 2026-07-13 PR #24332에서 collateral delete)

**제약**: RFC-0000 §1.2 LAW 1 (no dead-end) · V7l boundary guard ·
`keeper_secret_projection` product-agnostic docstring

---

## 1. 사실 (history + HEAD 실측)

### 1.1 이 영역은 세 번 폐기/삭제됐다 (둘은 설계 실패, 하나는 collateral)

| 시도 | RFC/PR | 상태 | 원인 |
|---|---|---|---|
| 1 | **RFC-0008** Credential Provider | Retired 2026-06-02 | repo-identity 결합. credential provider + host config bridge + in-container login + Docker mount + identity registry가 한 덩어리 |
| 2 | **RFC-0019** Keeper Credential Unification | Withdrawn 2026-06-02 | 동일 원인. repo→GitHub identity registry + in-container `gh auth login` provisioning |
| 3 | **PR #23528** (RFC-0236 §10) GitHub App installation token | 2026-07-07 main 머지 → **2026-07-13 PR #24332에서 collateral delete** | Gate governance 비계층화 리팩터터의 부수 손해. **credential 설계 결정이 아니다.** working feature가 governance 리팩터터에 휩쓸림 |

PR #24332의 설치 토큰 코드 삭제는 정확히 **9 files / 1343 deletions**다(`git show --numstat
7b62a87d44` 필터): `keeper_github_app_{jwt,installation_token}.{ml,mli}`(4),
`dashboard/.../keeper-github-app-config.{ts,test.ts}`(2), `docs/rfc/RFC-0236*`(1),
`test/test_keeper_github_app_jwt.ml` + `test_keeper_secret_projection_github_app.ml`(2).
(초안의 "12 파일 +443"은 부정확했다 — #23528은 총 1039 insertions, github_app 파일만 ~575.)

RFC-0008/0019의 Replacement Contract는 명시적이다: *"No dashboard or HTTP API exists for
repository GitHub credential materialization."* 본 RFC는 이 계약을 **부분적으로 되돌린다**.

### 1.2 HEAD 실측 (`70ae17bdda`, file:line 검증)

- `rg "device_code|device_flow|user_code|verification_uri|installation_id|app_jwt"` against
  `lib/` → **0건**. device-flow 코드는 이 코드베이스에 한 번도 존재한 적이 없다.
- `lib/keeper/credential_*`, `lib/keeper/keeper_gh_*`, `lib/keeper/keeper_github_app_*` — 전부 **0건**.
- keeper의 GitHub 인증: **명시적으로 안 함**. `Repo_git.run_git`(`lib/repo_manager/repo_git.ml:122`)
  는 기본 `env=[]`로 `merge_env`를 타서 **ambient host env를 그대로 상속**(credential 주입 없음).
  `non_interactive_git_env`(`GIT_TERMINAL_PROMPT=0` 등, `repo_git.ml:24-30`)은 상수로 정의됐으나
  **run_git 기본이 아니라** 일부 caller(clone/fetch `:150,161`, status `:244,256` 등)만 opt-in으로
  전달한다. 결론(ambient 의존·credential 주입 없음)은 동일하다.
- `Env_keeper_scrub` allowlist(`lib/env_keeper_scrub.ml:11-43`)에 `GH_TOKEN`/`GITHUB_TOKEN` 없음.
- dashboard: GitHub credential UI 표면 **0건**. `KNOWN_CONNECTOR_IDS = ['discord',
  'imessage', 'slack', 'telegram']`(`dashboard/src/components/connector-constants.ts:20`).

### 1.3 재사용 자산 (이미 HEAD에 존재, 정확한 API)

| 자산 | 위치 | 용도 |
|---|---|---|
| `Keeper_secret_projection.set_env_entry` | `lib/keeper/keeper_secret_projection.mli:49-58` | full signature: `base_path -> keeper_name -> scope:secret_scope -> name -> value -> (unit,string) result`. 0600, symlink reject, **single-line validation**(`.ml:165-167`, `\n`/`\r` 거부 — `gho_`/`github_pat_` token은 single-line이라 OK). product-agnostic |
| `local_env_for_keeper` overlay | `lib/keeper/keeper_secret_projection.ml:862-869` | keeper child env 주입 (scrub → overlay) |
| `Masc_http_client.post_sync` | `lib/masc_http_client/masc_http_client.mli:45-57` (piaf+TLS, per-domain pool) | GitHub OAuth 3 endpoint. **주의**: `For_testing.with_request_timeout`(`:117-125`)은 timeout proof seam일 뿐 **HTTP response mock이 아니다**. Phase 2 test는 별도 local mock HTTPS server 또는 Pool 단 주입 필요 |
| `Channel_gate_connector` module-type-S + registry | `lib/gate/channel_gate_connector.mli:19-64,68-83` | registry 패턴의 모델. **이것이 agnostic interface의 본보기** — `connector_id`/`display_name`/`channel`/generic operation만, product-specific 필드 0개 |
| keeper secrets POST route 패턴 | `lib/server/server_dashboard_http_keeper_api_post.ml:765-849` | `/credentials` route가 따를 패턴 |
| `save_file_atomic` | `lib/fs_compat/atomic_write.ml:2508-2544` (tmp write → fsync(tmp) → `rename` → fsync(dir)) | refresh token rotation 원자적 쓰기. **fsync pair가 wall-clock 비용 지배** |

### 1.4 overlay 순서 — 핵심 발견 (scrub layer 수정 불필요)

`local_env_for_keeper`(`keeper_secret_projection.ml:862-869`):

1. `:866` `merge_env_entries roots` — projected env 로드
2. `:867` `local_base_host_env` — host env를 `Env_keeper_scrub.filter_environment`로 scrub
3. `:868` `overlay_env_entries base env_entries` — projected env를 scrub된 host **위에** overlay

projected `GITHUB_TOKEN`은 scrub 경로를 통과하지 않는다. **scrub/projection layer 모두 zero change.**

---

## 2. 왜 지금 결정이 필요한가

### 2.1 D2가 OPEN이다

`RFC-0000-MASTER-ROADMAP.md` §11 (line 957) D2 verbatim 인용(§8.3에서 결정 가능 형태로 통합):
*"plain-text credential 입력을 GitHub App device flow로 대체"* 옵션 (a) typed device flow /
(b) UI·policy 제거(**plain-text 현상 유지는 선택지 아님**). 본 RFC는 (a)를 선택한다.

### 2.2 D2 인용이 stale이다

D2 행 blast-radius가 `lib/keeper/credential_*`·`lib/repo_manager/`를 인용하지만 이 파일들은
HEAD에 없다(§1.1). 출처 RFC-0322도 Withdrawn. 본 RFC는 credential 코드의 새 경로(`lib/credential/`)를
제안하며, D2 path 인용을 갱신한다.

### 2.3 앞선 시도와 다른 점

| 축 | RFC-0008/0019 | PR #23528 (collateral) | **본 RFC** |
|---|---|---|---|
| identity 범위 | per-repo | per-keeper (installation) | **per-keeper (user token)** |
| 메커니즘 | in-container `gh auth login` | installation token (JWT+PEM) | **device flow → user access token** |
| 코어가 GitHub를 아는가 | O | O (`keeper_github_app_*`) | **X — interface module은 product-agnostic¹** |
| 결합 | repo-manager-coupled | projection overlay | **loosely-coupled plugin** (`Credential_provider.S`) |
| attribution | repo identity | app installation | **user login** |

¹ 본 RFC 머지 시점(Phase 0)에는 `credential_provider.mli`가 **아직 존재하지 않는다**(Phase 1
산출물). "코어가 GitHub 모름"은 Phase 1에서 interface를 agnostic으로 작성 + V7l로 enforce할 때
성립하는 **promise**다. §2.3은 이걸 achieved fact가 아니라 Phase 1 약속으로 다룬다(§3.4, §7).

**주의**: #23528은 credential 설계 실패가 아니라 governance 리팩터터의 collateral이다(§1.1).
본 RFC가 회피해야 할 실패 패턴은 RFC-0008/0019의 **repo-identity 결합 + 코어로의 GitHub 침투**다.
#23528과의 차이(installation → user token, bot → user)는 유효하지만, #23528을 "실패한 시도"로
묶어 failure count를 부풀리지 않는다.

---

## 3. LAW & boundary-guard 제약

### 3.1 LAW 1 (no dead-end) — 만료와 revocation을 구분한다

- **만료(access token 8h)**: Phase 5 background refresh fiber가 사전 갱신해 **자동 회복**. keeper
  process도 살고 GitHub goal도 차단되지 않는다.
- **revocation(사용자가 GitHub에서 앱 권한 철회, 또는 refresh token 무효화)**: autonomous keeper가
  **자체 회복 불가** — human이 browser에서 device flow를 재완료해야 한다(비대화형 keeper는
  `verification_uri` 방문 + `user_code` 입력을 할 수 없다). 따라서 revocation 시 keeper process는
  살아있으나 **GitHub goal이 무기한 차단되는 operational dead-end**가 된다. 본 RFC는 이걸 명시적
  제한으로 받아들이고(§5), dashboard가 "재페어링 필요"를 표시한다. Phase 5는 expiry만 커버한다.

### 3.2 V7l boundary guard

`scripts/check-boundary-guard.sh:235-244` (V7l)은 **8개 파일만** 스캔한다:
`lib/keeper/keeper_gate.{ml,mli}`, `lib/keeper/keeper_tool_shared_runtime.{ml,mli}`,
`lib/keeper/keeper_tool_dispatch_runtime.{ml,mli}`, `lib/tool_bridge.{ml,mli}`.

코멼트(`:234`): *"Product and CLI names belong to connector/tool adapters, never this
boundary."* 즉 `lib/credential/github/*.ml`에서 `GitHub`를 이름붙이는 건 guard가 의도한 adapter
위치다. dashboard 파일(`dashboard/src/components/credentials/*.ts`)도 V7l·V7n 모두 범위 밖이다
(V7n은 `dashboard/src/components/ide/`·`dashboard/src/api/`만 스캔).

### 3.3 keeper_secret_projection product-agnostic 계약

`keeper_secret_projection.mli:33-35`: *"without interpreting a provider, product, CLI, or
credential format."* device-flow가 얻은 token은 `set_env_entry`로 전달되되, **페어링
orchestration 자체**는 `/secrets` action이 아니라 별도 `/credentials` 경로에 둔다.

### 3.4 interface naming discipline — 그리고 V7l 강제의 한계

interface module `lib/credential/credential_provider.mli`는 provider에 무관해야 한다: device-flow
특정 토큰(`user_code`, `verification_uri`, `device_flow`)이 이 파일에 등장하면 안 된다. §4.1은
이걸 **opaque prompt payload**로 지킨다.

**V7l regex의 실제 한계**: 패턴 `'GitHub|github_app|github-app|(^|[^[:alnum:]_])gh([^[:alnum:]_]|$)'`
는 **case-sensitive**라 대문자 `GitHub`와 standalone `gh`는 잡지만, `user_code`,
`device_flow`, lowercase `github`(docstring 예시), `verification_uri`는 **잡지 못한다**(실제
grep 검증). 따라서 "9번째 파일 추가만으로 CI 강제"는 거짓이다. Phase 1은 **두 가지**를 수반한다:

1. V7l scan list에 `lib/credential/credential_provider.{ml,mli}` 추가 — 8개 + 2개 = **10번째
   target**(단일 `.mli`만 추가하면 9번째; 본 RFC는 둘 다 추가를 권장).
2. **regex 확장 또는 별도 lint rule** — interface module에서 OAuth/device-flow 특정 토큰
   (`user_code`, `verification_uri`, `device_flow`, `client_id`)을 금지. V7l에 새 rule V7o를
   추가하거나 별도 `check-credential-interface-agnostic.sh`를 둔다.

(1)만으로는 interface가 device-flow concept을 leak해도 CI가 통과한다.

---

## 4. 설계

### 4.1 `Credential_provider.S` — opaque prompt로 agnostic화

```ocaml
(* lib/credential/credential_provider.mli — provider-agnostic.
   GitHub/gh/device_flow/user_code/verification_uri/client_id 같은 토큰이 이 파일에
   등장하면 boundary 위반이다 (§3.4). 페어링 UX payload는 opaque JSON으로 빼서 각 provider가
   자기 형태를 채운다. *)

module type S = sig
  val provider_id : string
  (** Stable lowercase slug. route path·state dir·dashboard dispatch에 사용. *)

  val display_name : string
  (** Human label for dashboard rendering. *)

  type pairing_state =
    | Pending of { prompt : Yojson.Safe.t; expires_at : float }
    (** [prompt]는 provider가 정의한 opaque UX payload. dashboard는 provider_id로
        provider-specific하게 렌더링한다. interface는 이를 해석하지 않는다. *)
    | Authorized of { identity : string; acquired_at : float; expires_at : float }
    | Expired
    | Error of string

  val start_pairing :
    base_path:string -> keeper_name:string -> unit -> (string, string) result
  (** 페어링 시작. opaque pairing_id 반환. pending state를 durably 기록. *)

  val pairing_status :
    base_path:string -> keeper_name:string -> pairing_id:string ->
    (pairing_state, string) result

  val status :
    base_path:string -> keeper_name:string -> unit ->
    [ `Authorized of { identity : string; expires_at : float }
    | `Absent
    | `Expired
    | `Error of string ]

  val refresh :
    base_path:string -> keeper_name:string -> unit -> (unit, string) result

  val revoke :
    base_path:string -> keeper_name:string -> unit -> (unit, string) result
end

val register : (module S) -> unit
val find : string -> (module S) option
val all : unit -> (module S) list
```

`prompt : Yojson.Safe.t`가 핵심 변경점(초안 rev 1의 `user_code`/`verification_uri` 필드를
대체). GitHub provider가 `prompt`에 `{"user_code":"WDJB-MJHT","verification_uri":"..."}`를
채우고, dashboard가 `provider_id="github"`일 때 이 JSON을 device-flow 카드로 렌더링한다. non-device-flow
provider(가상의 static-token provider)는 자기 형태의 `prompt`를 채우면 된다 — interface는
어떤 provider 모양에도 억지를 부리지 않는다. 이게 `Channel_gate_connector.S`(product 필드 0개)와
같은 규율이다.

**의도적 제외** (YAGNI): `list_scopes`, `rotate_keys`, `provision_app`, flow-type variant.

### 4.2 GitHub plugin 홈 + 외부 선행 조건 (client_id)

```
lib/credential/
  credential_provider.{ml,mli}   (* module type S + registry — agnostic *)
  dune
lib/credential/github/
  credential_provider_github.{ml,mli}   (* satisfies S; registered at bootstrap *)
  github_device_flow.{ml,mli}           (* HTTP 상태머신 *)
  github_oauth_client.{ml,mli}          (* 3 endpoint via Masc_http_client.post_sync *)
  github_token_store.{ml,mli}           (* refresh_token + metadata, 0600 *)
  dune
```

`lib/connector/`가 아니라 `lib/credential/`인 이유: `lib/gate/`가 messaging connector(`channel_id
→ keeper_name`, system-wide single token)를 가지고 있고 binding shape이 정반대라 분리한다.

**외부 선행 조건 (client_id)**: device flow 3 endpoint(`/login/device/code`, `/login/oauth/access_token`
폴링·refresh)는 전부 `client_id`를 요구한다(RFC 8628 §3.1/§3.2/§3.4). `client_id`는 코드 외
선행 조건이다:

1. GitHub OAuth App 또는 GitHub App 등록 — device flow 활성화 + "Expire user authorization
   tokens" ON(refresh token 생성을 위해).
2. `client_id`를 workspace config에 주입: `MASC_GITHUB_OAUTH_CLIENT_ID` env 또는
   `config/credentials.toml`의 `[github] client_id = "Iv1...."`.
3. **이 `client_id` 없이 Phase 2의 첫 실제 HTTP 호출은 실패한다.** mock HTTP test는 별개 infra.

`scope=repo,read:org` 기본값도 같은 config에서 조정(`MASC_GITHUB_APP_SCOPES`).

### 4.3 Polling — per-pairing Eio fiber + 멱등 start

| 옵션 | 판정 | 근거 |
|---|---|---|
| `Keeper_approval_queue` | 거부 | `resolve_with_policy ~decision:`은 `Approve \| Reject of string \| Edit of Yojson.Safe.t`(`keeper_approval_queue_rules_types.ml:44-51`)를 받는 HITL 심의 shaped. device flow는 GitHub 200 응답으로 끝나는 flow라 안 맞고 keeper HITL 승인 view와 혼재 |
| `Bg_task.spawn` | 거부 | shell subprocess. HTTP 상태머신과 shape 다름 |
| **per-pairing Eio fiber + state file** | 채택 | `start_pairing`마다 poll fiber를 spawn, terminal 시 종료. HTTP route는 state file 읽기 |

**멱등 정책 (concurrent pairing)**: `start_pairing`이 같은 keeper의 **non-terminal pending**이
있으면 **기존 pairing_id를 반환**하고 새 flow를 시작하지 않는다. operator가 새 flow를 원하면
`revoke` 또는 만료 대기. 동시 double-click·dashboard refresh·retry가 같은 keeper에 대해 새 device
code를 무한히 발급하는 걸 막는다. fiber cardinality는 **per-pairing**(각 `start_pairing`이 하나).

서버 재시작 중엔 device code가 ~15분 단발이라 auto-resume이 복잡도 대비 가치 없다. state file이
`pending`+만료 시각을 기록하므로 dashboard가 "flow expired, 재시작"을 표시하고 운영자가 재시도한다.

### 4.4 Refresh rotation — error branch + 실제 window

GitHub는 매 refresh마다 refresh token을 회전시킨다. `github_token_store`의 protocol:

1. `token.json`에서 현재 `(access, refresh)` 읽기
2. POST refresh → **status code 분기**:
   - `200` + `{access_token, refresh_token, expires_in}` → step 3
   - `400` + `{error: "invalid_grant"|"expired_token"}` → `Error` 반환, **old refresh 유지**(재페어링
     필요, §3.1 revocation). refresh fiber가 retry하지 않는다(이미 무효).
   - `200`이지만 `refresh_token` 누락(server-side rotation 비활성 등) → access만 갱신, refresh는
     old 유지 + 경고 로그(response shape drift)
   - 기타 non-200 / 네트워크 에러 → `Error`, old refresh 유지, retry 가능
3. **`save_file_atomic`**(`tmp write → fsync(tmp) → rename → fsync(dir)`)으로 `token.json` 갱신 —
   per-keeper `Mutex`로 직렬화(동시 refresh가 같은 refresh token을 중복 소비하지 않도록)
4. 그 후에야 `Keeper_secret_projection.set_env_entry ~base_path ~keeper_name ~scope:Keeper_secret
   ~name:"GITHUB_TOKEN" ~value:access'`

**loss window**: GitHub가 old refresh를 무효화하는 시점(POST 수락)부터 `save_file_atomic` 완료까지.
`save_file_atomic`은 fsync pair가 wall-clock을 지배해 SSD에서 **tens of ms**(정확한 값은 미측정).
초안 rev 1의 "~1ms"는 misquantification이었다(anti-hype 위반). crash 시 old refresh가 이미
무효화 상태라 credential 상실, 재페어링 필요.

`Masc_http_client.post_sync`는 `((int * string), string) result`로 status code를 주므로 step 2의
분기가 가능하다.

### 4.5 HTTP routes

```
POST   /api/v1/keepers/<name>/credentials/github/device-flow      → { pairing_id, prompt, expires_in, interval }
GET    /api/v1/keepers/<name>/credentials/github/device-flow/<id> → { status, identity, expires_at }
GET    /api/v1/keepers/<name>/credentials/github                  → { status, identity, expires_at, projected_env: ["GITHUB_TOKEN"] }
POST   /api/v1/keepers/<name>/credentials/github/refresh
POST   /api/v1/keepers/<name>/credentials/github/revoke
```

dispatch는 `Credential_provider.find "github"`로 agnostic. route 경로의 `github` 리터럴은
허용(`lib/server/`는 V7l 밖). `POST /device-flow` 응답의 `prompt`는 opaque JSON(§4.1)이고
dashboard가 provider_id로 렌더링한다.

**route cardinality**: route의 `device-flow` suffix는 GitHub provider의 유일 flow를 표시.
interface `register`는 `provider_id` 단일 key이므로 같은 provider_id에 두 flow를 등록하면
overwrite된다. future second flow(browser redirect, app-installation)는 **별도 provider_id**로
등록해야 한다(§8의 "별개 plugin"과 정합).

### 4.6 Dashboard widget

`dashboard/src/components/credentials/github-device-flow-card.ts` — `prompt` JSON에서
`user_code`/`verification_uri`를 추출해 표시(복사 버튼 + 만료 카운트다운 + polling 상태). keeper
detail view에 배치. connector schema는 static field만 표현하므로 interactive pairing은 새 widget.

### 4.7 전파 경로 — projection/scrub zero change + single-token constraint

1. device-flow fiber가 `{access_token, refresh_token}` 획득
2. `Keeper_secret_projection.set_env_entry ~base_path ~keeper_name ~scope:Keeper_secret
   ~name:"GITHUB_TOKEN" ~value:access_token`
3. keeper launch 시 `local_env_for_keeper`: host env scrub(`:867`) → projected env overlay(`:868`)
4. keeper process가 `GITHUB_TOKEN` 상속 → `git`/`gh`가 자동 감지

`Env_keeper_scrub` 수정 불필요(§1.4).

**constraint (D2-(1)에 미치는)**: 본 설계는 keeper당 **단일 `GITHUB_TOKEN`**을 전파한다.
D2-(1)(keeper-repo-mapping policy)이 나중에 **per-repo identity**(한 keeper가 repo마다 다른
GitHub user)를 원하면, 이 single-token 모델로는 표현하지 못한다 — interface 확장이 필요하다.
§8에서 반복.

---

## 5. trade-offs (비판적 유보)

1. **rotation loss window**: POST 수락 후 `save_file_atomic` 완료까지. fsync pair 지배로 SSD에서
   tens of ms(미측정). crash 시 credential 상실, 재페어링 필요. 개발자 도구 수용; production
   IAM엔 journaling/WAL 필요.
2. **8h access-token expiry**: Phase 5 전까지 8h 초과 실행 시 git/gh `401`. Phase 5가 사전 갱신.
3. **revocation = operational dead-end**(§3.1): autonomous keeper가 앱 권한 철회·refresh 무효화 시
   자체 회복 불가. human browser 재페어링 필요. 명시적 제한.
4. **concurrent pairing**: 멱등으로 완화(기존 pairing_id 반환)했지만, operator가 의도적으로
   재시작하려면 revoke/만료 대기해야 한다.
5. **선례 부재**: device-flow + per-agent GitHub identity 조합을 구현한 하네스 없음(Codex는 browser
   OAuth + server-side token; Claude Code는 GitHub App installation global per user; Hermes는
   plaintext PAT global). dashboard UX·fiber lifecycle edge case를 우리가 발견.
6. **Linux plaintext**: `.masc/secrets/<keeper>/env/GITHUB_TOKEN` plaintext 0600. filesystem read
   권한 공격자가 token 획득. Keychain은 Linux 불가. 완화: 0600 + dir 0700 + symlink reject.
   at-rest 암호화는 keystore 자체가 credential을 필요로 하는 재귀 문제.
7. **attribution plugin-internal**: 기본 user access token → "vincent via keeper". bot
   attribution은 별개 plugin(`provider_id="github-app"`)으로 가능.
8. **GitHub App scope**: `scope=repo,read:org` 기본, workspace config로 조정. 운영자 결정.

---

## 6. phasing

| Phase | 산출물 | test / 비고 |
|---|---|---|
| **0 (본 RFC)** | 이 문서 + D2 갱신 | RFC 게이트, 인덱스 일관성 |
| 1 | `Credential_provider.S` interface(opaque prompt) + registry + V7l/lint 확장 + stub provider | registry mechanics(self-referential). **caller 없음 — Phase 2 전까지 dead code**, useful은 Phase 2부터. lint rule이 §3.4 실제로 enforce하는지가 핵심 test |
| 2 | GitHub device-flow HTTP 상태머신 + token store + refresh rotation | **선행: GitHub OAuth App `client_id`(§4.2)**. mock HTTP는 local mock HTTPS server 또는 Pool 주입. pending→slow_down(interval 배수)→authorized, expired_token terminal, refresh error branch(400 invalid_grant), response shape drift |
| 3 | `/credentials` HTTP routes + bootstrap wiring | start pairing(멱등) → poll → revoke; projected `GITHUB_TOKEN`이 `local_env_for_keeper`에 나타남 |
| 4 | dashboard `github-device-flow-card` widget | `prompt` JSON → user_code 렌더, polling 전이 |
| **D2 closure** | Phase 4 완료 시 | 운영자 dashboard pair, plaintext 수정 없이 git push가 pair된 login으로 인증 |
| 5 (optional) | background refresh fiber | 8h expiry 사전 갱신. **revocation은 커버 안 됨**(§3.1) |

---

## 7. verification

- **interface agnostic CI**: Phase 1에서 (a) V7l scan list에 `credential_provider.{ml,mli}` 추가
  (8→10), (b) **regex 확장 또는 별도 lint**로 `user_code`/`verification_uri`/`device_flow`/`client_id`도
  잡게 함(§3.4). lint가 §3.4를 실제로 enforce하는지가 핵심 검증.
- **인덱스 일관성**: `python3 scripts/rfc-generate-index.py --check` PASS.
- **overlay-order 증명**(Phase 2 test): host env `GH_TOKEN=leaked` → `local_env_for_keeper` →
  projected `GITHUB_TOKEN`이 자식 env, `leaked` 부재.
- **refresh error branch test**(Phase 2): 400 invalid_grant → old refresh 유지 + Error; response
  shape drift(access만) → access 갱신 refresh 유지.
- **D2 acceptance**(Phase 4): §6 closure 기준.
- **RFC 게이트**: 본 RFC PR은 `pr-rfc-check.sh` PASS.

---

## 8. 본 RFC가 닫지 않는 것 (명시적 비-목표)

- **D2의 (1) keeper-repo-mapping UI/policy layer 유지 여부** — 본 RFC는 (2) device flow 교체만.
- **installation token (bot attribution)** — user-token(device flow)만. 별개 provider_id plugin으로 가능.
- **per-repo identity (한 keeper가 repo마다 다른 GitHub user)** — 본 RFC는 keeper당 단일
  `GITHUB_TOKEN`(§4.7). per-repo identity는 interface 확장이 필요하므로 **D2-(1)에 미치는
  constraint**로 명시.
- **at-rest 암호화** — Linux plaintext trade-off 수용(§5.6).
- **다른 provider (GitLab 등)** — interface는 열어두지만(opaque prompt 덕분) 구현하지 않는다.
- **`gh` subcommand risk classification 복구** — PR #24332에서 `gh_verb.ml` 등이 삭제됐다. Phase 3
  이전 별도 이슈.
- **revocation 자동 회복** — 불가(§3.1). 명시적 제한.
