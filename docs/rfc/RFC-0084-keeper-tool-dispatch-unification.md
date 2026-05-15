---
rfc: "0084"
title: "Keeper→Tool Dispatch Unification + 100% Trace/Telemetry"
status: Draft
created: 2026-05-15
updated: 2026-05-15
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0064", "0070", "0072", "0080", "0081"]
implementation_prs: []
---

# RFC-0084 — Keeper→Tool Dispatch Unification + 100% Trace/Telemetry

## §0 Summary

masc-mcp Keeper→Tool 실행 사이클은 현재 **3개의 dispatch entry**가 서로 다른 권한·trace·telemetry 동작을 갖는다. 본 RFC는 단일 `Tool_dispatch.guarded_dispatch` entry로 수렴하면서 **모든 dispatch가 4-tuple `(Span, Audit, Metric, Trace_id)`을 100% emit하도록 invariant를 강제**한다. 14개의 stacked PR로 분할 진행한다 (1-2주 horizon).

### 0.1 North Star

> 모든 Keeper Tool 호출은 4-tuple `(Span, Audit, Metric, Trace_id)`을 100% emit하며, 같은 typed dispatch path를 통과하고, 같은 권한/제약 검증을 거치며, 같은 결과 schema로 LLM에 반환된다.

어떤 PR도 이 invariant를 *느슨하게* 만들면 거부.

### 0.2 비대칭 분류 (CLAUDE.md "경계 명시 원칙")

| 비대칭 종류 | 행동 |
|---|---|
| **결함** — 권한 게이트 0건, dead pre-hook chain, post-hook silent skip | 통일 (typed wrapper로 root-fix) |
| **의도된 경계** — OAS↔masc-mcp boundary, Public MCP vs Internal, Runtime lens carve-out | typed enumeration으로 명시 (통일 금지) |

본 RFC는 **결함은 통일, 경계는 명시**. 두 행동이 동시에 typed 방식으로 진행.

---

## §1 Problem (line-pinned, caller-context)

### §1.1 3-Entry Dispatch Divergence

masc-mcp `lib/tool_dispatch.ml`에는 2개의 entry function이 있고, `lib/keeper/keeper_tag_dispatch.ml`이 3번째 fallback entry를 형성한다. 각 entry가 서로 다른 caller를 받고 서로 다른 hook/guard를 적용한다.

**Entry 1 — `Tool_dispatch.dispatch`** (`lib/tool_dispatch.ml:117-130`):

```ocaml
let dispatch ~(token : Tool_token.t) ~args : Tool_result.t option =
  let name = token.name in
  match Hashtbl.find_opt registry name with
  | Some handler ->
    let start_time = Time_compat.now () in
    let result =
      try handler ~name ~args
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Some (Tool_result.of_exn ~tool_name:name ~start_time exn)
    in
    (match result with
     | Some tr -> Some (run_post_hooks tr)
     | None -> None)                          (* ⚠ post-hook NOT invoked *)
  | None -> None                              (* ⚠ silent miss *)
```

- Pre-hook 호출 0건.
- `None` 반환 시 post-hook 미호출 → audit/metric silent skip.
- Tool 미등록 시 silent `None`.

**Entry 2 — `Tool_dispatch.dispatch_structured`** (`lib/tool_dispatch.ml:140-145`):

```ocaml
let dispatch_structured ~(token : Tool_token.t) ~args : Tool_result.t option =
  let name = token.name in
  match run_pre_hooks ~name ~args with
  | (Some _ as blocked, _) -> blocked
  | (None, coerced_args) -> dispatch ~token ~args:coerced_args
```

- Pre-hook → handler → post-hook 체인.
- **caller 0건** (`rg -n 'dispatch_structured' lib/ bin/`은 정의 파일 외 0 매치). 즉 dead.

**Entry 3 — `Keeper_tag_dispatch`** (`lib/keeper/keeper_tag_dispatch.ml`):

- `Tool_name.t`에 없는 tool (e.g. `masc_keeper_sandbox_status/start/stop`, `masc_keeper_msg_result`)을 runtime tag-registry로 fallback.
- `static_tag_of_tool_name`의 `Masc.m` 일부 variant가 `None` 반환 (`tool_dispatch.ml:213+`) → tag-registry fallback 경유.

