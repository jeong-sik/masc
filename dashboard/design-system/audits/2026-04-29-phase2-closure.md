# Phase 2 Implementation — closure (2026-04-29)

This note closes the Phase 2 (G/C/O/K/I plane) implementation track. It
consolidates four prior audits + the Phase F-Mid + Phase B-I0-B
shipping waves into a single status matrix, and points to the backend
RFC issues that own the remainder of the work.

## What "closure" means here

The original plan (`/Users/dancer/me/planning/claude-plans/20m-me-workspace-yousleepwhen-masc-mcp-h-curious-dusk.md`)
divided Phase 2 work into Phases C / D / E / F. Direct verification +
follow-up audits showed that the original "15 zones with zero production
surface" classification was inflated by name-grep mismatches. After
reclassification, the actual frontend-only work was small enough to be
finished in a single Mid wave (Phase F), and the rest is gated on
backend.

This file is the SSOT for "what's actually done" and "what's filed as
backend work" so future contributors don't re-evaluate the same zones
from scratch.

## Source audits

| Audit | Scope |
|-------|-------|
| `2026-04-29-phase2-implementation-gap.md` (#11523) | 6 partial-impl zones (G1/G2/O1/O3/K1/K4) |
| `2026-04-29-c1-board-zone-audit.md` (#11552) | C1 reclassification (covered) |
| `2026-04-29-remaining-zones-audit.md` (#11557) | K3/G3/C2/C3/G4/G5 + backend-blocked split |
| `2026-04-29-phase-b-i0-backbone.md` (#11560) | I0-A/B/C backbone status |
| `2026-04-29-o4-cost-latency-availability.md` (this PR) | O4 backend payload check |

## Status matrix — Phase 2 zones

| Zone | Spec source | Status | Evidence |
|------|-------------|--------|----------|
| **G1-A Horizon track** | `cb-group-d.jsx` | ✅ shipped | F-G1 #11533 (derived horizon progress) |
| **G1-B Metric tree** | `cb-group-d.jsx` | ✅ shipped | F-G1b #11536 (metric + target_value on tree row) |
| **G1-C Snapshot diff** | `cb-group-d.jsx` | 🔴 backend | issue #11573 (`goal_snapshots` + product call) |
| **G2-A Backlog** | `cb-group-d.jsx` | ✅ shipped (alternate kanban; flat-table optional) | `kanban-components.ts:TaskBacklog` |
| **G2-B Stale-claim alert** | `cb-group-d.jsx` | ✅ shipped | F-G2 #11534 |
| **G2-C Per-keeper task wall** | `cb-group-d.jsx` | ✅ shipped | F-G2 #11534 |
| **G3 Accountability (Recoverable + Fatal)** | `cb-group-g.jsx` | ✅ covered | PR #11543 (`error-boundary.ts` severity prop) |
| **C1 Board Zone** | `cb-group-c.jsx` | ✅ covered | `memory.ts` (audit #11552) |
| **C2 Messages** | `cb-group-e.jsx` | 🔴 backend partial | issue #11575 (`/api/v1/rooms` + mention inbox) |
| **C3 Composer v2** | `cb-group-e.jsx` | 🟡 use-site-blocked | issue #11576 (depends on #11575) |
| **O1 Cascade Inspector** | `cb-group-f.jsx` | 🔴 backend (Large) | issue #11574 (per-run hop trace API) |
| **O2 Audit Ledger** | `cb-group-f.jsx` | 🔴 backend (High) | issue #11569 (`/api/v1/audit`) |
| **O3-A Dashboard** | `cb-group-f.jsx` | ✅ shipped | `safe-autonomy.ts:SafeAutonomyPanel` |
| **O3-B ByKeeper** | `cb-group-f.jsx` | ✅ shipped (merged into KeeperCard) | `safe-autonomy.ts:KeeperCard` |
| **O3-C Trend** | `cb-group-f.jsx` | 🔴 backend | issue #11570 (`SafeAutonomyData.history[]`) |
| **O4 Cost & Latency** | `cb-group-f.jsx` | 🔴 backend | issue #11571 (aggregator endpoint; verified absent) |
| **O5 Heuristic + Stress** | `cb-group-f.jsx` | 🔴 backend | issue #11572 (`heuristics` + `agent_stress`) |
| **K1-A BDI panel** | `cb-group-h.jsx` | ✅ shipped | F-K1a #11526 (BdiSection extract) |
| **K1-B ToolAccess** | `cb-group-h.jsx` | ✅ shipped | F-K1c #11538 (read-only summary) |
| **K1-C TokenStats (cross-keeper)** | `cb-group-h.jsx` | ✅ shipped | F-K1b #11532 |
| **K2 Decisions/Memory** | `cb-group-h.jsx` | 🔴 backend | issue #11568 (`decisions.jsonl` + `memory.jsonl`) |
| **K3 Institution Episodes** | `cb-group-h.jsx` | ✅ covered | `memory-subsystems.ts:EpisodeCard` (audit #11557) |
| **K4 Autoresearch** | `cb-group-h.jsx` | ✅ deprecated | preview spec deprecated #11524 (production = self-improvement loop, intentionally different model) |
| **I0-A Branch selector** | `cb-group-i.jsx` | 🔴 backend | issue #11577 (`/api/v1/branches`) |
| **I0-B Keeper multi-select** | `cb-group-i.jsx` | ✅ shipped | #11560 (cross-zone filter signal + TokenStats use-site) |
| **I0-C Operator nudge log** | `cb-group-i.jsx` | 🔴 backend | issue #11578 (compose exists; log feed missing) |

## Phase status (original plan → actual)

| Original plan phase | Actual outcome |
|---------------------|----------------|
| **Phase A — Audit** | 1 PR (#11523) + 3 follow-up audits (#11552 / #11557 / Phase B backbone). Audit work was the bulk of "implementation"; classification corrections reduced rework. |
| **Phase B — I0 Foundation** | 1 of 3 shipped (I0-B #11560). I0-A and I0-C → backend issues (#11577, #11578). |
| **Phase C — Quick wins (K2/K3/C2/O2)** | K3 already covered; K2/O2/C2 → backend issues. **0 implementation PRs**, plan absorbed by audit reclassification. |
| **Phase D — Comms (C1/C3/G3)** | C1 + G3 already covered; C3 use-site-blocked. **0 implementation PRs**. |
| **Phase E — Observability (O4/O5)** | Both backend-blocked after Step 1 verification. **0 implementation PRs**, 2 backend issues. |
| **Phase F — Reconciliation** | 6 PRs shipped (#11526 / #11532 / #11533 / #11534 / #11536 / #11538). G1-C / O1 → backend issues. |

## Shipped PR index (Phase 2 work)

| PR | Subject |
|----|---------|
| #11523 | Phase A audit |
| #11524 | K4 autoresearch deprecation |
| #11526 | F-K1a `BdiSection` extract |
| #11532 | F-K1b cross-keeper TokenStats |
| #11533 | F-G1 derived horizon progress |
| #11534 | F-G2 stale alert + per-keeper wall |
| #11536 | F-G1b metric + target_value on GoalTree |
| #11538 | F-K1c read-only ToolAccess summary |
| #11543 | G3 ErrorBoundary severity (Recoverable + Fatal) |
| #11552 | C1 reclassification audit |
| #11557 | Remaining zones reclassification audit |
| #11560 | I0-B keeper multi-select + cross-zone filter signal |
| (this PR) | Phase 2 closure + O4 availability check |

## Backend RFC issues filed (this closure)

| Issue | Zone | Effort |
|-------|------|--------|
| #11568 | K2 Decisions/Memory | Mid |
| #11569 | O2 Audit Ledger | High |
| #11570 | O3 Trend (history[]) | Low |
| #11571 | O4 Cost & Latency aggregator | Mid |
| #11572 | O5 Heuristic + Stress | Mid |
| #11573 | G1-C Snapshot diff (+ product call) | Mid |
| #11574 | O1 Cascade Inspector (Large) | High |
| #11575 | C2 Messages rooms API | Mid |
| #11576 | C3 Composer v2 (use-site on #11575) | Low post-#11575 |
| #11577 | I0-A Branch selector | Mid |
| #11578 | I0-C Operator nudge log | Mid |

All issues use labels `backend-rfc` + `phase-2` and follow the same body
template (spec excerpt / required data shape / production status /
effort / frontend PR sequence post-backend / cross-link).

## Out of scope (this closure)

- **E1-E5 Code IDE plane**: user-deferred multi-quarter RFC, separate plan.
- **G4 Pagination / G5 Breadcrumb shared primitives**: optional, no
  guaranteed use site beyond board "show more" (per audit #11557). Open
  if needed; not tracked here.
- **DS-Drift Phase 2 token consolidation** (variables.css absorption,
  `--paper-*` tokens, breakpoint tokens): tracked separately from this
  closure — see plan archive section.

## Net frontend remaining work after this PR

**Zero**, until at least one of issues #11568-#11578 lands on the
backend side. Once a backend issue closes, its frontend PR sequence
(documented inside the issue body) becomes the next cycle's spawn.
