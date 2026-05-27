# RFC-0197: Cascade Attempt Watchdog — Per-Candidate Wrap + Shared Deadline

**Status**: Draft
**Date**: 2026-05-27
**Related**: RFC-0192 (cascade deadline propagation, MERGED), RFC-0022 (cascade attempt liveness)
**Meta-RFC**: RFC-0194 (Tool Surface Semantic SSOT) — §1 + §4 instantiation
**Memory anchors**: `feedback-cascade-budget-no-hard-gates`, `feedback-cascade-dual-ssot-diagnosis-must-compare-both-toml`

## Context

2026-05-27 server restart (17:08 KST, RFC-0192 PR-1/2/3 deployed) 직후 fleet observation:

```
analyst: keeper cycle FAILED 
cascade=tier-group.glm-coding-with-spark 
max_context=128000 context_budget=128000 
latency=579373ms 
error=Timeout: Turn wall-clock budget exhausted during cascade attempt 
       (budget=555.0s, watchdog=570.0s)
```

**Frequency**: 32 events / 2h (~16/h, ~384/day extrapolation)
**Single keeper**: 100% analyst
**Single cascade tier-group**: `tier-group.glm-coding-with-spark` (4 tier failover chain)
**Single budget value**: 99% `budget=555.0s, watchdog=570.0s` — *동일 cascade tier 만 fire*

`tier-group.glm-coding-with-spark` 의 runtime config:
```toml
tiers = ["strict_tool_candidates", "ollama_cloud_stable", "local_llama", "glm-coding-with-spark"]
strategy = "failover"
fallback = true
```

**4 tier failover 가 있는데도** log evidence:
```
analyst: turn terminal (non-exhaustion error) — err=Timeout: ... attempt=1
```

`attempt=1` = 첫 candidate timeout 만으로 terminal. **failover chain 미발동**.

## Root cause (3-layer analysis)

### Layer 1 (outermost) — `Keeper_unified_turn_attempt_watchdog`

`lib/keeper/keeper_unified_turn_execution.ml:158-170`:
```ocaml
Keeper_unified_turn_attempt_watchdog.dispatch
  ~clock
  ~attempt_watchdog_s          (* "attempt" 명시 *)
  ~oas_timeout_s
  ~on_cancelled:...
  ~run:(fun () -> Keeper_agent_run.run_turn ...)   (* whole turn wrap *)
```

`Eio.Time.with_timeout_exn clock attempt_watchdog_s run` (`keeper_unified_turn_attempt_watchdog.ml:8`) 발화 시 `Agent_sdk.Error.Api (Timeout)` Error 반환 → cascade chain 자체가 cancel.

**Semantic mismatch**: 변수 / log / RFC-0192 invariant 모두 *per-attempt* 명시. 그러나 wrap target = `run_turn` (= 전체 cascade chain 4 tier failover 포함).

### Layer 2 — `outer_wall_for_provider` (per-provider timeout, intent=fallback)

`lib/keeper/keeper_turn_driver_try_provider.ml:529`:
```ocaml
Eio.Time.with_timeout_exn clock t run_fn with
| Eio.Time.Timeout ->
  Log.Misc.info
    "[cascade-fallback] cascade %s: runtime lane per-provider \
     timeout after %.1fs, falling back"      (* ← "falling back" *)
    ...
```

이 layer 의 *intent* = fallback. 발화 시 Error 반환 → cascade `run` loop 가 next candidate 시도.

**그러나 Enforce mode 에서 비활성**:
```ocaml
(* lib/cascade/cascade_attempt_liveness_config.ml:236 *)
let outer_wall_for_attempt ~mode ~observer_attached ~per_provider_timeout_s ~candidate_key =
  match mode, observer_attached with
  | Enforce, true -> None       (* ← production default *)
  | ...
```

`MASC_CASCADE_ATTEMPT_LIVENESS` default = `enforce` (RFC-0022 mli line 16). 따라서 `outer_wall_for_provider = None` → `keeper_turn_driver_try_provider.ml:516-517`:
```ocaml
match outer_wall_for_provider with
| None -> run_fn ()             (* wrap 없이 그냥 run *)
| Some t -> Eio.Time.with_timeout_exn clock t run_fn
```

= **Layer 2 미발화**.

