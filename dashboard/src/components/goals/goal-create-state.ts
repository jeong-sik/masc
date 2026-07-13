// Goal creation state and async action — mirrors task-manage-state.ts idiom.
// RFC-0294 removed horizon from the live Goal contract. Keep this payload
// aligned with masc_goal_upsert's accepted schema; do not collect or stage
// fields the backend cannot persist.

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

export type GoalCreateError =
  | { kind: 'title_empty' }
  | { kind: 'submit'; message: string }

export const goalCreateError = signal<GoalCreateError | null>(null)

export interface GoalCreateInput {
  title: string
  priority: number
}

export function goalCreateErrorMessage(err: GoalCreateError | null): string | null {
  if (err === null) return null
  if (err.kind === 'title_empty') return '제목을 입력하세요'
  return err.message
}

export async function createGoal(input: GoalCreateInput): Promise<boolean> {
  const trimmedTitle = input.title.trim()
  if (!trimmedTitle) {
    goalCreateError.value = { kind: 'title_empty' }
    return false
  }
  goalCreating.value = true
  goalCreateError.value = null
  try {
    const args: Record<string, unknown> = {
      title: trimmedTitle,
      priority: input.priority,
    }
    await callMcpTool('masc_goal_upsert', args)
    showToast('목표 생성 완료', 'success')
    showGoalCreate.value = false
    await refreshGoals()
    return true
  } catch (err) {
    const message = errorToString(err)
    goalCreateError.value = { kind: 'submit', message }
    showToast(`목표 생성 실패: ${message}`, 'error')
    return false
  } finally {
    goalCreating.value = false
  }
}

export function resetGoalCreateForm(): void {
  goalCreateError.value = null
}
