---
rfc: "0153"
title: "Runtime Backpressure & Tier Admission"
status: Active
created: 2026-05-20
updated: 2026-06-16
author: vincent
supersedes: []
superseded_by: null
related: ["0009", "0022", "0042", "0082", "0088", "0102", "0127", "0152"]
implementation_prs: [16965, 16988, 16991]
---

## Progress audit (2026-05-21)

Status promoted Draft → Active. Phase A.1 + A.2 + B.1 landed
within 36 hours of the RFC body; subsequent phases remain.

| Phase | PR | Scope | Merged |
|-------|-----|------|--------|
| Phase A.1 | #16965 | typed `Runtime_saturation_signal` (additive only) | 2026-05-20 |
| Phase A.2 | #16988 | wire typed saturation signal emission | 2026-05-20 |
| Phase B.1 | #16991 | `runtime_tier_admission` module + tests | 2026-05-20 |

### Frontmatter format normalization

`implementation_prs` previously held a single freeform string
(`"#16965 (Phase A.1, merged 2026-05-20T12:25:11Z)"`). The
`docs/rfc/README.md` standard expects a list of bare integer PR
numbers. This audit normalizes to `[16965, 16988, 16991]` so
downstream tooling (the new `audit-rfc-closeout-lag.sh`) and human
readers see a consistent shape across RFCs.

### Pending — Phase B.2 and beyond

The RFC body's phase plan beyond B.1 is not enumerated tightly
enough in §4 to map remaining PR slots one-to-one from the commit
log alone. Author input needed before `Implemented` status — the
typical follow-ups for an admission-shaped RFC are:

- B.2+ — wire the admission decision into the runtime path
- C — saturation-driven backpressure into the caller
- soak window before fast-fail removal

Until those phases are explicitly enumerated and tracked, `Active`
is the accurate status: a runnable typed signal + admission module
exist, but the loop is not closed end-to-end.

### Related RFC

The closeout cohort that landed within the same week:
- **RFC-0141 / RFC-0142 / RFC-0148 / RFC-0154** — closed-sum cohort
- **RFC-0127** — runtime fast-fail provenance (already in related)

---

# RFC-0153 — Runtime Backpressure & Tier Admission

> Canonical HTML design doc: `~/me/memory/masc-rfc-0153-runtime-backpressure-2026-05-20.html` (full evidence tables, external research §7, design rationale).
>
> 본 markdown은 docs/rfc/ canonical 위치를 채우는 RFC body. 사용자 검토 후 Phase A.1 부터 단계별 PR.

## 0. TL;DR

`runtime_audit` 14일치 8917 attempt 중 43.5% 실패. "runtime 소진"이라 분류된 사건의 **80%+**가 실제로는 `max_execution_time_s 300s` hard timer fire의 *downstream symptom* — runtime routing 자체의 문제가 아니라 watchdog가 죽이는 것. 회복은 사용자 수동 `update_keeper resumed` 만 가능 (최근 paused 약 5시간 방치).

근본 원인: `try_runtime` (lib/keeper/keeper_turn_driver.ml ~757-908) 는 tier-by-tier sequential failover, **tier-level concurrency primitive 부재**. N개 keeper가 saturated tier에 동시 stampede → 동시 fail. 300s wall-clock가 runtime·context·turn 세 budget을 동시에 죽이는 공통 trigger.

제안 5단계:
- **Phase A** — Time cap 의미 분리 (kill switch → typed `Runtime_saturation_signal`). OpenClaw `x-should-retry: false` 패턴 차용 (§7).
- **Phase B** — Tier-level admission semaphore (Eio.Semaphore per runtime).
- **Phase C** — Adaptive client-side throttling (Google SRE Handbook §21 공식).
- **Phase D** — RFC-0152 보완. **D.1** fixed cooldown ladder (OpenClaw 1m→5m→25m→1h validated). **D.2** EWMA decay (novel, deferred).
- **Phase E** — Runtime → deadline-aware scheduler 재모델링 (별도 RFC 후보, 6개월 운영 데이터 후).

비-목표: RFC-0127의 provider-side fast-fail 영역, transient_http_status 분류 수정, last_blocker (RFC-0082, BLOCKED), 새 wire-format.

## 1. Problem

### 1.1 코드 증거 — sequential failover, 동시성 부재

`lib/keeper/keeper_turn_driver.ml` `try_runtime` 내부:

```ocaml
let rec try_runtime candidates ... =
  match candidates with
  | [] -> Error Exhausted              (* 빈 리스트 = 즉시 종결 *)
  | candidate :: rest ->
      (* 단일 candidate 실행 → 실패 시 *)
      try_runtime rest new_err          (* tail-recursion, 동시성 X *)
```

| 점검 항목 | 현 상태 |
|---|---|
| Eio.Stream / Semaphore / Pool at tier level | 사용 안 함 |
| `Admission_queue` 적용 지점 | keeper-turn 입장 시점만 (라인 1477-1484), tier 진입에는 없음 |
| Runtime × Turn × Context 교차 함수 | 없음. 셋이 독립 layer, 같은 300s timer만 공유 |
| 동시 N개 runtime 요청의 tier 진입 제어 | 없음 — stampede 가능 |
| "runtime exhausted" 로그 사이트 | ~1330 (all tiers failed), ~1153 (rejected by accept predicate) |

### 1.2 런타임 증거 — 14일치 측정 (`<base-path>/.masc/runtime_audit/2026-05/`)

| 분류 | 건수 / 비율 |
|---|---|
| 전체 attempt | 8917 / 14일 |
| failure 비율 | 3877 / 43.5% |
| runtime_exhausted (서버 로그) | 419건 (provider-k-three 263 + restart 124 + 8935 12 + hotfix 20) |
| 그 중 사유 = `candidates_filtered_after_cycles` | 123/123 (100%) — **downstream symptom** |
| 그 중 메시지 = `max_execution_time_s 300s` | 138 중 57이 정확히 300.0s 동률 — **real root** |
| runtime_exhausted at minute peak (provider-k-three 05-16) | 02:34 = 19/min, 02:27 = 18/min |
| `client_capacity_full` 폭증 (2026-05-19~20) | 486건/2일 (이전 0) — 기존 `Runtime_client_capacity` (per-URL, ollama 등) 백프레셔 *작동 중* signal. regression 아닐 가능성 큼 — §4.2 layer matrix 참조 |
| 회복 방식 | 100% 사용자 수동 `update_keeper resumed` (최근 paused_since = 18137s) |
| auto-resume 작동 | 사실상 비활성 (`failure_ratio` 게이트 즉시 차단) |

