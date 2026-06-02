# Dashboard Observability Audit — Phase 2 (per-file refinement)

**Date**: 2026-04-30
**Scope**: `lib/dashboard/*.ml` (40 files)
**Pattern**: 4-phase audit (`docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md`)
**Phase 1**: PR #12202 (surface count + provisional taxonomy)

## 1. Per-file classification

Each `lib/dashboard/*.ml` file mapped to exactly one class:

| Class | File | Rationale |
|---|---|---|
| C1 | `dashboard_http_autoresearch.ml` | HTTP autoresearch endpoint (loop list / detail) |
| C1 | `dashboard_http_helpers.ml` | Shared HTTP env-parse + JSON utilities |
| C1 | `dashboard_http_monitoring.ml` | HTTP monitoring endpoint (tool health, board, goals) |
| C2 | `dashboard_goals.ml` | Goal tree decision logic with verdict patterns |
| C2 | `dashboard_governance.ml` | Live judge status surface, verdict decisions |
| C2 | `dashboard_operator_judge.ml` | Operator judge + verdict logic |
| C2 | `dashboard_verification.ml` | Verification projection with verdict/decision logic |
| C3 | `dashboard_agent_relations.ml` | GraphQL agent-relations proxy (read-side) |
| C3 | `dashboard_attention.ml` | Read-side actionable item collector |
| C3 | `dashboard_attribution.ml` | Attribution tracking — read-side forwarder |
| C3 | `dashboard_eval_feed.ml` | Read-only OAS eval verdict consumer |
| C3 | `dashboard_execution_fixture.ml` | Execution fixture helper (read-side) |
| C3 | `dashboard_execution_sessions.ml` | Session seed building (read-side) |
| C3 | `dashboard_feature_health.ml` | Feature flag health read model |
| C3 | `dashboard_harness_health.ml` | Lab safety harness read model (passive status) |
| C3 | `dashboard_labels.ml` | Pure translation: raw states → operators |
| C3 | `dashboard_oas_bridge.ml` | OAS boundary proxy (read-side) |
| C3 | `dashboard_projection_cache.ml` | Shared projection cache wrapper |
| C3 | `dashboard_safe_autonomy.ml` | Safe autonomy read model |
| C3 | `dashboard_surface_readiness.ml` | Surface-readiness status tracking |
| C4 | `briefing_compactors.ml` | Compact raw JSON → briefing form |
| C4 | `briefing_gaps.ml` | Metadata gap detection for mission briefing |
| C4 | `briefing_json_helpers.ml` | JSON extract + normalization for briefing |
| C4 | `briefing_sections.ml` | Section builders for mission briefing |
| C4 | `dashboard_execution_builders.ml` | Keeper lifecycle phase builder |
| C4 | `dashboard_execution_helpers.ml` | Tone ADT + execution helpers for briefing |
| C4 | `dashboard_execution.ml` | Execution projection layer (32 brief_/render_ patterns) |
| C4 | `dashboard_governance_metrics.ml` | Aggregate tool-rejection counts (projection) |
| C4 | `dashboard_http_keeper_detail.ml` | Metric-window computation (projection helper) |
| C4 | `dashboard_http_keeper_metrics.ml` | Keeper metric types + 24h bucket construction |
| C4 | `dashboard_http_keeper.ml` | Keeper dashboard JSON renderer (briefing layer) |
| C4 | `dashboard_http_tool_quality.ml` | Tool quality aggregate projection |
| C4 | `dashboard_mission_agents.ml` | Agent brief construction + architecture |
| C4 | `dashboard_mission_assembly.ml` | Keeper briefs + operation context assembly |
| C4 | `dashboard_mission_briefing.ml` | Mission briefing cache + delivery + public JSON |
| C4 | `dashboard_mission.ml` | Mission projection (32 render_/project_ patterns) |
| C5 | `dashboard_cache.ml` | Prometheus counters (cache_hits_total, cache_misses_total) |
| C5 | `dashboard_governance_judge.ml` | Prometheus counters + judge logic |
| OTHER | `judge_diagnostics.ml` | Diagnostic helper — no clean class fit |
| OTHER | `judge_json_recovery.ml` | JSON recovery helper — no clean class fit |

## 2. Summary

