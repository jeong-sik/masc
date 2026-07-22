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

**결정 요청**: D2(`RFC-0000-MASTER-ROADMAP` §11, line 957)의 *"plain-text credential 입력을
GitHub App device flow로 대체"* 절반을 **(a) typed device flow**로 추진한다.

**연관**: D2 (RFC-0000 §11), RFC-0008 (retired 2026-06-02), RFC-0019 (withdrawn 2026-06-02),
RFC-0074 (retired), PR #23528 (RFC-0236 §10, 2026-07-13 PR #24332에서 collateral delete)

**제약**: RFC-0000 §1.2 LAW 1 (no dead-end) · V7l boundary guard ·
`keeper_secret_projection` product-agnostic docstring

---

## 1. 사실 (history + HEAD 실측)

### 1.1 이 영역은 세 번 폐기/삭제됐다

| 시도 | RFC/PR | 상태 | 원인 |
|---|---|---|---|
| 1 | **RFC-0008** Credential Provider | Retired 2026-06-02 | repo-identity 결합. credential provider + host config bridge + in-container login + Docker mount + identity registry가 한 덩어리로 엮임 |
| 2 | **RFC-0019** Keeper Credential Unification | Withdrawn 2026-06-02 | 동일 원인. repo→GitHub identity registry + in-container `gh auth login` provisioning |
| 3 | **PR #23528** (RFC-0236 §10) GitHub App installation token | 2026-07-07 main 머지 → **2026-07-13 PR #24332에서 collateral delete** | Gate governance 비계층화 리팩터터의 부수 손해. credential 설계 결정이 아님. `keeper_github_app_jwt.ml`, `keeper_github_app_installation_token.ml` 등 12 파일(+443)이 통째로 삭제 |

RFC-0008/0019의 Replacement Contract는 명시적이다: *"No dashboard or HTTP API exists for
repository GitHub credential materialization. Git commands fail normally when the ambient
environment cannot access the remote."* 본 RFC는 이 계약을 **부분적으로 되돌린다** — 그
이유와 되돌리는 범위를 §2에서 서술한다.

### 1.2 HEAD 실측 (`70ae17bdda`, file:line 검증)

- `rg "device_code|device_flow|user_code|verification_uri|installation_id|app_jwt"` against
  `lib/` → **0건**. device-flow 코드는 이 코드베이스에 한 번도 존재한 적이 없다 (fork의
  §10.5에서 명시적으로 reject됐던 경로).
- `lib/keeper/credential_*`, `lib/keeper/keeper_gh_*`, `lib/keeper/keeper_github_app_*` —
  전부 **0건** (패턴 매칭 없음).
- keeper의 GitHub 인증: **명시적으로 안 함**. `Repo_git.run_git`(`lib/repo_manager/repo_git.ml:122`)
  가 `GIT_TERMINAL_PROMPT=0` 계열의 non-interactive git env만 설정하고 credential을 주입하지
  않는다. ambient env에 의존.
- `Env_keeper_scrub` allowlist(`lib/env_keeper_scrub.ml:11-43`)에 `GH_TOKEN`/`GITHUB_TOKEN`
  없음.
- dashboard: GitHub credential UI 표면 **0건**. `KNOWN_CONNECTOR_IDS = ['discord',
  'imessage', 'slack', 'telegram']`(`dashboard/src/components/connector-constants.ts:20`,
  OCaml mirror `lib/server/server_routes_http_sidecar_paths.ml:6`). GitHub는 URL placeholder로만.

### 1.3 재사용 자산 (이미 HEAD에 존재, 정확한 API)

