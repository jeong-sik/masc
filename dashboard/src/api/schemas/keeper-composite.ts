/**
 * Keeper composite snapshot schema — the single source of truth for the
 * `/api/v1/keepers/:name/composite` response shape on the dashboard side.
 *
 * Contract (see dashboard/docs/API_CONTRACT.md):
 * - TS types are derived via `InferOutput<typeof Schema>` — no hand-typed
 *   interface for this endpoint.
 * - `fetchKeeperComposite` MUST pass the raw response through `v.parse`.
 *   Shape drift from the backend (`keeper_composite_observer.ml`
 *   `snapshot_to_json`) raises `CompositeSchemaDriftError`, not
 *   `undefined` access downstream.
 * - Backward tolerance is expressed explicitly here with `v.optional` /
 *   `v.fallback`, not in a post-hoc normalizer buried elsewhere.
 *
 * History: after PR #7334 removed manual_reconcile, the backend stopped
 * emitting `recovery` and `recovery_two_store_sync`. #7412 patched the
 * gap with a hand-rolled normalizer; this schema pilot (#7439) replaces
 * that normalizer with an explicit contract.
 */

import {
  array,
  boolean,
  fallback,
  nullable,
  number,
  object,
  optional,
  picklist,
  string,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'

// The FSM enums below use `fallback` (not hard-rejection) because
// Keeper state machines evolve asymmetrically: the OCaml backend
// (`keeper_composite_observer.ml`) can ship a new state variant in a
// release ahead of the dashboard. Hard-failing the parse would brick
// the entire operator view for the window between backend-deploy and
// frontend-deploy. The fallback state is intentionally the safest
// visible default — "Stable" / "idle" / "undecided" — so an unknown
// value renders as "nothing happening" rather than a misleading live
// state. When backend adds a new enum member, this file must be
// updated in the next dashboard release; the fallback buys time, not
// permanent tolerance. See docs/API_CONTRACT.md §Drift policy.

const KeeperCompositePhaseSchema = fallback(
  picklist([
    'Running',
    'Failing',
    'Overflowed',
    'Compacting',
    'HandingOff',
    'Draining',
    'Stable',
  ]),
  'Stable',
)

const KeeperCompositeTurnPhaseSchema = fallback(
  picklist(['idle', 'prompting', 'executing', 'compacting', 'finalizing']),
  'idle',
)

const KeeperCompositeDecisionStageSchema = fallback(
  picklist(['undecided', 'guard_ok', 'gate_rejected', 'tool_policy_selected']),
  'undecided',
)

const KeeperCompositeCascadeStateSchema = fallback(
  picklist(['idle', 'selecting', 'trying', 'done', 'exhausted']),
  'idle',
)

const KeeperCompositeCompactionStageSchema = fallback(
  picklist(['accumulating', 'compacting', 'done']),
  'accumulating',
)

// LT-16-KCB Phase 3: 6th axis. KCB is counter-based, not a classical
// Closed/Open/Half_open FSM — only three states are observable between
// tool calls because `record_failure` resets `consecutive_count` to 0
// inside the trip transition. See
// `lib/keeper/keeper_failure_circuit_breaker.mli`.
const KeeperCompositeCircuitBreakerStateSchema = fallback(
  picklist(['clean', 'warning', 'cooling']),
  'clean',
)

const KeeperCompositeAutoRulesSchema = object({
  reflect: boolean(),
  plan: boolean(),
  compact: boolean(),
  handoff: boolean(),
  guardrail_stop: boolean(),
  guardrail_reason: nullable(string()),
  goal_drift: number(),
})

const KeeperCompositeMeasurementSchema = object({
  captured: boolean(),
  auto_rules: optional(KeeperCompositeAutoRulesSchema),
})

const KeeperCompositeInvariantsSchema = object({
  phase_turn_alignment: boolean(),
  no_cascade_before_measurement: boolean(),
  compaction_atomicity: boolean(),
  event_priority_monotone: boolean(),
})

const KeeperLastOutcomeSchema = object({
  turn_id: number(),
  ended_at: number(),
  decision_stage: KeeperCompositeDecisionStageSchema,
  cascade_state: KeeperCompositeCascadeStateSchema,
  selected_model: nullable(string()),
})

export const KeeperCompositeSnapshotSchema = object({
  correlation_id: string(),
  run_id: string(),
  ts: number(),
  phase: KeeperCompositePhaseSchema,
  collapsed_from: optional(nullable(string())),
  turn_phase: KeeperCompositeTurnPhaseSchema,
  decision: object({ stage: KeeperCompositeDecisionStageSchema }),
  cascade: object({ state: KeeperCompositeCascadeStateSchema }),
  compaction: object({ stage: KeeperCompositeCompactionStageSchema }),
  // `circuit_breaker` is `optional` during the Phase 2 → Phase 3
  // rollout window: pinned backends that have not yet picked up
  // PR #7801 emit snapshots without this key, and the dashboard must
  // keep rendering instead of hard-failing the parse. Once the
  // backend pin catches up everywhere, a follow-up can drop
  // `optional` (promote the key to required with the `clean` fallback
  // alone).
  circuit_breaker: optional(
    object({ state: KeeperCompositeCircuitBreakerStateSchema }),
  ),
  measurement: KeeperCompositeMeasurementSchema,
  invariants: KeeperCompositeInvariantsSchema,
  is_live: boolean(),
  last_outcome: nullable(KeeperLastOutcomeSchema),
})

export type KeeperCompositeSnapshot = InferOutput<typeof KeeperCompositeSnapshotSchema>
export type KeeperCompositeInvariants = InferOutput<typeof KeeperCompositeInvariantsSchema>
export type KeeperCompositeMeasurement = InferOutput<typeof KeeperCompositeMeasurementSchema>
export type KeeperLastOutcome = InferOutput<typeof KeeperLastOutcomeSchema>
export type KeeperCompositePhase = InferOutput<typeof KeeperCompositePhaseSchema>
export type KeeperCompositeTurnPhase = InferOutput<typeof KeeperCompositeTurnPhaseSchema>
export type KeeperCompositeDecisionStage = InferOutput<typeof KeeperCompositeDecisionStageSchema>
export type KeeperCompositeCascadeState = InferOutput<typeof KeeperCompositeCascadeStateSchema>
export type KeeperCompositeCompactionStage = InferOutput<typeof KeeperCompositeCompactionStageSchema>

export class CompositeSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('composite', issues)
  }
}

export function parseKeeperCompositeSnapshot(data: unknown): KeeperCompositeSnapshot {
  return parseOrThrow(CompositeSchemaDriftError, KeeperCompositeSnapshotSchema, data)
}

// ── Fleet composite (LT-16a) ─────────────────────────────
//
// Backend: GET /api/v1/keepers/composite returns every registered
// keeper in one envelope. Reuses the per-keeper snapshot shape so the
// matrix UI (LT-16b, dashboard/src/components/fleet-fsm-matrix.ts) can
// share render logic between single-keeper detail and fleet views.
//
// Each poll bumps the masc_keeper_invariant_violations_total counter
// for any violating keeper (documented poll-triggered behaviour,
// docs/observability/cascade-metrics.md §masc_keeper_invariant_violations_total).

export const FleetCompositeSnapshotSchema = object({
  generated_at: number(),
  count: number(),
  snapshots: array(KeeperCompositeSnapshotSchema),
})

export type FleetCompositeSnapshot = InferOutput<typeof FleetCompositeSnapshotSchema>

export function parseFleetCompositeSnapshot(data: unknown): FleetCompositeSnapshot {
  return parseOrThrow(CompositeSchemaDriftError, FleetCompositeSnapshotSchema, data)
}
