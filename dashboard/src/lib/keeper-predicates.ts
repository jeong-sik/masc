// RFC-0135 PR-3 — primitive keeper predicates SSOT.
//
// Before this module, four call sites each implemented their own
// OR-chain for "is this keeper paused?" (and similar):
//   - keeper-action-panel.ts:113   (paused | status | phase)
//   - dashboard-shell.ts:168       (paused | phase | stage | status)
//   - monitoring-runtime.ts:182    (paused | phaseKey | lifecycleKey)
//   - tool-monitor/tool-monitor-reactivity.ts (paused | phase | pipeline_stage)
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
const PAUSED_PHASE_LOWER = PAUSED_PHASE.toLowerCase()

function lowerToken(value: string | null | undefined): string {
  return (value ?? '').toLowerCase()
}

/** Structural subset accepted by pause predicates.
 *  Operator snapshots may carry lowercase lifecycle tokens while the
 *  hydrated Keeper type uses PascalCase phases, so these predicates
 *  normalize token casing before comparing. */
export interface KeeperPausedInput {
  paused?: boolean | null
  lifecycle_phase?: Keeper['lifecycle_phase'] | string | null
  phase?: Keeper['phase'] | string | null
  pipeline_stage?: Keeper['pipeline_stage'] | string | null
  pause_state?: Keeper['pause_state'] | string | null
  /** Read by `isKeeperOperatorTargetable` through `KeeperOfflineInput`.
   *  `isKeeperPaused` itself no longer looks at it — see below. */
  status?: string | null
}

/** Operator considers the keeper paused on the explicit `paused` flag, FSM
 *  phase `Paused`, pipeline stage `paused`, or pause state `paused`.
 *
 *  `status = 'paused'` is not one of them. The server builds that word from
 *  the same `ld_paused` the flag comes from, so it carries nothing new — and
 *  it can outlive the flag: the execution-cache override keeps an existing
 *  `Cp_paused` when a `Stopped` phase event arrives
 *  (server_dashboard_http_execution_surfaces.ml), leaving `paused: false`
 *  next to `status: 'paused'` on one row. Reading the word there shows a
 *  stopped keeper as resumable. */
export function isKeeperPaused(keeper: KeeperPausedInput): boolean {
  if (keeper.paused === true) return true
  if (lowerToken(keeper.lifecycle_phase) === PAUSED_PHASE_LOWER) return true
  if (lowerToken(keeper.phase) === PAUSED_PHASE_LOWER) return true
  if (lowerToken(keeper.pipeline_stage) === PAUSED_LOWER_TOKEN) return true
  if (lowerToken(keeper.pause_state) === PAUSED_LOWER_TOKEN) return true
  return false
}

/** Keeper is in a *terminal failure* phase as classified by the
 *  backend's `agent_fsm.ml` (KSM cluster). The three phases here are
 *  distinct from operator-pinned shutdown (`Offline` / `Stopped`) — a
 *  crashed/dead keeper went down *involuntarily*.
 *
 *  Audit finding A1 (2026-05-19): tool-monitor/tool-monitor-reactivity.ts:227
 *  inlined this 3-literal OR chain on the same line that already
 *  called `isKeeperPaused`, so the surface had one typed predicate and
 *  one raw literal chain — a self-documented inconsistency. Adding a
 *  new terminal-failure phase to `agent_fsm.ml` updates every consumer
 *  here at once. */
const CRASHED_PHASES: ReadonlySet<string> = new Set<string>([
  'Crashed',
])

export function isKeeperCrashed(keeper: Keeper): boolean {
  const phase = keeper.lifecycle_phase ?? keeper.phase
  return typeof phase === 'string' && CRASHED_PHASES.has(phase)
}

const CRASHED_PHASES_LOWERCASE: ReadonlySet<string> = new Set<string>(
  [...CRASHED_PHASES].map(p => p.toLowerCase()),
)

/** Checks whether a phase string (any casing) represents a crashed state.
 *  SSE events emit lowercase phase tokens; Keeper objects use PascalCase.
 *  This normalizes both to the same SSOT set. */
export function isCrashedPhase(phase: string | null | undefined): boolean {
  if (typeof phase !== 'string') return false
  return CRASHED_PHASES.has(phase) || CRASHED_PHASES_LOWERCASE.has(phase.toLowerCase())
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
  lifecycle_phase?: Keeper['lifecycle_phase'] | string | null
  phase?: Keeper['phase'] | string | null
  /** Keeper health, one axis published in two placements: the keeper brief
   *  row carries it top-level, the execution route nests it under
   *  `diagnostic`. `Keeper['diagnostic']` types `health_state` as a closed
   *  union while operator snapshots keep an untyped record, so both read
   *  `unknown` and narrow below. */
  health?: unknown
  diagnostic?: { health_state?: unknown } | null
}

const OFFLINE_HEALTH = 'offline'

function healthToken(keeper: KeeperOfflineInput): string | null {
  const raw = keeper.health ?? keeper.diagnostic?.health_state
  return typeof raw === 'string' ? raw.toLowerCase() : null
}

