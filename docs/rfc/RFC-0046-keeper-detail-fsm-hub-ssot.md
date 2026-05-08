# RFC-0046 — Keeper Detail FSM Hub as SSOT

Status: Draft
Author: jeong-sik (with Claude Opus 4.7)
Date: 2026-05-08
Supersedes: —
Related: PR #14219, #14220 (dashboard cleanup precursors), KeeperCompositeLifecycle.tla

## 1. Problem

Keeper detail surface renders the same FSM state through **four parallel
paths**, none of them the canonical composite hub that already exists.

### 1.1 Concrete duplication map

| Surface | Source field(s) | Reads from |
|---|---|---|
| `keeper-detail-shell.ts:193` `KeeperPhaseAndStage` | `keeper.phase`, `keeper.pipeline_stage` | flat keeper signal |
| `keeper-detail.ts:1016` `PipelineStageBar` | `keeper.pipeline_stage` | flat keeper signal |
| `keeper-detail.ts:1018` `KeeperStateDiagramPanel` | `keeper.phase` | flat keeper signal |
| `keeper-detail.ts:1022` `KeeperMemoryTierPanel` | `keeper.phase` | flat keeper signal |
| `agents-unified.ts:156` `FsmHub` (NOT in detail) | `KeeperCompositeSnapshot` (6 axes) | composite endpoint |

The first four reach into the **flat keeper record** and pull two scalar
fields (`phase`, `pipeline_stage`). The fifth — already deployed at
`fsm-hub.ts` (1010 LoC) and `fsm-hub-types.ts` (`KeeperCompositeSnapshot`)
— consumes the same five sub-FSM projections that
`KeeperCompositeLifecycle.tla` declares as the joint observer:

| TLA projection | Snapshot field | Currently surfaced where |
|---|---|---|
| `ksm_phase` (KSM) | `snapshot.phase` | flat → 4 panels (above), composite → FsmHub |
| `ktc_turn_phase` (KTC) | `snapshot.turn_phase` | composite → FsmHub only |
| `kdp_decision` (KDP) | `snapshot.decision.stage` | composite → FsmHub only |
| `kcl_cascade_state` (KCL) | `snapshot.cascade.state` | composite → FsmHub only |
| `kmc_compaction` (KMC) | `snapshot.compaction.stage` | composite → FsmHub only |
| `circuit_breaker.state` | `snapshot.circuit_breaker.state` | composite → FsmHub only |

Result: an operator opening keeper detail sees **`phase` four times** but
**zero** of `turn_phase / decision / cascade / compaction / breaker`. To
get the full FSM picture they must back out to fleet view, find the
keeper, and use the FsmHub drill-down. Per-keeper analysis is the *exact*
flow that needs the composite, and it is the flow without it.

### 1.2 User-reported symptoms (PR #14219 / #14220 review)

> "TLA FSM 제대로 된 상태만 보여주면 되는 건데… SSOT 가 아니라 막
> 널부러져있음."

> "지금 위험한가? 음 ㅋㅋ 뭐 이런 번역이 있음? 스스로 돌고 있나? …"

