---
title: Runtime Deadline Propagation — Cumulative budget invariant for runtime tier-wait
rfc: "0192"
status: Draft
created: 2026-05-27
updated: 2026-05-27
author: vincent
supersedes: []
superseded_by: null
related: ["0088", "0153", "0182"]
closes: ["18845"]
implementation_prs: []
---

# RFC-0192 — Runtime Deadline Propagation

Status: Draft · Architectural framing + 4-PR stacked migration
Related: RFC-0088 (counter-as-fix umbrella), RFC-0153 Phase C.1 (runtime_tier_wait_scheduler 도입), RFC-0182 (Agent_tool_runtime.ctx Eio fields scaffold)
Closes: Issue #18845

## 0. Problem framing

`Runtime_tier_wait_scheduler.try_admission_or_wait` 의 `timeout_s` (env default 30s) 는
**per-attempt** 로 적용된다. Runtime 가 N providers 를 순회하면 admission wait 가
매 attempt 마다 fresh 30s 를 소비 → 누적 wait = N × 30s.

`keeper_agent_run.ml:450` 의 `admission_wait_timeout_sec` 는 *keeper-level total budget*
의도지만, `Runtime_tier_wait_scheduler` 로 전달되는 path 가 없어 의도가 silent 로
무시된다.

```
keeper_agent_run.ml:450
  └─ admission_wait_timeout_sec (Proactive priority) — keeper total budget 의도
     └─ keeper_turn_driver.run_named
        └─ keeper_turn_driver_try_runtime.ml:521 attempt_with_admission (per provider)
           └─ keeper_turn_driver_admission.ml:69 try_admission_or_wait
              └─ wait_config.timeout_s = RuntimeTierWait.timeout_s ()  ← env, default 30s
                  ⚠️ 매 attempt fresh 30s, parent budget 무시
```

## 1. Fleet evidence

- Issue #18845 발견 (2026-05-27 /loop iter#6): 147s wait 관측, 5 attempts × ~30s = 150s 일치.
- 2026-05-27 15:19~15:20 keeper-executor-agent turn=7 사고:
  - 9.5 분 hang → runtime rotate 후 21.5 초 더 → outer `keeper_turn_timeout_sec=600s` 정확히 천장.
  - "ambiguous partial commit" HITL latch (`appr_712fd216f048`, `committed tools = []` 인데 critical).
  - probe 결과 모든 runtime endpoint connect-level fast-fail/정상 → hang 진짜 source 는
    streaming stall + amplifier 누적의 합성.

## 2. Invariant (math composition)

```
∀ attempt i in runtime.attempts:
  effective_attempt_budget(i) = min(default_amplifier, deadline - now())
  where deadline = keeper_run_start + admission_wait_timeout_sec
```

- `default_amplifier` (현 `RuntimeTierWait.timeout_s ()`) 는 *상한* 역할로 retain.
  Runtime 단일 step 가 비정상으로 오래 걸려 다른 candidate 시도 못 하는 case 방지.
- `deadline` 은 keeper turn 시작 시점 wall-clock 으로 1회 계산, 모든 inner
  attempt 로 propagate.
- Type-level invariant: deadline 은 `Eio.Time.deadline` 또는 동등한 typed handle 로
  `Keeper_turn_driver.ctx` 에 carry. 호출 chain 어느 layer 도 forget 못 한다
  (RFC-0182 Phase 5 Eio plumbing 위에 합류).

## 3. Non-goals (anti-pattern guard)

다음 시그니처는 본 RFC 의 reject 영역이다. 향후 LLM-generated 패치가 본
invariant 위에 다음을 *덧붙이면* RFC violation 으로 본다.

- 새로운 threshold guard. 예: `if remaining < min_required_sec then fail_with_X`
  형태의 cliff cutoff.
- `cap = N seconds` / `cooldown = M seconds` / dedup / repair 류 symptom 억제.
- "force a turn after the cap" 류 watchdog timer.
- `min_required_sec` 같은 floor cliff. **현 코드의 `runtime_attempt_watchdog`
  `min_required_sec=15` 는 본 RFC 의 PR-4 단계에서 제거 대상 (hard gate 자체)**.

