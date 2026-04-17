---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_alerting.ml
  - lib/keeper/keeper_composite_observer.ml
  - lib/keeper/keeper_accountability.ml
---

# Adaptive Heartbeat Validation and Alert Wiring Spec

**Status**: Draft, production prerequisite
**Date**: 2026-03-29
**Scope**: Safety counter wiring, operator surface mapping, harness coverage, alert routing for adaptive heartbeat
**One sentence**: Adaptive heartbeat rollout gate를 추상 정책이 아니라 concrete dashboard fields, metrics, harness assertions, and alert rules로 연결한다.

## Related Documents

- `./adaptive-heartbeat-scheduling-rfc.md`
- `./adaptive-heartbeat-production-rollout-rfc.md`
- `./adaptive-heartbeat-observability-slo-spec.md`
- `./adaptive-heartbeat-grpc-and-phi-rollout-rfc.md`
- `./adaptive-heartbeat-phi-enforcement-rfc.md`
- `./adaptive-heartbeat-safety-harness-spec.md`
- `../ADAPTIVE-HEARTBEAT-PRODUCTION-RUNBOOK.md`
- `../MCP-READPATH-REVALIDATION-RUNBOOK.md`
- `../KEEPER-CONTINUITY-VALIDATION.md`
- `../TRANSPORT-PRACTICAL-PLAYBOOK.md`
- `../PERFORMANCE-SLO.md`

## 1. Goal

현재 production bundle은 무엇을 봐야 하는지 정의한다. 이 문서는 그것을 어디서, 어떻게, 무엇으로 검증할지 잠근다.

목표:

- required field와 safety counter를 concrete surface에 매핑
- 기존 harness가 무엇을 검증하고 무엇이 비어 있는지 명시
- alert severity와 rollout stop/go 조건을 연결

## 2. Validation Stack

Adaptive heartbeat production validation은 아래 네 층으로 구성한다.

| Layer | Primary artifact | Purpose |
|---|---|---|
| Operator field truth | `masc_keeper_status`, `masc_keeper_list`, dashboard execution | keeper state/failure ownership 확인 |
| Transport truth | `/api/v1/dashboard/transport-health` | gRPC/SSE/WS path health 확인 |
| Harness truth | read-path + continuity + safety harness | rollout gate 자동 검증 |
| Latency truth | `benchmarks/quick-bench.sh` | global MCP/REST/SSE SLO 확인 |

어느 한 층만 green이어도 promotion 할 수 없다.

## 3. Surface Mapping

### 3.1 Keeper Health Fields

This document uses `operator-visible keeper surface` to mean:

- at least one MCP keeper tool surface: `masc_keeper_status` or `masc_keeper_list(detailed=true)`
- at least one dashboard/operator snapshot surface: dashboard execution keeper sample or equivalent

Production gate requires both categories, not one alone.

| Required field | Primary surface | Secondary surface | Required by |
|---|---|---|---|
| `state` | `masc_keeper_status` | `masc_keeper_list(detailed=true)` | Stage 1 |
| `failure_reason` | `masc_keeper_status` | dashboard execution keeper sample | Stage 1 |
| `failure_streak_count` | `masc_keeper_status` | dashboard execution keeper sample | Stage 1 when heartbeat failure applies |
| `restart_count` | `masc_keeper_status` | `masc_keeper_list(detailed=true)` | Stage 1 |
| `last_restart_ts` | `masc_keeper_status` | dashboard execution keeper sample | Stage 1 |
| `last_successful_heartbeat_age_sec` | `masc_keeper_status` | `masc_keeper_list(detailed=true)` | Stage 1 |
| `consecutive_failures` | `masc_keeper_status` | dashboard execution keeper sample | Stage 1 |
| `self_preservation_active` | `masc_keeper_status` or dashboard execution | `masc_keeper_list(detailed=true)` | Stage 1 |
| `dead_ttl_remaining_sec` | `masc_keeper_status` | dashboard execution keeper sample | Stage 1 |
| `reconcile_excluded_reason` | `masc_keeper_status` | `masc_keeper_list(detailed=true)` | Stage 2 |

Rules:

- dashboard sample payload is not enough by itself; at least one MCP tool surface must expose the same fields
- `state=Dead` without `dead_ttl_remaining_sec` is a validation failure
- `failure_reason` must be normalized, not a raw stack trace
- `failure_reason=heartbeat_consecutive_failures` 이면 `failure_streak_count` 가 동반되어야 한다

### 3.2 Transport Fields

| Required field | Surface | Purpose |
|---|---|---|
| `grpc.listening` | `/api/v1/dashboard/transport-health` | gRPC transport readiness |
| `grpc.active_streams` | `/api/v1/dashboard/transport-health` | live gRPC usage |
| `grpc.subscribers` | `/api/v1/dashboard/transport-health` | external fanout visibility |
| `grpc.heartbeat_avg_seconds` | `/api/v1/dashboard/transport-health` | gRPC heartbeat latency |
| `sse.queue_max_depth` | `/api/v1/dashboard/transport-health` | SSE pressure correlation |
| `summary.primary_path` | `/api/v1/dashboard/transport-health` | active path recommendation |

Transport fields are advisory for canonical HTTP/file rollout, but mandatory for gRPC/Phi follow-up.

## 4. Metrics Wiring

### 4.1 Safety Counters

The following metrics must exist as machine-readable counters.

| Metric | Required consumer |
|---|---|
| `masc_keeper_dead_resurrection_total` | alert + rollout gate |
| `masc_keeper_reconcile_registered_launch_total` | alert + rollout gate |
| `masc_keeper_false_freshness_skip_total` | alert + rollout gate |
| `masc_keeper_unplanned_self_preservation_total` | alert + rollout gate |

