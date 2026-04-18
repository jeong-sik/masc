// Task detail overlay state — signals, fetch, normalization

import { signal } from '@preact/signals'
import { fetchTaskEvents } from '../../api/actions'
import { extractApiError } from '../../api/core'
import { fetchAgentTimeline, fetchKeeperTrajectory } from '../../api/dashboard'
import { buildTraceEvents, type UnifiedTraceEvent } from '../session-trace/session-trace-state'
import { findKeeper } from '../../lib/keeper-utils'
import { goalById } from './goal-helpers'
import type { Goal, Task } from '../../types'

// -- Activity filter (owned here, consumed by task-activity-list) ---

export type ActivityFilter = 'all' | 'tool_call' | 'broadcast' | 'task'
export const activeFilter = signal<ActivityFilter>('all')
export const activityListSearchQuery = signal<string>('')

// -- Normalized task event (from masc_task_history raw JSON) --------

export interface NormalizedTaskEvent {
  label: string
  agent: string | null
  actorKind: string | null
  taskId: string | null
  ts: string | null
  notes: string | null
}

interface TaskHistoryRow {
  type?: string
  agent?: string
  actor_kind?: string
  task?: string
  task_id?: string
  action?: string
  ts?: string
  ts_iso?: string
  notes?: string
  reason?: string
  handoff_context?: {
    summary?: string
  } | null
}

function normalizeTaskHistory(raw: TaskHistoryRow[]): NormalizedTaskEvent[] {
  return raw.map(r => ({
    label: r.action ?? (r.type ? r.type.replace('task_', '') : 'unknown'),
    agent: r.agent ?? null,
    actorKind: r.actor_kind ?? null,
    taskId: r.task ?? r.task_id ?? null,
    ts: r.ts ?? r.ts_iso ?? null,
    notes: r.notes ?? r.handoff_context?.summary ?? r.reason ?? null,
  }))
}

export function describeTaskEventsError(err: unknown): string {
  const api = extractApiError(err, '태스크 이벤트를 불러오지 못했습니다')
  if (api.timeout) {
    return '태스크 이벤트 요청이 시간 초과되었습니다. 다시 시도해 주세요'
  }
  if (api.status === 403) {
    return '태스크 이벤트를 읽을 권한이 없습니다'
  }
  if (api.status === 404) {
    return '태스크 이벤트 경로를 찾지 못했습니다'
  }
  if (api.message && api.message !== '태스크 이벤트를 불러오지 못했습니다') {
    return `태스크 이벤트를 불러오지 못했습니다: ${api.message}`
  }
  return '태스크 이벤트를 불러오지 못했습니다'
}

/**
 * Pure filter for task event rows.
 *
 * - `query` is case-insensitive substring match across `label`, `agent`,
 *   `actorKind`, and `notes` (trimmed).
 * - Empty/whitespace-only query returns the input reference unchanged
 *   (zero-allocation fast path).
 * - Does not mutate the input array.
 */
export function filterTaskEvents(
  rows: readonly NormalizedTaskEvent[],
  query: string,
): readonly NormalizedTaskEvent[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return rows
  return rows.filter(e => {
    if (e.label.toLowerCase().includes(needle)) return true
    if (e.agent && e.agent.toLowerCase().includes(needle)) return true
    if (e.actorKind && e.actorKind.toLowerCase().includes(needle)) return true
    if (e.notes && e.notes.toLowerCase().includes(needle)) return true
    return false
  })
}

/**
 * Pure filter for goal relation rows (the assignee keeper's active goals).
 *
 * - `query` is case-insensitive substring match across the goal's `id`,
 *   resolved `title`, `status`, and `metric` (trimmed). Unresolved goal
 *   ids still match on the raw id so operators can search by identifier
 *   even when the goal store has not loaded that entry yet.
 * - Empty/whitespace-only query returns the input reference unchanged
 *   (zero-allocation fast path, preserves identity for memoisation).
 * - `resolve` defaults to `goalById` so the filter stays pure in tests
 *   when the caller provides an injected lookup.
 * - Does not mutate the input array.
 */
