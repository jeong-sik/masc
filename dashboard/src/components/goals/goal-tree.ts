import { GoalCriterionReviewDetail, GoalCriterionReviewStatus } from './goal-criterion-review'
import { GOAL_TRANSITION_LABELS, goalLifecycleActions, type GoalTransitionAction } from '../../api/goal-lifecycle'
import { GoalProofDetail } from './goal-proof'
import { GoalCandlePanel } from './goal-candle'
// Goal Manager — goal-first planning surface with explicit phase, detail, and evidence.

import { html } from 'htm/preact'
import { GoalConfirmationPanel, confirmationHasUnsettledReceipt, confirmationPending } from './goal-confirmation'
import { batch, effect, signal } from '@preact/signals'
import { useCallback, useEffect, useLayoutEffect, useMemo, useState } from 'preact/hooks'
import { SECONDS_PER_HOUR } from '../../lib/format-time'
import { fetchDashboardGoalDetail, fetchDashboardGoalsTree } from '../../api/dashboard'
import { ApiRequestError, currentDashboardActor, getStoredToken, getStoredTokenMeta } from '../../api/core'
import { recoverScopedRejectedCredential, retryRejectedDevToken } from '../../api/dev-token'
import { storedTokenRevision } from '../../api/token-revision'
import { currentCanonicalDashboardActor, dashboardActorRevision, managedDashboardActorRevision,
  managedDashboardRefusal, managedDashboardUnverified, noteManagedCredentialRefusalObservation } from '../../lib/dashboard-session-actor'
