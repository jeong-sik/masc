import { computed, effect, signal, type ReadonlySignal } from '@preact/signals'
import { callMcpTaskCreationAtIdentity, callMcpToolAtIdentity, mcpCallFailureDisposition } from '../../api/mcp'
import { currentDashboardActor, currentStoredTokenRevision, getStoredToken, getStoredTokenMeta } from '../../api/core'
import { retryRejectedDevToken } from '../../api/dev-token'
import { showToast } from '../common/toast'
import { executionError, executionWorkspaceAuthority, refreshExecution, refreshGoals, refreshShell, tasks } from '../../store'
import { dashboardActorRevision, managedDashboardActorRevision, managedDashboardAuthRevision,
  managedDashboardRefusal, managedDashboardUnverified } from '../../lib/dashboard-session-actor'
import { storedTokenRevision } from '../../api/token-revision'
import { isCanonicalGoalId } from '../../lib/goal-identity'
import { artifactWorkspaceBody, captureArtifactWorkspace, type ArtifactWorkspace } from '../../api/published-artifacts'
import { isRecord } from '../common/normalize'
import { createTaskCreateReceiptStore, decodeTaskCreationResponse, TASK_CREATE_RECEIPT_STORAGE_KEY, type TaskCreateReservation,
  type TaskReceiptOwner } from './task-create-receipt'

export const showTaskCreate = signal(false)
const currentTaskDraft = signal(Symbol('task-create-draft'))
const draftRequests = signal<ReadonlyMap<symbol, string>>(new Map())
// Before a receipt exists, workspace capture still needs a per-draft double-click guard.
const preparingDrafts = signal<ReadonlySet<symbol>>(new Set())
const memoryOnlyDraft = signal<symbol | null>(null)
export const taskCreateStorageNotice = signal<symbol | null>(null)
export const taskCreateUsingMemoryOnly = computed(() => memoryOnlyDraft.value === currentTaskDraft.value)
const receiptOwner = signal<TaskReceiptOwner | null>(null)
export const taskCreateReceiptOwner: ReadonlySignal<TaskReceiptOwner | null> = receiptOwner
export let taskCreateReceipts = createTaskCreateReceiptStore({ owner: receiptOwner })

export const taskCreating = computed(() => {
  const draft = currentTaskDraft.value
  if (preparingDrafts.value.has(draft)) return true
  const requestId = draftRequests.value.get(draft)
  return requestId !== undefined
    && taskCreateReceipts.attempts.value.some(item => item.requestId === requestId && item.original.kind === 'pending')
})

export const taskDraftHasUnconfirmedRequest = computed(() => {
  const requestId = draftRequests.value.get(currentTaskDraft.value)
  if (!requestId) return false
  const original = taskCreateReceipts.attempts.value.find(item => item.requestId === requestId)?.original
  return original?.kind === 'pending' || original?.kind === 'unconfirmed'
})

export function beginSeparateTaskDraft(): void {
  const draft = Symbol('task-create-draft')
  currentTaskDraft.value = draft
  memoryOnlyDraft.value = null
  taskCreateStorageNotice.value = null
}

/** Choosing this does not send a Task; the operator submits the draft separately. */
export function chooseTaskCreateMemoryOnly(): void {
  if (taskCreateStorageNotice.peek() !== currentTaskDraft.peek()) return
  memoryOnlyDraft.value = currentTaskDraft.peek()
  taskCreateStorageNotice.value = null
}

export function retryTaskCreateStorage(): boolean {
  const ready = taskCreateReceipts.retryStorage()
  if (ready) taskCreateStorageNotice.value = null
  return ready
}

export function _testResetTaskCreateState(options?: { preserveStorage?: boolean }): void {
  taskCreateReceipts.dispose()
  if (!options?.preserveStorage) {
    try { globalThis.sessionStorage?.removeItem(TASK_CREATE_RECEIPT_STORAGE_KEY) } catch { /* unavailable in this test */ }
  }
  receiptOwner.value = null
  draftRequests.value = new Map()
  preparingDrafts.value = new Set()
  taskCreateReceipts = createTaskCreateReceiptStore({ owner: receiptOwner })
  beginSeparateTaskDraft()
}

