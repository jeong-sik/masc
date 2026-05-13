---
rfc: "0074"
title: "Sandbox & Credential Auto-provision per Keeper Preset"
status: Draft
created: 2026-05-14
updated: 2026-05-14
author: vincent
supersedes: []
superseded_by: null
related: ["0005", "0006", "0019", "0070", "0073"]
implementation_prs: []
---

# Sandbox & Credential Auto-provision per Keeper Preset

## 1. Context

`Keeper_run_tools.prepare_agent_setup` (lib/keeper/keeper_run_tools.ml:96-127) 가 turn 시작 시점에 `turn_sandbox_factory`, `turn_sandbox_factory_git`, credential bundle 을 옵셔널 인자로 받는다. 현재 boot path (`lib/keeper/keeper_registry.ml`) 가 이들을 *자동 부착하지 않으므로*, coding preset 의 fs/bash/shell/pr 도구가 turn 시점에 `factory=None` 으로 실행 fail 한다.

RFC-0073 이 *gap 을 진단*한다면 이 RFC 는 *gap 을 닫는다*.

## 2. Problem

- preset (coding/research/social/...) 은 *어떤 자원이 필요한지* 를 implicit 하게만 안다 (`preset_allowlist` 의 tool 목록).
- sandbox/credential 부착은 caller 측 책임 — `register_keeper` 호출자가 각자 ad-hoc 으로 결정.
- 결과: dashboard 상 "허용 54" 와 실제 호출 가능한 도구 사이 항구적 gap.
- credential 부착은 *security surface* — 모든 keeper 에 자동 주입은 부적절. preset-aware 가 필요.

CLAUDE.md §워크어라운드 거부 기준 시그니처 #3 (N-of-M abstraction admission) 의 회피 대상.

## 3. Proposal — `resource_plan` per Preset

preset 마다 *어떤 sandbox 와 credential 이 필요한지* 를 *선언적*으로 declare. boot 시 plan 을 resolve 해서 keeper entry 에 attach.

### 3.1 신규 모듈

```ocaml
(* lib/keeper/keeper_resource_plan.mli *)
type resource_plan = {
  fs_sandbox: [ `Required | `Optional | `Forbidden ];
  bash_sandbox: [ `Required | `Optional | `Forbidden ];
  git_sandbox: [ `Required | `Optional | `Forbidden ];
  credentials: Tool_capability.credential_kind list;  (* RFC-0073 *)
}

val plan_of_preset : Preset.t -> resource_plan
(* exhaustive match on Preset.t — 신규 preset 추가 시 컴파일 catch. *)

val attach :
  base_path:string ->
  keeper:Keeper_registry.entry ->
  plan:resource_plan ->
  auto_provision_credentials:bool ->
  Keeper_registry.entry
```

### 3.2 매핑 (예시)

| Preset | fs | bash | git | credentials |
|---|---|---|---|---|
| Minimal | Forbidden | Forbidden | Forbidden | [] |
| Social | Forbidden | Forbidden | Forbidden | [Slack_token] |
| Coding | Required | Required | Required | [Github_token] |
| Research | Required | Optional | Forbidden | [Web_search_key] |
| Delivery | Required | Required | Required | [Github_token; Slack_token] |
| Full | Required | Required | Required | [Github_token; Slack_token; Web_search_key] |

### 3.3 Boot Path 통합

`Keeper_registry.register_keeper` 호출 직후:

```ocaml
let plan = Keeper_resource_plan.plan_of_preset meta.preset in
let auto_creds = Config.bool ~default:false "auto_provision_credentials" in
let entry = Keeper_resource_plan.attach
  ~base_path ~keeper:entry ~plan ~auto_provision_credentials:auto_creds
```

### 3.4 Opt-in Flag

credential 자동 주입은 *default off* (`auto_provision_credentials=false`). 운영자가 `config/tool_policy.toml` 의 `[runtime]` 섹션에서 `auto_provision_credentials = true` 로 활성화. sandbox 자동 부착은 default on (보안 surface 가 없음 — read-only sandbox factory 는 ambient 자원이 아니라 *factory 등록*).

### 3.5 Fail Mode

`Required` 자원이 부착 불가능하면 keeper boot 자체 fail (early & loud). `Optional` 은 미부착 허용 — RFC-0073 의 probe 가 dashboard 에 표시.

## 4. Code Changes

| 파일 | 변경 종류 | 추정 LOC |
|---|---|---|
| `lib/keeper/keeper_resource_plan.ml` + `.mli` | 신규 | ~180 |
| `lib/keeper/keeper_registry.ml` | boot path 통합 1곳 | ~20 |
| `config/tool_policy.toml` | `[runtime].auto_provision_credentials` 키 1 | ~3 |
| `test/test_keeper_resource_plan.ml` | preset × 자원 매핑 unit | ~100 |

## 5. Phases

| Phase | 범위 | 머지 조건 |
|---|---|---|
| 0 | `resource_plan` skeleton + `plan_of_preset` exhaustive | RFC-0073 Phase 0 머지 후 |
| 1 | `attach` 구현 (sandbox factory 부착) | 단위 테스트 통과 |
| 2 | boot path 통합 (default off for credentials) | local sangsu boot 시 fs/bash/git probe Ready 전환 |
| 3 | credential opt-in 활성화 (운영자 결정) | 보안 검토 통과 |

## 6. Verification

- (a) `dune build` 통과 — `plan_of_preset` exhaustive match 가드.
- (b) `dune exec test/test_keeper_resource_plan.exe` — preset 8개 × 자원 5개 매트릭스 검증.
- (c) sangsu (preset=coding) boot 후 `runtime_readiness.blocked` 가 (credential 자동 주입 off 기준) `keeper_pr_*` 만 포함, fs/bash/git 도구는 Ready.
- (d) `auto_provision_credentials=true` 설정 후 reboot → `runtime_readiness.blocked` 가 빈 배열.

## 7. Workaround Rejection Self-Check

- ❌ "fail 시 fallback dummy sandbox 부착" — Required 자원 부재 시 boot fail, dummy 금지
- ❌ env var grab-all credential 주입 — `credentials` 가 typed list, source 는 RFC-0019 unification 후 SSOT
- ❌ preset 매핑 catch-all `_ ->` — exhaustive 강제
- ❌ "이미 부착되어 있으면 silent skip" — `attach` 가 idempotent 하지만 *이미 부착됨* 사실은 telemetry event 로 ledger 기록
- ✅ structural: preset 이 자원 요구의 SSOT

## 8. Related RFCs

- RFC-0005 Typed Capability Substrate — sandbox 추상의 base
- RFC-0006 Keeper Tool Surface Realignment & Symmetric Sandbox — symmetric sandbox 모델의 confirm
- RFC-0019 Keeper Credential Unification — credential source 의 SSOT (이 RFC 의 선행 의존)
- RFC-0070 Keeper Sandbox Runtime — Pure/Edge Separation — sandbox lifecycle 추상
- RFC-0073 Tool Readiness Probe — gap 진단을 통한 boot fail mode 검증