import { executionError, executionLoading, executionWorkspaceAuthority, refreshExecution, refreshShell, type ExecutionWorkspaceAuthority } from '../../store'
import { artifactWorkspaceBody, captureArtifactWorkspace, type ArtifactWorkspace } from '../../api/published-artifacts'
import { approvalInputText } from '../../lib/keeper-approval-input-text'
import { callMcpToolAtIdentity, mcpCallFailureDisposition, mcpIdentityRequiresGoalRefresh } from '../../api/mcp'
import { replaceRoute, route } from '../../router'
import {
  goalStoreUnavailable as storeUnavailable,
  goalTreeData as treeData,
  goalTreeError as treeError,
  goalTreeLoading as treeLoading,
  goalTreeObservationRevision,
  hydrateGoalTreeError,
  hydrateGoalTreeObservationError,
  hydrateGoalTreeSnapshot,
} from '../../goal-tree-state'
import { EmptyState, ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { FilterChips } from '../common/filter-chips'
import { StatusBadge } from '../common/status-badge'
import { showToast } from '../common/toast'
import { executionOutcomeLabel } from '../fsm-hub-types'
import { operatorDispositionReasonLabel } from '../fsm-hub-types'
import { runtimeOutcomeLabel } from '../fsm-hub-types'
import { ringFocusClasses } from '../common/ring'
import { trustDispositionLabel } from '../fsm-hub-types'
import { TimeAgo } from '../common/time-ago'
import { TaskCreateForm } from '../task-manage/task-create-form'
import type {
  DashboardGoalDetailResponse,
  DashboardGoalsTreeResponse,
  GoalDetailKeeper,
  GoalDetailTimelineEvent,
  GoalFsmProjection,
  GoalMeasurementProjection,
  GoalStoreUnavailable,
  GoalTreeNode,
  GoalTreeTask,
  GoalTreeSummary,
} from '../../types'
import {
  priorityStars,
  countAwaitingVerificationTasks,
  countAwaitingVerificationInTree,
  type GoalPhaseFilter,
  goalPhaseLabel,
  goalPhaseStatus,
  matchesGoalPhaseFilter,
  phaseFilterLabel,
  TaskProgressBar,
} from './goal-helpers'
import { trustHasPendingFirstEvidence } from './trust-summary-evidence'
import {
  goalTaskCompletionLabel,
  goalTaskSummaryForNode,
} from './goal-task-summary'
import { DECK_CHIP, DECK_LABEL } from './deck-classes'
import { GoalStoreUnavailableAlert } from './goal-store-unavailable'
import { errorToString } from '../../lib/format-string'
import { isUnambiguousGoalId } from '../../lib/goal-identity'

type GoalDetailTab = 'summary' | 'tasks' | 'evidence'

const CARD_BOX = 'rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3'
const GOAL_PANEL = 'rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-5'
const TREE_NODE_CARD_BASE = 'group flex items-start gap-3 rounded-[var(--r-1)] border p-3 transition-colors w-full text-left'
const TREE_NODE_CARD_ACTIVE = `${TREE_NODE_CARD_BASE} border-[var(--color-state-active-border)] bg-[var(--color-state-active-bg)] shadow-[0_0_0_1px_var(--color-brass-border)]`

/**
 * Pure hierarchy filter for goal tree nodes.
 *
 * Case-insensitive substring match on `node.title` and on `task.title` for
 * any task attached to the node. Ancestors of matching nodes are preserved
 * so the operator retains context (parent goal) — the tree shape
 * is never broken by the filter.
 */
function filterGoalTree(
  nodes: readonly GoalTreeNode[],
  query: string,
): readonly GoalTreeNode[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return nodes

  const result: GoalTreeNode[] = []
  for (const node of nodes) {
    const pruned = pruneNode(node, needle)
    if (pruned !== null) result.push(pruned)
  }
  return result
}

function pruneNode(node: GoalTreeNode, needle: string): GoalTreeNode | null {
  const title = node.title ?? ''
  const nodeMatches = title.toLowerCase().includes(needle)
  if (nodeMatches) return node

  const matchingTasks = node.tasks.filter(t =>
    (t.title ?? '').toLowerCase().includes(needle),
  )
  const prunedChildren: GoalTreeNode[] = []
  for (const child of node.children) {
    const prunedChild = pruneNode(child, needle)
    if (prunedChild !== null) prunedChildren.push(prunedChild)
  }

  if (matchingTasks.length === 0 && prunedChildren.length === 0) return null

  return {
    ...node,
    tasks: matchingTasks,
    children: prunedChildren,
  }
}

function filterGoalTreeByPhase(
  nodes: readonly GoalTreeNode[],
  filter: GoalPhaseFilter,
): readonly GoalTreeNode[] {
  if (filter === 'all') return nodes

  const result: GoalTreeNode[] = []
  for (const node of nodes) {
    const pruned = pruneNodeByPhase(node, filter)
    if (pruned !== null) result.push(pruned)
  }
  return result
}

function pruneNodeByPhase(
  node: GoalTreeNode,
  filter: GoalPhaseFilter,
): GoalTreeNode | null {
  const nodeMatches = matchesGoalPhaseFilter(node.phase, filter)
  const prunedChildren: GoalTreeNode[] = []
  for (const child of node.children) {
    const prunedChild = pruneNodeByPhase(child, filter)
    if (prunedChild !== null) prunedChildren.push(prunedChild)
  }

  if (!nodeMatches && prunedChildren.length === 0) return null
  if (nodeMatches && prunedChildren.length === node.children.length) return node

  return {
    ...node,
    tasks: nodeMatches ? node.tasks : [],
    children: prunedChildren,
  }
}

function flattenGoalTree(nodes: readonly GoalTreeNode[]): GoalTreeNode[] {
  const acc: GoalTreeNode[] = []
  const walk = (items: readonly GoalTreeNode[]) => {
    for (const item of items) {
      acc.push(item)
      if (item.children.length > 0) walk(item.children)
    }
  }
  walk(nodes)
  return acc
}

function goalIdIsUnambiguous(id: string, snapshot: DashboardGoalsTreeResponse): boolean {
  const observation = snapshot.identity_observation
  return Boolean(observation?.complete && isUnambiguousGoalId(id, observation.ids))
}

function goalFsmStateLabel(state: GoalFsmProjection['state']): string {
  return goalPhaseLabel(state)
}

function goalFsmObservationLabel(
  observation: GoalFsmProjection['activity_observation'],
): string {
  switch (observation) {
    case 'runtime': return 'runtime evidence'
    case 'approval': return 'approval event'
    case 'task': return 'task update'
    case 'goal_metadata': return 'goal metadata only'
    default: return observation
  }
}

function GoalFsmBadge({ fsm }: { fsm: GoalFsmProjection }) {
  const toneClass =
    'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
  return html`
    <span
      class="inline-flex items-center rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold uppercase ${toneClass}"
      title=${`source=${fsm.source}; activity=${goalFsmObservationLabel(fsm.activity_observation)}`}
    >
      Goal FSM · ${goalFsmStateLabel(fsm.state)}
    </span>
  `
}

function keeperTrustDispositionClass(
  trust: GoalDetailKeeper['runtime_trust'],
): string {
  const disposition = trust?.disposition
  if (disposition === 'Alert') return 'border-bad/25 bg-bad/10 text-bad'
  if (disposition === 'Blocked' || trust?.needs_attention) {
    return 'border-warn/25 bg-warn/10 text-warn'
  }
  if (disposition === 'Pass') return 'border-ok/25 bg-ok/10 text-ok'
  return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
}

function timelineSeverityClass(severity: GoalDetailTimelineEvent['severity']): string {
  switch (severity) {
    case 'bad': return 'border-bad/25 bg-bad/10 text-bad'
    case 'warn': return 'border-warn/25 bg-warn/10 text-warn'
    default: return 'border-card-border/50 bg-[var(--color-bg-surface)] text-text-body'
  }
}

const expandedNodes = signal<Set<string>>(new Set())
const filterQuery = signal('')
const treePhaseFilter = signal<GoalPhaseFilter>('all')
const selectedGoalId = signal<string | null>(null)
const selectedGoalRevision = signal(0)
function setSelectedGoal(id: string | null) {
  if (selectedGoalId.peek() === id) return
  selectedGoalRevision.value += 1
  selectedGoalId.value = id
}
const detailData = signal<DashboardGoalDetailResponse | null>(null)
const detailLoading = signal(false)
const detailError = signal<string | null>(null)
const detailTab = signal<GoalDetailTab>('summary')
let detailRequestSeq = 0
let treeRequestSeq = 0
let treeConsumerCount = 0
const goalAuthRetrying = signal(false)
let goalAuthRetryPromise: Promise<void> | null = null
const treeDecisionBinding = signal<{
  authority: ExecutionWorkspaceAuthority
  workspace: ArtifactWorkspace
  snapshot: DashboardGoalsTreeResponse
  authRevision: number
  actor: string
} | null>(null)
const detailDecisionBinding = signal<typeof treeDecisionBinding.value>(null)
const treeErrorOwner = signal<{ authority: ExecutionWorkspaceAuthority; authRevision: number; actor: string;
  observationRevision: number; error: string | null; unavailable: GoalStoreUnavailable | null } | null>(null)
type TreeRetryIntent = { authority: ExecutionWorkspaceAuthority; authRevision: number; actor: string;
  afterWrite?: { workspace: ArtifactWorkspace; request: number } }
const treeRetryIntent = signal<TreeRetryIntent | null>(null)
const treeRequestInFlight = signal<{ request: number; authority: ExecutionWorkspaceAuthority;
  authRevision: number; actor: string; observationRevision: number; controller: AbortController;
  workspace: ArtifactWorkspace | null; workspaceReady: Promise<ArtifactWorkspace> } | null>(null)
let treeWorkspaceAttestation: { request: number; authority: ExecutionWorkspaceAuthority;
  authRevision: number; actor: string; workspace: ArtifactWorkspace } | null = null

function recordTreeErrorOwner(authority: ExecutionWorkspaceAuthority, authRevision: number, actor: string) {
  treeErrorOwner.value = { authority, authRevision, actor, observationRevision: goalTreeObservationRevision.peek(), error: treeError.peek(),
    unavailable: storeUnavailable.peek() }
}

type GoalActionOwner = { epoch: string; authorityIdentity: number; connectionGeneration: number; workspaceRoot: string; mascRoot: string; authRevision: number; authScope: string; actor: string; actorName: string; goalId: string }
type GoalOperationNoticeState = 'transition_pending' | 'transition_ack' | 'transition_drop'
  | 'transition_unknown' | 'transition_refused' | 'confirmation_pending' | 'confirmation_verified' | 'confirmation_unknown'
type GoalOperationNotice = { authority: ExecutionWorkspaceAuthority; authRevision: number; actor: string;
  workspace: ArtifactWorkspace; goalId: string; state: GoalOperationNoticeState }
const goalOperationNotices = signal<Record<string, GoalOperationNotice>>({})
type GoalActionReceipt = {
  ticket: number
  action: GoalTransitionAction
  state: 'pending' | 'success' | 'warning' | 'error'
  message: string
  owner: GoalActionOwner
  uncertain?: boolean
  binding?: { phase: 'executing' | 'verifying'; criterion_revision: string; request_id?: string }
}
const goalActionReceipts = signal<Record<string, GoalActionReceipt>>({})
const goalActionHistory = signal<Record<string, GoalActionReceipt[]>>({})
const goalDropDrafts = signal<Record<string, { owner: GoalActionOwner; reason: string }>>({})
const hiddenDropReceipts = signal<Set<number>>(new Set())
const expandedEarlierDropReceipts = signal<Set<string>>(new Set())
const expandedEarlierDropDrafts = signal<Set<string>>(new Set())
const dropAuthorityIdentities = new WeakMap<ExecutionWorkspaceAuthority, number>()
let nextDropAuthorityIdentity = 0
let goalActionTicket = 0

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function dropReceiptContext(goalId: string, note: string | undefined): string {
  const reason = note === undefined ? '이 시도의 사유를 확인할 수 없습니다.' : `이 시도에서 입력한 사유(앞뒤 공백 제거): ${note}`
  return `Goal ${goalId}의 과거 Drop 시도 기록입니다. 같은 ID의 현재 Goal과 동일한 인스턴스인지는 확인되지 않았습니다.\n${reason}`
}

function dropResponseMatchesGoal(response: Record<string, unknown>): boolean {
  return response.phase === 'dropped' && isRecord(response.goal)
    && response.goal.id === response.goal_id && response.goal.phase === 'dropped'
}

function goalDropReceipt(response: Record<string, unknown>, note: string | undefined):
  { state: 'warning'; message: string; uncertain: true } {
  const lines: string[] = [dropReceiptContext(String(response.goal_id), note)]
  const matchesDropped = dropResponseMatchesGoal(response)
  if (!matchesDropped) {
    lines.push('Drop 응답에서 Goal 상태를 확인할 수 없습니다. 현재 Goal을 확인하세요.')
  } else if (response.noop === true) {
    lines.push('서버는 요청 당시 Goal이 이미 Dropped 상태였다고 응답했습니다.')
    lines.push('입력한 사유는 이 요청으로 저장되지 않았습니다.')
  } else if (response.noop === false) {
    lines.push('서버는 요청 당시 Goal Drop이 적용되었다고 응답했습니다.')
  } else {
    lines.push('Drop 응답에서 Goal 변경 여부를 확인할 수 없습니다. 현재 Goal을 확인하세요.')
  }
  const delivery = response.effect_delivery
  if (isRecord(delivery) && delivery.status === 'deferred') {
    lines.push(`서버의 Goal 기록·알림 일괄 전달에서 지연이 보고되었습니다. 이 Goal의 개별 전달 여부는 확인되지 않았습니다.${typeof delivery.detail === 'string' ? ` ${delivery.detail}` : ''}${delivery.durable_retry === true ? ' 서버는 재시도 대상으로 보관했다고 보고합니다.' : ''}`)
  } else if (!isRecord(delivery) || delivery.status !== 'delivered') {
    lines.push('서버의 Goal 기록·알림 일괄 전달 상태를 확인할 수 없습니다.')
  }
  return { state: 'warning', message: lines.join('\n'), uncertain: true }
}

function goalActionAuthScope(revision: number): string {
  const meta = getStoredTokenMeta()
  return getStoredToken() && meta?.source === 'dev' && meta.actor === 'dashboard' && meta.role === 'admin'
    ? 'managed-dev-dashboard' : `credential:${revision}`
}

// Bind observations to the actor that the request may send as well as its
// revision, so changing away and back cannot revive an older observation.
function goalDecisionActor(): string {
  const token = getStoredToken()
  const meta = getStoredTokenMeta()
  if (token && meta?.source === 'dev' && meta.actor) return JSON.stringify(['dev', meta.actor, managedDashboardActorRevision.peek()])
  return JSON.stringify([token ? currentCanonicalDashboardActor() : currentDashboardActor(), dashboardActorRevision.peek()])
}

function managedGoalCredentialRefused(): boolean {
  return getStoredToken() !== null && getStoredTokenMeta()?.source === 'dev'
    && (managedDashboardRefusal.peek() === storedTokenRevision.peek()
      || managedDashboardUnverified.peek() === storedTokenRevision.peek())
}

function rememberGoalOperation(key: string, notice: GoalOperationNotice) {
  if (managedGoalCredentialRefused() || executionWorkspaceAuthority.peek() !== notice.authority || storedTokenRevision.peek() !== notice.authRevision
    || goalDecisionActor() !== notice.actor) return
  goalOperationNotices.value = { ...goalOperationNotices.peek(), [key]: notice }
}

function goalOperationNoticeMessage(state: GoalOperationNoticeState): string {
  switch (state) {
    case 'transition_pending': return 'Goal 변경 요청을 처리 중입니다. 서버 수신 여부는 아직 확인되지 않았습니다.'
    case 'transition_ack': return '서버가 Goal 변경 요청에 응답했습니다. 요청한 작업 공간의 현재 상태를 확인해 주세요.'
    case 'transition_drop': return '서버가 Drop 요청에 응답했습니다. Goal 결과를 확인해 주세요.'
    case 'transition_unknown': return 'Goal 변경 결과를 확인하지 못했습니다. 다시 요청하기 전에 원래 작업 공간을 확인해 주세요.'
    case 'transition_refused': return 'Goal 변경 요청은 적용 전에 거절되었습니다.'
    case 'confirmation_pending': return '최종 확인 요청을 처리 중입니다. 서버 수신 여부는 아직 확인되지 않았습니다.'
    case 'confirmation_verified': return '확인 응답과 재조회에서 완료 기록이 일치했습니다.'
    case 'confirmation_unknown': return '최종 확인 결과를 확인하지 못했습니다. 다시 요청하기 전에 원래 작업 공간을 확인해 주세요.'
  }
}

function goalActionOwnerKey(owner: GoalActionOwner): string {
  return JSON.stringify([owner.epoch, owner.authorityIdentity, owner.connectionGeneration, owner.workspaceRoot, owner.mascRoot, owner.authScope, owner.actor, owner.goalId])
}

function dropAuthorityIdentity(authority: ExecutionWorkspaceAuthority): number {
  let identity = dropAuthorityIdentities.get(authority)
  if (identity === undefined) {
    identity = ++nextDropAuthorityIdentity
    dropAuthorityIdentities.set(authority, identity)
  }
  return identity
}

function dropViewKey(authority: ExecutionWorkspaceAuthority, workspace: ArtifactWorkspace,
  authRevision: number, actor: string, key: string | number): string {
  return JSON.stringify([dropAuthorityIdentity(authority), workspace.mascRoot, authRevision, actor, key])
}

function dropDraftForOwner(owner: GoalActionOwner): string | null {
  const draft = goalDropDrafts.value[goalActionOwnerKey(owner)]
  return draft && draft.reason.trim() !== '' ? draft.reason : null
}

function relatedEarlierGoalOwner(earlier: GoalActionOwner, current: GoalActionOwner): boolean {
  const sameLocation = earlier.workspaceRoot === current.workspaceRoot && earlier.mascRoot === current.mascRoot
    && earlier.goalId === current.goalId
  const previousConnection = (earlier.epoch !== current.epoch || earlier.authorityIdentity !== current.authorityIdentity)
    && earlier.authScope === current.authScope
    && earlier.actor === current.actor
  const dashboardBootstrap = earlier.actorName === 'dashboard' && earlier.authScope.startsWith('credential:')
    && current.authScope === 'managed-dev-dashboard'
  return sameLocation && (previousConnection || dashboardBootstrap)
}

function otherGoalActionPending(
  receipts: Record<string, GoalActionReceipt>, ownerKey: string, owner: GoalActionOwner,
): boolean {
  return Object.entries(receipts).some(([key, item]) => key !== ownerKey && item.state === 'pending'
    && item.owner.workspaceRoot === owner.workspaceRoot && item.owner.mascRoot === owner.mascRoot
    && item.owner.goalId === owner.goalId)
}

/** Requests can outlive a detail panel. Keep their last result with its Goal
    for this dashboard session, including while that Goal is not selected. */
function setGoalActionReceipt(ownerKey: string, receipt: GoalActionReceipt) {
  batch(() => {
    goalActionReceipts.value = { ...goalActionReceipts.value, [ownerKey]: receipt }
    if (receipt.state !== 'pending') {
      const previous = goalActionHistory.peek()[ownerKey] ?? []
      goalActionHistory.value = { ...goalActionHistory.peek(),
        [ownerKey]: [...previous.filter(item => item.ticket !== receipt.ticket), receipt] }
    }
  })
}

export function _testResetGoalActionReceipts() {
  goalOperationNotices.value = {}
  goalActionReceipts.value = {}
  goalActionHistory.value = {}
  goalDropDrafts.value = {}
  hiddenDropReceipts.value = new Set()
  expandedEarlierDropReceipts.value = new Set()
  expandedEarlierDropDrafts.value = new Set()
}

function setGoalDropDraft(key: string, value: string | null, owner?: GoalActionOwner) {
  const next = { ...goalDropDrafts.peek() }
  if (value === null) delete next[key]
  else if (owner) next[key] = { owner, reason: value }
  goalDropDrafts.value = next
}

function toggleNode(id: string) {
  const next = new Set(expandedNodes.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedNodes.value = next
}

function selectGoal(id: string) {
  if (route.value.params.goal && route.value.params.goal !== id) {
    const params = { ...route.value.params }
    delete params.goal
    replaceRoute('workspace', params)
  }
  setSelectedGoal(id)
}

function cleanRouteGoalId(value: string | undefined): string | null {
  return value && value.length > 0 ? value : null
}

function goalExpansionPath(nodes: readonly GoalTreeNode[], goalId: string): string[] | null {
  for (const node of nodes) {
    if (node.id === goalId) return [node.id]
    const childPath = goalExpansionPath(node.children, goalId)
    if (childPath) return [node.id, ...childPath]
  }
  return null
}

function expandAll(nodes: GoalTreeNode[]) {
  const ids = new Set(expandedNodes.value)
  function walk(items: GoalTreeNode[]) {
    for (const item of items) {
      ids.add(item.id)
      walk(item.children)
    }
  }
  walk(nodes)
  expandedNodes.value = ids
}

function collapseAll() {
  expandedNodes.value = new Set()
}

async function refreshTree() {
  const request = ++treeRequestSeq
  treeRequestInFlight.peek()?.controller.abort()
  treeWorkspaceAttestation = null
  treeDecisionBinding.value = null
  const authority = executionWorkspaceAuthority.peek()
  if (!authority) {
    treeRequestInFlight.value = null
    treeDecisionBinding.value = null
    treeErrorOwner.value = null
    treeRetryIntent.value = null
    treeLoading.value = false
    return
  }
  const authRevision = storedTokenRevision.peek()
  const actor = goalDecisionActor()
  const sentToken = getStoredToken()
  const intent = treeRetryIntent.peek()
  if (intent && (intent.authority !== authority || intent.authRevision !== authRevision || intent.actor !== actor)) {
    treeRetryIntent.value = null
  }
  const observationRevision = goalTreeObservationRevision.peek()
  const controller = new AbortController()
  const current = () => treeRequestSeq === request && executionWorkspaceAuthority.peek() === authority
    && storedTokenRevision.peek() === authRevision && goalDecisionActor() === actor
    && goalTreeObservationRevision.peek() === observationRevision
  const workspaceReady = (async () => captureArtifactWorkspace(
    authority.workspaceRoot, controller.signal, { reportCredentialRefusal: false }))()
  let requestWorkspace: ArtifactWorkspace | null = null
  treeRequestInFlight.value = { request, authority, authRevision, actor, observationRevision, controller, workspace: null, workspaceReady }
  treeLoading.value = true
  treeError.value = null
  try {
    const workspace = await workspaceReady
    if (!current()) return
    requestWorkspace = workspace
    treeWorkspaceAttestation = { request, authority, authRevision, actor, workspace }
    const active = treeRequestInFlight.peek()
    if (active?.request === request) treeRequestInFlight.value = { ...active, workspace }
    if (replaceReadBeforeWrite(request, authority, authRevision, actor, workspace)) return
    // Recovery may need the workspace attestation after a write even when
    // this credential is refused. Do not send another authenticated tree read.
    if (managedGoalCredentialRefused()) {
      treeRetryIntent.value = null
      return
    }
    const payload = await fetchDashboardGoalsTree(workspace, controller.signal, status => {
      if (status === 401 && sentToken && getStoredToken() === sentToken && getStoredTokenMeta()?.source === 'dev' && current()) {
        noteManagedCredentialRefusalObservation(authRevision)
      }
    })
    if (!current() || managedGoalCredentialRefused()) return
    if (replaceReadBeforeWrite(request, authority, authRevision, actor, workspace)) return
    batch(() => {
      if (!hydrateGoalTreeSnapshot(payload)) {
        treeDecisionBinding.value = null
        hydrateGoalTreeObservationError(new Error('Goal Store tree payload was malformed'))
        recordTreeErrorOwner(authority, authRevision, actor)
      } else {
        const snapshot = treeData.peek()
        if (snapshot) treeErrorOwner.value = null
        treeDecisionBinding.value = authority && workspace && snapshot ? { authority, workspace, snapshot, authRevision, actor } : null
        if (!snapshot && (treeError.peek() || storeUnavailable.peek())) recordTreeErrorOwner(authority, authRevision, actor)
      }
      treeRetryIntent.value = null
    })
  } catch (err) {
    const credentialRefusal = err instanceof ApiRequestError && (err.status === 401 || err.status === 403)
    const sameOwner = treeRequestSeq === request && executionWorkspaceAuthority.peek() === authority
      && storedTokenRevision.peek() === authRevision && goalDecisionActor() === actor
    if (!current() && !(sameOwner && credentialRefusal)) return
    const retry = treeRetryIntent.peek()
    if (!credentialRefusal && retry?.authority === authority && retry.authRevision === authRevision
      && retry.actor === actor && retry.afterWrite && request <= retry.afterWrite.request) {
      void refreshTree()
      return
    }
    const observationError = credentialRefusal
      ? new Error('인증 또는 권한이 거부되었습니다. 로그인 상태를 확인하거나 인증을 갱신한 뒤 다시 확인해 주세요.') : err
    batch(() => {
      treeDecisionBinding.value = null
      if (!hydrateGoalTreeError(observationError)) hydrateGoalTreeObservationError(observationError)
      recordTreeErrorOwner(authority, authRevision, actor)
      treeRetryIntent.value = null
    })
    if (err instanceof ApiRequestError && err.status === 401 && sentToken && requestWorkspace) {
      void recoverScopedRejectedCredential({ token: sentToken, authErrorCode: err.authErrorCode, httpStatus: 401 }, () =>
        treeRequestSeq === request && executionWorkspaceAuthority.peek() === authority
        && storedTokenRevision.peek() === authRevision && goalDecisionActor() === actor, undefined, requestWorkspace)
    }
  } finally {
    if (treeRequestInFlight.peek()?.request === request) treeRequestInFlight.value = null
    if (treeRequestSeq === request) treeLoading.value = false
  }
}

function sameArtifactWorkspace(left: ArtifactWorkspace, right: ArtifactWorkspace): boolean {
  return left.basePath === right.basePath && left.mascRoot === right.mascRoot
}

// A write that completed during an earlier read needs a later observation.
// Do not bind the earlier response, even if the transport ignored its abort.
function replaceReadBeforeWrite(request: number, authority: ExecutionWorkspaceAuthority, authRevision: number,
  actor: string, workspace: ArtifactWorkspace): boolean {
  const retry = treeRetryIntent.peek()
  if (!retry?.afterWrite || retry.authority !== authority || retry.authRevision !== authRevision || retry.actor !== actor) return false
  if (!sameArtifactWorkspace(retry.afterWrite.workspace, workspace)) {
    // This read belongs to a different current workspace. Keep that read but
    // do not treat it as the post-write observation for the original one.
    treeRetryIntent.value = null
    return false
  }
  if (request > retry.afterWrite.request) return false
  void refreshTree()
  return true
}

function refreshTreeAfterWrite(binding: NonNullable<typeof treeDecisionBinding.value>): boolean {
  const authority = executionWorkspaceAuthority.peek()
  if (treeConsumerCount === 0 || authority !== binding.authority
    || storedTokenRevision.peek() !== binding.authRevision || goalDecisionActor() !== binding.actor) return false
  const currentBinding = treeDecisionBinding.peek()
  if (currentBinding && (currentBinding.authority !== authority
    || !sameArtifactWorkspace(currentBinding.workspace, binding.workspace))) return false
  const active = treeRequestInFlight.peek()
  if (active && (active.authority !== authority || active.authRevision !== binding.authRevision
    || active.actor !== binding.actor || (active.workspace && !sameArtifactWorkspace(active.workspace, binding.workspace)))) return false
  const retry = treeRetryIntent.peek()
  if (retry?.afterWrite && retry.authority === authority && retry.authRevision === binding.authRevision
    && retry.actor === binding.actor && !sameArtifactWorkspace(retry.afterWrite.workspace, binding.workspace)) return false
  treeRetryIntent.value = { authority, authRevision: binding.authRevision, actor: binding.actor,
    afterWrite: { workspace: binding.workspace, request: treeRequestSeq } }
  // A read whose workspace has not yet been captured may belong to another
  // root under the same connection. Let it identify its root before replacing it.
  if (!active || active.workspace) void refreshTree()
  return true
}

// The credential or actor can change while a write is in flight. If the new
// view has independently identified the same workspace, let that owner read
// again after the old write; do not expose the old response to the new owner.
function refreshRelatedTreeAfterWrite(binding: NonNullable<typeof treeDecisionBinding.value>): boolean {
  const current = treeDecisionBinding.peek()
  if (current && current.authority === binding.authority && sameArtifactWorkspace(current.workspace, binding.workspace)) {
    return refreshTreeAfterWrite(current)
  }
  const active = treeRequestInFlight.peek()
  if (!active?.workspace || active.authority !== binding.authority
    || !sameArtifactWorkspace(active.workspace, binding.workspace)) return false
  return refreshTreeAfterWrite({ ...binding, authRevision: active.authRevision, actor: active.actor })
}

function retryTree() {
  if (managedGoalCredentialRefused()) {
    if (goalAuthRetryPromise) return goalAuthRetryPromise
    const authority = executionWorkspaceAuthority.peek()
    const authRevision = storedTokenRevision.peek()
    const actor = goalDecisionActor()
    const confirmedRefusal = managedDashboardRefusal.peek() === authRevision
    const binding = treeDecisionBinding.peek()
    const attestation = treeWorkspaceAttestation
    const ownedBinding = binding && binding.authority === authority && binding.authRevision === authRevision && binding.actor === actor
      ? binding : null
    const ownedAttestation = !ownedBinding && attestation && attestation.request === treeRequestSeq
      && attestation.authority === authority && attestation.authRevision === authRevision && attestation.actor === actor
      ? attestation : null
    const workspace = ownedBinding?.workspace ?? ownedAttestation?.workspace ?? null
    let retired = false
    let authorityRetired = false
    const isCurrent = () => !retired && authority !== null && executionWorkspaceAuthority.peek() === authority
      && storedTokenRevision.peek() === authRevision && goalDecisionActor() === actor && managedGoalCredentialRefused()
      && (ownedBinding !== null ? treeDecisionBinding.peek() === ownedBinding
        : ownedAttestation !== null && treeWorkspaceAttestation === ownedAttestation && treeRequestSeq === ownedAttestation.request)
    const stop = effect(() => {
      void executionWorkspaceAuthority.value
      void storedTokenRevision.value
      void dashboardActorRevision.value
      void managedDashboardActorRevision.value
      void managedDashboardRefusal.value
      void managedDashboardUnverified.value
      void treeDecisionBinding.value
      void treeRequestInFlight.value
      if (executionWorkspaceAuthority.peek() !== authority) authorityRetired = true
      if (workspace && !isCurrent()) retired = true
    })
    // A deliberate retry can recover a temporarily unavailable dev-token
    // endpoint. Do not interrupt an already running or scheduled recovery.
    const retry = Promise.resolve().then(async () => {
      let recheckShell = workspace === null || (!confirmedRefusal && managedDashboardRefusal.peek() !== authRevision)
      try {
        if (workspace && confirmedRefusal && isCurrent()) recheckShell = await retryRejectedDevToken(workspace, isCurrent)
      } finally {
        if (recheckShell && !authorityRetired && executionWorkspaceAuthority.peek() === authority) {
          await refreshShell({ force: true, recoverAuth: false })
        }
      }
    }).catch(error => {
      console.warn('[goals] authentication recheck failed:', error)
    }).finally(() => {
      stop()
      if (goalAuthRetryPromise === retry) {
        goalAuthRetryPromise = null
        goalAuthRetrying.value = false
      }
    })
    goalAuthRetryPromise = retry
    goalAuthRetrying.value = true
    return retry
  }
  const authority = executionWorkspaceAuthority.peek()
  if (!authority) return refreshExecution({ force: true }).catch(() => {})
  let request!: Promise<void>
  batch(() => {
    const authRevision = storedTokenRevision.peek()
    const actor = goalDecisionActor()
    const retry = treeRetryIntent.peek()
    if (!retry?.afterWrite || retry.authority !== authority || retry.authRevision !== authRevision || retry.actor !== actor) {
      treeRetryIntent.value = { authority, authRevision, actor }
    }
    request = refreshTree()
  })
  return request
}

async function refreshGoalDetail(goalId: string) {
  if (selectedGoalId.value !== goalId) return
  const binding = treeDecisionBinding.peek()
  if (managedGoalCredentialRefused() || !binding || binding.snapshot !== treeData.peek()
    || binding.authority !== executionWorkspaceAuthority.peek()
    || binding.authRevision !== storedTokenRevision.peek() || binding.actor !== goalDecisionActor()) return
  if (!goalIdIsUnambiguous(goalId, binding.snapshot)) {
    detailRequestSeq += 1
    detailData.value = null
    detailDecisionBinding.value = null
    detailLoading.value = false
    detailError.value = '현재 Goal 목록에서 ID를 구분할 수 없어 상세를 조회하지 않았습니다.'
    return
  }
  const reqId = ++detailRequestSeq
  const selectionRevision = selectedGoalRevision.peek()
  const sentToken = getStoredToken()
  const recoveryCurrent = () => detailRequestSeq === reqId && treeConsumerCount > 0 && selectedGoalId.value === goalId
    && selectedGoalRevision.peek() === selectionRevision
    && treeDecisionBinding.peek() === binding && treeData.peek() === binding.snapshot
    && executionWorkspaceAuthority.peek() === binding.authority
    && binding.authRevision === storedTokenRevision.peek() && binding.actor === goalDecisionActor()
  const current = () => !managedGoalCredentialRefused() && recoveryCurrent()
  detailLoading.value = true
  detailError.value = null
  try {
    const next = await fetchDashboardGoalDetail(goalId, binding.workspace, status => {
      if (status === 401 && sentToken && getStoredToken() === sentToken && getStoredTokenMeta()?.source === 'dev' && recoveryCurrent()) {
        noteManagedCredentialRefusalObservation(binding.authRevision)
      }
    })
    if (!next || typeof next !== 'object' || !('goal' in next)) {
      throw new Error('invalid goal detail payload')
    }
    if (!current()) return
    detailData.value = next
    detailDecisionBinding.value = binding
  } catch (err) {
    if (!recoveryCurrent()) return
    if (current()) {
      batch(() => {
        detailData.value = null
        detailDecisionBinding.value = null
        if (hydrateGoalTreeError(err)) {
          recordTreeErrorOwner(binding.authority, binding.authRevision, binding.actor)
          detailError.value = treeError.value
        } else {
          detailError.value = errorToString(err)
        }
      })
    }
    if (err instanceof ApiRequestError && err.status === 401 && sentToken) {
      void recoverScopedRejectedCredential({ token: sentToken, authErrorCode: err.authErrorCode, httpStatus: 401 },
        recoveryCurrent, undefined, binding.workspace)
    }
  } finally {
    if (current()) detailLoading.value = false
  }
}

function TreeSummary({
  summary,
  awaitingVerificationCount,
}: {
  summary: GoalTreeSummary
  awaitingVerificationCount: number
}) {
  return html`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(112px,1fr))] gap-2">
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.total_goals}</div>
        <div class="mt-1 ${DECK_LABEL}">전체 목표</div>
      </div>
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.phase_counts.executing ?? 0}</div>
        <div class="mt-1 ${DECK_LABEL}">실행</div>
      </div>
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.phase_counts.completed ?? 0}</div>
        <div class="mt-1 ${DECK_LABEL}">완료</div>
      </div>
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.phase_counts.verifying ?? 0}</div>
        <div class="mt-1 ${DECK_LABEL}">검증 중</div>
      </div>
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.pending_approvals}</div>
        <div class="mt-1 ${DECK_LABEL}">승인 대기</div>
      </div>
      ${awaitingVerificationCount > 0 ? html`
        <div class="rounded-[var(--r-0)] border border-[var(--color-brass-border)] bg-[var(--color-brass-soft)] p-3 text-center">
          <div class="font-mono text-xl font-semibold text-[var(--color-accent-fg)] tabular-nums">${awaitingVerificationCount}</div>
          <div class="mt-1 font-mono text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-accent-fg)]/80">Task 검증 대기</div>
        </div>
      ` : null}
    </div>
  `
}

function TreeTask({ task }: { task: GoalTreeTask }) {
  return html`
    <div class="flex flex-wrap items-center gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] px-2 py-1.5 text-xs">
      <span class="size-2 rounded-[var(--r-0)] shrink-0" style="background:${task.status_color}"></span>
      <span
        class="max-w-32 shrink truncate font-mono text-3xs text-text-dim"
        title=${`Task ID · ${task.id}`}
        translate="no"
      >${task.id}</span>
      <span class="min-w-0 flex-1 truncate text-text-body">${task.title}</span>
      ${task.assignee ? html`
        <span class="rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-1.5 py-0.5 text-3xs font-medium text-accent-fg">${task.assignee}</span>
      ` : null}
      <${StatusBadge} status=${task.status} />
    </div>
  `
}

function GoalTaskRelationStrip({
  node,
  compact = false,
}: {
  node: GoalTreeNode
  compact?: boolean
}) {
  const summary = goalTaskSummaryForNode(node)
  if (compact) {
    if (summary.total === 0) return null
    return html`
      <span
        class="rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-medium text-accent-fg"
        title=${`Goal-Task links: ${goalTaskCompletionLabel(summary)}`}
      >
        Task ${summary.done}/${summary.total}
      </span>
    `
  }

  return html`
    <div class=${CARD_BOX} data-goal-task-summary>
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div>
          <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">Goal-Task 관계</div>
          <div class="mt-1 text-sm text-text-body">${goalTaskCompletionLabel(summary)}</div>
        </div>
      </div>
      <div class="grid grid-cols-[repeat(auto-fit,minmax(110px,1fr))] gap-2 text-xs">
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
          <div class="text-3xs uppercase text-text-muted">open</div>
          <div class="mt-1 font-semibold text-text-strong">${summary.open}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
          <div class="text-3xs uppercase text-text-muted">awaiting verify</div>
          <div class="mt-1 font-semibold text-text-strong">${summary.awaiting_verification}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
          <div class="text-3xs uppercase text-text-muted">cancelled</div>
          <div class="mt-1 font-semibold text-text-strong">${summary.cancelled}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
          <div class="text-3xs uppercase text-text-muted">unassigned</div>
          <div class="mt-1 font-semibold text-text-strong">${summary.unassigned}</div>
        </div>
      </div>
    </div>
  `
}

function completionBindingForGoal(node: GoalTreeNode): {
  phase: 'executing' | 'verifying'; criterion_revision: string; request_id?: string
} | null {
  const phase = node.phase === 'executing' ? 'executing' : node.phase === 'verifying' ? 'verifying' : null
  if (phase === null) return null
  const proof = node.verification
  if (!proof || proof.state === 'unreadable') return null
  if (phase === 'verifying' && proof.state !== 'current') return null
  const completion = proof.state === 'current' ? proof.completion : proof.historical
  const binding: { phase: 'executing' | 'verifying'; criterion_revision: string } =
    { phase, criterion_revision: node.criterion_revision }
  if (completion.state === 'idle') return phase === 'executing' && proof.state === 'current' ? binding : null
  if (phase === 'verifying' && completion.state === 'proven' && completion.confirmation) return null
  const matches = completion.criterion.revision === node.criterion_revision
  if ((proof.state === 'current') !== matches) return null
  return { ...binding, request_id: completion.requestId }
}

function lifecycleActionsForGoal(node: GoalTreeNode): Array<{
  action: GoalTransitionAction
  variant: 'primary' | 'ok' | 'danger'
}> {
  return goalLifecycleActions(node.goal_fsm.next_actions)
    .filter(action => action !== 'request_complete' || completionBindingForGoal(node) !== null)
    .map(action => ({
    action,
    variant: action === 'drop' ? 'danger' : 'primary',
  }))
}

function GoalLifecycleActionPanel({ node }: { node: GoalTreeNode }) {
  const authority = executionWorkspaceAuthority.value
  const observed = treeDecisionBinding.value
  const tokenRevision = storedTokenRevision.value
  const binding = observed && observed.authority === authority && observed.snapshot === treeData.value
    && observed.authRevision === tokenRevision && observed.actor === goalDecisionActor() ? observed : null
  const identityUnsafe = binding !== null && !goalIdIsUnambiguous(node.id, binding.snapshot)
  const actions = identityUnsafe ? [] : lifecycleActionsForGoal(node)
  const authScope = goalActionAuthScope(tokenRevision)
  const owner = authority && binding ? { epoch: authority.epoch, authorityIdentity: dropAuthorityIdentity(authority), connectionGeneration: authority.connectionGeneration, workspaceRoot: authority.workspaceRoot,
    mascRoot: binding.workspace.mascRoot, authRevision: tokenRevision, authScope, actor: binding.actor,
    actorName: currentDashboardActor(), goalId: node.id } : null
  const ownerKey = owner ? goalActionOwnerKey(owner) : ''
  const receipt = goalActionReceipts.value[ownerKey]
  const history = (goalActionHistory.value[ownerKey] ?? []).filter(item => item.ticket !== receipt?.ticket)
  const previous = owner ? [
    ...Object.values(goalActionHistory.value).flat(),
    ...Object.values(goalActionReceipts.value).filter(item => item.state === 'pending'),
  ].filter(item => relatedEarlierGoalOwner(item.owner, owner)) : []
  const pendingAction = receipt?.state === 'pending' ? receipt.action : null
  const previousPending = previous.some(item => item.state === 'pending')
  const otherPending = owner ? otherGoalActionPending(goalActionReceipts.value, ownerKey, owner) : false
  const confirmationInFlight = binding ? confirmationPending(binding.workspace, node.id) : false
  const otherUncertain = owner ? Object.entries(goalActionHistory.value).some(([key, items]) => key !== ownerKey
    && items.some(item => item.uncertain && item.owner.workspaceRoot === owner.workspaceRoot
      && item.owner.mascRoot === owner.mascRoot && item.owner.goalId === owner.goalId)) : false
  // Drop opens a reason instead of sending: the server refuses a drop that
  // does not say why, and each cancelled Task's author is told that sentence.
  const dropReason = goalDropDrafts.value[ownerKey]?.reason ?? null
  const previousDrafts = owner ? Object.values(goalDropDrafts.value).filter(item =>
    item.reason.trim() !== '' && relatedEarlierGoalOwner(item.owner, owner)) : []
  const previousViewKey = (key: string | number) => authority && binding && owner
    ? dropViewKey(authority, binding.workspace, tokenRevision, owner.actor, key) : ''
  const canRevealPrevious = () => Boolean(authority && binding && owner
    && !managedGoalCredentialRefused()
    && executionWorkspaceAuthority.peek() === authority && treeDecisionBinding.peek() === binding
    && treeData.peek() === binding.snapshot && storedTokenRevision.peek() === owner.authRevision
    && goalDecisionActor() === owner.actor)

  const runAction = useCallback((action: GoalTransitionAction, note?: string) => {
    if (managedGoalCredentialRefused() || !authority || !binding || !owner || executionWorkspaceAuthority.peek() !== authority
      || treeDecisionBinding.peek() !== binding || treeData.peek() !== binding.snapshot
      || storedTokenRevision.peek() !== binding.authRevision
      || !goalIdIsUnambiguous(node.id, binding.snapshot)) return
    if (goalDecisionActor() !== binding.actor) {
      showToast('인증 정보가 변경되어 Goal을 다시 확인합니다.', 'warning')
      void refreshTree()
      return
    }
    const completionBinding = action === 'request_complete' ? completionBindingForGoal(node) : null
    if (action === 'request_complete' && completionBinding === null) {
      setGoalActionReceipt(ownerKey, { owner, ticket: ++goalActionTicket, action, state: 'error',
        message: '검증 요청을 읽지 못했습니다. 새로고침 후 다시 시도해 주세요.' })
      return
    }
    if (confirmationPending(binding.workspace, node.id) || goalActionReceipts.value[ownerKey]?.state === 'pending'
      || otherGoalActionPending(goalActionReceipts.peek(), ownerKey, owner)) return
    const actorId = currentDashboardActor()
    const actionSelectionRevision = selectedGoalRevision.peek()
    let recoveryObservation: { request: number; observation: number; workspace: ArtifactWorkspace } | null = null
    let recoveryRetired = false
    const recoveryBaseCurrent = () => !recoveryRetired && treeConsumerCount > 0 && executionWorkspaceAuthority.peek() === authority
      && storedTokenRevision.peek() === owner.authRevision && goalDecisionActor() === owner.actor
      && selectedGoalId.peek() === node.id && selectedGoalRevision.peek() === actionSelectionRevision
    const recoveryCurrent = () => {
      if (!recoveryBaseCurrent()) return false
      const current = treeDecisionBinding.peek()
      if (current && current.authority === authority && current.authRevision === owner.authRevision
        && current.actor === owner.actor && sameArtifactWorkspace(current.workspace, binding.workspace)) return true
      const attestation = treeWorkspaceAttestation
      if (attestation && attestation.request === treeRequestSeq && attestation.authority === authority
        && attestation.authRevision === owner.authRevision && attestation.actor === owner.actor
        && sameArtifactWorkspace(attestation.workspace, binding.workspace)) return true
      return Boolean(recoveryObservation && recoveryObservation.request === treeRequestSeq
        && recoveryObservation.observation === goalTreeObservationRevision.peek()
        && sameArtifactWorkspace(recoveryObservation.workspace, binding.workspace))
    }
    const waitForRecoveryCurrent = async () => {
      if (!recoveryBaseCurrent()) return false
      const request = treeRequestSeq
      const observation = goalTreeObservationRevision.peek()
      try {
        const workspace = await captureArtifactWorkspace(authority.workspaceRoot, undefined, { reportCredentialRefusal: false })
        if (!recoveryBaseCurrent() || request !== treeRequestSeq || observation !== goalTreeObservationRevision.peek()
          || !sameArtifactWorkspace(workspace, binding.workspace)) return false
        recoveryObservation = { request, observation, workspace }
        return true
      } catch { return false }
    }
    const ticket = ++goalActionTicket
    const stopRecoveryOwner = effect(() => {
      void executionWorkspaceAuthority.value
      void storedTokenRevision.value
      void dashboardActorRevision.value
      void managedDashboardActorRevision.value
      void selectedGoalRevision.value
      void treeDecisionBinding.value
      void treeRequestInFlight.value
      if (!recoveryBaseCurrent()) recoveryRetired = true
    })
    setGoalActionReceipt(ownerKey, { owner, ticket, action, state: 'pending', message: '', ...(completionBinding ? { binding: completionBinding } : {}) })
    const notice = (state: GoalOperationNoticeState) => rememberGoalOperation(`transition:${ticket}`, {
      authority, authRevision: owner.authRevision, actor: owner.actor, workspace: binding.workspace, goalId: node.id, state,
    })
    notice('transition_pending')
    const ownerIsCurrent = () => {
      const current = executionWorkspaceAuthority.peek()
      const currentBinding = treeDecisionBinding.peek()
      return !managedGoalCredentialRefused() && current === authority
        && currentBinding?.authority === current && currentBinding.snapshot === treeData.peek()
        && sameArtifactWorkspace(currentBinding.workspace, binding.workspace)
        && storedTokenRevision.peek() === owner.authRevision && goalDecisionActor() === owner.actor
    }
    void (async () => {
      try {
        const response = await callMcpToolAtIdentity('masc_goal_transition', {
          goal_id: node.id,
          action,
          expected_workspace: artifactWorkspaceBody(binding.workspace),
          ...(note === undefined ? {} : { note }),
          ...(completionBinding === null ? {} : { expected_verification: completionBinding }),
        }, { revision: owner.authRevision, actor: actorId }, () => !managedGoalCredentialRefused()
          && executionWorkspaceAuthority.peek() === authority
          && treeDecisionBinding.peek() === binding && treeData.peek() === binding.snapshot
          && storedTokenRevision.peek() === binding.authRevision && goalDecisionActor() === binding.actor
          && selectedGoalId.peek() === node.id && selectedGoalRevision.peek() === actionSelectionRevision
          && goalIdIsUnambiguous(node.id, binding.snapshot), recoveryCurrent, waitForRecoveryCurrent)
        const retry = action === 'request_complete' && node.phase === 'verifying'
        const parsed: unknown = JSON.parse(response)
        if (!isRecord(parsed) || parsed.status !== 'ok'
          || parsed.goal_id !== node.id || parsed.action !== action) {
          throw new Error('Goal transition response does not match the request')
        }
        const reconciled = parsed.reconciled === true
        const message = reconciled ? 'Existing verification reconciled'
          : retry ? 'Verification retry requested' : `${GOAL_TRANSITION_LABELS[action]} applied`
        const outcome = action === 'drop' ? goalDropReceipt(parsed, note) : { state: 'success' as const, message }
        if (goalActionReceipts.value[ownerKey]?.ticket !== ticket) return
        setGoalActionReceipt(ownerKey, { owner, ticket, action, ...outcome, ...(completionBinding ? { binding: completionBinding } : {}) })
        notice(action === 'drop' ? 'transition_drop' : 'transition_ack')
        const wasCurrent = ownerIsCurrent()
        const refreshRequested = refreshTreeAfterWrite(binding) || refreshRelatedTreeAfterWrite(binding)
        if (!wasCurrent) {
          if (managedGoalCredentialRefused()) return
          if (!refreshRequested) showToast('이전 연결의 Goal 변경 결과가 도착했습니다. 원래 workspace에서 확인하세요.', 'warning')
          return
        }
        if (selectedGoalId.value !== node.id) {
          if (outcome.state === 'warning') showToast('Drop 시도 결과에 확인할 항목이 있습니다. 원래 workspace에서 확인하세요.', 'warning')
          else showToast(`Goal ${node.id}: ${action === 'drop' ? 'Drop applied' : message}`)
        }
      } catch (err) {
        const rawDetail = errorToString(err)
        const disposition = mcpCallFailureDisposition(err)
        const requestDetail = disposition === 'outcome_unknown'
          ? `요청 결과를 확인하지 못했습니다. 다시 시도하기 전에 원래 Goal 상태를 확인하세요. ${rawDetail}`
          : disposition === 'known_tool_response'
            ? `${rawDetail} 일부 변경이 적용되었을 수 있습니다. 다시 시도하기 전에 Goal 상태를 확인하세요.` : rawDetail
        const detail = action === 'drop' ? `${dropReceiptContext(node.id, note)}\n${requestDetail}` : requestDetail
        if (goalActionReceipts.value[ownerKey]?.ticket !== ticket) return
        setGoalActionReceipt(ownerKey, { owner, ticket, action, state: 'error', message: detail,
          uncertain: disposition !== 'known_pre_effect', ...(completionBinding ? { binding: completionBinding } : {}) })
        notice(disposition === 'known_pre_effect' ? 'transition_refused' : 'transition_unknown')
        const wasCurrent = ownerIsCurrent()
        const refreshRequested = disposition !== 'known_pre_effect'
          && (refreshTreeAfterWrite(binding) || refreshRelatedTreeAfterWrite(binding))
        if (!wasCurrent) {
          if (managedGoalCredentialRefused()) return
          if (mcpIdentityRequiresGoalRefresh(err)) {
            showToast('인증이 변경되거나 거부되어 Goal을 변경하지 않았습니다. 현재 Goal을 다시 확인한 뒤 요청해 주세요.', 'warning')
            return
          }
          if (!refreshRequested) showToast('이전 연결의 Goal 변경 결과가 도착했습니다. 원래 workspace에서 확인하세요.', 'warning')
          return
        }
        if (selectedGoalId.value !== node.id) {
          if (action === 'drop') showToast('Drop 시도의 결과를 원래 workspace에서 확인하세요.', 'warning')
          else showToast(`Goal ${node.id}: ${detail}`, 'error')
        }
      } finally {
        stopRecoveryOwner()
      }
    })()
  }, [node, ownerKey, authority, binding, tokenRevision, previousPending])

  const bindingUnavailable = (node.phase === 'executing' || node.phase === 'verifying')
    && completionBindingForGoal(node) === null
  if (actions.length === 0 && !receipt && !bindingUnavailable && !identityUnsafe && dropReason === null && !otherPending && !confirmationInFlight
    && !otherUncertain && previous.length === 0 && previousDrafts.length === 0) return null

  return html`
    <div class=${CARD_BOX} data-goal-lifecycle-actions>
      ${identityUnsafe ? html`<p role="status" class="mb-3 text-xs text-text-muted">현재 Goal 목록에서 ID를 구분할 수 없어 변경을 사용할 수 없습니다.</p>` : null}
      ${bindingUnavailable ? html`
        <p role="status" class="mb-3 text-xs text-text-muted">검증 상태를 확인할 수 없어 완료 요청이나 재검증을 사용할 수 없습니다. ${node.phase === 'verifying' ? '이전 검증이 아직 진행 중일 수 있습니다. ' : ''}서버의 저장소와 실행 환경을 확인하거나 운영자에게 문의하고, 문제가 복구되면 Goal을 새로고침해 주세요.</p>` : null}
      ${binding === null ? html`<p role="status" class="mb-3 text-xs text-text-muted">현재 workspace에서 Goal을 다시 확인한 뒤 변경할 수 있습니다.</p>` : null}
      ${otherPending && !previousPending ? html`<p role="status" class="mb-3 text-xs text-text-muted">다른 연결 또는 인증의 같은 Goal 요청이 끝나기를 기다리는 중입니다.</p>` : null}
      ${confirmationInFlight ? html`<p role="status" class="mb-3 text-xs text-text-muted">이 목표의 최종 확인이 끝나기를 기다리는 중입니다.</p>` : null}
      ${otherUncertain && !otherPending ? html`<p role="status" class="mb-3 text-xs text-text-muted">다른 연결 또는 인증의 Goal 요청에 확인이 필요한 항목이 있습니다. 현재 상태를 확인해 주세요.</p>` : null}
      ${node.resume_phase ? html`<p class="mb-3 text-xs text-text-muted" data-goal-resume-phase>재개 시 ${goalPhaseLabel(node.resume_phase)} · 연결된 Task는 별도로 진행됩니다.</p>` : null}
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div>
          <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">Goal lifecycle</div>
        </div>
        <span class="${DECK_CHIP} text-[var(--color-fg-secondary)]">${node.phase}</span>
      </div>
      <div class="flex flex-wrap gap-2">
        ${actions.map(({ action, variant }) => {
          const label = action === 'request_complete' && node.phase === 'verifying'
            ? 'Retry verification'
            : GOAL_TRANSITION_LABELS[action]
          const isPending = pendingAction === action
          return html`
            <${ActionButton}
              key=${action}
              variant=${variant}
              size="sm"
              disabled=${pendingAction !== null || otherPending || confirmationInFlight || binding === null}
              ariaBusy=${isPending}
              ariaLabel=${label}
              title=${label}
              onClick=${() => {
                if (action === 'drop') {
                  setGoalDropDraft(ownerKey, dropReason ?? '', owner ?? undefined)
                } else {
                  runAction(action)
                }
              }}
            >
              ${isPending ? 'Working...' : label}
            <//>
          `
        })}
      </div>
      ${dropReason === null ? null : html`
        <form
          class="mt-3 flex flex-col gap-2"
          data-goal-drop-reason
          onSubmit=${(event: Event) => {
            event.preventDefault()
            const reason = dropReason.trim()
            if (reason !== '' && actions.some(item => item.action === 'drop')) runAction('drop', reason)
          }}
        >
          <label class="flex flex-col gap-1 text-xs text-text-muted">
            <span>Drop 사유 · 같은 ID의 현재 Goal이 초안 작성 당시와 동일한 인스턴스인지는 확인되지 않았습니다.</span>
            <textarea
              rows=${2}
              class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2 text-text-strong"
              value=${dropReason}
              disabled=${pendingAction !== null}
              autoFocus
              onInput=${(event: Event) => setGoalDropDraft(ownerKey, (event.target as HTMLTextAreaElement).value, owner ?? undefined)}
            ></textarea>
          </label>
          <div class="flex flex-wrap gap-2">
            <${ActionButton}
              type="submit"
              variant="danger"
              size="sm"
              disabled=${pendingAction !== null || otherPending || confirmationInFlight || binding === null
                || dropReason.trim() === '' || !actions.some(item => item.action === 'drop')}
              ariaBusy=${pendingAction === 'drop'}
            >
              Drop goal
            <//>
            <${ActionButton}
              variant="ghost"
              size="sm"
              disabled=${pendingAction !== null}
              onClick=${() => setGoalDropDraft(ownerKey, null)}
            >
              사유 초안 지우기
            <//>
          </div>
        </form>
      `}
      ${receipt?.state === 'success' ? html`
        <div class="mt-3 whitespace-pre-wrap break-words rounded-[var(--r-1)] border border-[var(--ok-25)] bg-[var(--ok-10)] px-3 py-2 text-xs text-[var(--color-status-ok)]" data-testid="goal-lifecycle-action-status">
          ${receipt.message}
        </div>
      ` : null}
      ${receipt?.state === 'warning' ? html`
        <div role="status" class="mt-3 whitespace-pre-wrap break-words rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-xs text-[var(--color-status-warn)]" data-testid="goal-lifecycle-action-warning">
          ${receipt.message}
        </div>
      ` : null}
      ${receipt?.state === 'error' ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-[var(--err-25)] bg-[var(--err-10)] px-3 py-2 text-xs text-[var(--color-status-err)]" data-testid="goal-lifecycle-action-error">
          ${receipt.message}
        </div>
      ` : null}
      ${receipt?.binding && receipt.state !== 'pending' ? html`
        <p class="mt-2 break-all text-xs text-text-muted" data-testid="goal-lifecycle-action-binding">
          요청 당시 기준 ${receipt.binding.criterion_revision} · 검증 요청 ${receipt.binding.request_id ?? '없음'}
        </p>` : null}
      ${history.length > 0 ? html`
        <div class="mt-3 space-y-1 text-xs text-text-muted" data-testid="goal-lifecycle-action-history">
          ${history.map(item => html`<p key=${item.ticket} class="whitespace-pre-wrap break-words">
            ${item.message}${item.binding ? ` · 요청 당시 기준 ${item.binding.criterion_revision} · 검증 요청 ${item.binding.request_id ?? '없음'}` : ''}
          </p>`)}
        </div>` : null}
      ${previous.length > 0 ? html`
        <div class="mt-3 space-y-1 text-xs text-text-muted" data-testid="goal-lifecycle-previous-connection">
          <p>이전 연결이나 인증의 요청 기록입니다. 현재 서버와 같은 workspace인지는 확인되지 않았습니다.</p>
          ${previous.map(item => html`<div key=${item.ticket}>
            <p class="whitespace-pre-wrap break-words">
              서버 ${item.owner.epoch} · ${GOAL_TRANSITION_LABELS[item.action]} · ${item.state === 'pending' ? '결과 대기 중'
                : item.action === 'drop' ? '이전 연결 결과' : item.message}
              ${item.binding ? ` · 기준 ${item.binding.criterion_revision} · 검증 요청 ${item.binding.request_id ?? '없음'}` : ''}
            </p>
            ${item.action === 'drop' && item.state !== 'pending' ? html`
              <button type="button" onClick=${() => {
                if (!canRevealPrevious()) return
                const key = previousViewKey(item.ticket)
                const next = new Set(expandedEarlierDropReceipts.peek())
                if (next.has(key)) next.delete(key)
                else next.add(key)
                expandedEarlierDropReceipts.value = next
              }}>${expandedEarlierDropReceipts.value.has(previousViewKey(item.ticket)) ? '이전 연결 결과 숨기기' : '이전 연결 결과 보기'}</button>
              ${expandedEarlierDropReceipts.value.has(previousViewKey(item.ticket)) ? html`
                <p class="whitespace-pre-wrap break-words">${item.message}</p>` : null}` : null}
          </div>`)}
        </div>` : null}
      ${previousDrafts.length > 0 ? html`
        <div class="mt-3 space-y-1 text-xs text-text-muted" data-testid="goal-drop-previous-drafts">
          <p>이전 연결이나 인증에서 보존된 Drop 사유입니다. 요청이 이미 적용됐을 수 있으니 상태를 확인해 주세요.</p>
          ${previousDrafts.map(item => html`<div key=${goalActionOwnerKey(item.owner)}>
            <p>서버 ${item.owner.epoch} · 이전 연결 초안</p>
            <button type="button" onClick=${() => {
              if (!canRevealPrevious()) return
              const key = previousViewKey(goalActionOwnerKey(item.owner))
              const next = new Set(expandedEarlierDropDrafts.peek())
              if (next.has(key)) next.delete(key)
              else next.add(key)
              expandedEarlierDropDrafts.value = next
            }}>${expandedEarlierDropDrafts.value.has(previousViewKey(goalActionOwnerKey(item.owner))) ? '이전 연결 초안 숨기기' : '이전 연결 초안 보기'}</button>
            ${expandedEarlierDropDrafts.value.has(previousViewKey(goalActionOwnerKey(item.owner))) ? html`
              <p class="whitespace-pre-wrap">${item.reason}</p>
              <button type="button" disabled=${pendingAction !== null || otherPending || (dropReason !== null && dropReason !== '')}
                onClick=${() => {
                  if (!owner || !canRevealPrevious()) return
                  const current = goalDropDrafts.peek()[ownerKey]?.reason
                  if (current !== undefined && current !== '') return
                  setGoalDropDraft(ownerKey, item.reason, owner)
                }}>이 사유를 현재 입력에 복사</button>
              ${dropReason !== null && dropReason !== '' ? html`<p>현재 초안을 지운 뒤 복사할 수 있습니다.</p>` : null}` : null}
          </div>`)}
        </div>` : null}
    </div>
  `
}

function TreeNode({ node, depth }: { node: GoalTreeNode; depth: number }) {
  const isExpanded = expandedNodes.value.has(node.id)
  const hasContent = node.children.length > 0 || node.tasks.length > 0
  const isSelected = selectedGoalId.value === node.id
  const indent = depth * 20
  const headerBase = isSelected
    ? TREE_NODE_CARD_ACTIVE
    : `${TREE_NODE_CARD_BASE} border-[var(--color-border-default)] bg-[var(--color-bg-surface)] hover:border-[var(--color-border-strong)]`

  return html`
    <div class="flex flex-col" style="margin-left:${indent}px">
      <button
        type="button"
        class="v2-workspace-row ${headerBase} ${hasContent ? 'cursor-pointer' : ''} ${ringFocusClasses()}"
        onClick=${() => {
          selectGoal(node.id)
          if (hasContent) toggleNode(node.id)
        }}
        aria-expanded=${hasContent ? isExpanded : undefined}
      >
        ${hasContent ? html`
          <span class="mt-0.5 shrink-0 text-xs text-text-dim transition-transform ${isExpanded ? 'rotate-90' : ''}">\u25B6</span>
        ` : html`
          <span class="mt-0.5 shrink-0 text-xs text-text-dim/30">\u25CB</span>
        `}

        <div class="min-w-0 flex-1">
          <div class="mb-1 flex flex-wrap items-center gap-2">
            <${StatusBadge} status=${goalPhaseStatus(node.phase)} label=${goalPhaseLabel(node.phase)} />
            <${GoalFsmBadge} fsm=${node.goal_fsm} />
            <span class="break-words text-base font-semibold text-text-strong line-clamp-2">${node.title}</span>
            <span class="text-2xs text-text-dim">${priorityStars(node.priority)}</span>
          </div>

          <div class="flex flex-wrap items-center gap-2.5 text-2xs text-text-muted">
            ${node.task_count > 0 ? html`<div class="w-32"><${TaskProgressBar} done=${node.task_done_count} total=${node.task_count} size="sm" /></div>` : null}
            <${GoalTaskRelationStrip} node=${node} compact />
            ${node.metric ? html`
              <span
                class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-1.5 py-0.5 font-mono text-3xs text-text-secondary"
                title=${`metric · ${node.metric}${node.target_value ? ` → ${node.target_value}` : ''}`}
              >
                <span aria-hidden="true">↗ </span>${node.metric}${node.target_value ? html`<span class="ml-1 text-text-strong"> · ${node.target_value}</span>` : null}
              </span>
            ` : null}
            <${GoalMeasurementBadge} node=${node} />
            <${GoalCriterionReviewStatus} review=${node.criterion_review} />
            ${(() => {
              const awaiting = countAwaitingVerificationTasks(node.tasks)
              return awaiting > 0 ? html`
                <span class="rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-medium text-accent-fg" title="시스템 LLM agent의 판정을 기다리는 task">
                  Task 검증 대기 ${awaiting}
                </span>
              ` : null
            })()}
            ${node.child_count > 0 ? html`<span>${node.child_count} 하위 목표</span>` : null}
            ${node.pending_approval_count > 0 ? html`
              <span class="rounded-[var(--r-1)] border border-warn/30 bg-warn/10 px-2 py-0.5 text-3xs font-medium text-warn">
                approval ${node.pending_approval_count}
              </span>
            ` : null}
            ${node.latest_keeper_ref ? html`
              <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-medium text-text-body">
                ${node.latest_keeper_ref}${node.latest_turn_ref != null ? ` · turn ${node.latest_turn_ref}` : ''}
              </span>
            ` : null}
          </div>

        </div>

        <div class="flex shrink-0 flex-col items-end gap-1">
          <span class="text-3xs text-text-dim">
            <${TimeAgo} timestamp=${node.last_activity_at} />
          </span>
          ${isSelected ? html`
            <span class="rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-semibold text-accent-fg">selected</span>
          ` : null}
        </div>
      </button>

      ${isExpanded ? html`
        <div class="mt-1.5 flex flex-col gap-1.5">
          ${node.tasks.length > 0 ? html`
            <div class="ml-6 flex flex-col gap-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-2">
              <div class="mb-1 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-text-dim">연결된 태스크</div>
              ${node.tasks.map(task => html`<${TreeTask} key=${task.id} task=${task} />`)}
            </div>
          ` : null}
          ${node.children.map(child => html`
            <${TreeNode} key=${child.id} node=${child} depth=${depth + 1} />
          `)}
        </div>
      ` : null}
    </div>
  `
}

function goalMeasurementLabel(measurement: GoalMeasurementProjection): string {
  switch (measurement.state) {
    case 'reported': return `관측 ${measurement.record.observed_value}`
    case 'not_recorded': return '관측 미기록'
    case 'unavailable': return '측정 저장소 읽기 실패'
    case 'not_loaded': return '측정 미로드'
    default: {
      const unhandled: never = measurement
      return unhandled
    }
  }
}

function GoalMeasurementBadge({ node }: { node: GoalTreeNode }) {
  const measurement = node.measurement
  return html`
    <span
      data-testid=${`goal-measurement-badge-${node.id}`}
      data-state=${measurement.state}
      class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-1.5 py-0.5 text-3xs text-text-secondary"
      title=${`현재 기준 개정 ${node.criterion_revision}`}
    >${goalMeasurementLabel(measurement)}</span>
  `
}

function GoalMeasurementDetail({ node }: { node: GoalTreeNode }) {
  const measurement = node.measurement
  let content
  switch (measurement.state) {
    case 'reported':
      content = html`
        <div class="mt-3 grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-3">
          <div>
            <div class="text-3xs text-text-muted">기록된 관측값</div>
            <div class="mt-1 break-words text-sm font-semibold text-text-strong" data-testid="goal-observed-value">${measurement.record.observed_value}</div>
          </div>
          <div>
            <div class="text-3xs text-text-muted">선언된 목표값</div>
            <div class="mt-1 break-words text-sm text-text-body">${node.target_value ?? '설정되지 않음'}</div>
          </div>
        </div>
        <div class="mt-3 break-words text-xs text-text-body" data-testid="goal-measurement-evidence">
          <span class="text-text-muted">증거 참조 · </span>${measurement.record.evidence}
        </div>
        <div class="mt-1 text-3xs text-text-muted">${measurement.record.actor} · ${measurement.record.recorded_at}</div>
        <div class="mt-2 text-3xs text-text-muted">관측 기록이며 목표 달성 판정은 별도 검증 결과를 따릅니다.</div>
      `
      break
    case 'not_recorded':
      content = html`<div class="mt-2 text-xs text-text-muted">현재 기준에 기록된 관측값이 없습니다.</div>`
      break
    case 'unavailable':
      content = html`<div class="mt-2 break-words text-xs text-warn" role="alert">측정 저장소를 읽지 못했습니다: ${measurement.reason}</div>`
      break
    case 'not_loaded':
      content = html`<div class="mt-2 text-xs text-text-muted">측정 투영이 아직 로드되지 않았습니다.</div>`
      break
    default: {
      const unhandled: never = measurement
      return unhandled
    }
  }
  return html`
    <section class=${CARD_BOX} aria-label="목표 측정" data-testid="goal-measurement-detail" data-state=${measurement.state}>
      <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">현재 기준의 측정</div>
      <div class="mt-1 break-all font-mono text-3xs text-text-muted" data-testid="goal-criterion-revision">
        기준 개정 ${node.criterion_revision}
      </div>
      ${content}
    </section>
  `
}

function DetailMetric({
  label,
  value,
  tone = 'default',
}: {
  label: string
  value: string | number
  tone?: 'default' | 'ok' | 'warn' | 'bad'
}) {
  const toneClass =
    tone === 'ok'
      ? 'text-ok'
      : tone === 'warn'
        ? 'text-warn'
        : tone === 'bad'
          ? 'text-bad'
          : 'text-text-strong'
  return html`
    <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-3">
      <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">${label}</div>
      <div class="mt-2 text-lg font-semibold tabular-nums ${toneClass}">${value}</div>
    </div>
  `
}

function DetailTabs({ active }: { active: GoalDetailTab }) {
  const tabs: GoalDetailTab[] = ['summary', 'tasks', 'evidence']
  return html`
    <div class="flex flex-wrap gap-2">
      ${tabs.map(tab => html`
        <button
          key=${tab}
          type="button"
          class="rounded-[var(--r-1)] border px-3 py-1.5 text-xs font-semibold uppercase tracking-wider transition-colors ${active === tab
            ? 'border-[var(--accent-35)] bg-[var(--accent-10)] text-accent-fg'
            : 'border-card-border/60 bg-[var(--color-bg-surface)] text-text-body hover:border-card-border/90'}"
          onClick=${() => { detailTab.value = tab }}
        >
          ${tab}
        </button>
      `)}
    </div>
  `
}

function KeeperCard({ keeper }: { keeper: GoalDetailKeeper }) {
  const trust = keeper.runtime_trust
  const execution = trust?.execution_summary ?? null
  const latestEvent = keeper.latest_causal_event ?? trust?.latest_causal_event ?? null
  const trustSummary =
    trust?.snapshot_error?.trim()
    || trust?.attention_reason?.trim()
    || trust?.disposition_reason?.trim()
    || execution?.sandbox_summary?.trim()
    || null
  const runtimeAttemptCount = execution?.provider_attempt_count
  const runtimeFailoverApplied = execution?.provider_fallback_applied
  const runtimeSelectedLane = execution?.provider_selected_model?.trim() || null
  const executionRuntimeOutcome = execution?.runtime_outcome?.trim() || null
  const sandboxRoot = execution?.sandbox_root?.trim() || null
  const latestTerminalCode = trust?.latest_terminal_reason?.code?.trim() || null
  const latestTerminalSummary = trust?.latest_terminal_reason?.summary?.trim() || null
  const latestNextAction = trust?.latest_next_action?.trim() || null
  const operatorDispositionReason = trust?.operator_disposition_reason?.trim() || null
  const pendingApproval = trust?.approval_state?.pending_first ?? null
  const pendingApprovalId = pendingApproval?.id?.trim() || null
  const pendingApprovalTool = pendingApproval?.tool_name?.trim() || null
  const pendingApprovalTask = pendingApproval?.task_id?.trim() || null
  const pendingApprovalBlocker = pendingApproval?.blocker_class?.trim() || null
  const shouldShowOperatorDispositionReason =
    operatorDispositionReason !== null && operatorDispositionReason !== trustSummary
  const shouldShowTrustSummary =
    Boolean(trustSummary)
    || Boolean(trust?.snapshot_status)
    || Boolean(trust?.approval_state?.state)
    || Boolean(trust?.next_human_action)
    || Boolean(latestTerminalCode)
    || Boolean(latestNextAction)
    || typeof runtimeAttemptCount === 'number'
    || runtimeFailoverApplied === true
    || Boolean(runtimeSelectedLane)
    || Boolean(executionRuntimeOutcome)
    || Boolean(sandboxRoot)
    || trustHasPendingFirstEvidence(trust?.approval_state ?? null)

  return html`
    <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-3">
      <div class="flex items-start justify-between gap-3">
        <div>
          <div class="text-sm font-semibold text-text-strong">${keeper.name}</div>
        </div>
        <div class="flex flex-wrap justify-end gap-1.5">
          ${trust?.disposition ? html`
            <span class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold ${keeperTrustDispositionClass(trust)}">
              검증 ${trustDispositionLabel(trust.disposition)}
            </span>
          ` : null}
          ${keeper.latest_execution_outcome ? html`
            <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-semibold text-text-body" title=${keeper.latest_execution_outcome}>
              ${executionOutcomeLabel(keeper.latest_execution_outcome)}
            </span>
          ` : null}
        </div>
      </div>
      <div class="mt-3 grid grid-cols-2 gap-2 text-2xs text-text-muted">
        <div>샌드박스</div>
        <div class="text-right text-text-body">${keeper.sandbox_profile}</div>
        <div>승인</div>
        <div class="text-right text-text-body">${trust?.approval_state?.summary ?? '-'}</div>
        <div>런타임</div>
        <div class="text-right text-text-body">${keeper.runtime_id ?? executionRuntimeOutcome ?? '-'}</div>
        <div>결과</div>
        <div class="text-right text-text-body" title=${keeper.runtime_outcome ?? executionRuntimeOutcome ?? ''}>${runtimeOutcomeLabel(keeper.runtime_outcome ?? executionRuntimeOutcome) ?? '-'}</div>
      </div>
      ${shouldShowTrustSummary ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-3">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">검증 요약</div>
          ${trustSummary ? html`
            <div class="mt-2 text-xs leading-relaxed text-text-body">${trustSummary}</div>
          ` : null}
          ${latestTerminalCode ? html`
            <div class="mt-2 text-xs leading-relaxed text-text-body">종료: ${latestTerminalCode}${latestTerminalSummary ? html` · ${latestTerminalSummary}` : null}</div>
          ` : null}
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-text-muted">
            ${trust?.snapshot_status ? html`
              <span>snapshot ${trust.snapshot_status}</span>
            ` : null}
            ${trust?.approval_state?.state ? html`
              <span>승인 상태 ${trust.approval_state.state}${trust.approval_state.latest_event_at ? html` · <${TimeAgo} timestamp=${trust.approval_state.latest_event_at} />` : null}</span>
            ` : null}
            ${pendingApprovalId ? html`
              <span>승인 ID ${pendingApprovalId}</span>
            ` : null}
            ${pendingApprovalTool ? html`
              <span>승인 도구 ${pendingApprovalTool}</span>
            ` : null}
            ${pendingApprovalTask ? html`
              <span>승인 작업 ${pendingApprovalTask}</span>
            ` : null}
            ${pendingApprovalBlocker ? html`
              <span>승인 차단 ${pendingApprovalBlocker}</span>
            ` : null}
            ${typeof runtimeAttemptCount === 'number' || runtimeFailoverApplied === true || runtimeSelectedLane ? html`
              <span>
                runtime
                ${typeof runtimeAttemptCount === 'number' ? ` ${runtimeAttemptCount}회` : ''}
                ${runtimeFailoverApplied === true ? ' failover' : ''}
                ${runtimeSelectedLane ? ` ${runtimeSelectedLane}` : ''}
              </span>
            ` : null}
            ${executionRuntimeOutcome ? html`
              <span>runtime ${executionRuntimeOutcome}</span>
            ` : null}
            ${sandboxRoot ? html`
              <span title=${sandboxRoot}>sandbox ${sandboxRoot}</span>
            ` : null}
            ${trust?.next_human_action ? html`
              <span>다음 ${trust.next_human_action}</span>
            ` : null}
            ${latestNextAction ? html`
              <span>권장 ${latestNextAction}</span>
            ` : null}
            ${/* Show receipt-level operator cause when it adds detail beyond trustSummary. */
              shouldShowOperatorDispositionReason ? html`
              <span title=${operatorDispositionReason ?? ''}>운영자 ${operatorDispositionReasonLabel(operatorDispositionReason)}</span>
            ` : null}
          </div>
        </div>
      ` : null}
      ${latestEvent ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">최근 키퍼 이벤트</div>
            <div class="text-3xs text-text-dim">
              <${TimeAgo} timestamp=${latestEvent.ts} />
            </div>
          </div>
          <div class="mt-2 text-xs font-semibold text-text-strong">${latestEvent.title}</div>
          <div class="mt-1 text-2xs leading-relaxed text-text-body">${latestEvent.summary}</div>
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-text-muted">
            <span>${latestEvent.kind}</span>
            ${latestEvent.keeper_turn_id != null ? html`
              <span>turn ${latestEvent.keeper_turn_id}</span>
            ` : null}
            ${latestEvent.next_human_action ? html`
              <span>next ${latestEvent.next_human_action}</span>
            ` : null}
            ${latestEvent.trace_id ? html`
              <span class="font-mono" title=${latestEvent.trace_id}>trace ${latestEvent.trace_id.slice(0, 8)}</span>
            ` : null}
          </div>
        </div>
      ` : null}
      ${keeper.latest_execution_at ? html`
        <div class="mt-3 text-3xs text-text-dim">
          최근 실행 <${TimeAgo} timestamp=${keeper.latest_execution_at} />
        </div>
      ` : null}
    </div>
  `
}

function GoalTimeline({ events }: { events: GoalDetailTimelineEvent[] }) {
  if (events.length === 0) {
    return html`<${EmptyState} message="최근 evidence가 없습니다" compact />`
  }
  return html`
    <div class="flex flex-col gap-2">
      ${events.map(event => html`
        <div key=${`${event.kind}:${event.lane}:${event.ts}`} class="rounded-[var(--r-1)] border p-3 ${timelineSeverityClass(event.severity)}">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="text-sm font-semibold">${event.title}</div>
            <div class="text-3xs text-text-dim">
              <${TimeAgo} timestamp=${event.ts} />
            </div>
          </div>
          <div class="mt-1 text-2xs text-text-muted">${event.lane}</div>
          <div class="mt-2 text-xs leading-relaxed text-text-body">${event.summary}</div>
        </div>
      `)}
    </div>
  `
}

function GoalDetailPanel({
  selectedNode,
  isRecoveryCurrent,
}: {
  selectedNode: GoalTreeNode | null
  isRecoveryCurrent: () => boolean
}) {
  const data = detailData.value
  const loading = detailLoading.value
  const error = detailError.value
  const activeTab = detailTab.value

  if (!selectedNode) {
    return html`
      <section class=${GOAL_PANEL} aria-label="목표 상세">
        <${EmptyState} message="왼쪽에서 목표를 선택하면 Summary / Tasks / Evidence가 표시됩니다." />
      </section>
    `
  }

  const binding = treeDecisionBinding.value
  const authorized = !managedGoalCredentialRefused() && binding && binding.authority === executionWorkspaceAuthority.value
    && binding.snapshot === treeData.value && binding.authRevision === storedTokenRevision.value
    && binding.actor === goalDecisionActor()
  const identitySafe = Boolean(authorized && binding && goalIdIsUnambiguous(selectedNode.id, binding.snapshot))
  const detail = identitySafe && binding === detailDecisionBinding.value
    && data?.goal.id === selectedNode.id ? data : null
  const confirmationOwner = authorized && binding ? {
    key: JSON.stringify([binding.authority.epoch, binding.workspace.basePath, binding.workspace.mascRoot,
      binding.authRevision, binding.actor, selectedNode.id]),
    goalId: selectedNode.id,
    workspace: binding.workspace,
    credentialScope: JSON.stringify([binding.authRevision, binding.actor]),
    executionEpoch: binding.authority.epoch,
  } : null
  const confirmationSelectionRevision = selectedGoalRevision.peek()
  const confirmationIsCurrent = () => Boolean(binding && goalIdIsUnambiguous(selectedNode.id, binding.snapshot)
    && !managedGoalCredentialRefused()
    && selectedGoalId.peek() === selectedNode.id
    && selectedGoalRevision.peek() === confirmationSelectionRevision
    && treeDecisionBinding.peek() === binding && treeData.peek() === binding.snapshot
    && executionWorkspaceAuthority.peek() === binding.authority
    && storedTokenRevision.peek() === binding.authRevision && goalDecisionActor() === binding.actor)
  const confirmationRecoveryBaseIsCurrent = () => Boolean(binding && treeConsumerCount > 0 && selectedGoalId.peek() === selectedNode.id
    && selectedGoalRevision.peek() === confirmationSelectionRevision
    && executionWorkspaceAuthority.peek() === binding.authority
    && storedTokenRevision.peek() === binding.authRevision && goalDecisionActor() === binding.actor)
  const confirmationRecoveryIsCurrent = () => {
    if (!binding || !confirmationRecoveryBaseIsCurrent()) return false
    const current = treeDecisionBinding.peek()
    if (current && current.authority === binding.authority && current.authRevision === binding.authRevision
      && current.actor === binding.actor && sameArtifactWorkspace(current.workspace, binding.workspace)) return true
    const attestation = treeWorkspaceAttestation
    if (attestation && attestation.request === treeRequestSeq && attestation.authority === binding.authority
      && attestation.authRevision === binding.authRevision && attestation.actor === binding.actor
      && sameArtifactWorkspace(attestation.workspace, binding.workspace)) return true
    const active = treeRequestInFlight.peek()
    return Boolean(active?.workspace && active.authority === binding.authority && active.authRevision === binding.authRevision
      && active.actor === binding.actor && sameArtifactWorkspace(active.workspace, binding.workspace))
  }
  const waitForConfirmationRecoveryCurrent = async () => {
    while (binding && confirmationRecoveryBaseIsCurrent()) {
      if (confirmationRecoveryIsCurrent()) return true
      const pending = treeRequestInFlight.peek()
      if (!pending || pending.authority !== binding.authority || pending.authRevision !== binding.authRevision
        || pending.actor !== binding.actor) return false
      let dispose = () => {}
      const replaced = new Promise<void>(resolve => {
        dispose = effect(() => {
          // Subscribe to every signal that can retire this confirmation or
          // replace the read; a transport may ignore its abort signal.
          void treeRequestInFlight.value
          void executionWorkspaceAuthority.value
          void storedTokenRevision.value
          void dashboardActorRevision.value
          void managedDashboardActorRevision.value
          void selectedGoalId.value
          void selectedGoalRevision.value
          if (!confirmationRecoveryBaseIsCurrent() || treeRequestInFlight.peek()?.request !== pending.request) resolve()
        })
      })
      try { await Promise.race([pending.workspaceReady, replaced]) } catch {
        if (treeRequestInFlight.peek()?.request !== pending.request) continue
        return false
      } finally {
        dispose()
      }
      if (confirmationRecoveryIsCurrent()) return true
      // A post-write refresh may replace the pre-write read as soon as it
      // identifies its workspace. Follow that new read, never the old one.
      if (treeRequestInFlight.peek()?.request === pending.request) return false
    }
    return false
  }
  const candleIsCurrent = () => {
    const current = treeDecisionBinding.peek()
    return Boolean(!managedGoalCredentialRefused() && binding && current && goalIdIsUnambiguous(selectedNode.id, current.snapshot)
      && selectedGoalId.peek() === selectedNode.id
      && executionWorkspaceAuthority.peek() === binding.authority && current.authority === binding.authority
      && current.workspace.basePath === binding.workspace.basePath && current.workspace.mascRoot === binding.workspace.mascRoot
      && storedTokenRevision.peek() === binding.authRevision && current.authRevision === binding.authRevision
      && current.actor === binding.actor && goalDecisionActor() === binding.actor)
  }
  const candleOwner = authorized && binding ? {
    key: JSON.stringify([binding.authority.epoch, binding.authority.connectionGeneration, binding.authority.workspaceRoot,
      binding.workspace.basePath, binding.workspace.mascRoot, binding.authRevision, binding.actor, selectedNode.id]),
    recoveryKey: JSON.stringify([binding.authority.workspaceRoot, binding.workspace.basePath, binding.workspace.mascRoot,
      binding.authRevision, binding.actor, selectedNode.id]),
    goalId: selectedNode.id, workspace: binding.workspace, executionEpoch: binding.authority.epoch,
  } : null
  const hasLifecyclePending = () => Boolean(binding && Object.values(goalActionReceipts.peek()).some(item =>
    item.state === 'pending' && item.owner.workspaceRoot === binding.authority.workspaceRoot
    && item.owner.mascRoot === binding.workspace.mascRoot && item.owner.goalId === selectedNode.id))
  const lifecyclePending = Boolean(binding && Object.values(goalActionReceipts.value).some(item =>
    item.state === 'pending' && item.owner.workspaceRoot === binding.authority.workspaceRoot
    && item.owner.mascRoot === binding.workspace.mascRoot && item.owner.goalId === selectedNode.id))
  return html`
    <section
      class=${`${GOAL_PANEL} flex flex-col gap-4`}
      aria-label="목표 상세"
      data-testid="goal-detail-panel"
      data-selected-goal-id=${selectedNode.id}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="max-w-150">
          <div class="text-2xs font-semibold uppercase tracking-[var(--track-label)] text-text-muted">목표 상세</div>
          <h3 class="mt-1 text-xl font-semibold tracking-[-0.02em] text-text-strong">${selectedNode.title}</h3>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <${StatusBadge} status=${goalPhaseStatus(selectedNode.phase)} label=${goalPhaseLabel(selectedNode.phase)} />
            <${GoalFsmBadge} fsm=${selectedNode.goal_fsm} />
            ${selectedNode.metric ? html`
              <span
                class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 font-mono text-3xs text-text-secondary"
                title="이 목표가 추적하는 metric"
              >
                <span class="text-text-muted">metric</span>
                <span class="ml-1.5">${selectedNode.metric}</span>
                ${selectedNode.target_value ? html`
                  <span class="text-text-muted">·</span>
                  <span class="ml-1 text-text-strong">${selectedNode.target_value}</span>
                ` : null}
              </span>
            ` : null}
          </div>
        </div>
        <div class="flex items-center gap-2">
          <${ActionButton}
            variant="ghost"
            size="sm"
            disabled=${loading}
            onClick=${() => { void refreshTree() }}
          >
            ${loading ? 'detail 갱신 중...' : 'detail 새로고침'}
          <//>
        </div>
      </div>

      <${GoalTaskRelationStrip} node=${selectedNode} />
      <${GoalMeasurementDetail} node=${selectedNode} />
      <${GoalCriterionReviewDetail} review=${identitySafe ? selectedNode.criterion_review : undefined} />
      <${GoalProofDetail} proof=${identitySafe ? selectedNode.verification : undefined} />
      ${candleOwner && identitySafe ? html`<${GoalCandlePanel} key=${candleOwner.key} owner=${candleOwner}
        isCurrent=${candleIsCurrent} refreshKey=${selectedNode.phase} />` : null}
      <${GoalLifecycleActionPanel} key=${selectedNode.id} node=${selectedNode} />
      ${confirmationOwner && ((identitySafe && (selectedNode.phase === 'awaiting_confirmation' || selectedNode.phase === 'completed'))
        || confirmationHasUnsettledReceipt(confirmationOwner.workspace, selectedNode.id)) ? html`
        <${GoalConfirmationPanel} key=${confirmationOwner.key} owner=${confirmationOwner} isCurrent=${confirmationIsCurrent}
          isRecoveryCurrent=${confirmationRecoveryIsCurrent}
          waitForRecoveryCurrent=${waitForConfirmationRecoveryCurrent}
          readAuthority=${binding} lifecyclePending=${lifecyclePending} hasLifecyclePending=${hasLifecyclePending}
          onOutcome=${(result: { ticket: number; state: 'pending' | 'confirmed' | 'uncertain' }) => {
            if (!binding) return
            const state: GoalOperationNoticeState = result.state === 'pending' ? 'confirmation_pending'
              : result.state === 'confirmed' ? 'confirmation_verified' : 'confirmation_unknown'
            rememberGoalOperation(`confirmation:${result.ticket}`, { authority: binding.authority,
              authRevision: binding.authRevision, actor: binding.actor, workspace: binding.workspace, goalId: selectedNode.id, state })
            if (result.state !== 'pending' && !refreshTreeAfterWrite(binding)) refreshRelatedTreeAfterWrite(binding)
          }}
          onConfirmed=${() => {}} />` : null}


      <${DetailTabs} active=${activeTab} />

      ${error ? html`<${ErrorState} message=${error} />` : null}
      ${loading && !detail ? html`<${LoadingState}>goal detail 로드 중...<//>` : null}

      ${activeTab === 'summary' ? html`
        <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-4">
          <div class="mb-2 flex flex-wrap items-center gap-2">
            <span class="text-2xs font-semibold uppercase text-text-muted">Goal FSM</span>
            <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-semibold text-text-body">
              ${selectedNode.goal_fsm.source}
            </span>
          </div>
          <div class="grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-2 text-xs text-text-body">
            <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
              <div class="text-3xs uppercase text-text-muted">state</div>
              <div class="mt-1 font-semibold text-text-strong">${goalPhaseLabel(selectedNode.goal_fsm.state)}</div>
            </div>
            <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
              <div class="text-3xs uppercase text-text-muted">activity</div>
              <div class="mt-1 font-semibold text-text-strong">${goalFsmObservationLabel(selectedNode.goal_fsm.activity_observation)}</div>
            </div>
          </div>
          ${selectedNode.goal_fsm.next_actions.length > 0 ? html`
            <div class="mt-3 flex flex-wrap gap-1.5">
              ${selectedNode.goal_fsm.next_actions.map(action => html`
                <code key=${action} class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-3xs text-text-secondary">${action}</code>
              `)}
            </div>
          ` : null}
        </div>

        <div class="grid grid-cols-[repeat(auto-fit,minmax(140px,1fr))] gap-3">
          <${DetailMetric} label="작업" value=${`${selectedNode.task_done_count}/${selectedNode.task_count}`} tone=${selectedNode.task_done_count === selectedNode.task_count && selectedNode.task_count > 0 ? 'ok' : 'default'} />
          <${DetailMetric} label="연결된 키퍼" value=${selectedNode.linked_keeper_names.length} />
          <${DetailMetric} label="승인 대기" value=${selectedNode.pending_approval_count} tone=${selectedNode.pending_approval_count > 0 ? 'warn' : 'default'} />
          <${DetailMetric}
            label="최근 활동"
            value=${selectedNode.stagnation_seconds == null
              ? 'unavailable'
              : selectedNode.stagnation_seconds > 0
                ? `${Math.floor(selectedNode.stagnation_seconds / SECONDS_PER_HOUR)}h idle`
                : 'now'}
          />
        </div>

        <div class=${CARD_BOX}>
          <div class="mb-3 flex items-center justify-between gap-3">
            <div>
              <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">Goal 범위 태스크</div>
              <div class="mt-1 text-sm text-text-body">이 goal에 직접 연결되는 새 태스크를 backlog에 넣습니다.</div>
            </div>
          </div>
          ${selectedNode.phase === 'completed' || selectedNode.phase === 'dropped'
            ? html`<p role="status" class="text-xs text-text-muted">종료된 Goal에는 새 태스크를 연결할 수 없습니다.</p>`
            : identitySafe && binding ? html`<${TaskCreateForm} goalId=${selectedNode.id} goalTitle=${selectedNode.title}
            goalDispatch=${{ workspace: binding.workspace,
              identity: { revision: binding.authRevision, actor: currentDashboardActor() }, isCurrent: confirmationIsCurrent,
              isRecoveryCurrent: () => isRecoveryCurrent() && selectedGoalId.peek() === selectedNode.id
                && selectedGoalRevision.peek() === confirmationSelectionRevision }} />`
            : html`<p role="status" class="text-xs text-text-muted">현재 Goal 목록에서 ID를 구분할 수 없어 태스크를 연결할 수 없습니다.</p>`}
        </div>
      ` : null}

      ${activeTab === 'tasks' ? html`
        ${detail ? (
          detail.linked_tasks.length > 0
            ? html`
              <div class="flex flex-col gap-2">
                ${detail.linked_tasks.map(task => html`<${TreeTask} key=${task.id} task=${task} />`)}
              </div>
            `
            : html`<${EmptyState} message="이 goal에 직접 연결된 태스크가 없습니다" compact />`
        ) : null}
      ` : null}

      ${activeTab === 'evidence' ? html`
        <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
          <div class="flex flex-col gap-4">
            <div class=${CARD_BOX}>
              <div class="mb-3 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">키퍼 준비 상태</div>
              ${detail ? (
                detail.linked_keepers.length > 0
                  ? html`
                    <div class="flex flex-col gap-2">
                      ${detail.linked_keepers.map(keeper => html`<${KeeperCard} key=${keeper.name} keeper=${keeper} />`)}
                    </div>
                  `
                  : html`<${EmptyState} message="연결된 keeper가 없습니다" compact />`
              ) : null}
            </div>

            <div class=${CARD_BOX}>
              <div class="mb-3 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">승인 대기</div>
              ${detail ? (
                detail.approvals.length > 0
                  ? html`
                    <div class="flex flex-col gap-2">
                      ${detail.approvals.map((approval, index) => html`
                        <div key=${String(approval.id ?? index)} class="rounded-[var(--r-1)] border border-warn/20 bg-warn/6 p-3 text-xs">
                          <div class="flex flex-wrap items-center justify-between gap-2">
                            <strong class="text-text-strong">${String(approval.tool_name ?? '(unknown tool)')}</strong>
                            <span class="text-text-dim">Human HITL · nonblocking</span>
                          </div>
                          <div class="mt-2 text-text-muted">${approvalInputText(String(approval.input_preview ?? 'pending operator decision'))}</div>
                        </div>
                      `)}
                    </div>
                  `
                  : html`<${EmptyState} message="approval 대기 없음" compact />`
              ) : null}
            </div>
          </div>

          <div class=${CARD_BOX}>
            <div class="mb-3 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">통합 타임라인</div>
            ${detail ? html`<${GoalTimeline} events=${detail.timeline} />` : null}
          </div>
        </div>
      ` : null}
    </section>
  `
}

/** The same workspace-bound Goal observation is used by GoalTree and Work. */
export function useGoalTreeDecisionObservation() {
  const [mountObserved, setMountObserved] = useState(false)
  const authority = executionWorkspaceAuthority.value
  const authorityError = executionError.value
  const authorityLoading = executionLoading.value
  const tokenRevision = storedTokenRevision.value
  const actorRevision = dashboardActorRevision.value
  const managedActorRevision = managedDashboardActorRevision.value
  const refusalRevision = managedDashboardRefusal.value
  const unverifiedRevision = managedDashboardUnverified.value
  const authRefused = (refusalRevision === tokenRevision || unverifiedRevision === tokenRevision) && managedGoalCredentialRefused()
  const authRetrying = goalAuthRetrying.value
  const observedData = treeData.value
  const observedRevision = goalTreeObservationRevision.value
  const decisionBinding = treeDecisionBinding.value
  const inFlight = treeRequestInFlight.value
  const retryIntent = treeRetryIntent.value
  const actor = goalDecisionActor()
  const ownsInFlight = Boolean(inFlight && inFlight.authority === authority
    && inFlight.authRevision === tokenRevision && inFlight.actor === actor
    && inFlight.observationRevision === observedRevision)
  const ownsRetry = Boolean(retryIntent && retryIntent.authority === authority
    && retryIntent.authRevision === tokenRevision && retryIntent.actor === actor)
  const boundData = decisionBinding && decisionBinding.authority === authority
    && decisionBinding.snapshot === observedData && decisionBinding.authRevision === tokenRevision
    && decisionBinding.actor === actor ? observedData : null
  const data = mountObserved && !authRefused ? boundData : null
  const errorOwner = treeErrorOwner.value
  const ownsError = errorOwner && errorOwner.authority === authority && errorOwner.authRevision === tokenRevision
    && errorOwner.actor === actor
  const currentError = ownsError && errorOwner.observationRevision === observedRevision
  const unconfirmed = Boolean(mountObserved && ownsError && !currentError && !ownsInFlight && !ownsRetry)
  // A dispatched Task keeps its original authority while the credential is
  // being classified, but never regains it after any owner transition.
  const recoveryOwner = useMemo(() => ({ retired: !mountObserved || !decisionBinding }), [decisionBinding, mountObserved])
  useLayoutEffect(() => {
    const stop = effect(() => {
      void treeDecisionBinding.value
      void treeData.value
      void executionWorkspaceAuthority.value
      void storedTokenRevision.value
      void dashboardActorRevision.value
      void managedDashboardActorRevision.value
      if (!decisionBinding || treeDecisionBinding.peek() !== decisionBinding || treeData.peek() !== decisionBinding.snapshot
        || executionWorkspaceAuthority.peek() !== decisionBinding.authority
        || storedTokenRevision.peek() !== decisionBinding.authRevision || goalDecisionActor() !== decisionBinding.actor) {
        recoveryOwner.retired = true
      }
    })
    return () => { recoveryOwner.retired = true; stop() }
  }, [decisionBinding, recoveryOwner])
  // A previous failure is only the last bound observation. Hide its detail
  // while a new read is pending; a later non-store failure replaces it.
  const error = authRefused ? (refusalRevision === tokenRevision
    ? '인증이 거부되었습니다. 인증을 갱신한 뒤 다시 확인해 주세요.'
    : '인증 상태를 확인할 수 없습니다. 인증을 다시 확인해 주세요.')
    : mountObserved && currentError && !ownsInFlight && !ownsRetry ? errorOwner.error : null
  const unavailable = !authRefused && mountObserved && currentError && !ownsInFlight && !ownsRetry ? errorOwner.unavailable : null
  // A current authority with neither a bound snapshot nor an owned failure
  // will start a read in the effect below, including on the first render.
  const loading = authRetrying || (!authRefused && (Boolean(authority && !mountObserved) || ownsInFlight || ownsRetry || (!authority && authorityLoading)
    || Boolean(authority && !data && !ownsError)))
  useLayoutEffect(() => {
    treeConsumerCount += 1
    const currentAuthority = executionWorkspaceAuthority.peek()
    const currentRevision = storedTokenRevision.peek()
    const currentActor = goalDecisionActor()
    const currentObservation = goalTreeObservationRevision.peek()
    const active = treeRequestInFlight.peek()
    const activeForOwner = active && active.authority === currentAuthority
      && active.authRevision === currentRevision && active.actor === currentActor
      && active.observationRevision === currentObservation
    // A newly mounted consumer must not use an earlier visit's proof. Withdraw
    // it for all consumers before starting or joining the current read. The
    // intent survives an unrelated observation that supersedes this read.
    treeDecisionBinding.value = null
    if (currentAuthority && !managedGoalCredentialRefused()) {
      const retry = treeRetryIntent.peek()
      if (!retry?.afterWrite || retry.authority !== currentAuthority || retry.authRevision !== currentRevision || retry.actor !== currentActor) {
        treeRetryIntent.value = { authority: currentAuthority, authRevision: currentRevision, actor: currentActor }
      }
      if (!activeForOwner) void refreshTree()
    }
    setMountObserved(true)
    return () => {
      treeConsumerCount -= 1
      if (treeConsumerCount !== 0) return
      // Invalidate before aborting: transports can ignore abort or reject
      // asynchronously, and neither outcome belongs to the next visit.
      treeRequestSeq += 1
      treeRequestInFlight.peek()?.controller.abort()
      batch(() => {
        treeRequestInFlight.value = null
        treeRetryIntent.value = null
        treeDecisionBinding.value = null
        treeLoading.value = false
      })
    }
  }, [])
  useEffect(() => {
    // Effects can run after a previous request has already published. Inspect
    // all ownership state together at execution time, not a mix of render-time
    // values and a later in-flight value.
    const currentAuthority = executionWorkspaceAuthority.peek()
    if (!currentAuthority) return
    const currentRevision = storedTokenRevision.peek()
    const currentActor = goalDecisionActor()
    const currentObservation = goalTreeObservationRevision.peek()
    const snapshot = treeData.peek()
    const binding = treeDecisionBinding.peek()
    const hasBinding = binding && binding.authority === currentAuthority && binding.snapshot === snapshot
      && binding.authRevision === currentRevision && binding.actor === currentActor
    const failure = treeErrorOwner.peek()
    const hasFailure = failure && failure.authority === currentAuthority && failure.authRevision === currentRevision
      && failure.actor === currentActor
    const active = treeRequestInFlight.peek()
    const activeForOwner = active && active.authority === currentAuthority
      && active.authRevision === currentRevision && active.actor === currentActor
      && active.observationRevision === currentObservation
    const retry = treeRetryIntent.peek()
    const hasRetry = retry && retry.authority === currentAuthority
      && retry.authRevision === currentRevision && retry.actor === currentActor
    if (managedGoalCredentialRefused() && !(hasRetry && retry?.afterWrite)) return
    if (!hasBinding && (!hasFailure || hasRetry) && !activeForOwner) void refreshTree()
  }, [authority, tokenRevision, actorRevision, managedActorRevision, refusalRevision, unverifiedRevision, observedRevision, observedData, decisionBinding, inFlight, retryIntent, data, ownsError])
  const isOwnerCurrent = () => {
    const current = treeDecisionBinding.peek()
    return Boolean(!managedGoalCredentialRefused() && mountObserved && decisionBinding && current && current.authority === decisionBinding.authority
      && sameArtifactWorkspace(current.workspace, decisionBinding.workspace)
      && executionWorkspaceAuthority.peek() === decisionBinding.authority
      && storedTokenRevision.peek() === decisionBinding.authRevision && goalDecisionActor() === decisionBinding.actor)
  }
  const isCurrent = () => Boolean(isOwnerCurrent() && decisionBinding
    && treeDecisionBinding.peek() === decisionBinding && treeData.peek() === decisionBinding.snapshot)
  const isRecoveryCurrent = () => Boolean(!recoveryOwner.retired && treeConsumerCount > 0 && decisionBinding
    && treeDecisionBinding.peek() === decisionBinding && treeData.peek() === decisionBinding.snapshot
    && executionWorkspaceAuthority.peek() === decisionBinding.authority
    && storedTokenRevision.peek() === decisionBinding.authRevision && goalDecisionActor() === decisionBinding.actor)
  const refreshAfterWrite = () => Boolean(decisionBinding && refreshTreeAfterWrite(decisionBinding))
  const isStoreUnavailableNow = () => {
    const currentAuthority = executionWorkspaceAuthority.peek()
    const currentRevision = storedTokenRevision.peek()
    const currentActor = goalDecisionActor()
    const failure = treeErrorOwner.peek()
    const active = treeRequestInFlight.peek()
    const retry = treeRetryIntent.peek()
    const matchesOwner = (value: { authority: ExecutionWorkspaceAuthority; authRevision: number; actor: string } | null) =>
      value && value.authority === currentAuthority && value.authRevision === currentRevision && value.actor === currentActor
    const activeForObservation = matchesOwner(active) && active?.observationRevision === goalTreeObservationRevision.peek()
    return Boolean(mountObserved && matchesOwner(failure) && failure?.unavailable
      && failure.observationRevision === goalTreeObservationRevision.peek() && !activeForObservation && !matchesOwner(retry))
  }
  return { authority, authorityError, authorityLoading, tokenRevision, actorRevision, managedActorRevision, authRefused,
    decisionBinding: mountObserved && !authRefused ? decisionBinding : null,
    data, loading, error, unavailable, unconfirmed, refresh: retryTree,
    isCurrent, isOwnerCurrent, isRecoveryCurrent, isStoreUnavailableNow, refreshAfterWrite }
}

export function GoalTree() {
  const { authority, authorityError, authorityLoading, tokenRevision, authRefused, decisionBinding,
    data, loading, error, unavailable, unconfirmed, isRecoveryCurrent } = useGoalTreeDecisionObservation()
  const query = filterQuery.value
  const activePhaseFilter = treePhaseFilter.value
  const selectedId = selectedGoalId.value
  const routeGoalId = cleanRouteGoalId(route.value.params.goal)
  const decisionActor = goalDecisionActor()
  const [handledRoute, setHandledRoute] = useState<{
    id: string; found: boolean; authority: ExecutionWorkspaceAuthority | null; authRevision: number; actor: string
  } | null>(null)
  const routeOwned = Boolean(routeGoalId && handledRoute?.id === routeGoalId
    && handledRoute.authority === authority && handledRoute.authRevision === tokenRevision
    && handledRoute.actor === decisionActor)
  useEffect(() => {
    setHandledRoute(null)
    if (routeGoalId) batch(() => {
      filterQuery.value = ''
      treePhaseFilter.value = 'all'
      setSelectedGoal(routeGoalId)
    })
  }, [routeGoalId, authority, tokenRevision, decisionActor])

  const visibleTree = useMemo(
    () => {
      if (!data) return []
      const filtered = filterGoalTree(filterGoalTreeByPhase(data.tree, activePhaseFilter), query)
      return [...filtered].sort((a, b) => (a.priority ?? 99) - (b.priority ?? 99))
    },
    [activePhaseFilter, data, query],
  )

  const allNodes = useMemo(
    () => (data ? flattenGoalTree(data.tree) : []),
    [data],
  )

  const visibleNodes = useMemo(
    () => flattenGoalTree(visibleTree),
    [visibleTree],
  )

  const selectedNode = useMemo(
    () => routeGoalId && !routeOwned ? null : visibleNodes.find(node => node.id === selectedId) ?? null,
    [selectedId, visibleNodes, routeGoalId, routeOwned],
  )

  useEffect(() => {
    if (!data) return
    if (allNodes.length === 0) {
      setSelectedGoal(null)
      return
    }
    if (visibleNodes.length === 0) {
      setSelectedGoal(null)
      return
    }
    if (routeGoalId && !routeOwned) {
      const expansionPath = goalExpansionPath(data.tree, routeGoalId)
      if (expansionPath && visibleNodes.some(node => node.id === routeGoalId)) {
        if (selectedGoalId.value !== routeGoalId) setSelectedGoal(routeGoalId)
        if (expansionPath.some(id => !expandedNodes.value.has(id))) {
          expandedNodes.value = new Set([...expandedNodes.value, ...expansionPath])
        }
        setHandledRoute({ id: routeGoalId, found: true, authority, authRevision: tokenRevision, actor: decisionActor })
        return
      }
      if (!expansionPath) {
        setSelectedGoal(routeGoalId)
        setHandledRoute({ id: routeGoalId, found: false, authority, authRevision: tokenRevision, actor: decisionActor })
      }
      return
    }
    if (routeGoalId && !allNodes.some(node => node.id === routeGoalId)) return
    if (!selectedGoalId.value || !visibleNodes.some(node => node.id === selectedGoalId.value)) {
      const nextId = routeGoalId && visibleNodes.some(node => node.id === routeGoalId)
        ? routeGoalId : visibleNodes[0]!.id
      selectGoal(nextId)
      const expansionPath = goalExpansionPath(data.tree, nextId) ?? [nextId]
      expandedNodes.value = new Set([...expandedNodes.value, ...expansionPath])
    }
  }, [allNodes, data, routeGoalId, routeOwned, authority, tokenRevision, decisionActor, visibleNodes])

  useEffect(() => {
    if (!selectedId || !decisionBinding || decisionBinding.authority !== authority || decisionBinding.snapshot !== data) {
      // A refused credential hides this view while its own scoped recovery
      // still needs to finish. Other withdrawals retire the detail request.
      if (!managedGoalCredentialRefused()) detailRequestSeq += 1
      detailData.value = null
      detailDecisionBinding.value = null
      detailError.value = null
      detailLoading.value = false
      return
    }
    void refreshGoalDetail(selectedId)
  }, [selectedId, authority, data, decisionBinding])

  const phaseCounts = useMemo(() => {
    const counts: Record<GoalPhaseFilter, number> = {
      all: allNodes.length,
      executing: 0,
      verifying: 0,
      awaiting_confirmation: 0,
      completed: 0,
      dropped: 0,
      paused: 0,
      blocked: 0,
    }
    for (const node of allNodes) {
      if (node.phase in counts) {
        counts[node.phase as Exclude<GoalPhaseFilter, 'all'>] += 1
      }
    }
    return counts
  }, [allNodes])

  const isFiltering = query.trim() !== '' || activePhaseFilter !== 'all'
  // Keep a Drop result visible when a phase filter or a new selection hides
  // its Goal. The original owner remains attached even if a refresh fails.
  const sameDropActor = (owner: GoalActionOwner) =>
    owner.authScope === goalActionAuthScope(tokenRevision) && owner.actor === goalDecisionActor()
  const compatibleDropOwner = (owner: GoalActionOwner) => sameDropActor(owner) || Boolean(data && authority && decisionBinding
    && relatedEarlierGoalOwner(owner, { epoch: authority.epoch, workspaceRoot: authority.workspaceRoot,
      authorityIdentity: dropAuthorityIdentity(authority), connectionGeneration: authority.connectionGeneration, mascRoot: decisionBinding.workspace.mascRoot, authRevision: tokenRevision,
      authScope: goalActionAuthScope(tokenRevision), actor: goalDecisionActor(), actorName: currentDashboardActor(), goalId: owner.goalId }))
  const sameDropSession = (owner: GoalActionOwner) => Boolean(authority && owner.epoch === authority.epoch
    && owner.authorityIdentity === dropAuthorityIdentity(authority) && sameDropActor(owner))
  const earlierReceiptViewKey = (ticket: number) => authority && decisionBinding
    ? dropViewKey(authority, decisionBinding.workspace, tokenRevision, goalDecisionActor(), ticket) : ''
  const earlierDraftViewKey = (owner: GoalActionOwner) => authority && decisionBinding
    ? dropViewKey(authority, decisionBinding.workspace, tokenRevision, goalDecisionActor(), goalActionOwnerKey(owner)) : ''
  const dropReceiptItems = [
    ...Object.values(goalActionHistory.value).flat(),
    ...Object.values(goalActionReceipts.value).filter(item => item.state === 'pending'),
  ]
  const matchingDropReceipts = authority ? dropReceiptItems.filter(item =>
    item.action === 'drop' && (item.state === 'pending' || item.state === 'warning' || item.state === 'error')
    && item.owner.workspaceRoot === authority.workspaceRoot && compatibleDropOwner(item.owner)) : []
  const compatibleDropReceipts = matchingDropReceipts.filter(item => !hiddenDropReceipts.value.has(item.ticket))
  const hiddenMatchingReceipts = data && decisionBinding ? matchingDropReceipts.filter(item =>
    hiddenDropReceipts.value.has(item.ticket) && item.owner.mascRoot === decisionBinding.workspace.mascRoot) : []
  const sessionDropReceipts = compatibleDropReceipts.filter(item => sameDropSession(item.owner))
  const earlierDropReceipts = compatibleDropReceipts.filter(item => !sameDropSession(item.owner))
  const detachedDropReceipts = data && decisionBinding ? sessionDropReceipts.filter(item =>
    item.owner.goalId !== selectedNode?.id && item.owner.mascRoot === decisionBinding.workspace.mascRoot) : []
  const detachedEarlierReceipts = data && decisionBinding ? earlierDropReceipts.filter(item =>
    item.owner.goalId !== selectedNode?.id && item.owner.mascRoot === decisionBinding.workspace.mascRoot) : []
  const detachedDropDrafts = data && authority && decisionBinding ? Object.values(goalDropDrafts.value).filter(item =>
    item.reason.trim() !== '' && item.owner.goalId !== selectedNode?.id
    && item.owner.workspaceRoot === authority.workspaceRoot && item.owner.mascRoot === decisionBinding.workspace.mascRoot
    && compatibleDropOwner(item.owner)
    && !compatibleDropReceipts.some(receipt => goalActionOwnerKey(receipt.owner) === goalActionOwnerKey(item.owner))) : []
  const otherAuthDropUncertain = Boolean(data && authority && decisionBinding && Object.values(goalActionHistory.value).flat().some(item =>
    item.action === 'drop' && item.uncertain && item.owner.workspaceRoot === authority.workspaceRoot
    && item.owner.mascRoot === decisionBinding.workspace.mascRoot && item.owner.goalId !== selectedNode?.id
    && allNodes.some(node => node.id === item.owner.goalId)
    && !compatibleDropOwner(item.owner)))
  const canAccessDropOwner = (owner: GoalActionOwner) => Boolean(authority && data && decisionBinding
    && !managedGoalCredentialRefused()
    && executionWorkspaceAuthority.peek() === authority && treeDecisionBinding.peek() === decisionBinding
    && treeData.peek() === data && storedTokenRevision.peek() === tokenRevision
    && goalDecisionActor() === decisionBinding.actor && authority.workspaceRoot === owner.workspaceRoot
    && decisionBinding.workspace.mascRoot === owner.mascRoot && compatibleDropOwner(owner))
  const openDropOwner = (owner: GoalActionOwner) => {
    if (!authority || !data || !decisionBinding || executionWorkspaceAuthority.peek() !== authority
      || treeDecisionBinding.peek() !== decisionBinding || treeData.peek() !== data
      || !canAccessDropOwner(owner)) return
    batch(() => {
      filterQuery.value = ''
      treePhaseFilter.value = 'all'
      selectGoal(owner.goalId)
      const path = goalExpansionPath(data.tree, owner.goalId) ?? [owner.goalId]
      expandedNodes.value = new Set([...expandedNodes.value, ...path])
    })
  }
  const clearDropDraft = (owner: GoalActionOwner) => {
    if (!canAccessDropOwner(owner)) return
    setGoalDropDraft(goalActionOwnerKey(owner), null)
  }
  const operationNotices = Object.entries(goalOperationNotices.value).filter(([, notice]) =>
    !authRefused && notice.authority === authority && notice.authRevision === tokenRevision && notice.actor === goalDecisionActor())
  const canOpenOperation = (notice: GoalOperationNotice) => Boolean(authority && data && decisionBinding
    && !managedGoalCredentialRefused()
    && executionWorkspaceAuthority.peek() === notice.authority && authority === notice.authority
    && storedTokenRevision.peek() === notice.authRevision && goalDecisionActor() === notice.actor
    && treeDecisionBinding.peek() === decisionBinding && treeData.peek() === data
    && decisionBinding.authority === notice.authority && decisionBinding.workspace.basePath === notice.workspace.basePath
    && decisionBinding.workspace.mascRoot === notice.workspace.mascRoot
    && goalIdIsUnambiguous(notice.goalId, data) && allNodes.some(node => node.id === notice.goalId))
  const openOperation = (notice: GoalOperationNotice) => {
    if (!data || !canOpenOperation(notice)) return
    batch(() => {
      filterQuery.value = ''
      treePhaseFilter.value = 'all'
      selectGoal(notice.goalId)
      const path = goalExpansionPath(data.tree, notice.goalId) ?? [notice.goalId]
      expandedNodes.value = new Set([...expandedNodes.peek(), ...path])
    })
  }

  return html`
    <div class="v2-workspace-surface flex flex-col gap-5">
      <section class="${GOAL_PANEL} v2-workspace-panel" aria-label="목표 관리자">
        <div class="mb-4 flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-190">
            <h3 class="text-2xl font-semibold tracking-[-0.02em] text-text-strong">목표 관리자</h3>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            ${data && data.tree.length > 0 ? html`
              <input
                type="search"
                value=${query}
                placeholder="목표 / 태스크 제목 필터"
                aria-label="목표 트리 필터"
                onInput=${(e: Event) => { filterQuery.value = (e.target as HTMLInputElement).value }}
                class="min-w-45 max-w-65 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-xs text-text-body placeholder:text-text-dim focus:outline-none focus:border-accent-fg"
              />
              <${ActionButton} variant="ghost" size="sm" class="v2-workspace-action" onClick=${() => expandAll(data.tree)}>
                모두 펼치기
              <//>
              <${ActionButton} variant="ghost" size="sm" class="v2-workspace-action" onClick=${collapseAll}>
                모두 접기
              <//>
            ` : null}
            <${ActionButton}
              variant="ghost"
              size="md"
              class="v2-workspace-action"
              disabled=${loading}
              onClick=${() => { void retryTree() }}
            >
              ${loading ? (authRefused ? '인증 확인 중...' : '새로고침 중...') : authRefused ? '인증 다시 확인' : '새로고침'}
            <//>
          </div>
        </div>

        ${data && data.tree.length > 0 ? html`
          <div class="mb-4 flex flex-wrap items-center gap-2">
            <span class="text-3xs font-semibold uppercase tracking-[var(--track-label)] text-text-muted">목표 단계</span>
            <${FilterChips}
              chips=${([
                'all',
                'executing',
                'verifying',
                'awaiting_confirmation',
                'completed',
                'dropped',
                'paused',
                'blocked',
              ] as GoalPhaseFilter[]).map(filter => ({
                key: filter,
                label: phaseFilterLabel(filter),
                count: phaseCounts[filter],
              }))}
              active=${treePhaseFilter}
              tone="accent"
              size="sm"
            />
          </div>
        ` : null}

        ${unavailable
          ? html`<${GoalStoreUnavailableAlert} unavailable=${unavailable} />`
          : error ? html`<${ErrorState} message=${error} />` : null}

        ${loading && data ? html`
          <div class="text-3xs text-text-dim" data-testid="goal-tree-loading">목표 트리 갱신 중...</div>
        ` : null}

        ${data ? html`
          <${TreeSummary}
            summary=${data.summary}
            awaitingVerificationCount=${countAwaitingVerificationInTree(data.tree)}
          />
        ` : null}
      </section>

      ${operationNotices.map(([key, notice]) => html`
        <section key=${key} role="status" data-testid="goal-operation-notice"
          class="rounded-[var(--r-1)] border border-[var(--color-border-subtle)] p-3 text-xs">
          <p>${goalOperationNoticeMessage(notice.state)}</p>
          ${canOpenOperation(notice) ? html`
            <${ActionButton} variant="ghost" size="sm" onClick=${() => openOperation(notice)}>
              같은 ID의 현재 Goal 열기
            <//>` : null}
          <${ActionButton} variant="ghost" size="sm" onClick=${() => {
            const next = { ...goalOperationNotices.peek() }
            delete next[key]
            goalOperationNotices.value = next
          }}>안내 닫기<//>
        </section>
      `)}

      ${!data && compatibleDropReceipts.length > 0 ? html`
        <p role="status" class="text-xs text-[var(--color-status-warn)]" data-testid="goal-drop-receipt-owner-unverified">
          이전 Drop 요청에 확인할 결과가 있습니다. 원래 연결과 workspace를 다시 확인해 주세요.
        </p>` : null}
      ${otherAuthDropUncertain ? html`
        <p role="status" class="text-xs text-[var(--color-status-warn)]" data-testid="goal-drop-other-auth-unverified">
          다른 연결 또는 인증의 Drop 결과 중 확인이 필요한 항목이 있습니다. 현재 Goal과 Task 상태를 확인해 주세요.
        </p>` : null}
      ${hiddenMatchingReceipts.length > 0 ? html`
        <${ActionButton} variant="ghost" size="sm" onClick=${() => {
          if (!authority || !data || !decisionBinding || executionWorkspaceAuthority.peek() !== authority
            || treeDecisionBinding.peek() !== decisionBinding || treeData.peek() !== data
            || storedTokenRevision.peek() !== tokenRevision || goalDecisionActor() !== decisionBinding.actor) return
          const restore = new Set(hiddenMatchingReceipts.map(item => item.ticket))
          hiddenDropReceipts.value = new Set([...hiddenDropReceipts.peek()].filter(ticket => !restore.has(ticket)))
        }}>숨긴 Drop 기록 다시 보기<//>` : null}
      ${detachedDropReceipts.map(item => html`
        <section key=${item.ticket} role="status" data-testid="goal-drop-detached-receipt"
          class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] p-3 text-xs text-[var(--color-status-warn)]">
          <p class="font-semibold">Goal ${item.owner.goalId} · ${item.state === 'pending' ? 'Drop 시도 진행 중' : '과거 Drop 요청 결과'}</p>
          <p class="break-all">요청 당시 workspace: ${item.owner.mascRoot}</p>
          <p class="mt-2 whitespace-pre-wrap break-words">${item.state === 'pending'
            ? 'Drop 시도가 진행 중입니다. 서버 수신 여부는 확인되지 않았습니다.' : item.message}</p>
          ${dropDraftForOwner(item.owner) !== null ? html`
            <p class="mt-2 whitespace-pre-wrap break-words">현재 Drop 사유 초안(이 시도 당시와 다를 수 있음): ${dropDraftForOwner(item.owner)}</p>` : null}
          <div class="mt-2 flex flex-wrap gap-2">
            ${data && allNodes.some(node => node.id === item.owner.goalId) ? html`
              <${ActionButton} variant="ghost" size="sm" onClick=${() => openDropOwner(item.owner)}>같은 ID Goal 열기<//>` : null}
            ${item.state !== 'pending' && dropDraftForOwner(item.owner) !== null ? html`
              <${ActionButton} variant="ghost" size="sm" onClick=${() => clearDropDraft(item.owner)}>이 초안 지우기<//>` : null}
            <${ActionButton} variant="ghost" size="sm" onClick=${() => {
              hiddenDropReceipts.value = new Set([...hiddenDropReceipts.peek(), item.ticket])
            }}>이 목록에서 숨기기<//>
          </div>
        </section>
      `)}
      ${detachedEarlierReceipts.map(item => html`
        <section key=${item.ticket} role="status" data-testid="goal-drop-earlier-connection"
          class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] p-3 text-xs text-[var(--color-status-warn)]">
          <p>Goal ${item.owner.goalId} · ${item.state === 'pending' ? '이전 연결의 Drop 시도가 진행 중입니다.' : '이전 연결의 Drop 결과가 있습니다.'} 현재 서버가 같은 workspace인지, 같은 ID Goal이 동일한 인스턴스인지는 확인되지 않았습니다.</p>
          ${expandedEarlierDropReceipts.value.has(earlierReceiptViewKey(item.ticket)) ? html`
            <div>
              <p class="mt-2 whitespace-pre-wrap break-words">${item.state === 'pending'
                ? 'Drop 시도가 진행 중입니다. 서버 수신 여부는 확인되지 않았습니다.' : item.message}</p>
              ${dropDraftForOwner(item.owner) !== null ? html`
                <p class="mt-2 whitespace-pre-wrap break-words">현재 Drop 사유 초안(이 시도 당시와 다를 수 있음): ${dropDraftForOwner(item.owner)}</p>` : null}
            </div>` : null}
          <div class="mt-2 flex flex-wrap gap-2">
            <${ActionButton} variant="ghost" size="sm" onClick=${() => {
              if (!canAccessDropOwner(item.owner)) return
              const key = earlierReceiptViewKey(item.ticket)
              const next = new Set(expandedEarlierDropReceipts.peek())
              if (next.has(key)) next.delete(key)
              else next.add(key)
              expandedEarlierDropReceipts.value = next
            }}>${expandedEarlierDropReceipts.value.has(earlierReceiptViewKey(item.ticket)) ? '이전 연결 결과 숨기기' : '이전 연결 결과 보기'}<//>
            ${data && allNodes.some(node => node.id === item.owner.goalId) ? html`
              <${ActionButton} variant="ghost" size="sm" onClick=${() => openDropOwner(item.owner)}>같은 ID Goal 열기<//>` : null}
            ${item.state !== 'pending' && dropDraftForOwner(item.owner) !== null ? html`
              <${ActionButton} variant="ghost" size="sm" onClick=${() => clearDropDraft(item.owner)}>이 초안 지우기<//>` : null}
            <${ActionButton} variant="ghost" size="sm" onClick=${() => {
              hiddenDropReceipts.value = new Set([...hiddenDropReceipts.peek(), item.ticket])
            }}>이 목록에서 숨기기<//>
          </div>
        </section>
      `)}
      ${detachedDropDrafts.map(item => html`
        <section key=${goalActionOwnerKey(item.owner)} data-testid="goal-drop-detached-draft"
          class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] p-3 text-xs text-[var(--color-status-warn)]">
          <p>Goal ${item.owner.goalId} · 보관 중인 Drop 사유 초안. 같은 ID의 현재 Goal과 동일한 인스턴스인지는 확인되지 않았습니다.</p>
          ${!sameDropSession(item.owner) ? html`<p>이 초안은 이전 연결에서 작성되었습니다. 현재 서버가 같은 workspace인지는 확인되지 않았습니다.</p>` : null}
          ${sameDropSession(item.owner) || expandedEarlierDropDrafts.value.has(earlierDraftViewKey(item.owner)) ? html`
            <p class="mt-2 whitespace-pre-wrap break-words">${item.reason}</p>` : null}
          <div class="mt-2 flex flex-wrap gap-2">
            ${!sameDropSession(item.owner) ? html`
              <${ActionButton} variant="ghost" size="sm" onClick=${() => {
                if (!canAccessDropOwner(item.owner)) return
                const key = earlierDraftViewKey(item.owner)
                const next = new Set(expandedEarlierDropDrafts.peek())
                if (next.has(key)) next.delete(key)
                else next.add(key)
                expandedEarlierDropDrafts.value = next
              }}>${expandedEarlierDropDrafts.value.has(earlierDraftViewKey(item.owner)) ? '이전 연결 초안 숨기기' : '이전 연결 초안 보기'}<//>` : null}
            ${allNodes.some(node => node.id === item.owner.goalId) ? html`
              <${ActionButton} variant="ghost" size="sm" onClick=${() => openDropOwner(item.owner)}>같은 ID Goal 열기<//>` : null}
            <${ActionButton} variant="ghost" size="sm" onClick=${() => clearDropDraft(item.owner)}>이 초안 지우기<//>
          </div>
        </section>
      `)}

      ${loading && !data ? html`
        <${LoadingState}>goal manager 로드 중...<//>
      ` : !data && !authority && !authorityLoading ? html`
        <div role="alert" class="text-sm text-[var(--color-status-err)]">
          workspace를 확인할 수 없습니다${authorityError ? `: ${authorityError}` : '.'}
          <button type="button" onClick=${() => { void refreshExecution({ force: true }).catch(() => {}) }}>다시 확인</button>
        </div>
      ` : !data && unconfirmed ? html`
        <div role="status" data-testid="goal-tree-unconfirmed">현재 Goal 상태를 다시 확인해 주세요.</div>
      ` : !data && !error && !unavailable ? html`
        <${LoadingState}>현재 workspace와 인증을 확인하는 중...<//>
      ` : data && data.tree.length === 0 ? html`
        <${EmptyState} message="등록된 목표 없음" />
      ` : data && isFiltering && visibleTree.length === 0 ? html`
        <section class="py-4 text-center text-xs text-text-dim" aria-label="필터 결과 없음">
          필터 결과 없음 (${data.tree.length} 목표)
        </section>
      ` : data ? html`
        <div class="grid gap-4 xl:grid-cols-[minmax(0,1.05fr)_minmax(360px,0.95fr)]">
          <section class="flex flex-col gap-2" aria-label="목표 트리">
            ${visibleTree.map(node => html`<${TreeNode} key=${node.id} node=${node} depth=${0} />`)}
          </section>
          <${GoalDetailPanel} selectedNode=${selectedNode} isRecoveryCurrent=${isRecoveryCurrent} />
        </div>
      ` : null}
    </div>
  `
}