**Caller 분포**:

| Caller | Entry | Pre-hook | Post-hook | Capability gate | Trace span |
|---|---|---|---|---|---|
| `keeper_exec_masc.ml:164` (keeper turn) | Entry 1 (`dispatch`) | ✗ bypass | ~ if result≠None | ✗ unrestricted¹ | ✗ |
| `keeper_exec_masc.ml:218` (keeper turn) | Entry 1 (`dispatch`) | ✗ bypass | ~ if result≠None | ✗ | ✗ |
| `mcp_server_eio_execute.ml:817` (MCP) | manual `run_pre_hooks` + `dispatch` | ✓ manual | ~ if result≠None | ‖ profile filter² | ✗ |
| `mcp_server_eio_execute.ml:999` (MCP) | manual `run_pre_hooks` + `dispatch` | ✓ manual | ~ if result≠None | ‖ profile filter² | ✗ |
| `keeper_tag_dispatch.ml` (fallback) | Entry 3 | ✗ | ? | ✗ | ✗ |

¹ `capability_registry.ml:358-362` 코멘트가 명시: *"Internal dispatch (`Tool_dispatch.dispatch`) remains unrestricted. The public MCP surface is now filtered at the profile level."*

² `Mcp_server_eio_tool_profile.tool_schemas_for_profile`이 `Tool_catalog.is_public_mcp` 적용으로 ~34 tools로 축소. 그러나 *capability gate*는 0건.

### §1.2 Telemetry 4-Tuple Emission Gap

`Tracing.with_span`은 oas `lib/agent/agent_tools.ml:161 invoke_hook`에서 hook 호출을 wrap하지만, **masc-mcp `lib/tool_dispatch.ml`이나 `lib/keeper/keeper_exec_masc.ml`에 0건** (verify: `rg -n 'Tracing\.with_span' lib/tool_dispatch.ml lib/keeper/keeper_exec_masc.ml` = 0 매치).

| Tuple slot | 현재 상태 |
|---|---|
| `Span` (OTel) | 0 emission. `lib/otel/otel_dispatch_hook.ml:103` 등록만 있고 span 시작/종료 없음. |
| `Audit` | `Audit_log.record` caller 10+곳 분산 (`dashboard_tool_host_events`, `governance_anomaly`, `mcp_server_eio_call_tool`, `mcp_server_eio_execute`, `operator/operator_control`, `tool_inline_dispatch_comm` 등). dispatch path에서 SSOT 없음. |
| `Metric` | `tool_metrics.install` (`lib/tool_metrics.ml:127`)가 post-hook으로 등록하지만 `dispatch:127-129`가 handler `None` 반환 시 post-hook 미호출 → metric silent skip. `Prometheus.inc_counter` 직접 호출은 `keeper_tool_disclosure.ml:480` 1건뿐. |
| `Trace_id` | propagation 메커니즘 0. LLM turn ↔ tool call ↔ side-effect 연결 단절. |

### §1.3 Surface Coverage Gap

`lib/keeper/tool_resolution.ml:81-86`의 `surfaces_to_check`는 8 variant 중 4개만 포함:

```ocaml
let surfaces_to_check =
  [ Tool_catalog_surfaces.Public_mcp
  ; Tool_catalog_surfaces.Spawned_agent
  ; Tool_catalog_surfaces.Local_worker
  ; Tool_catalog_surfaces.Admin
  ]
```

누락: `Session_min`, `Keeper_internal`, `Keeper_denied`, `System_internal`. 코드 주석 0. 의도된 정책인지 누락인지 불명.

`tool_resolution.ml:143-149`의 `all_admitting_sources`에서도 같은 4 surface만. RFC-0080 §2 architecture diagram에 "only 4 checked at policy boundary"라 명시되어 있지만 *왜* 4인지는 미설명.

### §1.4 Boot Policy ↔ Runtime Routing Split-Brain

| 경로 | 진입점 | 사용 sources |
|---|---|---|
| Boot policy load | `keeper_tool_policy_config.ml:229` `Tool_resolution.is_known_policy_tool_name` | 13 sources OR (via `Tool_resolution.resolve`) |
| Runtime route | `keeper_tool_disclosure.ml` (842줄) | `strip_mcp_masc_prefix` → `Keeper_tool_alias.public_masc_to_internal` → `route` → `is_known_internal` |

