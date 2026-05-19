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
// Discriminant invariants (RFC-0135 §2 conditioning matrix). The
// `execution_current` semantics are anchored at
// `lib/server/server_dashboard_http.ml:1061-1074`:
//
//   `execution_current = true`  — receipt either (a) does not exist, or
//      (b) is not from a stale live turn (`receipt_at >= live_started_at`).
//      The receipt's blocker, if any, reflects the *current* live turn.
//   `execution_current = false` — receipt is from a *previous* live turn
//      (`receipt_at < live_started_at` with a newer turn now live). The
//      blocker class describes that prior turn and is stale.
//   `stale_execution_receipt = receipt_present && !execution_current` is
//      the same axis seen from the receipt side; either signal counts as
//      an explicitly-stale marker.
//
//   paused   ⇐ keeper.paused | phase==='Paused' | pause_state==='paused'
//   offline  ⇐ phase ∈ Offline/Stopped/Dead/Crashed/Zombie  OR
//              status ∈ offline/inactive/unbooted
//   stuck    ⇐ (runtime_blocker_class set AND NOT explicitlyStale)
//              OR composite reports fiber_alive === false
//   running  ⇐ otherwise. When the blocker_class is set but the receipt
//              is explicitly stale, the blocker is recorded as
//              `staleBlocker` for display but does NOT drive the headline.
//
// catch-all `default:` is forbidden — see RFC-0135 §9 (PR-9 CI guard).

import type {
  Keeper,
  KeeperPhase,
  KeeperRuntimeBlockerClass,
  PipelineStage,
} from '../types/core'
import { toKeeperPhase } from '../keeper-store-normalize'
import type {
  KeeperCompositeSnapshot,
} from '../api/schemas/keeper-composite'

export type OfflineCause = 'unbooted' | 'shutdown' | 'crashed' | 'dead' | 'unknown'
export type PausedCause = 'operator' | 'supervisor' | 'auto_recover' | 'unknown'
export type StuckReason = KeeperRuntimeBlockerClass | 'fiber_dead' | 'unknown'

// RFC-0135 PR-14a — attention axis SSOT (Goal-2 typed-state expansion).
//
// `runtime_attention.{blocked,needs_attention}` was previously OR'd
// against `state.kind === 'stuck'` inline at
// `components/keeper-detail-runtime.ts:213-216`, leaving the typed
// state and the attention axis as parallel inputs to the same
// `blocked` decision. The two axes are *orthogonal* — a running keeper
// can have `attention: 'needs_attention'` set by backend without any
// blocker class, and a stuck keeper can have its attention cleared
// after operator acknowledgement. Encoding attention as a sum next to
// `KeeperOperationalState` keeps both signals explicit.
//
// Closed sum (no catch-all per RFC-0135 §9-4):
//   blocked          — backend says live execution is held
//   needs_attention  — backend flagged operator action required
//   clean            — neither set, no orange edge on dashboard
export type KeeperAttention = 'blocked' | 'needs_attention' | 'clean'

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
  // An explicit stale marker is required to demote a blocker. The absence
  // of `runtime_attention` (older backend, missing composite) leaves the
  // blocker meaningful — fail-closed default.
  const explicitlyStale =
    attention?.execution_current === false
    || attention?.stale_execution_receipt === true

  if (blockerClass !== null && !explicitlyStale) {
    return { kind: 'stuck', reason: blockerClass }
  }

  if (composite !== null && compositeFiberKnownDead(composite)) {
    return { kind: 'stuck', reason: 'fiber_dead' }
  }

  const turnPhase = composite?.turn_phase ?? keeper.pipeline_stage ?? 'idle'
  // A blocker that *was* recorded but is now explicitly stale gets
  // surfaced as informational context, not a headline.
  const staleBlocker =
    explicitlyStale && blockerClass !== null ? blockerClass : null
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

