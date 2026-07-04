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
import { isKeeperOffline, isKeeperPaused } from '../../lib/keeper-predicates'
import {
  PHASE_LABEL_KO,
  PHASE_TONE,
  type FleetTone,
  type KeeperPhaseToken,
} from '../../lib/fleet-tone'
import type { Keeper } from '../../types'

/** Coarse lifecycle bucket used both for the dot tone and roster grouping. */
export type KeeperBucket = 'running' | 'paused' | 'offline'

export function keeperBucket(keeper: Keeper): KeeperBucket {
  if (isKeeperPaused(keeper)) return 'paused'
  if (isKeeperOffline(keeper)) return 'offline'
  return 'running'
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

/** Normalize the canonical status token (from `keeperDisplayStatus`) into
 *  the closed `KeeperPhaseToken` keyspace. Unknown tokens collapse to
 *  `'unknown'` so `PHASE_TONE` / `PHASE_LABEL_KO` lookups are total.
 *
 *  Previously this was `keeperPhaseToken` reading from `lifecycle_phase`
 *  directly. That returned the raw `lifecycle_phase ?? phase` value
 *  (PascalCase) — incompatible with the lowercase-keyed SSOT in
 *  `fleet-tone.ts`. Routing through `keeperDisplayStatus` (which already
 *  applies the lowercasing + isKeeperPaused short-circuit) means there is
 *  exactly one mapping table from `KeeperPhase` to lowercase token (in
 *  `keeper-runtime-display.ts:197` `keeperLifecycleStatus`). */
export function phaseTokenFromKeeper(keeper: Keeper): KeeperPhaseToken {
  const token = keeperDisplayStatus(keeper).trim().toLowerCase()
  return isKeeperPhaseToken(token) ? token : 'unknown'
}

/** Closed-sum guard. `keeperDisplayStatus` returns a `string` (its
 *  signature is intentionally permissive because callers pass through
 *  arbitrary backend status values), so we narrow here against the
 *  declared token union. New tokens from the wire that are not yet in
 *  `KeeperPhaseToken` collapse to `'unknown'` via this fallback.
 *
 *  Why `Object.prototype.hasOwnProperty.call` instead of `value in PHASE_TONE`:
 *  the `in` operator walks the prototype chain. Although `PHASE_TONE` is
 *  now built with `Object.create(null)` (see `lib/fleet-tone.ts`) so
 *  this specific leak no longer applies, the `hasOwnProperty` form is
 *  defensive against future refactors that switch the map to a plain
 *  object literal or a `Map`. Either backend leak mode would let a
 *  wire token like `'constructor'` or `'toString'` slip past the
 *  `'unknown'` fallback and surface inherited `Object.prototype`
 *  members in `keeperStatusTone` / `keeperPhaseLabel`. */
function isKeeperPhaseToken(value: string): value is KeeperPhaseToken {
  return Object.prototype.hasOwnProperty.call(PHASE_TONE, value)
}

/** Phase label shown in the roster sub-row and the chat header state pill.
 *  Routes through keeperDisplayStatus so error/transient phases surface with
 *  the same token vocabulary the rest of the dashboard uses, then maps to a
 *  Korean label from the fleet-tone SSOT (no parallel PHASE_LABEL_KO here —
 *  that table moved to `lib/fleet-tone.ts`). Previously returned the raw
 *  `lifecycle_phase` enum, which leaked "Running"/"Compacting"/"HandingOff"
 *  into the UI. */
export function keeperPhaseLabel(keeper: Keeper): string {
  const token = phaseTokenFromKeeper(keeper)
  return PHASE_LABEL_KO[token] ?? token
}

/** Health tone for the status dot + header pill. One-line closed-map lookup
 *  against the fleet-tone SSOT (PHASE_TONE) — no parallel Set<string>
 *  classifier. The repo-owned fleet-tone module owns the KeeperPhase →
 *  tone mapping, so adding a new phase forces the compiler to flag a
 *  missing entry there.
 *
 *  Distinct from keeperBucket, which only groups running/paused/offline
 *  for the roster: a Failing or Overflowed keeper is neither offline nor
 *  paused, so the bucket classifies it as "running" and it would render a
 *  green dot while actually degraded. PHASE_TONE handles this — Failing /
 *  Overflowed both map to `bad`. */
export function keeperStatusTone(keeper: Keeper): FleetTone {
  return PHASE_TONE[phaseTokenFromKeeper(keeper)]
}

/** Fleet surfaces are attention-first: a keeper with blocked work or an
 *  approval gate should not look healthy just because its runtime is still
 *  technically running. Kept here so roster rows and the selected-runtime
 *  rail cannot silently diverge. */
export function keeperFleetTone(keeper: Keeper): FleetTone {
  if (
    keeper.needs_attention === true
    || (keeper.blocked_task_count ?? 0) > 0
    || keeper.current_gate?.kind === 'approval_required'
  ) return 'bad'
  return keeperStatusTone(keeper)
}

/** The state-pill modifier class for the chat header, derived from the
 *  health tone so error phases get the `bad` pill rather than collapsing
 *  to `off`. Transient (busy) phases get the dedicated `busy` pill so the
 *  header shows "compacting" as working-through, not stopped.
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

/** Current model label, reading the populated fields directly
 *  (keeperDisplayModel is a stub that returns null upstream). */
export function keeperModelLabel(keeper: Keeper): string | null {
  return keeper.active_model_label ?? keeper.active_model ?? keeper.model ?? null
}

/** Current runtime label for the header/rail. */
export function keeperRuntimeLabel(keeper: Keeper): string | null {
  return keeperDisplayRuntime(keeper)?.value ?? null
}