Rules:

- every safety counter must be queryable without log parsing
- dashboard may summarize them, but Prometheus-style metric or equivalent numeric surface is the source of truth
- any increment must annotate keeper name, state, and failure cohort in logs or structured event stream
- injected validation runs must carry a machine-readable `planned_test=true` or equivalent annotation so planned suppression events do not increment `masc_keeper_unplanned_self_preservation_total`

### 4.2 Health Metrics

These metrics are not required to stay zero, but they must exist for trend and regression checks.

| Metric | Used by |
|---|---|
| `masc_keeper_presence_sync_attempt_total{result}` | failure ratio alert |
| `masc_keeper_presence_sync_duration_seconds` | p95 regression gate |
| `masc_keeper_keepalive_cycle_duration_seconds` | p95 regression gate |
| `masc_keeper_freshness_skip_total` | skip trend |
| `masc_keeper_room_heartbeat_after_turn_total{result}` | domain separation audit |
| `masc_keeper_state_transition_total{from,to}` | state machine audit |
| `masc_keeper_restart_total{failure_reason}` | crash pressure |
| `masc_keeper_dead_tombstone_total` | exhausted keeper rate |
| `masc_keeper_dead_cleanup_total` | TTL cleanup audit |
| `masc_keeper_self_preservation_total{failure_reason}` | suppression visibility |

## 5. Harness Coverage

### 5.1 Existing Harness Ownership

| Harness | Current role | Required adaptive heartbeat assertions |
|---|---|---|
| `./scripts/harness_mcp_readpath_revalidation.sh` | MCP/dash cached read-path | required fields exist, cache stays fresh, transport-health remains queryable |
| `./scripts/harness_keeper_continuity_validation.sh` | live keeper continuity proof | room presence continuity, restart ownership continuity, post-restart same-name recovery |
| `./benchmarks/quick-bench.sh` | global latency | MCP/REST/SSE SLO guardrail |

### 5.2 Required Extensions

The current harnesses are necessary but not sufficient. Extend them as follows.

`mcp_readpath_revalidation.sh`:

- assert keeper sample payload contains required adaptive heartbeat fields
- assert `state=Dead` sample includes `dead_ttl_remaining_sec`
- assert `transport-health` remains `fresh` with adaptive fields enabled
- assert registered `Crashed` or `Dead` keeper is excluded because of registry ownership, not because the fiber is merely not running

`keeper_continuity_validation.sh`:

- inject the specific scenario `turn succeeds but Room.heartbeat_in_room fails`, then assert freshness lease does not refresh
- assert `Crashed` keeper is not relaunched by reconcile while registered
- assert `Dead` keeper remains excluded from reconcile until TTL cleanup
- assert TTL cleanup writes `meta.paused=true` before registry unregister; failed pause write must leave the keeper in `Dead`

### 5.3 New Safety Harness

Add a dedicated workload harness before Stage 2 promotion:

`./scripts/harness/workload/adaptive_heartbeat_safety_validation.sh`

Detailed script contract and scenario matrix are defined in `adaptive-heartbeat-safety-harness-spec.md`.

This harness should inject or simulate:

- repeated room heartbeat failures
- restart-budget exhaustion
- reconcile sweep while registered `Crashed`
- self-preservation dominant cohort burst

The harness is the canonical place to prove safety counters stay zero in the no-fault case and increment in the injected-fault case.

Planned vs unplanned suppression rule:

- fault-injection runs must stamp the run id and `planned_test=true` into emitted artifacts and structured events
- only suppressions without that annotation count toward `masc_keeper_unplanned_self_preservation_total`
- if annotation is missing, the event is treated as unplanned by default

## 6. Alert Routing

### 6.1 Critical Alerts

Trigger immediately on:

- `masc_keeper_dead_resurrection_total > 0`
- `masc_keeper_reconcile_registered_launch_total > 0`
- `masc_keeper_false_freshness_skip_total > 0`
- `masc_keeper_unplanned_self_preservation_total > 0`
- `state=Dead` surface missing `dead_ttl_remaining_sec`

Operator action:

- stop rollout
- preserve artifacts
- execute rollback from the production runbook

### 6.2 Warning Alerts

Trigger investigation, but not auto-rollback, on:

- presence sync failure ratio > 1% for 10m
- repeated `Crashed -> Running -> Crashed` loop below `Dead` threshold
- keepalive cycle p95 or presence sync p95 > 25% regression from Stage 0 baseline
- gRPC reconnect loop during G1-G4 follow-up rollout

## 7. Artifact Contract

Each rollout stage must leave behind:

- read-path summary json
- continuity summary json
- benchmark output
- keeper sample payload
- transport-health sample payload
- alert query output or screenshot-equivalent evidence

Artifact without timestamps or stage label is invalid evidence.

## 8. Go / No-Go Matrix

| Signal | Go | No-Go |
|---|---|---|
| required field presence | complete and internally consistent | missing or contradictory |
| safety counters | all zero | any increment |
| harness pass | all required harnesses pass | any fail |
| global SLO | within published limits | breach |
| alert state | no critical alerts | any critical alert |

## 9. Exit Criteria

This spec is satisfied only when:

- required fields are visible in keeper and dashboard surfaces
- safety counters are wired to machine-readable metrics
- existing harnesses are extended with adaptive heartbeat assertions
- the new safety harness exists or an equivalent scripted proof is documented
- alert thresholds and operator actions are consistent with the production runbook
