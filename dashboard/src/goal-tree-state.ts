import { signal } from '@preact/signals'

import type { DashboardGoalsTreeResponse } from './types'

export const goalTreeData = signal<DashboardGoalsTreeResponse | null>(null)
export const goalTreeLoading = signal(false)
export const goalTreeError = signal<string | null>(null)

export function hydrateGoalTreeSnapshot(payload: unknown): boolean {
  if (!payload || typeof payload !== 'object') return false
  const candidate = payload as Partial<DashboardGoalsTreeResponse>
  if (!Array.isArray(candidate.tree) || !candidate.summary || typeof candidate.summary !== 'object') {
    return false
  }
  goalTreeData.value = candidate as DashboardGoalsTreeResponse
  goalTreeError.value = null
  goalTreeLoading.value = false
  return true
}
