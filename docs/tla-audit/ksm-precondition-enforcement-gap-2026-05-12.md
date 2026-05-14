# KSM Precondition Enforcement Gap (2026-05-12)

**Spec**: `specs/keeper-state-machine/KeeperStateMachine.tla` (all condition-setter actions)
**OCaml**: `lib/keeper/keeper_state_machine.ml` (`update_conditions` lines 540-674)
**Iteration**: 9 (Phase A-5 잔여 sweep, `/loop` plan)
**Cross-ref**: iter 6 #14720 (Heartbeat/Turn_failed unconditional), iter 7 #14722 MERGED (root cause), iter 8 #14727 (R-A-8 PR-1).

## TL;DR

OCaml `update_conditions`이 *condition-setter events* 대해 TLA+ spec의 *state precondition*을 enforce 안 함. terminal phase reject (apply_event line 754-758)만 통합 enforce. 잘못된 caller가 부적절한 phase에서 event dispatch 시 silent state corruption 가능.

이건 *single event drift가 아니라 systematic class gap*. 단일 fix가 아닌 *defensive layer 통합 RFC* 후보.

audit memo only. 5 events × precondition gap 명시. 단일 가장 큰 fix가 *어디서* 들어가야 하는지 (`apply_event` enrichment vs caller assertions vs Result.t 반환) 의사결정 노트.

## 5 events × precondition gap

| Event | TLA+ precondition | OCaml precondition |
|---|---|---|
| `Auto_compact_triggered` | `NotTerminal ∧ fiber_alive ∧ context_overflow ∧ ¬compaction_active ∧ ¬handoff_active ∧ ¬compact_retry_exhausted` | terminal reject only |
| `Operator_compact_requested` | `NotTerminal ∧ fiber_alive ∧ ¬compaction_active ∧ ¬handoff_active` | terminal reject only |
| `Compact_retry_exhausted` | `NotTerminal ∧ fiber_alive ∧ context_overflow ∧ ¬compaction_active ∧ ¬compact_retry_exhausted` | terminal reject only |
| `Context_overflow_detected` | `NotTerminal ∧ fiber_alive ∧ ¬compaction_active` | terminal reject only |
| `Operator_clear_requested` | `NotTerminal` | terminal reject (1:1) |

마지막 행 (`Operator_clear_requested`)이 *유일하게* 1:1 정렬 — TLA+이 NotTerminal만 요구, OCaml의 terminal reject가 이를 enforce. 나머지 4 events는 *fiber_alive*, *~compaction_active* 등의 추가 precondition을 TLA+이 명시하지만 OCaml은 silent하게 받아들임.

## 시나리오 (silent corruption 가능)

### Scenario A — Auto_compact_triggered on non-overflowed keeper

caller가 잘못 dispatch:
- 현재 phase: Running, conditions: `context_overflow = false`
- Event: `Auto_compact_triggered`
- TLA+: precondition `context_overflow` 실패 → action disabled → spec 모델링 안 함
- OCaml: 무조건 `compaction_active = true` 설정 → derive_phase → Compacting
- 결과: keeper가 *overflow도 없는데* Compacting 진입 → 빈 compaction → CompactionFailed 또는 NoSavings 경로

### Scenario B — Compact_retry_exhausted on completed keeper

- 현재 phase: Running, `context_overflow = false`
- Event: `Compact_retry_exhausted` (잘못된 caller가 stale event 보냄)
- TLA+: precondition `context_overflow` 실패 → 모델링 안 함
- OCaml: `compact_retry_exhausted = true` latch 설정 → 다음 Context_overflow_detected 발생 시 (priority 7) → Paused
- 결과: 영구 latch가 keeper를 Paused로 강제 (operator 개입 필요)

### Scenario C — Operator_compact_requested during HandingOff

- 현재 phase: HandingOff, `handoff_active = true`
- Event: `Operator_compact_requested` (operator UI race condition)
- TLA+: `~handoff_active` 실패 → 모델링 안 함
- OCaml: `compaction_active = true` 설정 + `compact_retry_exhausted = false`
- 결과: 동시 compaction + handoff → derive_phase priority 8 (`handoff_active`) → HandingOff 유지지만 `compaction_active=true`가 *parasitic state*. handoff 완료 후 unexpected Compacting 진입.