두 경로가 일부 source는 공유하지만 *서로 다른 admission decision*을 내릴 수 있다. RFC-0080 §1 명시: production 1 boot window에서 540 lines `is not registered` warn + 88 distinct names 발생, 그 중 다수는 runtime dispatch 정상 (`tool_call tool=masc_code_git outcome=ok` co-exists with `groups.coding: tool 'masc_code_git' is not registered`).

### §1.5 Macro-portability Gap (P0)

keeper→tool 실행이 *macOS 운영자 workstation의 특정 디렉토리 layout*에 결합되어 있다.

| 코드 | 사이클 단계 | binding |
|---|---|---|
| `lib/keeper/host_config_provider.ml:3` | guard (cred env) | `let cred_root = "/tmp/keeper-creds"` (4× references) |
| `lib/keeper/keeper_shell_bash.ml:745, 802` | dispatch (bash family) | `[ "/bin/bash"; "-lc"; cmd ]` |
| `lib/keeper/keeper_exec_preflight.ml:24-43`, `keeper_gh_shared.ml:217`, `keeper_tool_pr_review.ml:192` | dispatch (gh family) | `[ "/bin/zsh"; "-lc"; ... ]` 5 sites |
| `lib/keeper/keeper_shell_ops.ml:339,387,661,702,746` | dispatch (shell ops) | `"/bin/ls"`, `"/bin/cat"`, `"/bin/pwd"`, `"/usr/bin/head"`, `"/usr/bin/tail"`, `"/usr/bin/wc"` 6 sites |
| `lib/tool_inline_dispatch_coord.ml:185-187, 267-268`, `mcp_server_eio_execute.ml:191, 210, 253, 331, 570` | persistence (agent identity) | `Printf.sprintf "/tmp/.masc_agent[_mcp]_%s" sid` **7 sites**. `TERM_SESSION_ID` 없으면 `"default"` silent collision |
| `lib/worker_dev_tools.ml:85` | dispatch (Fleet worker) | `Filename.concat home "me"` — 사용자별 binding |
| `lib/coord/coord_utils_backend_setup.ml:103`, `config_dir_resolver.ml:59`, `env_config_core.ml:353`, `cdal/adversarial_eval.ml:294, 301` | test-mode auto-detection | `String.starts_with ~prefix:"test_" executable` 5 sites — 보안 risk (binary rename으로 test mode silently 진입) |

NixOS/Alpine/Linux server에서 silent fail.

### §1.6 Dormant Hybrid Disclosure Infrastructure

OAS측 `Tool.disclosure_level` Hybrid + `Disclosure_resolver`는 `lib/pipeline/stage_parse.ml:42-46` + `lib/pipeline/pipeline_stage_prepare.ml:109-115` wired (since 0.194.0). 그러나 masc-mcp `worker_oas.ml`(886줄)에서 **caller 0** (`rg -n 'with_disclosure_level\|with_disclosure_resolver\|imseonghan' lib/ bin/` = 0).

→ 모든 keeper tool은 현재 Full_schema 단일 사이클. RFC-OAS-013 §1.3 경고가 정확히 main에 실현됨.

### §1.7 Workaround Rejection Signature 매핑 (CLAUDE.md §워크어라운드 거부 기준)

| 시그니처 | 현재 코드에 있는 hit |
|---|---|
| **#2 String/substring classifier** | `keeper_internal_tools` 32-entry string list (`tool_catalog_surfaces.ml:28-96`) + `Tool_dispatch.registry : (string, handler) Hashtbl.t`. 두 repo 횡단 동일 anti-pattern. |
| **#2 Prefix-gated** | `String.starts_with ~prefix:"masc_"` (`mcp_server_eio_tool_profile.ml:296`), `String.starts_with ~prefix:"test_"` 5 sites |
| **Unknown → Permissive Default** | `Option.value ~default:"default" (Sys.getenv_opt "TERM_SESSION_ID")` (`tool_inline_dispatch_coord.ml:186, 266`) → silent identity collision |
| **#1 Scattered hardcoded default** | `/tmp/.masc_agent[_mcp]_<sid>` 7 sites, `/bin/zsh` 5 sites, `.masc-ide` 4 sites |
| **Telemetry-as-fix** | Counter without fix는 본 RFC가 자체 안 함 — 4-tuple emission은 typed Outcome이 *fix*된 결과. counter는 alarm이 아닌 invariant check. |

