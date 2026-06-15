// Keeper Workspace — shared presentational helpers (sigil avatar, status dot,
// phase/group derivation). Kept separate so the roster + chat header + rail
// agree on a single status vocabulary instead of each re-deriving it.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { kSlot, kSigil } from '../keeper-badge'
import { keeperDisplayStatus } from '../../lib/keeper-runtime-display'
import { isKeeperOffline, isKeeperPaused } from '../../lib/keeper-predicates'
import type { Keeper } from '../../types'

/** Coarse lifecycle bucket used both for the dot tone and roster grouping. */
export type KeeperBucket = 'running' | 'paused' | 'offline'

export function keeperBucket(keeper: Keeper): KeeperBucket {
  if (isKeeperOffline(keeper)) return 'offline'
  if (isKeeperPaused(keeper)) return 'paused'
  return 'running'
}

export type DotTone = 'ok' | 'warn' | 'bad' | 'idle'

export function bucketDotTone(bucket: KeeperBucket): DotTone {
  if (bucket === 'running') return 'ok'
  if (bucket === 'paused') return 'warn'
  return 'idle'
}

const DOT_CLASS: Record<DotTone, string> = {
  ok: 'kw-dot ok',
  warn: 'kw-dot warn',
  bad: 'kw-dot bad',
  idle: 'kw-dot',
}

export function StatusDot({ tone, pulse }: { tone: DotTone; pulse?: boolean }): VNode {
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
  const style = {
    width: `${size}px`,
    height: `${size}px`,
    fontSize: `${Math.round(size * 0.42)}px`,
    background: `var(--color-keeper-${slot})`,
    boxShadow: beat ? `0 0 10px rgb(var(--color-keeper-${slot}-glow) / 0.6)` : undefined,
  }
  return html`<span class="kw-sigil" style=${style} title=${id} aria-label=${id}>${sigil}</span>`
}

/** Phase label shown in the roster sub-row and the chat header state pill.
 *  Prefers the typed FSM phase, falls back to the display-status mapper. */
export function keeperPhaseLabel(keeper: Keeper): string {
  return keeper.lifecycle_phase ?? keeper.phase ?? keeperDisplayStatus(keeper)
}

/** The state-pill modifier class for the chat header. */
export function statePillTone(bucket: KeeperBucket): 'run' | 'warn' | 'off' {
  if (bucket === 'running') return 'run'
  if (bucket === 'paused') return 'warn'
  return 'off'
}

/** Current model label, reading the populated fields directly
 *  (keeperDisplayModel is a stub that returns null upstream). */
export function keeperModelLabel(keeper: Keeper): string | null {
  return keeper.active_model_label ?? keeper.active_model ?? keeper.model ?? null
}

/** Current runtime label for the header/rail. */
export function keeperRuntimeLabel(keeper: Keeper): string | null {
  return keeper.runtime_canonical ?? keeper.selected_runtime_canonical ?? null
}
