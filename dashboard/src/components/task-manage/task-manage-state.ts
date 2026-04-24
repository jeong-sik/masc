import { signal } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { refreshExecution, refreshGoals } from '../../store'

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
    showToast(`태스크 생성 실패: ${err instanceof Error ? err.message : String(err)}`, 'error')
    return false
  } finally {
    taskCreating.value = false
  }
}
