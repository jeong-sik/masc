export type GoalCriterionReviewWaitingState =
  | 'pending'
  | 'execution_pending'
  | 'execution_unknown'
  | 'judgment_pending'
  | 'deferred'
  | 'superseded'

type CriterionReviewBinding = {
  criterion_revision: string
  request_id: string
  detail: string | null
}

/** Creation-criterion feasibility review. This never proves completion. */
export type GoalCriterionReviewProjection =
  | { state: 'unchecked' }
  | { state: 'unavailable'; detail: string }
  | (CriterionReviewBinding & { state: GoalCriterionReviewWaitingState; reason: null })
  | (CriterionReviewBinding & { state: 'viable' | 'needs_revision'; reason: string })
