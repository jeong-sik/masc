---
status: runbook
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_state_machine.ml
  - lib/keeper/keeper_config.ml
  - lib/keeper/heartbeat_smart.ml
---

# Adaptive Heartbeat Production Runbook

이 runbook은 canonical HTTP/file keeper path에서 adaptive heartbeat를 production에 올릴 때 사용하는 절차다.

## Related Documents

- `docs/design/adaptive-heartbeat-production-rollout-rfc.md`
- `docs/design/adaptive-heartbeat-observability-slo-spec.md`
- `docs/design/adaptive-heartbeat-validation-and-alert-wiring-spec.md`
- `docs/design/adaptive-heartbeat-grpc-and-phi-rollout-rfc.md`
- `docs/design/adaptive-heartbeat-phi-enforcement-rfc.md`
- `docs/design/adaptive-heartbeat-safety-harness-spec.md`
- `docs/MCP-READPATH-REVALIDATION-RUNBOOK.md`
- `docs/TRANSPORT-PRACTICAL-PLAYBOOK.md`

## Scope

- 포함: `work-as-heartbeat`, `self-preservation`, `Crashed/Dead` keeper state
- 제외: gRPC heartbeat, phi-accrual, cascade scheduler

기본 transport posture:

```bash
export MASC_GRPC_ENABLED=0
```

## Required Flags

Candidate and production target defaults:

```bash
export MASC_KEEPER_ADAPTIVE_HEARTBEAT_ENABLED=1
export MASC_KEEPER_WORK_AS_HEARTBEAT=1
export MASC_KEEPER_MAX_SILENCE_SEC=120
export MASC_KEEPER_SELF_PRESERVATION_ENABLED=1
export MASC_KEEPER_SELF_PRESERVATION_RATIO=0.3
export MASC_KEEPER_SELF_PRESERVATION_MIN_CANDIDATES=2
export MASC_KEEPER_DEAD_TTL_SEC=3600
```

Emergency rollback posture:

```bash
export MASC_KEEPER_ADAPTIVE_HEARTBEAT_ENABLED=0
```

If the service requires restart to apply env config, restart it before validation.

## Stage 0: Baseline Lock

Capture baseline with adaptive heartbeat disabled.

```bash
export MASC_KEEPER_ADAPTIVE_HEARTBEAT_ENABLED=0
MODES=http_only ./scripts/harness_mcp_readpath_revalidation.sh
./scripts/harness_keeper_continuity_validation.sh
MASC_URL=http://127.0.0.1:8935/mcp ./benchmarks/quick-bench.sh
curl -fsS http://127.0.0.1:8935/health/ready
curl -fsS http://127.0.0.1:8935/api/v1/dashboard/execution | jq '.projection_diagnostics.cache_state'
curl -fsS http://127.0.0.1:8935/api/v1/dashboard/transport-health | jq '.projection_diagnostics.cache_state'
```

Save:

- read-path summary json
- keeper continuity summary
- benchmark result
- keeper sample payload that shows current runtime fields

Do not promote a candidate unless baseline artifacts exist.

## Stage 1: Candidate Canary

Enable target production defaults in a small keeper cohort.

```bash
export MASC_KEEPER_ADAPTIVE_HEARTBEAT_ENABLED=1
export MASC_KEEPER_WORK_AS_HEARTBEAT=1
export MASC_KEEPER_SELF_PRESERVATION_ENABLED=1
MODES=http_only ./scripts/harness_mcp_readpath_revalidation.sh
./scripts/harness_keeper_continuity_validation.sh
MASC_URL=http://127.0.0.1:8935/mcp ./benchmarks/quick-bench.sh
```

Required checks:

- read-path harness passes twice consecutively
- keeper continuity harness passes
- global MCP/REST/SSE SLO remains inside `PERFORMANCE-SLO.md`
- operator-visible keeper surface shows:
  - `state`
  - `failure_reason`
  - `failure_streak_count` when `failure_reason=heartbeat_consecutive_failures`
  - `restart_count`
  - `last_successful_heartbeat_age_sec`
  - `dead_ttl_remaining_sec` when `state=Dead`
  - reconcile exclusion rooted in registry ownership (`is_registered`), not just `is_running=false`

