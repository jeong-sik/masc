---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_state_machine.ml
  - lib/keeper/keeper_config.ml
  - lib/keeper/heartbeat_smart.ml
---

# Adaptive Heartbeat Phi Enforcement RFC

**Status**: Draft, follow-up enforcement gate
**Date**: 2026-03-29
**Scope**: gRPC heartbeat phi-accrual enforcement semantics, transport overlay state, safe rollback boundaries
**One sentence**: Phi-accrual을 production에서 enforcement 할 때도 keeper supervisor와 room freshness ownership을 건드리지 않도록, transport-only enforcement contract를 잠근다.

## Related Documents

- `./adaptive-heartbeat-grpc-and-phi-rollout-rfc.md`
- `./adaptive-heartbeat-scheduling-rfc.md`
- `./adaptive-heartbeat-production-rollout-rfc.md`
- `./adaptive-heartbeat-observability-slo-spec.md`
- `./adaptive-heartbeat-validation-and-alert-wiring-spec.md`
- `./adaptive-heartbeat-safety-harness-spec.md`
- `../TRANSPORT-PRACTICAL-PLAYBOOK.md`

## 1. Goal

이 문서는 `adaptive-heartbeat-grpc-and-phi-rollout-rfc.md` 의 G5를 구체화한다.

목표는 세 가지다:

- phi-accrual enforcement의 최대 권한을 transport overlay로 제한한다.
- network loss signal이 local room ownership이나 keeper restart state로 번역되지 않게 막는다.
- operator가 advisory mode와 enforcement mode의 차이를 명확히 이해할 수 있게 한다.

## 2. Preconditions

이 RFC는 아래가 모두 충족되기 전에는 적용하지 않는다.

- canonical HTTP/file adaptive heartbeat Stage 0-3 완료
- gRPC/Phi rollout RFC의 G0-G4 완료
- phi shadow mode 14일 evidence 보유
- advisory alerts가 noisy 하지 않음
- [adaptive-heartbeat-safety-harness-spec.md](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/feature/adaptive-heartbeat-scheduling-rfc/docs/design/adaptive-heartbeat-safety-harness-spec.md) 의 gRPC/Phi 시나리오 구현 완료

이 전제 하나라도 빠지면 phi enforcement는 `No-Go` 다.

## 3. Non-Goals

- phi crossing만으로 keeper를 `Crashed` 또는 `Dead` 로 전이하지 않는다.
- phi를 reconcile ownership predicate에 사용하지 않는다.
- phi를 `last_successful_heartbeat_ts` 갱신/차단의 SSOT로 쓰지 않는다.
- phi를 room presence `consecutive_failures` reset에 사용하지 않는다.
- local keepalive fiber를 phi로 stop 하지 않는다.

## 4. Enforcement Model

### 4.1 Transport Overlay State

phi enforcement는 `keeper_state` 와 별도로 아래 transport overlay를 도입한다.

| Overlay state | Meaning | Keeper state impact |
|---|---|---|
| `Healthy` | gRPC ack cadence normal | none |
| `Suspect` | phi threshold 경계 접근, network jitter 의심 | none |
| `Unhealthy` | phi threshold sustained crossing, current gRPC stream 불신 | none |

Rules:

- overlay state는 operator-visible field여야 한다.
- overlay state는 `Running/Crashed/Dead` 같은 keeper lifecycle state를 대체하지 않는다.
- a keeper can be `Running + Unhealthy` or `Crashed + Healthy`; the domains remain separate.

### 4.2 Allowed Enforcement Actions

Production에서 phi enforcement가 할 수 있는 일은 아래로 제한한다.

| Action | Allowed | Notes |
|---|---|---|
| warning badge / alert emit | yes | advisory와 동일 |
| gRPC directive consumption suspend | yes | transport safety only |
| current gRPC heartbeat stream voluntary close | yes | transport reset only |
| gRPC reconnect backoff escalate | yes | separate from keeper restart budget |
| keeper `Crashed` / `Dead` transition | no | forbidden |
| room freshness lease mutation | no | forbidden |
| reconcile suppression / resume | no | forbidden |
| supervisor restart budget consumption | no | forbidden |

### 4.3 Enforcement Ladder

#### E1: Suspect

Entry:

- `phi_value >= suspect_threshold` for `N` consecutive samples

