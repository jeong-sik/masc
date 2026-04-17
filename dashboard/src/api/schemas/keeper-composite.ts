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
  safeParse,
  string,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

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

const KeeperCompositeAutoRulesSchema = object({
  reflect: boolean(),
  plan: boolean(),
  compact: boolean(),
  handoff: boolean(),
  guardrail_stop: boolean(),
  guardrail_reason: nullable(string()),
  goal_drift: number(),
})

export const KeeperCompositeMeasurementSchema = object({
  captured: boolean(),
  auto_rules: optional(KeeperCompositeAutoRulesSchema),
})

export const KeeperCompositeInvariantsSchema = object({
  phase_turn_alignment: boolean(),
  no_cascade_before_measurement: boolean(),
  compaction_atomicity: boolean(),
  event_priority_monotone: boolean(),
})

export const KeeperLastOutcomeSchema = object({
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
  turn_phase: KeeperCompositeTurnPhaseSchema,
  decision: object({ stage: KeeperCompositeDecisionStageSchema }),
  cascade: object({ state: KeeperCompositeCascadeStateSchema }),
  compaction: object({ stage: KeeperCompositeCompactionStageSchema }),
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

export class CompositeSchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  constructor(issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .slice(0, 3)
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`composite schema drift: ${summary}`)
    this.name = 'CompositeSchemaDriftError'
    this.issues = issues
  }
}

export function parseKeeperCompositeSnapshot(data: unknown): KeeperCompositeSnapshot {
  const result = safeParse(KeeperCompositeSnapshotSchema, data)
  if (!result.success) {
    throw new CompositeSchemaDriftError(result.issues)
  }
  return result.output
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
  const result = safeParse(FleetCompositeSnapshotSchema, data)
  if (!result.success) {
    throw new CompositeSchemaDriftError(result.issues)
  }
  return result.output
}
