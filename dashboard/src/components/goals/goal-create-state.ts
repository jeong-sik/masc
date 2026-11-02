// Goal creation state and the request's workspace-bound outcome.

import { signal } from '@preact/signals'
import { v4 as randomUuid } from 'uuid'
import { currentDashboardActor, getStoredToken, getStoredTokenMeta } from '../../api/core'
import { callMcpToolAtIdentity, mcpCallFailureDisposition, mcpStructuredContentFromError } from '../../api/mcp'
import { artifactWorkspaceBody, captureArtifactWorkspace, type ArtifactWorkspace } from '../../api/published-artifacts'
import { storedTokenRevision } from '../../api/token-revision'
import { dashboardActorRevision, managedDashboardActorRevision, managedDashboardAuthRevision,
  managedDashboardRefusal } from '../../lib/dashboard-session-actor'
import { executionWorkspaceAuthority, refreshGoals, type ExecutionWorkspaceAuthority } from '../../store'
import { isRecord } from '../common/normalize'
import { showToast } from '../common/toast'

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
  | { kind: 'uncertain'; message: string; ticket: number }

export const goalCreateError = signal<GoalCreateError | null>(null)

type GoalCreateOutcome = {
  ticket: number
  draft: symbol
  authority: ExecutionWorkspaceAuthority
  authRevision: number
  actor: string
  actorRevision: number
  managed: boolean
  managedAuthRevision: number
  workspace: ArtifactWorkspace
  goalId: string
  state: 'pending' | 'created' | 'uncertain'
}

// These in-memory receipts survive closing the form, not a page reload.
export const goalCreateOutcomes = signal<readonly GoalCreateOutcome[]>([])
let creationTicket = 0

export function goalCreateOutcomeIsCurrent(outcome: GoalCreateOutcome): boolean {
  return outcome.authority === executionWorkspaceAuthority.peek()
    && outcome.authRevision === storedTokenRevision.peek() && outcome.actor === currentDashboardActor()
    && (outcome.managed ? getStoredToken() !== null && getStoredTokenMeta()?.source === 'dev'
      && outcome.actorRevision === managedDashboardActorRevision.peek()
      && outcome.managedAuthRevision === managedDashboardAuthRevision.peek()
      && managedDashboardRefusal.peek() !== outcome.authRevision
      : outcome.actorRevision === dashboardActorRevision.peek())
}

export function goalCreateDraftHasOutcome(outcomes: readonly GoalCreateOutcome[]): boolean {
  return outcomes.some(outcome => outcome.draft === draftToken)
}

function setOutcome(outcome: GoalCreateOutcome) {
  goalCreateOutcomes.value = [...goalCreateOutcomes.peek().filter(item => item.ticket !== outcome.ticket), outcome]
}

export function dismissGoalCreateOutcome(ticket: number) {
  const outcome = goalCreateOutcomes.peek().find(item => item.ticket === ticket)
  if (!outcome || outcome.state === 'pending') return
  goalCreateOutcomes.value = goalCreateOutcomes.peek().filter(item => item.ticket !== ticket)
  const error = goalCreateError.peek()
  if (error?.kind === 'uncertain' && error.ticket === ticket) goalCreateError.value = null
}

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
    case 'submit':
    case 'uncertain': return err.message
  }
}

// These are the upsert handler's refusals before its locked state commit.
// An internal error or an unrecognized tool response can follow an effect.
function goalCreateRefusal(error: unknown): { message: string } | null {
  const data = mcpStructuredContentFromError(error)
  if (!isRecord(data)) return null
  const rejected = data.status === 'error' && (data.error_code === 'validation_error'
    || data.error_code === 'conflict' || data.error_code === 'not_found')
  const unavailable = data.ok === false && data.error_code === 'goal_store_unavailable'
  if (!rejected && !unavailable) return null
  return { message: typeof data.message === 'string' ? data.message : 'Goal 저장소와 입력을 확인해 주세요.' }
}

