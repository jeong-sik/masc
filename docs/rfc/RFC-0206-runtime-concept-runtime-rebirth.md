# RFC-0206: Runtime 개념 — runtime→Runtime 재탄생

- Status: Draft
- Date: 2026-05-30
- Supersedes 라우팅 레이어: RFC-0038(routing-intent), RFC-0041(group-item-hierarchy), RFC-0058 §Layer-4/5(routes/aliases), RFC-0181(routes+phonebook dual-SSOT)
- Superseded (partial): binding-key id 형식(`id = "provider.model"`, §2)은 RFC-0211이 supersede — id는 masc에 opaque, OAS만 parser. single-binding 모델/fail-fast load/§2.1은 유지.
- Builds on: RFC-0058(provider/model/binding 선언 스키마, Layers 1-3), keeper_meta_contract(HEAD; exhaustion 분류)
- Context: PR #19536이 `lib/runtime*`(170+파일) 전면 삭제 + 빌드 의도적 broken. 본 RFC는 그 후속 "Runtime 구현 채우기"의 설계 SSOT.

## 1. 동기

runtime는 다중 provider failover 프레임워크였다: `runtime_id`/`routes`/`tier`/`profile` 간접 레이어로 코드 호출지점을 설정에 매핑하고, 여러 후보를 health/capacity 신호로 정렬해 순차 시도했다. 30개 RFC가 이 추상화를 키웠고 264파일이 강결합됐다.

#19536은 이 개념을 코드베이스에서 제거했다. 남은 것은 소비자 쪽 844개 dangling `Runtime_*` 참조(122파일, keeper 82)와, 거의 빈 `lib/runtime`(2파일, 그마저 삭제된 `Runtime_declarative_types`에 의존해 컴파일 불가)이다.

본 RFC는 runtime를 1:1 복구하지 않는다. **Runtime을 자립 개념으로 정의하고 구현을 채운다.**

## 2. Runtime 개념

Runtime은 하나의 완전히 materialize된 (Provider × Model × Binding) triple과, dispatch 대상인 hot-path `Llm_provider.Provider_config.t`다. resolution graph의 노드가 아니라 **독립 값**이다.

- 시스템은 `config/runtime.toml`(파일명 rename은 deferred)을 flat `Runtime.t list` + 정확히 1개 default `Runtime.t`로 로드한다. default는 `[runtime].default = "provider.model"` 키로 선택한다.
- `runtime_id` 없음, `routes`/`logical_use` enum 없음, tier escalation 없음, profile 간접 없음. 각 binding 셀이 곧 하나의 Runtime이며 `"provider.model"` 문자열 키로 식별된다.
- 소비자는 list와 default를 직접 받아 `runtime.provider_config`를 LLM에 넘긴다. in-band routing 0.
- 다중후보 failover(Selecting/Trying 루프, weighted-random, round-robin, fallback chain)는 제거된다. Runtime은 단일 사전선택 provider를 나타내며 atomic하게 성공/실패한다. cross-runtime 재시도가 필요하면 그것은 in-turn FSM이 아니라 명시적 상위 supervisor 결정이다.

### 2.1 불변식: fail-fast

`[runtime].default`가 없거나, default id가 resolvable binding 중에 없으면 load 시점에 `Error`이고 startup을 abort한다. silent fallback 없음. (현재 `runtime.ml`의 `"tool_strict"` 하드코딩 fallback은 Unknown→Permissive 안티패턴이므로 **제거**한다 — §6 R1.)

## 3. 자립 타입 (P1)

삭제된 `Runtime_declarative_types`를 `lib/runtime/runtime_schema.ml(.mli)`의 자립 타입으로 재구현한다. `Runtime_` 네임스페이스로 재성장시키지 않는다.

