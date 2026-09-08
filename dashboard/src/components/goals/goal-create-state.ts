// Goal creation state and async action — mirrors task-manage-state.ts idiom.
// Keep this payload aligned with masc_goal_upsert's accepted schema; do not
// collect or stage fields the backend cannot persist.

import { signal } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { refreshGoals } from '../../store'
import { errorToString } from '../../lib/format-string'

export const GOAL_PRIORITY_MIN = 1
export const GOAL_PRIORITY_MAX = 5
export const GOAL_PRIORITY_DEFAULT = 3

export const showGoalCreate = signal(false)
export const goalCreating = signal(false)

// A dismissed draft cannot be changed by a request it already submitted.
let draftToken = Symbol('goal-create-draft')
export function currentGoalCreateDraft(): symbol { return draftToken }

export type GoalCreateError =
  | { kind: 'title_empty' }
  | { kind: 'metric_empty' }
  | { kind: 'target_empty' }
  | { kind: 'submit'; message: string }

export const goalCreateError = signal<GoalCreateError | null>(null)

export interface GoalCreateInput {
  title: string
  metric: string
  targetValue: string
  priority: number
}

export function goalCreateErrorMessage(err: GoalCreateError | null): string | null {
  if (err === null) return null
  switch (err.kind) {
    case 'title_empty': return '제목을 입력하세요'
    case 'metric_empty': return '측정 지표를 입력하세요'
    case 'target_empty': return '목표 값을 입력하세요'
    case 'submit': return err.message
  }
}

export async function createGoal(input: GoalCreateInput): Promise<boolean> {
  const owner = draftToken
  const trimmedTitle = input.title.trim()
  if (!trimmedTitle) {
    goalCreateError.value = { kind: 'title_empty' }
    return false
  }
  const metric = input.metric.trim()
  if (!metric) {
    goalCreateError.value = { kind: 'metric_empty' }
    return false
  }
  const targetValue = input.targetValue.trim()
  if (!targetValue) {
    goalCreateError.value = { kind: 'target_empty' }
    return false
  }
  goalCreating.value = true
  goalCreateError.value = null
  try {
    const args: Record<string, unknown> = {
      title: trimmedTitle,
      metric,
      target_value: targetValue,
      priority: input.priority,
    }
    await callMcpTool('masc_goal_upsert', args)
    showToast('목표 생성 완료', 'success')
    if (owner === draftToken) showGoalCreate.value = false
    await refreshGoals()
    return true
  } catch (err) {
    const message = errorToString(err)
    if (owner === draftToken) goalCreateError.value = { kind: 'submit', message }
    showToast(`목표 생성 실패: ${message}`, 'error')
    return false
  } finally {
    if (owner === draftToken) goalCreating.value = false
  }
}

export function resetGoalCreateForm(): void {
  draftToken = Symbol('goal-create-draft')
  goalCreating.value = false
  goalCreateError.value = null
}
