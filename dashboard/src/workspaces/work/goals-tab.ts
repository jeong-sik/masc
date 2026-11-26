/**
 * `2 Work > Goals` Tab (`goals-tab.ts`)
 *
 * - `MasterDetail` (42%/58%) + `VirtualList` for bounded DOM (<1,200 nodes).
 * - Strict closed-sum `goal_phase` badges (rejecting legacy `status` field).
 * - Strict `decodeGoalConfirmation()` reading `verification.completion.verdict` + `/health?full=1` `runtime_instance_id`.
 * - Capability-gated in `multi_account_signed_in` mode (skips unbridged `/api/v1/verification/requests`).
 * - Per-effect `AbortController` guards detail confirmation fetches against selection races.
 * - Verification verdicts strictly scoped to the selected Goal's linked tasks (zero unrelated fallback).
 */

import { html } from 'htm/preact'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { copyToClipboard } from '../../components/common/copyable-code'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { GoalSourceUnavailableError, goalSourceUnavailable } from '../../api/dashboard-goals'
import { activeWorkspaceId, currentSessionEpoch, isEpochCurrent } from '../../core/auth'
import { extractObserverTopics, markViewSynced, observerConnected, subscribeObserverFrames, subscribeObserverReconnect, subscribeObserverResync } from '../../core/observer'
import { formatObserved, resourceCache, type FetchReason, type Observed } from '../../core/resource-cache'
import { apiGet, apiMutate } from '../../core/transport'
import { KeeperBadge } from '../../components/keeper-badge'
import { InlineSpinner } from '../../components/common/inline-spinner'
import { formatDuration } from '../../lib/format-time'
import { MasterDetail, TargetLockedAction, VirtualList } from '../../components/primitives'
import {
  GOAL_PHASES,
  asNonEmptyString,
  asSafeInt,
  asString,
  asStringArray,
  availableGoalActions,
  callMcpToolViaCore,
  decodeGoalConfirmation,
  decodeGoalItem,
  formatRelativeTime,
  goalActivitySourceLabel,
  goalPhaseLabel,
  goalPhaseTone,
  isMultiAccountSession,
  isRecord,
  readWorkspacePrecondition,
  toExpectedWorkspaceBody,
  validateNewGoalInput,
  type GoalAction,
  type GoalActivity,
  type GoalConfirmationEvidence,
  type GoalItem,
  type GoalPhase,
  type VerificationRequestItem,
  type WorkspaceViewProps,
} from './types'

interface GoalListRead {
  readonly goals: readonly GoalItem[]
  readonly rejectedCount: number
  readonly incompleteTaskLinks: ReadonlySet<string>
}

interface VerificationListRead {
  readonly rows: readonly VerificationRequestItem[]
  readonly incomplete: boolean
  readonly recovery: string | null
}

type ConfirmationRead = { readonly goalId: string; readonly source: Observed<GoalListRead> } & (
  | { readonly kind: 'loading' }
  | { readonly kind: 'failed'; readonly message: string }
  | { readonly kind: 'ready'; readonly evidence: GoalConfirmationEvidence }
)

const goalListKey = 'work:goals:list'
const verificationListKey = 'work:goals:verification'
const goalTopics: readonly string[] = ['goal', 'goals', 'goal_updated', 'planning']
const verificationTopics: readonly string[] = ['verification', 'verification_requests', 'backlog', 'task', 'tasks']
const emptyRows: readonly never[] = []

function goalActivityText(activity: GoalActivity): string {
  switch (activity.kind) {
    case 'observed':
      return `${formatDuration(activity.stagnationSeconds)} 전 · ${goalActivitySourceLabel(activity.source)}`
    case 'unavailable':
      return '기록된 활동 없음'
    case 'unknown':
      return '확인 불가'
  }
}

function flattenGoalTree(nodes: unknown[], read: {
  goals: GoalItem[]
  rejectedCount: number
  incompleteTaskLinks: Set<string>
}): void {
  for (const node of nodes) {
    const decoded = decodeGoalItem(node)
    if (decoded.ok) {
      const goal = decoded.value
      read.goals.push(goal)
      const taskRows = isRecord(node) && Array.isArray(node.tasks) ? node.tasks : null
      const linkedCount = goal.linkedTaskCount
      if (taskRows !== null
        ? taskRows.length !== goal.linkedTasks.length
          || (linkedCount.kind === 'value' && linkedCount.data !== goal.linkedTasks.length)
        : linkedCount.kind !== 'value' || linkedCount.data !== 0) {
        read.incompleteTaskLinks.add(goal.id)
      }
    } else {
      read.rejectedCount += 1
    }
    if (isRecord(node) && Array.isArray(node.children)) {
      flattenGoalTree(node.children, read)
    }
  }
}

function decodeGoalList(raw: unknown, field: 'tree' | 'goals'): GoalListRead {
  const unavailable = goalSourceUnavailable(raw)
  if (unavailable) throw new GoalSourceUnavailableError(unavailable)
  const nodes = isRecord(raw) ? raw[field] : null
  if (!Array.isArray(nodes)) throw new Error('응답에서 목표 목록을 확인할 수 없습니다.')
  const read = { goals: [], rejectedCount: 0, incompleteTaskLinks: new Set<string>() }
  flattenGoalTree(nodes, read)
  return read
}

function decodeVerificationList(raw: unknown): VerificationListRead {
  if (!isRecord(raw)) throw new Error('검증 목록 응답 형식이 잘못되었습니다.')
  if (raw.backlog_error != null) throw new Error(asNonEmptyString(raw.backlog_error) ?? '태스크 대기열을 읽지 못했습니다.')
  if (!Array.isArray(raw.requests)) throw new Error('응답에서 검증 목록을 확인할 수 없습니다.')
  const items: VerificationRequestItem[] = []
  for (const r of raw.requests) {
    if (!isRecord(r)) continue
    const requestId = asNonEmptyString(r.request_id)
    const taskId = asNonEmptyString(r.task_id)
    if (!requestId || !taskId) continue
    const obs = isRecord(r.review_observation) ? r.review_observation : null
    items.push({
      requestId,
      taskId,
      taskTitle: asString(r.task_title, taskId),
      submittedBy: asString(r.submitted_by, 'unknown'),
      createdAt: typeof r.created_at === 'string' || typeof r.created_at === 'number' ? r.created_at : null,
      completionContract: asStringArray(r.completion_contract),
      submittedEvidence: asStringArray(r.submitted_evidence),
      reviewState: obs ? asNonEmptyString(obs.state) : null,
      reviewDetail: obs ? asNonEmptyString(obs.detail) : null,
    })
  }
  return {
    rows: items,
    incomplete: raw.truncated === true
      || (asSafeInt(raw.awaiting_unresolved_total) ?? 0) > 0
      || (asSafeInt(raw.unreadable_total) ?? 0) > 0
      || items.length < raw.requests.length,
    recovery: asNonEmptyString(raw.backlog_recovery),
  }
}

