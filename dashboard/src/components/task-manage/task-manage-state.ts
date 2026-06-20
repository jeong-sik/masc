import { signal } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { refreshExecution, refreshGoals } from '../../store'
import { errorToString } from '../../lib/format-string'

export const showTaskCreate = signal(false)
export const taskCreating = signal(false)

interface TaskCreateInput {
  title: string
  description: string
  priority?: number
  goal_id?: string | null
}

export async function createTask(input: TaskCreateInput): Promise<boolean> {
  if (!input.title.trim()) { showToast('제목을 입력하세요', 'error'); return false }
  taskCreating.value = true
  try {
    const args: Record<string, unknown> = { title: input.title.trim(), description: input.description.trim() }
    if (input.priority) args.priority = input.priority
    if (input.goal_id?.trim()) args.goal_id = input.goal_id.trim()
    await callMcpTool('masc_add_task', args)
    showToast('태스크 생성 완료', 'success')
    showTaskCreate.value = false
    await Promise.all([
      refreshExecution({ force: true }),
      refreshGoals(),
    ])
    return true
  } catch (err) {
    showToast(`태스크 생성 실패: ${errorToString(err)}`, 'error')
    return false
  } finally {
    taskCreating.value = false
  }
}

// RFC-0267 Phase 2: assign an existing goalless task to a goal. Goes through the
// masc_task_set_goal MCP tool (the same callMcpTool path createTask uses); the
// backend rejects an unknown id or an already-assigned task, surfaced as a toast.
export async function assignTaskToGoal(taskId: string, goalId: string): Promise<boolean> {
  if (!taskId.trim() || !goalId.trim()) return false
  try {
    await callMcpTool('masc_task_set_goal', { task_id: taskId, goal_id: goalId })
    showToast('목표에 배정 완료', 'success')
    await Promise.all([
      refreshExecution({ force: true }),
      refreshGoals(),
    ])
    return true
  } catch (err) {
    showToast(`목표 배정 실패: ${errorToString(err)}`, 'error')
    return false
  }
}