function bindReceiptOwner(workspace: ArtifactWorkspace): TaskReceiptOwner | null {
  const authority = executionWorkspaceAuthority.peek()
  if (!authority) return null
  const revision = currentStoredTokenRevision()
  const actor = currentDashboardActor()
  const token = getStoredToken()
  const managed = token !== null && getStoredTokenMeta()?.source === 'dev'
  const actorRevision = managed ? managedDashboardActorRevision.peek() : dashboardActorRevision.peek()
  const managedRevision = managedDashboardAuthRevision.peek()
  const isCurrent = () => executionWorkspaceAuthority.peek() === authority
    && currentStoredTokenRevision() === revision && currentDashboardActor() === actor
    && (managed ? getStoredToken() === token && getStoredTokenMeta()?.source === 'dev'
      && managedDashboardActorRevision.peek() === actorRevision
      && managedDashboardAuthRevision.peek() === managedRevision
      && managedDashboardRefusal.peek() !== revision && managedDashboardUnverified.peek() !== revision
      : dashboardActorRevision.peek() === actorRevision)
  if (!isCurrent()) return null
  const existing = receiptOwner.peek()
  if (existing && existing.workspace.basePath === workspace.basePath && existing.workspace.mascRoot === workspace.mascRoot
    && existing.identity.revision === revision && existing.identity.actor === actor && existing.isCurrent()) return existing
  const owner: TaskReceiptOwner = { workspace: { ...workspace }, identity: { revision, actor }, isCurrent }
  receiptOwner.value = owner
  return owner
}

effect(() => {
  void executionWorkspaceAuthority.value
  void storedTokenRevision.value
  void dashboardActorRevision.value
  void managedDashboardActorRevision.value
  void managedDashboardAuthRevision.value
  void managedDashboardRefusal.value
  void managedDashboardUnverified.value
  const current = receiptOwner.peek()
  if (current && !current.isCurrent()) receiptOwner.value = null
})

async function verifyReceiptOwner(expected?: ArtifactWorkspace): Promise<TaskReceiptOwner | null> {
  const authority = executionWorkspaceAuthority.peek()
  if (!authority) {
    showToast('현재 작업 공간을 확인한 뒤 이전 요청을 다시 확인해 주세요.', 'warning')
    return null
  }
  const revision = currentStoredTokenRevision()
  const actor = currentDashboardActor()
  const actorVersion = dashboardActorRevision.peek()
  const managedVersion = managedDashboardActorRevision.peek()
  const managedAuthVersion = managedDashboardAuthRevision.peek()
  const current = () => executionWorkspaceAuthority.peek() === authority && currentStoredTokenRevision() === revision
    && currentDashboardActor() === actor && dashboardActorRevision.peek() === actorVersion
    && managedDashboardActorRevision.peek() === managedVersion && managedDashboardAuthRevision.peek() === managedAuthVersion
  try {
    const workspace = await captureArtifactWorkspace(authority.workspaceRoot, undefined, { reportCredentialRefusal: false })
    if (!current()) return null
    if (expected && (workspace.basePath !== expected.basePath || workspace.mascRoot !== expected.mascRoot)) {
      showToast('이 요청을 보낸 작업 공간에서 다시 확인해 주세요.', 'warning')
      return null
    }
    const managed = getStoredToken() !== null && getStoredTokenMeta()?.source === 'dev'
    if (managed && managedDashboardRefusal.peek() === revision) {
      const recheckShell = await retryRejectedDevToken(workspace, current)
      if (recheckShell && current()) await refreshShell({ force: true, recoverAuth: false })
      return null
    }
    if (managed && managedDashboardUnverified.peek() === revision) {
      await refreshShell({ force: true, recoverAuth: false })
      return null
    }
    const owner = bindReceiptOwner(workspace)
    if (!owner || !current()) {
      showToast('현재 인증과 작업 공간을 다시 확인해 주세요.', 'warning')
      return null
    }
    return owner
  } catch {
    if (current()) showToast('이전 요청의 작업 공간을 확인하지 못했습니다.', 'warning')
    return null
  }
}

