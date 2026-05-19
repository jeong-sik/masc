---
rfc: "0117"
title: "KCR item-health representation parity — typed Degraded variant + spec cooldown action + PerKeeperIsolation correction"
status: Draft
created: 2026-05-17
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0072", "0113", "0114", "0115", "0116"]
implementation_prs: [15957]
---

# RFC-0117: KCR item-health representation parity — typed Degraded variant + spec cooldown action + PerKeeperIsolation correction

## §1 Problem (caller-context)

`docs/tla-audit/kcr-c2-health-state-representation-gap-2026-05-12.md` 가 KCR (KeeperCascadeRouting) spec 의 item-health 모델과 OCaml runtime 의 health 모델이 *같은 의도* 를 *다른 representation* 으로 encode 함을 문서화. RFC-0116 의 *fallback cap* drift 와 sibling. C-1 이 *cap mechanism*, **C-2 (본 RFC) 가 *state representation***.

### Spec health model

```tla
item_health \in [Keepers × Items → {"Healthy", "Degraded", "Unhealthy"}]

HealthStateConsistent ==
    \A k \in Keepers, i \in Items :
        LET h = item_health[<<k, i>>]
            cf = consecutive_failures[<<k, i>>]
        IN /\ (h = "Healthy"   => cf = 0)
           /\ (h = "Degraded"  => cf > 0 /\ cf < MaxConsecutive)
           /\ (h = "Unhealthy" => cf >= MaxConsecutive)

PerKeeperIsolation == TRUE  \* Comment: "Structural invariant: enforced by variable typing"
```

3 typed state, per `<<keeper, item>>` granularity, `PerKeeperIsolation` placeholder.

### OCaml health model

`lib/keeper/keeper_health_probe.ml:9-12`:

```ocaml
type health_status =
  | Healthy
  | Unhealthy of string  (* reason *)
```

**2 states only — no `Degraded` variant**. 주석 (line 41-42):

> "Success -> Healthy immediately. Failure -> Unhealthy (no Degraded intermediate for now)."

`lib/cascade/cascade_health_tracker.ml:297, 509, 524-555`:

```ocaml
mutable consecutive_failures: int;
mutable cooldown_until: float;     (* time-based gate, no spec counterpart *)

(* Success: reset *)
state.consecutive_failures <- 0;
state.cooldown_until <- 0.0;

(* Failure | Rejected: increment + threshold-gate cooldown *)
state.consecutive_failures <- state.consecutive_failures + 1;
if state.consecutive_failures >= threshold then
  state.cooldown_until <- now +. cooldown_dur

(* Soft_rate_limited: immediate cooldown, no failure count gate *)
state.cooldown_until <- now +. soft_cooldown
```

OCaml 의 *Degraded equivalent* 는 implicit predicate: `0 < consecutive_failures < threshold ∧ cooldown_until ≤ now`. 어디에도 typed variant 없음.

### 4 gap surfaces (audit doc 인용)

1. **`Soft_rate_limited` 가 spec 에 없음**: cooldown 만 setting, `consecutive_failures` 증가 안 함. Spec view 에서 keeper 가 `Healthy` 유지 — runtime 은 gated. 10번 발생해도 spec invariant 모르고 통과.

2. **Cooldown 이 Unhealthy 를 `cf` 와 decouple**: Spec `cf ≥ MaxConsecutive ⇔ Unhealthy`. OCaml `cf ≥ threshold OR cooldown_until > now`. Cooldown 만료 후 `cf` 그대로면 OCaml 효과적으로 Degraded — spec 는 *time-elapsed re-Degradation* 모름.

3. **Per-item-per-keeper vs per-provider-key**: Spec key `<<keeper, item>>`. OCaml `cascade_health_tracker` keys `provider_key` (single string, *keeper 간 공유*). 같은 provider 쓰는 두 keeper 가 cooldown 공유 — `PerKeeperIsolation == TRUE` *spec lie* (실제 production 미준수).

4. **2-state OCaml `health_status` 는 cascade health 용 아님**: probe type 일 뿐, selector 의 per-item decision 은 boolean 기반. spec 의 3-state typing 이 OCaml 어디에도 없음 — `cf int + cooldown float + bool predicate` 산재.

### Why this needs an RFC

