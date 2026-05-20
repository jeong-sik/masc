---
rfc: "0153"
title: "Cascade Backpressure & Tier Admission"
status: Draft
created: 2026-05-20
updated: 2026-05-20 (post-merge audit: §6.8 + §4.2 admission_policy + §4.4 measurements)
author: vincent
supersedes: []
superseded_by: null
related: ["0009", "0022", "0042", "0082", "0088", "0102", "0127", "0152"]
implementation_prs: ["#16965 (Phase A.1, merged 2026-05-20T12:25:11Z)"]
---

# RFC-0153 — Cascade Backpressure & Tier Admission

> Canonical HTML design doc: `~/me/memory/masc-mcp-rfc-0153-cascade-backpressure-2026-05-20.html` (full evidence tables, external research §7, design rationale).
>
> 본 markdown은 docs/rfc/ canonical 위치를 채우는 RFC body. 사용자 검토 후 Phase A.1 부터 단계별 PR.

## 0. TL;DR

`cascade_audit` 14일치 8917 attempt 중 43.5% 실패. "cascade 소진"이라 분류된 사건의 **80%+**가 실제로는 `max_execution_time_s 300s` hard timer fire의 *downstream symptom* — cascade routing 자체의 문제가 아니라 watchdog가 죽이는 것. 회복은 사용자 수동 `update_keeper resumed` 만 가능 (최근 paused 약 5시간 방치).

근본 원인: `try_cascade` (lib/keeper/keeper_turn_driver.ml ~757-908) 는 tier-by-tier sequential failover, **tier-level concurrency primitive 부재**. N개 keeper가 saturated tier에 동시 stampede → 동시 fail. 300s wall-clock가 cascade·context·turn 세 budget을 동시에 죽이는 공통 trigger.

제안 5단계:
- **Phase A** — Time cap 의미 분리 (kill switch → typed `Cascade_saturation_signal`). OpenClaw `x-should-retry: false` 패턴 차용 (§7).
- **Phase B** — Tier-level admission semaphore (Eio.Semaphore per tier-group).
- **Phase C** — Adaptive client-side throttling (Google SRE Handbook §21 공식).
- **Phase D** — RFC-0152 보완. **D.1** fixed cooldown ladder (OpenClaw 1m→5m→25m→1h validated). **D.2** EWMA decay (novel, deferred).
- **Phase E** — Cascade → deadline-aware scheduler 재모델링 (별도 RFC 후보, 6개월 운영 데이터 후).

비-목표: RFC-0127의 provider-side fast-fail 영역, transient_http_status 분류 수정, last_blocker (RFC-0082, BLOCKED), 새 wire-format.

## 1. Problem

### 1.1 코드 증거 — sequential failover, 동시성 부재

`lib/keeper/keeper_turn_driver.ml` `try_cascade` 내부:

```ocaml
let rec try_cascade candidates ... =
  match candidates with
  | [] -> Error Exhausted              (* 빈 리스트 = 즉시 종결 *)
  | candidate :: rest ->
      (* 단일 candidate 실행 → 실패 시 *)
      try_cascade rest new_err          (* tail-recursion, 동시성 X *)
```

| 점검 항목 | 현 상태 |
|---|---|
| Eio.Stream / Semaphore / Pool at tier level | 사용 안 함 |
| `Admission_queue` 적용 지점 | keeper-turn 입장 시점만 (라인 1477-1484), tier 진입에는 없음 |
| Cascade × Turn × Context 교차 함수 | 없음. 셋이 독립 layer, 같은 300s timer만 공유 |
| 동시 N개 cascade 요청의 tier 진입 제어 | 없음 — stampede 가능 |
| "cascade exhausted" 로그 사이트 | ~1330 (all tiers failed), ~1153 (rejected by accept predicate) |

### 1.2 런타임 증거 — 14일치 측정 (`<base-path>/.masc/cascade_audit/2026-05/`)