/** RFC-0135 PR-14a — orthogonal attention axis.
 *
 *  Maps `composite.runtime_attention.{blocked, needs_attention}` to a
 *  closed sum. Priority: `blocked` over `needs_attention` (backend can
 *  set both, in which case the operator-blocking case is louder).
 *
 *  When composite is null, returns `'clean'` — without backend
 *  attestation the dashboard has no basis to claim attention is needed.
 *  Callers may still combine this with `state.kind === 'stuck'` if
 *  blocker-class evidence alone should surface an alert. */
export function deriveKeeperAttention(
  composite: KeeperCompositeSnapshot | null,
): KeeperAttention {
  const attention = composite?.runtime_attention
  if (attention?.blocked === true) return 'blocked'
  if (attention?.needs_attention === true) return 'needs_attention'
  return 'clean'
}

// RFC-0135 PR-11 — Composite KSM phase SSOT helpers.
//
// `KeeperCompositeSnapshot.phase` is wire-format lowercase emitted by
// backend `lib/server/server_dashboard_http.ml` and typed as bare
// `string` in `api/schemas/keeper-composite.ts`. Three call sites had
// re-implemented phase grouping inline:
//   - keeper-fsm-specs.ts:140-150   (ksmTone — 11-literal 2-tier OR)
//   - fsm-hub-invariant-analysis.ts:74-186  (8 literal compares)
//   - fleet-fsm-matrix.ts:262,486,497  (running/idle compares)
// Same 6 warn-phase literals were copy-pasted between fsm-specs and
// invariant-analysis (N-of-M anti-pattern; software-development.md
// §AI 코드 생성 안티패턴 #2).
//
// `KeeperKsmPhase` is the closed sum of states emitted by the backend
// KeeperStateMachine TLA spec (KSM_STATES in keeper-fsm-specs.ts).
// `compositePhaseTone` is total and exhaustive — adding a new variant
// here requires touching every consumer at compile time.

export type KeeperKsmPhase =
  | 'offline'
  | 'running'
  | 'failing'
  | 'overflowed'
  | 'compacting'
  | 'handing_off'
  | 'draining'
  | 'paused'
  | 'stopped'
  | 'crashed'
  | 'restarting'
  | 'dead'
  | 'zombie'

const KSM_PHASE_VALUES: ReadonlySet<string> = new Set<KeeperKsmPhase>([
  'offline', 'running', 'failing', 'overflowed', 'compacting',
  'handing_off', 'draining', 'paused', 'stopped', 'crashed',
  'restarting', 'dead', 'zombie',
])

/** Narrow `string` to `KeeperKsmPhase` if it is a known value, else
 *  return `null`. Use at the schema/wire boundary; downstream code
 *  should consume the typed sum directly. */
export function toKsmPhase(raw: string | null | undefined): KeeperKsmPhase | null {
  if (raw == null) return null
  return KSM_PHASE_VALUES.has(raw) ? (raw as KeeperKsmPhase) : null
}

/** Three-valued tone classification used by FSM-graph node rendering
 *  and invariant cards: terminal/error phases → 'err', long-running
 *  rare-state phases → 'warn', live forward-progress phases → 'active'.
 *
 *  Exhaustive over `KeeperKsmPhase`. If TypeScript reports a missing
 *  case after adding a new variant, route it to the appropriate tone —
 *  do not add a `default:` (RFC-0135 §9-4 forbids catch-all). */
export function compositePhaseTone(phase: KeeperKsmPhase): 'active' | 'warn' | 'err' {
  switch (phase) {
    case 'offline':
    case 'running':
      return 'active'
    case 'overflowed':
    case 'compacting':
    case 'handing_off':
    case 'draining':
    case 'paused':
    case 'restarting':
      return 'warn'
    case 'failing':
    case 'stopped':
    case 'crashed':
    case 'dead':
    case 'zombie':
      return 'err'
  }
}

/** Composite snapshot is in the "running" KSM bucket. Mirrors the
 *  semantic of `state.kind === 'running'` for typed-keeper SSOT but
 *  operates on the lowercase wire format from composite snapshots. */
export function compositeIsRunning(snapshot: { phase: string }): boolean {
  return snapshot.phase === 'running'
}

/** Composite snapshot is in the "idle" KTC turn-phase bucket.
 *  Lowercase wire format. */