### Layer 3 — Cascade attempt liveness observer (RFC-0022)

`Cascade_attempt_liveness` observer 가 streaming chunks 기반으로 attempt liveness 판정 → 위반 시 `Liveness_kill` raise via `Eio.Switch.fail`.

Fleet evidence: 32 event 모두 **outer watchdog (Layer 1) 가 첫 발화** — Layer 3 observer fire 안 함. Provider 가 *극심하게 slow* 인데 streaming chunks 유지 (heartbeat 등) → observer 가 alive 로 판정 가능.

### Race outcome

Layer 1 (570s, whole turn) > Layer 2 (disabled in Enforce) > Layer 3 (observer, not firing). **항상 Layer 1 이 fire** → cascade fallback path 0.

## Impact

- analyst keeper: 32 turn × 9.25 min = 296 keeper-minute / 2h baseline. **작업 시간의 ~250% 가 timeout-bound stuck** (병렬 turn 가능성 고려).
- 4 tier failover chain (`strict_tool_candidates / ollama_cloud_stable / local_llama / glm-coding-with-spark`) 가 코드는 있는데 *실행 불가*.
- 사용자 직관: "심하게 잘못된 느낌, 이런 에러를 왜 자꾸 내뿜는거지" — 정확한 진단.

## Proposed (Meta-RFC §1 + §4 정합)

### Design

**Layer 1 watchdog 의 wrap target 을 per-candidate (try_provider 호출) 로 이동**. budget 은 *remaining turn deadline* 으로 shared.

```
Before (현재):
  Outer wrap (Layer 1): attempt_watchdog_s 동안 whole_run_turn 시도
    └── run_turn
          └── cascade run loop
                ├── try_provider candidate_1   (no inner watchdog in Enforce)
                ├── try_provider candidate_2   (unreachable if candidate_1 hangs)
                └── ...

After (RFC-0197):
  Outer wrap (turn-level): hard ceiling (예: 30min) — 60min hard ceiling 방지
    └── run_turn
          └── cascade run loop
                ├── per-candidate watchdog wrap: budget = min(provider_effective_timeout, deadline-now())
                │     └── try_provider candidate_1   → timeout → Error → next
                ├── per-candidate watchdog wrap: budget = min(remaining_deadline-now(), per_provider)
                │     └── try_provider candidate_2   → may succeed or timeout → next
                └── ...
                (budget=0 시점 = "exhausted" terminal)
```

### Math (RFC-0192 invariant 와 정합)

```
effective_per_candidate_budget = min(per_provider_effective_timeout, remaining_turn_deadline_at_candidate_start)

where remaining_turn_deadline_at_candidate_start = turn_deadline - clock.now()
```

이는 정확히 RFC-0192 §2 의 `composed_attempt_budget = min(amplifier, deadline-now())` — *attempt* 가 candidate 별 wrap. RFC-0192 의 *semantic 회복*.

### 호환성

- **Layer 2 (`outer_wall_for_attempt` Enforce → None)**: 그대로 유지. Layer 3 observer 의 책임 분리 보존 (RFC-0022 design 무변).
- **Layer 1 (whole-turn watchdog)**: 제거하지 않고 *turn-level absolute upper bound* (예: 30min hard ceiling) 로 retain. RFC-0192 PR-4 의 후속에서 *60min hard ceiling 자체를 줄임* 가능.
- **Cascade run loop**: 기존 `keeper_turn_driver_try_cascade.ml` 의 `run` 함수가 candidate 시도 — *그 안* 에 per-candidate watchdog wrap 추가.

### Non-goals (Meta-RFC §4 anti-pattern 회피)

- **새 hard gate 0**: 기존 watchdog 의 wrap location 만 이동 + per-candidate scope 추가. budget 은 math composition.
- **새 substring classifier 0**: `Eio.Time.Timeout` typed exception 그대로.
- **새 counter 0**: 기존 `cascade-fallback` log message 활용 (이미 line 532-533 존재).
- **N-of-M 회피**: 단일 wrap location 추가 (per-candidate), abstraction 변경 없음.

## Implementation outline

### Phase A — RFC doc + Issue (본 PR)

Doc only, code = 0.

### Phase B — Per-candidate watchdog wrap (single PR)