### 1.3 사건 사슬 — 03:22:47~48 sangsu (대표 사례)

1. runtime `strict_tool_candidates` 시도
2. `max_execution_time 300s` hard timer fire
3. runtime가 즉시 다음 후보로 ⇒ `productive slot 180s exhausted after 300.3s`
4. "all runtimes exhausted (terminal)" — 모두 1초 내 발생

같은 timer 한 번이 runtime·context·turn 셋을 동시에 죽임. "3중 소진"은 *원인 3개*가 아니라 *결과 3면*.

### 1.4 사용자의 의문 — "왜 wait/queue 안 함?"

**그런 객체 자체가 존재하지 않음**. runtime는 처음부터 *단일-요청 failover chain*으로 모델링됐고, "여러 keeper가 동시에 같은 tier로 가는 상황"이 1급 시민이 아님. RFC-0102 (pre-turn gate)가 admission *직전* 한 layer를 추가했지만 tier 진입 후의 동시성은 여전히 부재.

## 2. Goals / Non-goals

### Goals

- **G1.** Runtime·context·turn 소진의 *공통 trigger* (300s wall-clock)을 분리하여, 각 layer가 자기 budget만 책임지게 함.
- **G2.** Tier saturation을 *failure*가 아니라 *typed signal*로 모델링 — caller가 결정 (즉시 fail / deadline 내 wait / degraded path).
- **G3.** 동시 N개 keeper의 stampede를 tier-level admission semaphore로 차단.
- **G4.** Adaptive throttling으로 *failure 상태의 tier에 부담 안 줌*.
- **G5.** RFC-0152 의 auto-resume에 시간감쇠 — D.1 fixed ladder → D.2 EWMA (측정 후).

### Non-goals

- Provider health probe redesign (RFC-0127).
- `transient_http_status` 분류 수정.
- `runtime.toml` runtime 멤버 선택 전략.
- last_blocker 경로 (RFC-0082, BLOCKED).
- 새 wire-format / API surface (Phase A는 *추가만*).

## 3. 관련 RFC 와 layer 분리

RFC-0127 의 4-layer matrix를 **시간 축**으로 확장:

| 축 | Layer | RFC | 본 RFC와의 관계 |
|---|---|---|---|
| 공간 (RFC-0127 §2) | Pre-turn | RFC-0102 | 직교 |
|  | Pre-attempt | RFC-0009 | 직교 (trust score ordering) |
|  | In-attempt | RFC-0022 | 직교 (per-attempt liveness) |
|  | Cross-attempt | RFC-0012 | 직교 (mid-turn no progress) |
| 시간 (본 RFC 신설) | Watchdog hard kill | 현재 코드 (RFC 없음) | **본 RFC가 redesign** |
|  | Tier admission | — | **본 RFC가 신설** |
|  | Client throttling | — | **본 RFC가 신설** |
| 회복 | Auto-resume | RFC-0152 | **본 RFC가 보완** (Phase D) |
| 발견 | Provider fast-fail | RFC-0127 | 직교 |

**왜 RFC-0127 / 0152 의 Phase가 아니라 신규 RFC인가**: RFC-0127은 *provider error* 발생 시의 runtime 반응, 본 RFC는 *latency가 길어져서 watchdog가 죽이려 할 때*의 runtime 반응. 다른 trigger. RFC-0152는 *pause된 keeper의 복귀*, 본 RFC는 *애초에 pause로 떨어지지 않도록* backpressure. Phase로 들어가면 추상 경계가 흐려짐.

## 4. Design

### 4.1 Phase A — Time Cap → Typed Saturation Signal (OpenClaw-validated)

**외부 검증 (§7)**: OpenClaw `docs/concepts/retry.md` — Provider SDK가 60s+ wait 권고 시 OpenClaw가 `x-should-retry: false` *inject*하여 SDK 내부 wait 끊고 model failover로 escalate. 본 RFC Phase A 가 정확히 동일 패턴.

**현 동작** (`lib/runtime/runtime_runner.ml:44`, `lib/keeper/keeper_turn_runtime_budget.ml:47`):
```
300s timer fire → runtime attempt cancelled
  → 다음 candidate가 "cooldown" 으로 필터됨 (이전 candidate가 300s 동안 fail 처리됐으므로)
  → candidates_filtered_after_cycles 로그
  → keeper pause + "runtime exhausted" 표시
```

**제안 — typed Saturation signal 추출**:

```ocaml
(* NEW: lib/runtime/runtime_saturation_signal.ml *)
type t =
  | Provider_rate_limited of { provider_id : string; retry_after_ms : int option }
  | Time_cap_fired of {
      observed_latency_ms : int;
      cap_ms : int;
      provider_id : string option;
    }
  | All_tiers_filtered_after_cycles of {
      runtime_id : string;
      cycle_count : int;
    }
  | Inflight_capacity_full of {
      tier_id : string;
      max_inflight : int;
    }

val to_log_string : t -> string
val to_metric_label : t -> string
val to_yojson : t -> Yojson.Safe.t
```

**caller dispatch** (`lib/keeper/keeper_turn_runtime_budget.ml`):

```ocaml
match Runtime_saturation_signal.classify ~elapsed_ms ~cause with
| Time_cap_fired _ as sig_ ->
    record_saturation_observation sig_;
    decide_after_saturation ~remaining_budget sig_
| _ as sig_ ->
    record_saturation_observation sig_;
    propagate_to_caller sig_
```

핵심: 300s cap이 *kill switch*가 아니라 *signal emit*로. caller가 *남은 turn deadline*과 *signal 종류*를 보고 결정. Phase A 내에서는 default 행동을 *현재와 동일*하게 유지 (추가만). Phase B/C 가 signal을 *사용*.