/** Explicit receipt lookup; it never resends the creation request. */
export async function recheckTaskCreation(requestId: string): Promise<void> {
  const attempt = taskCreateReceipts.attempts.peek().find(item => item.requestId === requestId)
  if (!attempt || !await verifyReceiptOwner(attempt.workspace)) return
  const result = await taskCreateReceipts.observe(requestId)
  if (result.kind === 'owner_unavailable' || result.kind === 'workspace_mismatch') {
    showToast('현재 인증과 작업 공간을 다시 확인해 주세요.', 'warning')
  }
}

export function acknowledgeTaskCreateResult(requestId: string): void {
  const item = taskCreateReceipts.attempts.peek().find(attempt => attempt.requestId === requestId)
  const owner = receiptOwner.peek()
  if (!item || !owner || !owner.isCurrent() || item.workspace.basePath !== owner.workspace.basePath
    || item.workspace.mascRoot !== owner.workspace.mascRoot || item.latestReadFailureCurrent
    || !(item.originalCurrent || item.latestReadCurrent)) return
  taskCreateReceipts.markPresented(requestId)
}

export function compactTaskCreateReceipts(): void {
  const result = taskCreateReceipts.compact()
  if (result.persisted && result.removedAttempts + result.removedErrors === 0) {
    showToast('정리할 수 있는 기록이 없습니다. 현재 인증으로 결과를 확인해 주세요.', 'warning')
  } else if (result.persisted) showToast('확인된 기록과 중복 조회 오류를 정리했습니다.', 'success')
  else showToast('기록을 정리했지만 저장하지 못했습니다. 저장 상태를 다시 확인해 주세요.', 'warning')
}

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

export type TaskCreatePresentation = {
  /** A dismissed or edited draft cannot dispatch after an asynchronous observation. */
  readonly isCurrent?: () => boolean
  /** Finish only the draft that submitted this request. */
  readonly finish: () => boolean
}