export async function createGoal(input: GoalCreateInput, isStoreUnavailableNow: () => boolean = () => false,
  workspaceView: (workspace: ArtifactWorkspace) => 'current' | 'different' | 'unconfirmed' = () => 'unconfirmed'): Promise<boolean> {
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
  if (goalCreating.peek() || goalCreateDraftHasOutcome(goalCreateOutcomes.peek())) return false
  const authority = executionWorkspaceAuthority.peek()
  if (!authority) {
    goalCreateError.value = { kind: 'submit', message: '현재 작업 공간을 확인한 뒤 목표를 생성해 주세요.' }
    return false
  }
  const authRevision = storedTokenRevision.peek()
  const actor = currentDashboardActor()
  const managed = getStoredToken() !== null && getStoredTokenMeta()?.source === 'dev'
  const actorRevision = managed ? managedDashboardActorRevision.peek() : dashboardActorRevision.peek()
  const managedAuthRevision = managedDashboardAuthRevision.peek()
  const sameConnection = () => executionWorkspaceAuthority.peek() === authority
    && storedTokenRevision.peek() === authRevision && currentDashboardActor() === actor
    && (managed ? getStoredToken() !== null && getStoredTokenMeta()?.source === 'dev'
      && managedDashboardActorRevision.peek() === actorRevision
      : dashboardActorRevision.peek() === actorRevision)
  const decisionCurrent = () => sameConnection() && (!managed
    || (managedDashboardAuthRevision.peek() === managedAuthRevision && managedDashboardRefusal.peek() !== authRevision))
  if (!decisionCurrent()) {
    goalCreateError.value = { kind: 'submit', message: '인증이 거부되었습니다. 인증을 확인한 뒤 다시 시도해 주세요.' }
    return false
  }
  const canDispatch = () => owner === draftToken && decisionCurrent() && !isStoreUnavailableNow()
  goalCreating.value = true
  goalCreateError.value = null
  let outcome: GoalCreateOutcome | null = null
  try {
    const workspace = await captureArtifactWorkspace(authority.workspaceRoot, undefined, { reportCredentialRefusal: false })
    const canSend = () => canDispatch() && workspaceView(workspace) !== 'different'
    if (!canSend()) {
      if (owner === draftToken && sameConnection()) {
        goalCreateError.value = { kind: 'submit', message: '현재 작업 공간과 Goal 저장소를 다시 확인해 주세요.' }
      }
      return false
    }
    const goalId = `goal-${randomUuid()}`
    outcome = { ticket: ++creationTicket, draft: owner, authority, authRevision, actor, actorRevision, managed,
      managedAuthRevision, workspace, goalId, state: 'pending' }
    setOutcome(outcome)
    let recoveryWorkspace: ArtifactWorkspace | null = null
    const recoveryBaseCurrent = () => owner === draftToken && sameConnection()
      && workspaceView(workspace) !== 'different' && !isStoreUnavailableNow()
    const recoveryCurrent = () => recoveryBaseCurrent() && (workspaceView(workspace) === 'current'
      || (recoveryWorkspace !== null && recoveryWorkspace.basePath === workspace.basePath
        && recoveryWorkspace.mascRoot === workspace.mascRoot))
    const waitForRecoveryCurrent = async () => {
      if (!recoveryBaseCurrent()) return false
      try {
        const observed = await captureArtifactWorkspace(authority.workspaceRoot, undefined, { reportCredentialRefusal: false })
        if (!recoveryBaseCurrent() || observed.basePath !== workspace.basePath || observed.mascRoot !== workspace.mascRoot) return false
        recoveryWorkspace = observed
        return true
      } catch { return false }
    }
    const response = await callMcpToolAtIdentity('masc_goal_upsert', {
      id: goalId, if_absent: true, expected_workspace: artifactWorkspaceBody(workspace),
      title: trimmedTitle, metric, target_value: targetValue, priority: input.priority,
    }, { revision: authRevision, actor }, canSend, recoveryCurrent, waitForRecoveryCurrent)
    const parsed: unknown = JSON.parse(response)
    if (!isRecord(parsed) || parsed.status !== 'ok' || parsed.action !== 'created'
      || parsed.goal_id !== goalId || !isRecord(parsed.goal) || parsed.goal.id !== goalId) {
      throw new Error('Goal creation response does not match the request')
    }
    setOutcome({ ...outcome, state: 'created' })
    const sameWorkspaceView = decisionCurrent() && workspaceView(workspace) === 'current'
    if (sameWorkspaceView) {
      if (owner === draftToken) {
        showToast('서버가 목표 생성 요청에 응답했습니다.', 'success')
        showGoalCreate.value = false
      }
      // A later observation failure cannot turn a committed response into a
      // failed creation or keep the submitted draft in flight.
      void refreshGoals().catch(() => {})
    }
    return owner === draftToken && sameWorkspaceView
  } catch (err) {
    const disposition = outcome === null ? 'known_pre_effect' : mcpCallFailureDisposition(err)
    const refusal = disposition === 'known_tool_response' ? goalCreateRefusal(err) : null
    if (outcome && disposition !== 'known_pre_effect' && !refusal) {
      setOutcome({ ...outcome, state: 'uncertain' })
      if (owner === draftToken && decisionCurrent()) {
        goalCreateError.value = { kind: 'uncertain',
          message: '생성 결과를 확인하지 못했습니다. 중복 생성을 피하려면 요청한 작업 공간에서 결과를 확인해 주세요.',
          ticket: outcome.ticket }
      }
    } else {
      if (outcome) goalCreateOutcomes.value = goalCreateOutcomes.peek().filter(item => item.ticket !== outcome?.ticket)
      if (owner === draftToken && decisionCurrent()) {
        goalCreateError.value = { kind: 'submit', message: (outcome && workspaceView(outcome.workspace) === 'current' ? refusal?.message : null)
          ?? '생성 전에 요청이 거절되었습니다. 작업 공간과 입력을 확인해 주세요.' }
      }
    }
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

export function _testResetGoalCreateOutcomes(): void {
  goalCreateOutcomes.value = []
}