본 RFC §8의 self-check가 이 매핑을 명시적으로 점검.

---

## §2 Invariants (모든 PR 만족 필수)

### §2.1 Telemetry 4-Tuple Invariant

모든 tool dispatch는 다음 4가지를 *반드시* emit:

| Tuple slot | Contract | 누락 시 결과 |
|---|---|---|
| `Span` | `Tracing.with_span ~kind:Tool_dispatch ~name ~tool_id ~trace_id` open/close pair | trace 단절 — root cause 추적 불가 |
| `Audit` | `Audit_log.record ~event:Tool_dispatched ~outcome ~keeper_id ~tool_id` | audit gap — 어떤 keeper가 무엇을 호출했는지 미상 |
| `Metric` | `Prometheus.inc_counter tool_dispatch_total{outcome,tool,surface}` | dashboard 0 — alert 미발화 |
| `Trace_id` | LLM turn에서 시작된 `Trace_id.t`가 handler에 전달 + result에 stamp | turn ↔ tool ↔ side-effect 연결 단절 |

PR-14 property test가 100 random tool calls × 모든 entry path에 대해 4-tuple emission count = 4 × 100 = 400임을 검증.

### §2.2 Single Dispatch Path Invariant

- *모든* keeper-originated 호출 → `Tool_dispatch.guarded_dispatch` (PR-3 신설)
- *모든* MCP-originated 호출 → `Tool_dispatch.guarded_dispatch` (같은 entry)
- *모든* tag-dispatch fallback → `Tool_dispatch.guarded_dispatch` (같은 entry)
- *0 caller*는 `dispatch` / `dispatch_structured` / `run_pre_hooks` 직접 호출 (PR-11에서 제거)

PR-14 CI lint `ci/lint-no-direct-dispatch.sh`가 강제.

### §2.3 Typed Boundary Invariant

- **Tool 이름** → `Tool_name.t` (exhaustive over all dispatched tools, PR-2)
- **Capability** → `Capability.t` typed sum + Set (PR-4). 5개 `(string, unit) Hashtbl.t`를 collapse.
- **Dispatch outcome** → `Dispatch_outcome.t = Handled | Rejected_by_capability | Rejected_by_pre_hook | No_handler | Handler_error` (5-arm exhaustive, PR-10)
- **Surface** → `Tool_catalog_surfaces.surface` 8 variant 모두 enumerated (PR-5)
- **Host config** → `Host_config.t` typed record (PR-12)
- **Disclosure strategy** → `disclosure_strategy` typed (PR-13)

### §2.4 Surface 경계 Invariant (의도된 경계 명시)

| 경계 | 코드에 typed enumeration 필수 |
|---|---|
| **OAS Agent SDK ↔ masc-mcp keeper runtime** | masc-mcp의 oas usage는 `Worker_oas` 단일 module에 집중. 역방향 의존 0. (RFC-OAS-011 + SDK Independence Gate strict mode 이미 강제) |
| **Public MCP ↔ Internal** | `Surface.Public_mcp` vs 그 외. 같은 dispatch path, 다른 capability set. |
| **Runtime lens (외부 `"runtime"` placeholder vs 내부 real provider)** | `lib/cascade/cascade_catalog_runtime.candidate_probe_to_yojson` + `cascade_legacy_runner.cascade_attempt_to_json` carve-out — typed surface로 명시. 메모리 `reference_runtime_lens_boundary_carve_out`. |
| **Boot policy ↔ runtime route** | 같은 `Tool_resolution.resolve` 결과를 *재사용*. 두 번 결정하지 않음 (PR-6). |

---

## §3 Type Design

### §3.1 `Tool_name.t` Exhaustive (PR-2)

```ocaml
(* lib/tool_name.ml — 추가 variants *)
type t =
  | Keeper of keeper
  | Masc of masc
  | Masc_keeper of masc_keeper          (* 새로 enumerate *)
  | Dynamic_test of string              (* test-only fallback, PR-9 *)
  ...

and masc_keeper =
  | Sandbox_start | Sandbox_stop | Sandbox_status
  | Msg_result
  ...
```

