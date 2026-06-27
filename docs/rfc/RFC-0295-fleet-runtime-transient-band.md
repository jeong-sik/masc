---
rfc: "0295"
title: "Fleet RuntimeBand 5th value — transient (busy tone dead-branch recovery)"
status: Draft
created: 2026-06-27
updated: 2026-06-27
revision_note: "§5.2 mapping source corrected in revision 2 (2026-06-27). The transient phases live on `opState.phase` (KeeperPhase SSOT), not `opState.kind` (closed sum of offline/paused/stuck/running). agentBand retains 4-tone routing because AgentStatus carries no FSM-phase information. Revision 3 (2026-06-27): §5.2 documents wire-vocabulary asymmetry — composite uses `handing_off` (snake_case via BACKEND_PHASE_LOWERCASE_MAP), pipeline_stage uses `handoff` (single word); both resolve to the HandingOff PascalCase SSOT."
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

## 4. Caller census — RuntimeBand has 4 exhaustive switch sites (revision 2)

`rg -n 'RuntimeBand' dashboard/src --type ts` returns **9 lines**, all
in two files (`monitoring-runtime.ts`, `agent-roster.ts`). Of those,
**4 sites have exhaustive switch statements on `RuntimeBand`** that
must add a `'transient'` arm:

| site | current arms needed | action |
|---|---|---|
| `components/agent-roster.ts:83-89` `rosterBandActionHint(band, isKeeper)` | 4 | add `case 'transient' → '전이'` |
| `lib/monitoring-runtime.ts:158-175` `keeperBand(projection)` | 4 | add transient branch per §5.2 |
| `lib/monitoring-runtime.ts:230-258` `agentBand(status)` | 4 | unchanged — see §5.2 |
| `lib/monitoring-runtime.ts:264-267` `runtimeBandForAgent(...)` | 4 | unchanged (routes to `keeperBand`) |

The remaining 5 sites are type references
(`Record<RuntimeBand, ...>`, function returns, property reads). They
widen automatically when the sum type extends; no manual edit is
required for them, though `agent-roster.ts:97 ROSTER_BAND_TONE` must be
rewritten because its *value* union narrows from
`'ok' | 'warn' | 'bad' | 'idle'` (4) to include `'busy'` (5).

A first-pass audit (revision 1) listed 18 sites based on substring
matching of the 4-value literals; that census was incorrect — those
matches were on unrelated closed sums (`KeeperAttention`,
`PausedCause`, `RepoState`, etc.), not on `RuntimeBand`. The exhaustive
enforcement of `RuntimeBand` only fires where the parameter or local
variable is typed `RuntimeBand`.

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

`keeperBand` (line 158) routes to `transient` when the keeper's FSM phase
is a *transient* phase. The phase data lives on `projection.opState.phase`
(preferred, typed `KeeperPhase` SSOT — `types/core.ts:1083`) or, when
the composite is unavailable, `keeper.pipeline_stage` (lowercase wire
format, `types/core.ts:945`). The `STAGE_PHASE_EQUIVALENTS` table at
`monitoring-runtime.ts:101-110` is the cross-format SSOT.

| condition | band |
|---|---|
| `opState.kind === 'paused'` | `paused` |
| `opState.kind === 'offline'` | `offline` |
| `opState.kind === 'stuck'` | `attention` (existing — unchanged) |
| `opState.phase ∈ {Compacting, HandingOff, Draining, Restarting}` *(or pipeline_stage equivalents `compacting`/`handoff`/`draining`/`restarting`)* | **`transient`** (new) |
| `attention_signals.length > 0` | `attention` |
| else | `active` |

**Wire vocabulary asymmetry (revision 3, 2026-06-27, found by pre-flight vitest
on implementation PR)** — `opState.phase` is *normalized* by
`toKeeperPhase` (keeper-store-normalize.ts:159) which consults
`BACKEND_PHASE_LOWERCASE_MAP` (line 110). That map spells `handing_off`
(snake_case) for the composite wire, while the `pipeline_stage` wire uses
`handoff` (single word, types/core.ts:945). Both shapes resolve to the
`HandingOff` PascalCase SSOT, so they are *the same phase* — but the
caller-facing literals are not interchangeable. `isTransientPhase` accepts
both spellings (and the PascalCase) so the band routing is consistent
regardless of which projection path fires. Pre-flight test:
`monitoring-runtime.test.ts:288-291` ('handing_off' composite) and
`monitoring-runtime.test.ts:299-302` ('HandingOff' PascalCase) both pass;
`'handoff'` only fires through the `pipeline_stage` path (`STAGE_LABELS`
key, line 84).

The mapping is **phase-first**, not kind-first. `opState.kind` lives on
a closed sum (`offline`/`paused`/`stuck`/`running` —
`keeper-operational-state.ts:106-113`) that carries no transient-phase
information; transient phases are encoded on `opState.phase` (the
orthogonal axis), not on `opState.kind`. The current code reads
`opState.kind` only and lets the `'stuck'` arm absorb the visual signal,
which is why the prototype's busy rail is unreachable from the dashboard
path.

`agentBand` (line 230) does NOT gain a transient arm. `AgentStatus`
(`agent-status.ts:16-22`) is a closed sum of presence states
(`active | busy | listening | idle | inactive | offline`) that carries
no FSM-phase information; the agent-status `'busy'` token is an
operational cue (currently driving work), not a transient FSM phase.
Agents without a linked keeper therefore keep their existing 4-tone
routing. Operators see the transient rail only on rows where a keeper
is linked and the keeper FSM is mid-transition.

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

- `rg -n 'RuntimeBand' dashboard/src --type ts` returns 9 lines; the
  sum-type extension to 5 values forces a compile-time error on the
  4 exhaustive switch sites (§4) until each adds a `'transient'` arm.
- `dashboard/src/components/agent-roster.test.ts:729-731` asserts
  `data-tone` is in `valid`. Extend `valid` from 4 → 5 with `'busy'`.
- New tests in `dashboard/src/lib/monitoring-runtime.test.ts`
  asserting `runtimeBandMeta('transient')` returns the new band meta
  AND `summarizeKeeperMonitoring(...)` returns `band.key === 'transient'`
  for each of the four transient phases (`Compacting`/`HandingOff`/
  `Draining`/`Restarting`) — driven via `composite.phase` (lowercase
  wire format, see `KeeperCompositePhaseSchema`).
- `dashboard/src/components/fleet-health-panel.test.ts` — update any
  band fixtures that enumerate the 4-value band.
- Visual: at runtime, trigger Compacting on a keeper and confirm
  `data-tone="busy"` appears on the row's left rail and the chip.

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