/**
 * `2 Work > Tasks & Schedules` Tab (`tasks-tab.ts`)
 *
 * - `MasterDetail` + `VirtualList` (bounded DOM even with hundreds of tasks).
 * - 7 status filter chips (`All | Active | AwaitingVerify | Todo | Unlinked | Done | Schedules`)
 *   with exact reconciled counts (`Active = Claimed + InProgress`, fixing `#7`!).
 * - Full CRUD: Create Task (`masc_add_task`), Claim/Transition (`masc_transition`),
 *   Goal-link (`POST /api/v1/tasks/:id/link-goal` — strictly goalless tasks only per `constitution.xml`),
 *   Cancel (`POST /api/v1/dashboard/tasks/cancel`), Delete (`POST /api/v1/dashboard/tasks/delete`).
 * - Cursor-paginated Task History Timeline (`GET /api/v1/dashboard/tasks/history/page?task_id=&limit=20[&cursor=]`,
 *   with per-effect `AbortController` race guard and explicit `409 task_history_source_changed` handling).
 * - Scheduled Automation view & create (`GET /api/v1/dashboard/scheduled-automation?active_only=true`,
 *   `POST /api/v1/tools/masc_schedule_create`, `POST /api/v1/tools/masc_schedule_cancel`).
 */

import { html } from 'htm/preact'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { authSession, isEpochCurrent, sessionEpoch } from '../../core/auth'
import {
  extractObserverTopics,
  markViewSynced,
  observerConnected,
  subscribeObserverFrames,
  subscribeObserverReconnect,
  subscribeObserverResync,
} from '../../core/observer'
import { currentRoute } from '../../routes/router'
import { resourceCache, type FetchReason, type Observed } from '../../core/resource-cache'
import { apiGet, apiMutate } from '../../core/transport'
import { InlineSpinner } from '../../components/common/inline-spinner'
import { decodeVerificationCoverage, type VerificationCoverage } from '../../lib/verification-coverage'
import { KeeperBadge } from '../../components/keeper-badge'
import { MasterDetail, PopoverMenu, VirtualList } from '../../components/primitives'
import {
  asNonEmptyString,
  asSafeInt,
  asString,
  asStringArray,
  callMcpToolViaCore,
  checkTaskGoalLinkable,
  computeTaskFilterCounts,
  decodeGoalItem,
  decodeTaskItem,
  filterTasksByChip,
  formatRelativeTime,
  isRecord,
  readWorkspacePrecondition,
  toExpectedWorkspaceBody,
  type GoalItem,
  type ScheduleProjection,
  type ScheduleRow,
  type TaskFilterChip,
  type TaskHistoryPageData,
  type TaskItem,
  type TaskStatus,
  type VerificationRequestItem,
  type WorkspaceViewProps,
} from './types'

interface PlanningTasks {
  readonly tasks: readonly TaskItem[]
  readonly goals: readonly GoalItem[]
}

interface ExecutionTasks {
  readonly tasks: readonly TaskItem[]
  readonly omitted: number
  readonly retained: boolean
}

interface TaskReadOwner {
  readonly epoch: number
  readonly taskId: string
}

const planningKey = 'work:tasks:planning'
const executionKey = 'work:tasks:execution'
const taskTopics = [
  'task', 'tasks', 'task_updated', 'planning', 'backlog',
  'verification', 'verification_requests', 'goal_projection_changed',
]
const scheduleTopics = [
  'schedules', 'schedule_store_changed', 'scheduled_automation_changed', 'scheduled_automation',
]

function decodeTasks(raw: unknown): TaskItem[] {
  if (!isRecord(raw) || !Array.isArray(raw.tasks)) {
    throw new Error('태스크 목록 응답 형식이 잘못되었습니다.')
  }
  const tasks: TaskItem[] = []
  for (const row of raw.tasks) {
    const task = decodeTaskItem(row)
    if (task) tasks.push(task)
  }
  return tasks
}

function decodePlanningTasks(raw: unknown): PlanningTasks {
  if (!isRecord(raw) || (!Array.isArray(raw.goals) && !Array.isArray(raw.tasks))) {
    const detail = isRecord(raw) && raw.ok === false ? asNonEmptyString(raw.reason) : null
    throw new Error(detail ?? '계획 목록 응답 형식이 잘못되었습니다.')
  }
  const tasks = Array.isArray(raw.tasks) ? decodeTasks(raw) : []
  const goals: GoalItem[] = []
  if (Array.isArray(raw.goals)) {
    for (const row of raw.goals) {
      const goal = decodeGoalItem(row)
      if (goal.ok) goals.push(goal.value)
    }
  }
  return { tasks, goals }
}

function decodeExecutionTasks(raw: unknown): ExecutionTasks {
  const tasks = decodeTasks(raw)
  const counts = isRecord(raw) && isRecord(raw.task_counts) ? raw.task_counts : null
  const diagnostics = isRecord(raw) && isRecord(raw.projection_diagnostics) ? raw.projection_diagnostics : null
  const total = asSafeInt(counts?.total)
  const shown = asSafeInt(counts?.shown)
  const omitted = total !== null && shown !== null ? Math.max(0, total - shown) : 0
  return { tasks, omitted, retained: diagnostics?.cache_state === 'stale' }
}

function loadTaskSources(reason: FetchReason) {
  const options = { ttlMs: 10_000, topics: taskTopics, reason }
  return Promise.all([
    resourceCache.fetch(planningKey, (signal) =>
      apiGet('/api/v1/dashboard/planning', { signal, decode: decodePlanningTasks }), options),
    resourceCache.fetch(executionKey, (signal) =>
      apiGet('/api/v1/dashboard/execution?light=true', { signal, decode: decodeExecutionTasks }), options),
  ])
}

function sourceAlert(label: string, observation: Observed<unknown>) {
  switch (observation.kind) {
    case 'loading':
    case 'value':
      return null
    case 'absent':
    case 'unreported':
    case 'failed': {
      const reason = observation.kind === 'failed' ? observation.error.message : observation.reason
      return html`
        <div class="wk-notice wk-notice--warn wk-inset" role="alert">
          ${label} 조회 불가${reason ? ` · ${reason}` : ''}
        </div>
      `
    }
  }
}

function renderTaskSyncPill(sources: readonly { label: string; observation: Observed<unknown>; retained?: boolean }[]) {
  const loadingLabels: string[] = []
  const staleLabels: string[] = []
  for (const s of sources) {
    if (s.observation.kind === 'loading') {
      loadingLabels.push(s.label)
    } else if (s.observation.kind === 'value' && (s.observation.stale || Boolean(s.retained))) {
      staleLabels.push(s.label)
    }
  }
  const parts: string[] = []
  if (loadingLabels.length > 0) parts.push(`${loadingLabels.join(', ')} 불러오는 중…`)
  if (staleLabels.length > 0) parts.push(`${staleLabels.join(', ')} · 마지막 조회 결과`)
  if (parts.length === 0) return null
  const text = parts.join(' · ')
  const tone = staleLabels.length > 0 ? 'warn' : 'info'
  return html`
    <span class=${`wk-status-pill wk-status-pill--${tone}`} role="status" title=${text}>
      ${loadingLabels.length > 0 && html`<${InlineSpinner} />`}
      <span class="wk-status-pill-text">${text}</span>
    </span>
  `
}

interface TaskVerificationReport {
  readonly rows: readonly VerificationRequestItem[]
  readonly coverage: VerificationCoverage
  readonly malformedRows: number
}