| 자산 | 위치 | 본 설계에서의 용도 |
|---|---|---|
| `Keeper_secret_projection.set_env_entry` | `lib/keeper/keeper_secret_projection.mli:49-58` | token 영속화 (0600, symlink reject, single-line validation). **product-agnostic** |
| `local_env_for_keeper` overlay | `lib/keeper/keeper_secret_projection.ml:862-869` | keeper child process env 주입 |
| `Masc_http_client.post_sync` | `lib/masc_http_client/masc_http_client.mli:45-57` (piaf+TLS, per-domain pool) | GitHub OAuth 3 endpoint 호출. test seam `:117-125` |
| `Channel_gate_connector` module-type-S + registry | `lib/gate/channel_gate_connector.mli:19-64,68-83` | `Credential_provider.S` registry 패턴의 모델 (단 binding shape은 다름 — §4.2) |
| keeper secrets POST route 패턴 | `lib/server/server_dashboard_http_keeper_api_post.ml:765-849` | `/credentials` route가 따를 패턴 |
| keeper suffix dispatch | `lib/server/server_dashboard_http_keeper_api_types.ml:7-117` | `/credentials` suffix 추가 지점 |
| `save_file_atomic` (`rename(2)` 기반) | `keeper_secret_projection.ml:555` 사용 참조 | refresh token rotation 원자적 쓰기 |

### 1.4 overlay 순서 — 핵심 발견 (scrub layer 수정 불필요)

`local_env_for_keeper`(`keeper_secret_projection.ml:862-869`)의 순서:

1. `:866` `merge_env_entries roots` — projected env entries 로드 (`secrets/base/env` +
   `secrets/<keeper>/env` overlay)
2. `:867` `local_base_host_env` — host env를 `Env_keeper_scrub.filter_environment`로 scrub
3. `:868` `overlay_env_entries base env_entries` — projected env를 scrub된 host **위에** overlay

**결론**: projected `GITHUB_TOKEN`은 scrub 경로를 통과하지 않는다. `Env_keeper_scrub`
allowlist에 `GH_TOKEN`을 추가할 필요가 없다. 오히려 host shell에 leak된 `GH_TOKEN`을 scrub이
올바르게 제거하며, projection overlay가 per-keeper 값을 SSOT로 공급한다. **scrub layer와
projection layer 모두 zero change.**

---

## 2. 왜 지금 결정이 필요한가

### 2.1 D2가 OPEN이다

`RFC-0000-MASTER-ROADMAP.md` §11 (line 957) D2 verbatim:

> existing multi-repo substrate와 별개인 keeper-repo-mapping UI/policy layer를 유지할 것인가
> **+ plain-text credential 입력을 GitHub App device flow로 대체할 것인가**
>
> 옵션: (a) typed device flow로 유지 (b) UI/policy layer 제거; **plain-text 현상 유지는 선택지 아님**
>
> blast-radius: **높음** — credential/identity RFC-gated

본 RFC는 D2의 **device flow 교체 절반**만 담당하고 (a)를 선택한다.

### 2.2 D2 인용이 stale이다

D2 행의 blast-radius는 `lib/keeper/credential_*`·`lib/repo_manager/`를 인용하지만, 이
파일들은 §1.1의 세 번 폐기 과정에서 HEAD에서 사라졌다. 출처로 적힌 RFC-0322도 Withdrawn.
본 RFC는 credential 코드의 **새 경로**(`lib/credential/`)를 제안하며, D2 행의 path 인용을
갱신할 것을 권한다 (본 RFC 머지 시 roadmap에 반영).

### 2.3 세 번째 시도가 앞의 두 번과 다른 점

| 축 | RFC-0008/0019 | PR #23528 | **본 RFC** |
|---|---|---|---|
| identity 범위 | per-repo | per-keeper (installation) | **per-keeper (user token)** |
| 메커니즘 | in-container `gh auth login` | installation token (JWT+PEM) | **device flow → user access token** |
| 코어가 GitHub를 아는가 | O | O (`keeper_github_app_*`) | **X** (`credential_provider.mli`는 product-agnostic) |
| 결합 형태 | repo-manager-coupled | `keeper_secret_projection` overlay | **loosely-coupled plugin** (`Credential_provider.S`) |
| attribution | repo identity | app installation ("masc-bot") | **user login** ("vincent via keeper") |

