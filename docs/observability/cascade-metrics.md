---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/cascade/
  - lib/cascade_inference.ml
---

# Cascade Observability Metrics

How to read the cascade counters exposed by `/metrics` and the alerting rules that turn them into pages.

## Background

After the LT-* series (LT-1 through LT-7) every cycle of `Oas_worker_named.cycle_loop` produces observable state on **five surfaces**:

| Surface | Location | Use case |
|---------|----------|----------|
| 1. Snapshot JSON | `GET /api/v1/cascade/config`, `/cascade/client_capacity` | Current state polling (dashboard refresh) |
| 2. Ring buffer JSON | `GET /api/v1/cascade/client_capacity/history`, `/cascade/strategy_trace` | Recent-event audit (debugging) |
| 3. Dashboard cards | `dashboard/src/components/cascade-config-panel.ts` | Human operator view |
| 4. Prometheus counters | `GET /metrics` | Time-series + alerting (this doc) |
| 5. TLA+ specs | `specs/boundary/CascadeStrategy*.tla` | Formal correctness (offline) |

The Prometheus surface binds the runtime events to alerting rules; the TLA+ surface guarantees the state machine variant labels (`ordered`, `filtered_empty`, `exhausted`) stay consistent.

## Counters

### `masc_cascade_capacity_events_total`

| Label | Values |
|-------|--------|
| `kind` | `acquired`, `released`, `rejected_full` |
| `key_type` | `cli`, `ollama`, `other` |

Incremented from `Cascade_client_capacity_history.record`. One event per semaphore transition. `rejected_full` is the saturation signal — a caller could not acquire a slot and moved on to the next cascade candidate.

Label cardinality: `3 × 3 = 9 series`.

### `masc_cascade_strategy_decisions_total`

| Label | Values |
|-------|--------|
| `cascade` | cascade profile name (bounded by `cascade.json`, typically < 20) |
| `strategy` | `failover`, `capacity_aware`, `weighted_random`, `circuit_breaker_cycling`, `priority_tier`, `sticky`, `round_robin` |
| `kind` | `ordered`, `filtered_empty`, `exhausted` |

Incremented from `Cascade_strategy_trace.record`. One event per cycle iteration of `cycle_loop`. `exhausted` is the terminal variant — cascade gave up after `max_cycles` without a successful provider pick.

Label cardinality: `≈ 20 × 7 × 3 = 420 series` upper bound.

Both counter names and label tuples are shared with the JSON projection + dashboard card, so Grafana queries join cleanly with the same identifiers that operators see.

## Alerting Rules

`infrastructure/monitoring/cascade-alerts.yml` carries four rules. Load them into your Prometheus instance via:

```yaml
# prometheus.yml
rule_files:
  - /path/to/masc-mcp/infrastructure/monitoring/cascade-alerts.yml
```

| Alert | Severity | Fires when |
|-------|----------|------------|
| `OllamaCapacityRejectionSurge` | warning | ollama `rejected_full` > 0.5/s for 10m |
| `CliCapacityRejectionSurge` | warning | CLI provider `rejected_full` > 1/s for 10m |
| `CascadeExhaustionBurst` | **critical** | Any cascade `exhausted` > 0.1/s for 15m |
| `StrategyFilteredEmptyStorm` | warning | `filtered_empty` / total > 50% for 10m |
| `NoCapacityEventsInLastHour` | info | No capacity events for 1h (broken wiring vs idle) |

### Response playbooks

**OllamaCapacityRejectionSurge** — either `MASC_OLLAMA_MAX_CONCURRENT` is mis-sized or a runaway keeper is hammering the same model. Check `/api/v1/cascade/strategy_trace?cascade=<name>` to identify the saturating cascade. Either raise the semaphore (risks ollama thrash) or add a different provider to the cascade.

**CascadeExhaustionBurst** — every hit is a user-visible cascade failure. Inspect `/api/v1/cascade/health` (provider health) + `/api/v1/cascade/config` (candidate list). If all providers are cooling down, the underlying issue is upstream (API key, rate limit, network).

**StrategyFilteredEmptyStorm** — the strategy is rejecting >50% of cycles. Usually means `Capacity_aware` or `Circuit_breaker_cycling` is too restrictive, or cooldowns are saturated. Cross-reference with `OllamaCapacityRejectionSurge` to separate root cause.

## Grafana Dashboard

Pre-built dashboard at `infrastructure/monitoring/grafana-cascade-dashboard.json`.

Import via Grafana UI: **Dashboards → New → Import → Upload JSON file**. When prompted for a data source, pick your Prometheus instance; the dashboard uses `${DS_PROMETHEUS}` templating so it works across environments.

Dashboard UID: `masc-cascade`. Tag: `cascade`. 8 panels:

| # | Panel | Query highlight |
|---|-------|-----------------|
| 1 | Capacity events (kind × key_type) | `rate(...capacity_events_total[5m])` |
| 2 | Strategy decisions (kind) | colour-coded green/orange/red |
| 3 | Exhaustion (24h) | `increase(...{kind="exhausted"}[24h])` |
| 4 | Ollama rejections (1h) | ties to `OllamaCapacityRejectionSurge` alert |
| 5 | CLI rejections (1h) | ties to `CliCapacityRejectionSurge` alert |
| 6 | Filter-empty ratio (5m) | ties to `StrategyFilteredEmptyStorm` alert |
| 7 | Exhaustion by cascade | per-cascade breakdown |
| 8 | 24h decision table | sortable `(cascade, strategy, kind)` totals |

Refresh interval: 30s. Default time window: last 6h.

## SLOs

