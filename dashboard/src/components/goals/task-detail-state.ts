// Task detail overlay state — signals, fetch, normalization

import { signal } from '@preact/signals'
import { fetchTaskHistory } from '../../api/actions'
import { fetchAgentTimeline, fetchKeeperTrajectory } from '../../api/dashboard'
import { buildTraceEvents, type UnifiedTraceEvent } from '../session-trace/session-trace-state'
import { findKeeper } from '../../lib/keeper-utils'
import type { Task } from '../../types'

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

// -- Overlay signals ------------------------------------------------

export const selectedTask = signal<Task | null>(null)
export const taskEvents = signal<NormalizedTaskEvent[]>([])
export const taskEventsLoading = signal(false)
export const taskEventsError = signal<string | null>(null)

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
    const raw = await fetchTaskHistory(taskId, 50)
    if (eventsFetchToken.value !== token) return
    const parsed: unknown = JSON.parse(raw)
    const arr = Array.isArray(parsed) ? parsed : ((parsed as Record<string, unknown>).events ?? [])
    taskEvents.value = normalizeTaskHistory(arr as TaskHistoryRow[])
  } catch {
    if (eventsFetchToken.value === token) taskEventsError.value = 'fetch failed'
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
