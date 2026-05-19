// RFC-0135 PR-3 — primitive keeper predicates SSOT.
//
// Before this module, four call sites each implemented their own
// OR-chain for "is this keeper paused?" (and similar):
//   - keeper-action-panel.ts:113   (paused | status | phase)
//   - dashboard-shell.ts:168       (paused | phase | stage | status)
//   - monitoring-runtime.ts:182    (paused | phaseKey | lifecycleKey)
//   - keeper-reactivity-monitor.ts (paused | phase | pipeline_stage)
//
// Each chain looked at a *different subset of axes*, so two surfaces
// could disagree on whether the same keeper was paused. RFC-0135
// §1.5.1 Cluster C3 catalogued this drift; the typed
// `KeeperOperationalState` SSOT (PR-1) handles full operational state
// derivation, while this module provides the *primitive* booleans the
// derivation function reuses and that non-typed call sites need.
//
// Each predicate checks every documented axis so SSOT == strict
// superset of the historical chains. Adding a new axis here updates
// every call site simultaneously.

import type { Keeper } from '../types/core'

const PAUSED_PHASE = 'Paused'
const PAUSED_LOWER_TOKEN = 'paused'

/** Operator considers the keeper paused on any of: explicit `paused`
 *  flag, FSM phase `Paused`, pipeline stage `paused`, or lowercased
 *  status `paused`. */
export function isKeeperPaused(keeper: Keeper): boolean {
  if (keeper.paused === true) return true
  if (keeper.phase === PAUSED_PHASE) return true
  if (keeper.pipeline_stage === PAUSED_LOWER_TOKEN) return true
  if ((keeper.status ?? '').toLowerCase() === PAUSED_LOWER_TOKEN) return true
  return false
}

/** Operator considers the keeper offline / down on any of: terminal
 *  FSM phases (Offline/Stopped/Dead/Crashed/Zombie) or one of the
 *  three off-tokens emitted in `keeper.status`. */
export function isKeeperOffline(keeper: Keeper): boolean {
  switch (keeper.phase) {
    case 'Offline':
    case 'Stopped':
    case 'Dead':
    case 'Crashed':
    case 'Zombie':
      return true
    default:
      break
  }
  const status = (keeper.status ?? '').toLowerCase()
  return status === 'offline' || status === 'inactive' || status === 'unbooted'
}

/** Closed set of blocker classes that the wakeup action is intended
 *  to recover. These three are the classes pre-RFC `canWake` checked
 *  inline in keeper-action-panel.ts; widening this set requires
 *  matching backend wakeup-recovery handling. */
const WAKEUP_RECOVERABLE_BLOCKERS = new Set<string>([
  'cascade_exhausted',
  'oas_timeout_budget',
  'turn_timeout',
])

export function keeperIsStuckOnRecoverableBlocker(keeper: Keeper): boolean {
  const cls = keeper.runtime_blocker_class
  return typeof cls === 'string' && WAKEUP_RECOVERABLE_BLOCKERS.has(cls)
}

/** Wakeup is meaningful when the keeper is stuck on one of the
 *  recoverable blocker classes *or* it is in a non-paused, non-offline
 *  state where the operator may want to kick the next turn. */
export function keeperCanWakeup(keeper: Keeper): boolean {
  if (keeperIsStuckOnRecoverableBlocker(keeper)) return true
  return !isKeeperPaused(keeper) && !isKeeperOffline(keeper)
}