The anthropomorphic Korean question subtitles (already removed in #14219)
were a symptom: with the composite snapshot **not surfaced**, panels
attempted to compensate by adding interpretive copy on top of partial
state. Removing the copy without fixing the underlying surface leaves
operators with even less signal than before.

## 2. Goals

1. Make the **FsmHub composite snapshot** the single SSOT for keeper FSM
   state on the detail surface.
2. Delete or downgrade the four parallel phase-only panels that
   duplicate one axis of the snapshot.
3. Preserve the diagrams (`KeeperStateDiagramPanel` for `phase`
   transition history, `KeeperMemoryTierPanel` for memory-tier visual)
   as **derived views fed from the snapshot**, not independent fetchers.
4. Zero new backend fields. Zero new RPCs. The composite endpoint
   already exists (`KeeperCompositeSnapshot`).

## 3. Non-goals

- No change to `KeeperCompositeLifecycle.tla` or any sub-FSM spec.
- No change to backend OCaml — this is dashboard-only re-wiring.
- No change to fleet-level FsmHub (`agents-unified.ts:156`).
- No new info architecture sections. Existing 6 sections
  (요약 / 대화 / 진단 / 정체성 / 설정 / 디버그) stay; 요약 section
  internals are reorganized.

## 4. Design

### 4.1 Surface change in 운영 상태 개요 section

Before (`keeper-detail.ts:1011-1093`):

```
KeeperRuntimeAlertStrip
KeeperDetailSection eyebrow="상태 개요" title="운영 상태 개요"
  PipelineStageBar          ← duplicates phase
  CollapsibleSection "Phase State Machine"
    KeeperStateDiagramPanel  ← reads keeper.phase directly
  CollapsibleSection "메모리 티어"
    KeeperMemoryTierPanel    ← reads keeper.phase directly
  KpiGrid                    ← stays (4 KPI sections, post-#14219)
  CtxCompositionPanel
  PromptTelemetryPanel
  InferenceTelemetryPanel
```

After:

```
KeeperRuntimeAlertStrip
KeeperDetailSection eyebrow="상태 개요" title="운영 상태 개요"
  FsmHub keeperName=${keeper.name} mode="detail"   ← NEW: single hub
                                                    showing 6 axes
  KpiGrid                                           ← unchanged
  CtxCompositionPanel
  PromptTelemetryPanel
  InferenceTelemetryPanel
```

`KeeperPhaseAndStage` in the page header (`keeper-detail-shell.ts:193`)
stays — it is the breadcrumb-level summary. The redundant
`PipelineStageBar` inside the section body goes.

`KeeperStateDiagramPanel` and `KeeperMemoryTierPanel` are **moved**
under FsmHub as expandable derived views (existing `<details>` /
collapsible pattern). Their inputs change from `currentPhase=
${keeper.phase}` to `snapshot=${fsmHub.snapshot}` so they read the same
SSOT FsmHub already consumes.

### 4.2 FsmHub `mode` prop

FsmHub is currently fleet-targeted. Add a `mode: 'fleet' | 'detail'`
prop (default `'fleet'` for back-compat). In `'detail'` mode:

- Skip the "select a keeper" affordance (the parent already pinned one).
- Render a more compact lane stack (vertical, 6 lanes, suited for the
  detail page width).
- Surface invariant violations inline with the keeper's
  `KeeperRuntimeAlertStrip` (avoid double-warning).

This is additive. No fleet-side regression.

### 4.3 Removed surfaces

| File | Action | Reason |
|---|---|---|
| `keeper-pipeline-stage.ts` (`PipelineStageBar`) | **Delete** if no other caller; otherwise leave for fleet | Single-axis duplicate of FsmHub `phase` lane |
| `keeper-state-diagram.ts` (`KeeperStateDiagramPanel`) | **Refactor** to take `snapshot` prop | Diagram still useful, source must be SSOT |
| `keeper-memory-tier-panel.ts` (`KeeperMemoryTierPanel`) | **Refactor** to take `snapshot` prop | Same |

Net LoC: estimated **−250 to −400** (PipelineStageBar deletion + prop
plumbing simplification). FsmHub adds ≤30 LoC for `mode='detail'`.

## 5. Migration plan

Single PR is acceptable; the dashboard already passes typecheck (baseline
fsm-hub-types-2026-05-05 errors aside). Splitting is fine if reviewer
prefers smaller diffs.

| Step | Files | Verification |
|---|---|---|
| 1 | `fsm-hub.ts` — add `mode` prop | unit test: `mode='detail'` skips selector |
| 2 | `keeper-state-diagram.ts`, `keeper-memory-tier-panel.ts` — accept `snapshot` prop, fall back to `currentPhase` for one cycle | existing tests stay green |
| 3 | `keeper-detail.ts` — replace `PipelineStageBar` + raw panel mounts with `<FsmHub mode="detail" />` and snapshot-fed children | `keeper-detail.test.ts` updated |
| 4 | Delete `keeper-pipeline-stage.ts` if grep shows no other caller | typecheck |
| 5 | Remove fallback prop on the two refactored panels | typecheck |

## 6. Risks

| Risk | Mitigation |
|---|---|
| FsmHub backend snapshot endpoint slower than flat keeper field | Already in production for fleet view; per-keeper detail load includes snapshot fetch in same WS frame today (see `dashboard-ws.ts`) |
| Diagram component coupling to flat field | Compatibility prop kept for one cycle (Step 2), removed in Step 5 |
| FsmHub detail mode feels too dense in narrow viewports | Vertical lane stack + compact KPI tiles already in design system; verify <520px breakpoint |
| Test churn | Snapshot-prop refactor is mechanical; tests already use `KeeperCompositeSnapshot` fixtures elsewhere |

## 7. Out of scope (future RFCs)

- Composite-snapshot-driven *event timeline* (`KeeperCompositeLifecycle`
  ActionSet → human-readable transitions). Currently rendered ad-hoc
  inside fsm-hub; deserves its own RFC.
- Backend deduplication of `keeper.phase` vs `snapshot.phase` (two
  paths to the same value via different stores). Dashboard-only fix
  here; backend SSOT enforcement is RFC-0044-adjacent work.

## 8. Acceptance criteria

- [ ] Operator opening `monitoring?section=agents&view=keepers&keeper=X`
      sees all six FSM lanes (phase, turn_phase, decision, cascade,
      compaction, circuit_breaker) at the top of 운영 상태 개요.
- [ ] No component on the detail surface reads `keeper.phase` /
      `keeper.pipeline_stage` directly *except* the page-header
      breadcrumb (`KeeperPhaseAndStage`).
- [ ] `pnpm typecheck` introduces zero new errors over baseline.
- [ ] `pnpm test` passes; new test asserts that opening detail surface
      renders exactly one composite snapshot consumer in the page body.

## 9. Evidence Record

- Evidence: `specs/keeper-state-machine/KeeperCompositeLifecycle.tla`
  L60-L130 (5 sub-FSM state sets); `dashboard/src/components/fsm-hub-types.ts`
  L1-L40 (`CompositeObservation` + 6th breaker axis);
  `dashboard/src/components/keeper-detail.ts` L1011-L1093 (current
  duplication site).
- Timestamp: 2026-05-08T21:30+09:00
- Confidence: High — TLA spec and FsmHub component both exist in main
  at HEAD `4542ace9ec`.
- Delta: User-reported "SSOT가 아니라 막 널부러져있음" maps to
  exactly one structural defect (composite hub not mounted in detail
  surface). Fix is re-wiring, not redesign.
