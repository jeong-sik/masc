---
rfc: "keeper-credential-device-flow"
title: "GitHub Addon — Keeper별 / MASC 전체 GitHub 연결 (Device Flow Connect)"
status: Draft
created: 2026-07-22
updated: 2026-07-22
author: vincent (drafted with Claude)
supersedes: []
superseded_by: null
related: ["0008", "0019", "0074", "0000"]
implementation_prs: []
---

# RFC: GitHub Addon — Keeper별 / MASC 전체 GitHub 연결 (Device Flow Connect)

Status: Draft · rev 3 (addon 단순화) · 2026-07-22 · HEAD `70ae17bdda`

**결정 요청**: D2(`RFC-0000-MASTER-ROADMAP` §11)의 *"plain-text credential 입력을 GitHub App
device flow로 대체"* — **GitHub addon**으로. keeper 개별 또는 MASC 전체에 "Connect GitHub" →
device flow OAuth → 토큰 주입.

**연관**: D2 (RFC-0000 §11), RFC-0008/0019 (retired/withdrawn — 같은 실수 안 하려 단순화), PR
#23528 (#24332에서 collateral delete)

---

## 1. 배경

### 1.1 요청

keeper 개별, 또는 MASC 전체(workspace)에 **GitHub addon**을 설정하고 싶다. dashboard에서
"Connect GitHub" 버튼 → OAuth device flow → 편하게 연결. GitHub 연결 자체가 특별한 게 아니라
addon 하나로, 나중에 다른 addon도 같은 자리에 올 수 있으면 좋겠다.

### 1.2 역사와 교훈

이 영역은 세 번 폐기/삭제됐다 — RFC-0008/0019(repo-identity 결합으로 retired/withdrawn),
PR #23528(Gate 리팩터터 collateral delete). 교훈: **무겁게 만들지 말 것**. plugin/module-type
framework, opaque interface 같은 과잉 추상화는 provider 1개일 때 부채만 만든다. 본 RFC는 GitHub
코드를 직접 짜고, 다른 addon이 실제로 생기면 그때 공통을 뽑는다(YAGNI).

### 1.3 HEAD 실측

- GitHub credential 코드 0건(`lib/keeper/credential_*`, `keeper_github_app_*` 부재).
- keeper는 ambient env에 의존(`Repo_git.run_git`은 credential 주입 안 함).
- **`keeper_secret_projection`이 이미 per-keeper + workspace(base) overlay를 제공한다** — 이게 본
  RFC의 핵심 기반이다(§2.3).

---

## 2. 설계

### 2.1 GitHub addon — `lib/credential/github_*` 직접

```
lib/credential/github/
  github_device_flow.ml(i)   (* device flow HTTP 상태머신 *)
  github_addon.ml(i)          (* Connect 시작/poll/revoke, scope 처리 *)
  dune
```

module type / registry / opaque interface **없음**. GitHub 코드를 직접 짠다. `lib/credential/`
경로는 V7l boundary guard(`scripts/check-boundary-guard.sh:235-244`) 범위 밖이라 adapter 위치로
허용된다. 두 번째 addon(예: GitLab)이 실제로 필요해지면 그때 공통 부분을 뽑는다.

### 2.2 Connect UX (device flow)

1. dashboard "Connect GitHub" 버튼 클릭(keeper detail view 또는 workspace settings).
2. backend가 `POST https://github.com/login/device/code`(`Masc_http_client.post_sync`, piaf+TLS)
   → `{device_code, user_code, verification_uri, expires_in, interval}`.
