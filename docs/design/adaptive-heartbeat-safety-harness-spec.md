---
status: reference
last_verified: 2026-04-17
code_refs:
  - scripts/harness/
  - lib/keeper/keeper_state_machine.ml
  - lib/keeper/keeper_composite_observer.ml
---

# Adaptive Heartbeat Safety Harness Spec

**Status**: Draft, implementation spec
**Date**: 2026-03-29
**Scope**: Dedicated workload harness for adaptive heartbeat safety invariants, injected-fault scenarios, artifact contract
**One sentence**: Adaptive heartbeat의 production gate를 자동화하려면, ownership/freshness/dead-tombstone/self-preservation invariant를 시나리오별로 증명하는 전용 harness가 필요하다.

## Related Documents

- `./adaptive-heartbeat-scheduling-rfc.md`
- `./adaptive-heartbeat-production-rollout-rfc.md`
- `./adaptive-heartbeat-observability-slo-spec.md`
- `./adaptive-heartbeat-validation-and-alert-wiring-spec.md`
- `./adaptive-heartbeat-grpc-and-phi-rollout-rfc.md`
- `./adaptive-heartbeat-phi-enforcement-rfc.md`
- `../ADAPTIVE-HEARTBEAT-PRODUCTION-RUNBOOK.md`
- `../KEEPER-CONTINUITY-VALIDATION.md`

## 1. Goal

이 문서는 새 workload harness의 script contract를 정의한다.

대상 스크립트:

`./scripts/harness/workload/adaptive_heartbeat_safety_validation.sh`

이 harness의 목적:

- no-fault baseline에서 safety counters zero를 증명
- injected fault에서 expected counter/state transition만 발생함을 증명
- runbook stop/go 규칙을 machine-checkable artifact로 남김

## 2. Non-Goals

- global latency benchmark 대체
- long-haul soak test 대체
- general chaos engineering framework 제공
- keeper continuity harness 전체 대체

이 harness는 safety invariant 전용이다.

## 3. Script Contract

### 3.1 Inputs

Recommended environment surface:

| Variable | Meaning |
|---|---|
| `RUN_ID` | run identifier |
| `RUN_DIR` | artifact root |
| `START_SERVER` | harness-managed server startup 여부 |
| `KEEP_SERVER` | run 후 server 유지 여부 |
| `BASE_PATH` | runtime base path |
| `TARGET_SCENARIOS` | comma-separated scenario list |
| `PORT` | server port override |
| `KEEPER_NAME` | target durable keeper name |
| `KEEPER_MODELS` | deterministic model cascade override |
| `PLANNED_TEST` | planned fault injection marker, default `1` |

### 3.2 Default Scenario Set

Default:

`TARGET_SCENARIOS=baseline,freshness_domain,reconcile_ownership,dead_tombstone,self_preservation`

Optional follow-up:

- `grpc_transport`
- `phi_shadow`
- `phi_enforced`

## 4. Artifact Contract

The harness must produce:

| Artifact | Purpose |
|---|---|
| `summary.json` | overall pass/fail and scenario matrix |
| `phases.jsonl` | chronological scenario events |
| `keeper-status-*.json` | operator surface snapshots |
| `transport-health-*.json` | transport snapshots |
| `metrics-*.txt` or `metrics-*.json` | safety counter and health metric sample |
| `fault-plan.json` | injected fault parameters and `planned_test=true` |

Required summary fields:

- `run_id`
- `planned_test`
- `scenarios`
- `safety_counters_before`
- `safety_counters_after`
- `keeper_samples`
- `transport_samples`
- `pass`

Artifact without `planned_test` is invalid for self-preservation scenarios.

## 5. Core Scenarios

### 5.1 `baseline`

Purpose:

- prove no-fault adaptive heartbeat does not trip safety counters

Assertions:

- all safety counters remain zero
- required keeper fields are visible
- no unexpected `Crashed` or `Dead`

### 5.2 `freshness_domain`

Purpose:

- prove turn success does not mask room heartbeat failure

Injection:

- simulate or force `turn succeeds but Room.heartbeat_in_room fails`

Assertions:

- `last_successful_heartbeat_ts` does not refresh
- `last_successful_heartbeat_age_sec` increases
- `masc_keeper_false_freshness_skip_total` remains zero in no-fault branch and increments only if the invariant is intentionally violated in a negative test mode

### 5.3 `reconcile_ownership`

Purpose:

- prove registered `Crashed` or `Dead` keeper is not relaunched by reconcile

Injection:

- create registered `Crashed` keeper with restart/backoff pending

Assertions:

- reconcile excludes the keeper because `is_registered=true`
- `masc_keeper_reconcile_registered_launch_total` remains zero
- owner of recovery remains supervisor path

### 5.4 `dead_tombstone`

Purpose:

- prove exhausted keeper remains excluded until cleanup

Injection:

- exhaust restart budget

Assertions:

- keeper enters `Dead`
- `dead_ttl_remaining_sec` is visible
- cleanup writes `meta.paused=true` before unregister
- failed pause write leaves the keeper in `Dead`
- `masc_keeper_dead_resurrection_total` remains zero

### 5.5 `self_preservation`

Purpose:

- prove planned dominant cohort suppression is distinguishable from unplanned incidents

Injection:

- trigger dominant `failure_reason` burst across multiple keepers

Assertions:

- suppression event carries `planned_test=true`
- planned event does not increment `masc_keeper_unplanned_self_preservation_total`
- operator surface shows active suppression and failure cohort

## 6. Optional Follow-Up Scenarios

### 6.1 `grpc_transport`

Purpose:

- validate gRPC heartbeat surface without changing canonical safety semantics

Assertions:

- `grpc_connected` and `last_grpc_ack_age_sec` visible
- disconnected gRPC stream does not refresh room freshness lease

### 6.2 `phi_shadow`

Purpose:

- validate shadow-only phi evidence capture

Assertions:

- `phi_value`, `phi_threshold`, `phi_shadow_decision` visible
- shadow run does not mutate keeper lifecycle state

### 6.3 `phi_enforced`

Purpose:

- validate transport-only phi enforcement per [adaptive-heartbeat-phi-enforcement-rfc.md](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/feature/adaptive-heartbeat-scheduling-rfc/docs/design/adaptive-heartbeat-phi-enforcement-rfc.md)

Assertions:

- `grpc_transport_state` may change
- keeper `state` does not change because of phi
- `masc_keeper_phi_state_violation_total` remains zero

## 7. Pass/Fail Rules

The harness is `fail` if any of the following occur:

- required artifact missing
- `planned_test` marker missing for injected-fault scenarios
- unexpected safety counter increment
- contradictory operator surface fields
- scenario-specific invariant failure

The harness is `pass` only if:

- every targeted scenario passes
- safety counter deltas match expectation
- generated artifacts are timestamped and machine-readable

## 8. Runbook Mapping

Recommended rollout usage:

| Stage | Required scenarios |
|---|---|
| Stage 1 canary | `baseline,freshness_domain,reconcile_ownership` |
| Stage 2 soak | `baseline,freshness_domain,reconcile_ownership,dead_tombstone,self_preservation` |
| gRPC/Phi follow-up | add `grpc_transport`, `phi_shadow`, and optionally `phi_enforced` |

## 9. Exit Criteria

This spec is satisfied only when:

- the harness script exists at the declared path
- default scenarios produce the required artifacts
- runbook references the harness as a production gate
- gRPC/Phi follow-up scenarios are either implemented or explicitly skipped with rationale
