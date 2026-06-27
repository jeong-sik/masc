---
rfc: "0295"
title: "Fleet RuntimeBand 5th value — transient (busy tone dead-branch recovery)"
status: Draft
created: 2026-06-27
updated: 2026-06-27
author: jeong-sik (vincent)
supersedes: []
superseded_by: null
related: ["0294", "0288", "fleet.jsx prototype (~/Downloads/v2 4/project/keeper-v2/fleet.jsx)"]
implementation_prs: []
---

# RFC-0295 — Fleet `RuntimeBand.transient` (5th value, busy tone dead-branch recovery)

Status: Draft
Author: jeong-sik (vincent)
Date: 2026-06-27
Scope: `dashboard/src/lib/monitoring-runtime.ts#RuntimeBand` (closed sum type),
`dashboard/src/components/agent-roster.ts#ROSTER_BAND_TONE`, every caller that
switches/matches on the 4-value band (`'active' | 'attention' | 'paused' | 'offline'`),
and the keeper-v2 Fleet CSS tone-rail rendering
(`dashboard/src/styles/keeper-v2/fleet.css`).

Out of scope: backend `Keeper_runtime_projection` (`lib/keeper/keeper_runtime_projection.ml`),
the per-keeper FSM phases themselves (`lib/keeper/keeper_lifecycle.ml` 12-FSM),
SSE event payload schemas, and `dashboard/src/components/keeper-workspace/*`
which already uses `kw-fleet-aside[data-tone]` directly without going through
`RuntimeBand`.

## 1. Problem — Fleet CSS paints 5 tones, TS only emits 4; "busy" is a dead branch

The keeper-v2 Fleet design (`fleet.jsx` prototype, ground truth in
`~/Downloads/v2 4/project/keeper-v2/notes/grounding.md`) defines a 5-value
tone vocabulary for the row-left tone-rail and the per-row phase chip:

```
ok | warn | bad | busy | idle
```

The CSS in `dashboard/src/styles/keeper-v2/fleet.css` honors all five
(`fl-row[data-tone="busy"]` at line 96, `fl-chip[data-tone="busy"]` at line 131).
The TS path that fills `data-tone` is narrower. Two layers constrain it:

1. `RuntimeBand` is a closed sum type with 4 values:
   `dashboard/src/lib/monitoring-runtime.ts:10`
   `export type RuntimeBand = 'active' | 'attention' | 'paused' | 'offline'`
2. `agent-roster.ts:97` maps each band onto a `FleetTone`:
   ```
   const ROSTER_BAND_TONE: Record<RuntimeBand, 'ok' | 'warn' | 'bad' | 'idle'> = {
     active: 'ok',
     attention: 'bad',
     paused: 'warn',
     offline: 'idle',
   }
   ```
   `'busy'` is **not** in the range. Every `data-tone` written by `agent-roster.ts`
   is one of four values; the CSS `[data-tone="busy"]` selectors are dead branches.

The prototype's intent is recoverable from `phaseTone(k.phase)` at
`fleet.jsx:30` — it maps every FSM phase onto the 5-tone vocabulary
(`PHASE_TONE[phase] || 'idle'`, where `PHASE_TONE` includes transient
phases like `Compacting | Draining | HandingOff | Restarting` → `'busy'`).
Because the dashboard runs `phase → RuntimeBand → FleetTone` instead of
`phase → FleetTone`, transient phases collapse to `active`/`attention`
and lose the busy rail.

## 2. In scope / Out of scope

In scope:

- `RuntimeBand` sum type extension with `'transient'` as a 5th value.
- `BAND_META: Record<RuntimeBand, RuntimeBandMeta>` and `agentBand`/`keeperBand`
  mapping completeness (line 112, 158, 230).
- `ROSTER_BAND_TONE: Record<RuntimeBand, FleetTone>` becomes a 5→5 mapping
  with `transient: 'busy'`.
- Every exhaustive `switch (band)` and case-by-case match in dashboard code:
  `api/board.ts:94`, `components/governance.ts:60`,
  `components/ide/ide-persistence-panel.ts:71/79/105`,
  `components/overview/overview.ts:446/452/457/476/478/479`,
  `components/keeper-exclusion-label.ts:31`,
  `components/approvals/approvals-surface.ts:47`,
  `components/goals/goal-helpers.ts:148/161/191`,
  `components/goals/goal-tree.ts:251/266`.
- Test fixtures that exhaustively enumerate the 4-value band.
- `lib/monitoring-runtime.ts` Phase → Band mapping: any phase whose
  `op_state.kind === 'transient'` (Compacting | Draining | HandingOff |
  Restarting) routes to the new `transient` band.

Out of scope:

- Backend `lib/keeper/keeper_runtime_projection.ml` — the projection
  already exposes `op_state.kind`; we only consume it. No new backend
  field.
- Keeper FSM phases themselves (`lib/keeper/keeper_lifecycle.ml` 12-FSM).
- SSE event payload schemas (`schemas/sse_event_generated.ts`).
- `dashboard/src/components/keeper-workspace/*` — already paints
  `data-tone` from phase directly without going through `RuntimeBand`,
  so it will gain nothing from this change.

## 3. Justification — the busy rail is the only piece of Fleet semantics
the dashboard actually drops

The 5-tone vocabulary is not arbitrary decoration. The visual signal
distinguishes **steady-state phases** (active/paused/offline/attention)
from **transient phases** (Compacting/Draining/HandingOff/Restarting).
The prototype maps all four transient phases onto `busy` and reserves
`bad` for runtime-attention rows that are not in transition. Conflating
"keeper is in transition" with "keeper is failing" loses the operator's
ability to scan "what is currently moving" down a single column edge,
which is the design's stated goal
(`fleet.jsx:1-3`: *"tone-rail per row, real varied phase chips"*).