## Findings

### F-9.1 (HIGH risk strategic): apply_event scope 확장 후보

`apply_event` (line 752-799)는 현재 *terminal phase reject*만 통합 enforce. 같은 함수에 *event-specific precondition*을 추가하면 모든 5 gap을 한 곳에서 해결.

**Suggested fix (R-A-9 RFC 후보)**:
```ocaml
let apply_event ~current_phase ~conditions ~event ~now =
  match current_phase with
  | Stopped | Dead | Zombie -> Error (Terminal_state {...})
  | _ ->
    match check_event_precondition event conditions with
    | Error mismatch -> Error (Precondition_violation { event; mismatch })
    | Ok () ->
      let updated_conditions = update_conditions conditions event in
      ...
```
`check_event_precondition`: pattern-match on event variant, returns `Result.t`. precondition strings (e.g., "Auto_compact_triggered requires context_overflow") matched against TLA+ spec text 1:1.

이 fix는:
1. Silent state corruption 차단.
2. OCaml↔TLA+ spec 정렬 (precondition 측면).
3. Caller bugs를 ApplyEvent error로 surface (현재는 silent).

### F-9.2 (MID risk operational): existing test가 이런 silent corruption 못 잡음

`test/test_keeper_state_machine.ml`의 chain_apply tests는 *행복 경로* (happy path) 만 검증. 위의 Scenario A/B/C 같은 *misuse case*는 test에 없음.

**Suggested follow-up PR**: F-9.1 RFC가 landed 후 misuse case 5종 negative test 추가.

### F-9.3 (LOW risk: spec accuracy): `OperatorClearRequested`의 precondition 약함

TLA+ `OperatorClearRequested`은 `NotTerminal`만 요구 — `fiber_alive` 부재. 즉 *Crashed/Restarting* phase에서도 clear 가능. OCaml도 동일 (terminal reject만). 이건 1:1 정렬되지만 *의도된 약함*인지 *누락*인지 명확하지 않음.

production 시나리오: operator가 Crashed keeper의 context를 clear하고 재시작? Or 그냥 redundant? `masc_keeper_clear` 호출자 grep 필요.

## Verification

- [x] 5 condition-setter events 모두 OCaml vs TLA+ precondition 비교.
- [x] Operator_clear_requested 만 1:1 정렬 확인.
- [x] 3 misuse scenarios (Auto_compact / Compact_retry / Operator_compact) 분석으로 silent corruption 경로 도출.
- [x] apply_event 기존 terminal reject가 5 gap의 *부분만* enforce 확인.
- [ ] F-9.1 fix (R-A-9 RFC)는 본 PR 범위 밖. 별도 iteration.

## Trade-off

- **단점**: 코드/스펙 0건. 5 silent corruption vector 가 그대로 존재.
- **장점**: *systematic gap class* 식별 — iter 6 (Heartbeat/Turn_failed unconditional)와 같은 패턴 더 발견. 단일 RFC (apply_event precondition layer)가 5 fix를 통합.
- 잠재 회의: F-9.1 fix가 *모든* caller에서 발생할 수 있는 *misuse pattern*을 강제하는 것 — 일부 legitimate caller path가 *spec보다 약하게* dispatch 했을 수도 (성능, 단순성). enforce 후 *test fail 회피*를 위한 caller 변경 cascade 가능.

## RFC

`RFC-WAIVED: audit-only memo. F-9.1 (apply_event precondition layer) is a separate RFC candidate that covers 5 condition-setter events in one structural change. R-A-9 register backlog.`

## 진행 추적

- 다음 iteration: **R-A-8 PR-2** (TLC verify + KNOWN_FAILURES 제거 — iter 8 #14727 머지 대기) OR **R-A-9 PR-1** (apply_event precondition layer).
- Backlog 적재: R-A-9 (apply_event precondition layer, 5 events at once).