function refreshGoalList(reason: FetchReason) {
  return resourceCache.fetch<GoalListRead>(goalListKey, async (signal) => {
    const tree = await apiGet('/api/v1/dashboard/goals', { signal, decode: (raw) => decodeGoalList(raw, 'tree') })
    if (tree.ok || signal.aborted || tree.error.kind === 'epoch_stale') return tree
    return apiGet('/api/v1/dashboard/planning', { signal, decode: (raw) => decodeGoalList(raw, 'goals') })
  }, { ttlMs: 10_000, topics: goalTopics, reason })
}

function refreshVerificationList(reason: FetchReason) {
  return resourceCache.fetch<VerificationListRead>(verificationListKey, (signal) =>
    apiGet('/api/v1/verification/requests?view=awaiting&limit=50&offset=0', { signal, decode: decodeVerificationList }),
  { ttlMs: 10_000, topics: verificationTopics, reason })
}

// This view is keyed by auth epoch. Keep data already shown when a scoped
// reread fails, without treating it as the current response.
function useLastRead<T>(observation: Observed<T>): T | null {
  const last = useRef<T | null>(null)
  useLayoutEffect(() => {
    if (observation.kind === 'value') last.current = observation.data
  }, [observation])
  return observation.kind === 'value' ? observation.data : last.current
}

function showReadStatus(label: string, observation: Observed<unknown>, retained: boolean) {
  switch (observation.kind) {
    case 'loading':
      return html`<div class="wk-notice wk-notice--info" role="status"><${InlineSpinner} /> ${label} 불러오는 중…</div>`
    case 'value':
      return observation.stale
        ? html`<div class="wk-notice wk-notice--warn" role="status">${label} · 마지막 조회</div>`
        : null
    case 'failed':
    case 'unreported':
    case 'absent': {
      const detail = observation.kind === 'failed' ? observation.error.message : observation.reason
      return html`<div class="wk-notice wk-notice--err" role="alert">
        ${label} 조회 불가${retained ? ' · 마지막 조회 표시 중' : ''}${detail ? ` · ${detail}` : ''}
      </div>`
    }
  }
}

function actionLabel(action: GoalAction): string {
  switch (action) {
    case 'request_complete': return '완료 검증 요청'
    case 'pause': return '일시정지'
    case 'resume': return '재개'
    case 'block': return '차단'
    case 'unblock': return '차단 해제'
    case 'drop': return '중단(Drop)'
    case 'reopen': return '다시 열기'
  }
}