근거: CLAUDE.md "워크어라운드 거부 기준" §5 (cap/cooldown 가족), §1 (counter-as-fix).
Issue #18845 author self-check 가 이미 `wait_config.timeout_s = 30s` 자체가
"§5 cap symptom 억제 패턴" 이라고 식별. 본 RFC 는 그 self-flag 를 정식 invariant 로
박는다.

## 4. Alternatives considered

### 4.1 옵션 B — Runtime-level fast-fail (Issue #18845)

> 첫 admission wait fail (Inflight_capacity_full) 시 runtime abort. 다른 provider attempt 안 함.

**Rejected**. Issue author 본인이 단점 명시: *"runtime rotation 의도 (한 provider
거부 시 다른 provider 시도) 와 충돌"*. 또 §3 non-goals 의 cliff cutoff 안티패턴
가족. Hard gate 를 *다른* hard gate 로 교체할 뿐.

### 4.2 옵션 C — Per-runtime aggregate budget (env semantic 변경)

> `MASC_RUNTIME_TIER_WAIT_TIMEOUT_S` 를 runtime-aggregate semantic 으로 재정의.

**Weaker form of 옵션 A.** Math composition 은 맞지만 deadline propagation 이
*type-level invariant* 가 아니라 *env interpretation* 위에 얹힘. Future caller
가 silent 로 옛 per-attempt semantic 으로 회귀 가능 (envvar 만 보고 의미 추정).
Type 으로 강제하는 옵션 A 가 누적 안전.

### 4.3 Watchdog timer per attempt

각 attempt 시작 시 30s 알람 설정.

**Rejected**. Amplifier 와 같은 결함 반복. Outer budget 과 compose 안 됨. 새로운
side-channel.

## 5. Implementation — 4-PR stacked migration

RFC-0189 PR-1c 의 stacked-PR 패턴 재사용 (각 PR 단일 axis, 회귀 격리).

| PR | Axis | 변경 | Backward-compat | 테스트 |
|----|------|------|------|--------|
| **PR-1** | ctx wiring | `Keeper_turn_driver.ctx` 에 `deadline : Eio.Time.deadline option` 필드 추가. 콜러 0건 사용. | yes — None default | 기존 테스트 100% 통과 (behavior 변경 0) |
| **PR-2** | scheduler deadline | `try_admission_or_wait` 시그니처: `~timeout_s : float` → `~deadline : Eio.Time.deadline option`. 내부 `timeout_s = min default_amplifier (max 0.0 (deadline - now))`. | yes — `None` 시 옛 env 사용 | 단위: deadline 만료 → 즉시 abort. 5 mock provider 시나리오 total wait ≤ deadline. |
| **PR-3** | caller migration | `keeper_agent_run.ml:450` 에서 deadline 계산 + `keeper_turn_driver.run_named` → `try_runtime` → admission wrapper 까지 propagate. | yes — None passthrough 가능 | 통합 + fleet canary (1 keeper, 24h 관찰). |
| **PR-4** | hard-gate cleanup | `runtime_attempt_watchdog` 의 `min_required_sec` cliff 제거 (§3 non-goal). `runtime_attempt_remaining_budget_sec` metric 승격. | **no** — invariant 가 cliff 를 대체 | **PR-3 머지 후 7-day fleet 검증 통과 시에만 머지**. |

### 5.1 Type sketch

```ocaml
(* lib/keeper/keeper_turn_driver.mli, PR-1 *)
type ctx =
  { ...
  ; deadline : Eio.Time.deadline option
  ; ...
  }

(* lib/runtime/runtime_tier_wait_scheduler.mli, PR-2 *)
val try_admission_or_wait :
  ctx:ctx ->
  ?deadline:Eio.Time.deadline ->  (* Some → deadline drives; None → env amplifier *)
  ... ->
  admission_outcome

(* lib/keeper/keeper_agent_run.ml:450, PR-3 *)
let deadline =
  Eio.Time.Mono.now mono
  |> Eio.Time.Mono.add (Mtime.Span.of_uint64_ns (Int64.of_float (admission_wait_timeout_sec *. 1e9)))
in
Keeper_turn_driver.run_named ~ctx:{ ctx with deadline = Some deadline } ...
```