세 번 모두 different axis에서 달라졌다. 본 RFC가 앞선 시도의 실패 원인(repo-identity 결합,
코어로의 GitHub 침투)을 회피하는 근거는 §3의 boundary 검토로 검증한다.

---

## 3. LAW & boundary-guard 제약

### 3.1 LAW 1 (no dead-end)

token 만료·revocation이 keeper를 terminal 상태로 만들지 않는다. keeper process는 살아있고
git/gh 호출만 `401`로 실패한다. Phase 5 (background refresh fiber)가 8h 만료를 사전 갱신해
최종 해소한다. Phase 5 전에는 "keeper는 동작하지만 GitHub 작업이 인증 실패" 상태가 되며,
이걸 §5에 문서화된 제한으로 둔다.

### 3.2 V7l boundary guard

`scripts/check-boundary-guard.sh:235-244` (V7l-generic-gate-product-knowledge)는 **8개 파일만**
스캔한다: `lib/keeper/keeper_gate.{ml,mli}`, `lib/keeper/keeper_tool_shared_runtime.{ml,mli}`,
`lib/keeper/keeper_tool_dispatch_runtime.{ml,mli}`, `lib/tool_bridge.{ml,mli}`.

스크립트 코멼트(`:234`): *"Product and CLI names belong to connector/tool adapters, never
this boundary."* 즉 `lib/credential/github/*.ml`에서 `GitHub`를 이름붙이는 것은 **guard가
의도한 adapter 위치**다. dashboard connector 파일(`dashboard/src/components/credential-*.ts`)도
V7l 범위 밖이다.

본 RFC가 지키는 경계: interface module `lib/credential/credential_provider.mli`는
**GitHub를 이름붙이지 않는다** (naming discipline). 이건 CI 강제가 가능하다 — V7l scan
list에 9번째 파일로 추가하는 PR을 본 RFC 구현 Phase 1에서 수반한다 (§7).

### 3.3 keeper_secret_projection product-agnostic 계약

`keeper_secret_projection.mli:33-35` docstring: *"Secret names and values are projected
without interpreting a provider, product, CLI, or credential format."*

device-flow가 얻은 token은 이 계약을 존중해 `set_env_entry`로 전달된다. 단 **페어링
orchestration 자체**(device-code 발급, polling, refresh rotation)는 product-specific이므로
`/secrets` action이 아니라 별도 `/credentials` 경로에 둔다. token 값만 product-agnostic
projection을 탄다.

### 3.4 credential_provider.mli naming discipline

interface module은 provider에 대해 완전히 무관심해야 한다: `provider_id : string`,
`display_name : string`, 그 외 provider-agnostic operation만 노출. `GitHub`, `gh`,
`device_flow`, `user_code` 같은 token이 이 파일에 등장하면 안 된다. 구현 시 V7l에 9번째
scan target으로 추가해 CI가 강제하게 한다.

---

## 4. 설계

### 4.1 `Credential_provider.S` module type (최소 surface)

```ocaml
(* lib/credential/credential_provider.mli — provider-agnostic. GitHub/gh/device_flow
   등의 단어가 이 파일에 등장하면 boundary 위반이다 (§3.4). *)

module type S = sig
  val provider_id : string
  (** Stable lowercase identifier ("github"). Route path · state dir · dashboard dispatch. *)

  val display_name : string
  (** Human label for dashboard rendering. *)

  type pairing_state =
    | Pending of { user_code : string; verification_uri : string; expires_at : float }
    | Authorized of { login : string; acquired_at : float; expires_at : float }
    | Expired
    | Error of string

  val start_pairing :
    base_path:string -> keeper_name:string -> unit -> (string, string) result
  (** Initiate pairing. Returns opaque pairing_id. Durably records pending state.
      Implementation begins provider-specific background polling (impl-owned). *)

  val pairing_status :
    base_path:string -> keeper_name:string -> pairing_id:string ->
    (pairing_state, string) result
  (** Read current pairing state. Non-blocking; impl's poller updates the state file. *)

  val status :
    base_path:string -> keeper_name:string -> unit ->
    [ `Authorized of { login : string; expires_at : float }
    | `Absent
    | `Expired
    | `Error of string ]
  (** Whether a usable credential is currently projected for this keeper. *)

  val refresh :
    base_path:string -> keeper_name:string -> unit -> (unit, string) result
  (** Force immediate refresh. Impl guarantees rotation atomicity (§4.4). *)

  val revoke :
    base_path:string -> keeper_name:string -> unit -> (unit, string) result
  (** Revoke at provider AND delete projected secret. After Ok, [status] is `Absent. *)
