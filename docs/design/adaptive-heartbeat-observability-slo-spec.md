---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_accountability.ml
  - lib/keeper/keeper_alerting.ml
  - lib/keeper/keeper_composite_observer.ml
---

# Adaptive Heartbeat Observability and SLO Spec

**Status**: Draft, production prerequisite
**Date**: 2026-03-29
**Scope**: Canonical HTTP/file keeper path observability fields, metric taxonomy, safety counters, rollout SLO gates
**One sentence**: Adaptive heartbeat를 production에 올리기 전에 operator surface, failure taxonomy, and rollout-blocking SLO를 잠근다.

## Related Documents

- `./adaptive-heartbeat-scheduling-rfc.md`
- `./adaptive-heartbeat-production-rollout-rfc.md`
- `./adaptive-heartbeat-validation-and-alert-wiring-spec.md`
- `./adaptive-heartbeat-grpc-and-phi-rollout-rfc.md`
- `./adaptive-heartbeat-phi-enforcement-rfc.md`
- `./adaptive-heartbeat-safety-harness-spec.md`
- `./error-handling-and-operations-spec.md`
- `../PERFORMANCE-SLO.md`
- `../ADAPTIVE-HEARTBEAT-PRODUCTION-RUNBOOK.md`

## 1. Goal

Adaptive heartbeat의 production gate는 단순 latency가 아니라 `ownership safety + operator truth` 다.

이 문서의 목적은:

- operator가 keeper recovery 상태를 오해하지 않도록 공개 필드를 잠그고
- rollout 동안 반드시 0이어야 하는 safety counter를 정의하고
- global performance SLO와 heartbeat-specific promotion gate를 연결하는 것이다.

## 2. Canonical Scope

이 문서의 모든 규칙은 canonical HTTP/file keeper path에만 적용한다.

- `MASC_GRPC_ENABLED=0`
- phi-accrual 미포함
- work-as-heartbeat + self-preservation + `Dead` tombstone 포함

gRPC/Phi가 들어오면 별도 observability spec이 필요하다.

## 3. Required Operator Surfaces

아래 필드는 최소 하나의 operator-visible keeper surface에서 반드시 보여야 한다. 권장 표준 surface는 `masc_keeper_list(detailed=true)` 와 관련 dashboard/operator snapshot이다.

| Field | Meaning | Required for rollout |
|---|---|---|
| `state` | `Running/Paused/Stopped/Crashed/Dead` | yes |
| `failure_reason` | canonical serialized failure reason | yes for `Crashed` / `Dead` |
| `failure_streak_count` | integer streak detail for heartbeat failure cohorts | yes when `failure_reason=heartbeat_consecutive_failures` |
| `restart_count` | supervisor restart budget consumption | yes |
| `last_restart_ts` | last restart attempt time | yes |
| `last_successful_heartbeat_age_sec` | freshness lease age | yes |
| `consecutive_failures` | presence-sync failure streak | yes |
| `self_preservation_active` | current sweep suppression state | yes |
| `dead_ttl_remaining_sec` | `Dead` tombstone cleanup countdown | yes when `state=Dead` |
| `reconcile_excluded_reason` | why reconcile is skipping this keeper | recommended |

## 4. Canonical Failure Reason Taxonomy

Failure grouping은 free-form string matching으로 하지 않는다. Operator surface와 logs는 아래 taxonomy를 canonical source로 사용한다.

| Serialized value | Meaning |
|---|---|
| `heartbeat_consecutive_failures` | room/presence sync failure streak이 budget 초과 |
| `fiber_unresolved` | supervisor generic fallback path |
| `exception:<summary>` | structured but non-heartbeat exception |

Rules:

- `Heartbeat_consecutive_failures of int` 는 serialized operator field에서 `heartbeat_consecutive_failures` 로 normalize 한다.
- integer streak count는 `failure_streak_count` 로 별도 노출하고, cohort key에는 넣지 않는다.
- `exception:<summary>` 의 `<summary>` 는 bounded, stable, non-stack-trace string 이어야 한다.

## 5. Production Metrics

Canonical naming rule:

- `masc_` prefix와 base unit `seconds` 를 canonical metric namespace로 사용한다.
- prefix 없는 older examples or `_ms` names are legacy draft notation only and must not be used as the production query source.