1. **RFC-0114/0115/0116 spec-runtime contract family 의 *4번째 변형***: state representation drift. C-1 이 *cap source*, C-2 가 *state form*. KCR 의 두 audit 가 같은 family 의 두 측면.
2. **Audit doc 가 3 RFC candidate 명시** (R-C-2.a / R-C-2.b / R-C-2.c). 본 RFC 가 그 세 후보를 *통합 spec*.
3. **`PerKeeperIsolation == TRUE` placeholder 는 *spec lie*** — 명시적 correction 필요.
4. **Counter-as-Validator 패턴 자연스러움**: gap surface 4 모두 *측정 가능* — `is_item_healthy = true ∧ cooldown_until > now` 같은 case 가 발생하면 spec lie 의 증거.

근본 원인: **state 가 OCaml 에서 *implicit predicate* 로 분산** (cf int + cooldown float + bool); spec 가 *typed 3-state* 로 모델.

## §2 Approach

3 layer, audit doc 의 3 candidate 통합:

**Layer A — OCaml typed `item_health_state` (R-C-2.a)**

`Keeper_cascade_selector` 또는 `cascade_health_tracker` 에 typed variant:

```ocaml
module Item_health : sig
  type t =
    | Healthy
    | Degraded of { failures : int; max : int }  (* derived from consecutive_failures *)
    | Unhealthy of { reason : unhealthy_reason }

  and unhealthy_reason =
    | Failure_threshold_exceeded of { failures : int; max : int }
    | Cooldown_active of { until : float }
    | Soft_rate_limited of { until : float }
    | Probe_failure of string

  val of_tracker_state :
    consecutive_failures:int ->
    cooldown_until:float ->
    threshold:int ->
    now:float ->
    t
end
```

Smart constructor `of_tracker_state` 가 4 dimension 을 typed state 로 collapse. dashboard / `is_item_healthy` 호출자가 typed match 가능.

**Layer B — Spec extension (R-C-2.b)**

`KeeperCascadeRouting.tla` 에 `cooldown_until` 변수 + `SoftRateLimit` action 추가:

```tla
VARIABLES
    ..., cooldown_until      \* keeper × item → Nat (logical time)

SoftRateLimit(k, i, dur) ==
    /\ ...
    /\ cooldown_until' = [cooldown_until EXCEPT ![<<k, i>>] = now + dur]
    /\ item_health' = [item_health EXCEPT ![<<k, i>>] = "Unhealthy"]
    /\ consecutive_failures' = consecutive_failures   \* unchanged

CooldownExpiry(k, i) ==
    /\ now >= cooldown_until[<<k, i>>]
    /\ item_health[<<k, i>>] = "Unhealthy"
    /\ consecutive_failures[<<k, i>>] < MaxConsecutive
    /\ item_health' = [item_health EXCEPT ![<<k, i>>] = "Degraded"]
```

`HealthStateConsistent` invariant 보강 — cooldown 의미 포함.

**Layer C — `PerKeeperIsolation` correction (R-C-2.c)**

Spec 본문 line ~?: `PerKeeperIsolation == TRUE` placeholder 제거. 대신 *honest operational invariant*:

```tla
\* PerProviderCooldownSharing - keepers using the same provider share cooldown.
\* This is intentional per cascade_health_tracker keying by provider_key,
\* not a violation. Spec is honest about non-isolation along the cooldown axis.
PerProviderCooldownSharing ==
    \A k1, k2 \in Keepers, i \in Items :
        provider_of[<<k1, i>>] = provider_of[<<k2, i>>] =>
            cooldown_until[<<k1, i>>] = cooldown_until[<<k2, i>>]
```

R-C-2.c 는 spec 를 *production reality* 와 align — lie 제거.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `Item_health` typed module + `of_tracker_state` smart constructor + 8 unit test (4 gap surface 별 transition) | dune build PASS, alcotest PASS |
| P3 | `is_item_healthy` caller 가 typed `Item_health.t` 반환 또는 derived bool 사용. Selector 통합. | PBT: 4 gap scenario 모두 typed state surface 반영 |
| P4 | Spec PR (R-C-2.b) — `cooldown_until` 변수 + `SoftRateLimit` + `CooldownExpiry` action. KCR.cfg PASS + KCR-buggy.cfg 에 `BuggySoftRateLimit` action 추가, invariant violation 확인 | TLC PASS clean, FAIL buggy |
| P5 | Spec PR (R-C-2.c) — `PerKeeperIsolation` placeholder 제거, `PerProviderCooldownSharing` 추가 | TLC PASS, 사용자 인지 |
| P6 | dashboard 가 4 typed state (Healthy / Degraded / Unhealthy-cooldown / Unhealthy-threshold) UI 표시 + telemetry counter `keeper_item_health_state_transitions_total{from,to}` | telemetry shows non-zero `Soft_rate_limited` transitions = spec-runtime parity 증거 |