`static_tag_of_tool_name`이 `Masc.m`의 모든 variant에 대해 `Some _` 반환 (현재 `None` 반환 variants 제거 또는 명시적 module_tag 부여).

### §3.2 `Capability.t` (PR-4)

```ocaml
(* lib/keeper/capability.ml — new *)
type kind =
  | Read_only
  | Requires_join
  | Mcp_context_required
  | Destructive
  | Idempotent

type t = { kind : kind; override : string option }

val of_tool_name : Tool_name.t -> t list
val required_for_keeper : Keeper_id.t -> t list
val gate : required:t list -> granted:Set.t -> [`Pass | `Reject of string]
```

5개 `(string, unit) Hashtbl.t`를 collapse. 결정 D1 (plan §6)에 따라 hybrid (per-domain + per-tool override).

### §3.3 `Dispatch_outcome.t` (PR-10)

```ocaml
(* lib/dispatch_outcome.ml — new *)
type t =
  | Handled of Tool_result.t
  | Rejected_by_capability of { tool : Tool_name.t; missing : Capability.t list }
  | Rejected_by_pre_hook of { tool : Tool_name.t; reason : string }
  | No_handler of { tool_name_raw : string; tried_sources : Tool_resolution.tried_source list }
  | Handler_error of { tool : Tool_name.t; exn : exn; backtrace : string }
```

Post-hook signature: `Dispatch_outcome.t -> Dispatch_outcome.t`. 5 post-hook site 모두 5-arm exhaustive match (`tool_output_validation:65`, `tool_usage_log:272`, `tool_metrics:127`, `otel_dispatch_hook:103`, `server_bootstrap_loops:968`).

### §3.4 `Host_config.t` (PR-12)

```ocaml
(* lib/keeper/host_config.ml — new *)
type t = {
  cred_root : string;          (* was hardcoded "/tmp/keeper-creds" *)
  host_bash : string;          (* PATH-resolved *)
  host_zsh  : string;          (* PATH-resolved *)
  host_sh   : string;          (* PATH-resolved *)
  coreutils : coreutils;       (* PATH-resolved bundle *)
  agent_runtime_root : string; (* was "/tmp/.masc_agent_*" — now <base>/.masc/runtime/agent/ *)
  sandbox_workspace_root : string; (* was "$HOME/me" — config-driven *)
}

and coreutils = {
  ls : string; cat : string; pwd : string;
  head : string; tail : string; wc : string;
}

val resolve : base_path:string -> (t, string) result
val test_mode_token : t -> Test_mode_token.t  (* PR-12: replaces String.starts_with "test_" *)
```

### §3.5 `disclosure_strategy` (PR-13)

```ocaml
(* lib/keeper/keeper_meta.ml — additions *)
type disclosure_strategy =
  | Full
  | Hybrid of { core_tools : string list }
  | Minimal_index_with_demote_on_error

(* TOML schema:
   [disclosure]
   strategy = "hybrid"
   full_names = ["keeper_bash", "keeper_fs_edit"]
   demote_on_error = true
*)
```

RFC-OAS-013 §2.1 v2의 `if meta.name = "imseonghan"` 패턴 거부. 대신 *config-driven*.

---

## §4 Stacked PR Plan — 14 PR

요약 표. line-pinned 세부사항은 plan file `/Users/dancer/.claude/plans/serene-prancing-iverson.md` §3.