## 6. Closeout target

- **Fleet criterion**: 24h post PR-3 머지, `ambiguous_partial_commit` HITL latch 발동 0건.
- **PR-4 머지 조건**: 7-day fleet, 다음 두 metric 모두 0:
  - `runtime_attempt_watchdog_floor_fired_count` (있다면 emit)
  - `keeper_turn_timeout_ceiling_hit_count` for `runtime.glm-coding-with-spark` /
    `runtime.primary` / `runtime.governance`
- Issue #18845 close at PR-4 merge.

## 7. TLA+ hint (optional, RFC-0136 spec hygiene)

```tla
KeeperRuntimeBudgetInvariant ==
  \A i \in 1..Cardinality(runtimeAttempts) :
    attemptBudget[i] <= keeperDeadline - runtimeStartTime[i]

(* Buggy variant: per-attempt fresh budget *)
KeeperRuntimeBudgetBuggy ==
  \A i \in 1..Cardinality(runtimeAttempts) :
    attemptBudget[i] = defaultAmplifier  (* ignores deadline *)
```

`KeeperRuntimeBudgetInvariant` 를 `INVARIANT` 로, buggy variant 를 `NextBuggy`
action 으로 분리하면 clean spec (PASS) + buggy spec (invariant violated) 양쪽
검증 가능. RFC-0136 의 bug-as-action 패턴 적용.

## 8. Workaround-bar self-check

| Signature | Applies? |
|-----------|----------|
| §1 counter-as-fix | N/A — root behavior change. PR-4 가 telemetry 만 emit 하는 게 아니라 cliff 제거. |
| §2 string classifier | N/A — typed deadline value. |
| §3 N-of-M | N/A — 4-PR stack 이 단일 axis × 4. Caller migration (PR-3) 가 *모든* 사이트 동시 switch. |
| §5 cap/cooldown | **부분 적용 — 정확히 *제거* 대상**. 기존 `wait_config.timeout_s=30s` cap 을 본 RFC 가 min composition 으로 약화 (제거 아님 — *상한 역할만* retain). `min_required_sec` floor 는 PR-4 에서 *완전 제거*. |
| §6 test backdoor | N/A. |
| §7 codemod 미수행 N-fix | N/A — caller 5 사이트 PR-3 일괄. |

## 9. Open questions

1. **Deadline 값의 wall-clock vs Eio.Mono**: Eio.Time.Mono 가 견고하나, fleet
   debugging 시 wall-clock log 와 매칭이 필요. RFC 본문에는 Mono 권장, log emission
   시점만 wall-clock 변환.
2. **Re-entrancy**: nested runtime (runtime A 안에서 runtime B 호출하는 case 있는가?)
   가 있다면 inner runtime 가 parent deadline 을 *공유* 해야 하는지, *별도* 인지
   decision 필요. 현재 코드 base 에는 nested runtime 없으나 RFC-0182 Phase 5 후
   가능성 검토.
3. **Telemetry baseline**: PR-4 머지 전 7-day 검증의 *baseline* 측정은 PR-3 머지
   직전 24h 의 `keeper_turn_timeout_ceiling_hit_count` (있다면). 없다면 PR-1 에
   metric emit 만 추가.

## 10. References

- Issue #18845 (runtime-tier-wait per-attempt accumulates)
- Today's fleet incident: keeper-executor-agent turn=7, 9.5min hang (2026-05-27 15:19~15:20 KST)
- CLAUDE.md §"워크어라운드 거부 기준"
- RFC-0088 (counter-as-fix umbrella)
- RFC-0153 Phase C.1 (runtime_tier_wait_scheduler intro)
- RFC-0182 (Agent_tool_runtime.ctx Eio fields)
- Memory: `feedback_runtime_budget_no_hard_gates.md` (user-stated anti-goal policy)