| 타입 | 형태 | 대체 |
|------|------|------|
| `api_format` | `Messages_api \| Chat_completions_api \| Ollama_api` | `runtime_api_format` |
| `transport` | `Http of string \| Cli of string` | `runtime_transport` |
| `credential` | `Env of string \| File of string \| Inline of string` | `runtime_credential` |
| `thinking_control_format` | OAS `Llm_provider.Capabilities.thinking_control_format` re-export (`No_thinking_control`, `Thinking_object`, `Thinking_object_adaptive`, `Thinking_object_only`, `Chat_template_kwargs`, `Chat_template_token of string`, `Ollama_think`, `Reasoning_effort`, `Enable_thinking`) | `runtime_thinking_control_format` |
| `capabilities` | 10-field provider 행동 record + `capabilities_default` | `runtime_capabilities` |
| `model_capabilities` | 24-field record (`Llm_provider.Capabilities` 미러) + default | `runtime_model_capabilities` |
| `provider` | Layer 1 record (id/display_name/protocol/api_format/transport/is_non_interactive/credentials/capabilities/headers). log·healthcheck sub-record는 v1에서 parse-and-ignore | `runtime_provider` |
| `model_spec` | Layer 2 record (id/api_name/tools_support/max_context/thinking_support/max_thinking_budget/streaming/capabilities/match_prefixes) | `runtime_model_spec` |
| `binding` | Layer 3 record (provider_id/model_id/is_default/optional max_concurrent/price_*/keep_alive/num_ctx) + `binding_key` | `runtime_binding` |
| `config` | `{ providers; models; bindings; default_runtime_id }` — **routes/system_targets/profiles/aliases DROP** | `runtime_config` minus routing |

조회 헬퍼 `provider_of_id : config -> string -> provider option`, `model_of_id : config -> string -> model_spec option`도 함께 자립화한다.

## 4. FSM 추출 (routes/tiers 폐기)

runtime 5-state(`Idle/Selecting/Trying/Done/Exhausted`)는 다중후보 selection FSM으로 살아남지 않는다. Selecting/Trying/round-robin/fallback은 single-binding 모델에서 소멸한다.

그러나 keeper 소비자(`keeper_composite_observer`, `keeper_registry`의 packed state, 5개 invariant)가 이를 turn-observation/FSM-invariant로 매치한다. 재배치:

- **keeper 소유 slimmed enum**: `keeper_turn_phase = Turn_idle | Turn_dispatching | Turn_done | Turn_exhausted`. `Trying → Turn_dispatching`, `Selecting`은 삭제(in-turn 선택 없음).
- `Runtime_routed` event_kind, `Runtime_backpressured` 신호는 단일 dispatch 이벤트 + turn-terminal `Timeout`/`Admission_denied` 에러로 collapse(capacity 거부는 더 이상 provider-level backpressure가 아님).
- **exhaustion 분류는 재생성 금지**: `keeper_meta_contract.runtime_exhaustion_reason`(10 variant: Connection_refused/Dns_failure/No_providers_available/All_providers_failed/Candidates_filtered_after_cycles/Max_turns_exceeded/Structural_attempt_timeout/Capacity_exhausted/No_tool_capable/Other_detail) + `blocker_class`(`Runtime_exhausted` carrier)는 HEAD에 이미 keeper-owned로 생존(`keeper_meta_contract.mli:139-196`). **그대로 재사용.** 이 표면은 operator 대시보드가 파싱하는 frozen seam이므로 rename 금지.
- `check_no_runtime_before_measurement` 등 5개 invariant는 keeper concern으로 생존하되 `Turn_dispatching` gate로 retarget.

## 5. 계승 / 폐기

**계승(INHERIT):**
- `keeper_meta_contract`의 exhaustion_reason + blocker_class (frozen, 재사용)
- `Llm_provider.Provider_config.t`를 `Runtime.t.provider_config` hot-path 대상으로 (외부 OAS lib, 생존)
- RFC-0058 절대 원칙: 코드는 provider/model 이름을 모른다 — provider 추가 = TOML 항목만, 재컴파일 없음
- RFC-0058 §4.1 load-time validation = `Runtime.load_list`의 fail-fast gate
- `binding.max_concurrent` is optional metadata for explicit operator overrides; missing means no static per-binding cap. It does not replace URL/probe-based capacity by default.
- api_format 3-variant dispatch를 provider 정체성과 분리