| PR | Branch | Base | 핵심 변경 | Risk | LoC |
|---|---|---|---|---|---|
| **PR-1** | `feature/rfc-0083-pr-1-rfc-doc-audit` | `main` | RFC 본문 + 3 pinned-fail tests | low | 400-600 |
| PR-2 | `pr-2-tool-name-exhaustive` | PR-1 | `Tool_name.t` exhaustive | med | 250-400 |
| PR-3 | `pr-3-guarded-dispatch-skeleton` | PR-2 | `Tool_dispatch.guarded_dispatch` + `Tool_telemetry` SSOT (4-tuple wrapper) | low | 400-600 |
| PR-4 | `pr-4-typed-capability` | PR-3 | `Capability.t` typed | med | 350-550 |
| PR-5 | `pr-5-surface-coverage` | PR-4 | `surfaces_to_check` 4 → 8 | med | 200-350 |
| PR-6 | `pr-6-resolver-unify` | PR-5 | Boot ↔ runtime resolver SSOT (24h shadow) | **high** | 450-650 |
| PR-7 | `pr-7-keeper-guarded` | PR-6 | keeper turn → `guarded_dispatch` (log-only mode) | **high** | 250-400 |
| PR-8 | `pr-8-mcp-guarded` | PR-7 | MCP server → `guarded_dispatch` | med | 150-250 |
| PR-9 | `pr-9-tag-dispatch-guarded` | PR-8 | tag-dispatch fallback → `guarded_dispatch` | med | 200-350 |
| PR-10 | `pr-10-dispatch-outcome-total` | PR-9 | `Dispatch_outcome.t` 5-arm + post-hook total | med | 350-500 |
| PR-11 | `pr-11-legacy-removal` | PR-10 | `dispatch`/`dispatch_structured`/`MASC_DISPATCH_V2` 제거 | low | 150-250 |
| PR-12 | `pr-12-host-config-portability` | PR-11 (PR-1 parallel) | `Host_config.t` + 하드코드 11곳 일소 | med | 600-900 |
| PR-13 | `pr-13-disclosure-activation` | PR-12 | RFC-OAS-013 config-driven activation | med | 400-600 |
| PR-14 | `pr-14-telemetry-completeness` | PR-13 | Property test + CI lint + RFC closeout | low | 350-500 |

전체 LoC: 4,000-6,400 across 14 PRs.

**Critical decision points** (plan §6 참조):
- D1 (PR-2 land 전): `Capability.t` granularity → hybrid (per-domain + per-tool override) 권고
- D2 (PR-5 land 전): `Keeper_denied` semantics → policy gate excluded + typed enum 권고
- D3 (PR-10 land 전): `Dispatch_outcome.t` arm 수 → 5-arm 권고

---

## §5 Migration + Rollback

| PR | Migration | Rollback |
|---|---|---|
| PR-2 | exhaustive match 컴파일러 강제 → 모든 caller 일제 갱신 | single-PR revert |
| PR-3 | new entry, caller 변경 0 | single-PR revert |
| PR-4 | parity test: 기존 5 set 모든 admit이 typed Capability로 동일 결과 | single-PR revert |
| PR-5 | boot warn 540 → 0 측정 | revert + 4-variant 복귀 |
| PR-6 | **24h shadow mode**: both paths 동시 실행, divergence log. 0 divergence면 PR-7 진행 | single-PR revert |
| PR-7 | **Pre-hook log-only mode 1 deploy cycle** → enforce. Capability gate advisory mode 처음 24h | `keeper_exec_masc.ml` 2-line revert |
| PR-8~9 | 동일 path 적용 | single-PR revert |
| PR-10 | post-hook signature 변경 5 site 일제 (compile-time 강제) | single-PR revert |
| PR-11 | dead code 제거 (PR-7~10 후) | single-PR revert (cherrry-pick) |
| PR-12 | macOS+Linux dual host CI matrix | single-PR revert |
| PR-13 | keeper TOML schema bump, 기본값 `Full` (no-op) | TOML revert |
| PR-14 | property test + dashboard + closeout | single-PR revert |

---

## §6 Test Strategy

### §6.1 Pinned Tests (PR-1)

본 PR에 추가되는 3 test가 *현재 telemetry/surface/pre-hook gap*을 measurable evidence로 픽스. PR-5/7/9에서 *기대값 갱신*과 함께 fail → pass 전환.

| Test | 현재 측정값 | PR-X에서 갱신 |
|---|---|---|
| `test_dispatch_telemetry_gap.ml` | 4-tuple emission count vs dispatch count → gap | PR-9 (모든 3 entry가 `guarded_dispatch`로 통합 후 100%) |
| `test_surface_coverage_gap.ml` | `surfaces_to_check` size = 4 | PR-5 (8로 확장) |
| `test_keeper_prehook_gap.ml` | keeper turn pre-hook invocation count = 0 | PR-7 (> 0) |

### §6.2 Parity Test (PR-6)

