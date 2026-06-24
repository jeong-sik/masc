// Goal creation state and async action — mirrors task-manage-state.ts idiom.
// RFC-0294: horizon is no longer a top-level view axis, but the prototype
// keeps it as a creation-time planning attribute. The backend currently
// rejects unknown keys (additionalProperties: false), so horizon and
// lead_keeper are collected in the UI but not sent until the backend schema
// is updated. See docs/superpowers/plans/2026-06-24-masc-goal-task-dashboard-implementation.md.

import { signal } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { refreshGoals } from '../../store'
import { errorToString } from '../../lib/format-string'

export const GOAL_PRIORITY_MIN = 1
export const GOAL_PRIORITY_MAX = 5
export const GOAL_PRIORITY_DEFAULT = 3

export type GoalHorizon = 'short' | 'medium' | 'long'

export const GOAL_HORIZONS: GoalHorizon[] = ['short', 'medium', 'long']

export const GOAL_HORIZON_LABELS: Record<GoalHorizon, string> = {
  short: '단기',
  medium: '중기',
  long: '장기',
}

export const showGoalCreate = signal(false)
export const goalCreating = signal(false)
export const goalCreateError = signal<string | null>(null)

export interface GoalCreateInput {
  title: string
  priority: number
  require_completion_approval: boolean
  horizon?: GoalHorizon
  lead_keeper?: string | null
}

export async function createGoal(input: GoalCreateInput): Promise<boolean> {
  const trimmedTitle = input.title.trim()
  if (!trimmedTitle) {
    goalCreateError.value = '제목을 입력하세요'
    return false
  }
  goalCreating.value = true
  goalCreateError.value = null
  try {
    const args: Record<string, unknown> = {
      title: trimmedTitle,
      priority: input.priority,
    }
    if (input.require_completion_approval) {
      args.require_completion_approval = true
    }
    // Backend compatibility gate: masc_goal_upsert currently rejects unknown
    // keys. Do not send horizon/lead_keeper until the backend schema accepts
    // them. Set ENABLE_NEW_GOAL_FIELDS to true after verifying the backend.
    const ENABLE_NEW_GOAL_FIELDS = false
    if (ENABLE_NEW_GOAL_FIELDS) {
      if (input.horizon) args.horizon = input.horizon
      if (input.lead_keeper) args.lead_keeper = input.lead_keeper
    }
    await callMcpTool('masc_goal_upsert', args)
    showToast('목표 생성 완료', 'success')
    showGoalCreate.value = false
    await refreshGoals()
    return true
  } catch (err) {
    const message = errorToString(err)
    goalCreateError.value = message
    showToast(`목표 생성 실패: ${message}`, 'error')
    return false
  } finally {
    goalCreating.value = false
  }
}

export function resetGoalCreateForm(): void {
  goalCreateError.value = null
}