export function GoalsTab(props: WorkspaceViewProps) {
  const epoch = currentSessionEpoch()
  const multiAccount = isMultiAccountSession()
  const goalObservation = resourceCache.observe<GoalListRead>(goalListKey).value
  const verificationObservation = resourceCache.observe<VerificationListRead>(verificationListKey).value
  const goalRead = useLastRead(goalObservation)
  const verificationRead = useLastRead(verificationObservation)
  const goals = goalRead?.goals ?? emptyRows
  const verificationRows = verificationRead?.rows ?? emptyRows
  const goalsCurrent = goalObservation.kind === 'value' && !goalObservation.stale
  const goalCountsKnown = goalsCurrent && goalRead?.rejectedCount === 0
  const verificationsCurrent = !multiAccount && verificationObservation.kind === 'value'
    && !verificationObservation.stale && verificationObservation.data.recovery === null
  const [phaseFilter, setPhaseFilter] = useState<GoalPhase | 'ALL'>('ALL')
  const [query, setQuery] = useState('')
  const [selectedGoalId, setSelectedGoalId] = useState<string | null>(props.entityId ?? null)
  const selectedGoalRef = useRef<string | null>(null)

  // Create Goal form state
  const [showCreate, setShowCreate] = useState(false)
  const [title, setTitle] = useState('')
  const [measureKind, setMeasureKind] = useState<'done_when' | 'count' | 'quantity'>('done_when')
  const [condition, setCondition] = useState('')
  const [noun, setNoun] = useState('')
  const [total, setTotal] = useState('1')
  const [unit, setUnit] = useState('')
  const [direction, setDirection] = useState<'at_least' | 'at_most'>('at_least')
  const [target, setTarget] = useState('1')
  const [procedure, setProcedure] = useState('')
  const [priority, setPriority] = useState(2)
  const [createError, setCreateError] = useState<string | null>(null)
  const [createSuccess, setCreateSuccess] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)

  // Transition & Confirmation state
  const [transitionNote, setTransitionNote] = useState('')
  const [actionBusy, setActionBusy] = useState<string | null>(null)
  const [actionFeedback, setActionFeedback] = useState<{ kind: 'ok' | 'err'; message: string } | null>(null)

  const [confirmationRead, setConfirmationRead] = useState<ConfirmationRead | null>(null)
  const [liveConfirmRev, setLiveConfirmRev] = useState<string | null>(null)
  const confirmAbortRef = useRef<AbortController | null>(null)

  // Verification verdict state
  const [verdictReasonByReq, setVerdictReasonByReq] = useState<Record<string, string>>({})

  const loadData = useCallback((reason: FetchReason) => {
    if (!isEpochCurrent(epoch)) return
    void refreshGoalList(reason)
    if (!multiAccount) void refreshVerificationList(reason)
  }, [epoch, multiAccount])

  useEffect(() => {
    loadData('mount')
  }, [loadData])

  useEffect(() => {
    if (goalsCurrent) markViewSynced()
  }, [goalsCurrent])

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null
    let pendingGoals = false
    let pendingVerification = false
    const schedule = (goals: boolean, verification: boolean) => {
      if (!isEpochCurrent(epoch)) return
      pendingGoals ||= goals
      pendingVerification ||= verification && !multiAccount
      if (timer !== null || (!pendingGoals && !pendingVerification)) return
      timer = setTimeout(() => {
        timer = null
        if (isEpochCurrent(epoch)) {
          if (pendingGoals) void refreshGoalList('sse')
          if (pendingVerification) void refreshVerificationList('sse')
        }
        pendingGoals = false
        pendingVerification = false
      }, 450)
    }
    const invalidateReads = () => {
      if (!isEpochCurrent(epoch)) return
      resourceCache.invalidateKey(goalListKey)
      if (!multiAccount) resourceCache.invalidateKey(verificationListKey)
    }
    const unsubscribe = subscribeObserverFrames((frame) => {
      const topics = extractObserverTopics(frame)
      schedule(topics.some((topic) => goalTopics.includes(topic)),
        topics.some((topic) => verificationTopics.includes(topic)))
    })
    const unsubscribeReconnect = subscribeObserverReconnect(() => schedule(true, true))
    const unsubscribeResync = subscribeObserverResync((reason) => {
      invalidateReads()
      if (reason === 'observer_resync_required') schedule(true, true)
    })
    let connectedBefore = observerConnected.peek()
    const unsubscribeConnection = observerConnected.subscribe((connected) => {
      if (connected && !connectedBefore) {
        invalidateReads()
        schedule(true, true)
      }
      connectedBefore = connected
    })
    return () => {
      unsubscribe()
      unsubscribeReconnect()
      unsubscribeResync()
      unsubscribeConnection()
      if (timer !== null) clearTimeout(timer)
    }
  }, [epoch, multiAccount])

  useLayoutEffect(() => {
    setSelectedGoalId(props.entityId ?? null)
  }, [props.entityId])

  const filteredGoals = useMemo(() => {
    const q = query.trim().toLowerCase()
    return goals.filter((g) => {
      if (phaseFilter !== 'ALL' && g.phase !== phaseFilter) return false
      if (q && !g.title.toLowerCase().includes(q) && !g.id.toLowerCase().includes(q) && !g.measureText.toLowerCase().includes(q)) {
        return false
      }
      return true
    })
  }, [goals, phaseFilter, query])

  const phaseCounts = useMemo(() => {
    const counts: Record<string, number> = { ALL: goals.length }
    for (const p of GOAL_PHASES) counts[p] = 0
    for (const g of goals) counts[g.phase] = (counts[g.phase] ?? 0) + 1
    return counts
  }, [goals])

  const selectedGoal = useMemo(
    () => selectedGoalId === null
      ? goals[0] ?? null
      : goals.find((g) => g.id === selectedGoalId) ?? null,
    [goals, selectedGoalId],
  )
  useLayoutEffect(() => {
    selectedGoalRef.current = selectedGoal?.id ?? null
    if (selectedGoalId === null && goalsCurrent && selectedGoal) setSelectedGoalId(selectedGoal.id)
  }, [selectedGoalId, selectedGoal, goalsCurrent])
  const taskLinksIncomplete = selectedGoal !== null
    && (goalRead?.incompleteTaskLinks.has(selectedGoal.id) === true || !!verificationRead?.recovery)
  const selectedConfirmationRead = confirmationRead?.goalId === selectedGoal?.id
    && confirmationRead?.source === goalObservation ? confirmationRead : null
  const currentConfirmation = selectedConfirmationRead?.kind === 'ready'
    ? selectedConfirmationRead.evidence : null

  useEffect(() => subscribeObserverFrames((frame) => {
    if (!currentConfirmation || !isEpochCurrent(epoch)) return
    const topics = extractObserverTopics(frame)
    if (!topics.some((topic) => goalTopics.includes(topic))) return
    const data = isRecord(frame.data) ? frame.data : null
    const payload = isRecord(data?.payload) ? data.payload : data
    const goalId = asNonEmptyString(payload?.goal_id)
    if (!goalId || goalId === currentConfirmation.goalId) {
      const revision = asNonEmptyString(payload?.criterion_revision) ?? asNonEmptyString(payload?.revision)
      setLiveConfirmRev(revision ?? `${currentConfirmation.criterionRevision}:sse-${Date.now()}`)
    }
  }), [currentConfirmation, epoch])
  const verification = selectedGoal?.verification
  const proof = verification?.state === 'stale' ? verification.historical
    : verification?.state === 'current' && selectedGoal?.phase !== 'Awaiting_confirmation'
      ? verification.completion : null

  const loadConfirmation = useCallback(async (goalId: string, source: Observed<GoalListRead>) => {
    if (multiAccount || !isEpochCurrent(epoch) || source.kind !== 'value' || source.stale) return
    confirmAbortRef.current?.abort()
    const controller = new AbortController()
    confirmAbortRef.current = controller
    const { signal } = controller
    const owner = { goalId, source }

    setConfirmationRead({ ...owner, kind: 'loading' })

    const wsRes = await readWorkspacePrecondition()
    if (signal.aborted || !isEpochCurrent(epoch)) return
    if (!wsRes.ok) {
      setConfirmationRead({ ...owner, kind: 'failed', message: wsRes.error.message })
      return
    }
    const params = new URLSearchParams({
      goal_id: goalId,
      expected_base_path: wsRes.value.base_path,
      expected_masc_root: wsRes.value.masc_root,
    })
    const res = await apiGet<unknown>(`/api/v1/goals/confirmation?${params.toString()}`, { signal })
    if (signal.aborted || !isEpochCurrent(epoch)) return
    if (!res.ok) {
      setConfirmationRead({ ...owner, kind: 'failed', message: res.error.message })
      return
    }
    const decoded = decodeGoalConfirmation(res.value, goalId, wsRes.value)
    if (!decoded.ok) {
      setConfirmationRead({ ...owner, kind: 'failed', message: decoded.error })
      return
    }
    setConfirmationRead({ ...owner, kind: 'ready', evidence: decoded.value })
    setLiveConfirmRev(decoded.value.criterionRevision)
  }, [epoch, multiAccount])

  useEffect(() => {
    setTransitionNote('')
    setActionFeedback(null)
  }, [selectedGoal?.id])

  useEffect(() => {
    if (selectedGoal && selectedGoal.phase === 'Awaiting_confirmation') {
      void loadConfirmation(selectedGoal.id, goalObservation)
    }
    return () => confirmAbortRef.current?.abort()
  }, [selectedGoal?.id, selectedGoal?.phase, goalObservation, loadConfirmation])

  const handleCreateGoal = async (e: Event) => {
    e.preventDefault()
    if (multiAccount || !isEpochCurrent(epoch) || creating) return
    setCreateError(null)
    setCreateSuccess(null)
    const validated = validateNewGoalInput({
      title,
      measureKind,
      condition,
      noun,
      total,
      unit,
      direction,
      target,
      procedure,
      priority,
    })
    if (!validated.ok) {
      setCreateError(validated.error)
      return
    }
    setCreating(true)
    const wsRes = await readWorkspacePrecondition()
    if (!isEpochCurrent(epoch)) return
    if (!wsRes.ok) {
      setCreating(false)
      setCreateError(wsRes.error.message)
      return
    }
    const goalId = `goal-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
    const callRes = await callMcpToolViaCore('masc_goal_upsert', {
      id: goalId,
      if_absent: true,
      expected_workspace: toExpectedWorkspaceBody(wsRes.value),
      title: validated.value.title,
      measure: validated.value.measure,
      procedure: validated.value.procedure,
      priority: validated.value.priority,
    })
    if (!isEpochCurrent(epoch)) return
    setCreating(false)
    if (!callRes.ok) {
      setCreateError(callRes.error.message)
      return
    }
    setCreateSuccess(`목표 "${validated.value.title}" 생성 완료`)
    setTitle('')
    setCondition('')
    setNoun('')
    setProcedure('')
    setShowCreate(false)
    resourceCache.invalidateTopic('goals')
    loadData('manual')
  }

  const handleTransition = async (goal: GoalItem, action: GoalAction) => {
    if (multiAccount || !isEpochCurrent(epoch) || !goalsCurrent || actionBusy !== null) return
    setActionBusy(action)
    setActionFeedback(null)
    const wsRes = await readWorkspacePrecondition()
    if (!isEpochCurrent(epoch)) return
    if (resourceCache.peek(goalListKey) !== goalObservation || selectedGoalRef.current !== goal.id) {
      setActionBusy(null)
      setActionFeedback({ kind: 'err', message: '목표 정보가 변경되었습니다. 최신 상태를 확인한 뒤 다시 실행하세요.' })
      return
    }
    if (!wsRes.ok) {
      setActionBusy(null)
      setActionFeedback({ kind: 'err', message: wsRes.error.message })
      return
    }
    const body: Record<string, unknown> = {
      goal_id: goal.id,
      action,
      expected_workspace: toExpectedWorkspaceBody(wsRes.value),
    }
    if (transitionNote.trim()) body.note = transitionNote.trim()
    const res = await apiMutate<unknown>('POST', '/api/v1/tools/masc_goal_transition', body)
    if (!isEpochCurrent(epoch)) return
    setActionBusy(null)
    if (!res.ok) {
      setActionFeedback({ kind: 'err', message: `전이 실패 (${action}): ${res.error.message}` })
      return
    }
    setTransitionNote('')
    setActionFeedback({ kind: 'ok', message: `${goal.id} → ${action} 전이 적용됨` })
    resourceCache.invalidateTopic('goals')
    loadData('manual')
  }

  const handleConfirmCompletion = async () => {
    const confirmation = currentConfirmation
    if (!confirmation || !isEpochCurrent(epoch) || !goalsCurrent || actionBusy !== null
        || resourceCache.peek(goalListKey) !== goalObservation
        || selectedGoalRef.current !== confirmation.goalId
        || liveConfirmRev !== confirmation.criterionRevision) return
    setActionBusy('confirm')
    setActionFeedback(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/goals/confirmation', {
      goal_id: confirmation.goalId,
      criterion_revision: confirmation.criterionRevision,
      request_id: confirmation.requestId,
      verification_run_id: confirmation.verificationRunId,
      expected_workspace: confirmation.workspace,
      expected_operator_id: confirmation.inspectionOperatorId,
      expected_runtime_instance_id: confirmation.runtimeInstanceId,
    })
    if (!isEpochCurrent(epoch)) return
    setActionBusy(null)
    if (!res.ok) {
      setActionFeedback({ kind: 'err', message: `완료 확정 실패: ${res.error.message}` })
      return
    }
    setActionFeedback({ kind: 'ok', message: `목표 ${confirmation.goalId} 최종 완료 확정됨` })
    resourceCache.invalidateTopic('goals')
    loadData('manual')
  }

  const copyText = async (label: string, text: string) => {
    if (!text) return
    setActionFeedback(await copyToClipboard(text)
      ? { kind: 'ok', message: `${label} 복사됨` }
      : { kind: 'err', message: `${label} 복사에 실패했습니다. 직접 선택해 복사해 주세요.` })
  }

  const handleVerificationVerdict = async (
    req: VerificationRequestItem,
    verdict: 'approve' | 'reject',
  ) => {
    if (!isEpochCurrent(epoch) || !goalsCurrent || !verificationsCurrent || actionBusy !== null
        || resourceCache.peek(goalListKey) !== goalObservation
        || resourceCache.peek(verificationListKey) !== verificationObservation
        || selectedGoalRef.current !== selectedGoal?.id) return
    const reason = (verdictReasonByReq[req.requestId] ?? '').trim()
    if (verdict === 'reject' && !reason) {
      setActionFeedback({ kind: 'err', message: '반려(reject) 시 사유를 반드시 입력해야 합니다.' })
      return
    }
    setActionBusy(`verif:${req.requestId}`)
    setActionFeedback(null)
    const body: Record<string, unknown> = {
      task_id: req.taskId,
      verification_id: req.requestId,
      verdict,
    }
    if (verdict === 'reject') body.reason = reason
    const res = await apiMutate<unknown>('POST', '/api/v1/verification/verdict', body)
    if (!isEpochCurrent(epoch)) return
    setActionBusy(null)
    if (!res.ok) {
      setActionFeedback({ kind: 'err', message: `검증 판정 실패: ${res.error.message}` })
      return
    }
    setActionFeedback({
      kind: 'ok',
      message: `검증 ${req.requestId} (${req.taskId}) ${verdict === 'approve' ? '승인' : '반려'} 완료`,
    })
    resourceCache.invalidateTopic('verification')
    loadData('manual')
  }

  // Strictly scope verifications to the selected goal's linked tasks (zero cross-goal fallback!)
  const relatedVerifications = useMemo(() => {
    if (!selectedGoal) return []
    const linkedIds = new Set(selectedGoal.linkedTasks.map((t) => t.id))
    return verificationRows.filter((v) => linkedIds.has(v.taskId))
  }, [verificationRows, selectedGoal])
  // A count of related verifications is a fact only when both reads are current
  // and complete; otherwise an empty or partial list would read as "none".
  const relatedVerificationsKnown = verificationsCurrent && goalsCurrent
    && !verificationRead?.incomplete && !taskLinksIncomplete

  const linkedTaskSummary = useMemo(() => {
    if (!selectedGoal) return '—'
    const total = selectedGoal.linkedTasks.length
    const done = selectedGoal.linkedTasks.filter((t) => t.status === 'Done').length
    const awaiting = selectedGoal.linkedTasks.filter((t) => t.status === 'AwaitingVerification').length
    const cancelled = selectedGoal.linkedTasks.filter((t) => t.status === 'Cancelled').length
    const rest = total - done - awaiting - cancelled
    return `태스크 ${total}개 · 완료 ${done} · 검증 대기 ${awaiting} · 취소 ${cancelled} · 그 외 ${rest}`
  }, [selectedGoal])

  const masterPane = html`
    <div class="wk-pane-col">
      <div class="wk-pane-head">
        <h2 class="wk-pane-title">Goals <span class="wk-chip-count">(${goalCountsKnown ? filteredGoals.length : '—'})</span></h2>
        <div class="wk-actions">
          ${!multiAccount && html`
            <button type="button" class="btn-primary" onClick=${() => setShowCreate((v) => !v)}>
              ${showCreate ? '닫기' : '+ 새 목표'}
            </button>
          `}
          <button type="button" class="btn-ghost" onClick=${() => void loadData('manual')}>
            새로고침
          </button>
        </div>
      </div>

      <div class="wk-filter-bar">
        <input
          type="search"
          class="wk-input"
          placeholder="목표 제목, ID, 측정 조건 검색…"
          value=${query}
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          aria-label="목표 검색"
        />
        <div class="wk-chips" role="group" aria-label="목표 단계 필터">
          <button
            type="button"
            class="wk-chip"
            aria-pressed=${phaseFilter === 'ALL'}
            onClick=${() => setPhaseFilter('ALL')}
          >
            All <span class="wk-chip-count">${goalCountsKnown ? phaseCounts.ALL : '—'}</span>
          </button>
          ${GOAL_PHASES.map((phase) => html`
            <button
              key=${phase}
              type="button"
              class="wk-chip"
              aria-pressed=${phaseFilter === phase}
              onClick=${() => setPhaseFilter(phase)}
            >
              ${goalPhaseLabel(phase)}
              <span class="wk-chip-count">${goalCountsKnown ? phaseCounts[phase] : '—'}</span>
            </button>
          `)}
        </div>
        ${goalRead && goalRead.rejectedCount > 0 && html`
          <div class="wk-notice wk-notice--warn" role="status">
            형식이 올바르지 않은 목표 ${goalRead.rejectedCount}건을 읽지 못했습니다.
          </div>
        `}
      </div>

      ${showCreate && html`
        <form class="wk-form wk-inset" onSubmit=${handleCreateGoal}>
          <div class="wk-section-title">새 목표 생성 (measure + procedure 필수)</div>
          <div class="wk-field">
            <label for="goal-title">제목</label>
            <input
              id="goal-title"
              class="wk-input"
              required
              value=${title}
              onInput=${(e: Event) => setTitle((e.target as HTMLInputElement).value)}
              placeholder="예: 대시보드 DOM 1,200 이하 달성"
            />
          </div>
          <div class="wk-form-grid">
            <div class="wk-field">
              <label for="goal-measure-kind">성공 조건 유형 (measure)</label>
              <select
                id="goal-measure-kind"
                class="wk-select"
                value=${measureKind}
                onChange=${(e: Event) => setMeasureKind((e.target as HTMLSelectElement).value as 'done_when' | 'count' | 'quantity')}
              >
                <option value="done_when">완료 조건 (done_when)</option>
                <option value="count">개수 달성 (count)</option>
                <option value="quantity">수량 기준 (quantity)</option>
              </select>
            </div>
            <div class="wk-field">
              <label for="goal-priority">우선순위 (1=최고)</label>
              <input
                id="goal-priority"
                type="number"
                min="1"
                max="5"
                class="wk-input tnum"
                value=${priority}
                onInput=${(e: Event) => setPriority(Number((e.target as HTMLInputElement).value))}
              />
            </div>
          </div>

          ${measureKind === 'done_when' && html`
            <div class="wk-field">
              <label for="goal-measure-cond">완료 조건</label>
              <input
                id="goal-measure-cond"
                class="wk-input"
                value=${condition}
                onInput=${(e: Event) => setCondition((e.target as HTMLInputElement).value)}
                placeholder="참/거짓으로 판정 가능한 한 줄 조건"
              />
            </div>
          `}
          ${measureKind === 'count' && html`
            <div class="wk-form-grid">
              <div class="wk-field">
                <label for="goal-measure-noun">단위 명사 (noun)</label>
                <input id="goal-measure-noun" class="wk-input" value=${noun} onInput=${(e: Event) => setNoun((e.target as HTMLInputElement).value)} placeholder="예: PR" />
              </div>
              <div class="wk-field">
                <label for="goal-measure-total">목표 개수 (total)</label>
                <input id="goal-measure-total" type="number" min="1" class="wk-input tnum" value=${total} onInput=${(e: Event) => setTotal((e.target as HTMLInputElement).value)} />
              </div>
            </div>
          `}
          ${measureKind === 'quantity' && html`
            <div class="wk-form-grid">
              <div class="wk-field">
                <label for="goal-measure-dir">방향</label>
                <select id="goal-measure-dir" class="wk-select" value=${direction} onChange=${(e: Event) => setDirection((e.target as HTMLSelectElement).value as 'at_least' | 'at_most')}>
                  <option value="at_least">이상 (≥)</option>
                  <option value="at_most">이하 (≤)</option>
                </select>
              </div>
              <div class="wk-field">
                <label for="goal-measure-target">목표 수치</label>
                <input id="goal-measure-target" type="number" step="any" class="wk-input tnum" value=${target} onInput=${(e: Event) => setTarget((e.target as HTMLInputElement).value)} />
              </div>
              <div class="wk-field">
                <label for="goal-measure-unit">단위 (unit)</label>
                <input id="goal-measure-unit" class="wk-input" value=${unit} onInput=${(e: Event) => setUnit((e.target as HTMLInputElement).value)} placeholder="예: ms, KB" />
              </div>
            </div>
          `}

          <div class="wk-field">
            <label for="goal-procedure">측정 절차 (procedure — 필수)</label>
            <textarea
              id="goal-procedure"
              class="wk-textarea"
              value=${procedure}
              onInput=${(e: Event) => setProcedure((e.target as HTMLTextAreaElement).value)}
              onKeyDown=${(e: KeyboardEvent) => {
                if (e.isComposing || e.keyCode === 229) return
                if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && !creating) {
                  e.preventDefault()
                  void handleCreateGoal(e)
                }
              }}
              placeholder="Verifier가 실재성·도달 가능성을 검증할 수 있는 구체적 측정 절차"
            />
          </div>
          ${createError && html`<div class="wk-notice wk-notice--err" role="alert">${createError}</div>`}
          <div class="wk-actions">
            <button type="submit" class="btn-primary" disabled=${creating}>
              ${creating ? '생성 중…' : '목표 저장'}
            </button>
            <button type="button" class="btn-ghost" onClick=${() => setShowCreate(false)}>취소</button>
          </div>
        </form>
      `}

      ${createSuccess && html`<div class="wk-notice wk-notice--ok wk-inset">${createSuccess}</div>`}
      ${showReadStatus('목표 목록', goalObservation, goalRead !== null)}

      ${goalRead && html`
            <${VirtualList}
              items=${filteredGoals}
              estimateSize=${96}
              height="100%"
              ariaLabel="목표 목록"
              getItemKey=${(g: GoalItem) => g.id}
              empty=${goalsCurrent && html`<div class="wk-detail-pad"><span class="dtable-absent">${goalRead.rejectedCount > 0
                ? '읽은 범위에 표시할 목표가 없습니다.' : '표시할 목표가 없습니다.'}</span></div>`}
              renderItem=${(g: GoalItem) => html`
                <button
                  type="button"
                  class="wk-row-btn wk-goal-row"
                  data-selected=${selectedGoal?.id === g.id ? 'true' : 'false'}
                  onClick=${() => setSelectedGoalId(g.id)}
                >
                  <div class="wk-row-top">
                    <span class="wk-row-title" title=${g.title}>${g.title}</span>
                    <span class=${`wk-badge wk-badge--${goalPhaseTone(g.phase)}`}>
                      ${goalPhaseLabel(g.phase)}
                      ${g.resumePhase ? ` ↩ ${g.resumePhase}` : ''}
                    </span>
                  </div>
                  ${g.measureText && html`
                    <div class="wk-goal-measure" title=${g.measureText}>${g.measureText}</div>
                  `}
                  <div class="wk-row-meta">
                    <span class="mono">P${g.priority}</span>
                    <span class="tnum">Tasks: ${formatObserved(g.linkedTaskCount)}</span>
                    ${g.pendingApprovalCount !== null && g.pendingApprovalCount > 0 && html`
                      <span class="wk-badge wk-badge--warn tnum">승인 대기 ${g.pendingApprovalCount}</span>
                    `}
                    ${g.activity.kind === 'observed' && html`
                      <span class="tnum" title=${g.activity.lastActivityAt ?? ''}>마지막 활동 ${formatDuration(g.activity.stagnationSeconds)} 전</span>
                    `}
                    ${g.criterionVerdict.kind === 'viable' && html`<span class="wk-badge wk-badge--ok">기준 적합</span>`}
                    ${g.criterionVerdict.kind === 'needs_revision' && html`<span class="wk-badge wk-badge--err">기준 수정 필요</span>`}
                  </div>
                </button>
              `}
            />
          `}
    </div>
  `

  const detailPane = selectedGoal
    ? html`
        <div class="wk-detail-pad">
          <div class="wk-section-head">
            <div class="wk-min-w-0">
              <div class="mono wk-sub-id">${selectedGoal.id}</div>
              <h2 class="wk-heading">${selectedGoal.title}</h2>
            </div>
            <div class="wk-actions">
              <span class=${`wk-badge wk-badge--${goalPhaseTone(selectedGoal.phase)}`}>
                ${goalPhaseLabel(selectedGoal.phase)}
                ${selectedGoal.resumePhase ? ` (보존: ${selectedGoal.resumePhase})` : ''}
              </span>
              <button
                type="button"
                class="btn-ghost"
                aria-label="목표 ID 복사"
                title="목표 ID 복사"
                onClick=${() => void copyText('목표 ID', selectedGoal.id)}
              >
                ID 복사
              </button>
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => props.onNavigate(`/work/candle/${encodeURIComponent(selectedGoal.id)}`)}
              >
                Candle 지급 보기 →
              </button>
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => props.onInspect({
                  title: `Goal: ${selectedGoal.title}`,
                  subtitle: `${selectedGoal.id} · ${selectedGoal.phase}`,
                  kind: 'goal',
                  data: selectedGoal,
                })}
              >
                원본 검사
              </button>
            </div>
          </div>

          ${actionFeedback && html`
            <div class=${`wk-notice wk-notice--${actionFeedback.kind}`} role="status">
              ${actionFeedback.message}
            </div>
          `}

          <div class="wk-kv-grid">
            <div class="wk-kv">
              <span class="wk-kv-k">성공 조건 (measure)</span>
              <span class="wk-kv-v">${selectedGoal.measureText}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">우선순위 / 마감</span>
              <span class="wk-kv-v tnum">P${selectedGoal.priority} · ${selectedGoal.dueDate ?? '없음'}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">연결 태스크</span>
              <span class="wk-kv-v tnum">${formatObserved(selectedGoal.linkedTaskCount)}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">기준 리비전</span>
              <span class="wk-kv-v mono">${selectedGoal.criterionRevision ?? '없음'}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">승인 대기</span>
              <span class="wk-kv-v tnum">${selectedGoal.pendingApprovalCount === null ? '확인 불가' : `${selectedGoal.pendingApprovalCount}건`}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">마지막 활동</span>
              <span class="wk-kv-v tnum">${goalActivityText(selectedGoal.activity)}</span>
            </div>
          </div>

          <div class="wk-notice" role="status">
            ${taskLinksIncomplete || !goalsCurrent
              ? '태스크 목록 확인 중 — 아래 연결된 태스크와 검증 목록을 함께 보세요.'
              : relatedVerificationsKnown
                ? `${linkedTaskSummary} · 검증 제출 ${relatedVerifications.length}건${relatedVerifications.length > 0 ? ' (아래 목록)' : ''}`
                : `${linkedTaskSummary} · 검증 제출 —`}
          </div>

          <section class="wk-section" aria-label="측정 절차 및 기준 심사">
            <div class="wk-section-head">
              <h3 class="wk-section-title">측정 절차 (procedure) & Criterion Review</h3>
              ${selectedGoal.criterionVerdict.kind === 'viable' && html`<span class="wk-badge wk-badge--ok">Viable</span>`}
              ${selectedGoal.criterionVerdict.kind === 'needs_revision' && html`<span class="wk-badge wk-badge--err">Needs Revision</span>`}
              ${selectedGoal.criterionVerdict.kind === 'pending' && html`<span class="wk-badge wk-badge--idle">${selectedGoal.criterionVerdict.state}</span>`}
              ${selectedGoal.criterionVerdict.kind === 'unavailable' && html`<span class="wk-badge wk-badge--warn">Unavailable</span>`}
              <button
                type="button"
                class="btn-ghost"
                aria-label="측정 절차 복사"
                title="측정 절차 복사"
                disabled=${!selectedGoal.procedure}
                onClick=${() => void copyText('측정 절차', selectedGoal.procedure)}
              >
                복사
              </button>
              ${selectedGoal.phase === 'Awaiting_confirmation' && currentConfirmation && html`
                <span class="wk-muted-sm">최신 증거는 아래 Goal Completion Confirmation 참조 (기준 ${currentConfirmation.criterionRevision})</span>
              `}
            </div>
            <${MarkdownContent} class="wk-prose" text=${selectedGoal.procedure || '측정 절차 없음'} />
            <${MarkdownContent} class="wk-muted-sm" text=${
              selectedGoal.criterionVerdict.kind === 'viable' || selectedGoal.criterionVerdict.kind === 'needs_revision'
                ? selectedGoal.criterionVerdict.reason
                : selectedGoal.criterionVerdict.kind === 'unavailable'
                  ? selectedGoal.criterionVerdict.detail
                  : (selectedGoal.criterionVerdict.detail ?? 'Verifier 기준 심사 대기 중')
            } />
            ${selectedGoal.lastReviewNote && html`
              <div class="wk-notice">최근 전환 메모<${MarkdownContent} text=${selectedGoal.lastReviewNote} /></div>
            `}
          </section>

          ${!multiAccount && html`<section class="wk-section" aria-label="목표 단계 전환">
            <h3 class="wk-section-title">Phase Transition (POST /api/v1/tools/masc_goal_transition)</h3>
            <input
              type="text"
              class="wk-input"
              placeholder="전환 사유/메모 (선택, Drop 등 취소 사유는 last_review_note에 기록)"
              value=${transitionNote}
              onInput=${(e: Event) => setTransitionNote((e.target as HTMLInputElement).value)}
              aria-label="단계 전환 메모"
            />
            <div class="wk-actions">
              ${availableGoalActions(selectedGoal.phase).map((act) => html`
                <button
                  key=${act}
                  type="button"
                  class=${act === 'drop' || act === 'block' ? 'wk-btn-danger' : act === 'request_complete' ? 'btn-primary' : 'btn-ghost'}
                  disabled=${actionBusy !== null || !goalsCurrent}
                  onClick=${() => void handleTransition(selectedGoal, act)}
                >
                  ${actionBusy === act ? '처리 중…' : actionLabel(act)}
                </button>
              `)}
            </div>
          </section>`}

          ${selectedGoal.phase === 'Awaiting_confirmation' && html`
            <section class="wk-section" aria-label="목표 최종 완료 확인">
              <div class="wk-section-head">
                <h3 class="wk-section-title">Goal Completion Confirmation</h3>
                ${currentConfirmation && html`
                  <button
                    type="button"
                    class="btn-ghost"
                    aria-label="완료 증거 복사"
                    title="완료 증거 복사"
                    onClick=${() => void copyText('완료 증거', currentConfirmation.evidence)}
                  >
                    증거 복사
                  </button>
                `}
                ${!multiAccount && html`
                  <button type="button" class="btn-ghost" disabled=${!goalsCurrent} onClick=${() => void loadConfirmation(selectedGoal.id, goalObservation)}>
                    증거 다시 읽기
                  </button>
                `}
              </div>
              ${multiAccount && html`<div class="wk-notice wk-notice--info">이 세션에서는 완료 확인 증거를 조회할 수 없습니다.</div>`}
              ${selectedConfirmationRead?.kind === 'loading' && html`
                <span class="dtable-absent" role="status"><${InlineSpinner} /> Verifier 증명 증거 불러오는 중…</span>
              `}
              ${selectedConfirmationRead?.kind === 'failed' && html`
                <div class="wk-notice wk-notice--err" role="alert">${selectedConfirmationRead.message}</div>
              `}
              ${currentConfirmation && html`
                <div class="wk-muted-sm">
                  증명 주체: <strong>${currentConfirmation.actor}</strong> (${currentConfirmation.authorityKind}) · 기록: ${formatRelativeTime(currentConfirmation.recordedAt)}
                </div>
                <${MarkdownContent} class="wk-prose" text=${currentConfirmation.evidence} />
                <${TargetLockedAction}
                  target=${{
                    workspaceId: activeWorkspaceId.peek(),
                    keeper: currentConfirmation.actor,
                    requestId: currentConfirmation.requestId,
                    revision: currentConfirmation.criterionRevision,
                  }}
                  currentRevision=${liveConfirmRev ?? currentConfirmation.criterionRevision}
                  lockedEpoch=${epoch}
                  onRefresh=${() => void loadConfirmation(selectedGoal.id, goalObservation)}
                >
                  <button
                    type="button"
                    class="wk-btn-ok"
                    disabled=${actionBusy !== null || !goalsCurrent}
                    onClick=${() => void handleConfirmCompletion()}
                  >
                    ${actionBusy === 'confirm' ? '확정 중…' : '최종 완료 확정 (Confirm Completion)'}
                  </button>
                <//>
              `}
            </section>
          `}

          ${(proof?.state === 'proven' || proof?.state === 'refuted') && html`
            <section class="wk-section" aria-label="목표 검증 증거">
              <div class="wk-section-head">
                <h3 class="wk-section-title">${verification?.state === 'stale' ? '이전 기준의 검증 증거' : '목표 검증 증거'}</h3>
                <button
                  type="button"
                  class="btn-ghost"
                  aria-label="검증 증거 복사"
                  title="검증 증거 복사"
                  onClick=${() => void copyText('검증 증거', proof.evidence)}
                >
                  증거 복사
                </button>
              </div>
              <div class="wk-muted-sm">
                ${proof.state === 'proven' ? '증명됨' : '반증됨'} · ${proof.actor} · ${formatRelativeTime(proof.recordedAt)}
              </div>
              <${MarkdownContent} class="wk-prose" text=${proof.evidence} />
              ${proof.state === 'refuted' && html`<${MarkdownContent} class="wk-notice" text=${proof.reason} />`}
            </section>
          `}

          <section class="wk-section" aria-label="연결된 태스크">
            <div class="wk-section-head">
              <h3 class="wk-section-title">연결된 태스크 (${taskLinksIncomplete || !goalsCurrent ? '—' : selectedGoal.linkedTasks.length})</h3>
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => props.onNavigate('/work/tasks')}
              >
                전체 태스크 보기 →
              </button>
            </div>
            ${taskLinksIncomplete && html`
              <div class="wk-notice wk-notice--warn" role="status">연결된 태스크 목록을 모두 확인하지 못했습니다.</div>
            `}
            ${selectedGoal.linkedTasks.length === 0
              ? !taskLinksIncomplete && goalsCurrent && html`<span class="dtable-absent">연결된 태스크가 없습니다.</span>`
              : html`
                  <div class="wk-stack-1">
                    ${selectedGoal.linkedTasks.map((t) => html`
                      <button
                        key=${t.id}
                        type="button"
                        class="wk-row-btn wk-linked-row"
                        onClick=${() => props.onNavigate(`/work/tasks/${encodeURIComponent(t.id)}`)}
                      >
                        <div class="wk-row-top">
                          <span class="wk-row-title">${t.title}</span>
                          <span class="wk-badge">${t.status}</span>
                        </div>
                        <div class="wk-row-meta">
                          <span class="mono">${t.id}</span>
                          ${t.assignee ? html`<${KeeperBadge} id=${t.assignee} size="sm" />` : html`<span>미배정</span>`}
                        </div>
                      </button>
                    `)}
                  </div>
                `}
          </section>

          <section class="wk-section" aria-label="연결 태스크 검증 판정">
            <div class="wk-section-head">
              <h3 class="wk-section-title">Verification Verdicts (${relatedVerificationsKnown ? relatedVerifications.length : '—'})</h3>
              ${!multiAccount && html`
                <button type="button" class="btn-ghost" onClick=${() => void refreshVerificationList('manual')}>검증 다시 읽기</button>
              `}
            </div>
            ${multiAccount
              ? html`<div class="wk-notice wk-notice--info">이 세션에서는 검증 대기열을 조회할 수 없습니다.</div>`
              : html`
                  ${showReadStatus('검증 목록', verificationObservation, verificationRead !== null)}
                  ${verificationRead?.recovery && html`
                    <div class="wk-notice wk-notice--warn" role="status">현재 검증 목록 조회 불가 · 복구 스냅샷 표시 중</div>
                  `}
                  ${verificationRead?.incomplete && html`
                    <div class="wk-notice wk-notice--warn" role="status">검증 목록의 일부만 확인되었습니다.</div>
                  `}
                  ${relatedVerifications.length === 0 && verificationsCurrent && goalsCurrent && html`
                    <span class="dtable-absent">${verificationRead?.incomplete || taskLinksIncomplete
                      ? '읽은 범위에 이 목표의 검증 제출이 없습니다.'
                      : '이 목표에 연결된 태스크의 대기 중인 검증 제출이 없습니다.'}</span>
                  `}
                  ${relatedVerifications.map((req) => html`
                    <div key=${req.requestId} class="wk-subcard">
                      <div class="wk-row-top">
                        <strong>${req.taskTitle}</strong>
                        <span class="mono wk-sub-id">${req.requestId}</span>
                      </div>
                      <div class="wk-row-meta">
                        <span>제출: <${KeeperBadge} id=${req.submittedBy} size="sm" /></span>
                        <span>태스크: <span class="mono">${req.taskId}</span></span>
                        ${req.reviewState === 'running' && verificationsCurrent
                          ? html`<span class="wk-badge wk-badge--info"><${InlineSpinner} /> 검토 중</span>`
                          : req.reviewState && html`<span class="wk-badge">${req.reviewState === 'running'
                            ? '마지막 관측 · 검토 중' : req.reviewState}</span>`}
                      </div>
                      ${req.reviewDetail && html`<div class="wk-muted-sm">${req.reviewDetail}</div>`}
                      ${req.submittedEvidence.length > 0 && html`
                        <div class="wk-muted-sm">
                          증거
                          <ul>${req.submittedEvidence.map((evidence, index) => html`
                            <li key=${index}><${MarkdownContent} text=${evidence} /></li>
                          `)}</ul>
                        </div>
                      `}
                      <input
                        type="text"
                        class="wk-input"
                        placeholder="반려 사유 (reject 시 필수)"
                        value=${verdictReasonByReq[req.requestId] ?? ''}
                        onInput=${(e: Event) => setVerdictReasonByReq((prev) => ({
                          ...prev,
                          [req.requestId]: (e.target as HTMLInputElement).value,
                        }))}
                        aria-label=${`검증 ${req.requestId} 반려 사유`}
                      />
                      <div class="wk-actions">
                        <button
                          type="button"
                          class="wk-btn-ok"
                          disabled=${actionBusy !== null || !goalsCurrent || !verificationsCurrent}
                          onClick=${() => void handleVerificationVerdict(req, 'approve')}
                        >
                          검증 승인
                        </button>
                        <button
                          type="button"
                          class="wk-btn-danger"
                          disabled=${actionBusy !== null || !goalsCurrent || !verificationsCurrent}
                          onClick=${() => void handleVerificationVerdict(req, 'reject')}
                        >
                          검증 반려
                        </button>
                      </div>
                    </div>
                  `)}
                `}
          </section>
        </div>
      `
    : null

  return html`
    <${MasterDetail}
      master=${masterPane}
      detail=${detailPane}
      hasSelection=${selectedGoal !== null}
      selectionKey=${selectedGoalId}
      masterLabel="목표 목록"
      detailLabel="목표 상세"
      emptyDetail=${html`<div class="wk-detail-pad"><span class="dtable-absent">목표를 선택하면 단계 전환, 기준 심사, 검증 판정 및 연결 태스크를 확인할 수 있습니다.</span></div>`}
    />
  `
}