```ocaml
(* test/test_dispatch_disclosure_parity.ml *)
let () = QCheck.Test.check_exn @@ QCheck.Test.make
  ~name:"boot_decision = runtime_decision"
  ~count:1000
  (QCheck.string)
  (fun tool_name ->
    let boot = Keeper_tool_policy_config.is_known_policy_tool_name tool_name in
    let runtime = Keeper_tool_disclosure.runtime_decision tool_name in
    Bool.equal boot (decision_to_bool runtime))
```

### §6.3 Shadow Mode (PR-6 → PR-7)

PR-6 merge 후 24h:
1. 새 unified resolver와 legacy disclosure routing 둘 다 실행
2. Result divergence를 `Audit_log.record ~event:Shadow_divergence`로 기록
3. 24h 무 divergence 확인 후 PR-7 진행

### §6.4 Property Test (PR-14)

```ocaml
let () = QCheck.Test.check_exn @@ QCheck.Test.make
  ~name:"every_dispatch_emits_4_tuple"
  ~count:100
  arbitrary_tool_call
  (fun (entry, tool, args) ->
    let before = Telemetry_probe.snapshot () in
    let _outcome = Tool_dispatch.guarded_dispatch ~entry ~tool ~args in
    let after = Telemetry_probe.snapshot () in
    Telemetry_probe.delta before after = { span = 1; audit = 1; metric = 1; trace_id = 1 })
```

기대값: 100 calls × 4-tuple = 400 emissions. 누락 0.

---

## §7 Deferred (이 sprint 밖)

| 항목 | 이유 |
|---|---|
| **RFC-0080 Phase 3** (13 source pruning) | Multi-sprint. 각 source ownership audit 필요. 본 sprint는 typed shim 유지하고 Phase 3은 별도 RFC. |
| **oas RFC-OAS-013 closeout** (`resolve_disclosure_level` dedup) | oas repo의 SDK Independence Gate + Draft Auto-Merge Guard. 별도 track. |
| **Keeper sub-library extraction** | Memory `project_keeper_sublib_extraction_analysis`: 189↔118 cycle. 본 sprint는 typed boundary *준비*. |
| **TLA+ spec for new dispatch FSM** | CLAUDE.md TLA+ Bug Model. Property test (PR-14)가 1차 안전선. TLA+ spec은 다음 RFC. |
| **MCP `_meta` field로 descriptor 전달** | RFC-OAS-012 영역. masc-mcp 변경 0. |

---

## §8 Workaround-Rejection Self-Check (CLAUDE.md §워크어라운드 거부 기준)

본 RFC의 14 PR이 다음 시그니처에 해당하지 않음을 명시:

| 시그니처 | 해당? | 회피 방법 |
|---|---|---|
| **#1 Telemetry-as-fix** (counter without fix) | ✗ | 4-tuple invariant는 *side-effect*가 typed `Dispatch_outcome`으로 *fixed*된 결과. counter는 alarm이 아닌 invariant check (PR-14 property test가 강제). |
| **#2 String/substring classifier** | ✗ | PR-2 (typed `Tool_name`), PR-4 (typed `Capability`), PR-10 (typed `Dispatch_outcome`)으로 *모든 string 분류기 제거* |
| **#2 Prefix-gated test-mode** | ✗ | PR-12에서 `String.starts_with "test_"` 5 sites → `Test_mode_token.t` typed |
| **#3 N-of-M patch** | ✗ | RFC가 *모든* dispatch entry 일제 unify. 부분 patch 0. |
| **Cap/Cooldown/Dedup/Repair** | ✗ | 해당 패턴 도입 0. 모든 변경이 root-fix. |

각 PR body에 자체 self-check 포함 (PR template).

---

## §9 References

### 9.1 코드 (line-pinned)