end

val register : (module S) -> unit
val find : string -> (module S) option
val all : unit -> (module S) list
```

**의도적 제외** (YAGNI): `list_scopes`, `rotate_keys`, `provision_app`,
`get_installation_targets`. 두 번째 provider가 등장해 필요해질 때까지 interface를 부풀리지
않는다.

### 4.2 GitHub plugin 홈: `lib/credential/github/`

```
lib/credential/
  credential_provider.{ml,mli}   (* module type S + registry — provider-agnostic *)
  dune                            (* library masc.credential_provider *)
lib/credential/github/
  credential_provider_github.{ml,mli}  (* satisfies S; registered at server bootstrap *)
  github_device_flow.{ml,mli}          (* HTTP state machine: device-code request + poll *)
  github_oauth_client.{ml,mli}         (* 3 endpoints via Masc_http_client.post_sync *)
  github_token_store.{ml,mli}          (* refresh_token + metadata, 0600, rotation-atomic *)
  dune                                  (* library masc.credential_github *)
```

**`lib/connector/`가 아닌 이유**: `lib/gate/`가 messaging connector(`channel_id →
keeper_name`, system-wide single token)를 이미 가지고 있고 binding shape이 정반대다.
messaging connector framework를 per-keeper 다중 identity로 전복시키는 대신, 별개 최상위
`lib/credential/`에 둬 messaging과 **공존**한다. 이건 Codex의 connector 모델이 messaging과
credential-provider를 같은 framework의 다른 종류로 다루는 것과 같은 원리다.

### 4.3 Polling: dedicated Eio fiber + per-keeper state file

| 옵션 | 판정 | 근거 |
|---|---|---|
| `Keeper_approval_queue.submit_pending` + `resolve_with_policy` | **거부** | `resolve_with_policy ~decision:Approve/Deny`는 HITL decision-shaped. device flow는 GitHub가 200을 반환해 끝나는 flow라 의미가 안 맞고, keeper HITL 승인 view와 혼재 |
| `Bg_task.spawn` | **거부** | shell subprocess + stdout/stderr ring. HTTP 상태머신과 shape 다름 |
| **dedicated Eio fiber + state file** | **채택** | server-bootstrap 소유 fiber가 `interval`초마다 폴링, state file 갱신, terminal 시 자가종료. HTTP route는 state file을 읽기만 |

서버 재시작 중엔 device code가 ~15분 단발이라 auto-resume이 복잡도 대비 가치가 없다.
state file이 `pending` + 만료 시각을 기록하므로, dashboard는 "flow expired, 재시작"을
표시하고 운영자가 재시도한다.

### 4.4 Refresh rotation atomicity (HIGH risk)

GitHub는 device-flow user token에서 **매 refresh마다 refresh token을 회전**시킨다
(OAuth 2.0 device flow with refresh tokens, GitHub 구현). 서버가 old refresh token을
사용한 뒤 new refresh token을 영속화하기 전에 crash하면 credential이 복구 불가능하게
상실한다.

`github_token_store`의 atomicity protocol (persist-before-consume):

1. `token.json`에서 현재 `(access_token, refresh_token)` 읽기
2. GitHub에 refresh POST → 새 `(access', refresh', expires')`
3. **`save_file_atomic`(`rename(2)`)** 로 `token.json`을 새 refresh_token으로 갱신 —
   per-keeper `Mutex`로 직렬화 (동시 refresh가 같은 refresh token을 중복 소비하지 않도록)
4. **그 후에야** `Keeper_secret_projection.set_env_entry ~name:"GITHUB_TOKEN" ~value:access'`

refresh token(희소·회전 자원)을 access token consumer보다 먼저 영속화한다. step 3 실패 시
old refresh_token이 디스크에 남아 retry가 재사용한다.

### 4.5 HTTP routes (새 `/credentials` 경로)

```
POST   /api/v1/keepers/<name>/credentials/github/device-flow
       → { pairing_id, user_code, verification_uri, expires_in, interval }
GET    /api/v1/keepers/<name>/credentials/github/device-flow/<pairing_id>
       → { status, login, expires_at }
GET    /api/v1/keepers/<name>/credentials/github
       → { status, login, expires_at, projected_env: ["GITHUB_TOKEN"] }
POST   /api/v1/keepers/<name>/credentials/github/refresh
POST   /api/v1/keepers/<name>/credentials/github/revoke
```

dispatch는 `Credential_provider.find "github"`로 provider-agnostic. route 경로에 `github`
리터럴이 들어가는 건 허용된다 (`lib/server/`는 V7l 범위 밖). future GitLab route는
`/credentials/gitlab/device-flow`로 core 변경 없이 추가된다.

### 4.6 Dashboard widget

기존 connector schema는 static field만 표현한다 (`connector-config-form.ts`의 `FieldWidget`
switch에 action branch 없음). interactive pairing(user_code 표시 + polling)은 **새 widget**이
필요하다: `dashboard/src/components/credentials/github-device-flow-card.ts` (user_code 표시 +
복사 버튼 + 만료 카운트다운 + polling 상태 표시). keeper detail view에 배치. dashboard
파일은 V7l 밖이라 GitHub 이름 허용.

### 4.7 전파 경로 — projection/scrub zero change

1. device-flow polling fiber가 `{access_token, refresh_token}` 획득
2. `Keeper_secret_projection.set_env_entry ~scope:Keeper_secret ~name:"GITHUB_TOKEN"
   ~value:access_token`
3. keeper launch 시 `local_env_for_keeper`: host env scrub(`:867`) → projected env
   overlay(`:868`)
4. keeper process가 `GITHUB_TOKEN` 상속 → `git`/`gh`가 자동 감지

`Env_keeper_scrub` 수정 불필요 (§1.4).

---

## 5. trade-offs (비판적 유보)

1. **rotation bug window (~1ms)**: GitHub가 old refresh token을 수락한 직후 ~1ms window에서
   crash 시 credential 상실. atomicity protocol(§4.4)이 완화하지만 닫지는 못한다. 개발자
   도구 수준에서 수용; production IAM엔 journaling/WAL이 필요하다.
2. **8h expiry on long keeper runs**: Phase 5 전까지 8h 초과 실행 시 git/gh가 `401`. keeper
   자체는 살아있음 (LAW 1). 문서화된 제한; Phase 5가 최종 해소.
3. **선례 부재**: device-flow + per-agent GitHub identity 조합을 구현한 하네스가 없다
   (Codex는 browser OAuth + server-side token; Claude Code는 GitHub App installation이지만
   global per user; Hermes는 plaintext PAT global). dashboard UX·fiber lifecycle edge case를
   우리가 발견해야 한다. Phase 2 test가 상태머신을 HTTP route 이전에 exhaustive 검증한다.
4. **Linux plaintext**: `.masc/secrets/<keeper>/env/GITHUB_TOKEN`이 plaintext 0600 파일.
   filesystem read 권한 공격자가 token 획득. macOS Keychain은 Linux에서 불가능해 cross-platform
   경로를 택했다. 완화: 0600(`set_env_entry`가 이미 강제) + `.masc/` dir 0700 + symlink reject.
   at-rest 암호화는 keystore 자체가 credential을 필요로 하는 재귀적 문제 — 본 RFC 범위 밖.
5. **attribution plugin-internal**: 기본 user access token → "vincent via keeper". bot
   attribution("masc-bot", installation token)은 별개 plugin 구현(`credential_provider_github_app_installation`)
   으로 가능하며 interface가 수용한다. 본 RFC는 user-token만 한다.
6. **GitHub App scope**: `scope=repo,read:org` 기본. 너무 좁으면 silent `403`, 너무 넓으면
   과인가. workspace config(`MASC_GITHUB_APP_SCOPES` 또는 `config/credentials.toml`)로 조정 가능,
   운영자 결정.

---

## 6. phasing

각 phase는 독립적으로 merge 가능하고 각각 test를 수반한다.

| Phase | 산출물 | test |
|---|---|---|
| **0 (본 RFC)** | 이 문서 + D2 갱신 | RFC 게이트(`pr-rfc-check.sh`), 인덱스 일관성 |
| 1 | `Credential_provider.S` interface + registry + stub provider (`lib/credential/`) | registry register/find/all, stub lifecycle, interface에 `GitHub` 문자 0건 (CI grep) |
| 2 | GitHub device-flow HTTP 상태머신 + token store + refresh rotation (`lib/credential/github/`) | mock HTTP: pending→slow_down(interval 배수)→authorized, expired_token terminal, refresh rotation crash-between, projection integration, scrub non-interference |
| 3 | `/credentials` HTTP routes + server bootstrap wiring | start pairing → poll → revoke; projected `GITHUB_TOKEN`이 `local_env_for_keeper`에 나타남 |
| 4 | dashboard `github-device-flow-card` widget | Playwright: user_code 렌더, polling 상태 전이 |
| **D2 closure** | Phase 4 완료 시 | 운영자가 dashboard에서 keeper pair, plaintext 파일 수정 없이, keeper git push가 pair된 login으로 인증 |
| 5 (optional) | background refresh fiber + 8h expiry 사전 갱신 | synthetic clock, 만료 N분 전 refresh 발화 |

---

## 7. verification

- **boundary guard CI**: Phase 1에서 V7l scan list에 `lib/credential/credential_provider.{ml,mli}`
  를 9번째 target으로 추가. interface가 GitHub를 이름붙이면 CI가 reject.
- **인덱스 일관성**: `python3 scripts/rfc-generate-index.py --check` PASS.
- **overlay-order 증명** (Phase 2 test에 포함): host env에 `GH_TOKEN=leaked` 설정 →
  `local_env_for_keeper` 실행 → projected `GITHUB_TOKEN`이 자식 env에 들어가고 `leaked`는
  부재 (scrub이 host `GH_TOKEN` 제거, projection이 per-keeper 값 공급).
- **D2 acceptance** (Phase 4): §6의 closure 기준.
- **RFC 게이트**: 본 RFC PR은 `pr-rfc-check.sh`가 PASS (credential/identity 영역).

---

## 8. 본 RFC가 닫지 않는 것 (명시적 비-목표)

- **D2의 (1) keeper-repo-mapping UI/policy layer 유지 여부** — 본 RFC는 (2) device flow
  교체만 담당. (1)은 별개 결정으로 남는다.
- **installation token (bot attribution)** — 본 RFC는 user-token(device flow)만. 별개
  plugin으로 가능하나 YAGNI.
- **at-rest 암호화** — Linux plaintext trade-off를 수용한다 (§5.4).
- **다른 provider (GitLab, Bitbucket)** — interface는 열어두지만 구현하지 않는다. 두 번째
  provider가 필요해질 때 일반화를 재검토.
- **`gh` subcommand risk classification 복구** — PR #24332에서 `lib/exec/gh_verb.ml`,
  `gh_capability_policy.ml`, `shell_ir_risk.ml`이 같이 삭제됐다. keeper가 `gh auth`/`gh secret
  set`을 치는 risk model 부재는 본 RFC 범위 밖이나, Phase 3 이전에 별도로 다뤄야 할
  선행/병렬 이슈로 기록한다.
