---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper_registry/keeper_state_machine.ml
  - lib/keeper/keeper_registry.ml
  - lib/keeper/keeper_supervisor.ml
---

# RFC-0002: Keeper 11-State Machine + Det/NonDet Boundary Formalization

**Status**: Draft
**Date**: 2026-04-05
**Scope**: `masc` keeper lifecycle state machine redesign
**One sentence**: Keeper의 5-state 상태 머신을 11-state로 확장하고, 비결정론적 측정과 결정론적 전이 사이에 관찰 가능한 buffer state와 snapshot-at-decision 경계를 도입한다.

## Related Documents

- `RFC-0001-det-nondet-boundary-harness.md` — Design Principle 1 (Det/NonDet Rules)
- `../../archive/trpg/lib/trpg/engine_state_machine.mli` — Result-based transition pattern
- `../../docs/design/adr-masc-oas-boundary-ssot.md` — MASC/OAS boundary rules

## Problem Statement

현재 `keeper_registry.ml:49-54`의 상태 머신:

```ocaml
type keeper_state = Running | Paused | Stopped | Crashed | Dead
```

세 가지 구조적 문제:

1. **관찰 불가능한 전이**: compaction, handoff, failure 누적, drain이 진행되는 동안 외부에서 "Running"으로만 보인다. `derive_pipeline_stage` (keeper_status_runtime.ml)는 30초 recency window heuristic으로 추론하지만 정확하지 않다.

2. **재현 불가능한 crash**: `context_ratio >= threshold`가 compaction을 트리거하고 실패하면 즉시 Crashed로 전이. 판단 시점의 threshold 값, context_ratio 값, timing이 기록되지 않아 재현할 수 없다.

3. **산재된 상태 변경**: `set_state` 호출이 keeper_keepalive.ml, keeper_supervisor.ml, keeper_turn_lifecycle.ml 세 곳에 분산. 중앙 집중화된 transition validation이 없다.

## Design Anchors

| 패턴 | 출처 | 적용 |
|------|------|------|
| Deterministic Core, Agentic Shell | Morissette 2026 | 3-layer 아키텍처 기본 원칙 |
| Phase vs Conditions | Kubernetes Pod Lifecycle | Conditions(bool) primitive, Phase 파생 |
| state_enter callback | Erlang gen_statem | Buffer state entry/exit action |
| Half-Open probe | Circuit Breaker (Resilience4j) | Failing state = controlled probe |
| Guard conditions | Hybrid Automata | NonDet measurement -> Det guard evaluation |
| Result-based transition | TRPG engine_state_machine.mli | `can_transition` + typed error |

## Architecture: 3-Layer

```
Layer 3 (NonDet Shell)    Measurements -> Typed Events
                          keeper_keepalive.ml, keeper_memory_recall.ml
                              |  capture() — 유일한 NonDet 경계
                              v
Layer 2 (Det Core)        Events x Conditions -> Phase transitions
                          keeper_state_machine.ml (NEW)
                              |  derive_phase() — pure function
                              v
Layer 1 (Storage)         Atomic registry updates + backward-compat projection
                          keeper_registry.ml + keeper_state_compat.ml
```

핵심 불변량: **snapshot 이후 모든 것은 결정론적**. 같은 snapshot이면 같은 transition.

## State Definition

### 11-State Phase Enum

```ocaml
type phase =
  | Offline       (* Registered, no heartbeat fiber yet *)
  | Running       (* Healthy heartbeat loop *)
  | Failing       (* Consecutive failures detected, probing recovery *)
  | Compacting    (* Context compaction in progress *)
  | HandingOff    (* Generation rollover in progress *)
  | Draining      (* Graceful shutdown: completing current turn *)
  | Paused        (* Operator-paused *)
  | Stopped       (* Clean exit *)
  | Crashed       (* Unrecoverable error, restart candidate *)
  | Restarting    (* Supervisor backoff wait before re-launch *)
  | Dead          (* Restart budget exhausted, tombstone *)
```

### Observable Conditions (Kubernetes Pattern)

```ocaml
type conditions = {
  fiber_alive : bool;
  heartbeat_healthy : bool;
  turn_healthy : bool;
  context_within_budget : bool;
  context_handoff_needed : bool;
  compaction_active : bool;
  handoff_active : bool;
  operator_paused : bool;
  stop_requested : bool;
  restart_budget_remaining : bool;
  backoff_elapsed : bool;
  drain_complete : bool;
}
```

Phase는 conditions로부터 단일 pure function `derive_phase`로 파생된다.

### Transition Matrix