/** Operator considers the keeper offline / down on either axis that
 *  states it directly: a terminal lifecycle phase (Offline/Stopped/Crashed)
 *  or `health_state = offline`, which the backend computes fresh from
 *  `keepalive_running` and heartbeat age.
 *
 *  It deliberately ignores `keeper.status`. That field folds health and
 *  phase back into one word and is refreshed by a different path than the
 *  axes it summarises, so the two can disagree on the same row — measured
 *  2026-08-24: `rondo` carried `status=offline` beside `health=healthy`,
 *  `phase=Running` for the whole observation window. Reading it here made
 *  a live keeper look shut down, which offered `boot` and `purge` and hid
 *  `wakeup`. `inactive` was the worse half: it stood for stale, degraded
 *  and zombie at once, so a keeper that had merely gone quiet was counted
 *  as one that had stopped. */
export function isKeeperOffline(keeper: KeeperOfflineInput): boolean {
  const phase = lowerToken(keeper.lifecycle_phase ?? keeper.phase)
  if (
    phase === 'offline'
    || phase === 'stopped'
    || phase === 'crashed'
  ) {
    return true
  }
  return healthToken(keeper) === OFFLINE_HEALTH
}

/** Closed set of blocker classes that the wakeup action is intended
 *  to recover. These three are the classes pre-RFC `canWake` checked
 *  inline in keeper-action-panel.ts; widening this set requires
 *  matching backend wakeup-recovery handling.
 *  Runtime execution-limit observations are deliberately absent: they are
 *  completed turn observations and never recoverable blocker classes. */
const WAKEUP_RECOVERABLE_BLOCKERS = new Set<string>([
  'runtime_exhausted',
])

export function keeperIsStuckOnRecoverableBlocker(keeper: Keeper): boolean {
  const cls = keeper.runtime_blocker_class
  return typeof cls === 'string' && WAKEUP_RECOVERABLE_BLOCKERS.has(cls)
}

/** Wakeup only kicks the next turn, so it is offered for every live
 *  (non-paused, non-offline) keeper — including ones stuck on a
 *  recoverable blocker. The blocker classes no longer gate this
 *  predicate (the old `if stuck return true; return true` had collapsed
 *  into a constant); keeperIsStuckOnRecoverableBlocker remains the
 *  advisory signal (currently pinned by tests only; no render surface
 *  consumes it yet). */
export function keeperCanWakeup(keeper: Keeper): boolean {
  return !isKeeperPaused(keeper) && !isKeeperOffline(keeper)
}

export interface KeeperActionVisibility {
  canPause: boolean
  canResume: boolean
  canWake: boolean
  canBoot: boolean
  canShutdown: boolean
  canPurge: boolean
}

/** Determine which lifecycle actions are relevant for a keeper's
 *  current state. Keep this in the predicate SSOT so command and
 *  detail surfaces do not drift. */
export function keeperActionVisibility(keeper: Keeper): KeeperActionVisibility {
  const isPaused = isKeeperPaused(keeper)
  const isOffline = isKeeperOffline(keeper)
  const isRunning = isKeeperRunningExcludingRestarting(keeper)
  // A paused directive can outlive its process. The durable owner generation
  // remains the Resume_owner fencing token after the live lane exits, so a
  // paused keeper must resume before an offline lane is booted.

  return {
    canPause:    isRunning && !isPaused,
    canResume:   isPaused,
    canWake:     keeperCanWakeup(keeper),
    canBoot:     isOffline && !isPaused,
    canShutdown: isRunning || isPaused,
    // Purge deletes the keeper and every store it owns, permanently, so it
    // is offered only for a keeper that is not taking turns: paused (the
    // scenario harnesses leave their keepers here) or offline (finished
    // canaries). A healthy running keeper must be paused or shut down first,
    // so the button can never be a one-click loss of working state.
    canPurge:    isPaused || isOffline,
  }
}

/** Operator-facing target lists must keep paused keepers selectable so
 *  the operator can message/probe/resume them even if another axis still
 *  reports an offline-ish status. */
export function isKeeperOperatorTargetable(keeper: KeeperPausedInput & KeeperOfflineInput): boolean {
  return isKeeperPaused(keeper) || !isKeeperOffline(keeper)
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
  'listening',
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
// RFC-0135 PR-SSOT: ATTENTION_PHASES — phases that indicate the keeper
// needs operator attention (error, recovery, or transitional states).
// Previously defined locally in monitoring-runtime.ts as a private Set
// and partially duplicated as BUFFER_PHASES in keeper-phase-indicator.ts.
// Both sites now import from here.
export const ATTENTION_PHASES: ReadonlySet<string> = new Set<string>([
  'Failing',
  'Overflowed',
  'Compacting',
  'HandingOff',
  'Draining',
  'Crashed',
  'Restarting',
])

// BUFFER_PHASES — subset of ATTENTION_PHASES used for visual pulse
// animation in keeper-phase-indicator.ts. Excludes `Crashed` (terminal
// failure gets a static badge, not a pulse). Derived from the SSOT so
// adding a new attention phase auto-updates the animation gate.
export const BUFFER_PHASES: ReadonlySet<string> = new Set<string>(
  [...ATTENTION_PHASES].filter(p => p !== 'Crashed'),
)

export function isKeeperRunningExcludingRestarting(keeper: Keeper): boolean {
  const status = (keeper.status ?? '').toLowerCase()
  if (RUNNING_STATUS_TOKENS.has(status)) return true
  const phase = keeper.phase
  if (typeof phase === 'string' && RUNNING_PHASES_EXCLUDING_RESTARTING.has(phase)) return true
  return false
}
