import { signal } from '@preact/signals'
import { callMcpTool, callMcpToolAtIdentity, mcpCallFailureDisposition } from '../../api/mcp'
import { showToast } from '../common/toast'
import { refreshExecution, refreshGoals } from '../../store'
import { errorToString } from '../../lib/format-string'
import { isCanonicalGoalId } from '../../lib/goal-identity'
import { artifactWorkspaceBody, type ArtifactWorkspace } from '../../api/published-artifacts'
import { isRecord } from '../common/normalize'

export const showTaskCreate = signal(false)
export const taskCreating = signal(false)

interface TaskCreateInput {
  title: string
  description: string
  priority?: number
  goal_id?: string | null
}

export type GoalTaskDispatch = {
  readonly workspace: ArtifactWorkspace
  readonly identity: { readonly revision: number; readonly actor: string }
  readonly isCurrent: () => boolean
  readonly isRecoveryCurrent?: () => boolean
  readonly waitForRecoveryCurrent?: () => Promise<boolean>
}

export type GoalAssignmentDispatch = GoalTaskDispatch & {
  readonly isOwnerCurrent: () => boolean
  readonly refreshAfterWrite: () => boolean
}

export async function createTask(input: TaskCreateInput, goalDispatch?: GoalTaskDispatch): Promise<boolean> {
  if (!input.title.trim()) { showToast('제목을 입력하세요', 'error'); return false }
  const linkedGoalId = input.goal_id ?? null
  if (linkedGoalId !== null && (!isCanonicalGoalId(linkedGoalId) || !goalDispatch || !goalDispatch.isCurrent())) {
    showToast('현재 Goal을 다시 확인한 뒤 태스크를 연결해 주세요.', 'warning')
    return false
  }
  taskCreating.value = true
  try {
    const args: Record<string, unknown> = { title: input.title.trim(), description: input.description.trim() }
    if (input.priority) args.priority = input.priority
    if (linkedGoalId !== null && goalDispatch) {
      args.goal_id = linkedGoalId
      args.expected_workspace = artifactWorkspaceBody(goalDispatch.workspace)
      await callMcpToolAtIdentity('masc_add_task', args, goalDispatch.identity, goalDispatch.isCurrent,
        goalDispatch.isRecoveryCurrent, goalDispatch.waitForRecoveryCurrent)
    } else {
      await callMcpTool('masc_add_task', args)
    }
    if (linkedGoalId !== null && !goalDispatch?.isCurrent()) {
      showToast('이전 요청의 태스크 생성 응답이 도착했습니다. 요청한 workspace에서 결과를 확인해 주세요.', 'warning')
      return true
    }
    showToast('태스크 생성 완료', 'success')
    showTaskCreate.value = false
    await Promise.all([
      refreshExecution({ force: true }),
      refreshGoals(),
    ]).catch(error => {
      // The write already committed; its refresh error is visible in the store.
      console.warn('[Tasks] post-write observation refresh failed:', error)
    })
    return true
  } catch (err) {
    if (linkedGoalId !== null) {
      const disposition = mcpCallFailureDisposition(err)
      if (!goalDispatch?.isCurrent()) {
        showToast('이전 요청의 결과가 도착했습니다. 요청한 workspace에서 Goal과 Task 상태를 확인해 주세요.', 'warning')
      } else if (disposition === 'known_pre_effect') {
        showToast('태스크 생성 전에 요청이 거부되었습니다. workspace와 Goal을 다시 확인해 주세요.', 'warning')
      } else if (disposition === 'known_tool_response') {
        showToast('서버가 오류를 반환했으며 일부 변경이 적용됐을 수 있습니다. 요청한 workspace의 Goal과 Task를 확인한 뒤 다시 요청해 주세요.', 'warning')
      } else {
        showToast('태스크 생성 결과를 확인할 수 없습니다. 다시 요청하면 중복될 수 있으니 요청한 workspace의 Goal과 Task를 확인해 주세요.', 'warning')
      }
    } else {
      showToast(`태스크 생성 실패: ${errorToString(err)}`, 'error')
    }
    return false
  } finally {
    taskCreating.value = false
  }
}

// Assign using the Goal observation's workspace and the caller's dispatch guard.
export async function assignTaskToGoal(taskId: string, goalId: string, dispatch: GoalAssignmentDispatch): Promise<boolean> {
  if (!taskId.trim() || !isCanonicalGoalId(goalId) || !dispatch.isCurrent()) return false
  try {
    const response = await callMcpToolAtIdentity('masc_task_set_goal', { task_id: taskId, goal_id: goalId,
      expected_workspace: artifactWorkspaceBody(dispatch.workspace) }, dispatch.identity, dispatch.isCurrent,
    dispatch.isRecoveryCurrent, dispatch.waitForRecoveryCurrent)
    const receipt: unknown = JSON.parse(response)
    if (!isRecord(receipt) || receipt.ok !== true || receipt.task_id !== taskId || receipt.goal_id !== goalId) {
      throw new Error('Assignment response does not match the request')
    }
    const sameOwner = dispatch.isOwnerCurrent()
    dispatch.refreshAfterWrite()
    if (!sameOwner) {
      showToast('이전 관측의 배정 요청이 처리되었습니다. 요청한 workspace에서 Goal과 Task를 확인해 주세요.', 'warning')
      return true
    }
    showToast('목표에 배정 완료', 'success')
    await refreshExecution({ force: true }).catch(error => {
      // The write already committed; its refresh error is visible in the store.
      console.warn('[Tasks] post-write observation refresh failed:', error)
    })
    return true
  } catch (err) {
    const disposition = mcpCallFailureDisposition(err)
    const sameOwner = dispatch.isOwnerCurrent()
    if (disposition !== 'known_pre_effect') dispatch.refreshAfterWrite()
    if (!sameOwner) {
      showToast('이전 배정 요청의 결과가 도착했습니다. 요청한 workspace에서 Goal과 Task를 확인해 주세요.', 'warning')
    } else if (disposition === 'known_pre_effect') {
      showToast('배정 전에 요청이 거부되었습니다. workspace와 Goal을 다시 확인해 주세요.', 'warning')
    } else if (disposition === 'known_tool_response') {
      showToast('서버가 배정 오류를 반환했으며 일부 변경이 적용됐을 수 있습니다. 요청한 workspace에서 Goal과 Task를 확인해 주세요.', 'warning')
    } else {
      showToast('배정 결과를 확인할 수 없습니다. 요청한 workspace에서 Goal과 Task를 확인한 뒤 다시 요청해 주세요.', 'warning')
    }
    return false
  }
}