변경 위치:
1. `lib/keeper/keeper_turn_driver_try_cascade.ml` — `run` 함수 의 `candidate :: rest` 분기에 `Eio.Time.with_timeout_exn` wrap 추가.
2. `lib/keeper/keeper_turn_driver.ctx` (이미 RFC-0192 PR-1 에서 deadline field 추가) — try_cascade ctx 로 deadline propagation 보장.
3. 새 helper `Cascade_deadline.budget_for_candidate_at` (RFC-0192 PR-1 의 `composed_attempt_budget_at` 와 동일 시그니처 — 또는 alias).

변경 회피:
- `Keeper_unified_turn_attempt_watchdog.dispatch` 시그니처 무변 (caller 만 변경, 또는 caller 그대로 두고 *내부* 추가 wrap)
- `keeper_unified_turn_execution.ml:158-170` 의 outer wrap *유지* (turn-level absolute bound) — 추가 layer 만 도입

### Phase C — 신규 test

- `test_cascade_fallback_on_provider_timeout.ml`: provider 가 hang 시 next candidate 시도 검증
- `test_cascade_deadline_shared_across_candidates.ml`: 첫 candidate 가 deadline 다 쓰면 next candidate 즉시 exhausted

### Phase D — Fleet validation (7d window)

- Baseline: 32 events / 2h (단일 candidate terminate)
- Target: `cascade-fallback` log message 가 LLM 한테 도달, next candidate 시도 사례 fleet 측정
- success metric: analyst keeper 의 *non-first-candidate success* rate ≥ 0 → ≥ 30%

## Verification

- **OCaml test**: Phase C 2 expect-test
- **Fleet metric**: 7d window
  - `keeper cycle FAILED ... attempt=1` rate
  - Baseline: 100% (현재 모든 turn fail 이 attempt=1)
  - Target ≤ 50% (50%+ 가 attempt≥2 시도)
- **Build-time guard**: deadline propagation 누락 시 build fail (RFC-0192 의 required labeled args pattern 차용)

## Anti-pattern check (Meta-RFC §4)

| Anti-pattern | Check |
|---|---|
| §1 Counter-as-fix | ✓ 새 counter 0, 기존 `cascade-fallback` log 활용 |
| §2 String classifier | ✓ typed Eio.Time.Timeout 그대로 |
| §3 N-of-M | ✓ 단일 wrap location, abstraction 무변 |
| 새 hard gate | ✓ math composition (min(provider, remaining-deadline)) |
| 사용자 메모 `[[feedback-cascade-budget-no-hard-gates]]` | ✓ 정합 — wrap location 만 이동, budget 계산은 그대로 |
| 사용자 메모 `[[feedback-surgical-workaround-rejected-for-tool-surface]]` | ✓ tool surface 가 아닌 cascade scheduling 영역. RFC-driven |

## Sequencing

- **RFC-0192 PR-4 (pending #9, hard-gate cleanup) 와 충돌 없음**: PR-4 는 `min_required_sec=15` cliff 제거. 본 RFC-0197 은 *wrap layer 추가*. 의존성 없음, parallel.
- **RFC-0022 (Enforce mode None policy) revisit 권장**: Phase D 후 observer fire rate 측정. 0 면 RFC-0022 별도 RFC.

## Out of scope

- Provider hang 자체 진단 (`tier-group.glm-coding-with-spark` 어느 tier 가 hang) — 별도 incident, Issue #18894 영역
- LLM 한테 alternatives 전달 (Meta-RFC §2, RFC-0195 영역)
- 60min hard ceiling 자체 줄이기 — RFC-0192 PR-4 cleanup 영역

## References

- RFC-0192 (cascade deadline propagation) — PR-1/2/3 MERGED
- RFC-0022 (cascade attempt liveness) — `MASC_CASCADE_ATTEMPT_LIVENESS` Enforce mode
- RFC-0194 (Meta-RFC) — §1 (typed SSOT), §4 (anti-pattern negation)
- 메모: `feedback-cascade-budget-no-hard-gates` (math composition only)
- 메모: `feedback-cascade-dual-ssot-diagnosis-must-compare-both-toml` (runtime toml 확인 완료)
- Fleet evidence: 2026-05-27 8.4h+ 32 event analyst keeper terminal