Action:

- set `grpc_transport_state=Suspect`
- emit warning
- keep current stream open

Exit:

- `phi_value < suspect_threshold` for `M` consecutive samples

#### E2: Unhealthy

Entry:

- `phi_value >= unhealthy_threshold` for `N` consecutive samples

Action:

- set `grpc_transport_state=Unhealthy`
- emit critical transport alert
- stop trusting gRPC directives for this stream
- voluntarily close the current gRPC heartbeat stream
- enter gRPC-only reconnect backoff

Exit:

- successful reconnect + ack stabilization for `M` consecutive samples

#### E3: Recovery

Action:

- clear `grpc_transport_state` back to `Healthy`
- clear temporary directive suppression
- record recovery event

Recovery must not mutate keeper `restart_count` or `failure_reason`.

## 5. Runtime Contract

### 5.1 Flags

| Flag | Default | Meaning |
|---|---|---|
| `MASC_KEEPER_PHI_ENABLED` | `0` | enable phi module |
| `MASC_KEEPER_PHI_MODE` | `off` | `off`, `shadow`, `advisory`, `enforced` |
| `MASC_KEEPER_PHI_SUSPECT_THRESHOLD` | implementation-defined | enter `Suspect` |
| `MASC_KEEPER_PHI_UNHEALTHY_THRESHOLD` | implementation-defined | enter `Unhealthy` |
| `MASC_KEEPER_PHI_CONSECUTIVE_SAMPLES` | implementation-defined | consecutive sample gate |
| `MASC_KEEPER_PHI_RECONNECT_BACKOFF_MAX_SEC` | implementation-defined | gRPC-only reconnect ceiling |

### 5.2 Required Fields

| Field | Meaning |
|---|---|
| `grpc_transport_state` | `Healthy`, `Suspect`, `Unhealthy` |
| `phi_value` | current accrual score |
| `phi_mode` | `shadow`, `advisory`, `enforced` |
| `phi_last_transition_ts` | last overlay transition |
| `grpc_directives_suppressed` | whether directives are ignored |
| `grpc_reconnect_backoff_sec` | active gRPC-only reconnect delay |

## 6. Metrics and Alerts

### 6.1 Required Metrics

| Metric | Meaning |
|---|---|
| `masc_keeper_phi_transition_total{from,to}` | overlay transitions |
| `masc_keeper_phi_enforcement_total{action}` | enforcement actions taken |
| `masc_keeper_grpc_directive_suppression_total` | directives dropped due to phi enforcement |
| `masc_keeper_grpc_phi_reconnect_total` | gRPC reconnects initiated by phi enforcement |

### 6.2 Hard Safety Counters

These must remain zero during phi enforcement rollout:

- `masc_keeper_dead_resurrection_total`
- `masc_keeper_reconcile_registered_launch_total`
- `masc_keeper_false_freshness_skip_total`
- `masc_keeper_unplanned_self_preservation_total`
- `masc_keeper_phi_state_violation_total`

`masc_keeper_phi_state_violation_total` means phi enforcement changed local keeper state, room freshness lease, or supervisor restart accounting.

## 7. Validation Requirements

Before enabling `MASC_KEEPER_PHI_MODE=enforced`, all of the following must be proven:

- shadow mode confusion matrix available
- advisory mode alert quality accepted
- manual disconnect test keeps keeper lifecycle state unchanged
- jitter burst test may enter `Suspect` but not `Unhealthy` if reconnect is unnecessary
- hard disconnect test may enter `Unhealthy` and close gRPC stream, but local keepalive continues
- no safety counter increments

## 8. Rollback

Rollback order:

1. `MASC_KEEPER_PHI_MODE=advisory`
2. if needed, `MASC_KEEPER_PHI_MODE=off`
3. if gRPC path itself is unstable, disable gRPC transport cohort

If any local keeper state mutation is attributed to phi enforcement, rollback is immediate and mandatory.

## 9. Exit Criteria

This RFC is satisfied only when:

- phi enforcement is documented as transport-only
- operator surfaces show overlay state distinctly from keeper lifecycle state
- hard safety counters remain zero in rollout
- gRPC reconnect control is demonstrably separated from supervisor restart budget
- rollback from `enforced` to `advisory` is scripted and tested