| 분류 | 건수 / 비율 |
|---|---|
| 전체 attempt | 8917 / 14일 |
| failure 비율 | 3877 / 43.5% |
| cascade_exhausted (서버 로그) | 419건 (glm-three 263 + restart 124 + 8935 12 + hotfix 20) |
| 그 중 사유 = `candidates_filtered_after_cycles` | 123/123 (100%) — **downstream symptom** |
| 그 중 메시지 = `max_execution_time_s 300s` | 138 중 57이 정확히 300.0s 동률 — **real root** |
| cascade_exhausted at minute peak (glm-three 05-16) | 02:34 = 19/min, 02:27 = 18/min |
| `client_capacity_full` 폭증 (2026-05-19~20) | 486건/2일 (이전 0) — 기존 `Cascade_client_capacity` (per-URL, ollama 등) 백프레셔 *작동 중* signal. regression 아닐 가능성 큼 — §4.2 layer matrix 참조 |
| 회복 방식 | 100% 사용자 수동 `update_keeper resumed` (최근 paused_since = 18137s) |
| auto-resume 작동 | 사실상 비활성 (`failure_ratio` 게이트 즉시 차단) |

### 1.3 사건 사슬 — 03:22:47~48 sangsu (대표 사례)

1. tier-group `strict_tool_candidates` 시도
2. `max_execution_time 300s` hard timer fire
3. cascade가 즉시 다음 후보로 ⇒ `productive slot 180s exhausted after 300.3s`
4. "all cascades exhausted (terminal)" — 모두 1초 내 발생

같은 timer 한 번이 cascade·context·turn 셋을 동시에 죽임. "3중 소진"은 *원인 3개*가 아니라 *결과 3면*.

### 1.4 사용자의 의문 — "왜 wait/queue 안 함?"

**그런 객체 자체가 존재하지 않음**. cascade는 처음부터 *단일-요청 failover chain*으로 모델링됐고, "여러 keeper가 동시에 같은 tier로 가는 상황"이 1급 시민이 아님. RFC-0102 (pre-turn gate)가 admission *직전* 한 layer를 추가했지만 tier 진입 후의 동시성은 여전히 부재.

## 2. Goals / Non-goals

### Goals

- **G1.** Cascade·context·turn 소진의 *공통 trigger* (300s wall-clock)을 분리하여, 각 layer가 자기 budget만 책임지게 함.
- **G2.** Tier saturation을 *failure*가 아니라 *typed signal*로 모델링 — caller가 결정 (즉시 fail / deadline 내 wait / degraded path).
- **G3.** 동시 N개 keeper의 stampede를 tier-level admission semaphore로 차단.
- **G4.** Adaptive throttling으로 *failure 상태의 tier에 부담 안 줌*.
- **G5.** RFC-0152 의 auto-resume에 시간감쇠 — D.1 fixed ladder → D.2 EWMA (측정 후).

### Non-goals

- Provider health probe redesign (RFC-0127).
- `transient_http_status` 분류 수정.
- `cascade.toml` tier-group 멤버 선택 전략.
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

**왜 RFC-0127 / 0152 의 Phase가 아니라 신규 RFC인가**: RFC-0127은 *provider error* 발생 시의 cascade 반응, 본 RFC는 *latency가 길어져서 watchdog가 죽이려 할 때*의 cascade 반응. 다른 trigger. RFC-0152는 *pause된 keeper의 복귀*, 본 RFC는 *애초에 pause로 떨어지지 않도록* backpressure. Phase로 들어가면 추상 경계가 흐려짐.

## 4. Design

### 4.1 Phase A — Time Cap → Typed Saturation Signal (OpenClaw-validated)

**외부 검증 (§7)**: OpenClaw `docs/concepts/retry.md` — Provider SDK가 60s+ wait 권고 시 OpenClaw가 `x-should-retry: false` *inject*하여 SDK 내부 wait 끊고 model failover로 escalate. 본 RFC Phase A 가 정확히 동일 패턴.

**현 동작** (`lib/cascade/cascade_runner.ml:44`, `lib/keeper/keeper_turn_cascade_budget.ml:47`):
```
300s timer fire → cascade attempt cancelled
  → 다음 candidate가 "cooldown" 으로 필터됨 (이전 candidate가 300s 동안 fail 처리됐으므로)
  → candidates_filtered_after_cycles 로그
  → keeper pause + "cascade exhausted" 표시
```

**제안 — typed Saturation signal 추출**:

```ocaml
(* NEW: lib/cascade/cascade_saturation_signal.ml *)
type t =
  | Provider_rate_limited of { provider_id : string; retry_after_ms : int option }
  | Time_cap_fired of {
      observed_latency_ms : int;
      cap_ms : int;
      provider_id : string option;
    }
  | All_tiers_filtered_after_cycles of {
      cascade_name : string;
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

**caller dispatch** (`lib/keeper/keeper_turn_cascade_budget.ml`):

```ocaml
match Cascade_saturation_signal.classify ~elapsed_ms ~cause with
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
(* NEW: lib/cascade/cascade_tier_admission.ml *)
type tier_id = string

type admission_policy =
  | Required          (* main keeper_turn path; semaphore acquire 강제 *)
  | Bypass            (* side task (probe, memory summary, run_tools);
                         semaphore 우회. starvation 방지 *)

type t = {
  semaphores : (tier_id, Eio.Semaphore.t) Hashtbl.t;
  config     : (tier_id, int (* max_inflight *)) Hashtbl.t;
}

val create : Cascade_config.t -> t

val with_admission :
  t ->
  tier_id:tier_id ->
  deadline_ms:int ->
  admission_policy:admission_policy ->  (* NEW (§6.8) *)
  (unit -> 'a) ->
  ('a, Cascade_saturation_signal.t) result
(** [admission_policy = Bypass] 일 때 semaphore acquire 없이 즉시 진행.
    side task가 production traffic에 의해 starve되지 않도록 *명시적*
    분리 — default은 없음 (caller가 반드시 결정). *)
```

**Caller policy 매핑** (Q7 audit 기반):

| Caller | admission_policy | 근거 |
|---|---|---|
| `keeper_turn_driver.try_cascade` (main keeper turn) | `Required` | main production traffic; backpressure 의도 |
| `keeper_stale_watchdog:692` (cascade health probe) | `Bypass` | probe가 production load 측정해야 함; semaphore에 묶이면 self-defeating |
| `keeper_run_tools:757` (tool execution) | 검토 후 결정 | 일반적으로 main turn 내부 nested fiber — Phase B 시작 시 audit |
| `keeper_memory_llm_summary:220` (memory summary) | `Bypass` | side task; production traffic에 양보 |
| `cascade_runtime.ml:638,660,709` | 검토 후 결정 | runtime 측 entry point — caller에 따라 결정 |

> 기존 `Admission_queue` (turn-level, lib/cascade/cascade_error_classify.ml `Admission_queue_*` variant) 와 명확히 구분하기 위해 module 이름을 `cascade_tier_admission` 로 명명.

#### 4.2.1 기존 admission/capacity layer 와의 관계 (post-B.1 정리)

`Cascade_tier_admission` 은 *신규 layer*. 기존 코드베이스에 *유사 의도*의 module이 4개 존재 — 같은 추상으로 잘못 흡수하지 말 것.

| Module | 단위 | 동기 | 호출 site | 작동 방식 |
|---|---|---|---|---|
| `Cascade_throttle` (기존) | per-URL | llama-server `/slots` Discovery — server-reported capacity | 자동 (Discovery loop) | server-side slot 수치 미러링 |
| `Cascade_client_capacity` (기존, @since 0.9.6) | **per-URL endpoint** | ollama 등 slot 개념 없는 server 보호 — 같은 GPU 동시 hammer 방지 | `keeper_turn_driver.acquire_client_capacity_slot` (try_cascade 안) | `MASC_CLIENT_CAPACITY` env 로 register, `try_acquire` → `None` 시 cascade 가 next candidate (no queueing) |
| `Admission_queue_*` variants (기존) | turn-level | error classification — provider 가 admission queue 거부 신호 보낼 때 | `cascade_error_classify.ml` 안 | error→retry 정책 분기 |
| **`Cascade_tier_admission`** (NEW, B.1) | **per-tier-group** | tier 전체 동시성 cap — 같은 tier 안 여러 endpoint 합산 admission | (B.2 wire-in 예정) `try_cascade` *outer wrap* | `with_admission` → `Capacity_full` signal emit, cascade 가 next tier |

핵심 차이:
- `Cascade_client_capacity` = **endpoint(URL) 1개당 동시 N개**. 한 endpoint 가 saturated 면 *같은 tier 안 다른 endpoint* 시도 가능.
- `Cascade_tier_admission` = **tier-group 전체 동시 N개**. tier 가 saturated 면 *그 tier 전체 skip*, next tier 로.

호출 site 순서 (B.2 wire-in 시):
```
try_cascade
  └── [outer] Cascade_tier_admission.with_admission ~tier_id ~admission_policy
        └── per-candidate loop
              └── [inner] acquire_client_capacity_slot candidate  (기존)
                    └── HTTP call
```
Outer 가 tier 단위 reject → cascade 가 next tier. Inner 가 endpoint 단위 reject → 같은 tier 안 next endpoint. *직교*.

§1.2 의 `client_capacity_full` 폭증 (486건/2일) 은 **inner layer (기존) 가 백프레셔 작동 중인 신호** — 본 RFC novel layer 와 무관. *RFC-0088 §1 "telemetry-as-fix" 의 inverse*: counter 가 emit 되는 것이 fix 작동의 증거. regression 으로 트리아지 *하지 말 것*.

#### 4.2.2 Phase B.2 wire-in prerequisite — tier_id plumbing

post-B.1 caller-chain trace (`lib/cascade/cascade_catalog_runtime_named_providers.ml:206`) 에서 발견:

```
keeper_turn_driver.try_cascade
  └── resolve_named_providers_strict_with_secondary_resolver ~cascade_name
        └── lookup_active_profile cascade_name → profile.weighted_entries
              └── direct_candidate_providers_ordered_by_entries  (* flatten *)
        └── { providers : Provider_config.t list; secondary_resolver }
```

`providers` 는 *flattened* provider 리스트로, **parent tier-group identity 가 손실**됨. `try_cascade` 가 candidate 를 받을 시점에는 그 candidate 가 어느 tier-group 에 속하는지 알 수 없음.

→ Phase B.2 wire-in 의 진짜 prerequisite:
- (a) `resolve_named_providers_strict*` 의 return type 을 `(Provider_config.t * tier_id) list` 로 확장, 또는
- (b) `try_cascade` signature 에 `tier_id_of:(Provider_config.t -> string)` lookup 함수 주입, 또는
- (c) `Cascade_runtime_candidate.t` 자체에 `tier_id` 필드 추가 (build site 에서 채움).

세 옵션 모두 caller chain 5+ 곳에 전파. *B.2 시작 전* 별도 PR 로 plumbing 선행 필요. 본 RFC §11 Phased Rollout 의 B.2 단계를 *B.2.0 plumbing → B.2.1 wire-in* 으로 분할.

**cascade.toml 스키마 확장**:

```toml
[tier-group.strict_tool_candidates]
tiers = [...]
max_inflight = 8                  # NEW (optional, default 8)
admission_wait_ms = 2000          # NEW (optional, default 2000)
```

호출 site: `try_cascade` 의 candidate 진입 직전에 `with_admission` wrap. semaphore 못 얻으면 *다음 tier로 즉시 진행*.

### 4.3 Phase C — Adaptive Client-Side Throttling (Google SRE §21)

공식: `reject_probability = max(0, (requests − K × accepts) / (requests + 1))` · K=2 · window=2분.

```ocaml
(* NEW: lib/cascade/cascade_adaptive_throttle.ml *)
val create : k:float -> window_sec:int -> t
val maybe_reject : t -> tier_id:string ->
  [ `Proceed | `Reject_with_signal of Cascade_saturation_signal.t ]
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

**masc-mcp 실측 주기와의 정렬** (Q8 audit, 2026-05-20):

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

OpenClaw 패턴(1m→5m→25m→1h)이 masc-mcp의 5분 keepalive 주기에 자연 정렬됨. 미세 조정은 D.1 머지 후 2주 데이터로 검증.

#### D.2 — EWMA Decay (deferred, 측정 게이트)

D.1 머지 + 2주 운영 후 측정:
- D.1 ladder의 false-positive 회복 비율 측정 (회복 후 즉시 재실패)
- 10%+ 면 EWMA(α=0.2)로 D.2 진행, 미만이면 D.2 deferred

### 4.5 Phase E — Cascade as Scheduler (별도 RFC 후보)

| 특성 | Failover Chain (현) | Scheduler (대안) |
|---|---|---|
| tier 의미 | backup 순위 | 병렬 capacity pool |
| hedged request | 불가능 | 2배 capacity로 p99 절감 |
| deadline propagation | 없음 | top-level deadline 전파 |
| 구현 비용 | — | 고 (cascade.toml 의미 변경, transition 필요) |

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
nested cascade가 같은 semaphore 요구 시 deadlock. **완화**: per-tier semaphore + nested same-tier acquire 금지 invariant (TLA+ 검증). **잔여**: nested cascade 실재 여부 audit (Phase B prerequisite).

### 6.3 공격 #3: Phase C cold-start reject storm
**완화**: 첫 100 req 또는 window 충전 전까지 비활성.

### 6.4 공격 #4: A+B+C 결합 → "보이지 않는" 거절률
**완화**: 모든 거부에 typed signal + dashboard panel.

### 6.5 공격 #5: "그냥 300s를 600s로 늘리면?"
대안: 1줄 PR. **반박**: cap 의미 유지 → stampede / no-queue 문제 그대로. 자원 효율 악화. **잔여**: env override 제공 (`MASC_CASCADE_MAX_EXECUTION_TIME_S`).

### 6.6 공격 #6: RFC-0152 와의 의미 충돌 (완화됨)
D.1 fixed ladder를 RFC-0152 enum의 *명세 채우기*로 위치 → 의미 확장 아니라 *완성*. owner 동일 (vincent).

### 6.7 공격 #7: MASC novel 영역의 무모성
Phase B/C/E는 세 framework 모두 안 함. **완화**: tower::limit::ConcurrencyLimit (Rust) production validated 사례 존재 → novel은 sub-pattern 단위, full pattern은 아님. Phase B 시작 전 "framework들이 피한 사례" 추가 조사.

### 6.8 공격 #8 (post-merge, Q7 audit 기반): Phase B 무차별 admission → side task starvation

**증상**: Phase A.1 merge (PR #16965) 후 Q7 audit에서 `Cascade_catalog_runtime.resolve_named_providers_strict` 의 *4-5개 독립 entry point* 가 발견됨:
- `keeper_turn_driver` (main keeper turn — main production traffic)
- `keeper_stale_watchdog:692` (cascade health probe — *production이 saturated일 때 더 자주 호출되어야 함*)
- `keeper_run_tools:757` (tool execution)
- `keeper_memory_llm_summary:220` (memory summary — side task)
- `cascade_runtime.ml:638,660,709` (runtime entry points)

**공격**: Phase B의 admission semaphore가 위 entry point에 *무차별* 적용되면:
1. watchdog probe가 production load에 막혀 *cascade health를 측정 못 함* (self-defeating)
2. memory summary 같은 side task가 영원히 starve
3. 최악의 경우: probe가 "unhealthy" 판단을 못 내려서 RFC-0127 의 fast-fail path가 작동 안 함 → RFC-0153 자체가 RFC-0127을 무력화

**완화** (§4.2에 반영):
- `with_admission` 시그니처에 `~admission_policy:[ \`Required | \`Bypass ]` 명시적 파라미터
- main keeper_turn path만 `Required`
- watchdog / memory_summary / 기타 side task는 `Bypass`
- `keeper_run_tools` / `cascade_runtime` entry point는 Phase B 시작 시 case-by-case audit
- TLA+ `NoNestedSameTierAdmission` invariant에 *bypass path는 acquire 카운터에 무영향* 명시

**잔여 위험**: caller policy 매핑이 잘못되면 (예: main을 Bypass로 설정) backpressure 효과가 무력. 완화책으로 default 값 없이 *caller가 반드시 명시*하도록 시그니처 강제 + lint으로 매핑 검증.

**왜 #8이 #2 (nested deadlock)와 다른가**: #2는 동일 caller의 nested cascade를 우려 (자기재귀 = OK, 별도 fiber = 위험). #8은 *별개의 caller chain*이 같은 자원을 요구하는 경합. #2는 TLA+로 검증, #8은 *policy enum 강제*로 검증.

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

세 framework 모두 masc-mcp `try_cascade`와 동일한 sequential per-call fallback chain. 결론:

- **시안 A**: OpenClaw가 직접 검증 (production).
- **시안 D.1**: OpenClaw 1m→5m→25m→1h validated.
- **시안 B/C/E**: 셋 다 부재. MASC novel territory (정직히 표기). Google SRE Handbook §21 (C) + Rust tower::limit (B) 가 외부 reference.

## 8. TLA+ Bug Model

- `spec/CascadeSaturationSignal.tla` (Phase A)
- `spec/CascadeTierAdmission.tla` (Phase B)
- `spec/CascadeAdaptiveThrottle.tla` (Phase C)

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
| Phase A signal | `test_cascade_saturation_signal.ml` | JSON round-trip + log_string |
| Phase A caller | `test_keeper_turn_cascade_budget_signal.ml` | 300s timer 시뮬레이션 → `Time_cap_fired` |
| Phase B admission | `test_cascade_tier_admission.ml` | concurrent acquire + max_inflight 초과 reject |
| Phase B no-deadlock | QCheck property | 1000회 random, deadlock 0건 |
| Phase C throttle | `test_cascade_adaptive_throttle.ml` | 50% fail tier → reject ratio 50%±10% |
| Phase C cold-start | `test_throttle_cold_start.ml` | 첫 100 req Proceed |
| E2E stampede | `test_cascade_stampede_e2e.ml` | 16 keeper × 동시 turn → 진입 *순차화* |
| 회귀 | 기존 `test_cascade_*` | green |

## 10. Phase 분할 + 구현 순서

| Phase | Files | LoC | 위험 | Rollback |
|---|---|---|---|---|
| 0 (본 RFC) | `docs/rfc/RFC-0153-*.md` | docs | none | revert |
| **A.1** signal module | `lib/cascade/cascade_saturation_signal.ml{,i}` + test | ~250 | low | revert |
| A.2 caller dispatch | keeper_turn_cascade_budget 1-2 site | ~150 | medium | env flag |
| B.1 admission module | `lib/cascade/cascade_tier_admission.ml{,i}` + test | ~300 | medium | env flag |
| B.2 toml 스키마 | config parser | ~100 | low | revert |
| C.1 throttle | `lib/cascade/cascade_adaptive_throttle.ml{,i}` + test | ~250 | medium | env flag |
| C.2 wire-in | `try_cascade` 1 site | ~50 | medium | env flag |
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
| cascade.toml 스키마 break | Low | High | default 값 + 미설정 시 현 동작 |
| RFC 번호 race | Medium | Medium | Draft PR 즉시 push + git fetch 검증 |
| MASC novel territory (B/C/E) | Medium | Medium | incremental rollout + env flag + 2주 운영 게이트 |

## 12. Open Questions

1. `max_inflight` default 8 적정? — 운영 데이터 (16 keeper × ~0.5 req/min)로 검증.
2. Phase A "남은 turn deadline" 어디서 가져오나? `keeper_turn_cascade_budget` 확인 필요.
3. Phase B semaphore fiber 단위 vs process 단위? Eio.Semaphore는 fiber-local.
4. Phase C K=2 (SRE 권장) 적합? — 첫 deploy K=4 보수적, 1주 후 K=2.
5. ~~신규 회귀 `client_capacity_full` 486건/2일이 본 RFC와 관련 있나?~~ — **RESOLVED (§4.2.1 layer matrix)**: regression 아님. 기존 `Cascade_client_capacity` (per-URL) 백프레셔 작동 신호. 별도 트리아지 불필요.
6. Phase E 데이터 기반 의사결정에 필요한 metric — Phase A signal 분포 + Phase B 거부율 + Phase C reject ratio. 6개월 데이터.
7. Phase B nested cascade audit — 실제 코드에 nested cascade가 있나? Phase B prerequisite.
8. D.1 fixed ladder의 단계(1m→5m→25m→1h)가 masc-mcp keeper turn 주기 (5-15분 compaction)에 맞는가? — 미세 조정.

## 13. References

### 코드
- `lib/keeper/keeper_turn_driver.ml:757-908` — `try_cascade`
- `lib/keeper/keeper_turn_driver.ml:1330` — "cascade exhausted" 로그
- `lib/keeper/keeper_turn_driver.ml:1477-1484` — Admission_queue (turn level)
- `lib/cascade/cascade_runner.ml:44` — `max_execution_time_s`
- `lib/keeper/keeper_turn_cascade_budget.ml:47` — time cap consumption
- `lib/cascade/cascade_error_classify.ml:22-25` — `Cascade_exhausted` (기존)

### 런타임 Evidence
- `<base-path>/.masc/cascade_audit/2026-05/*.jsonl` — 14일치 8917 attempt
- `<base-path>/.masc/logs/masc-mcp-glm-three-20260516T0152.log` — 02:34 peak 19/min stampede
- `<base-path>/.masc/logs/masc-mcp-8935.log` — 03:22:47~48 sangsu 사건 사슬

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