Stop immediately if:

- any `Dead` keeper resurrects without operator action
- reconcile relaunches a registered keeper
- failed `Room.heartbeat_in_room` is followed by freshness skip
- unplanned self-preservation triggers

## Stage 2: Expanded Cohort Soak

Expand to a representative keeper cohort and repeat the same validation stack.

Commands:

```bash
MODES=http_only ./scripts/harness_mcp_readpath_revalidation.sh
./scripts/harness_keeper_continuity_validation.sh
MASC_URL=http://127.0.0.1:8935/mcp ./benchmarks/quick-bench.sh
```

Promotion conditions:

- Stage 1 checks remain green
- dedicated safety harness from `docs/design/adaptive-heartbeat-safety-harness-spec.md` is implemented and passes its Stage 2 scenario set
- no safety counter increases
- keepalive and presence-sync p95 do not regress more than 25% from Stage 0 baseline
- no operator intervention is needed to recover keeper ownership semantics

## Stage 3: Full Production

Proceed only when Stage 2 is clean.

Final verification set:

```bash
MODES=http_only ./scripts/harness_mcp_readpath_revalidation.sh
./scripts/harness_keeper_continuity_validation.sh
MASC_URL=http://127.0.0.1:8935/mcp ./benchmarks/quick-bench.sh
curl -fsS http://127.0.0.1:8935/health/ready
```

Full production sign-off requires:

- all safety counters remain zero
- global PERFORMANCE-SLO thresholds hold
- operator surface remains internally consistent
- rollback rehearsal already completed successfully

## Rollback Procedure

### Soft Rollback

Disable adaptive heartbeat behavior first:

```bash
export MASC_KEEPER_ADAPTIVE_HEARTBEAT_ENABLED=0
```

Restart or redeploy the service with that config, then rerun:

```bash
MODES=http_only ./scripts/harness_mcp_readpath_revalidation.sh
./scripts/harness_keeper_continuity_validation.sh
```

### Subsystem Rollback

If master disable is too coarse, disable subsystems separately:

```bash
export MASC_KEEPER_WORK_AS_HEARTBEAT=0
export MASC_KEEPER_SELF_PRESERVATION_ENABLED=0
```

### Hard Rollback

If recovery ownership remains unsafe after soft rollback, redeploy the previous release binary/config bundle.

## Operator Incident Guide

### `Crashed`

- confirm `failure_reason`
- if `failure_reason=heartbeat_consecutive_failures`, confirm `failure_streak_count`
- confirm restart_count is moving under supervisor ownership
- confirm reconcile is not relaunching the same registered keeper

### `Dead`

- confirm `dead_ttl_remaining_sec` is visible
- do not manually remove registry entry unless you also decide the keeper should re-enter scheduling
- after TTL cleanup, verify `meta.paused=true`
- if pause write fails, keep the tombstone registered and retry cleanup rather than unregistering first

### Self-Preservation Trigger

- treat as rollout stop by default
- inspect dominant `failure_reason`
- if operator intentionally induced the fault, annotate the event and continue only after the injected test ends
- otherwise rollback and investigate root cause

### Freshness/Heartbeat Drift

- if turn success is visible but room heartbeat is failing, verify `last_successful_heartbeat_age_sec` is aging
- if freshness skip still fires in that condition, rollback immediately

## Production Blockers

Do not continue rollout if any of the following occur:

- `masc_keeper_dead_resurrection_total > 0`
- `masc_keeper_reconcile_registered_launch_total > 0`
- `masc_keeper_false_freshness_skip_total > 0`
- `masc_keeper_unplanned_self_preservation_total > 0`
- read-path harness failure
- continuity harness failure
- PERFORMANCE-SLO breach linked to the candidate

## Notes

- This runbook intentionally reuses existing harnesses. It does not require a new heartbeat-only harness to start rollout.
- Dedicated injected-fault proof for later stages is specified in `docs/design/adaptive-heartbeat-safety-harness-spec.md`.
- gRPC and phi-accrual are explicitly out of scope for this production runbook. Follow-up production scope is documented in `docs/design/adaptive-heartbeat-grpc-and-phi-rollout-rfc.md`.