### 5.1 Safety Counters

아래 counter는 rollout promotion 동안 모두 `0` 이어야 한다.

| Metric | Meaning |
|---|---|
| `masc_keeper_dead_resurrection_total` | `Dead` keeper가 operator action 없이 다시 실행됨 |
| `masc_keeper_reconcile_registered_launch_total` | registry entry가 있는 keeper를 reconcile이 잘못 재기동 |
| `masc_keeper_false_freshness_skip_total` | failed room heartbeat 이후 freshness skip 발생 |
| `masc_keeper_unplanned_self_preservation_total` | operator-injected test가 아닌 suppression 발생 |

이 네 개 중 하나라도 증가하면 rollout은 stop 상태다.

### 5.2 Health Metrics

아래는 measured-but-not-zero counters다.

| Metric | Required use |
|---|---|
| `masc_keeper_presence_sync_attempt_total{result}` | success/error 비율 추적 |
| `masc_keeper_presence_sync_duration_seconds` | stage latency |
| `masc_keeper_keepalive_cycle_duration_seconds` | 전체 keepalive loop latency |
| `masc_keeper_freshness_skip_total` | skip hit rate |
| `masc_keeper_room_heartbeat_after_turn_total{result}` | turn 후 heartbeat success/failure |
| `masc_keeper_state_transition_total{from,to}` | state machine audit |
| `masc_keeper_restart_total{failure_reason}` | restart pressure 추적 |
| `masc_keeper_dead_tombstone_total` | exhausted keeper 발생량 |
| `masc_keeper_dead_cleanup_total` | TTL cleanup 완료량 |
| `masc_keeper_self_preservation_total{failure_reason}` | dominant cohort suppression 횟수 |

## 6. SLO and Alert Policy

### 6.1 Global SLO

Global API/SSE requirements are inherited unchanged from [PERFORMANCE-SLO.md](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/docs/PERFORMANCE-SLO.md).

Promotion is blocked if the candidate breaches any published MCP/REST/SSE threshold.

### 6.2 Heartbeat-Specific Promotion Gate

Absolute latency 대신 baseline-relative gate를 사용한다.

| Gate | Rule |
|---|---|
| Safety counters | all zero |
| Global performance | no PERFORMANCE-SLO breach |
| Keepalive latency regression | `masc_keeper_keepalive_cycle_duration_seconds` p95 must not regress more than 25% vs Stage 0 baseline |
| Presence sync latency regression | `masc_keeper_presence_sync_duration_seconds` p95 must not regress more than 25% vs Stage 0 baseline |
| Operator truth | required fields must be present and internally consistent |

### 6.3 Alerts

| Severity | Condition |
|---|---|
| `critical` | any safety counter > 0 |
| `critical` | `state=Dead` keeper without visible `dead_ttl_remaining_sec` |
| `critical` | unplanned self-preservation trigger |
| `warn` | presence sync failure ratio > 1% for 10m |
| `warn` | repeated `Crashed -> Running -> Crashed` loop below `Dead` threshold |

## 7. Acceptance Queries

Runbook and dashboards must be able to answer these without log spelunking:

- Is any keeper currently `Dead`?
- Why is a keeper `Crashed`?
- If `failure_reason=heartbeat_consecutive_failures`, what is the current streak count?
- Is reconcile skipping a keeper because it is registered, paused, or dead?
- Was the last freshness lease created by a successful room heartbeat?
- Did self-preservation fire, and for which failure cohort?

If any answer requires reading raw stack traces or filesystem state directly, observability is incomplete.

## 8. Owners

The following ownership split is required:

- keeper runtime owner: failure taxonomy, state transitions, safety counters
- operator/dashboard owner: keeper surface fields, dashboard truth, alert visibility
- rollout owner: Stage 0-3 baseline comparison and promotion decision

This split is role-based. One person may fill multiple roles, but the responsibilities remain distinct.

## 9. Exit Criteria

This spec is satisfied only when:

- all required fields are implemented in an operator-visible surface
- all safety counters are emitted and testable
- alert conditions are documented and wired
- rollout runbook references these exact metrics and fields
- baseline-relative gates and global SLO gates are both enforceable