**폐기(DISCARD):**
- `Runtime_name.t` 문자열 wrapper(~90 ref) → raw string id, 검증은 TOML load 경계에서만
- `Runtime_routes`/`runtime_routes_resolve`/`logical_use` enum
- `Runtime_strategy` + strategy kind ADT + trace (single Failover)
- `Runtime_fsm` 다중후보 `decide()`(Accept/Try_next/Exhausted) → atomic success/fail
- round-robin cursor, fallback_events/hops, multi-tier escalation
- `Runtime_observation` state-bearing record → 단일 attempt metadata(latency_ms/error/outcome)로 demote
- 전역 `Runtime_health_tracker.global` 싱글톤(runtime-name 축) → per-runtime-key health를 명시 전달
- `runtime_source` enum, weighted_entry_drop, route→catalog→profile 2단 resolution
- `Runtime_phonebook_*`/`Runtime_routing_policy`/`Runtime_capability_profile` registry
- Layer 4 per-use overrides(alias), route, system_targets, profile
- `get_default_runtime_id`의 `"tool_strict"` 하드코딩 fallback

## 6. 구현 단계

| Phase | 목표 | 파일 | unblocks |
|-------|------|------|----------|
| **P1** | `runtime_schema.ml(.mli)` 10 type group + defaults + provider_of_id/model_of_id/binding_key. 삭제 모듈 의존 0. `open Runtime_declarative_types` 대체 | ~4 | Runtime.t가 자립 타입으로 컴파일; P2 타깃 스키마 확보 |
| **P2** | `runtime_toml.ml`(Otoml→config), `runtime_adapter.ml`(binding→Provider_config.t). load_list/of_binding 배선. runtime.toml fixture + no-default fixture(Error) 검증 | ~7 | load_list end-to-end; init_default; startup fail-fast |
| **P3** | singleton 경계 결정. ref 기반 유지 + `"tool_strict"` fallback 삭제(uninit→fail loud). eager-init crash 회피(lazy/explicit + test fixture) | ~5 | 90 사이트 안전 re-home |
| **P4** | keeper 소비자 re-home(dominant 77파일). Runtime_name/runner/error_classify/catalog_runtime → raw id, get_default_runtime_id, keeper_meta_contract, keeper_turn_phase. 5파일 batch | ~16 batch | 844 dangling 대부분 해소 |
| **P5** | 주변 소비자: config_diagnostic, dashboard runtime lens, admission_queue, server, otel, operator. dune deps에서 runtime lib 제거 | ~21 | full build green; dangling 0 |
| **P6** | invariant retarget(`Turn_dispatching`), load_list fail-fast test(no-default→Error, bad-id→Error, subset filtering), mutation-test | ~6 | 검증 가능한 완료 기준 |

## 7. 리스크

