# Dashboard Observability Audit — 2026-04-30 (Phase 1)

> Status: Phase 1 / Survey. First-pass audit applying the 4-phase pattern from `docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md` (PR #12193) to a new domain.
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Tracks: First survey using the codified audit pattern

---

## 1. Purpose

The dashboard subsystem (`lib/dashboard/`) carries 40 `.ml` + 40 `.mli` files implementing the operator-facing HTTP/SSE/JSON surface. This audit measures **how many modules emit Prometheus metrics** (or any structured observability output beyond log lines).

Companion to:
- TLA+ specs gap audit (`docs/audit/TLA-SPECS-GAP-AUDIT-2026-04*.md`) — measures spec-side coverage
- TLA+ PPX adoption audit (`docs/audit/TLA-PPX-ADOPTION-AUDIT-2026-04.md`) — measures runtime PPX hookup
- This audit — measures runtime **metric emission** coverage

## 2. Method

```bash
# Module count
ls lib/dashboard/*.ml  | wc -l   # 40
ls lib/dashboard/*.mli | wc -l   # 40

# Metric emission grep (counter increment / register / Prometheus.* calls)
rg -l "Prometheus\.|metric_" lib/dashboard/

# False positives (data field "metric_fn", read-side wrappers)
rg "metric_fn|read_keeper_metric_records" lib/dashboard/
```

## 3. Findings

### 3.1 Metric emitter classification (per CLAUDE.md tropes — measure, don't claim)

| File | Class | Notes |
|---|---|---|
| `dashboard_cache.ml` | **emitter** | `Prometheus.inc_counter Prometheus.metric_cache_hits_total` / `_misses_total` with `cache:dashboard` label |
| `dashboard_governance_judge.ml` | **emitter** | `Prometheus.register_counter` + `inc_counter` for governance decisions |
| `dashboard_harness_health.ml` | reader | `read_keeper_metric_records` — consumes existing metric snapshots, doesn't emit |
| `dashboard_http_autoresearch.ml` | data field name | references `metric_fn` as a JSON field on autoresearch loops, no Prometheus calls |

**True emitters: 2 of 40 (5%)**.

### 3.2 Surface inventory by purpose (heuristic from filename)

| Subgroup | Files | Has metric? |
|---|---|---|
| `briefing_*` | 8 | 0/8 |
| `dashboard_http_*` | ~10 | 0/10 (autoresearch is a false-positive grep hit) |
| `dashboard_oas_*` | ~5 | 0/5 |
| `dashboard_cascade*`, `dashboard_governance_judge`, `dashboard_operator_judge` | ~10 | 1/10 (governance_judge) |
| `dashboard_cache`, `dashboard_harness_health`, `dashboard_attention`, `dashboard_safe_autonomy` | ~7 | 1/7 (cache) |

The HTTP route handlers (`dashboard_http_*`) are the largest unhooked subgroup. Each handler has natural metric candidates: request count, latency histogram, error counter.

## 4. Gap categorisation (Phase 2 candidates)

This is Phase 1; refinement deferred to Phase 2. Initial classification:

| Class | Count | Severity | Notes |
|---|---|---|---|
| **C1: HTTP route handler with no metrics** | ~10 | High | Each lacks request_total / latency_seconds / errors_total. Bounded work — 1 PR per handler family. |
| **C2: Judge / decider with no metrics** | ~9 | Medium | Operator/governance judges emit decisions but most don't increment counters. Reuse `register_counter` pattern from `dashboard_governance_judge`. |
| **C3: Read-side wrappers** | ~5 | N/A | `dashboard_harness_health` reads existing snapshots — instrumenting the *reader* is wrong direction; the data source should emit. |
| **C4: Briefing / projection layer** | ~8 | Low | Pure data transforms; observability candidate is upstream cache/store. |
| **C5: Already instrumented** | 2 | none | dashboard_cache, dashboard_governance_judge |

The audit's C1–C5 taxonomy is preliminary. Phase 2 will refine via per-file inspection (cf. Q-P0-3 Phase 2 §1).

## 5. Mapping to existing observability infrastructure

The Prometheus module exposes counters / histograms via `Prometheus.metric_*`. dashboard_cache uses `metric_cache_hits_total` / `_misses_total` — a precedent. Adopting metrics elsewhere in dashboard:

```ocaml
let route_metric_label = [("route", "/keepers"); ("method", "GET")]
Prometheus.inc_counter Prometheus.metric_dashboard_request_total
  ~labels:route_metric_label ()
```

Requires `Prometheus.metric_dashboard_request_total` to exist — likely **prereq invariant analogue**. Cf. Q-P0-2 Phase 3 prereq pattern: 1/3 of "needs prereq" are real (33% accuracy).

## 6. Why fixes are deferred (per audit pattern)

Phase 1 is docs-only. Each metric needs a domain-specific decision (counter vs histogram, label dimensions, cardinality bound). Writing metrics without that domain knowledge produces *fake* observability — high cardinality labels degrade the time series, miscounted resets break alert math.

Defer per-handler instrumentation to Phase 3, modelled on Q-P0-2 Phase 3 (8 RFC stubs, 1 cycle each).

## 7. Recommended ratchet (descriptive)

```bash
# Strict (eventual, after Phase 2 + Phase 3 baseline)
dashboard_metric_emitter_files: count of lib/dashboard/*.ml with
  at least one Prometheus.inc_counter / register_counter call
# Floor: 2 (current). Goal: monotonic increase.

# Descriptive
dashboard_http_handlers_without_metrics: count of dashboard_http_*.ml
  with zero Prometheus.* calls
# Floor: ~10 (current, estimate). Goal: monotonic decrease.
```

Same enforcement discipline as the OAS chain: defer hard-gating until ≥2 follow-up PRs land. Phase 4 deferral.

## 8. Phase plan

| Phase | Scope | Status |
|---|---|---|
| **1 (this PR)** | Survey + heuristic taxonomy | this PR |
| 2 | Per-file refinement of C1–C5 classification (full sweep) | next |
| 3 | Per-handler instrumentation PRs (fan-out) | after Phase 2 baseline |
| 4 | Ratchet wire-up (`scripts/dashboard-metrics-ratchet.sh` + CI step) | after ≥2 Phase 3 PRs land |

Mirrors the structure documented in `docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md`. First audit chain to **explicitly invoke** the codified pattern as a starting point.

## 9. References

- `docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md` (PR #12193) — pattern source
- `docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04*.md` — Q-P0-3 chain (4/4 MERGED)
- `docs/audit/TLA-SPECS-GAP-AUDIT-2026-04*.md` — Q-P0-2 chain (Phase 3 closure in #12188)
- `lib/prometheus.{ml,mli}` — metric registry
- `lib/dashboard/dashboard_cache.ml`, `lib/dashboard/dashboard_governance_judge.ml` — current 2 emitters

*Audit date: 2026-04-30 / Phase 1 of 4 / docs-only / first audit using codified 4-phase pattern*