P2 가 OCaml-only (safe), P4/P5 가 spec PR. P3 가 caller wiring — production 영향.

## §4 Open questions

1. **Q1**: `Item_health.t` 와 `Keeper_health_probe.health_status` 의 관계? probe 가 별도 type 유지 vs delegate to `Item_health`? **잠정**: 별도 유지 — probe 는 *cascade ratio observability*, selector 는 *per-item decision*. 두 type 가 명시적 변환 함수.

2. **Q2**: spec 의 `cooldown_until` 가 logical time (Nat) — OCaml 의 float time 과 어떻게 mapping? **잠정**: P4 의 spec 는 abstract step 만 모델 (`now + dur` 의 dur 가 CONSTANT), OCaml 는 wall clock. Spec model 가 *순서* 만 capture, 정량 수치 별도.

3. **Q3**: R-C-2.c 의 *spec lie 제거* 가 *기존 invariant 강도* 약화? `PerKeeperIsolation == TRUE` 가 *어떤 보장도 안 함* — 강도 = 0. 제거 = 0 → 0, no loss. **잠정**: 제거 진행.

4. **Q4**: `Item_health.Degraded of { failures; max }` 가 *runtime mutation* 시 호출자 cost? smart constructor 가 derive, 별도 storage 없음. Hot path 영향 없음. **잠정**: P2 의 PBT 가 perf 측정.

## §5 Non-goals

- **`Soft_rate_limited` 의 *정책 변경* (cooldown duration tuning)**: 본 RFC 는 *spec-runtime parity* 만. tuning 별도.
- **Provider key 의 *전반적 refactor***: per-keeper key 로 전환 검토 별도. 본 RFC 는 *현 keying* 을 spec 가 반영.
- **다른 keeper spec 의 health representation** (KAQ, KAL): 별도 RFC. KCR 만.

## §6 Risk & rollback

- **Risk 1**: P3 caller wiring 이 *기존 caller* 의 boolean predicate 와 호환성. → `Item_health.is_healthy : t -> bool` adapter 제공. legacy path 보존.
- **Risk 2**: P4 spec 변경이 *기존 invariant 깨짐* → KCR.cfg TLC PASS 확인 P4 acceptance.
- **Risk 3**: P5 의 `PerKeeperIsolation` 제거가 *기존 spec 사용자* (reader, tooling) 의 mental model 깨뜨림. → P5 commit message + spec 본문 comment 에 명시적 justification.
- **Risk 4**: P6 telemetry counter 추가가 *Counter-as-Fix* 시그니처? → 본 counter 는 *Counter-as-Validator* — spec invariant 만족 *증명* 용도, silent loss visibility 가 아님.

Rollback: 각 Phase 별 PR. P3 typed wrapper 만 사용 가능 (P2 만 land). P4/P5 spec PR 은 *spec only*, OCaml 무영향.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `Item_health.t` 모듈 + smart constructor + 8 unit test PASS.
- [ ] P3: `is_item_healthy` 호출자 typed state 사용. 4 gap scenario PBT PASS.
- [ ] P4: KCR spec `cooldown_until` + `SoftRateLimit` + `CooldownExpiry`. clean TLC PASS, buggy FAIL.
- [ ] P5: KCR spec `PerKeeperIsolation` removed + `PerProviderCooldownSharing` added.
- [ ] P6: dashboard 4 state UI + telemetry `keeper_item_health_state_transitions_total` non-zero `Soft_rate_limited` evidence.

## §8 Number allocation note

Allocated as RFC-0117. Ledger advanced 0109 → 0118 (skip 0109-0116 due to inflight #15902 RFC-0109 + #15924/15927/15933/15937/15939/15944/15947 RFC-0110~0116 (iter-2..8 of this loop)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