Without `busy`, transient-phase keepers paint the same edge color as
steady-state `active` or `attention`, and the dashboard's group divider
(`fl-group.attn` for attention-first sort) becomes ambiguous during a
burst of compactions.

## 4. Caller census — 28 sites touch `RuntimeBand`, 18 have exhaustive switches

`rg -n 'RuntimeBand|\b(active|attention|paused|offline)\b' dashboard/src --type ts`
returns **28 files**. Of those, **18 sites have exhaustive switch/case
statements** that must add a `'transient'` arm. The exhaustive set:

| site | current arms needed | action |
|---|---|---|
| `api/board.ts:94` `switch (band)` | 4 | add `'transient' → transientBandApi()` |
| `components/governance.ts:60` `case 'offline'` | 1 | add `case 'transient'` |
| `components/ide/ide-persistence-panel.ts:71/79/105` | 3 | add `case 'transient'` |
| `components/overview/overview.ts:446/452/457/476/478/479` | 6 | add `case 'transient'` (label: `'전이'` per prototype's `FL_TONE_LABEL`) |
| `components/keeper-exclusion-label.ts:31` | 1 | add `case 'transient'` |
| `components/approvals/approvals-surface.ts:47` `switch (band)` | 4 | add `case 'transient'` |
| `components/goals/goal-helpers.ts:148/161/191` | 3 | add `case 'transient'` |
| `components/goals/goal-tree.ts:251/266` | 2 | add `case 'transient'` |

The remaining 10 sites are type references (`Record<RuntimeBand, …>`,
function returns, property reads). They widen automatically when the
sum type extends; no manual edit required as long as they do not
exhaustively switch.

## 5. Design — `transient` as a first-class band

### 5.1 The band

`monitoring-runtime.ts` gains:

```
export type RuntimeBand = 'active' | 'attention' | 'paused' | 'offline' | 'transient'
```

`BAND_META[transient]` is added with label `'전이'` (matches the prototype's
`FL_TONE_LABEL.busy`), description matching the prototype gloss
(`PHASE_INFO[phase]` for the four transient phases; falls back to
`'단계 전이 중'`).

### 5.2 The mapping

`keeperBand` (line 158) routes to `transient` when
`projection.op_state.kind ∈ { Compacting | Draining | HandingOff | Restarting }`.
These four `op_state.kind` values already exist in
`lib/keeper/keeper_runtime_projection.ml`; the dashboard already imports
them in `monitoring-runtime.ts`. The mapping is:

| condition | band |
|---|---|
| `op_state.kind === 'paused'` | `paused` |
| `op_state.kind === 'offline'` | `offline` |
| `op_state.kind ∈ {Compacting, Draining, HandingOff, Restarting}` | **`transient`** (new) |
| `attention_reasons.length > 0` | `attention` |
| else | `active` |

`agentBand` (line 230) gains a parallel branch for the agent-status
counterpart (`status ∈ {'compacting','draining','handing_off','restarting'}`).

### 5.3 The tone

`ROSTER_BAND_TONE` (line 97) becomes:

```
const ROSTER_BAND_TONE: Record<RuntimeBand, FleetTone> = {
  active:    'ok',
  attention: 'bad',
  paused:    'warn',
  offline:   'idle',
  transient: 'busy',
}
```

CSS in `fleet.css` already paints `[data-tone="busy"]`. The dead branches
become live.

### 5.4 Label consistency

`FL_TONE_LABEL` already contains `busy: '전이'` (line 317). The aside
"selected runtime" label therefore reads correctly without further change.

## 6. Verification

- `rg -n "case 'active'|case 'attention'|case 'paused'|case 'offline'" dashboard/src --type ts | wc -l` increases by 18 (one new arm per exhaustive site).
- `dashboard/src/components/agent-roster.test.ts:729-731` already asserts `data-tone` is in `valid`. Extend `valid` from 4 → 5.
- `dashboard/src/components/fleet-health-panel.test.ts` — update band fixtures.
- New test `monitoring-runtime.test.ts` asserting `keeperBand` returns `'transient'` for each of the four transient `op_state.kind` values.
- Visual: at runtime, trigger Compacting on a keeper and confirm `data-tone="busy"` appears on the row's left rail and the chip.

## 7. Migration / rollback

This RFC lands in **one PR** with the sum-type extension + every exhaustive
switch arm. The 18 sites are mechanical edits; no semantic decisions remain
beyond §5.2's `op_state.kind` set.

Rollback is a single revert because the change is additive — removing the
`'transient'` value restores the prior closed sum type and TS will report
the now-unhandled arms as `never` violations across the 18 sites, which
makes the rollback mechanically obvious.

## 8. Risks

- **Caller spread**: 18 sites need mechanical edits. Mitigated by a single
  PR; CI exhaustive-match lint surfaces any miss.
- **Test fixture churn**: tests that exhaustively enumerate the 4-value
  band must be updated. Mitigated by `rg` enumeration in §6 before merge.
- **Backend 12-FSM phases that the dashboard already calls "transient"
  but the backend classifies differently** — out of scope; would belong
  to a sibling RFC on `op_state.kind` alignment.

## 9. Open questions

- Should `agentBand` use the same `'compacting'|'draining'|'handing_off'|'restarting'`
  string set as `keeperBand`'s `op_state.kind`? Currently `agentBand`
  uses an agent `status` field; need to confirm agent status string values
  align. (May require follow-up RFC if they diverge.)