3. dashboard에 `user_code` + `verification_uri`(https://github.com/login/device) 표시 + 복사 버튼.
4. 사용자가 브라우저에서 승인.
5. backend polling `POST /login/oauth/access_token`(`interval`초, `authorization_pending` → 계속,
   `slow_down` → interval 증가, `expired_token` → 만료, 성공 → 토큰).
6. 토큰 획득 → `keeper_secret_projection`에 저장(§2.3).

**외부 선행**: `client_id` 필요(device flow 3 endpoint 전부 필수, RFC 8628). GitHub OAuth App 또는
GitHub App 등록 후 `MASC_GITHUB_OAUTH_CLIENT_ID` env 또는 `config/credentials.toml`에 주입. 이
`client_id` 없이 Phase 1의 실제 HTTP 호출이 실패한다.

### 2.3 scope — keeper 개별 OR MASC 전체 (기존 `secret_scope` 재사용)

사용자 요청 "keeper 개별 또는 masc 전체"는 `keeper_secret_projection.secret_scope`(`mli:11-13`)와
**1:1 매칭**:

| 사용자 의도 | `secret_scope` | 저장 위치 | 효과 |
|---|---|---|---|
| keeper 개별 | `Keeper_secret` | `.masc/secrets/<keeper>/env/GITHUB_TOKEN` | 해당 keeper만 |
| MASC 전체 | `Shared_secret` | `.masc/secrets/base/env/GITHUB_TOKEN` | 모든 keeper 상속 |

```ocaml
(* GitHub addon이 Connect 완료 시 호출 — 새 API 0, 기존 set_env_entry 재사용 *)
Keeper_secret_projection.set_env_entry
  ~base_path ~keeper_name
  ~scope:(if workspace_wide then Shared_secret else Keeper_secret)
  ~name:"GITHUB_TOKEN" ~value:access_token
```

**overlay 규칙**(`local_env_for_keeper`, `keeper_secret_projection.ml:862-869`): `base`(workspace)를
먼저 로드하고 `<keeper>`가 덮어쓴다. 따라서 **keeper-level이 workspace-level을 override**한다 —
workspace 전체 토큰 + 특정 keeper만 다른 계정이 자연스럽게 된다.

### 2.4 전파 — projection/scrub zero change

`local_env_for_keeper`: host env scrub(`:867`) → projected env overlay(`:868`). projected
`GITHUB_TOKEN`은 scrub 경로를 안 통과한다. `Env_keeper_scrub` allowlist 수정 불필요(이미 확인).
keeper process가 `GITHUB_TOKEN` 상속 → `git`/`gh` 자동 감지.

### 2.5 polling — per-Connect Eio fiber

`Connect GitHub` 클릭마다 poll fiber를 spawn, terminal(성공/만료/에러) 시 종료. HTTP route는
state file을 읽기만. 멱등: 같은 keeper의 non-terminal pending이 있으면 기존 id 반환(중복 발급 방지).

---

## 3. trade-offs

1. **8h token 만료**: GitHub App user access token은 8h. 장기 실행 keeper가 만료 시 `401`. Phase 3
   refresh fiber가 사전 갱신(선택). 또는 만료 긴 토큰 설정. **revocation**(사용자가 앱 권한 철회)은
   autonomous keeper가 자체 회복 불가 — dashboard가 "재연결 필요" 표시.
2. **선례 부재**: device-flow + per-agent GitHub identity를 구현한 하네스가 없다. 하지만 minimal
   설계라 위험 국소화.
3. **Linux plaintext**: `.masc/secrets/<keeper>/env/GITHUB_TOKEN` 0600. Keychain은 Linux 불가.
   cross-platform 경로 선택. 0600 + dir 0700 + symlink reject로 완화(이미 `set_env_entry` 강제).
4. **client_id 외부 선행**: 코드 외 작업(GitHub App 등록). Phase 1 전 확보 필요.

---

## 4. phasing

| Phase | 산출물 | test |
|---|---|---|
| 0 (본 RFC) | 이 문서 + D2 갱신 | RFC 게이트, 인덱스 일관성 |
| 1 | `github_device_flow.ml` + `github_addon.ml`(scope 처리) + projection 주입 | mock HTTP: pending→slow_down→authorized, expired_token, scope별 저장 위치(base vs `<keeper>`), overlay override |
| 2 | dashboard "Connect GitHub" widget + `/credentials/github/*` routes | Connect → poll → 연결; projected `GITHUB_TOKEN`이 keeper env에 나타남 |
| **D2 closure** | Phase 2 완료 시 | 운영자 dashboard Connect → plaintext 수정 없이 keeper git 인증 |
| 3 (optional) | refresh fiber + 8h 사전 갱신 | synthetic clock, 만료 전 refresh |

---

## 5. 비-목표

- **plugin/module-type framework** — 다른 addon이 실제로 생기면 그때 공통 추출(YAGNI).
- **installation token(bot attribution)** — user access token(device flow)만.
- **per-repo identity**(한 keeper가 repo마다 다른 계정) — keeper당/workspace당 단일 토큰.
- **at-rest 암호화** — Linux plaintext trade-off 수용.
- **`gh` subcommand risk classification 복구**(#24332 삭제) — 별도 이슈.