export function filterGoalRelations(
  ids: readonly string[],
  query: string,
  resolve: (id: string) => Goal | undefined = goalById,
): readonly string[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return ids
  return ids.filter(id => {
    if (id.toLowerCase().includes(needle)) return true
    const goal = resolve(id)
    if (!goal) return false
    if (goal.title.toLowerCase().includes(needle)) return true
    if (goal.status.toLowerCase().includes(needle)) return true
    if (goal.metric && goal.metric.toLowerCase().includes(needle)) return true
    return false
  })
}

// -- Overlay signals ------------------------------------------------

export const selectedTask = signal<Task | null>(null)
export const taskEvents = signal<NormalizedTaskEvent[]>([])
export const taskEventsLoading = signal(false)
export const taskEventsError = signal<string | null>(null)
export const taskEventsSearchQuery = signal('')
export const goalRelationSearchQuery = signal('')

export type TaskDetailTab = 'overview' | 'activity'
export const activeTab = signal<TaskDetailTab>('overview')

export const activityEvents = signal<UnifiedTraceEvent[]>([])
export const activityLoading = signal(false)
export const activityError = signal<string | null>(null)

const eventsFetchToken = signal(0)
const activityFetchToken = signal(0)

// -- State lifecycle ------------------------------------------------

function resetState(): void {
  taskEvents.value = []
  taskEventsLoading.value = false
  taskEventsError.value = null
  taskEventsSearchQuery.value = ''
  goalRelationSearchQuery.value = ''
  activityEvents.value = []
  activityLoading.value = false
  activityError.value = null
  activeTab.value = 'overview'
  activeFilter.value = 'all'
  activityListSearchQuery.value = ''
}

export function openTaskDetail(task: Task): void {
  resetState()
  selectedTask.value = task
  void loadTaskEvents(task.id)
}

export function closeTaskDetail(): void {
  selectedTask.value = null
  eventsFetchToken.value++
  activityFetchToken.value++
  resetState()
}

export function switchToActivityTab(task: Task): void {
  activeTab.value = 'activity'
  if (task.assignee && activityEvents.value.length === 0 && !activityLoading.value) {
    void loadActivity(task)
  }
}

// -- Fetch with stale guard -----------------------------------------

async function loadTaskEvents(taskId: string): Promise<void> {
  const token = ++eventsFetchToken.value
  taskEventsLoading.value = true
  taskEventsError.value = null
  try {
    const raw = await fetchTaskEvents(taskId, 50)
    if (eventsFetchToken.value !== token) return
    const arr = Array.isArray(raw) ? raw : []
    taskEvents.value = normalizeTaskHistory(arr as TaskHistoryRow[])
  } catch (err) {
    if (eventsFetchToken.value === token) {
      taskEventsError.value = describeTaskEventsError(err)
    }
  } finally {
    if (eventsFetchToken.value === token) taskEventsLoading.value = false
  }
}

// -- Activity loading (keeper: timeline + trajectory, else: timeline only) --

async function loadActivity(task: Task): Promise<void> {
  if (!task.assignee) return
  const token = ++activityFetchToken.value
  activityLoading.value = true
  activityError.value = null

  try {
    const keeper = findKeeper(task.assignee)
    const timelineName = keeper?.agent_name ?? task.assignee
    const trajectoryName = keeper?.name ?? null

    const [timeline, trajectory] = await Promise.all([
      fetchAgentTimeline(timelineName, 24, 200),
      trajectoryName ? fetchKeeperTrajectory(trajectoryName, 100) : Promise.resolve(null),
    ])

    if (activityFetchToken.value !== token) return
    activityEvents.value = buildTraceEvents(timeline, trajectory)
  } catch (err) {
    if (activityFetchToken.value !== token) return
    activityError.value = err instanceof Error ? err.message : 'fetch failed'
  } finally {
    if (activityFetchToken.value === token) activityLoading.value = false
  }
}

/** Whether the activity tab should be visible (assignee exists). */
export function hasActivityTab(task: Task): boolean {
  return Boolean(task.assignee)
}

/** Whether the assignee is a keeper (affects tool call visibility). */
export function isKeeperAssignee(task: Task): boolean {
  return task.assignee ? findKeeper(task.assignee) !== null : false
}

// -- Goal relationship (keeper's active goals) ----------------------

export function assigneeGoalIds(task: Task): string[] {
  const keeper = findKeeper(task.assignee)
  return keeper?.active_goal_ids ?? []
}
