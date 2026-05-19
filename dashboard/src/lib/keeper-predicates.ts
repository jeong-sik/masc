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

/** Keeper is in a *terminal failure* phase as classified by the
 *  backend's `agent_fsm.ml` (KSM cluster). The three phases here are
 *  distinct from operator-pinned shutdown (`Offline` / `Stopped`) — a
 *  crashed/dead/zombie keeper went down *involuntarily*.
 *
 *  Audit finding A1 (2026-05-19): keeper-reactivity-monitor.ts:227
 *  inlined this 3-literal OR chain on the same line that already
 *  called `isKeeperPaused`, so the surface had one typed predicate and
 *  one raw literal chain — a self-documented inconsistency. Adding a
 *  new terminal-failure phase to `agent_fsm.ml` updates every consumer
 *  here at once. */
const CRASHED_PHASES: ReadonlySet<string> = new Set<string>([
  'Crashed',
  'Dead',
  'Zombie',
])

export function isKeeperCrashed(keeper: Keeper): boolean {
  const phase = keeper.phase
  return typeof phase === 'string' && CRASHED_PHASES.has(phase)
}

/** Structural subset of `Keeper` accepted by `isKeeperOffline`.
 *  The predicate only reads `phase` and `status`, so callers that
 *  receive narrower snapshot shapes (e.g. `OperatorKeeperSnapshot`,
 *  which has no `phase` field) can pass them in directly. When
 *  `phase` is absent the switch falls through to the status-token
 *  check — the more conservative answer than only matching the
 *  literal `'offline'` token.
 *
 *  Audit finding B5 (2026-05-19): two callsites used a local
 *  `normalizeStatus(keeper.status) !== 'offline'` which only catches
 *  one of the three off-tokens (`offline | inactive | unbooted`).
 *  Routing them through this predicate closes the undercount. */
export interface KeeperOfflineInput {
  phase?: Keeper['phase']
  status?: string
}

/** Operator considers the keeper offline / down on any of: terminal
 *  FSM phases (Offline/Stopped/Dead/Crashed/Zombie) or one of the
 *  off-tokens emitted in `keeper.status`. */
export function isKeeperOffline(keeper: KeeperOfflineInput): boolean {
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
  // RFC-0139 PR-2: the `'stopped'` status token is emitted from
  // `Keeper_state_machine.phase_to_string`
  // (lib/keeper/keeper_lifecycle_events.ml:74) when only the
  // wire-format status string is in hand (no PascalCase phase yet).
  // The legacy `lib/status-utils.isOfflineStatus` recognised it; folded
  // in here so `isOfflineStatus` can be retired as strict-subset
  // duplication.
  return status === 'offline'
    || status === 'inactive'
    || status === 'unbooted'
    || status === 'stopped'
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

// RFC-0135 PR-11 — running predicate excluding `Restarting`.
//
// The action panel's `canPause`/`canWake` gates treat `Restarting` as
// "stuck" (kicked but not yet running), not "running". This subset of
// the SSOT running variant is action-panel-specific but had been
// inlined as a 10-literal OR chain at keeper-action-panel.ts:99-117
// with a self-doc comment admitting the duplication. The full literal
// set lives here so a new lifecycle phase added to the running cluster
// is reflected in every consumer at once.
const RUNNING_STATUS_TOKENS = new Set<string>([
  'active',
  'running',
  'idle',
  'busy',
])

const RUNNING_PHASES_EXCLUDING_RESTARTING: ReadonlySet<string> = new Set<string>([
  'Running',
  'Failing',
  'Overflowed',
  'Compacting',
  'HandingOff',
  'Draining',
])

/** Keeper is "running" for action-panel purposes — turn-producing,
 *  alive, but explicitly *not* `Restarting`. The action panel routes
 *  `Restarting` to the wakeup branch (kicked-but-not-ticking) rather
 *  than the pause branch, so a single SSOT predicate must distinguish.
 *
 *  Strict subset of `deriveKeeperOperationalState(...).kind === 'running'`
 *  — it excludes the `Restarting` phase the typed state currently maps
 *  to `running`. When `KeeperOperationalState` gains a dedicated
 *  `restarting` variant (RFC-0135 follow-up Goal-2), this predicate
 *  collapses to that check. */
export function isKeeperRunningExcludingRestarting(keeper: Keeper): boolean {
  const status = (keeper.status ?? '').toLowerCase()
  if (RUNNING_STATUS_TOKENS.has(status)) return true
  const phase = keeper.phase
  if (typeof phase === 'string' && RUNNING_PHASES_EXCLUDING_RESTARTING.has(phase)) return true
  return false
}
