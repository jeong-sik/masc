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
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { markViewSynced } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { apiGet, apiMutate } from '../../core/transport'
import { ok } from '../../lib/result'
import { KeeperBadge } from '../../components/keeper-badge'
import { MasterDetail, VirtualList } from '../../components/primitives'
import {
  asNonEmptyString,
  asSafeInt,
  asString,
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
  type WorkspaceViewProps,
} from './types'

interface TasksBundle {
  readonly tasks: readonly TaskItem[]
  readonly goals: readonly GoalItem[]
  readonly schedules: ScheduleProjection
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
  const rawReqs = Array.isArray(raw.requests) ? raw.requests : []
  const rows: ScheduleRow[] = []
  for (const r of rawReqs) {
    if (!isRecord(r)) continue
    const scheduleId = asNonEmptyString(r.schedule_id)
    if (!scheduleId) continue
    const lastWake = isRecord(r.last_wake) ? r.last_wake : null
    rows.push({
      scheduleId,
      scheduleInstanceId: asString(r.schedule_instance_id, scheduleId),
      status: asString(r.status, 'scheduled'),
      source: asString(r.source, 'operator'),
      dueAt: asNonEmptyString(r.due_at),
      nextDueAt: asNonEmptyString(r.next_due_at),
      recurrenceKind: asString(r.recurrence_kind, 'one_shot'),
      recurrenceSummary: asString(r.recurrence_summary, ''),
      keeperName: asNonEmptyString(r.payload_keeper_name) ?? asNonEmptyString(r.payload_target),
      summary: asNonEmptyString(r.payload_summary),
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
  const [bundle, setBundle] = useState<TasksBundle>({
    tasks: [],
    goals: [],
    schedules: { state: 'available', rows: [], totalCount: 0, truncated: false },
  })
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [chip, setChip] = useState<TaskFilterChip>('all')
  const [query, setQuery] = useState('')
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(props.entityId ?? null)
  const [selectedScheduleId, setSelectedScheduleId] = useState<string | null>(null)

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

  // Cursor-paginated Task History Timeline (`#36`) with AbortController race guard
  const [historyEvents, setHistoryEvents] = useState<TaskHistoryPageData['events']>([])
  const [historyNextCursor, setHistoryNextCursor] = useState<string | null>(null)
  const [historyLoading, setHistoryLoading] = useState(false)
  const [historyError, setHistoryError] = useState<string | null>(null)
  const [historySourceChanged, setHistorySourceChanged] = useState(false)
  const historyAbortRef = useRef<AbortController | null>(null)

  const loadTasksAndSchedules = useCallback(async (reason: 'mount' | 'manual' = 'mount') => {
    setLoading(true)
    setLoadError(null)
    const obs = await resourceCache.fetch<TasksBundle>(
      'work:tasks:bundle',
      async (signal) => {
        const [planRes, execRes, schedRes] = await Promise.all([
          apiGet<unknown>('/api/v1/dashboard/planning', { signal }),
          apiGet<unknown>('/api/v1/dashboard/execution?light=true', { signal }),
          apiGet<unknown>('/api/v1/dashboard/scheduled-automation?active_only=true', { signal }),
        ])
        if (!planRes.ok && !execRes.ok) return planRes

        const taskMap = new Map<string, TaskItem>()
        const collectTasks = (rawArr: unknown) => {
          if (!Array.isArray(rawArr)) return
          for (const item of rawArr) {
            const decoded = decodeTaskItem(item)
            if (decoded) taskMap.set(decoded.id, decoded)
          }
        }

        const goals: GoalItem[] = []
        if (planRes.ok && isRecord(planRes.value)) {
          collectTasks(planRes.value.tasks)
          if (Array.isArray(planRes.value.goals)) {
            for (const g of planRes.value.goals) {
              const dec = decodeGoalItem(g)
              if (dec.ok) goals.push(dec.value)
            }
          }
        }
        if (execRes.ok && isRecord(execRes.value)) {
          collectTasks(execRes.value.tasks)
        }

        const schedules = schedRes.ok
          ? decodeSchedulesResponse(schedRes.value)
          : { state: 'unavailable' as const, reason: schedRes.error.message }

        return ok({ tasks: [...taskMap.values()], goals, schedules })
      },
      { ttlMs: 10_000, topics: ['tasks', 'task_updated', 'planning', 'schedules'], reason },
    )
    setLoading(false)
    if (obs.kind === 'value') {
      setBundle(obs.data)
      markViewSynced()
      setSelectedTaskId((prev) => {
        if (props.entityId && obs.data.tasks.some((t) => t.id === props.entityId)) return props.entityId
        if (prev && obs.data.tasks.some((t) => t.id === prev)) return prev
        return obs.data.tasks[0]?.id ?? null
      })
      if (obs.data.schedules.state === 'available') {
        const firstSchedId = obs.data.schedules.rows[0]?.scheduleId ?? null
        setSelectedScheduleId((prev) => prev ?? firstSchedId)
      }
    } else if (obs.kind === 'failed') {
      setLoadError(obs.error.message)
    }
  }, [props.entityId])

  useEffect(() => {
    void loadTasksAndSchedules('mount')
  }, [loadTasksAndSchedules])

  const counts = useMemo(() => computeTaskFilterCounts(bundle.tasks), [bundle.tasks])

  const filteredTasks = useMemo(() => {
    const base = filterTasksByChip(bundle.tasks, chip)
    const q = query.trim().toLowerCase()
    if (!q) return base
    return base.filter((t) =>
      t.title.toLowerCase().includes(q)
      || t.id.toLowerCase().includes(q)
      || (t.assignee?.toLowerCase().includes(q) ?? false)
      || (t.goalId?.toLowerCase().includes(q) ?? false),
    )
  }, [bundle.tasks, chip, query])

  const selectedTask = useMemo(
    () => bundle.tasks.find((t) => t.id === selectedTaskId) ?? null,
    [bundle.tasks, selectedTaskId],
  )

  const selectedSchedule = useMemo(() => {
    if (bundle.schedules.state !== 'available') return null
    return bundle.schedules.rows.find((s) => s.scheduleId === selectedScheduleId) ?? null
  }, [bundle.schedules, selectedScheduleId])

  const loadHistoryPage = useCallback(async (
    taskId: string,
    cursor: string | null,
    append: boolean,
    externalSignal?: AbortSignal,
  ) => {
    historyAbortRef.current?.abort()
    const controller = new AbortController()
    historyAbortRef.current = controller
    const signal = externalSignal ?? controller.signal

    setHistoryLoading(true)
    setHistoryError(null)
    setHistorySourceChanged(false)
    const params = new URLSearchParams({
      task_id: taskId,
      limit: '20',
    })
    if (cursor) params.set('cursor', cursor)
    const res = await apiGet<TaskHistoryPageData>(`/api/v1/dashboard/tasks/history/page?${params.toString()}`, { signal })
    if (signal.aborted) return
    setHistoryLoading(false)
    if (!res.ok) {
      if (res.error.kind === 'conflict_cas' || res.error.status === 409 || res.error.code === 'task_history_source_changed') {
        setHistorySourceChanged(true)
        setHistoryError('이력 원장이 변경되어 현재 커서가 만료되었습니다 (409 task_history_source_changed). 처음부터 다시 불러오세요.')
        return
      }
      setHistoryError(res.error.message)
      return
    }
    const pageEvents = Array.isArray(res.value.events) ? res.value.events : []
    setHistoryEvents((prev) => (append ? [...prev, ...pageEvents] : pageEvents))
    setHistoryNextCursor(res.value.next_cursor ?? null)
  }, [])

  useEffect(() => {
    if (chip !== 'schedules' && selectedTask) {
      const controller = new AbortController()
      setHistoryEvents([])
      setHistoryNextCursor(null)
      void loadHistoryPage(selectedTask.id, null, false, controller.signal)
      return () => {
        controller.abort()
      }
    }
    historyAbortRef.current?.abort()
    return undefined
  }, [chip, selectedTask?.id, loadHistoryPage])

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
    await loadTasksAndSchedules('manual')
  }

  const handleTaskTransition = async (task: TaskItem, action: 'claim' | 'start' | 'release') => {
    setBusyAction(action)
    setFeedback(null)
    const res = await callMcpToolViaCore('masc_transition', { task_id: task.id, action })
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `전환 실패 (${action}): ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `${task.id} → ${action} 적용됨` })
    resourceCache.invalidateTopic('tasks')
    await loadTasksAndSchedules('manual')
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
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `Goal 연결 실패: ${res.error.message}` })
      return
    }
    setLinkGoalId('')
    setFeedback({ kind: 'ok', message: `${task.id} → Goal ${targetGoalId} 연결 완료` })
    resourceCache.invalidateTopic('tasks')
    await loadTasksAndSchedules('manual')
  }

  const handleCancelTask = async (task: TaskItem) => {
    setBusyAction('cancel')
    setFeedback(null)
    const wsRes = await readWorkspacePrecondition()
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
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `태스크 취소 실패: ${res.error.message}` })
      return
    }
    setCancelReason('')
    setFeedback({ kind: 'ok', message: `태스크 ${task.id} 취소 완료` })
    resourceCache.invalidateTopic('tasks')
    await loadTasksAndSchedules('manual')
  }

  const handleDeleteTask = async (task: TaskItem) => {
    setBusyAction('delete')
    setFeedback(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/dashboard/tasks/delete', { task_id: task.id })
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `태스크 삭제 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `태스크 ${task.id} 삭제 완료` })
    resourceCache.invalidateTopic('tasks')
    await loadTasksAndSchedules('manual')
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
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `예약 생성 실패: ${res.error.message}` })
      return
    }
    setSchedMessage('')
    setShowCreateSchedule(false)
    setFeedback({ kind: 'ok', message: `${schedKeeper.trim()} 예약 자동화 등록 완료` })
    resourceCache.invalidateTopic('schedules')
    await loadTasksAndSchedules('manual')
  }

  const handleCancelSchedule = async (scheduleId: string) => {
    setBusyAction(`cancel-sched:${scheduleId}`)
    setFeedback(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/tools/masc_schedule_cancel', {
      schedule_id: scheduleId,
      reason: 'operator cancelled from dashboard',
    })
    setBusyAction(null)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `예약 취소 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `예약 ${scheduleId} 취소됨` })
    resourceCache.invalidateTopic('schedules')
    await loadTasksAndSchedules('manual')
  }

  const scheduleCountLabel = bundle.schedules.state === 'available'
    ? String(bundle.schedules.totalCount)
    : '없음'

  const chipItems: readonly { id: TaskFilterChip; label: string; count: string }[] = [
    { id: 'all', label: 'All', count: String(counts.all) },
    { id: 'active', label: 'Active', count: String(counts.active) },
    { id: 'awaiting_verify', label: 'AwaitingVerify', count: String(counts.awaiting_verify) },
    { id: 'todo', label: 'Todo', count: String(counts.todo) },
    { id: 'unlinked', label: 'Unlinked', count: String(counts.unlinked) },
    { id: 'done', label: 'Done', count: String(counts.done + counts.cancelled) },
    { id: 'schedules', label: 'Schedules', count: scheduleCountLabel },
  ]

  const masterPane = html`
    <div class="wk-pane-col">
      <div class="wk-pane-head">
        <h2 class="wk-pane-title">
          ${chip === 'schedules' ? 'Scheduled Automation' : 'Tasks'}
        </h2>
        <div class="wk-actions">
          ${chip === 'schedules'
            ? html`<button type="button" class="btn-primary" onClick=${() => setShowCreateSchedule((v) => !v)}>${showCreateSchedule ? '닫기' : '+ 새 예약'}</button>`
            : html`<button type="button" class="btn-primary" onClick=${() => setShowCreateTask((v) => !v)}>${showCreateTask ? '닫기' : '+ 새 태스크'}</button>`}
          <button type="button" class="btn-ghost" onClick=${() => void loadTasksAndSchedules('manual')}>새로고침</button>
        </div>
      </div>

      <div class="wk-filter-bar">
        <div class="wk-chips" role="group" aria-label="태스크 상태 필터">
          ${chipItems.map((c) => html`
            <button
              key=${c.id}
              type="button"
              class="wk-chip"
              aria-pressed=${chip === c.id}
              onClick=${() => setChip(c.id)}
            >
              ${c.label} <span class="wk-chip-count">${c.count}</span>
            </button>
          `)}
        </div>
        ${chip !== 'schedules' && html`
          <input
            type="search"
            class="wk-input"
            placeholder="태스크 제목, ID, 담당 Keeper, Goal ID 검색…"
            value=${query}
            onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
            aria-label="태스크 검색"
          />
        `}
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
            <textarea id="new-task-desc" class="wk-textarea" value=${newTaskDesc} onInput=${(e: Event) => setNewTaskDesc((e.target as HTMLTextAreaElement).value)} />
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
                ${bundle.goals.map((g) => html`<option key=${g.id} value=${g.id}>${g.title} (${g.phase})</option>`)}
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
            <textarea id="sched-msg" class="wk-textarea" required value=${schedMessage} onInput=${(e: Event) => setSchedMessage((e.target as HTMLTextAreaElement).value)} />
          </div>
          <div class="wk-actions">
            <button type="submit" class="btn-primary" disabled=${busyAction !== null}>예약 등록</button>
            <button type="button" class="btn-ghost" onClick=${() => setShowCreateSchedule(false)}>취소</button>
          </div>
        </form>
      `}

      ${loadError && html`<div class="wk-notice wk-notice--err wk-inset" role="alert">${loadError}</div>`}

      ${chip === 'schedules'
        ? bundle.schedules.state === 'unavailable'
          ? html`<div class="wk-detail-pad"><div class="wk-notice wk-notice--warn">예약 저장소 조회 불가: ${bundle.schedules.reason}</div></div>`
          : html`
              <${VirtualList}
                items=${bundle.schedules.rows}
                estimateSize=${74}
                height="100%"
                ariaLabel="예약 자동화 목록"
                getItemKey=${(s: ScheduleRow) => s.scheduleId}
                empty=${html`<div class="wk-detail-pad"><span class="dtable-absent">활성 예약이 없습니다 (0).</span></div>`}
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
            `
        : loading && bundle.tasks.length === 0
          ? html`<div class="wk-detail-pad"><span class="dtable-absent">태스크 목록 불러오는 중…</span></div>`
          : html`
              <${VirtualList}
                items=${filteredTasks}
                estimateSize=${76}
                height="100%"
                ariaLabel="태스크 목록"
                getItemKey=${(t: TaskItem) => t.id}
                empty=${html`<div class="wk-detail-pad"><span class="dtable-absent">조건에 맞는 태스크가 없습니다.</span></div>`}
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
                  <div class="wk-body-pre">${selectedTask.description}</div>
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
                          ${bundle.goals.map((g) => html`<option key=${g.id} value=${g.id}>${g.title} (${g.phase})</option>`)}
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

              <section class="wk-section" aria-label="태스크 이력 타임라인">
                <div class="wk-section-head">
                  <h3 class="wk-section-title">Task History Timeline (Cursor Paginated)</h3>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => void loadHistoryPage(selectedTask.id, null, false)}
                  >
                    처음부터 다시 읽기
                  </button>
                </div>
                ${historySourceChanged && html`
                  <div class="wk-notice wk-notice--warn" role="alert">
                    ${historyError}
                  </div>
                `}
                ${!historySourceChanged && historyError && html`
                  <div class="wk-notice wk-notice--err" role="alert">${historyError}</div>
                `}
                ${historyLoading && historyEvents.length === 0
                  ? html`<span class="dtable-absent">이력 불러오는 중…</span>`
                  : historyEvents.length === 0
                    ? html`<span class="dtable-absent">기록된 이력이 없습니다.</span>`
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
              </section>
            </div>
          `
        })()
      : null

  return html`
    <${MasterDetail}
      master=${masterPane}
      detail=${detailPane}
      hasSelection=${chip === 'schedules' ? selectedSchedule !== null : selectedTask !== null}
      masterLabel=${chip === 'schedules' ? '예약 목록' : '태스크 목록'}
      detailLabel=${chip === 'schedules' ? '예약 상세' : '태스크 상세'}
      emptyDetail=${html`<div class="wk-detail-pad"><span class="dtable-absent">항목을 선택하세요.</span></div>`}
    />
  `
}