- **R1 (silent-default landmine):** `"tool_strict"` fallback은 init 순서가 틀리면 90 사이트가 조작된 id를 받는다 — Unknown→Permissive 안티패턴. P3에서 삭제(Error/raise on uninit), 이월 금지.
- **R2 (eager-init crash):** 메모리 2026-05-30 B3 `runtime_id_for_use` gut이 fail-fast raise + eager module-level binding으로 config-less 바이너리(테스트) startup crash 때문에 DEFER됨. Runtime 싱글톤도 동일 위험 — init을 lazy/explicit로 유지하고 test runtime fixture 제공.
- **R3 (병렬 충돌):** 다른 세션이 동일 파일에서 runtime purge 진행 중(feat/runtime-name-cleanup 174파일, host load 110+). P4 전 `masc_broadcast` + in-flight PR scan 필수(broken-main race #19424 재발 방지).
- **R4 (재성장):** runtime_toml/runtime_adapter를 minimal하게. aliases/routes/profiles 파싱 전면 drop, validator dual-mode·longest-prefix model matching은 binding이 실제 fuzzy resolution을 요구하기 전엔 포팅 금지.
- **R5 (frozen seam):** `keeper_meta_contract`의 `blocker_class_to_string` literal을 operator 대시보드가 파싱. `Runtime_exhausted` rename은 alerting을 깬다. reuse, refactor 금지.
- **R6 (CI surface gate):** `Detect Changed Surfaces`가 types-only P1을 no-surface로 오분류해 Build/Test skip한 전례(2026-05-28). gate가 `lib/runtime/`에 trigger되는지 검증.

## 8. 검증

- P1: `dune build lib/runtime/ --root .` 통과 (keeper broken 무관하게 runtime lib 자립 컴파일)
- P2: runtime.toml fixture 로드 성공 + no-default fixture → `Error`
- P6: fail-fast mutation-test (default 누락/오류 시 반드시 Error)
- 최종: full build green + `rg -w 'Runtime_[A-Za-z_]+' lib bin` = 0

## 9. P4/P5 범위 정밀 측정 (2026-05-30, measured)

P1-P3(자립 schema/parser/adapter + runtime.ml 재배선 + `tool_strict` 제거)은 완료·격리 컴파일 검증(scratch EXIT=0)·커밋됨. P4/P5 진입 전 dangling 범위를 정밀 측정해 초기 추정(844/122)을 교정했다.

### 9.1 surviving vs dangling 분류 (결정적)

`rg 'Runtime_[A-Za-z_]+'`의 862 occurrence는 dangling 여부 무관 집계였다. 64개 distinct 심볼을 생존-정의 여부로 분류:

- **21 심볼 = keeper 소유 variant 생성자**(생존 keeper 모듈에 정의, 컴파일 정상). `Runtime_idle/selecting/trying/done/exhausted`(keeper_registry_types/keeper_composite_observer/keeper_meta_contract), `Runtime_routed`(keeper_runtime_manifest_types), `Runtime_admitted/backpressured`(keeper_heartbeat_loop), `Runtime_attempts_exhausted`(keeper_turn_disposition) 등. **마이그레이션 대상 아님.** RFC §4대로 `keeper_meta_contract.Runtime_exhausted`는 frozen seam(operator 대시보드 파싱)이라 보존. rename(Runtime_idle→Turn_idle)은 P6 선택 polish.
- **30+ 심볼 = dangling 모듈 참조**(삭제된 runtime 모듈). 이것만이 컴파일 차단. **진짜 범위: 120 파일 / 507 모듈-접근 occurrence** (lib/keeper 83, lib 17, dashboard 9, server 4, otel/local/config/operator 7).

### 9.2 dispatch 부분그래프 = restore-rename (rewrite 아님)

최대 비용은 dispatch cluster. `Runtime_runner`(61 ref) 소비 심볼의 35/61은 **타입 참조**(`stop_reason`/`run_result`/`response`/`cli_transport_overrides` — 전부 `Runtime_agent_context`/`Runtime_transport` 별칭), 실함수 호출은 `run`/`run_with_masc_tools`/`resolve_tool_lane` ~4건.

전이 폐쇄: runtime_runner(785줄) + runtime_agent_context(390) + runtime_transport(407) + runtime_oas_runner(500) + runtime_transport_*(~14 하위모듈) + runtime_wire_overlay ≈ 2500줄. **그러나 측정 결과 이 부분그래프는 routing/strategy/health/selection 의존이 0**(runtime_transport는 자기 하위모듈 + `Runtime_config` + circular `Runtime_runner`만 의존). runtime_runner.run body의 selection 오염은 `Runtime_observation` 단 2건.

→ RFC §5 INHERIT(transport + api_format 3-variant dispatch 보존)와 부합. dispatch substrate = transport/dispatch/config 부분그래프를 `Runtime_*` 네임스페이스로 **restore + 결정론적 rename**(내부 `Runtime_config`→Runtime_schema, `Runtime_observation` 2건 외과 처리). 2500줄 재작성이 아니라 mechanical rename이라 workflow fan-out 적합.

### 9.3 cluster별 전략 (P4/P5 application)

| cluster | dangling 모듈 | 전략 |
|---------|--------------|------|
| dispatch | Runtime_runner/oas_runner/agent_context/transport(+14 sub)/wire_overlay | **restore-rename → Runtime_***; selection 2건 외과 제거 |
| catalog-config-types | legacy runtime catalog/runtime_candidate/config/decl/declarative_* | 이미 구축된 lib/runtime(Runtime/Runtime_schema/Runtime_toml/Runtime_adapter)로 mechanical 치환 |
| error-events | Runtime_error_classify/internal_error/event_bridge/events/inference | 생존 keeper_meta_contract 재사용 / 일부 re-home |
| health-capacity-obs | Runtime_health_tracker/observation/saturation_signal/capacity_probe/slot | DISCARD 싱글톤, observation→single attempt metadata demote |
| fsm-liveness-preflight | Runtime_fsm/attempt_fsm/preflight_state/attempt_liveness*/deadline | keeper_turn_phase substrate / delete |
| routing | Runtime_routing/routes/strategy | DISCARD callsite |
| naming | Runtime_name | raw string id |
| misc | Runtime_worker_defaults/agent_context/trust_persist | per-symbol 분류 |

세부 file-level 매핑은 Phase U 워크플로(8-cluster understand) 산출.

## 10. Substrate 설계 (Phase U 종합, 2026-05-30)

8-cluster understand 워크플로(w93dm28ba) 종합 + 저자 override. dependency layer 순서로 실행한다(monolithic lib → 전부 green 돼야 머지).

### L0 — lib/runtime 추가 (keeper 의존 0, 최우선)

- **transport/dispatch 부분그래프 restore-rename** (RFC §9.2): `runtime_transport`(+14 transport_* 하위) + `runtime_agent_context` + `runtime_wire_overlay` + `runtime_oas_runner` + `runtime_runner` → `Runtime_transport*` / `Runtime_agent_context` / `Runtime_wire_overlay` / `Runtime_oas_runner` / `Runtime_agent`. ~3000 LoC, 결정론적 rename. 경계 rewire: `Runtime_config`→`Runtime_schema`/`Runtime`, `Runtime_name`→`string`, `Runtime_observation` 참조(runner 2건) 외과 제거.
- **`Runtime_agent`** (dispatch entry): `stop_reason`/`run_result`(runtime_observation 필드 제거)/`response`/`cli_transport_overrides` 타입 + `run`/`run_with_masc_tools` single-binding wrapper(Agent_sdk.Agent.run 위).
- **`runtime_constants`**: `fallback_context_window = 128000`.
- **`runtime_deadline`**: `of_seconds_from_now` 등 (Runtime_deadline 단순 이식).
- **`Runtime.config_path : unit -> string option`** 추가 (Runtime_runtime.runtime_config_path 대체).
- 샘플링 상수: `Llm_provider.Constants.Worker_sampling`(외부 lib, 존재 시 reuse) — 신규 모듈 회피.

### L1 — lib/keeper substrate (L0 + 생존 keeper_meta_contract 의존)

- **`keeper_event_bridge`** ← Runtime_event_bridge (start/native_event_to_json, 동일 시그니처).
- **`keeper_event_publisher`** ← Runtime_events (publish_keeper_lifecycle/snapshot, Masc_event_bus.get).
- **`keeper_binding_health`** ← Runtime_health_tracker (per-binding, global 싱글톤 제거; record_success/failure/rejected/...).
- **`keeper_attempt_metrics`** + **`keeper_audit`** ← Runtime_observation (single attempt metadata demote; `runtime_id`→`binding_id:string`).
- **`keeper_attempt_liveness`** ← Runtime_attempt_liveness(+config/observer) (per-attempt streaming liveness FSM, Eio Switch).
- **`keeper_preflight_health_tracker`** ← Runtime_preflight_state (global/record/is_disabled/reset_on_health_recovery/reason_slug).
- **error classify**: 신규 모듈 0 — `Keeper_meta_contract`가 이미 `masc_internal_error`/codec/provider_rejection/capacity_backpressure_source 소유(RFC-0142). 소비자는 `Runtime_error_classify.X`/`Runtime_internal_error.X` → `Keeper_meta_contract.X`.

### DISCARD / DELETE-CALLSITE (substrate 0)

- **catalog**: legacy runtime catalog snapshot/validation/resolution APIs — routing 아티팩트, callsite 삭제.
- **routing**: `Runtime_routes.logical_use`→string literal("keeper_turn"), `Runtime_routes_resolve.runtime_id_for_use`→`Runtime.get_default_runtime_id ()`, `Runtime_strategy.*`/`Runtime_strategy_trace.record` → **callsite에서 identity/no-op inline** (⚠️ 저자 override: U 에이전트가 제안한 `Runtime_strategy` 신규 모듈은 multi-candidate 재성장이므로 **거부**. single binding에서 order_candidates는 항등, record_choice는 no-op).
- **misc**: `Runtime_trust_persist.start_snapshot_fiber` → 삭제(JSONL 스냅샷 불요, 관측은 Neo4j/legacy metrics backend).

### L2 — consumer rewire (120 파일)

L0+L1 위로 재배선. mechanical(naming Runtime_name→string 49파일, error→Keeper_meta_contract, misc 상수) + semantic(dispatch run_result destructure 25파일, catalog DELETE-CALLSITE, fsm). naming은 batch 가능, semantic은 파일별.

### L0 substrate ADDITION (semantic 경계 매핑, measured 2026-05-30)

restored substrate + 120 consumer가 참조하는 semantic 심볼의 확정 매핑:

| 삭제 심볼 | refs | 대체 |
|-----------|------|------|
| `Runtime_config.parse_model_string` | 10 | **신규** `Runtime.parse_model_string : string -> Provider_config.t option` (Runtime_adapter 경유, "provider/model" 파싱) |
| `Runtime_config.split_provider_model` | 1 | inline `String.split_on_char '/'` 또는 Runtime helper |
| `Runtime_config.filter_healthy_strict` / `health_filter_rejection_to_string` | 2 | keeper_binding_health 또는 discard (single binding = 필터 불요) |
| `Runtime_config.resolve_strategy` | 1 | DISCARD (routing) |
| `Runtime_runtime.models_of_runtime_id(_result)` | 8 | single-binding collapse: `[ (get_default_runtime ()).model ]` (multi-candidate 리스트→단일) |
| `Runtime_runtime.fallback_context_window` | 5 | **신규** `Runtime_constants.fallback_context_window = 128000` |
| `Runtime_runtime.runtime_config_path` | 5 | **신규** `Runtime.config_path : unit -> string option` |
| `Runtime_runtime.{local_model_label,default_model_strings,resolve_*_context,max_output_tokens_ceiling*,local_capacity_for_selections,ensure_api_keys_for_labels}` | ~15 | Runtime.t/Runtime_schema 조회로 collapse (single binding) |
| `Runtime_metrics.on_{provider_cooldown,runtime_audit_failure,resolve_live_fallback,runtime_metrics_eviction}` | 9 | **신규** `Runtime_metrics.on_*` legacy metrics backend emitter (오염 runtime_metrics 미복원; 순수 카운터만) |
| `Runtime_capability_profile.{provider_satisfies_profile,is_system_runtime_id}` | 2 | DISCARD/predicate (profile 제거) |
| `Runtime_observation` (substrate 내) | 4 | `Keeper_observation` (L1 restored) |
| `Runtime_runner` (substrate 내) | 2 | `Runtime_agent` (L0 rename 누락분) |
| `Runtime_name` (substrate 내) | 11 | `string` (type), 호출 제거(to_string/of_string_exn) |
| `Runtime_tier_wait_scheduler` | 1 | DISCARD (tier 제거됨 #19436) |
| `Runtime_error_classify` (substrate 내) | 1 | `Keeper_meta_contract` |

신규 substrate addition 모듈: `runtime_constants`(fallback_context_window), `runtime_metrics`(on_* emitter), `Runtime`에 `parse_model_string`/`config_path`/model-resolution 헬퍼 추가.

### 검증 순서

L0 scratch 컴파일 → L1 (keeper_meta_contract 링크 필요, 전체 lib 빌드) → L2 후 full build green + `rg -w 'Runtime_[a-z][A-Za-z_]*\.' lib bin` = 0 (생존 variant 생성자 `Runtime_idle` 등은 잔존 허용, P6 rename).

RFC-WAIVED 근거(상위 #19536): 사용자 명시 지시에 따른 runtime→Runtime 재탄생. 본 RFC가 그 구현 단계의 설계 SSOT를 제공한다.
