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
- (this) — alerting rules + doc
