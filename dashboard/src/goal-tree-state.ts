import { signal } from '@preact/signals'

import { decodeKeeperApprovalQueueState } from './api/dashboard-gate'
import { DashboardGoalsApprovalQueueUnavailableError } from './api/dashboard-goals'
import type { DashboardGoalsTreeResponse, KeeperApprovalQueueState } from './types'

export const goalTreeData = signal<DashboardGoalsTreeResponse | null>(null)
export const goalTreeLoading = signal(false)
export const goalTreeError = signal<string | null>(null)
export const goalTreeApprovalQueueState = signal<KeeperApprovalQueueState | null>(null)

function applyUnavailableState(
  state: Extract<KeeperApprovalQueueState, { state: 'unavailable' }>,
): void {
  goalTreeApprovalQueueState.value = state
  goalTreeData.value = null
  goalTreeError.value = `${state.icon} ${state.title}: ${state.operator_detail}`
  goalTreeLoading.value = false
}

export function hydrateGoalTreeError(error: unknown): boolean {
  if (!(error instanceof DashboardGoalsApprovalQueueUnavailableError)) return false
  applyUnavailableState(error.approval_queue_state)
  return true
}

export function hydrateGoalTreeSnapshot(payload: unknown): boolean {
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
  goalTreeData.value = {
    ...candidate,
    approval_queue_state: approvalQueueState,
  } as DashboardGoalsTreeResponse
  goalTreeError.value = null
  goalTreeLoading.value = false
  return true
}
