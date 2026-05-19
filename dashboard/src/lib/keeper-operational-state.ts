// RFC-0135 §2 — Typed SSOT for keeper operational state.
//
// Every dashboard surface (roster card, detail runtime panel, alert strip,
// action panel, lifecycle timeline) derives its display verdict from this
// single function. Three pre-RFC sites that disagreed on the same keeper:
//   - agent-roster.ts:rosterStateNote        (flat runtime_blocker_class read)
//   - keeper-detail-runtime.ts:deriveKeeperLiveTruth
//                                            (composite-aware conditioning)
//   - keeper-action-panel.ts:keeperActionVisibility
//                                            (status/phase/paused OR-chain)
// will all call `deriveKeeperOperationalState` instead (PR-3 ~ PR-6).
//
// Discriminant invariants (RFC-0135 §2 conditioning matrix):
//   paused      ⇐ keeper.paused | phase==='Paused' | pause_state==='paused'
//   offline     ⇐ phase ∈ Offline/Stopped/Dead/Crashed/Zombie  OR
//                 status ∈ offline/inactive/unbooted
//   stuck       ⇐ runtime_blocker_class set AND execution_current !== true
//                 OR composite reports fiber_alive === false
//   running     ⇐ otherwise (turn_phase carried; lingering stale blocker is
//                 recorded but does NOT drive the headline)
//
// catch-all `default:` is forbidden — see RFC-0135 §9 (PR-9 CI guard).

import type {
  Keeper,
  KeeperRuntimeBlockerClass,
} from '../types/core'
import type {
  KeeperCompositeSnapshot,
} from '../api/schemas/keeper-composite'

export type OfflineCause = 'unbooted' | 'shutdown' | 'crashed' | 'dead' | 'unknown'
export type PausedCause = 'operator' | 'supervisor' | 'auto_recover' | 'unknown'
export type StuckReason = KeeperRuntimeBlockerClass | 'fiber_dead' | 'unknown'

export type KeeperOperationalState =
  | { readonly kind: 'offline'; readonly cause: OfflineCause }
  | { readonly kind: 'paused'; readonly cause: PausedCause }
  | { readonly kind: 'stuck'; readonly reason: StuckReason }
  | {
      readonly kind: 'running'
      readonly turnPhase: string
      readonly staleBlocker: KeeperRuntimeBlockerClass | null
    }

export interface DeriveInputs {
  readonly keeper: Keeper
  readonly composite: KeeperCompositeSnapshot | null
}

export function deriveKeeperOperationalState(
  { keeper, composite }: DeriveInputs,
): KeeperOperationalState {
  if (isPaused(keeper)) {
    return { kind: 'paused', cause: derivePausedCause(keeper) }
  }
  if (isOffline(keeper, composite)) {
    return { kind: 'offline', cause: deriveOfflineCause(keeper) }
  }

  const blockerClass = keeper.runtime_blocker_class ?? null
  const attention = composite?.runtime_attention ?? null
  // `execution_current === true` is the strongest fresh-turn signal,
  // but backend may leave it unset (or briefly `false`) while a fresh
  // turn is in flight and the first receipt for it hasn't landed.
  // `is_live === true` confirms a live turn is in progress; either
  // signal is enough to treat a flat `runtime_blocker_class` as a
  // stale prior-turn leftover rather than an active blocker (matches
  // the `previousExecutionReceipt` interpretation in the legacy
  // `deriveKeeperLiveTruth` path that this module is taking over).
  const executionFresh =
    attention?.execution_current === true || composite?.is_live === true
  const staleReceipt = attention?.stale_execution_receipt === true

  if (blockerClass !== null && !executionFresh) {
    return { kind: 'stuck', reason: blockerClass }
  }

  // Backend explicitly flagged the keeper as needing attention. Trust
  // this over the flat blocker-class read — backend has already done
  // the stale-receipt conditioning for us. When no typed
  // `runtime_blocker_class` is present (or it's an old keeper that
  // lost the class but kept the attention flag), fall back to the
  // `'unknown'` StuckReason variant.
  if (
    attention?.blocked === true
    || attention?.needs_attention === true
  ) {
    return { kind: 'stuck', reason: blockerClass ?? 'unknown' }
  }

  if (composite !== null && compositeFiberKnownDead(composite)) {
    return { kind: 'stuck', reason: 'fiber_dead' }
  }

  const turnPhase = composite?.turn_phase ?? keeper.pipeline_stage ?? 'idle'
  const staleBlocker =
    executionFresh && (blockerClass !== null || staleReceipt)
      ? blockerClass
      : null
  return { kind: 'running', turnPhase, staleBlocker }
}

function isPaused(k: Keeper): boolean {
  if (k.paused === true) return true
  if (k.phase === 'Paused') return true
  if (k.pause_state === 'paused') return true
  return false
}

function derivePausedCause(k: Keeper): PausedCause {
  if (k.runtime_blocker_class === 'supervisor_paused') return 'supervisor'
  if (k.pause_state === 'paused') return 'operator'
  if (k.phase === 'Paused') return 'operator'
  return 'unknown'
}

function isOffline(k: Keeper, c: KeeperCompositeSnapshot | null): boolean {
  if (c !== null && (c.phase === 'Stopped' || c.phase === 'Dead')) return true
  if (
    k.phase === 'Offline'
    || k.phase === 'Stopped'
    || k.phase === 'Dead'
    || k.phase === 'Crashed'
    || k.phase === 'Zombie'
  ) return true
  const normalizedStatus = (k.status ?? '').toLowerCase()
  return (
    normalizedStatus === 'offline'
    || normalizedStatus === 'inactive'
    || normalizedStatus === 'unbooted'
  )
}

function deriveOfflineCause(k: Keeper): OfflineCause {
  if (k.phase === 'Crashed') return 'crashed'
  if (k.phase === 'Dead' || k.phase === 'Zombie') return 'dead'
  if (k.phase === 'Stopped') return 'shutdown'
  const normalizedStatus = (k.status ?? '').toLowerCase()
  if (normalizedStatus === 'unbooted') return 'unbooted'
  if (normalizedStatus === 'offline' || normalizedStatus === 'inactive') return 'unbooted'
  return 'unknown'
}

function compositeFiberKnownDead(c: KeeperCompositeSnapshot): boolean {
  const diag = c.phase_diagnosis
  if (diag == null) return false
  const fiberAlive = diag.conditions.fiber_alive
  return fiberAlive === false
}
