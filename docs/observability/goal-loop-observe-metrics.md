# GOAL LOOP Observe Metrics

Status: exporter contract
Last verified: 2026-05-06

This document pins the GOAL LOOP Observe phase to repo-owned telemetry
artefacts. The runtime may expose these metrics directly or bridge them
from parsed logs, but the names, thresholds, and dashboard coverage are
now contract checked.

## Artefacts

- `infrastructure/monitoring/goal-loop-observe-metrics.contract.json`
  is the machine-readable source of required Observe signals.
- `infrastructure/monitoring/goal-loop-observe-alerts.yml` is the
  Prometheus alert rule file.
- `infrastructure/monitoring/grafana-goal-loop-observe-dashboard.json`
  is the Grafana dashboard.
- `scripts/validate_goal_loop_observe_metrics.py` verifies that every
  required signal appears in alerts and dashboard queries.

## Required Signals

| Signal | Metric | Alert |
|--------|--------|-------|
| keeper turn success rate | `masc_keeper_turn_completed_total`, `masc_keeper_turn_scheduled_total` | `GoalLoopKeeperTurnSuccessRateCritical` |
| keeper semaphore wait p99 | `masc_keeper_semaphore_wait_seconds_bucket` | `GoalLoopKeeperSemaphoreWaitP99Critical` |
| starvation rate | `masc_keeper_semaphore_wait_timeout_total`, `masc_keeper_turn_scheduled_total` | `GoalLoopKeeperStarvationRateCritical` |
| keeper alive-but-stuck | `masc_keeper_alive_but_stuck_seconds`, `masc_keeper_alive_but_stuck_threshold_seconds` | `GoalLoopKeeperAliveButStuckCritical` |
| keeper zombie loop | `masc_keeper_zombie_loop_detected_total` | `GoalLoopKeeperZombieLoopCritical` |
| provider health probe skipped | `masc_provider_health_probe_skipped_total` | `GoalLoopProviderHealthProbeSkippedWarning` |
| provider actual health status | `masc_provider_actual_health_status` | `GoalLoopProviderActualHealthUnhealthyCritical` |
| pricing catalog miss | `masc_pricing_catalog_miss_total` | `GoalLoopPricingCatalogMissCritical` |
| dashboard all-zero metrics | `masc_dashboard_metric_all_zeros` | `GoalLoopDashboardMetricAllZerosWarning` |
| dashboard snapshot latency | `masc_dashboard_snapshot_latency_seconds_bucket` | `GoalLoopDashboardSnapshotLatencyP99Warning` |
| goal attainment | `masc_goal_attainment_pct`, `masc_goal_attainment_measured` | `GoalLoopGoalAttainmentUnmeasuredOrInvalidWarning` |
| memory usage | `masc_memory_usage_bytes` | `GoalLoopMemoryUsageInvalidWarning` |
| config unknown keys ignored | `masc_config_unknown_keys_ignored_total` | `GoalLoopConfigUnknownKeysIgnoredWarning` |
| credential archived by starvation | `masc_config_credential_archived_starvation_total` | `GoalLoopCredentialArchivedStarvationCritical` |
| governance judge unparseable | `masc_governance_judge_unparseable_total` | `GoalLoopGovernanceJudgeUnparseableWarning` |
| governance lenient JSON fallback | `masc_governance_lenient_json_fallback_hit_total` | `GoalLoopGovernanceLenientJsonFallbackWarning` |
| persistence UTF-8 repair | `masc_persistence_utf8_repair_total` | `GoalLoopPersistenceUtf8RepairCritical` |
| write_meta CAS retry | `masc_write_meta_cas_retry_total` | `GoalLoopWriteMetaCasRetryWarning` |

## Validation

Run the contract validator from the repo root:

```sh
python3 scripts/validate_goal_loop_observe_metrics.py \
  infrastructure/monitoring/goal-loop-observe-metrics.contract.json \
  --alerts-yml infrastructure/monitoring/goal-loop-observe-alerts.yml \
  --dashboard-json infrastructure/monitoring/grafana-goal-loop-observe-dashboard.json \
  --require-complete \
  --format text
```

Expected result:

```text
GOAL LOOP Observe Metrics Contract: PASS
checked_signals: 18
passing_signals: 18
failing_signals: 0
```

The script is intentionally stdlib-only. CI can run it without installing
YAML tooling because it checks explicit alert names, metric names, and
threshold fragments from the contract.

Cloud and subprocess-CLI providers do not support an auth-free bootstrap
health probe. Catalog validation reports those candidates as
`not_applicable` and keeps `masc_provider_actual_health_status` at `0`
(`unknown`) without incrementing
`masc_provider_health_probe_skipped_total`. The skipped counter is reserved
for providers where a probe was expected but could not run.

## Apply

Prometheus deployments should include
`infrastructure/monitoring/goal-loop-observe-alerts.yml` in their
`rule_files` glob. Grafana imports
`infrastructure/monitoring/grafana-goal-loop-observe-dashboard.json`
through the normal dashboard provisioning path or File -> Import.

## Exporter Contract

The contract uses bounded labels from the prompt:

- `keeper_name`
- `cascade_profile`
- `provider_name`
- `profile_name`
- `model_id`
- `file_path`
- `goal_id`

Counters should increment on the exact failure event. Gauges should hold
the current runtime state. Histograms must expose Prometheus `_bucket`
series so the p99 rules can use `histogram_quantile`.