type TaskVerificationRead = TaskReadOwner & (
  | { readonly kind: 'loading'; readonly report: TaskVerificationReport | null }
  | { readonly kind: 'ready'; readonly report: TaskVerificationReport }
  | { readonly kind: 'failed'; readonly report: TaskVerificationReport | null; readonly message: string }
)

function decodeTaskVerifications(raw: unknown, expectedTaskId: string): TaskVerificationReport {
  if (!isRecord(raw) || !Array.isArray(raw.requests)) {
    throw new Error('응답에 검증 이력이 없습니다')
  }
  const rows: VerificationRequestItem[] = []
  for (const r of raw.requests) {
    if (!isRecord(r)) continue
    const requestId = asNonEmptyString(r.request_id)
    const taskId = asNonEmptyString(r.task_id)
    if (!requestId || taskId !== expectedTaskId) continue
    const obs = isRecord(r.review_observation) ? r.review_observation : null
    rows.push({
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
  return { rows, coverage: decodeVerificationCoverage(raw), malformedRows: raw.requests.length - rows.length }
}

function reviewStateTone(state: string | null): 'ok' | 'err' | 'warn' | 'info' | 'idle' {
  switch (state) {
    case 'approved': return 'ok'
    case 'rejected':
    case 'failed':
    case 'commit_failed':
    case 'execution_repair_required': return 'err'
    case 'running':
    case 'execution_pending': return 'info'
    case 'unavailable':
    case 'not_reviewed':
    case 'cancelled': return 'warn'
    default: return 'idle'
  }
}

function decodeScheduleTimestamp(isoRaw: unknown, unixRaw: unknown): string | null {
  const iso = asNonEmptyString(isoRaw)
  if (iso) return iso
  if (typeof unixRaw === 'number' && Number.isFinite(unixRaw) && unixRaw > 0) {
    try {
      return new Date(unixRaw * 1000).toISOString()
    } catch {
      return null
    }
  }
  return asNonEmptyString(unixRaw)
}

function decodeSchedulesResponse(raw: unknown): ScheduleProjection {
  if (!isRecord(raw)) {
    return { state: 'unavailable', reason: '예약 자동화 응답 형식이 잘못되었습니다.' }
  }
  const readError = asNonEmptyString(raw.schedule_store_read_error)
  if (readError) return { state: 'unavailable', reason: readError }
  if (raw.schedule_store_known === false || raw.status === 'unknown') {
    return { state: 'unavailable', reason: '예약 저장소 상태를 확인할 수 없습니다.' }
  }
  if (!Array.isArray(raw.requests)) {
    return { state: 'unavailable', reason: '예약 자동화 응답 형식이 잘못되었습니다.' }
  }
  const rows: ScheduleRow[] = []
  for (const r of raw.requests) {
    if (!isRecord(r)) continue
    const scheduleId = asNonEmptyString(r.schedule_id)
    if (!scheduleId) continue
    const lastWake = isRecord(r.last_wake) ? r.last_wake : null
    const payload = isRecord(r.payload) && r.payload.kind === 'masc.keeper_wake'
      && isRecord(r.payload.body) ? r.payload.body : null
    rows.push({
      scheduleId,
      scheduleInstanceId: asString(r.schedule_instance_id, scheduleId),
      status: asString(r.status, 'scheduled'),
      source: asString(r.source, 'operator'),
      dueAt: decodeScheduleTimestamp(r.due_at_iso, r.due_at),
      nextDueAt: decodeScheduleTimestamp(r.next_due_at_iso, r.next_due_at),
      recurrenceKind: asString(r.recurrence_kind, 'one_shot'),
      recurrenceSummary: asString(r.recurrence_summary, ''),
      keeperName: asNonEmptyString(r.payload_keeper_name) ?? asNonEmptyString(r.payload_target),
      summary: asNonEmptyString(r.payload_summary),
      message: typeof payload?.message === 'string' && payload.message.trim() ? payload.message : null,
      lastWakeStatus: lastWake ? asNonEmptyString(lastWake.status) : null,
      lastWakeError: lastWake ? asNonEmptyString(lastWake.error) : null,
    })
  }
  const totalCount = asSafeInt(raw.request_count) ?? rows.length
  return { state: 'available', rows, totalCount, truncated: raw.truncated === true }
}

function taskStatusTone(status: TaskStatus): 'ok' | 'info' | 'warn' | 'err' | 'stalled' | 'idle' {
  switch (status) {
    case 'Todo': return 'idle'
    case 'Claimed': return 'info'
    case 'InProgress': return 'info'
    case 'AwaitingVerification': return 'warn'
    case 'Done': return 'ok'
    case 'Cancelled': return 'err'
  }
}

export function TasksTab(props: WorkspaceViewProps) {
  const epoch = sessionEpoch.value
  const routeViewParam = currentRoute.value.query.view
  const [chip, setChip] = useState<TaskFilterChip>(() => (routeViewParam === 'schedules' ? 'schedules' : 'all'))
  const [schedulesActiveOnly, setSchedulesActiveOnly] = useState(true)
  const scheduleKey = `work:schedules:active-only-${schedulesActiveOnly}`
  const planningObs = resourceCache.observe<PlanningTasks>(planningKey).value
  const executionObs = resourceCache.observe<ExecutionTasks>(executionKey).value
  const scheduleObs = resourceCache.observe<ScheduleProjection>(scheduleKey).value

  const planning = planningObs.kind === 'value' ? planningObs.data : null
  const execution = executionObs.kind === 'value' ? executionObs.data : null
  const schedules = scheduleObs.kind === 'value' ? scheduleObs.data : null
  const tasks = useMemo(() => {
    const byId = new Map<string, TaskItem>()
    for (const task of planning?.tasks ?? []) byId.set(task.id, task)
    for (const task of execution?.tasks ?? []) byId.set(task.id, task)
    return [...byId.values()]
  }, [planning, execution])
  const tasksCurrent = planningObs.kind === 'value' && !planningObs.stale
    && executionObs.kind === 'value' && !executionObs.stale && !executionObs.data.retained
  const schedulesCurrent = scheduleObs.kind === 'value' && !scheduleObs.stale
    && schedules?.state === 'available'

  useEffect(() => {
    if (routeViewParam === 'schedules') {
      setChip('schedules')
    }
  }, [routeViewParam])
  const [query, setQuery] = useState('')
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(props.entityId ?? null)
  const [selectedScheduleId, setSelectedScheduleId] = useState<string | null>(null)

  useEffect(() => {
    setSelectedTaskId(props.entityId ?? null)
  }, [props.entityId, epoch])
  useEffect(() => {
    setSelectedScheduleId(null)
  }, [epoch])

  // Task Create form
  const [showCreateTask, setShowCreateTask] = useState(false)
  const [newTaskTitle, setNewTaskTitle] = useState('')
  const [newTaskDesc, setNewTaskDesc] = useState('')
  const [newTaskPriority, setNewTaskPriority] = useState(2)
  const [newTaskGoalId, setNewTaskGoalId] = useState('')

  // Schedule Create form
  const [showCreateSchedule, setShowCreateSchedule] = useState(false)
  const [schedKeeper, setSchedKeeper] = useState('')
  const [schedMessage, setSchedMessage] = useState('')
  const [schedDueInSec, setSchedDueInSec] = useState(300)
  const [schedRepeat, setSchedRepeat] = useState<'one_shot' | 'interval'>('one_shot')
  const [schedIntervalSec, setSchedIntervalSec] = useState(3600)

  // Mutations & Detail controls
  const [linkGoalId, setLinkGoalId] = useState('')
  const [cancelReason, setCancelReason] = useState('')
  const [busyAction, setBusyAction] = useState<string | null>(null)
  const [feedback, setFeedback] = useState<{ kind: 'ok' | 'err' | 'warn'; message: string } | null>(null)

  useEffect(() => {
    setBusyAction(null)
    setFeedback(null)
  }, [epoch])

  // Per-task verification history (surfaces verdicts even for unlinked/goalless tasks)
  const [taskVerificationRead, setTaskVerificationRead] = useState<TaskVerificationRead | null>(null)
  const [verifRefreshTick, setVerifRefreshTick] = useState(0)

  // Cursor-paginated Task History Timeline (`#36`) with AbortController race guard
  const [historyEvents, setHistoryEvents] = useState<TaskHistoryPageData['events']>([])
  const [historyNextCursor, setHistoryNextCursor] = useState<string | null>(null)
  const [historyLoading, setHistoryLoading] = useState(false)
  const [historyError, setHistoryError] = useState<string | null>(null)
  const [historySourceChanged, setHistorySourceChanged] = useState(false)
  const [historyOwner, setHistoryOwner] = useState<TaskReadOwner | null>(null)
  const historyAbortRef = useRef<AbortController | null>(null)

  const loadSchedules = useCallback((reason: FetchReason) => resourceCache.fetch(
    scheduleKey,
    (signal) => apiGet(`/api/v1/dashboard/scheduled-automation?active_only=${schedulesActiveOnly}`,
      { signal, decode: decodeSchedulesResponse }),
    { ttlMs: 10_000, topics: scheduleTopics, reason },
  ), [scheduleKey, schedulesActiveOnly])
  const loadSchedulesRef = useRef(loadSchedules)
  loadSchedulesRef.current = loadSchedules
  useEffect(() => {
    void loadTaskSources('mount')
  }, [epoch])
  useEffect(() => {
    void loadSchedules('mount')
  }, [loadSchedules, epoch])
  useEffect(() => {
    if (chip === 'schedules' ? schedulesCurrent : tasksCurrent) markViewSynced()
  }, [chip, planningObs, executionObs, scheduleObs, tasksCurrent, schedulesCurrent])
  useEffect(() => {
    setSelectedTaskId((prev) => {
      if (prev && (!tasksCurrent || tasks.some((t) => t.id === prev))) return prev
      return tasks[0]?.id ?? null
    })
  }, [tasks, tasksCurrent, props.entityId, epoch])
  useEffect(() => {
    if (schedules?.state !== 'available') return
    setSelectedScheduleId((prev) => {
      if (prev && (!schedulesCurrent || schedules.rows.some((row) => row.scheduleId === prev))) return prev
      return schedules.rows[0]?.scheduleId ?? null
    })
  }, [schedules, schedulesCurrent, epoch])

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null
    let pendingTaskReload = false
    let pendingScheduleReload = false
    let pendingVerifReload = false
    const scheduleReload = (taskChanged: boolean, scheduleChanged: boolean, verificationsChanged: boolean) => {
      pendingTaskReload ||= taskChanged
      pendingScheduleReload ||= scheduleChanged
      pendingVerifReload ||= verificationsChanged
      if (timer) return
      timer = setTimeout(() => {
        timer = null
        if (!isEpochCurrent(epoch)) return
        if (pendingTaskReload) void loadTaskSources('sse')
        if (pendingScheduleReload) void loadSchedulesRef.current('sse')
        if (pendingVerifReload) setVerifRefreshTick((t) => t + 1)
        pendingTaskReload = false
        pendingScheduleReload = false
        pendingVerifReload = false
      }, 450)
    }
    const unsub = subscribeObserverFrames((frame) => {
      if (!isEpochCurrent(epoch)) return
      const topics = extractObserverTopics(frame)
      const data = isRecord(frame.data) ? frame.data : null
      const payload = isRecord(data?.payload) ? data.payload : data
      const executionInvalidated = topics.includes('execution_snapshot') && payload?.execution_invalidated === true
      if (executionInvalidated) resourceCache.invalidateTopic('tasks')
      const taskChanged = executionInvalidated || topics.some((t) => taskTopics.includes(t))
      const scheduleChanged = topics.some((t) => scheduleTopics.includes(t))
      if (!taskChanged && !scheduleChanged) return
      scheduleReload(taskChanged, scheduleChanged,
        topics.includes('verification') || topics.includes('verification_requests'))
    })
    const invalidateSources = () => {
      if (!isEpochCurrent(epoch)) return
      resourceCache.invalidateTopic('tasks')
      resourceCache.invalidateTopic('schedules')
    }
    const unsubResync = subscribeObserverResync((reason) => {
      invalidateSources()
      if (reason === 'observer_resync_required') scheduleReload(true, true, true)
    })
    const unsubReconnect = subscribeObserverReconnect(() => scheduleReload(true, true, true))
    let wasConnected = observerConnected.peek()
    const unsubConnection = observerConnected.subscribe((connected) => {
      if (connected && !wasConnected) {
        invalidateSources()
        scheduleReload(true, true, true)
      }
      wasConnected = connected
    })
    return () => {
      unsub()
      unsubResync()
      unsubReconnect()
      unsubConnection()
      if (timer) clearTimeout(timer)
    }
  }, [epoch])

  const counts = useMemo(() => computeTaskFilterCounts(tasks), [tasks])

  const filteredTasks = useMemo(() => {
    const base = filterTasksByChip(tasks, chip)
    const q = query.trim().toLowerCase()
    if (!q) return base
    return base.filter((t) =>
      t.title.toLowerCase().includes(q)
      || t.id.toLowerCase().includes(q)
      || (t.assignee?.toLowerCase().includes(q) ?? false)
      || (t.goalId?.toLowerCase().includes(q) ?? false),
    )
  }, [tasks, chip, query])

  const selectedTask = tasks.find((t) => t.id === selectedTaskId)
    ?? (selectedTaskId === null ? tasks[0] ?? null : null)
  const selectedSchedule = schedules?.state === 'available'
    ? schedules.rows.find((s) => s.scheduleId === selectedScheduleId) ?? schedules.rows[0] ?? null
    : null

  const loadHistoryPage = useCallback(async (
    taskId: string,
    cursor: string | null,
    append: boolean,
  ) => {
    historyAbortRef.current?.abort()
    const controller = new AbortController()
    historyAbortRef.current = controller
    const signal = controller.signal

    setHistoryOwner({ epoch, taskId })
    if (!append) {
      setHistoryEvents([])
      setHistoryNextCursor(null)
    }
    setHistoryLoading(true)
    setHistoryError(null)
    setHistorySourceChanged(false)
    const params = new URLSearchParams({
      task_id: taskId,
      limit: '20',
    })
    if (cursor) params.set('cursor', cursor)
    const res = await apiGet<TaskHistoryPageData>(`/api/v1/dashboard/tasks/history/page?${params.toString()}`, { signal })
    if (signal.aborted || !isEpochCurrent(epoch)) return
    setHistoryLoading(false)
    if (!res.ok) {
      if (res.error.kind === 'conflict_cas' || res.error.status === 409 || res.error.code === 'task_history_source_changed') {
        setHistorySourceChanged(true)
        setHistoryNextCursor(null)
        setHistoryError('이력 원장이 변경되어 현재 커서가 만료되었습니다 (409 task_history_source_changed). 처음부터 다시 불러오세요.')
        return
      }
      setHistoryError(res.error.message)
      return
    }
    const pageEvents = Array.isArray(res.value.events) ? res.value.events : []
    setHistoryEvents((prev) => (append ? [...prev, ...pageEvents] : pageEvents))
    setHistoryNextCursor(res.value.next_cursor ?? null)
  }, [epoch])

  const isSingleUser = authSession.value.kind === 'single_user_local'
  const isSchedulesView = chip === 'schedules'
  const selectedTaskKey = selectedTask?.id ?? null
  const historyCurrent = historyOwner?.epoch === epoch && historyOwner.taskId === selectedTaskKey
  const visibleVerificationRead = taskVerificationRead?.taskId === selectedTaskKey
    && taskVerificationRead.epoch === epoch ? taskVerificationRead : null
  const visibleVerificationReport = visibleVerificationRead?.report ?? null
  const taskVerifications = visibleVerificationReport?.rows ?? []
  const verificationCoverageNotices: string[] = []
  if (visibleVerificationReport) {
    const { coverage, malformedRows } = visibleVerificationReport
    if (coverage.unreadableTotal !== null && coverage.unreadableTotal > 0) {
      verificationCoverageNotices.push(`전체 검증 저장소에서 ${coverage.unreadableTotal}건 읽기 불가`)
    }
    if (malformedRows > 0) verificationCoverageNotices.push(`응답에서 ${malformedRows}건 표시 불가`)
    if (coverage.truncated) {
      verificationCoverageNotices.push(coverage.total === null
        ? '검증 이력 일부만 표시'
        : `검증 이력 ${coverage.total}건 중 ${taskVerifications.length}건 표시`)
    }
  }

  useEffect(() => {
    setCancelReason('')
    setLinkGoalId('')
  }, [selectedTaskKey, selectedSchedule?.scheduleId, chip])

  useEffect(() => {
    if (isSchedulesView || !selectedTaskKey) return undefined
    void loadHistoryPage(selectedTaskKey, null, false)
    return () => historyAbortRef.current?.abort()
  }, [isSchedulesView, selectedTaskKey, loadHistoryPage])

  useEffect(() => {
    if (isSchedulesView || !selectedTaskKey || !isSingleUser) return undefined
    const controller = new AbortController()
    const scope = { taskId: selectedTaskKey, epoch }
    const lastReport = (read: TaskVerificationRead | null) =>
      read?.taskId === scope.taskId && read.epoch === scope.epoch ? read.report : null
    setTaskVerificationRead((read) => ({ ...scope, kind: 'loading', report: lastReport(read) }))
    void apiGet<TaskVerificationReport>(
      `/api/v1/verification/requests?view=all&task_id=${encodeURIComponent(selectedTaskKey)}&limit=10`,
      { signal: controller.signal, decode: (raw) => decodeTaskVerifications(raw, selectedTaskKey) },
    ).then((res) => {
      if (controller.signal.aborted || !isEpochCurrent(epoch)) return
      if (res.ok) {
        setTaskVerificationRead({ ...scope, kind: 'ready', report: res.value })
      } else if (
        res.error.kind !== 'aborted'
        && res.error.kind !== 'epoch_stale'
      ) {
        setTaskVerificationRead((read) => ({ ...scope, kind: 'failed', report: lastReport(read), message: res.error.message }))
      }
    })
    return () => {
      controller.abort()
    }
  }, [isSchedulesView, selectedTaskKey, verifRefreshTick, isSingleUser, epoch])

  const handleCreateTask = async (e: Event) => {
    e.preventDefault()
    const trimmed = newTaskTitle.trim()
    if (!trimmed) {
      setFeedback({ kind: 'err', message: '태스크 제목을 입력하세요.' })
      return
    }
    setBusyAction('create-task')
    setFeedback(null)
    const args: Record<string, unknown> = {
      title: trimmed,
      description: newTaskDesc.trim(),
      priority: newTaskPriority,
    }
    if (newTaskGoalId.trim()) args.goal_id = newTaskGoalId.trim()
    const res = await callMcpToolViaCore('masc_add_task', args)
    if (!isEpochCurrent(epoch)) return
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `태스크 생성 실패: ${res.error.message}` })
      return
    }
    setNewTaskTitle('')
    setNewTaskDesc('')
    setNewTaskGoalId('')
    setShowCreateTask(false)
    setFeedback({ kind: 'ok', message: `태스크 "${trimmed}" 생성 완료` })
    resourceCache.invalidateTopic('tasks')
    await loadTaskSources('manual')
  }

  const handleTaskTransition = async (task: TaskItem, action: 'claim' | 'start' | 'release') => {
    setBusyAction(action)
    setFeedback(null)
    const res = await callMcpToolViaCore('masc_transition', { task_id: task.id, action })
    if (!isEpochCurrent(epoch)) return
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `전환 실패 (${action}): ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `${task.id} → ${action} 적용됨` })
    resourceCache.invalidateTopic('tasks')
    await loadTaskSources('manual')
  }

  const handleLinkGoal = async (task: TaskItem) => {
    const linkable = checkTaskGoalLinkable(task)
    if (!linkable.ok) {
      setFeedback({
        kind: 'warn',
        message: linkable.error === 'Already_assigned'
          ? '이미 Goal에 연결된 태스크는 재할당하거나 해제할 수 없습니다 (Already_assigned).'
          : '완료 또는 취소된 태스크에는 Goal을 연결할 수 없습니다.',
      })
      return
    }
    const targetGoalId = linkGoalId.trim()
    if (!targetGoalId) {
      setFeedback({ kind: 'err', message: '연결할 Goal을 선택하세요.' })
      return
    }
    setBusyAction('link-goal')
    setFeedback(null)
    const wsRes = await readWorkspacePrecondition()
    if (!isEpochCurrent(epoch)) return
    if (!wsRes.ok) {
      setBusyAction(null)
      setFeedback({ kind: 'err', message: wsRes.error.message })
      return
    }
    const res = await apiMutate<unknown>(
      'POST',
      `/api/v1/tasks/${encodeURIComponent(task.id)}/link-goal`,
      { goal_id: targetGoalId, expected_workspace: toExpectedWorkspaceBody(wsRes.value) },
    )
    if (!isEpochCurrent(epoch)) return
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `Goal 연결 실패: ${res.error.message}` })
      return
    }
    setLinkGoalId('')
    setFeedback({ kind: 'ok', message: `${task.id} → Goal ${targetGoalId} 연결 완료` })
    resourceCache.invalidateTopic('tasks')
    await loadTaskSources('manual')
  }

  const handleCancelTask = async (task: TaskItem) => {
    setBusyAction('cancel')
    setFeedback(null)
    const wsRes = await readWorkspacePrecondition()
    if (!isEpochCurrent(epoch)) return
    if (!wsRes.ok) {
      setBusyAction(null)
      setFeedback({ kind: 'err', message: wsRes.error.message })
      return
    }
    const body: Record<string, unknown> = {
      task_id: task.id,
      expected_workspace: toExpectedWorkspaceBody(wsRes.value),
    }
    if (cancelReason.trim()) body.reason = cancelReason.trim()
    const res = await apiMutate<unknown>('POST', '/api/v1/dashboard/tasks/cancel', body)
    if (!isEpochCurrent(epoch)) return
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `태스크 취소 실패: ${res.error.message}` })
      return
    }
    setCancelReason('')
    setFeedback({ kind: 'ok', message: `태스크 ${task.id} 취소 완료` })
    resourceCache.invalidateTopic('tasks')
    await loadTaskSources('manual')
  }

  const handleDeleteTask = async (task: TaskItem) => {
    setBusyAction('delete')
    setFeedback(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/dashboard/tasks/delete', { task_id: task.id })
    if (!isEpochCurrent(epoch)) return
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `태스크 삭제 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `태스크 ${task.id} 삭제 완료` })
    resourceCache.invalidateTopic('tasks')
    await loadTaskSources('manual')
  }

  const handleCreateSchedule = async (e: Event) => {
    e.preventDefault()
    if (!schedKeeper.trim() || !schedMessage.trim()) {
      setFeedback({ kind: 'err', message: '대상 Keeper와 예약 메시지를 입력하세요.' })
      return
    }
    setBusyAction('create-schedule')
    setFeedback(null)
    const body: Record<string, unknown> = {
      keeper_name: schedKeeper.trim(),
      message: schedMessage.trim(),
      due_in_sec: Math.max(10, Math.trunc(schedDueInSec)),
      recurrence_kind: schedRepeat,
    }
    if (schedRepeat === 'interval') {
      body.recurrence_interval_sec = Math.max(60, Math.trunc(schedIntervalSec))
    }
    const res = await apiMutate<unknown>('POST', '/api/v1/tools/masc_schedule_create', body)
    if (!isEpochCurrent(epoch)) return
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `예약 생성 실패: ${res.error.message}` })
      return
    }
    setSchedMessage('')
    setShowCreateSchedule(false)
    setFeedback({ kind: 'ok', message: `${schedKeeper.trim()} 예약 자동화 등록 완료` })
    resourceCache.invalidateTopic('schedules')
    await loadSchedulesRef.current('manual')
  }

  const handleCancelSchedule = async (scheduleId: string) => {
    setBusyAction(`cancel-sched:${scheduleId}`)
    setFeedback(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/tools/masc_schedule_cancel', {
      schedule_id: scheduleId,
      reason: 'operator cancelled from dashboard',
    })
    if (!isEpochCurrent(epoch)) return
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `예약 취소 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `예약 ${scheduleId} 취소됨` })
    resourceCache.invalidateTopic('schedules')
    await loadSchedulesRef.current('manual')
  }

  const taskCountLabel = (count: number) => tasksCurrent ? String(count) : '—'
  const scheduleCountLabel = schedulesCurrent && schedules?.state === 'available'
    ? String(schedules.totalCount)
    : '—'

  const chipItems: readonly { id: TaskFilterChip; label: string; count: string }[] = [
    { id: 'all', label: 'All', count: taskCountLabel(counts.all) },
    { id: 'active', label: 'Active', count: taskCountLabel(counts.active) },
    { id: 'awaiting_verify', label: 'AwaitingVerify', count: taskCountLabel(counts.awaiting_verify) },
    { id: 'todo', label: 'Todo', count: taskCountLabel(counts.todo) },
    { id: 'unlinked', label: 'Unlinked', count: taskCountLabel(counts.unlinked) },
    { id: 'done', label: 'Done', count: taskCountLabel(counts.done + counts.cancelled) },
    { id: 'schedules', label: 'Schedules', count: scheduleCountLabel },
  ]

  const tasksSyncPill = isSchedulesView
    ? renderTaskSyncPill([{ label: '예약 목록', observation: scheduleObs }])
    : renderTaskSyncPill([
        { label: '계획 목록', observation: planningObs },
        { label: '실행 태스크', observation: executionObs, retained: execution?.retained },
      ])

  const activeChipItem = chipItems.find((c) => c.id === chip) ?? chipItems[0]!
  const activeChipDisplay = activeChipItem.id === 'all' ? '전체' : activeChipItem.label

  const masterPane = html`
    <div class="wk-pane-col">
      <div class="wk-pane-head">
        <h2 class="wk-pane-title">
          ${chip === 'schedules' ? 'Scheduled Automation' : 'Tasks'}
        </h2>
        <div class="wk-pane-status-slot" data-testid="tasks-sync-slot">
          ${tasksSyncPill}
        </div>
        <div class="wk-actions">
          ${chip === 'schedules'
            ? html`<button type="button" class="btn-primary" onClick=${() => setShowCreateSchedule((v) => !v)}>${showCreateSchedule ? '닫기' : '+ 새 예약'}</button>`
            : html`<button type="button" class="btn-primary" onClick=${() => setShowCreateTask((v) => !v)}>${showCreateTask ? '닫기' : '+ 새 태스크'}</button>`}
          <button
            type="button"
            class="btn-ghost"
            onClick=${() => void (isSchedulesView ? loadSchedules('manual') : loadTaskSources('manual'))}
          >새로고침</button>
        </div>
      </div>

      <div class="wk-filter-bar">
        <div class="wk-filter-row">
          <${PopoverMenu}
            triggerLabel=${`상태: ${activeChipDisplay} (${activeChipItem.count}) ▾`}
            triggerClassName="btn-ghost"
            triggerTestId="tasks-status-filter"
            popoverTestId="tasks-status-filter-menu"
            ariaLabel="태스크 상태 필터"
            items=${chipItems.map((c) => ({
              id: c.id,
              testId: `tasks-filter-${c.id}`,
              label: `${c.id === 'all' ? '전체' : c.label} (${c.count})`,
              active: chip === c.id,
              separatorBefore: c.id === 'schedules',
              onSelect: () => setChip(c.id),
            }))}
          />
          ${chip === 'schedules'
            ? html`
                <div class="wk-chips" role="group" aria-label="예약 범위 필터">
                  <button
                    type="button"
                    class="wk-chip"
                    aria-pressed=${schedulesActiveOnly}
                    onClick=${() => setSchedulesActiveOnly(true)}
                  >
                    활성만
                  </button>
                  <button
                    type="button"
                    class="wk-chip"
                    aria-pressed=${!schedulesActiveOnly}
                    onClick=${() => setSchedulesActiveOnly(false)}
                  >
                    전체 이력
                  </button>
                </div>
              `
            : html`
                <input
                  type="search"
                  class="wk-input wk-filter-search"
                  placeholder="태스크 제목, ID, 담당 Keeper, Goal ID 검색…"
                  value=${query}
                  onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
                  aria-label="태스크 검색"
                />
              `}
        </div>
      </div>

      ${showCreateTask && chip !== 'schedules' && html`
        <form class="wk-form wk-inset" onSubmit=${handleCreateTask}>
          <div class="wk-section-title">새 태스크 추가 (masc_add_task)</div>
          <div class="wk-field">
            <label for="new-task-title">제목</label>
            <input id="new-task-title" class="wk-input" required value=${newTaskTitle} onInput=${(e: Event) => setNewTaskTitle((e.target as HTMLInputElement).value)} />
          </div>
          <div class="wk-field">
            <label for="new-task-desc">설명</label>
            <textarea
              id="new-task-desc"
              class="wk-textarea"
              value=${newTaskDesc}
              onInput=${(e: Event) => setNewTaskDesc((e.target as HTMLTextAreaElement).value)}
              onKeyDown=${(e: KeyboardEvent) => {
                if (e.isComposing || e.keyCode === 229) return
                if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && busyAction === null) {
                  e.preventDefault()
                  void handleCreateTask(e)
                }
              }}
            />
          </div>
          <div class="wk-form-grid">
            <div class="wk-field">
              <label for="new-task-pri">우선순위</label>
              <input id="new-task-pri" type="number" min="1" max="5" class="wk-input tnum" value=${newTaskPriority} onInput=${(e: Event) => setNewTaskPriority(Number((e.target as HTMLInputElement).value))} />
            </div>
            <div class="wk-field">
              <label for="new-task-goal">연결 Goal (선택 — 미지정 시 독립 태스크)</label>
              <select id="new-task-goal" class="wk-select" value=${newTaskGoalId} onChange=${(e: Event) => setNewTaskGoalId((e.target as HTMLSelectElement).value)}>
                <option value="">(없음 — 독립 태스크)</option>
                ${planning?.goals.map((g) => html`<option key=${g.id} value=${g.id}>${g.title} (${g.phase})</option>`)}
              </select>
            </div>
          </div>
          <div class="wk-actions">
            <button type="submit" class="btn-primary" disabled=${busyAction !== null}>생성</button>
            <button type="button" class="btn-ghost" onClick=${() => setShowCreateTask(false)}>취소</button>
          </div>
        </form>
      `}

      ${showCreateSchedule && chip === 'schedules' && html`
        <form class="wk-form wk-inset" onSubmit=${handleCreateSchedule}>
          <div class="wk-section-title">예약 자동화 생성 (POST /api/v1/tools/masc_schedule_create)</div>
          <div class="wk-form-grid">
            <div class="wk-field">
              <label for="sched-keeper">대상 Keeper</label>
              <input id="sched-keeper" class="wk-input" required value=${schedKeeper} onInput=${(e: Event) => setSchedKeeper((e.target as HTMLInputElement).value)} placeholder="예: e-masc-the-leader" />
            </div>
            <div class="wk-field">
              <label for="sched-due">최초 실행 지연 (초)</label>
              <input id="sched-due" type="number" min="10" class="wk-input tnum" value=${schedDueInSec} onInput=${(e: Event) => setSchedDueInSec(Number((e.target as HTMLInputElement).value))} />
            </div>
          </div>
          <div class="wk-form-grid">
            <div class="wk-field">
              <label for="sched-repeat">반복 방식</label>
              <select id="sched-repeat" class="wk-select" value=${schedRepeat} onChange=${(e: Event) => setSchedRepeat((e.target as HTMLSelectElement).value as 'one_shot' | 'interval')}>
                <option value="one_shot">1회 실행 (one_shot)</option>
                <option value="interval">주기 반복 (interval)</option>
              </select>
            </div>
            ${schedRepeat === 'interval' && html`
              <div class="wk-field">
                <label for="sched-interval">반복 간격 (초)</label>
                <input id="sched-interval" type="number" min="60" class="wk-input tnum" value=${schedIntervalSec} onInput=${(e: Event) => setSchedIntervalSec(Number((e.target as HTMLInputElement).value))} />
              </div>
            `}
          </div>
          <div class="wk-field">
            <label for="sched-msg">메시지</label>
            <textarea
              id="sched-msg"
              class="wk-textarea"
              required
              value=${schedMessage}
              onInput=${(e: Event) => setSchedMessage((e.target as HTMLTextAreaElement).value)}
              onKeyDown=${(e: KeyboardEvent) => {
                if (e.isComposing || e.keyCode === 229) return
                if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && busyAction === null) {
                  e.preventDefault()
                  void handleCreateSchedule(e)
                }
              }}
            />
          </div>
          <div class="wk-actions">
            <button type="submit" class="btn-primary" disabled=${busyAction !== null}>예약 등록</button>
            <button type="button" class="btn-ghost" onClick=${() => setShowCreateSchedule(false)}>취소</button>
          </div>
        </form>
      `}

      ${isSchedulesView
        ? html`
            ${sourceAlert('예약 목록', scheduleObs)}
            ${schedules?.state === 'unavailable' && html`
              <div class="wk-notice wk-notice--warn wk-inset" role="alert">예약 저장소 조회 불가 · ${schedules.reason}</div>
            `}
            ${schedules?.state === 'available' && html`
              ${schedules.truncated && html`
                <div class="wk-notice wk-notice--warn wk-inset" role="note">
                  예약 목록이 표시 제한으로 일부만 표시됩니다 (${schedules.rows.length} / ${schedules.totalCount}건).
                </div>
              `}
              <${VirtualList}
                items=${schedules.rows}
                estimateSize=${74}
                height="100%"
                ariaLabel="예약 자동화 목록"
                getItemKey=${(s: ScheduleRow) => s.scheduleId}
                empty=${schedulesCurrent
                  ? html`<div class="wk-detail-pad"><span class="dtable-absent">${schedulesActiveOnly ? '활성 예약이 없습니다 (0).' : '기록된 예약 이력이 없습니다 (0).'}</span></div>`
                  : null}
                renderItem=${(s: ScheduleRow) => html`
                  <button
                    type="button"
                    class="wk-row-btn"
                    data-selected=${selectedSchedule?.scheduleId === s.scheduleId ? 'true' : 'false'}
                    onClick=${() => setSelectedScheduleId(s.scheduleId)}
                  >
                    <div class="wk-row-top">
                      <span class="wk-row-title">${s.summary ?? s.scheduleId}</span>
                      <span class="wk-badge wk-badge--info">${s.status}</span>
                    </div>
                    <div class="wk-row-meta">
                      ${s.keeperName && html`<${KeeperBadge} id=${s.keeperName} size="sm" />`}
                      <span>${s.recurrenceSummary || s.recurrenceKind}</span>
                      <span>다음 실행: ${formatRelativeTime(s.nextDueAt ?? s.dueAt)}</span>
                    </div>
                  </button>
                `}
              />
            `}
          `
        : html`
            ${sourceAlert('계획 목록', planningObs)}
            ${sourceAlert('실행 태스크', executionObs)}
            ${execution !== null && execution.omitted > 0 && html`
              <div class="wk-notice wk-inset" role="note">
                종료된 실행 태스크 ${execution.omitted}건이 현재 목록의 표시 범위 밖에 있습니다.
              </div>
            `}
              <${VirtualList}
                items=${filteredTasks}
                estimateSize=${76}
                height="100%"
                ariaLabel="태스크 목록"
                getItemKey=${(t: TaskItem) => t.id}
                empty=${tasksCurrent
                  ? html`<div class="wk-detail-pad"><span class="dtable-absent">${(execution?.omitted ?? 0) > 0
                    ? '표시 범위에 해당하는 태스크가 없습니다.'
                    : '조건에 맞는 태스크가 없습니다.'}</span></div>`
                  : null}
                renderItem=${(t: TaskItem) => html`
                  <button
                    type="button"
                    class="wk-row-btn"
                    data-selected=${selectedTask?.id === t.id ? 'true' : 'false'}
                    onClick=${() => setSelectedTaskId(t.id)}
                  >
                    <div class="wk-row-top">
                      <span class="wk-row-title">${t.title}</span>
                      <span class=${`wk-badge wk-badge--${taskStatusTone(t.status)}`}>${t.status}</span>
                    </div>
                    <div class="wk-row-meta">
                      <span class="mono">${t.id}</span>
                      <span class="mono">P${t.priority}</span>
                      ${t.assignee ? html`<${KeeperBadge} id=${t.assignee} size="sm" />` : html`<span>미배정</span>`}
                      ${t.goalId ? html`<span class="mono">Goal: ${t.goalId}</span>` : html`<span class="wk-badge wk-badge--idle">Unlinked</span>`}
                    </div>
                  </button>
                `}
              />
            `}
    </div>
  `

  const detailPane = chip === 'schedules'
    ? selectedSchedule
      ? html`
          <div class="wk-detail-pad">
            ${feedback && html`<div class=${`wk-notice wk-notice--${feedback.kind}`} role="status">${feedback.message}</div>`}
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <div class="mono wk-sub-id">${selectedSchedule.scheduleId}</div>
                <h2 class="wk-heading">${selectedSchedule.summary ?? '예약 자동화'}</h2>
              </div>
              <span class="wk-badge wk-badge--info">${selectedSchedule.status}</span>
            </div>
            <div class="wk-kv-grid">
              <div class="wk-kv">
                <span class="wk-kv-k">대상 Keeper</span>
                <span class="wk-kv-v">${selectedSchedule.keeperName ? html`<${KeeperBadge} id=${selectedSchedule.keeperName} size="sm" />` : '없음'}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">반복 주기</span>
                <span class="wk-kv-v">${selectedSchedule.recurrenceSummary || selectedSchedule.recurrenceKind}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">예정 시각</span>
                <span class="wk-kv-v tnum">${selectedSchedule.nextDueAt ?? selectedSchedule.dueAt ?? '없음'}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">최근 실행 결과</span>
                <span class="wk-kv-v">${selectedSchedule.lastWakeStatus ?? '실행 이력 없음'}</span>
              </div>
            </div>
            ${selectedSchedule.message && html`<${MarkdownContent} class="wk-prose" text=${selectedSchedule.message} />`}
            ${selectedSchedule.lastWakeError && html`
              <div class="wk-notice wk-notice--err">최근 실패 사유: ${selectedSchedule.lastWakeError}</div>
            `}
            <div class="wk-actions">
              <button
                type="button"
                class="wk-btn-danger"
                disabled=${busyAction !== null}
                onClick=${() => void handleCancelSchedule(selectedSchedule.scheduleId)}
              >
                예약 취소
              </button>
            </div>
          </div>
        `
      : null
    : selectedTask
      ? (() => {
          const linkCheck = checkTaskGoalLinkable(selectedTask)
          return html`
            <div class="wk-detail-pad">
              ${feedback && html`<div class=${`wk-notice wk-notice--${feedback.kind}`} role="status">${feedback.message}</div>`}
              <div class="wk-section-head">
                <div class="wk-min-w-0">
                  <div class="mono wk-sub-id">${selectedTask.id}</div>
                  <h2 class="wk-heading">${selectedTask.title}</h2>
                </div>
                <span class=${`wk-badge wk-badge--${taskStatusTone(selectedTask.status)}`}>${selectedTask.status}</span>
              </div>

              <div class="wk-kv-grid">
                <div class="wk-kv">
                  <span class="wk-kv-k">담당자</span>
                  <span class="wk-kv-v">${selectedTask.assignee ? html`<${KeeperBadge} id=${selectedTask.assignee} size="sm" />` : '없음'}</span>
                </div>
                <div class="wk-kv">
                  <span class="wk-kv-k">연결 Goal</span>
                  <span class="wk-kv-v">
                    ${selectedTask.goalId
                      ? html`
                          <button
                            type="button"
                            class="btn-ghost wk-btn-compact"
                            onClick=${() => props.onNavigate(`/work/goals/${encodeURIComponent(selectedTask.goalId!)}`)}
                          >
                            ${selectedTask.goalId} →
                          </button>
                        `
                      : '없음 (독립 태스크)'}
                  </span>
                </div>
                <div class="wk-kv">
                  <span class="wk-kv-k">우선순위</span>
                  <span class="wk-kv-v tnum">P${selectedTask.priority}</span>
                </div>
                <div class="wk-kv">
                  <span class="wk-kv-k">검증 ID</span>
                  <span class="wk-kv-v mono">${selectedTask.verificationId ?? '없음'}</span>
                </div>
              </div>

              ${selectedTask.description && html`
                <section class="wk-section">
                  <h3 class="wk-section-title">설명</h3>
                  <${MarkdownContent} class="wk-prose" text=${selectedTask.description} />
                </section>
              `}

              ${selectedTask.handoff.kind === 'unreadable' && html`
                <div class="wk-notice wk-notice--warn" role="note">이 태스크에 남은 인계 메모를 읽을 수 없습니다. 원본 검사에서 값을 확인하세요.</div>
              `}
              ${selectedTask.handoff.kind === 'readable' && html`
                <section class="wk-section" aria-label="인계 메모">
                  <h3 class="wk-section-title">인계 메모 (handoff)</h3>
                  <div class="wk-kv-grid">
                    <div class="wk-kv">
                      <span class="wk-kv-k">넘긴 이유</span>
                      <span class="wk-kv-v">${selectedTask.handoff.context.reason ?? '없음'}</span>
                    </div>
                    <div class="wk-kv">
                      <span class="wk-kv-k">다음 단계</span>
                      <span class="wk-kv-v">${selectedTask.handoff.context.next_step ?? '없음'}</span>
                    </div>
                    <div class="wk-kv">
                      <span class="wk-kv-k">실패 유형</span>
                      <span class="wk-kv-v">${selectedTask.handoff.context.failure_mode ?? '없음'}</span>
                    </div>
                    <div class="wk-kv">
                      <span class="wk-kv-k">남긴 이 / 시각</span>
                      <span class="wk-kv-v">${selectedTask.handoff.context.updated_by ?? '없음'} · ${formatRelativeTime(selectedTask.handoff.context.updated_at)}</span>
                    </div>
                  </div>
                  ${selectedTask.handoff.context.summary && html`<${MarkdownContent} class="wk-prose" text=${selectedTask.handoff.context.summary} />`}
                  ${(selectedTask.handoff.context.evidence_refs?.length ?? 0) > 0 && html`
                    <ul class="wk-prose">
                      ${selectedTask.handoff.context.evidence_refs?.map((ref) => html`<li key=${ref} class="mono">${ref}</li>`)}
                    </ul>
                  `}
                </section>
              `}

              <section class="wk-section" aria-label="태스크 작업 제어">
                <h3 class="wk-section-title">Lifecycle Actions</h3>
                <div class="wk-actions">
                  ${selectedTask.status === 'Todo' && html`
                    <button type="button" class="btn-primary" disabled=${busyAction !== null} onClick=${() => void handleTaskTransition(selectedTask, 'claim')}>
                      Claim (담당 잡기)
                    </button>
                  `}
                  ${selectedTask.status === 'Claimed' && html`
                    <button type="button" class="btn-primary" disabled=${busyAction !== null} onClick=${() => void handleTaskTransition(selectedTask, 'start')}>
                      Start (진행 시작)
                    </button>
                    <button type="button" class="btn-ghost" disabled=${busyAction !== null} onClick=${() => void handleTaskTransition(selectedTask, 'release')}>
                      Release (담당 해제)
                    </button>
                  `}
                  ${selectedTask.status === 'InProgress' && html`
                    <button type="button" class="btn-ghost" disabled=${busyAction !== null} onClick=${() => void handleTaskTransition(selectedTask, 'release')}>
                      Release
                    </button>
                  `}
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => props.onInspect({
                      title: `Task: ${selectedTask.title}`,
                      subtitle: `${selectedTask.id} · ${selectedTask.status}`,
                      kind: 'task',
                      data: selectedTask,
                    })}
                  >
                    원본 검사
                  </button>
                </div>

                ${selectedTask.status !== 'Done' && selectedTask.status !== 'Cancelled' && html`
                  <div class="wk-row-wrap wk-mt-2">
                    <input
                      type="text"
                      class="wk-input wk-flex-input"
                      placeholder="취소 사유 (선택)"
                      value=${cancelReason}
                      onInput=${(e: Event) => setCancelReason((e.target as HTMLInputElement).value)}
                      aria-label="태스크 취소 사유"
                    />
                    <button type="button" class="wk-btn-warn" disabled=${busyAction !== null} onClick=${() => void handleCancelTask(selectedTask)}>
                      Cancel Task
                    </button>
                    <button type="button" class="wk-btn-danger" disabled=${busyAction !== null} onClick=${() => void handleDeleteTask(selectedTask)}>
                      Delete Task
                    </button>
                  </div>
                `}
                ${(selectedTask.status === 'Done' || selectedTask.status === 'Cancelled') && html`
                  <div class="wk-actions wk-mt-1">
                    <button type="button" class="wk-btn-danger" disabled=${busyAction !== null} onClick=${() => void handleDeleteTask(selectedTask)}>
                      Delete Task
                    </button>
                  </div>
                `}
              </section>

              ${isSingleUser && html`
                <section class="wk-section" aria-label="태스크 검증 판정">
                  <div class="wk-section-head">
                    <h3 class="wk-section-title">
                      Verification Verdicts <span class="wk-chip-count">(${visibleVerificationRead?.kind === 'ready' && verificationCoverageNotices.length === 0 ? taskVerifications.length : '—'})</span>
                    </h3>
                    <div class="wk-pane-status-slot">
                      ${(!visibleVerificationRead || visibleVerificationRead.kind === 'loading') && html`
                        <span
                          class="wk-status-pill wk-status-pill--info"
                          role="status"
                          title=${visibleVerificationReport ? '검증 이력 갱신 중 · 마지막 조회 표시' : '검증 이력을 불러오는 중…'}
                        >
                          <${InlineSpinner} size="xs" />
                          <span class="wk-status-pill-text">
                            ${visibleVerificationReport ? '갱신 중 · 마지막 조회' : '검증 이력 불러오는 중…'}
                          </span>
                        </span>
                      `}
                    </div>
                  </div>
                  ${visibleVerificationRead?.kind === 'failed' && html`
                    <div class="wk-notice wk-notice--err" role="alert">검증 이력 조회 실패 · ${visibleVerificationRead.message}${visibleVerificationReport ? ' · 마지막 조회 표시' : ''}</div>
                  `}
                  ${verificationCoverageNotices.length > 0 && html`
                    <div class="wk-notice" role="status">${verificationCoverageNotices.join(' · ')}</div>
                  `}
                  ${visibleVerificationRead?.kind === 'ready' && verificationCoverageNotices.length === 0
                    && taskVerifications.length === 0 && html`<p class="wk-muted-sm">표시할 검증 이력이 없습니다.</p>`}
                  <div class="wk-stack-1">
                    ${taskVerifications.map((vr) => html`
                      <div key=${vr.requestId} class="wk-kv">
                        <div class="wk-row-top">
                          <span class="mono wk-sub-id" title=${vr.requestId}>${vr.requestId}</span>
                          <span class=${`wk-badge wk-badge--${reviewStateTone(vr.reviewState)}`}>
                            ${vr.reviewState ?? 'unobserved'}
                          </span>
                        </div>
                        <div class="wk-muted-sm">
                          제출: ${vr.submittedBy}${vr.createdAt ? ` · ${formatRelativeTime(vr.createdAt)}` : ''}
                        </div>
                        ${vr.reviewDetail && html`<div class="wk-body-pre">${vr.reviewDetail}</div>`}
                      </div>
                    `)}
                  </div>
                </section>
              `}

              <section class="wk-section" aria-label="Goal 연결">
                <h3 class="wk-section-title">Goal 연결 (set_task_goal — goalless 태스크 전용)</h3>
                ${linkCheck.ok
                  ? html`
                      <div class="wk-row-wrap">
                        <select
                          class="wk-select wk-flex-input"
                          value=${linkGoalId}
                          onChange=${(e: Event) => setLinkGoalId((e.target as HTMLSelectElement).value)}
                          aria-label="연결할 Goal 선택"
                        >
                          <option value="">Goal 선택…</option>
                          ${planning?.goals.map((g) => html`<option key=${g.id} value=${g.id}>${g.title} (${g.phase})</option>`)}
                        </select>
                        <button
                          type="button"
                          class="btn-primary"
                          disabled=${busyAction !== null || !linkGoalId}
                          onClick=${() => void handleLinkGoal(selectedTask)}
                        >
                          Goal 연결
                        </button>
                      </div>
                    `
                  : html`
                      <div class="wk-notice">
                        ${linkCheck.error === 'Already_assigned'
                          ? `이미 Goal(${selectedTask.goalId})에 연결되어 있습니다. constitution.xml 규약상 재할당/해제는 허용되지 않습니다 (Already_assigned).`
                          : '종료된 태스크(Done/Cancelled)에는 Goal을 연결할 수 없습니다.'}
                      </div>
                    `}
              </section>

              <details
                class="ap-disclosure"
                data-testid="task-history-disclosure"
                aria-label="태스크 이력 타임라인"
                open=${(historyCurrent && Boolean(historyError)) || undefined}
              >
                <summary class="ap-disclosure-trigger">
                  <span>
                    이력 ${historyCurrent && !historyLoading ? `${historyEvents.length}건` : '…'} · Task History Timeline
                  </span>
                  <span aria-hidden="true">▸</span>
                </summary>
                <div class="ap-disclosure-body">
                  <div class="wk-section-head">
                    <span class="wk-muted-sm">Cursor Paginated raw timeline</span>
                    <button
                      type="button"
                      class="btn-ghost"
                      onClick=${() => void loadHistoryPage(selectedTask.id, null, false)}
                    >
                      처음부터 다시 읽기
                    </button>
                  </div>
                  ${historyCurrent && historySourceChanged && html`
                    <div class="wk-notice wk-notice--warn" role="alert">
                      ${historyError}
                    </div>
                  `}
                  ${historyCurrent && !historySourceChanged && historyError && html`
                    <div class="wk-notice wk-notice--err" role="alert">${historyError}</div>
                  `}
                  ${!historyCurrent || (historyLoading && historyEvents.length === 0)
                    ? html`<span class="dtable-absent" role="status"><${InlineSpinner} /> 이력 불러오는 중…</span>`
                    : historyEvents.length === 0
                      ? historyError ? null : html`<span class="dtable-absent">기록된 이력이 없습니다.</span>`
                      : html`
                          <ol class="wk-timeline">
                            ${historyEvents.map((ev, idx) => html`
                              <li key=${`${ev.source}-${ev.offset}-${idx}`} class="wk-timeline-item">
                                <div class="wk-row-top">
                                  <span class="mono wk-sub-id">
                                    ${ev.source} · offset ${ev.offset}
                                  </span>
                                </div>
                                <pre class="wk-code-preview">${typeof ev.event === 'string' ? ev.event : JSON.stringify(ev.event, null, 2)}</pre>
                              </li>
                            `)}
                          </ol>
                          ${historyNextCursor && html`
                            <button
                              type="button"
                              class="btn-ghost"
                              disabled=${historyLoading}
                              onClick=${() => void loadHistoryPage(selectedTask.id, historyNextCursor, true)}
                            >
                              ${historyLoading ? '불러오는 중…' : '이전 이력 더 불러오기'}
                            </button>
                          `}
                        `}
                </div>
              </details>
            </div>
          `
        })()
      : null

  return html`
    <${MasterDetail}
      master=${masterPane}
      detail=${detailPane}
      hasSelection=${chip === 'schedules' ? selectedSchedule !== null : selectedTask !== null}
      selectionKey=${chip === 'schedules' ? `sched:${selectedScheduleId ?? ''}` : `task:${selectedTaskId ?? ''}`}
      masterLabel=${chip === 'schedules' ? '예약 목록' : '태스크 목록'}
      detailLabel=${chip === 'schedules' ? '예약 상세' : '태스크 상세'}
      emptyDetail=${html`<div class="wk-detail-pad"><span class="dtable-absent">항목을 선택하세요.</span></div>`}
    />
  `
}