export function compositeIsTurnIdle(snapshot: { turn_phase: string }): boolean {
  return snapshot.turn_phase === 'idle'
}

// RFC-0135 PR-14c — display reason SSOT (Goal-2c typed-state expansion).
//
// `keeper-detail-runtime.ts:257-264` inlined a 3-way fallback for the
// "runtime reason" detail line:
//   composite.runtime_attention.reason
//   ?? keeper.runtime_blocker_summary
//   ?? keeper.attention_reason
//   ?? null
// The same precedence is needed by the alert strip and the agent
// roster, and inlining the chain at each callsite makes it easy for
// a future field to be added in one place but missed in another.

/** Live display reason string for the current attention/blocker state,
 *  with composite-preferred precedence. Returns `null` when no source
 *  has a non-empty trimmed value — caller supplies the display fallback. */
export function deriveKeeperDisplayReason(
  keeper: Pick<Keeper, 'runtime_blocker_summary' | 'attention_reason'>,
  composite: KeeperCompositeSnapshot | null,
): string | null {
  const trim = (raw: unknown): string | null =>
    typeof raw === 'string' && raw.trim().length > 0 ? raw : null
  return (
    trim(composite?.runtime_attention?.reason)
    ?? trim(keeper.runtime_blocker_summary)
    ?? trim(keeper.attention_reason)
    ?? null
  )
}

// RFC-0135 PR-14b — turn-phase SSOT (Goal-2b typed-state expansion).
//
// `keeper-detail-runtime.ts:194-195` (and one earlier 3-way fallback
// removed by PR-5) read turn phase via composite-or-flat fallback:
//   `compositeSnapshot?.turn_phase ?? keeper.pipeline_stage`
// The two sources have different semantics (composite is the *live*
// KTC turn cycle from backend; pipeline_stage is the flat-record
// snapshot of the prior turn) but downstream consumers treat them as
// interchangeable strings. Centralizing the fallback policy here lets
// future consumers (Goal-2c displaySummary, Goal-2d phase) reuse the
// same precedence without re-reading raw composite fields.
//
// Precedence (composite preferred):
//   1. composite.turn_phase if composite present
//   2. keeper.pipeline_stage (flat record fallback)
//   3. null (no signal available)

/** Live turn phase, preferring composite SSE stream over flat record.
 *  Returns `null` when no source has a value. Caller-side `??` against
 *  a literal default (e.g. `'idle'`) is the supported fallback shape
 *  — do not embed display defaults here. */
export function deriveKeeperTurnPhase(
  keeper: Pick<Keeper, 'pipeline_stage'>,
  composite: KeeperCompositeSnapshot | null,
): string | null {
  const compositeTurn = composite?.turn_phase
  if (typeof compositeTurn === 'string' && compositeTurn.length > 0) return compositeTurn
  const flatStage: PipelineStage | undefined = keeper.pipeline_stage
  if (typeof flatStage === 'string' && flatStage.length > 0) return flatStage
  return null
}

// RFC-0135 PR-14d — composite-preferred phase SSOT (Goal-2d).
//
// Two phase sources exist on the wire:
//   - `composite.phase` (lowercase, live KSM wire format)
//   - `keeper.phase` (PascalCase, flat-record snapshot)
// `monitoring-runtime.ts:keeperPhaseForDisplay` previously consumed
// only `keeper.phase`, leaving composite-fresh phase signals unused
// when a composite snapshot was available. This helper centralizes
// the precedence so `monitoring-runtime` and `agent-roster` see the
// same phase for the same keeper.

/** Composite-preferred `KeeperPhase`. Returns the typed PascalCase
 *  value from composite if present and narrow-able, else from the
 *  flat record, else `null`. */
export function derivePreferredPhase(
  keeper: Pick<Keeper, 'phase'>,
  composite: KeeperCompositeSnapshot | null,
): KeeperPhase | null {
  const compositePhase = composite?.phase
  if (typeof compositePhase === 'string' && compositePhase.length > 0) {
    const narrowed = toKeeperPhase(compositePhase)
    if (narrowed !== null) return narrowed
  }
  return toKeeperPhase(keeper.phase)
}