Recording rules + SLO-specific alerts at `infrastructure/monitoring/cascade-slo.yml`.

| SLO | Target | Window | Recording rule |
|-----|--------|--------|----------------|
| `cascade_ordered_ratio` | ≥ 0.99 | 28d | `masc:cascade_ordered_ratio:rate28d` |
| `cascade_exhaustion_daily` | ≤ 1 per cascade | 1h rolling | `masc:cascade_exhaustion_rate_daily:rate1h` |
| `ollama_rejection_hourly` | ≤ 10/h | 5m | `masc:ollama_rejection_rate_hourly:rate5m` |

### Ordered ratio SLO (99%)

Defines the happy path as an error-budget contract: at most 1% of cycles may hit `filtered_empty` or `exhausted`. The 28d burn-rate rule `masc:cascade_error_budget_burn:rate28d` expresses how fast the budget is being consumed:

- **< 1.0** — within budget
- **1.0 – 2.0** — degraded, investigate
- **> 2.0** — fast burn (`CascadeOrderedSLOFastBurn` alert fires at 1h window)

**Error budget policy**: when 28d burn rate exceeds 2×, freeze non-critical cascade changes (cascade.json edits, strategy swaps) until burn returns below 1×. This gate is manual — the rule only surfaces the number.

### Exhaustion SLO (≤ 1/day/cascade)

Per-cascade absolute ceiling. Exhaustion is always user-visible; one per day is already noise but accommodates transient upstream outages. `CascadeExhaustionSLOViolation` alert fires at > 1/day for 1h.

### Ollama rejection SLO (≤ 10/h)

Capacity saturation tolerance. Below 10/h the semaphore sizing is doing its job; above suggests either a runaway keeper or under-provisioned `MASC_OLLAMA_MAX_CONCURRENT`. `OllamaRejectionSLOViolation` alert at > 10/h for 30m.

### Why recording rules

Alerts + Grafana panels + ad-hoc queries all need the same ratios. Computing `(1 - ordered/total) / 0.01` three times is a drift hazard. Recording rules (`masc:...:rate...`) precompute once, everyone reads the same number.

## Formal correctness link

The `kind` label values are not ad-hoc strings — they mirror the `event_kind` variant in `lib/cascade/cascade_strategy_trace.mli`:

```ocaml
type event_kind = Ordered | Filtered_empty | Exhausted
```

Phase B TLA+ spec (`specs/boundary/CascadeStrategyStateful.tla`, PR #7632) models the same state machine with `Ordered` / `FilteredEmpty` / `Exhausted` transitions. Any spec change that adds a variant **must** update:

1. The OCaml `event_kind` type + `kind_to_string` serialiser.
2. The `.mli` docstring listing kinds.
3. The alerting rules in this directory (new thresholds if the variant is operationally significant).
4. The dashboard card legend (`verification-specs-panel.ts` classifier).

This is the spec → code → dashboard → metric consistency contract.

## Related PRs

- #7630 — Phase D client capacity history (ring buffer, JSON)
- #7632 — TLA+ Phase B Sticky/RR spec
- #7637 — TLA+ spec index dashboard
- #7643 — Strategy decision trace (ring buffer, JSON)
- #7645 — `masc_cascade_capacity_events_total` counter
- #7649 — `masc_cascade_strategy_decisions_total` counter
- #7679 — SLO card (in-process burn-rate computation)
- (LT-13) — `masc_keeper_invariant_violations_total` counter + alerts

---

## `masc_keeper_invariant_violations_total` (LT-13)

| Label       | Values                                                                             |
| ----------- | ---------------------------------------------------------------------------------- |
| `keeper`    | Keeper name (bounded by keepers registered on host, typically < 50)                |
| `invariant` | `PhaseTurnAlignment`, `NoCascadeBeforeMeasurement`, `CompactionAtomicity`, `EventPriorityMonotone` |

Incremented from `Keeper_composite_observer.bump_invariant_violations`, invoked by `observe` on every snapshot. One counter tick **per violated invariant per snapshot**. A sustained rate means the FSM composition is wedged in an inconsistent cross-axis state.

Label cardinality: `keepers × 4` (≤ 200 series in practice).

### PromQL patterns

```promql
# Fleet-wide violation burst (5-minute window)
sum by (invariant) (increase(masc_keeper_invariant_violations_total[5m]))

# Which keeper is offending for a specific invariant
topk(5, rate(masc_keeper_invariant_violations_total
              {invariant="PhaseTurnAlignment"}[5m]))

# Invariant health SLO (what fraction of snapshots satisfy all 4?)
# Requires pairing with a snapshots_total counter in a follow-up; out of
# scope for LT-13.
```

### Spec↔code↔counter contract

Any renaming of the invariant constants must land in all **6 places** in the same PR — see `docs/observability/fsm-spec-code-drift.md` §4. Specifically:

1. TLA+ invariant predicate in `specs/keeper-state-machine/KeeperCompositeLifecycle.tla`.
2. OCaml `invariant_key` variant in `keeper_composite_observer.mli`.
3. `invariant_key_to_string` (the Prometheus label source).
4. `invariants_check` record field name (the OCaml result).
5. Alert rule in `infrastructure/monitoring/cascade-alerts.yml`.
6. Grafana panel (landing in LT-13b — follow-up).

### Why one tick per snapshot instead of edge-triggered?

A violated invariant that *persists* across multiple snapshots is a stronger signal than one that flips once — `rate()`/`increase()` reflect the persistence directly. Edge-triggering would require a prior-state cache on the observer, which conflicts with the observer's pure-projection contract (`keeper_composite_observer.mli:1-20`).
