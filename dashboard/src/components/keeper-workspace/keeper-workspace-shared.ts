// Keeper Workspace — shared presentational helpers (sigil avatar, status dot,
// phase/group derivation). Kept separate so the roster + chat header + rail
// agree on a single status vocabulary instead of each re-deriving it.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { kSlot, kSigil } from '../keeper-badge'
import {
  keeperDisplayRuntime,
  keeperDisplayStatus,
} from '../../lib/keeper-runtime-display'
import {
  deriveKeeperOperationalState,
} from '../../lib/keeper-operational-state'
import {
  PHASE_LABEL_KO,
  PHASE_TONE,
  type FleetTone,
  type KeeperPhaseToken,
} from '../../lib/fleet-tone'
import type { Keeper } from '../../types'

/** Coarse lifecycle bucket used both for the dot tone and roster grouping.
 *  Derived from the typed `KeeperOperationalState` SSOT so the roster groups
 *  match the canonical 4-state vocabulary: running / paused / stuck
 *  (확인 필요) / offline (중지).
 *
 *  Callers that can reach the fleet composite map MUST pass the keeper's
 *  snapshot through: derive promotes a `synthetic_stall` blocker to stuck
 *  only when the composite attention axis confirms it (`blocked === true`),
 *  so a composite-less call would group that keeper under running while
 *  registry/monitoring show `확인 필요` — the exact split this module
 *  exists to prevent. */
export type KeeperBucket = 'running' | 'paused' | 'stuck' | 'offline'

export function keeperBucket(
  keeper: Keeper,
  composite: Parameters<typeof deriveKeeperOperationalState>[0]['composite'] = null,
): KeeperBucket {
  return deriveKeeperOperationalState({ keeper, composite }).kind
}

const DOT_CLASS: Readonly<Record<FleetTone, string>> = {
  ok: 'kw-dot ok',
  warn: 'kw-dot warn',
  bad: 'kw-dot bad',
  busy: 'kw-dot busy',
  idle: 'kw-dot',
}

export function StatusDot({ tone, pulse }: { tone: FleetTone; pulse?: boolean }): VNode {
  return html`<span class=${`${DOT_CLASS[tone]}${pulse ? ' pulse' : ''}`} aria-hidden="true"></span>`
}

/** Canonical color + 2-letter sigil avatar at an arbitrary size (KeeperBadge
 *  tops out at 24px; the chat hero needs 46px). Reuses the same kSlot/kSigil
 *  registry so colors match the rest of the dashboard. */
export function WorkspaceSigil({
  id,
  size,
  beat = false,
}: {
  id: string
  size: number
  beat?: boolean
}): VNode {
  const slot = kSlot(id)
  const sigil = kSigil(id)
  // B4: expose the slot glow as --sigil-glow so the CSS kw-sigil-beat keyframe
  // can pulse it (replacing the old static box-shadow). Always set so a
  // non-beating sigil that later starts beating already has the color wired.
  const style = {
    width: `${size}px`,
    height: `${size}px`,
    fontSize: `${Math.round(size * 0.42)}px`,
    background: `var(--color-keeper-${slot})`,
    '--sigil-glow': `var(--color-keeper-${slot}-glow)`,
  }
  return html`<span class=${`kw-sigil${beat ? ' kw-sigil-beat' : ''}`} style=${style} title=${id} aria-label=${id}>${sigil}</span>`
}

/** The canonical status token for a keeper.
 *
 *  `keeperDisplayStatus` now declares `KeeperPhaseToken` as its return
 *  type, so this is a pass-through. It previously re-narrowed with a
 *  runtime `hasOwnProperty` guard because that function returned `string`;
 *  the guard was where `'idle'` / `'listening'` / `'handingoff'` /
 *  `'offline'` silently became `'unknown'`, i.e. `확인 필요`. Parsing now
 *  happens once, at the wire boundary inside `keeperDisplayStatus`
 *  (`toKeeperPhaseToken` in `lib/fleet-tone.ts`), so re-checking here would
 *  only be able to hide a producer bug, not catch one.
 *
 *  Kept as a named function rather than inlined: three call sites read it
 *  as "the token for this keeper", and it is the seam to change if the
 *  workspace ever needs a token different from the shared display one. */
export function phaseTokenFromKeeper(keeper: Keeper): KeeperPhaseToken {
  return keeperDisplayStatus(keeper)
}

/** Phase label shown in the roster sub-row and the chat header state pill.
 *  Routes through keeperDisplayStatus so error/transient phases surface with
 *  the same token vocabulary the rest of the dashboard uses, then maps to a
 *  Korean label from the fleet-tone SSOT (no parallel PHASE_LABEL_KO here —
 *  that table moved to `lib/fleet-tone.ts`). Previously returned the raw
 *  `lifecycle_phase` enum, which leaked raw phase names
 *  into the UI. */
export function keeperPhaseLabel(keeper: Keeper): string {
  if (keeper.config_error?.blocking === true) return '설정 차단'
  const token = phaseTokenFromKeeper(keeper)
  return PHASE_LABEL_KO[token] ?? token
}

/** Health tone for the status dot + header pill. One-line closed-map lookup
 *  against the fleet-tone SSOT (PHASE_TONE) — no parallel Set<string>
 *  classifier. The repo-owned fleet-tone module owns the KeeperPhase →
 *  tone mapping, so adding a new phase forces the compiler to flag a
 *  missing entry there.
 *
 *  Distinct from keeperBucket, which groups into the 4 coarse buckets
 *  (running/paused/stuck/offline) for the roster: a Failing
 *  keeper is neither offline nor paused, so the bucket classifies it as
 *  "stuck" only when a blocker class is recorded — without one it lands in
 *  "running" and would render a green dot while actually degraded.
 *  PHASE_TONE handles this — Failing maps to `bad`. */
export function keeperStatusTone(keeper: Keeper): FleetTone {
  return PHASE_TONE[phaseTokenFromKeeper(keeper)]
}

/** Fleet surfaces are attention-first: a keeper with blocked work or an
 *  approval gate should not look healthy just because its runtime is still
 *  technically running. Kept here so roster rows and the selected-runtime
 *  rail cannot silently diverge. */
export function keeperFleetTone(keeper: Keeper): FleetTone {
  if (
    keeper.config_error?.blocking === true
    || keeper.needs_attention === true
    || (keeper.blocked_task_count ?? 0) > 0
    || keeper.current_gate?.kind === 'approval_required'
  ) return 'bad'
  return keeperStatusTone(keeper)
}

/** The state-pill modifier class for the chat header, derived from the
 *  health tone so error phases get the `bad` pill rather than collapsing
 *  to `off`. Transient (busy) phases get the dedicated `busy` pill so the
 *  header shows transitional phases as working-through, not stopped.
 *
 *  Note: this is a 1:1 type mapping, not a classifier. Same `FleetTone`
 *  keyspace → CSS class suffix. Kept as a function (not a constant table)
 *  because TypeScript `Record<FleetTone, PillClass>` would already be
 *  total, and the explicit `if` chain is easier for maintainers to read
 *  at the call site. */
export function statePillTone(tone: FleetTone): 'run' | 'warn' | 'bad' | 'busy' | 'off' {
  if (tone === 'ok') return 'run'
  if (tone === 'warn') return 'warn'
  if (tone === 'bad') return 'bad'
  if (tone === 'busy') return 'busy'
  return 'off'
}

/** Current runtime label for the header/rail. */
export function keeperRuntimeLabel(keeper: Keeper): string | null {
  return keeperDisplayRuntime(keeper)?.value ?? null
}