| From\To | Off | Run | Fail | Comp | Hand | Drain | Pause | Stop | Crash | Restart | Dead |
|---------|-----|-----|------|------|------|-------|-------|------|-------|---------|------|
| Offline |     | Y   |      |      |      |       |       | Y    |       |         |      |
| Running |     |     | Y    | Y    | Y    | Y     | Y     | Y    |       |         |      |
| Failing |     | Y   |      |      |      | Y     |       |      | Y     |         |      |
| Compact |     | Y   | Y    |      |      |       |       |      | Y     |         |      |
| HandOff |     | Y   | Y    |      |      |       |       |      | Y     |         |      |
| Draining|     |     |      |      |      |       |       | Y    | Y     |         |      |
| Paused  |     | Y   |      |      |      | Y     |       | Y    |       |         |      |
| Stopped |     |     |      |      |      |       |       |      |       |         |      |
| Crashed |     |     |      |      |      |       |       |      |       | Y       | Y    |
| Restart |     | Y   |      |      |      |       |       |      | Y     |         | Y    |
| Dead    |     |     |      |      |      |       |       |      |       |         |      |

Terminal states: Stopped, Dead.

### Buffer State Behavior

| State | Entry Trigger | Exit to Running | Exit to Crashed | Timeout |
|-------|--------------|-----------------|-----------------|---------|
| Failing | Heartbeat_failed (count < max) | Heartbeat_ok (counter reset) | count >= max | none |
| Compacting | Compaction_started | Compaction_completed | Compaction_failed | 60s |
| HandingOff | Handoff_started | Handoff_completed (gen++) | Handoff_failed | 30s |
| Draining | Stop_requested (turn active) | n/a | Drain timeout | 120s |
| Restarting | Supervisor_restart_attempt | Fiber launch success | Launch fail | backoff delay |

### Backward Compatibility

```ocaml
(* 11-state -> 5-state projection *)
let to_legacy = function
  | Offline       -> Stopped
  | Running       -> Running
  | Failing       -> Running   (* Still attempting recovery *)
  | Compacting    -> Running   (* Sub-activity of running *)
  | HandingOff    -> Running   (* Sub-activity of running *)
  | Draining      -> Running   (* Still completing work *)
  | Paused        -> Paused
  | Stopped       -> Stopped
  | Crashed       -> Crashed
  | Restarting    -> Crashed   (* Awaiting restart *)
  | Dead          -> Dead
```

## Det/NonDet Boundary

### Measurement Snapshot

모든 비결정론적 값(context_ratio, similarity scores, wall-clock, Runtime_params thresholds)을 한 번에 캡처하는 immutable record.

```ocaml
type measurement_snapshot = {
  snapshot_id : string;
  keeper_name : string;
  timestamp : float;           (* single clock read *)
  thresholds : threshold_params;  (* frozen Runtime_params *)
  context : context_measurement;
  similarity : similarity_measurement;
  timing : timing_measurement;
  failures : failure_measurement;
}
```

### Guard Evaluation

```ocaml
val evaluate : measurement_snapshot -> event list
(* Pure function. No I/O, no clock, no mutable reads. *)
(* Same snapshot -> same events. *)
```

### Audit Trail

모든 transition은 (snapshot, events_fired, selected_event, outcome)을 기록한다. `replay_check`로 historical snapshot을 재평가하여 동일 결과를 검증할 수 있다.

## Implementation Phases

### Phase 1: New Modules, Zero Consumers (1 PR)
- `keeper_state_machine.ml/.mli` — phase, conditions, events, derive_phase, apply_event
- `keeper_measurement.ml/.mli` — snapshot types (no capture impl yet)
- `keeper_guard.ml/.mli` — pure guard evaluation
- `keeper_transition_audit.ml/.mli` — audit record types
- `keeper_state_compat.ml/.mli` — legacy projection
- `test_keeper_state_machine.ml` — exhaustive pure tests

### Phase 2: Registry Integration (1 PR)
- `keeper_registry.ml` — conditions field, dispatch_event, set_state deprecated

### Phase 3: Supervisor Migration (1 PR)
- `keeper_supervisor.ml` — event-based crash/restart handling

### Phase 4: Keepalive Migration (1 PR)
- `keeper_keepalive.ml` — snapshot capture + event dispatch
- `keeper_memory_recall.ml` — guard wrapper

### Phase 5: Cleanup + Dashboard (1 PR)
- Remove deprecated set_state, derive_pipeline_stage heuristic
- Dashboard phase rendering

## Risks

| Risk | Mitigation |
|------|-----------|
| Eio fiber safety | conditions는 non-yielding 연산만 사용. 단일 fiber 소유 |
| Dashboard backward compat | registry_state (5-state) 유지, phase (11-state) 추가 |
| Transition table 복잡도 | derive_phase single pure function + property test 전수 검증 |
| GADT 과잉 | Phase payload 차이가 작아 plain variant + exhaustive match 선택 |

## Scope Exclusion

- RFC-0001의 Emotional Recovery Loop, Thompson rehabilitation (별도 구현)
- Adversarial harness (Phase 5 이후)
- failure_reason ADT 변경 없음 (self-preservation과 직교)
