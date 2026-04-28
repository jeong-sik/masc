# Remaining Phase 2 zones — reconciliation audit (2026-04-29)

Second follow-up to `2026-04-29-phase2-implementation-gap.md`, after the
C1 audit revealed that the original "15 zones with zero production
surface" classification was based on grepping spec component names
rather than production naming. This audit re-evaluates the remaining
zones and splits them into:

- **Production already covers spec** (no implementation work needed)
- **Backend dependency confirmed** (Phase F scope blocked)
- **Use-site missing** (frontend can't be built without an upstream zone)

## Methodology

For each zone:
1. Search production for the spec's data shape (not its component name)
2. If a production component is found, compare per-variant to spec
3. If no component is found, look for the underlying data source
4. If no data source, classify as **backend-blocked**

## Summary

| Zone | Original audit class | Reclassified | Reason |
|------|----------------------|--------------|--------|
| C1 Board Zone | zero-surface | full coverage | `memory.ts` (separate audit #11552) |
| **K3 Institution Episodes** | zero-surface | **full coverage** | `memory-subsystems.ts:EpisodeCard` + `MemorySubsystemsEpisode` data already match all spec fields |
| **C2 Messages** | zero-surface | **partial coverage** | `keeper-chat-panel.ts` covers chat surface; mention inbox + state-block message variants are not separate UI but data exists |
| **K2 Decisions/Memory** | zero-surface | backend-blocked | no `decisions.jsonl` / `memory.jsonl` cross-keeper API; only per-keeper `Keeper.last_speech_act` |
| **O2 Audit Ledger** | zero-surface | backend-blocked | `/api/v1/audit` endpoint absent; closest is `cascade/strategy_trace` which is a different schema |
| **O3 Trend variant** | partial (Phase F-C) | backend-blocked | `SafeAutonomyData.history[]` field absent (verified in `safe-autonomy.ts:80`) |
| **O5 Heuristic + Stress** | zero-surface | backend-blocked | no `heuristics.jsonl` / `agent_stress.jsonl` API in `dashboard/src/api/` |
| **G1-C Snapshot diff** | partial | backend-blocked | `goal_snapshots` API absent; product decision required |
| **O1 Cascade Inspector** | partial | Large + backend-partial | `StrategyTraceTable` rows exist but spec's per-run hop card model needs new endpoint shape |
| **C3 Composer v2** | zero-surface | use-site-missing | composer requires C2 chat surface to be a zone; current chat lives inside per-keeper detail |
| **G3 Error boundary** | zero-surface | full coverage | reconciled in #11543 (severity prop + reload) |
| **G4 Pagination / G5 Breadcrumb** | not in original audit | partial coverage | `dashboard-shell.ts` already renders breadcrumb trail; pagination is per-feature inline (board, etc.) |

**Net effect**: of the 15 zones the original audit listed as missing,
**3 are actually full coverage** (C1, K3, G3 already reconciled),
**1 is partial coverage** (C2),
**6 are genuinely backend-blocked** (K2, O2, O3, O5, G1-C, O1),
**1 is use-site-missing** (C3),
**2 are partial UI primitives with existing equivalents** (G4, G5).
**E1-E5** remain user-deferred.

## Detail — K3 Institution Episodes

**Spec** (`cb-group-h.jsx:216-290`): `EpisodeCards` + `EpisodeLearnings`. Episode card shape: `{id, ts, participants[], outcome, summary, learnings[]}`.

**Production** (`memory-subsystems.ts:409`): `EpisodeCard({ ep })` consumes `MemorySubsystemsEpisode` (`api/dashboard.ts:2333`):
```
{ id, timestamp, participants[], event_type, summary, outcome, learnings[], context{} }
```

Every spec field has a production equivalent (`ts → timestamp`). Production exceeds spec (`event_type` + `context` extras). Data source: `/api/v1/dashboard/memory-subsystems` (`dashboard.ts:2381`). Mounted at `monitoring?section=memory-subsystems`.

**No reconciliation PR needed for K3.**

## Detail — C2 Messages

**Spec** (`cb-group-e.jsx:157-313`): three variants — Room timeline, Mention inbox, State-block message focus.

**Production**: `dashboard/src/components/keeper-chat-panel.ts` is a per-keeper chat surface (not a room timeline). `dashboard/src/components/chat/primitives.ts` provides chat primitives. `MASC_broadcast` exists via `callMcpTool('masc_broadcast', ...)` in `actions.ts:24`.

**Gap** — partial:
- C2-A Room timeline: missing as a zone (chat is per-keeper, not per-room)
- C2-B Mention inbox: missing entirely
- C2-C State-block message: missing as a structured-message form

The data plumbing is partly there (broadcast tool call works), but a "rooms" abstraction that would group messages cross-keeper is not surfaced. **Backend partial-blocked**: `masc_broadcast` exists for sending but no `/api/v1/rooms` for fan-out reading. Reconciliation requires either a room API or a synthesized stream-by-broadcast view.

## Detail — Backend-blocked zones (K2 / O2 / O3 / O5 / G1-C)

For each, the path was: search for the data type, the API endpoint, the SSE event type. None found:

- **K2** `decisions.jsonl` / `memory.jsonl` — no decision/memory stream API. `Keeper.last_speech_act` is the only per-keeper field, not a cross-keeper log.
- **O2** `audit.jsonl` — no `/api/v1/audit`. `cascade/strategy_trace` is a different (cascade-internal) audit, not the global event ledger the spec describes.
- **O3** `SafeAutonomyData.history[]` — verified absent in `safe-autonomy.ts:80`.
- **O5** `heuristics.jsonl` / `agent_stress.jsonl` — no matching API surface.
- **G1-C** `goal_snapshots` — no snapshot API.

Each requires backend work outside Phase F scope.

## Detail — C3 Composer v2 (use-site missing)

**Spec** (`cb-group-e.jsx:317-440`): Composer with broadcast / dm / state-block modes.

The composer would have to live inside a chat surface. Today's production chat surface is per-keeper (`keeper-chat-panel.ts`), not a multi-room board. Building the composer in isolation produces dead code; the room/board chat surface needs to exist first (= C2 unblocked).

## Detail — G4 Pagination / G5 Breadcrumb (partial primitives)

- **G5 Breadcrumb**: `dashboard-shell.ts:534-625` already derives and renders a navigation trail per current route. Spec's stand-alone Breadcrumb primitive is implicit in the shell.
- **G4 Pagination**: pagination patterns exist inline (board "show more", autoresearch cycles table, etc.) but no shared primitive. A shared `<Pagination>` component would be net positive but is opt-in: small, low-risk, but no guaranteed use site beyond board "show more".

These are not blockers; flagged as "could ship a shared primitive someday".

## Recommendation — outcome of this audit

Phase F (Reconciliation) backlog as it actually stands after this audit:

| Bucket | Zones |
|--------|-------|
| ✅ Already covered (close as no-op) | C1, K3, G3 |
| 🟡 Partial — frontend extension possible | C2 (reconciliation requires backend room API), G4/G5 (optional primitives) |
| 🔴 Backend-blocked | K2, O2, O3, O5, G1-C |
| 🔴 Large (multi-PR) | O1 Cascade Inspector |
| 🟡 Use-site missing | C3 (depends on C2) |
| ⏸ User-deferred | E1-E5, Phase B (I0 IDE Backbone) |

**Implication**: of the original audit's "15 zones with zero production surface" list, only the 6 backend-blocked zones plus C3 (use-site-missing) are actually open work. The other 8 are either covered or low-priority primitives.

Phase F is structurally **closer to done than it looked**. After Phase B (I0 IDE Backbone), the remaining frontend-only work is small (G4 Pagination + G5 Breadcrumb primitives at most); the other zones are gated on backend.
