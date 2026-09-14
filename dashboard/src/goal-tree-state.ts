import { signal } from '@preact/signals'

import { decodeKeeperApprovalQueueState } from './api/dashboard-gate'
import {
  DashboardGoalsApprovalQueueUnavailableError,
  GoalSourceUnavailableError,
  goalSourceUnavailable,
} from './api/dashboard-goals'
import { goalStoreUnavailableSummary } from './lib/goal-store-unavailable-labels'
import type {
  DashboardGoalsTreeResponse,
  GoalSourceUnavailable,
  GoalStoreUnavailable,
  KeeperApprovalQueueState,
} from './types'

export const goalTreeData = signal<DashboardGoalsTreeResponse | null>(null)
export const goalTreeLoading = signal(false)
export const goalTreeError = signal<string | null>(null)
export const goalTreeApprovalQueueState = signal<KeeperApprovalQueueState | null>(null)
/**
 * RFC-0444 §2.3 row 4: the parsed Goal store failure, kept beside the rendered
 * line so the Goal tree can draw file · reason · reset step and the create
 * form can refuse submission. Null whenever the last observation was not a
 * `goal_store_unavailable` envelope.
 */
export const goalStoreUnavailable = signal<GoalStoreUnavailable | null>(null)

function applyUnavailableState(
  state: Extract<KeeperApprovalQueueState, { state: 'unavailable' }>,
): void {
  goalTreeApprovalQueueState.value = state
  goalStoreUnavailable.value = null
  goalTreeData.value = null
  goalTreeError.value = `${state.icon} ${state.title}: ${state.operator_detail}`
  goalTreeLoading.value = false
}

export function hydrateGoalSourceUnavailable(unavailable: GoalSourceUnavailable): void {
  goalTreeApprovalQueueState.value = null
  goalTreeData.value = null
  goalTreeLoading.value = false
  switch (unavailable.kind) {
    case 'unavailable':
      goalStoreUnavailable.value = unavailable
      goalTreeError.value = goalStoreUnavailableSummary(unavailable)
      return
    case 'links_unavailable':
      goalStoreUnavailable.value = null
      goalTreeError.value = unavailable.detail
      return
    default: {
      const unhandled: never = unavailable
      return unhandled
    }
  }
}

export function hydrateGoalTreeError(error: unknown): boolean {
  if (error instanceof GoalSourceUnavailableError) {
    hydrateGoalSourceUnavailable(error.unavailable)
    return true
  }
  if (!(error instanceof DashboardGoalsApprovalQueueUnavailableError)) return false
  applyUnavailableState(error.approval_queue_state)
  return true
}

export function hydrateGoalTreeObservationError(error: unknown): void {
  const detail = error instanceof Error
    ? error.message
    : typeof error === 'string' && error.length > 0
      ? error
      : 'Goal tree observation failed'
  goalTreeApprovalQueueState.value = null
  goalStoreUnavailable.value = null
  goalTreeData.value = null
  goalTreeError.value = detail
  goalTreeLoading.value = false
}

export function hydrateGoalTreeSnapshot(payload: unknown): boolean {
  const unavailable = goalSourceUnavailable(payload)
  if (unavailable !== null) {
    hydrateGoalSourceUnavailable(unavailable)
    return true
  }
  if (!payload || typeof payload !== 'object') return false
  const candidate = payload as Partial<DashboardGoalsTreeResponse> & {
    approval_queue_state?: unknown
  }
  const approvalQueueState = decodeKeeperApprovalQueueState(candidate.approval_queue_state)
  if (!approvalQueueState) return false
  if (approvalQueueState.state === 'unavailable') {
    if (candidate.tree !== null || candidate.summary !== null) return false
    applyUnavailableState(approvalQueueState)
    return true
  }
  if (!Array.isArray(candidate.tree) || !candidate.summary || typeof candidate.summary !== 'object') {
    return false
  }
  goalTreeApprovalQueueState.value = approvalQueueState
  goalStoreUnavailable.value = null
  goalTreeData.value = {
    ...candidate,
    approval_queue_state: approvalQueueState,
  } as DashboardGoalsTreeResponse
  goalTreeError.value = null
  goalTreeLoading.value = false
  return true
}
