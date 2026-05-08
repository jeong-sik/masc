# Monitoring artefacts

Prometheus / Grafana files that live alongside the masc-mcp source so deployments can apply them without a separate ops repo.

## Catalogue

| File | Domain | Kind | Companion doc |
|------|--------|------|---------------|
| `cascade-alerts.yml` | cascade | alerts | `docs/observability/cascade-metrics.md` |
| `cascade-slo.yml` | cascade | recording rules + SLO alerts | `docs/observability/cascade-metrics.md` |
| `grafana-cascade-dashboard.json` | cascade | Grafana dashboard | `docs/observability/cascade-metrics.md` |
| `grafana-goal-loop-observe-dashboard.json` | GOAL LOOP Observe | Grafana dashboard | `docs/observability/goal-loop-observe-metrics.md` |
| `grafana-keeper-turn-fsm-dashboard.json` | keeper turn FSM | Grafana dashboard | `docs/observability/keeper-turn-fsm-metrics.md` |
| `goal-loop-observe-alerts.yml` | GOAL LOOP Observe | alerts | `docs/observability/goal-loop-observe-metrics.md` |
| `goal-loop-observe-metrics.contract.json` | GOAL LOOP Observe | exporter contract | `docs/observability/goal-loop-observe-metrics.md` |
| `keeper-turn-fsm-alerts.yml` | keeper turn FSM | alerts | `docs/observability/keeper-turn-fsm-metrics.md` |
| `keeper-turn-fsm-slo.yml` | keeper turn FSM | recording rules | `docs/observability/keeper-turn-fsm-metrics.md` |
| `grafana-dashboard-surface-dashboard.json` | dashboard IA | Grafana dashboard | `docs/observability/dashboard-surface-metrics.md` |

## Domains

The two domains are **deliberately separate**.

### GOAL LOOP Observe

Tracks the Observe phase signals from the GOAL LOOP design: keeper
liveness, semaphore wait, provider health skips, pricing misses,
dashboard all-zero diagnostics, config drift, governance fallback, UTF-8
repair, and CAS retries. The exporter contract is
`goal-loop-observe-metrics.contract.json`; `scripts/validate_goal_loop_observe_metrics.py`
checks that the alert rules and Grafana dashboard cover every required
signal.

### Cascade

Tracks cascade-routing decisions inside `Keeper_turn_driver.cycle_loop`. Counters: `masc_cascade_strategy_decisions_total{cascade,strategy,kind}`, `masc_cascade_capacity_events_total{kind,key_type}`. State vocabulary: `ordered / filtered_empty / exhausted` (TLA+ `KeeperCascadeLifecycle`).

### Dashboard IA

Tracks dashboard surface and section opens to drive RFC-0048 IA Phase 2 deletion-threshold decisions. Counters: `dashboard_surface_open_total{surface}`, `dashboard_section_open_total{surface, section, redirected_from}`. The `redirected_from` label distinguishes direct opens from redirect-driven opens (legacy bookmarks) — only direct opens count toward RFC-0048 §4.4 hide/delete thresholds. Aggregate-only, no PII. Producer code: `lib/dashboard/dashboard_nav_event.ml`, `dashboard/src/lib/nav-telemetry.ts`. CLI consumer: `scripts/dashboard-ia-usage.sh`.

### Keeper turn FSM

Tracks the typed turn-state ADT inside `run_keeper_cycle`. Counter: `masc_keeper_turn_fsm_transitions_total{from,to,keeper}`. State vocabulary: 10 typed states with `failure_reason` / `cancel_reason` carriers (TLA+ `KeeperTurnFSM`).

`keeper-turn-fsm-alerts.yml` also carries the **fsm_guard violation** alerts (group `masc_keeper_fsm_guard`). Counter: `masc_fsm_guard_violation_total{action,stage}` — incremented when a `[@@fsm_guard "<expr>"]`-injected runtime assertion catches a TLA+ Next-set violation in counter mode (`MASC_FSM_GUARD_ASSERT=0`). Production default is assert mode (unset or `1`), where violations re-raise immediately and this counter stays at zero. The dashboard surfaces this counter in the bottom row of `grafana-keeper-turn-fsm-dashboard.json`.

The two domains overlap *only* at `cascade_routing` — when the keeper FSM enters cascade routing, the cascade subsystem takes over until a provider is selected (or exhausted). Both surfaces emit independently; an operator chasing a turn that died at cascade exhaustion sees:

- `masc_keeper_turn_fsm_transitions_total{to="failed:cascade_unavailable",keeper=...}` — keeper view
- `masc_cascade_strategy_decisions_total{kind="exhausted",cascade=...}` — cascade view

Both should fire for the same turn; if only one fires the runtime path skipped a layer.

## Apply

Prometheus picks up the alert / recording files via the standard rule_files glob; Grafana imports the JSON via File → Import. There's no apply script — deployments use whatever IaC they already run for the cascade rules.

## Companion code references

- `lib/prometheus.{ml,mli}` — counter + label declarations
- `lib/keeper/keeper_turn_fsm.{ml,mli}` — typed FSM ADT
- `lib/cascade/cascade_strategy_trace.ml` — cascade decision events
- `bin/masc_trace.ml` — per-turn timeline CLI (reads receipts + system_log + tool_calls)

## Adding a new artefact

1. Pick a domain (cascade / keeper-turn-fsm / new-domain). Don't mix domains in one file — each file maps to one companion doc.
2. Match the filename pattern: `<domain>-<kind>.{yml,json}`.
3. Update the catalogue table above.
4. Add a `## Counter` or `## Recording rule` section to the companion doc in `docs/observability/`.
5. If a new domain is being introduced, add a `### <Domain>` subsection to the **Domains** section above.

The catalogue + companion doc pairing is what keeps spec-code-drift audits tractable; see `docs/observability/fsm-spec-code-drift.md`.