- `lib/tool_dispatch.ml:117-130` — `dispatch` (Entry 1)
- `lib/tool_dispatch.ml:140-145` — `dispatch_structured` (Entry 2, dead)
- `lib/tool_dispatch.ml:32` — `registry : (string, handler) Hashtbl.t`
- `lib/tool_dispatch.ml:79-80` — `pre_hooks` / `post_hooks` refs
- `lib/tool_dispatch.ml:127-129` — handler `None` → silent skip
- `lib/tool_dispatch.ml:149` — `MASC_DISPATCH_V2` flag
- `lib/tool_dispatch.ml:159-163` — 5 `(string, unit) Hashtbl.t` capability sets
- `lib/tool_dispatch.ml:197-213+` — `module_tag` typed sum + `static_tag_of_tool_name`
- `lib/keeper/tool_resolution.ml:56-103` — `resolve` 13-source short-circuit
- `lib/keeper/tool_resolution.ml:81-86, 143-149` — `surfaces_to_check` 4 variants
- `lib/keeper/keeper_tool_disclosure.ml` (842 lines) — runtime routing
- `lib/keeper/keeper_exec_masc.ml:164, 218` — keeper turn `dispatch` direct
- `lib/keeper/capability_registry.ml:358-362` — "Internal dispatch unrestricted" 코멘트
- `lib/mcp_server_eio_execute.ml:817, 999` — manual `run_pre_hooks` + `dispatch`
- `lib/keeper/keeper_tag_dispatch.ml` — Entry 3 fallback
- `lib/keeper/host_config_provider.ml:3` — `/tmp/keeper-creds`
- `lib/keeper/keeper_shell_bash.ml:745, 802` — `/bin/bash`
- `lib/tool_inline_dispatch_coord.ml:185-187, 267-268`, `mcp_server_eio_execute.ml:191-570` — `/tmp/.masc_agent[_mcp]_<sid>` 7 sites
- `lib/worker_oas.ml` (886 lines) — disclosure activation 대상

### 9.2 분석 보고서 (`~/me/.tmp/keeper-tool-cycle-audit/`)

- `00-primary-synthesis.md` (608줄, 1차 합성)
- `03-hardcode-path-audit.md` (183줄, agent #3 결과)
- `04-final-report.md` (240줄, 최종 합성)

### 9.3 관련 RFC

- RFC-0042 keeper terminal code closed sum
- RFC-0064 two-surface tool alias
- RFC-0070 keeper sandbox pure-edge separation
- RFC-0072 keeper sub-FSM transitions typed
- RFC-0080 tool registry SSOT (Phase 3 deferred)
- RFC-0081 telemetry envelope and pivot timeline

### 9.4 관련 OAS RFC (read-only consumer)

- RFC-OAS-008 typed tool identification (oas measured 머지)
- RFC-OAS-009 v2 sever core→CDAL deps (oas PR-B 머지)
- RFC-OAS-011 CDAL → masc-mcp migration (완료)
- RFC-OAS-013 keeper tool disclosure activation (PR-13에서 활성화)

### 9.5 메모리

- `reference_runtime_lens_boundary_carve_out` — 외부 placeholder vs 내부 real lens
- `feedback_user_rejects_cron_pr_loop` — Draft + human-approved-ready label
- `feedback_masc_mcp_draft_guard_blocks_agent_ready` — agent ready 자동 차단
- `feedback_keeper_tool_alias_3_tier_is_overengineered` — 공용 도구 이름 1st-class
- `feedback_lint_string_classifier_is_workaround_not_fundamental` — string classifier 자체 거부
- `feedback_rfc_number_reservation_needed` — RFC 번호 race 사고

### 9.6 Plan file

`/Users/dancer/.claude/plans/serene-prancing-iverson.md` (~530줄) — 14 PR sequence, dependency graph, risk matrix, cadence, exit criteria 1-10.

---

## §10 Exit Criteria

본 RFC 완료 (모든 14 PR 머지 + exit criteria 만족) 시점에 plan file §13 1-10 모두 만족:

1. 14 PR 모두 머지 (Draft → `human-approved-ready` → squash merge)
2. `test_telemetry_completeness` property test green (4-tuple emission 100%)
3. `ci/lint-no-direct-dispatch.sh` green
4. Production 24h window `is not registered` warn 0
5. `disclosure_strategy` config 적용 keeper 1+
6. Grafana dashboard 4-tuple emission tile 100% 유지 24h
7. RFC-0084, RFC-0080, RFC-OAS-008/009 v2/011/013 모든 `implementation_prs` field 채워짐
8. B1, B2, B4, B5, B6, B7, B8, B10, B12, B13 close (10/13 bugs)
9. B3 (Phase 3 source pruning) — 다음 sprint escalate
10. B11 (oas closeout) — oas repo 별도 track escalate