export async function createTask(input: TaskCreateInput, goalDispatch?: GoalTaskDispatch,
  presentation?: TaskCreatePresentation): Promise<boolean> {
  if (!input.title.trim()) { showToast('제목을 입력하세요', 'error'); return false }
  const linkedGoalId = input.goal_id ?? null
  if (linkedGoalId !== null && (!isCanonicalGoalId(linkedGoalId) || !goalDispatch || !goalDispatch.isCurrent())) {
    showToast('현재 Goal을 다시 확인한 뒤 태스크를 연결해 주세요.', 'warning')
    return false
  }
  const draft = currentTaskDraft.peek()
  if (taskCreating.peek() || taskDraftHasUnconfirmedRequest.peek()) return false
  const planningAuthority = linkedGoalId === null ? executionWorkspaceAuthority.peek() : null
  if (linkedGoalId === null && !planningAuthority) {
    showToast('현재 작업 공간을 확인한 뒤 태스크를 다시 등록해 주세요.', 'warning')
    void refreshExecution({ force: true }).catch(error => {
      console.warn('[Tasks] workspace observation failed:', error)
    })
    return false
  }
  const authRevision = currentStoredTokenRevision()
  const actor = currentDashboardActor()
  const sentToken = getStoredToken()
  const managed = sentToken !== null && getStoredTokenMeta()?.source === 'dev'
  const actorRevision = managed ? managedDashboardActorRevision.peek() : dashboardActorRevision.peek()
  const managedAuthRevision = managedDashboardAuthRevision.peek()
  const presentationCurrent = () => presentation?.isCurrent?.() ?? true
  const samePlanningConnection = () => planningAuthority !== null
    && executionWorkspaceAuthority.peek() === planningAuthority
    && currentStoredTokenRevision() === authRevision && currentDashboardActor() === actor
    && (managed ? getStoredToken() === sentToken && getStoredTokenMeta()?.source === 'dev'
      && managedDashboardActorRevision.peek() === actorRevision
      : dashboardActorRevision.peek() === actorRevision)
  const planningRecoveryCurrent = () => samePlanningConnection() && presentationCurrent()
  const planningDecisionCurrent = () => samePlanningConnection() && (!managed
    || (managedDashboardAuthRevision.peek() === managedAuthRevision && managedDashboardRefusal.peek() !== authRevision
      && managedDashboardUnverified.peek() !== authRevision))
  let dispatch = linkedGoalId === null ? null : goalDispatch ?? null
  let reservation: TaskCreateReservation | null = null
  const receipts = taskCreateReceipts
  preparingDrafts.value = new Set([...preparingDrafts.peek(), draft])
  try {
    if (linkedGoalId === null && planningAuthority) {
      if (!planningRecoveryCurrent()) return false
      const workspace = await captureArtifactWorkspace(planningAuthority.workspaceRoot, undefined,
        { reportCredentialRefusal: false })
      if (!planningRecoveryCurrent()) {
        showToast('요청 전에 작업 공간이나 입력이 바뀌어 태스크를 만들지 않았습니다.', 'warning')
        return false
      }
      if (!planningDecisionCurrent()) {
        // Recheck credentials as a separate action. Never replay this Task POST.
        if (managed && managedDashboardRefusal.peek() === authRevision) {
          const recheckShell = await retryRejectedDevToken(workspace, planningRecoveryCurrent)
          if (recheckShell && planningRecoveryCurrent()) await refreshShell({ force: true, recoverAuth: false })
        } else if (managed && managedDashboardUnverified.peek() === authRevision && planningRecoveryCurrent()) {
          await refreshShell({ force: true, recoverAuth: false })
        }
        if (executionWorkspaceAuthority.peek() === planningAuthority && presentationCurrent()) {
          showToast('인증 상태를 확인한 뒤 태스크를 다시 등록해 주세요.', 'warning')
        }
        return false
      }
      dispatch = { workspace, identity: { revision: authRevision, actor },
        isCurrent: () => planningDecisionCurrent() && presentationCurrent(), isRecoveryCurrent: planningRecoveryCurrent }
    }
    if (!dispatch || !dispatch.isCurrent()) return false
    const owner = bindReceiptOwner(dispatch.workspace)
    if (!owner || owner.identity.revision !== dispatch.identity.revision || owner.identity.actor !== dispatch.identity.actor) {
      showToast('현재 인증과 작업 공간을 확인한 뒤 태스크를 다시 등록해 주세요.', 'warning')
      return false
    }
    const reserved = memoryOnlyDraft.peek() === draft
      ? receipts.reserveMemoryOnly(linkedGoalId) : receipts.reserve(linkedGoalId)
    if (reserved.kind !== 'reserved') {
      if (reserved.kind === 'storage_unavailable') {
        taskCreateStorageNotice.value = draft
        showToast('요청 기록을 보관하지 못해 태스크를 보내지 않았습니다.', 'warning')
      } else {
        showToast('요청을 준비하지 못했습니다. 현재 작업 공간을 다시 확인해 주세요.', 'warning')
      }
      return false
    }
    reservation = reserved.reservation
    const requests = new Map(draftRequests.peek())
    requests.set(draft, reservation.requestId)
    draftRequests.value = requests
    const preparations = new Set(preparingDrafts.peek())
    preparations.delete(draft)
    preparingDrafts.value = preparations
    const canSend = () => reservation?.isCurrent() === true && dispatch?.isCurrent() === true
      && presentationCurrent() && currentTaskDraft.peek() === draft
    if (!canSend()) {
      receipts.settleOriginal(reservation.requestId, { kind: 'not_sent' })
      receipts.forgetDefinite(reservation.requestId)
      return false
    }
    const args: Record<string, unknown> = { title: input.title.trim(), description: input.description.trim() }
    if (input.priority) args.priority = input.priority
    if (linkedGoalId !== null) args.goal_id = linkedGoalId
    args.expected_workspace = artifactWorkspaceBody(dispatch.workspace)
    args.creation_request_id = reservation.requestId
    const originalRequestId = reservation.requestId
    const response = await callMcpTaskCreationAtIdentity(args, dispatch.identity, canSend,
      dispatch.isRecoveryCurrent, dispatch.waitForRecoveryCurrent, result => {
        receipts.settleOriginal(originalRequestId, result)
      })
    const created = decodeTaskCreationResponse(response, reservation.requestId, linkedGoalId)
    if (!created) {
      receipts.settleOriginal(reservation.requestId, { kind: 'unconfirmed', reason: 'response_unknown' })
      showToast('태스크 생성 응답을 확인할 수 없습니다. 이전 요청의 결과를 확인해 주세요.', 'warning')
      return false
    }
    receipts.settleOriginal(reservation.requestId, created)
    if (!dispatch.isCurrent()) {
      showToast('이전 요청의 태스크 생성 응답이 도착했습니다. 요청한 workspace에서 결과를 확인해 주세요.', 'warning')
      return true
    }
    let presented = true
    try {
      if (presentation) presented = presentation.finish()
    } catch (error) {
      // The server has already accepted the write; a presentation error
      // cannot turn that result into a failed creation.
      console.warn('[Tasks] created task presentation failed:', error)
      presented = false
    }
    if (!presented) {
      showToast('이전 요청의 태스크 생성 응답이 도착했습니다. 요청한 위치에서 결과를 확인해 주세요.', 'warning')
      return true
    }
    if (linkedGoalId === null && !planningDecisionCurrent()) {
      showToast('이전 요청의 태스크 생성 응답이 도착했습니다. 요청한 workspace에서 결과를 확인해 주세요.', 'warning')
      return true
    }
    showToast(`태스크 생성 완료 · ${created.taskId}`, 'success')
    try {
      const observations: Promise<void>[] = []
      if (linkedGoalId !== null || planningDecisionCurrent()) observations.push(refreshExecution({ force: true }))
      if (linkedGoalId !== null) observations.push(refreshGoals())
      await Promise.all(observations)
      if (reservation.isCurrent() && executionError.peek() === null
        && tasks.peek().some(task => task.id === created.taskId)) {
        receipts.markPresented(reservation.requestId)
        receipts.forgetDefinite(reservation.requestId)
      }
    } catch (error) {
      // The write already committed; keep its receipt visible if refresh failed.
      console.warn('[Tasks] post-write observation refresh failed:', error)
    }
    return true
  } catch (err) {
    if (dispatch) {
      const disposition = mcpCallFailureDisposition(err)
      if (reservation) {
        const settled = receipts.settleOriginal(reservation.requestId,
          disposition === 'known_pre_effect' ? { kind: 'rejected_before_effect' }
            : { kind: 'unconfirmed', reason: disposition === 'known_tool_response' ? 'server_error' : 'response_unknown' })
        if (disposition === 'known_pre_effect' && settled.kind === 'settled') receipts.forgetDefinite(reservation.requestId)
      }
      if (!dispatch.isCurrent()) {
        showToast('이전 요청의 결과가 도착했습니다. 요청한 workspace에서 Task 상태를 확인해 주세요.', 'warning')
      } else if (disposition === 'known_pre_effect') {
        showToast('태스크 생성 전에 요청이 거부되었습니다. workspace와 입력을 다시 확인해 주세요.', 'warning')
      } else if (disposition === 'known_tool_response') {
        showToast('서버가 오류를 반환했으며 일부 변경이 적용됐을 수 있습니다. 요청한 workspace의 Task를 확인한 뒤 다시 요청해 주세요.', 'warning')
      } else {
        showToast('태스크 생성 결과를 확인할 수 없습니다. 다시 요청하면 중복될 수 있으니 요청한 workspace의 Task를 확인해 주세요.', 'warning')
      }
    } else {
      showToast('태스크 생성 전에 작업 공간을 확인하지 못했습니다. 연결을 확인한 뒤 다시 시도해 주세요.', 'warning')
    }
    return false
  } finally {
    if (preparingDrafts.peek().has(draft)) {
      const preparations = new Set(preparingDrafts.peek())
      preparations.delete(draft)
      preparingDrafts.value = preparations
    }
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