| Class | Phase 1 estimate | Phase 2 actual | Δ |
|---|---|---|---|
| C1 (HTTP handlers) | ~10 | **3** | −7 |
| C2 (Judges/deciders) | ~9 | **4** | −5 |
| C3 (Read-side wrappers) | ~5 | **14** | +9 |
| C4 (Briefing/projection) | ~8 | **17** | +9 |
| C5 (Instrumented) | 2 | **2** | 0 |
| OTHER | — | 2 | +2 |
| **Total** | 40 | 40 | — |

## 3. Phase 1 → Phase 2 deltas (conservative-bias self-correcting)

The 4-phase pattern doc (PR #12193) predicts that Phase 1 will over-classify candidates and Phase 2 will narrow them. This audit confirms that property:

- **C1 (HTTP) over-estimated by 3.3×**: Phase 1 grepped `dashboard_http_*` filenames (10 hits) but most of those route handlers are projection layers that build JSON for someone else's HTTP dispatch. Only 3 actually own a handler entry point.
- **C2 (Judges) over-estimated by 2.25×**: Phase 1 inferred from `*_judge|*_decider` patterns. Phase 2 reveals only 4 hold real verdict logic; the rest are projections of other judges.
- **C3 + C4 under-estimated by ~3×**: combined briefing + read-side surface is the dominant population (78% of files). Dashboard is largely a **projection-and-read layer**, not a decision layer.

Why this matters for Phase 3 prioritization:
- The high-severity C1 bucket is much smaller than feared — only 3 HTTP handlers need request_total / latency / error counters.
- The "judge" instrumentation pattern from `dashboard_governance_judge.ml` (C5) generalizes naturally to the 4 real C2 modules.
- C3/C4 instrumentation has lower marginal value — read-side wrappers should not emit metrics (the data source should), and projection layers are mostly pure functions of upstream state.

## 4. Phase 3 prioritization (proposal — fixes deferred to follow-up PRs)

**Tier P1 — high signal, small surface (C1 + C2 = 7 files)**:
- 3 HTTP handlers → request_total + request_duration_seconds histogram + request_errors_total
- 4 judges → verdict_total counter labeled by verdict outcome (mirror governance_judge pattern)

**Tier P2 — instrumented modules (C5 = 2 files, baseline)**:
- Already covered. Use as reference patterns for Tier P1 PRs.

**Tier P3 — deferred / low priority**:
- C3 (14 files): instrument the **data source** (GraphQL, OAS bridge), not the read-side wrapper. False instrumentation here would inflate cardinality without adding signal.
- C4 (17 files): pure projection. Skip unless a specific projection produces user-visible latency.
- OTHER (2 files): inspect case-by-case in Phase 3.

## 5. Updated ratchet recommendation (refines PR #12202)

Phase 1 proposed:
- `dashboard_metric_emitter_files` (INC, floor 2)
- `dashboard_http_handlers_without_metrics` (DEC, floor ~10)

Phase 2 refines to:
- `dashboard_metric_emitter_files` (INC, floor **2**) — unchanged
- `dashboard_http_handlers_without_metrics` (DEC, floor **3**) — narrowed from ~10 to 3 (correct surface)
- `dashboard_judges_without_metrics` (DEC, floor **3**) — new metric (4 C2 minus 1 C5 already-instrumented governance_judge = 3)

These three together cap regression and make Phase 3 progress visible.

## 6. References

- PR #12202 — Phase 1 (parent)
- PR #12193 — 4-phase audit pattern (codification)
- PR #12143 — TLA+ PPX adoption audit Phase 2 (sibling pattern)
- `lib/dashboard/dashboard_cache.ml`, `lib/dashboard/dashboard_governance_judge.ml` — current C5 anchors
- `docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04-PHASE2.md` — Phase 2 prior art (C1–C4 taxonomy)

## 7. Audit pattern validation

Second consecutive audit chain to surface conservative-bias self-correction:
1. OAS boundary audit (#12089→#12100→#12112): Phase 1 ~50 violations → Phase 2 ~12 (4× narrowing).
2. TLA specs gap audit (#12131→#12132→#12137): Phase 1 21 tautologies → Phase 2 0 (full pivot).
3. **Dashboard observability audit (this chain)**: Phase 1 over-estimates C1+C2 (~19) → Phase 2 actual 7 (2.7× narrowing).

The pattern doc's claim that "Phase 1 mis-classification is feature, not bug" continues to hold across three independent domains.
