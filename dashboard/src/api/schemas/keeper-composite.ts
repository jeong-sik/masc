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

import * as v from 'valibot'

const KeeperCompositePhaseSchema = v.fallback(
  v.picklist([
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

const KeeperCompositeTurnPhaseSchema = v.fallback(
  v.picklist(['idle', 'prompting', 'executing', 'compacting', 'finalizing']),
  'idle',
)

const KeeperCompositeDecisionStageSchema = v.fallback(
  v.picklist(['undecided', 'guard_ok', 'gate_rejected', 'tool_policy_selected']),
  'undecided',
)

const KeeperCompositeCascadeStateSchema = v.fallback(
  v.picklist(['idle', 'selecting', 'trying', 'done', 'exhausted']),
  'idle',
)

const KeeperCompositeCompactionStageSchema = v.fallback(
  v.picklist(['accumulating', 'compacting', 'done']),
  'accumulating',
)

const KeeperCompositeAutoRulesSchema = v.object({
  reflect: v.boolean(),
  plan: v.boolean(),
  compact: v.boolean(),
  handoff: v.boolean(),
  guardrail_stop: v.boolean(),
  guardrail_reason: v.nullable(v.string()),
  goal_drift: v.number(),
})

export const KeeperCompositeMeasurementSchema = v.object({
  captured: v.boolean(),
  auto_rules: v.optional(KeeperCompositeAutoRulesSchema),
})

export const KeeperCompositeInvariantsSchema = v.object({
  phase_turn_alignment: v.boolean(),
  no_cascade_before_measurement: v.boolean(),
  compaction_atomicity: v.boolean(),
  event_priority_monotone: v.boolean(),
})

export const KeeperLastOutcomeSchema = v.object({
  turn_id: v.number(),
  ended_at: v.number(),
  decision_stage: KeeperCompositeDecisionStageSchema,
  cascade_state: KeeperCompositeCascadeStateSchema,
  selected_model: v.nullable(v.string()),
})

export const KeeperCompositeSnapshotSchema = v.object({
  correlation_id: v.string(),
  run_id: v.string(),
  ts: v.number(),
  phase: KeeperCompositePhaseSchema,
  turn_phase: KeeperCompositeTurnPhaseSchema,
  decision: v.object({ stage: KeeperCompositeDecisionStageSchema }),
  cascade: v.object({ state: KeeperCompositeCascadeStateSchema }),
  compaction: v.object({ stage: KeeperCompositeCompactionStageSchema }),
  measurement: KeeperCompositeMeasurementSchema,
  invariants: KeeperCompositeInvariantsSchema,
  is_live: v.boolean(),
  last_outcome: v.nullable(KeeperLastOutcomeSchema),
})

export type KeeperCompositeSnapshot = v.InferOutput<typeof KeeperCompositeSnapshotSchema>
export type KeeperCompositeInvariants = v.InferOutput<typeof KeeperCompositeInvariantsSchema>
export type KeeperCompositeMeasurement = v.InferOutput<typeof KeeperCompositeMeasurementSchema>
export type KeeperLastOutcome = v.InferOutput<typeof KeeperLastOutcomeSchema>
export type KeeperCompositePhase = v.InferOutput<typeof KeeperCompositePhaseSchema>
export type KeeperCompositeTurnPhase = v.InferOutput<typeof KeeperCompositeTurnPhaseSchema>
export type KeeperCompositeDecisionStage = v.InferOutput<typeof KeeperCompositeDecisionStageSchema>
export type KeeperCompositeCascadeState = v.InferOutput<typeof KeeperCompositeCascadeStateSchema>
export type KeeperCompositeCompactionStage = v.InferOutput<typeof KeeperCompositeCompactionStageSchema>

export class CompositeSchemaDriftError extends Error {
  readonly issues: readonly v.BaseIssue<unknown>[]
  constructor(issues: readonly v.BaseIssue<unknown>[]) {
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
  const result = v.safeParse(KeeperCompositeSnapshotSchema, data)
  if (!result.success) {
    throw new CompositeSchemaDriftError(result.issues)
  }
  return result.output
}