### 4.2 Phase B — Tier-Level Admission Semaphore (MASC novel)

**외부 검증 부재**: Hermes/OpenClaw/OpenHands 모두 single-session 모델이라 tier-level admission semaphore *부재* (§7). MASC 멀티-keeper 동시성은 이 framework들보다 어려운 영역. Phase B는 novel design — TLA+ 검증 + incremental rollout 필수.

**Module** (updated per §6.8 attack #8 — admission_policy parameter):

```ocaml
(* NEW: lib/runtime/runtime_tier_admission.ml *)
type tier_id = string

type admission_policy =
  | Required          (* main keeper_turn path; semaphore acquire 강제 *)
  | Bypass            (* side task (probe, memory summary, run_tools);
                         semaphore 우회. starvation 방지 *)

type t = {
  semaphores : (tier_id, Eio.Semaphore.t) Hashtbl.t;
  config     : (tier_id, int (* max_inflight *)) Hashtbl.t;
}

val create : Runtime_config.t -> t

val with_admission :
  t ->
  tier_id:tier_id ->
  deadline_ms:int ->
  admission_policy:admission_policy ->  (* NEW (§6.8) *)
  (unit -> 'a) ->
  ('a, Runtime_saturation_signal.t) result
(** [admission_policy = Bypass] 일 때 semaphore acquire 없이 즉시 진행.
    side task가 production traffic에 의해 starve되지 않도록 *명시적*
    분리 — default은 없음 (caller가 반드시 결정). *)
```

**Caller policy 매핑** (Q7 audit 기반):

| Caller | admission_policy | 근거 |
|---|---|---|
| `keeper_turn_driver.try_runtime` (main keeper turn) | `Required` | main production traffic; backpressure 의도 |
| `keeper_stale_watchdog:692` (runtime health probe) | `Bypass` | probe가 production load 측정해야 함; semaphore에 묶이면 self-defeating |
| `keeper_run_tools:757` (tool execution) | 검토 후 결정 | 일반적으로 main turn 내부 nested fiber — Phase B 시작 시 audit |
| `keeper_memory_llm_summary:220` (memory summary) | `Bypass` | side task; production traffic에 양보 |
| `runtime_runtime.ml:638,660,709` | 검토 후 결정 | runtime 측 entry point — caller에 따라 결정 |

> 기존 `Admission_queue` (turn-level, lib/runtime/runtime_error_classify.ml `Admission_queue_*` variant) 와 명확히 구분하기 위해 module 이름을 `runtime_tier_admission` 로 명명.

#### 4.2.1 기존 admission/capacity layer 와의 관계 (post-B.1 정리)

`Runtime_tier_admission` 은 *신규 layer*. 기존 코드베이스에 *유사 의도*의 module이 4개 존재 — 같은 추상으로 잘못 흡수하지 말 것.

| Module | 단위 | 동기 | 호출 site | 작동 방식 |
|---|---|---|---|---|
| `Runtime_throttle` (기존) | per-URL | llama-server `/slots` Discovery — server-reported capacity | 자동 (Discovery loop) | server-side slot 수치 미러링 |
| `Runtime_client_capacity` (기존, @since 0.9.6) | **per-URL endpoint** | ollama 등 slot 개념 없는 server 보호 — 같은 GPU 동시 hammer 방지 | `keeper_turn_driver.acquire_client_capacity_slot` (try_runtime 안) | `MASC_CLIENT_CAPACITY` env 로 register, `try_acquire` → `None` 시 runtime 가 next candidate (no queueing) |
| `Admission_queue_*` variants (기존) | turn-level | error classification — provider 가 admission queue 거부 신호 보낼 때 | `runtime_error_classify.ml` 안 | error→retry 정책 분기 |
| **`Runtime_tier_admission`** (NEW, B.1) | **per-runtime** | tier 전체 동시성 cap — 같은 tier 안 여러 endpoint 합산 admission | (B.2 wire-in 예정) `try_runtime` *outer wrap* | `with_admission` → `Capacity_full` signal emit, runtime 가 next tier |

핵심 차이:
- `Runtime_client_capacity` = **endpoint(URL) 1개당 동시 N개**. 한 endpoint 가 saturated 면 *같은 tier 안 다른 endpoint* 시도 가능.
- `Runtime_tier_admission` = **runtime 전체 동시 N개**. tier 가 saturated 면 *그 tier 전체 skip*, next tier 로.

호출 site 순서 (B.2 wire-in 시):
```
try_runtime
  └── [outer] Runtime_tier_admission.with_admission ~tier_id ~admission_policy
        └── per-candidate loop
              └── [inner] acquire_client_capacity_slot candidate  (기존)
                    └── HTTP call
```
Outer 가 tier 단위 reject → runtime 가 next tier. Inner 가 endpoint 단위 reject → 같은 tier 안 next endpoint. *직교*.

§1.2 의 `client_capacity_full` 폭증 (486건/2일) 은 **inner layer (기존) 가 백프레셔 작동 중인 신호** — 본 RFC novel layer 와 무관. *RFC-0088 §1 "telemetry-as-fix" 의 inverse*: counter 가 emit 되는 것이 fix 작동의 증거. regression 으로 트리아지 *하지 말 것*.

#### 4.2.2 Phase B.2 wire-in prerequisite — tier_id plumbing

post-B.1 caller-chain trace (`lib/runtime/runtime_catalog_runtime_named_providers.ml:206`) 에서 발견:

```
keeper_turn_driver.try_runtime
  └── resolve_named_providers_strict_with_secondary_resolver ~runtime_id
        └── lookup_active_profile runtime_id → profile.weighted_entries
              └── direct_candidate_providers_ordered_by_entries  (* flatten *)
        └── { providers : Provider_config.t list; secondary_resolver }
```

`providers` 는 *flattened* provider 리스트로, **parent runtime identity 가 손실**됨. `try_runtime` 가 candidate 를 받을 시점에는 그 candidate 가 어느 runtime 에 속하는지 알 수 없음.

→ Phase B.2 wire-in 의 진짜 prerequisite:
- (a) `resolve_named_providers_strict*` 의 return type 을 `(Provider_config.t * tier_id) list` 로 확장, 또는
- (b) `try_runtime` signature 에 `tier_id_of:(Provider_config.t -> string)` lookup 함수 주입, 또는
- (c) `Runtime_runtime_candidate.t` 자체에 `tier_id` 필드 추가 (build site 에서 채움).

세 옵션 모두 caller chain 5+ 곳에 전파. *B.2 시작 전* 별도 PR 로 plumbing 선행 필요. 본 RFC §11 Phased Rollout 의 B.2 단계를 *B.2.0 plumbing → B.2.1 wire-in* 으로 분할.

#### 4.2.3 Actual implementation — PR #17013 (post-merge audit)

PR #17013 (`feat(runtime): wire tier admission into keeper attempts`, merged 2026-05-20) 가 §4.2.2 의 plumbing prerequisite 을 *bypass* 하고 다른 접근으로 main 에 진입. RFC 와 drift 발생 — 본 sub-section 은 실제 구현 명문화.

| 측면 | §4.2 원래 design | PR #17013 실제 구현 |
|---|---|---|
| Admission unit | per-runtime (runtime.toml `[runtime.X]`) | **per-runtime-name** (`tier_admission_id = runtime_id`) |
| Capacity 설정 | runtime.toml `max_inflight = 8` per group | 단일 `Runtime_tier_admission.create ()` (default cap 8) |
| Policy 결정 | caller site 매핑 (§4.2 본문 테이블) | **per-priority** (`runtime_tier_admission_policy_of_priority : Request_priority.t -> admission_policy`) — Proactive→Required, Background→Bypass |
| Env flag | (별도) | A.2 와 공유: `MASC_RUNTIME_SATURATION_SIGNAL_ENABLED` |

**§4.2.2 plumbing 회피 메커니즘**: `runtime_id` 은 try_runtime entry point 에 이미 있는 식별자. resolver 가 flatten 한 provider 리스트는 *그대로* — admission 결정이 candidate-level 이 아니라 *runtime-call-level* 에서 이루어지므로 tier_id plumbing 불필요.

**Trade-off**:
- ✅ §4.2.2 의 5+ caller chain plumbing 부담 제거. wire-in 3 파일로 완료 (lib/keeper/keeper_turn_driver.{ml,mli} + test).
- ⚠️ per-runtime cap (RFC §4.2 의 원래 motivation) 미실현. 한 runtime_id 안 여러 runtime 이 같은 counter 공유 → tier 간 *상호 starvation* 가능.
- ⚠️ priority 분류가 runtime.toml tier 구조와 *직교* — 한 runtime_id 안 Proactive + Background 가 같은 admission counter 공유.
- ⚠️ `MASC_CLIENT_CAPACITY` (§4.2.1 inner layer) 와 cap 값 정합성 검증 부재.

**Future work**:
- per-runtime granularity 가 측정상 진짜 필요한지 6개월 데이터로 결정 (§5 Phase E).
- 필요 시 §4.2.2 plumbing 의 3 옵션 중 (c) `Runtime_runtime_candidate.t.tier_id` 가 가장 저비용 (build site 한 곳만 변경).
- runtime.toml `max_inflight` 스키마는 *deferred* — 우선 모든 runtime default 8 로 운영하며 saturation signal 분포 측정.

§11 Phased Rollout 의 B.2 단계가 PR #17013 으로 *partial-fulfilled*. runtime.toml 스키마 + per-runtime cap 는 future work.

**runtime.toml 스키마 확장** (deferred per §4.2.3):

```toml
[runtime.strict_tool_candidates]
tiers = [...]
max_inflight = 8                  # NEW (optional, default 8)
admission_wait_ms = 2000          # NEW (optional, default 2000)
```

호출 site: `try_runtime` 의 candidate 진입 직전에 `with_admission` wrap. semaphore 못 얻으면 *다음 tier로 즉시 진행*.

#### 4.2.4 Per-binding HTTP-round-trip gate — root design (supersedes §4.2.3 turn-level wrap)

**Status note**: §4.2.1 의 tier-admission machinery (`Runtime_throttle` / `Runtime_client_capacity` / `Runtime_tier_admission`) 는 RFC-0206 (#19536) runtime rebirth 에서 `lib/runtime*` 전면 삭제와 함께 purge 됨. 본 sub-section 은 binding granularity 로 backpressure 를 재정초한다. frontmatter status 를 `Implemented` → `Active` 로 강등 (기술한 모듈 일부가 더 이상 존재하지 않음).

**문제**: provider endpoint (예: 로컬 ollama, 동시 연결 수 제한 있음) 에 여러 keeper 가 동시에 라우팅될 때, in-flight HTTP 요청 수를 *사전* 제한하는 게이트가 없다. `keeper_binding_health` 는 실패 *후* cooldown (반응형 circuit-breaker) 일 뿐이고, `fd_accountant.ml` 의 `Provider_http` slot 은 단일 process-global FD-class 풀 (provider/model 키 없음) 이다. per-binding 사전 제한이 부재.

**기각된 접근 (turn-level wrap)**: per-binding semaphore 를 `Runtime_agent.run` attempt 전체에 거는 방식. attempt 는 LLM 호출 + 로컬 tool/subprocess 실행을 포함하므로, provider HTTP 와 무관한 로컬 작업 동안에도 provider slot 을 점유 → provider HTTP capacity 와 keeper attempt lifetime 을 혼동.

**채택 (root, R-a')**: slot 을 **provider HTTP round-trip 경계**에서 획득한다. OAS `Llm_provider.Llm_transport.t` (record of `complete_sync` / `complete_stream`) 를 masc 가 decorate 하여, 각 completion 호출 안에서 per-binding `Eio.Semaphore` slot 을 잡고 푼다.

- **OAS 변경 없음**: `Llm_provider.Complete.make_http_transport` (complete.mli, @since 0.78.0) 가 이미 public. masc 는 이미 이 transport 를 만들어 `provider_resource_slot_transport` (Fd_accountant `Provider_http`) 로 decorate 중 (`runtime_agent.ml`). 새 per-binding decorator 를 같은 자리에 layering.
- **경계법 준수**: OAS `provider_throttle.ml` 가 *"concurrency control is the responsibility of the downstream consumer; OAS-level slot queueing would create invisible backpressure the consumer cannot observe"* 로 명시. semaphore registry 는 masc 소유. key = `provider:model@base_url` (`Runtime_provider_binding.provider_health_key_of_config`, OAS-owned `Provider_config.t` identity field 로부터 masc-side 도출).
- **타입**: `max_concurrent` 은 `int option`. `None` = per-binding cap 없음 (coarse global `Fd_accountant.Provider_http` 풀만 적용; "보호 없음" 이 아니라 "per-binding cap 없음"). `0`-as-marker permissive default (CLAUDE.md anti-pattern #2) 제거.
- **backpressure**: slot-wait 가 `wait_timeout_sec` (default·clamp 는 env) 초과 시 typed `Keeper_internal_error.Capacity_backpressure { source = Runtime_slot }` 로 표면화 → `keeper_binding_health` backoff 발화.

**slot lifetime 의미론**:
- **per-HTTP-attempt** — `Complete.complete_with_retry` 의 retry 루프가 transport 호출 *바깥*에 있으므로, decorator 가 transport record 안에 있으면 매 attempt 가 slot 을 재획득한다. backoff 중인 retry 는 slot 을 점유하지 않아 다른 keeper 를 굶기지 않음 (turn-level wrap 대비 개선).
- **streaming** — `complete_stream` 은 SSE 전 구간을 읽고 반환하므로 slot 도 stream 전체 동안 유지. 열린 streaming connection 은 실제로 endpoint capacity 를 점유하므로 물리적으로 옳다. 단 `wait_timeout_sec` 은 worst-case stream 길이를 고려해 sizing.
- **취소-안전** — `Eio.Switch.on_release` 로 release. 단, acquire 가 `with_timeout` race 로 permit 을 받은 채 timeout 으로 표면화되는 edge (Eio semaphore 의 cancel-loses-race) 에서 permit 누수를 막기 위해, permit 획득 직후 동기 플래그를 set 하고 release 를 플래그+Switch 에 결박한다 (match arm 결과값에 의존하지 않음).

**multi-domain 주의**: masc 는 `Eio.Executor_pool` (`domain_count = max 2 (recommended-1)`) 로 multi-domain. `Eio.Semaphore` 의 cross-domain 거동은 **기존에 같은 경계에서 수용된 `Fd_accountant.Provider_http` semaphore 와 동일** (동일 transport record 의 layered decorator 라 항상 같은 domain 에서 실행). 따라서 본 변경은 새 cross-domain 리스크를 도입하지 않으며, cross-domain 강제 enforcement 가 측정상 필요해지면 두 게이트를 함께 마이그레이션한다 (별도 작업).

**direct-caller 통합**: keeper turn 트래픽 (`Runtime_agent.run` → pipeline) 외에, `Complete.complete` 를 `?transport` 없이 직접 호출해 같은 endpoint 를 치는 post-turn 메모리 경로 (`keeper_agent_run_post_turn_memory.ml` 에서 매 turn 발화) 를 같은 per-binding semaphore 로 묶는다 — 호출자와 무관하게 binding 당 총 in-flight 가 하나의 cap 으로 bounded.

- **Memory OS librarian** (`keeper_librarian_runtime.ml`): 자체 unkeyed `Eio.Semaphore.make 1` (전역 1-slot, 산포된 게이트) 을 제거하고 `Runtime_binding_capacity` 로 흡수. binding 의 `max_concurrent` 를 `provider_for_runtime` 에서 같이 가져와 keeper-turn 과 동일 key (`provider:model@base_url`) 의 semaphore 를 공유. librarian 의 fast-fail wait (`MASC_KEEPER_MEMORY_OS_LIBRARIAN_SLOT_WAIT_SEC`, default 0.25s) 는 유지 (포화 시 best-effort memory 작업을 queue 하지 않고 `provider_slot_busy` 로 즉시 skip). librarian 은 본 RFC 가 겨냥한 provider-concurrency 과부하의 문서화된 원인 (memory: 2026-06-15/16 empty-response 53→62% spike).
- **Memory LLM summary** (`keeper_memory_llm_summary.ml`): 동일 post-turn 경로. provider 후보를 `(provider_cfg, max_concurrent)` 쌍으로 resolve 하여 각 완료 호출을 per-binding 게이트로 감쌈. slot wait-timeout 은 Capacity_backpressure `http_error` 로 표면화되어 다음 provider 로 fallback.

- **scope-out (진단 도구)**: runtime probe / bench (`tool_local_runtime_verify.ml` / `tool_local_runtime_bench.ml`) 는 게이트하지 않는다. 이들은 endpoint 의 raw 도달성/지연을 *측정*하는 operator-triggered 진단 도구로, 게이트를 적용하면 keeper 부하에 의해 측정이 왜곡되고 (목적 훼손) 빈도가 낮아 steady-state 부하가 아니다. 정상 keeper/memory 트래픽이 게이트되므로 이 결정은 보호 공백이 아니다.

### 4.3 Phase C — Adaptive Client-Side Throttling (Google SRE §21)

공식: `reject_probability = max(0, (requests − K × accepts) / (requests + 1))` · K=2 · window=2분.

```ocaml
(* NEW: lib/runtime/runtime_adaptive_throttle.ml *)
val create : k:float -> window_sec:int -> t
val maybe_reject : t -> tier_id:string ->
  [ `Proceed | `Reject_with_signal of Runtime_saturation_signal.t ]
val record_attempt : t -> tier_id:string -> success:bool -> unit
```

cold-start 방지: 첫 100 requests 또는 window 충전 전까지 `maybe_reject` 항상 `` `Proceed ``.

### 4.4 Phase D — RFC-0152 보완

**외부 evidence**: OpenClaw 1m→5m→25m→1h fixed ladder validated. EWMA 어디서도 검증 안 됨.

#### D.1 — Fixed Cooldown Ladder (OpenClaw 패턴)

RFC-0152 `Auto_resume_with_backoff` 의 backoff를 fixed step ladder로 명세화:

```ocaml
(* lib/keeper/keeper_supervisor_pause_policy.ml *)
let resume_backoff_ladder_sec = [|60; 300; 1500; 3600|]
(* OpenClaw 패턴: 1m → 5m → 25m → 1h *)
let billing_backoff_ladder_sec = [|18000; 86400|]  (* 5h → 24h *)
```

**masc 실측 주기와의 정렬** (Q8 audit, 2026-05-20):

| 항목 | 값 | 출처 |
|---|---|---|
| Keeper keepalive snapshot interval | 300s default (clamped [15, 3600]) | `lib/config/env_config_keeper.ml:191` |
| Compaction cooldown | 15s default (이전 90s에서 축소) | `lib/keeper/keeper_config.ml:486` |
| Proactive heartbeat interval | 30s | `lib/keeper/keeper_config.ml:484` comment |
| Autonomous max turns/call | 10 default | `lib/keeper/keeper_runtime_resolved.ml:60` |
| Reactive max turns/call | 30 default | 동일 |

Ladder 단계별 의미:

| 단계 | 절대 시간 | 상대 의미 |
|---|---|---|
| `60s` | 2 heartbeats | transient cooldown — 다음 cycle 시도 |
| `300s` | 1 keepalive cycle | 1 turn skip 후 재시도 |
| `1500s` | 5 keepalive cycles | sustained outage; 운영자 인지 시간 |
| `3600s` | max cap | 자동 회복의 상한 (이후 manual 또는 escalation) |

OpenClaw 패턴(1m→5m→25m→1h)이 masc의 5분 keepalive 주기에 자연 정렬됨. 미세 조정은 D.1 머지 후 2주 데이터로 검증.

#### D.2 — EWMA Decay (deferred, 측정 게이트)

D.1 머지 + 2주 운영 후 측정:
- D.1 ladder의 false-positive 회복 비율 측정 (회복 후 즉시 재실패)
- 10%+ 면 EWMA(α=0.2)로 D.2 진행, 미만이면 D.2 deferred

### 4.5 Phase E — Runtime as Scheduler (별도 RFC 후보)

| 특성 | Failover Chain (현) | Scheduler (대안) |
|---|---|---|
| tier 의미 | backup 순위 | 병렬 capacity pool |
| hedged request | 불가능 | 2배 capacity로 p99 절감 |
| deadline propagation | 없음 | top-level deadline 전파 |
| 구현 비용 | — | 고 (runtime.toml 의미 변경, transition 필요) |

§7 세 framework 모두 scheduler 추상 부재 → Phase E는 *MASC novel + 외부 검증 없는* 대형 변경. Phase A-C 머지 + 6개월 운영 데이터 후 별도 RFC.

## 5. Workaround Self-Check (RFC-0088 Umbrella)

| # | 패턴 | 본 RFC 검증 |
|---|---|---|
| 1 | Telemetry-as-Fix | **PASS** — Phase A signal은 Phase B/C 입력. 단독 머지 금지를 PR body에 명시. |
| 2 | String/Substring 분류기 | **PASS** — closed sum type. |
| 3 | N-of-M patch | **조심** — caller exhaustive match 강제 + PR body grep 결과 첨부. |
| 4 | catch-all `_ ->` | **PASS** — exhaustive. |
| 5 | cap/cooldown/dedup/repair | **핵심 검증** — cap을 *제거*가 아닌 *재정의*. §6 self-attack 참조. |
| 6 | test backdoor | **PASS** — 미도입. |
| 7 | codemod 누락 typo fix | **PASS** — 단일 caller. |

## 6. 비판적 검토 — 본 RFC 를 공격함

본인 manifest §"First-class Thinking §7 비판 First":

### 6.1 공격 #1: Phase A 단독 머지 = RFC-0088 §1 정확히
Phase A만 머지되고 B/C가 늦으면 "visible로 만들기만 하고 fix 안 함" — RFC-0088 §1 자체. **완화**: PR body 자체 sunset 약속 ("Phase B 머지 1주 안에 안 일어나면 revert").

### 6.2 공격 #2: Phase B Semaphore 새 deadlock
nested runtime가 같은 semaphore 요구 시 deadlock. **완화**: per-tier semaphore + nested same-tier acquire 금지 invariant (TLA+ 검증). **잔여**: nested runtime 실재 여부 audit (Phase B prerequisite).

### 6.3 공격 #3: Phase C cold-start reject storm
**완화**: 첫 100 req 또는 window 충전 전까지 비활성.

### 6.4 공격 #4: A+B+C 결합 → "보이지 않는" 거절률
**완화**: 모든 거부에 typed signal + dashboard panel.

### 6.5 공격 #5: "그냥 300s를 600s로 늘리면?"
대안: 1줄 PR. **반박**: cap 의미 유지 → stampede / no-queue 문제 그대로. 자원 효율 악화. **잔여**: env override 제공 (`MASC_RUNTIME_MAX_EXECUTION_TIME_S`).

### 6.6 공격 #6: RFC-0152 와의 의미 충돌 (완화됨)
D.1 fixed ladder를 RFC-0152 enum의 *명세 채우기*로 위치 → 의미 확장 아니라 *완성*. owner 동일 (vincent).

### 6.7 공격 #7: MASC novel 영역의 무모성
Phase B/C/E는 세 framework 모두 안 함. **완화**: tower::limit::ConcurrencyLimit (Rust) production validated 사례 존재 → novel은 sub-pattern 단위, full pattern은 아님. Phase B 시작 전 "framework들이 피한 사례" 추가 조사.

### 6.8 공격 #8 (post-merge, Q7 audit 기반): Phase B 무차별 admission → side task starvation

**증상**: Phase A.1 merge (PR #16965) 후 Q7 audit에서 runtime named-provider resolution의 *4-5개 독립 entry point* 가 발견됨:
- `keeper_turn_driver` (main keeper turn — main production traffic)
- `keeper_stale_watchdog:692` (runtime health probe — *production이 saturated일 때 더 자주 호출되어야 함*)
- `keeper_run_tools:757` (tool execution)
- `keeper_memory_llm_summary:220` (memory summary — side task)
- `runtime_runtime.ml:638,660,709` (runtime entry points)

**공격**: Phase B의 admission semaphore가 위 entry point에 *무차별* 적용되면:
1. watchdog probe가 production load에 막혀 *runtime health를 측정 못 함* (self-defeating)
2. memory summary 같은 side task가 영원히 starve
3. 최악의 경우: probe가 "unhealthy" 판단을 못 내려서 RFC-0127 의 fast-fail path가 작동 안 함 → RFC-0153 자체가 RFC-0127을 무력화

**완화** (§4.2에 반영):
- `with_admission` 시그니처에 `~admission_policy:[ \`Required | \`Bypass ]` 명시적 파라미터
- main keeper_turn path만 `Required`
- watchdog / memory_summary / 기타 side task는 `Bypass`
- `keeper_run_tools` / `runtime_runtime` entry point는 Phase B 시작 시 case-by-case audit
- TLA+ `NoNestedSameTierAdmission` invariant에 *bypass path는 acquire 카운터에 무영향* 명시

**잔여 위험**: caller policy 매핑이 잘못되면 (예: main을 Bypass로 설정) backpressure 효과가 무력. 완화책으로 default 값 없이 *caller가 반드시 명시*하도록 시그니처 강제 + lint으로 매핑 검증.

**왜 #8이 #2 (nested deadlock)와 다른가**: #2는 동일 caller의 nested runtime를 우려 (자기재귀 = OK, 별도 fiber = 위험). #8은 *별개의 caller chain*이 같은 자원을 요구하는 경합. #2는 TLA+로 검증, #8은 *policy enum 강제*로 검증.

## 7. 외부 시스템 비교

> 백그라운드 research agent가 세 repo를 실제 fetch 후 인용. 라인 환각 없음. Full evidence → HTML §7.

### 7.1 Hermes Agent (NousResearch)
- `agent/chat_completion_helpers.py::try_activate_fallback(FailoverReason)` — `_fallback_index` advance, primary 떠날 때만 60s cooldown.
- `agent/nous_rate_guard.py::is_genuine_nous_rate_limit` — quota vs upstream transient 분리 (시안 A 동일 원칙).
- `agent/rate_limit_tracker.py` — passive header parsing only, 차단 X.
- **queue/semaphore 없음**.

### 7.2 OpenClaw
- `src/provider-runtime/operation-retry.ts::executeProviderOperationWithRetry` — `base*2^(n-1)` backoff.
- **`docs/concepts/retry.md` 핵심**: SDK wait > 60s → `x-should-retry: false` inject → failover escalate. **시안 A 직접 검증**.
- `docs/concepts/model-failover.md` — cooldown ladder 1m→5m→25m→1h cap (billing 5h→24h), `auth-state.json` persist. **시안 D.1 직접 검증**.
- **semaphore/queue/admission 없음**.

### 7.3 OpenHands SDK
- `openhands-sdk/openhands/sdk/llm/llm.py` — tenacity-based retry, `LLM_RETRY_EXCEPTIONS`.
- `openhands-sdk/openhands/sdk/llm/fallback_strategy.py::FallbackStrategy.try_fallback()` — Nested fallback 명시적 차단 (`saved_strategy=fb.fallback_strategy; fb.fallback_strategy=None`).
- `_litellm_modify_params_lock: threading.RLock` 단 하나. **queue/semaphore 없음**.
- 본 RFC 공격 #2 (nested admission deadlock) 의 **방어 사례로 참조 가치**.

### 7.4 종합

세 framework 모두 masc `try_runtime`와 동일한 sequential per-call fallback chain. 결론:

- **시안 A**: OpenClaw가 직접 검증 (production).
- **시안 D.1**: OpenClaw 1m→5m→25m→1h validated.
- **시안 B/C/E**: 셋 다 부재. MASC novel territory (정직히 표기). Google SRE Handbook §21 (C) + Rust tower::limit (B) 가 외부 reference.

## 8. TLA+ Bug Model

- `spec/RuntimeSaturationSignal.tla` (Phase A)
- `spec/RuntimeTierAdmission.tla` (Phase B)
- `spec/RuntimeAdaptiveThrottle.tla` (Phase C)

**Safety**:
- `SaturationSignalNeverLost` — saturation 시 항상 typed signal emit.
- `NoNestedSameTierAdmission` — fiber stack 같은 tier 중첩 acquire 금지 (OpenHands 패턴 응용).
- `AdaptiveThrottleNoColdStartReject` — window 충전 전 reject_probability=0.

**Liveness**:
- `SaturationSignalEventuallyConsumed`
- `AdmissionEventuallyGrants` (admission_wait_ms 안에 grant 또는 typed reject)

**Bug actions**:
- `BugSignalEmittedButFixMissing` (Phase A 단독)
- `BugNestedAdmissionDeadlock`
- `BugColdStartRejectStorm`

## 9. 검증 계획

| Surface | Test | Pass |
|---|---|---|
| Phase A signal | `test_runtime_saturation_signal.ml` | JSON round-trip + log_string |
| Phase A caller | `test_keeper_turn_runtime_budget_signal.ml` | 300s timer 시뮬레이션 → `Time_cap_fired` |
| Phase B admission | `test_runtime_tier_admission.ml` | concurrent acquire + max_inflight 초과 reject |
| Phase B no-deadlock | QCheck property | 1000회 random, deadlock 0건 |
| Phase C throttle | `test_runtime_adaptive_throttle.ml` | 50% fail tier → reject ratio 50%±10% |
| Phase C cold-start | `test_throttle_cold_start.ml` | 첫 100 req Proceed |
| E2E stampede | `test_runtime_stampede_e2e.ml` | 16 keeper × 동시 turn → 진입 *순차화* |
| 회귀 | 기존 `test_runtime_*` | green |

## 10. Phase 분할 + 구현 순서

| Phase | Files | LoC | 위험 | Rollback |
|---|---|---|---|---|
| 0 (본 RFC) | `docs/rfc/RFC-0153-*.md` | docs | none | revert |
| **A.1** signal module | `lib/runtime/runtime_saturation_signal.ml{,i}` + test | ~250 | low | revert |
| A.2 caller dispatch | keeper_turn_runtime_budget 1-2 site | ~150 | medium | env flag |
| B.1 admission module | `lib/runtime/runtime_tier_admission.ml{,i}` + test | ~300 | medium | env flag |
| B.2 toml 스키마 | config parser | ~100 | low | revert |
| C.1 throttle | `lib/runtime/runtime_adaptive_throttle.ml{,i}` + test | ~250 | medium | env flag |
| C.2 wire-in | `try_runtime` 1 site | ~50 | medium | env flag |
| D.1 fixed ladder | `keeper_supervisor_pause_policy` | ~80 | low | revert |
| D.2 EWMA (deferred) | `keeper_supervisor_pause_policy` | ~150 | medium | RFC-0152 owner 협의 |
| E (별도 RFC) | — | — | — | — |

**구현 순서**:
1. 본 RFC body + ledger advance (RFC-0153 reservation, Draft PR open 즉시)
2. Phase A.1 (추가만) ← **오늘**
3. Phase A.2 (env flag 뒤) ← 사용자 검토 ★
4. Phase B.1 + B.2 (env flag 뒤) ← 사용자 검토 ★
5. 1주 운영 + dashboard 가시화
6. Phase C.1 + C.2 (env flag 뒤)
7. Phase D.1
8. 2주 운영 → D.2 진행 여부 결정
9. env flag 제거 (별도 PR cluster)
10. Phase E 별도 RFC 작성 여부 결정

## 11. Risks / Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Phase A 단독 머지 = 텔레메트리-as-fix | Medium | High | PR body hard deadline + revert 약속 |
| Phase B nested admission deadlock | Medium | High | per-tier semaphore + TLA+ + OpenHands `saved_strategy=None` 패턴 |
| Phase C cold-start reject storm | Medium | Medium | 첫 100 req 비활성 |
| "보이지 않는" 거절률 증가 | Medium | Medium | typed signal + dashboard |
| RFC-0152 의미 충돌 | Low | Medium | D.1을 RFC-0152 명세 채우기로 위치 |
| 운영자가 "300s 늘리고 싶음" | High | Low | env override |
| runtime.toml 스키마 break | Low | High | default 값 + 미설정 시 현 동작 |
| RFC 번호 race | Medium | Medium | Draft PR 즉시 push + git fetch 검증 |
| MASC novel territory (B/C/E) | Medium | Medium | incremental rollout + env flag + 2주 운영 게이트 |

## 12. Open Questions

1. `max_inflight` default 8 적정? — 운영 데이터 (16 keeper × ~0.5 req/min)로 검증.
2. Phase A "남은 turn deadline" 어디서 가져오나? `keeper_turn_runtime_budget` 확인 필요.
3. Phase B semaphore fiber 단위 vs process 단위? Eio.Semaphore는 fiber-local.
4. Phase C K=2 (SRE 권장) 적합? — 첫 deploy K=4 보수적, 1주 후 K=2.
5. ~~신규 회귀 `client_capacity_full` 486건/2일이 본 RFC와 관련 있나?~~ — **RESOLVED (§4.2.1 layer matrix)**: regression 아님. 기존 `Runtime_client_capacity` (per-URL) 백프레셔 작동 신호. 별도 트리아지 불필요.
6. Phase E 데이터 기반 의사결정에 필요한 metric — Phase A signal 분포 + Phase B 거부율 + Phase C reject ratio. 6개월 데이터.
7. Phase B nested runtime audit — 실제 코드에 nested runtime가 있나? Phase B prerequisite.
8. D.1 fixed ladder의 단계(1m→5m→25m→1h)가 masc keeper turn 주기 (5-15분 compaction)에 맞는가? — 미세 조정.

## 13. References

### 코드
- `lib/keeper/keeper_turn_driver.ml:757-908` — `try_runtime`
- `lib/keeper/keeper_turn_driver.ml:1330` — "runtime exhausted" 로그
- `lib/keeper/keeper_turn_driver.ml:1477-1484` — Admission_queue (turn level)
- `lib/runtime/runtime_runner.ml:44` — `max_execution_time_s`
- `lib/keeper/keeper_turn_runtime_budget.ml:47` — time cap consumption
- `lib/runtime/runtime_error_classify.ml:22-25` — `Runtime_exhausted` (기존)

### 런타임 Evidence
- `<base-path>/.masc/runtime_audit/2026-05/*.jsonl` — 14일치 8917 attempt
- `<base-path>/.masc/logs/masc-provider-k-three-20260516T0152.log` — 02:34 peak 19/min stampede
- `<base-path>/.masc/logs/masc-8935.log` — 03:22:47~48 sangsu 사건 사슬

### 관련 RFC
- RFC-0009 / 0022 / 0042 / 0082 / 0088 / 0102 / 0127 / 0152

### 외부 시스템
- OpenClaw (https://github.com/openclaw/openclaw) — `docs/concepts/retry.md`, `docs/concepts/model-failover.md`, `src/provider-runtime/operation-retry.ts`
- Hermes Agent (https://github.com/NousResearch/hermes-agent) — `agent/chat_completion_helpers.py`, `agent/nous_rate_guard.py`, `agent/rate_limit_tracker.py`, `agent/retry_utils.py`
- OpenHands SDK (https://github.com/OpenHands/software-agent-sdk) — `openhands-sdk/openhands/sdk/llm/llm.py`, `openhands-sdk/openhands/sdk/llm/fallback_strategy.py`
- Google SRE Handbook §21 "Handling Overload" (https://sre.google/sre-book/handling-overload/)
- Netflix Hystrix (https://github.com/Netflix/Hystrix/wiki/How-it-Works) — deprecated 2018
- Rust tower::limit (https://docs.rs/tower/latest/tower/limit/index.html)

### 사용자 manifest 준수
- §"Anti-Hype Rules" / §"First-class Thinking §7 비판 First" / §"워크어라운드 거부 기준" / §"TLA+ Bug Model" / §"3-Try Rule" / §"외부 연구 인용 출처"

---

본 RFC 는 **Draft**. 사용자 승인 후 Phase A.1 부터 단계별 PR.
