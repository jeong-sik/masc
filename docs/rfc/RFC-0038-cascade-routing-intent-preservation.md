# RFC-0038: Cascade Routing Intent Preservation

> **Status**: Draft
> **Authors**: vincent (with Claude)
> **Created**: 2026-05-07
> **Related RFCs**: RFC-0001 (det/nondet boundary — silent substitution anti-pattern), RFC-0024 (ollama cascade integration), RFC-0026 (work-conserving keeper admission), RFC-0027 (capability-typed cascade catalog) — RFC-0027 §3.4 PR #3 + PR #4 의 specification 을 가속화/구체화한다.
> **Anchor commit**: `065e568be1` (PR #11210, 2026-04-27 — cross-cascade fallback 도입)

## 1. Summary

Cascade routing layer 가 사용자가 cascade.toml 에 명시한 model intent 와 무관한 모델을 silently 호출한다. 5월 1-6일 audit 에서 2,620 turns 중 254 turns (9.69%) 가 `configured_labels` 와 `candidate_models` 가 disjoint 한 silent substitution 을 겪었다. ollama 는 22번 의도된 후보로 등장했지만 실제로 1번만 실행됐다 (4.5% intent-realization rate).

본 RFC 는 이 문제를 단일 패치가 아니라 **3-layer compounding failure** 로 진단하고 layer 별 invariant 와 fix sequence 를 정의한다.

- **L0 — Default-deny cross-cascade fallback**: cascade fallback 은 toml 의 explicit `fallback_cascade` chain 으로만 표현. 코드의 cross-cascade resolver 는 default-disabled, env flag 로 legacy mode 만 유지.
- **L1 — Dynamic capability classification**: Provider capability 를 정적 record 가 아니라 model-id 별 probe + pattern table 로 분류. modern ollama 모델 (gemma4-, qwen3-, llama3.1+) 의 native function-calling 지원이 false negative 로 묻히지 않게 한다.
- **L4 — Audit substitution visibility**: substitution 이 일어나면 cascade observation 에 `substituted_from_cascade`, `substitution_reason` 필드를 기록. RFC-0001 §"표현" axis 직접 충족.

L2 (transport keeper-identity gap) 와 L3 (permission-aware filtering) 는 본 RFC 에서 invariant 만 선언하고 구현은 후속 RFC 로 분리한다.

## 2. Motivation

### 2.1 사고 정량 (2026-05-01 ~ 2026-05-06)

데이터 소스: `~/me/.masc/cascade_audit/2026-05/0[1-6].jsonl`

| 측정 | 값 |
|------|----|
| 총 turn 수 | 2,620 |
| Substitution (configured ∩ candidate = ∅) | **254 (9.69%)** |
| 영향 keeper 종 | 17 (fleet-wide, 단일 keeper 한정 아님) |
| ollama configured attempts | 22 |
| ollama actually selected_model | **1** (4.5% intent-realization) |

**Substitution 분포 — top 5 cascade**:

| Cascade | Substitutions |
|---------|---------------|
| `big_three` | 108 |
| `glm_coding_plan_only` | **100/100 (100%)** — 별개 namespace mismatch bug |
| `local_test` | 20/21 (95%) |
| `tier_fast` | 18 |
| `keeper_bound_safe` | 7 |

**Substitution 후 실패 원인 — top 4**:

| Reason | Count |
|--------|-------|
| (substitution 후 성공 / no top_level_reason) | 179 |
| Rate limited | 52 |
| `Invalid request: You do not have permission to access glm-5-code` | 14 |
| Per-provider timeout (120s/180s) | 6 |

### 2.2 RFC-0001 위반

`docs/rfc/RFC-0001-det-nondet-boundary-harness.md:92-96`:

```text
heuristic / LLM parse miss
  -> silent fallback or low-visibility substitution
  -> Thompson / reputation / routing bias
  -> stressed agent gets harder conditions
```

`docs/rfc/RFC-0001-det-nondet-boundary-harness.md:159-162`:

| axis | 안티패턴 | 처방 |
|------|---------|------|
| 표현 | silent fallback, generic substitution | agent 가 difficulty/stress 를 broadcast 로 표현 가능 |

본 RFC 의 L0 + L4 는 위 처방의 직접 구현이다.

### 2.3 Root cause path

`lib/oas_worker_named.ml:193-197` — `require_tool_support` 가 keeper-internal MCP tools 보유 시 자동 true 로 승격:
```ocaml
let require_tool_support =
  require_tool_support
  || keeper_internal_tools_require_materialized_runtime_surface
       ~keeper_name tools
in
```

`lib/oas_worker_named.ml:237-247` — filter call:
```ocaml
let candidate_cfgs =
  filter_candidate_providers_for_tool_support
    ~keeper_name ?runtime_mcp_policy ~tools
    ~require_tool_choice_support ~require_tool_support
    ?secondary_resolver ~label:cascade_name
    candidate_cfgs
in
```

`lib/oas_worker_named.ml:270-312` — 빈 후보일 때 cross-cascade fallback (silent swap path):
```ocaml
let candidate_cfgs =
  match candidate_cfgs with
  | [] ->
      (match resolve_tool_capable_provider_across_cascades
              ~exclude_cascade:cascade_name ()
       with
       | Some (source_cascade, provider_cfg) ->
           Llm_metric_bridge.emit_fallback_triggered
             ~kind:"cross_cascade"
             ~detail:(Printf.sprintf "%s->%s" cascade_name source_cascade);
           [provider_cfg]
       | None -> [])
  | _ -> candidate_cfgs
in
```

지원 함수들:
- `lib/oas_worker_named_cascade.ml:106` — `keeper_internal_tools_require_materialized_runtime_surface`
- `lib/oas_worker_named_cascade.ml:379` — `filter_candidate_providers_for_tool_support`
- `lib/oas_worker_named_cascade.ml:473` — `resolve_tool_capable_provider_across_cascades`

Capability 정적 분류 (root of L1):
- `lib/provider_tool_support.ml:39-69` — `capabilities_of_config` (model-id 미사용, provider-kind 만으로 결정)
- `lib/provider_tool_support.ml:148-242` — `supports_required_tool_use` 게이트
- ollama → `Llm_provider.Capabilities.ollama_capabilities` 정적 적용 → `supports_inline_tools=false`

### 2.4 Downstream evidence — 2026-04-28 executor incident

본 RFC 의 cross-cascade silent substitution 이 단일 turn level 에 그치지 않고 keeper-level 자율행동 정지로 amplify 되는 사례가 2026-04-28 에 관측되었다. 분석 출처: `~/Downloads/Kimi_Agent_Keeper FSM 고정/` (Kimi Agent 5-stage analysis, 2026-04-28).

**사고 흐름** (Kimi `executor_reanalysis.md` §3 인용):

1. `local_with_kimi_coding_with_glm` cascade 의 모든 provider 가 tool-use gate reject (`codex_keeper_bound_actor_required`)
2. **`ollama:qwen3.6:27b-coding-nvfp4` 로 cross-cascade fallback** ← 본 RFC L0 가 차단하려는 path
3. Provider 가 응답을 시작했으나 (`turn started` 17:21:40) tool call 을 생성하지 않고 `end_turn`/`stop_reason` 도 발생시키지 않음
4. Turn FSM Axis 1 에서 `streaming` 상태에 11분+ 갇힘
5. Watchdog `in_turn_stale` 판정이 OAS hard cap (3600s) 까지 기다림 → keeper 자율행동 정지

**스펙-구현 간극 진단** (Kimi `executor_reanalysis.md` §4 인용):

> "TLA+ 스펙 관점: 설계는 올바름. `EveryTurnEventuallyTerminates`, `SF_vars(StreamComplete)` liveness 는 올바르게 모델링.
> OCaml 구현 관점: `streaming` 상태에서 provider-level timeout 부재 (3600s 만 존재), watchdog `in_turn_stale` 판정 너무 느림, `operator_disposition: pause_human` 과 `paused: false` 의 동기화 실패."

**3축 직교 상태 framing** (Kimi `executor_reanalysis.md` §2):

```
Axis 1: Turn Phase (KeeperTurnFSM)        — streaming 에 갇힘 (피해)
Axis 2: Decision Stage (KeeperTurnCycle)  — 영향 미상
Axis 3: Cascade State (KeeperOASAdvanced) — provider hang (trigger)
```

본 RFC 는 **Axis 3 의 silent substitution 만** 다룬다. Axis 1 의 streaming-state escape hatch / watchdog stale 판정 / disposition 동기화는 별도 RFC 영역 (§3.2 NG6-NG8 참조).

**본 RFC L0 가 4월 28일 사고에 미치는 영향**:

- ✅ **차단 가능**: cross-cascade fallback default-off 시 step 2 가 발생하지 않고 명시적 에러 (`Cascade_local_only_filter_drained`) 로 즉시 실패. step 3-5 chain 미발동.
- ❌ **차단 불가**: 이미 streaming 에 갇힌 turn 의 자율 복구는 본 RFC scope 밖. Axis 1 의 streaming timeout 별도 RFC 가 같이 진행되어야 자율 복구.

**Anchor commit (PR #11210) 의 의도와 결과 정반대**:

PR #11210 의 motivation 인용: "Resolves the permanent BDI defer loop where keepers using keeper_unified (codex_cli + ollama) had zero tool-capable providers." 즉 **defer loop 해결을 위해 cross-cascade fallback 을 도입** — 그러나 4월 28일 사고에서는 정반대로 **cross-cascade fallback 자체가 keeper 11분 멈춤의 trigger**. RFC-0001 anti-pattern ("silent fallback or low-visibility substitution") 이 운영 사고로 실증된 사례.

### 2.5 Anchor commit 의 의도와 누락된 invariant

PR #11210 (commit `065e568be1`, 2026-04-27) 본문:

> "When all providers in the current cascade fail the tool-capability filter, search all other cascades for a healthy tool-capable provider... Resolves the permanent BDI defer loop where keepers using keeper_unified (codex_cli + ollama) had zero tool-capable providers because codex_cli is blocked by keeper-bound MCP and ollama lacks tool_choice support."

도입 의도는 **"BDI defer loop 해결"** 이었으나 다음 invariant 가 누락되었다:

- **I-Intent**: 사용자가 cascade.toml 에 명시한 model 집합과 실제 실행 model 은 같거나, 명시적 fallback chain 의 결과여야 한다.
- **I-Visibility**: routing 결정에 substitution 이 발생하면 cascade observation 에 즉시 표현되어야 한다 (metric 만으로는 부족).
- **I-Capability**: capability 분류는 model-id 단위 의 ground-truth 또는 설정 가능한 pattern table 에서 와야 한다.

RFC-0027 §3.4 PR #3 가 "cross-cascade fallback resolver capability propagation" 으로 사후 조정을 시도했으나 미구현.

## 3. Goals / Non-Goals

### 3.1 Goals

| # | Invariant | Layer |
|---|-----------|-------|
| G1 | Cross-cascade fallback 은 default-off. fallback chain 은 cascade.toml 의 `fallback_cascade` 만 표현 path. | L0 |
| G2 | Substitution 이 (legacy mode 또는 fallback_cascade chain 으로) 발생 시 audit observation 에 source cascade + reason 필드 포함. | L4 |
| G3 | Capability classification 은 model-id 별 probe 결과 또는 명시적 pattern table 을 우선. provider-kind 정적 분류는 fallback 만. | L1 |
| G4 | 5월 1-6일 audit 의 254 substitution 케이스 replay 시 audit observation 의 `substituted_from_cascade` 가 non-null 이거나 cascade 가 명시적 실패 (`Cascade_local_only_filter_drained`) 로 처리됨. | L0 + L4 |

### 3.2 Non-Goals

| # | 분리 |
|---|------|
| NG1 | ollama transport 가 keeper-bound MCP HTTP header (`X-MASC-Agent-Name`) 를 carry 하도록 만드는 것 — fundamental architectural change, 별도 RFC. |
| NG2 | Permission-aware candidate filtering (keeper credential set 과 모델 권한 매칭) — 별도 RFC, RFC-0026 admission layer 와 통합 검토. |
| NG3 | `glm-coding:*` ↔ `glm-coding-plan:*` namespace mismatch (B2 — 100% substitution 의 직접 원인) — 본 RFC 와 병렬 단일 hot fix PR 로 분리 (`glm_coding_plan_only` cascade 의 model label 정규화). |
| NG4 | BDI defer loop (PR #11210 의 원래 motivation) — fallback chain 명시화로 자연스레 해소될 것으로 예상하나 본 RFC 의 success criterion 에는 미포함. |
| NG5 | RFC-0026 admission scheduler 변경. |
| NG6 | **Streaming-state provider-level timeout** (현재 keeper hard cap 3600s 만 존재, provider 가 stream tool-call 없이 멈출 때 graceful recovery 부재). 별도 RFC — Kimi `executor_reanalysis.md` §4 문제 1. |
| NG7 | **Watchdog `in_turn_stale` 판정 가속화** (현재 grace 360s 후에도 stale=false 유지, fiber kill 까지 OAS hard cap 까지 기다림). 별도 RFC — Kimi `executor_reanalysis.md` §4 문제 2. |
| NG8 | **`operator_disposition` ↔ `paused` 동기화** (OAS scheduler layer 와 keeper local layer 의 비동기 desync — `pause_human` 인데 `paused=false` 모순). 별도 RFC, RFC-0019 keeper-credential-unification 또는 cross-axis sync RFC 와 통합 검토 — Kimi `executor_reanalysis.md` §4 문제 3. |

## 4. Design

### 4.1 L0 — Cross-cascade fallback default-off

**Code surface**: `lib/oas_worker_named.ml:270-312`, `lib/oas_worker_named_cascade.ml:473-550`.

**Behavior change**:

```ocaml
(* 신규 env flag, default "off" *)
type cross_cascade_mode = Off | Legacy | Explicit_chain_only

let cross_cascade_mode_current () = (* MASC_CROSS_CASCADE_FALLBACK *)
  match Sys.getenv_opt "MASC_CROSS_CASCADE_FALLBACK" with
  | Some "legacy" -> Legacy
  | Some "chain" | None -> Explicit_chain_only  (* default *)
  | Some "off" | _ -> Off
```

`lib/oas_worker_named.ml:270-312` 변경:
- 기존: `candidate_cfgs = []` → `resolve_tool_capable_provider_across_cascades` 호출
- 변경:
  - `Off`: 빈 candidate → 즉시 명시적 에러 `Cascade_local_only_filter_drained { cascade_name; ollama_dropped_count; require_tool_support_reason }`
  - `Explicit_chain_only` (default): cascade.toml 의 `fallback_cascade` chain 만 따라감 (기존 정상 코드 path 유지). cross-cascade resolver 는 호출 안 함.
  - `Legacy`: 기존 행동 (cross-cascade resolver 호출). RFC-0001 anti-pattern 으로 분류, deprecation warning 출력.

**Rollout**:
- Phase 1 (PR-A): mode 도입, default `Explicit_chain_only`. legacy 행동 보존 path 는 `Legacy` 로만 진입.
- Phase 2 (1-2 weeks 운영 후): 기존 implicit cross-cascade 의존 cascade 들의 toml 에 명시적 `fallback_cascade` chain 추가 마이그레이션.
- Phase 3: `Legacy` mode deprecation warning → 차후 `Off` default.

**Migration guide**: cascade.toml 의 모든 user-facing cascade 가 `fallback_cascade` 명시. 예:
```toml
[big_three]
fallback_cascade = "tier_fast"  # 기존 implicit cross-cascade 대신
```

### 4.2 L1 — Dynamic capability classification

**Code surface**: `lib/provider_tool_support.ml:39-69` (capabilities_of_config), `lib/llm_provider/capabilities.ml`.

**Behavior change**:

```ocaml
(* 신규: model-id 별 capability override table *)
val resolve_capabilities :
  Provider_config.t -> capabilities
(** Resolution order (highest precedence first):
    1. cascade.toml `[capability_overrides]` table per model-id
    2. provider-built-in pattern table (e.g., gemma4-/qwen3-/llama3.1+ → native tools)
    3. live probe via provider transport (`/api/show` for ollama) — cached with TTL
    4. provider-kind static fallback (current behavior) *)
```

**Pattern table 초기 등록 (L1 default)**:

| Pattern | Provider | inline_tools | inline_tool_choice | Source |
|---------|----------|--------------|-------------------|--------|
| `ollama:gemma4-*`, `ollama:gemma3-*` (>= 3) | Ollama | true | true | Google model card |
| `ollama:qwen3-*`, `ollama:qwen3.6-*` | Ollama | true | true | Qwen model card |
| `ollama:llama3.1*`, `ollama:llama3.2*`, `ollama:llama3.3*` | Ollama | true | true | Meta model card |
| `ollama:phi-3*`, `ollama:phi-3.5*` | Ollama | true | false | MS model card |
| `ollama:llama2-*`, older | Ollama | false | false | static fallback |

**Probe path (Phase 2)**:
- ollama: `GET /api/show` 의 `model_info.tools` field
- 첫 호출 시 cache, TTL=24h (모델 fine-tune 시 invalidation 은 server reload 시점)

**cascade.toml override (Phase 1, 즉시)**:
```toml
[capability_overrides]
"ollama:gemma4:26b-nvfp4" = { supports_inline_tools = true, supports_inline_tool_choice = true }
"ollama:qwen3.6:27b-coding-nvfp4" = { supports_inline_tools = true, supports_inline_tool_choice = true }
```

이 override 가 들어가면 nick0cave / sangsu / masc-improver 의 keeper-bound turn 시 ollama 가 filter 통과 가능 — keeper-bound MCP HTTP header 요건은 여전히 해소 안 됨 (L2 별도 RFC). 다만 `runtime_mcp_policy` 가 None 인 turn (lighter keeper) 에서는 ollama 가 진짜 후보로 들어감.

### 4.3 L4 — Audit substitution visibility

**Code surface**: `lib/oas_worker_cascade.ml:220-258` (`cascade_observation_of_candidates`).

**Schema 추가**:

```ocaml
type cascade_observation = {
  ...existing fields...
  substituted_from_cascade : string option;  (* NEW *)
  substitution_reason : string option;       (* NEW: e.g. "explicit_fallback_chain", "cross_cascade_legacy", "capability_drop" *)
  capability_filter_summary : capability_filter_summary option;  (* NEW *)
}

and capability_filter_summary = {
  configured_count : int;
  dropped_count : int;
  drop_reasons : (string * int) list;  (* e.g. [("inline_tools_unsupported", 3); ("runtime_mcp_blocked_by_headers", 1)] *)
}
```

**Backward compatibility**: 모든 신규 필드는 optional (default None). 기존 audit log parser 는 무영향.

**Dashboard panel**: cascade audit 패널에 substitution rate 그래프 추가 (별도 PR, 본 RFC scope-out 가능).

### 4.4 L2/L3 — Invariant 선언 only

**L2 (transport keeper-identity)** invariant: ollama 가 cross-cascade resolver 의 swap target 이 아니라 본인 cascade 의 진짜 후보로 동작하려면 keeper identity HTTP header 를 carry 해야 한다. 구현 path 후보:
- (a) ollama transport 에 직접 header propagation 추가
- (b) local MCP-HTTP bridge sidecar 신설 (keeper identity → ollama API 변환)

→ 별도 RFC 작성. L1 의 capability override 가 먼저 들어가면 lighter keeper 에서 ollama 활용은 즉시 가능, L2 는 keeper-bound keeper 시나리오 전용.

**L3 (permission-aware filtering)** invariant: cascade candidate 는 keeper 의 effective credential set 과 호환되는 model 만 포함한다. 구현은 `Keeper_admission_glue` 와 통합. → RFC-0026 후속 RFC 로 분리.

## 5. PR Sequence

| PR | Layer | 변경 surface | Dependencies | RFC 인용 |
|----|-------|-------------|--------------|---------|
| **PR-A** | L0 + L4 schema | `oas_worker_named.ml:270-312`, `oas_worker_named_cascade.ml:473-550`, `oas_worker_cascade.ml:220-258`, `cascade_config.ml` | none | RFC-0001, RFC-0027 §3.4 PR #3 |
| **PR-B** | L0 migration | `.masc/config/cascade.toml` 의 모든 cascade 에 명시적 `fallback_cascade` chain | PR-A | RFC-0027 §3.4 PR #4 (`__safe_lane`) |
| **PR-C** | B2 hot fix | `glm-coding:*` ↔ `glm-coding-plan:*` namespace mismatch 정규화 | none (parallel) | RFC-0027 §3 |
| **PR-D** | L1 override table | `cascade_config.ml` capability_overrides schema, cascade.toml 등록 | PR-A 권장 | RFC-0024, RFC-0027 |
| **PR-E** | L1 pattern table | `lib/provider_tool_support.ml`, `lib/llm_provider/capabilities.ml` model-id pattern 분류 | PR-D | RFC-0024, RFC-0027 |
| **PR-F** | L1 live probe | ollama `/api/show` probe + cache | PR-E | RFC-0024 |
| **PR-G** | L4 dashboard panel | dashboard substitution rate graph | PR-A | RFC-0001 §"표현" |

## 6. Compatibility / Migration

- 모든 PR 은 **backward-compatible** opt-in 설계.
- L0 의 `Legacy` mode 가 1-2주 default 후보 (rollout 안전성). 그 다음 `Explicit_chain_only` 로 default 변경.
- cascade.toml schema 추가 필드는 모두 optional.
- `MASC_CROSS_CASCADE_FALLBACK` env flag 의 sunset 일정: PR-A 머지 후 4주 운영 → flag 제거 PR.

## 7. Verification

| Layer | Test |
|-------|------|
| L0 | Unit test: cascade routing decision trace — 빈 candidate × mode 별 분기 |
| L0 | Replay test: 5월 1-6일 jsonl 의 254 substitution 케이스를 fixture 로, mode=`Explicit_chain_only` 시 모두 명시적 에러 또는 toml chain 결과 |
| L1 | Property test: capability table 의 invariant — gemma4/qwen3 modern 모델은 inline_tools=true |
| L1 | Probe cache TTL test |
| L4 | Schema roundtrip test: observation JSON encode/decode 보존 |
| Property | Invariant I1 (Intent): `configured_labels ⊆ candidate_models` 또는 `substituted_from_cascade ≠ None` |

## 8. Risks

| Risk | Mitigation |
|------|------------|
| L0 default 변경으로 BDI defer loop 재발 (PR #11210 의 원래 motivation) | Phase 1 default = `Legacy`. cascade.toml 마이그레이션 (Phase 2) 후 default 변경. metric `cross_cascade_fallback_legacy_total` 모니터링. |
| L1 pattern table 이 model 출시 속도를 못 따라감 | cascade.toml `[capability_overrides]` 가 일급 escape hatch. 운영 중 즉시 추가 가능. |
| L1 live probe 가 ollama 서버 부하 | 24h TTL cache + per-server semaphore. probe 실패 시 pattern table fallback. |
| RFC-0027 §3.4 PR #3/PR #4 와 scope 중복 | 본 RFC 는 PR #3/#4 specification 을 가속화/구체화. RFC-0027 author (jeong-sik) 의 명시적 ack 필요. |
| L4 schema 변경이 기존 audit consumer 깨뜨림 | 모든 신규 필드 optional, default None. consumer 변경 금지. |

## 9. Memory rule 준수

- `feedback_rfc_section_1_4_caller_context_unverified.md`: §2.3 의 모든 file:line citation 은 `rg -nC1` 으로 grep 검증 후 기재함 (oas_worker_named.ml:193-197, 237-247, 270-312; oas_worker_named_cascade.ml:106, 379, 473; provider_tool_support.ml:39-69, 148-242).
- `feedback_audit_must_cross_reference_audit_responses.md`: §2.4 에서 PR #11210 의 본문 인용, RFC-0027 §3.4 후속 PR 표 직접 인용.
- `feedback_no-string-matching-classification`: L1 의 pattern table 은 model-id 의 의미론적 분류, 임의 substring matching 아님.
- `feedback_split_brain_rfc_0022_pr_2_pr3_overlap`: RFC-0027 author 와 PR scope sync 필요 — 본 RFC 의 PR-D~PR-F 가 RFC-0027 §3.4 PR #3 와 의미상 중복 가능.
- `feedback_self_audit_grep_only_false_positive_trap`: Kimi `executor_reanalysis.md` 가 자기 이전 분석 (`executor_keeper_diagnosis.md` / `executor_fsm_tla_analysis.md`) 의 I1-I5 invariant 위반 주장을 **추측에 불과**라고 자기정정한 것은 본 메모리 규칙의 모범 사례. 본 RFC 의 §2.3 file:line citation 검증과 같은 결.

## 10. Open questions

- Q1: L0 default 변경 후 BDI defer loop 가 재발하는 keeper 가 있다면 emergency rollback 절차? (env flag 즉시 `Legacy` 로 되돌릴 수 있는 path)
- Q2: L1 의 `cascade.toml [capability_overrides]` block 이 RFC-0026 admission schema 와 충돌 가능성?
- Q3: B2 (glm namespace) hot fix 는 본 RFC 와 병렬 PR 로 가는데, 의존 관계 명시 필요? (PR-C 가 PR-B 보다 먼저 들어가야 substitution 률이 의미있게 떨어짐)
- Q4: L2 별도 RFC 작성 시점 — L1 PR-D~PR-F 운영 결과 후가 합리적인가?

## 11. References

- RFC-0001: det/nondet boundary harness — silent substitution anti-pattern, "표현" axis
- RFC-0024: ollama cascade integration — runtime catalog, KV cache
- RFC-0026: work-conserving keeper admission — admission layer 와 분리
- RFC-0027: capability-typed cascade catalog — capability profile registry, §3.4 후속 PR 표
- Anchor commit: `065e568be1` (PR #11210, 2026-04-27)
- Audit data: `~/me/.masc/cascade_audit/2026-05/0[1-6].jsonl` (2,620 turns)
- 분석 노트: 2026-05-07 5-track parallel investigation (cross-cascade intent, tool-support filter, keeper-internal requirement, audit log triage, RFC + git history)
- 외부 분석 (Kimi Agent, 2026-04-28): `~/Downloads/Kimi_Agent_Keeper FSM 고정/`
  - `plan.md` — 5-stage analysis plan
  - `executor_keeper_analysis.md` — initial deep-dive
  - `executor_failure_chain_analysis.md` — 5-stage cascade failure timeline
  - `executor_fsm_tla_analysis.md` — TLA+ formal analysis (later partially corrected)
  - `executor_keeper_diagnosis.md` — synthesized incident report
  - `executor_reanalysis.md` — **자기정정 보고서**, KeeperTurnFSM.tla 직접 검증 후 결론. 본 RFC §2.4 의 main source.
- KeeperTurnFSM TLA+ spec: `specs/keeper-turn-fsm/KeeperTurnFSM.tla` (PR #11190, commit `86de071019`) — `SF_vars(StreamComplete)` (line 300) liveness, `EveryTurnEventuallyTerminates` (line 353) invariant. Kimi reanalysis 의 spec correctness 주장의 ground truth.
