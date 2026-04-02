// Task detail overlay state — signals, fetch, normalization

import { signal } from '@preact/signals'
import { fetchTaskHistory } from '../../api/actions'
import { findKeeper } from '../../lib/keeper-utils'
import { goals } from '../../store'
import type { Task, Goal } from '../../types'

// -- Normalized task event (from masc_task_history raw JSON) --------

export interface NormalizedTaskEvent {
  label: string
  agent: string | null
  taskId: string | null
  ts: string | null
  notes: string | null
}

interface TaskHistoryRow {
  type?: string
  agent?: string
  task?: string
  task_id?: string
  action?: string
  ts?: string
  ts_iso?: string
  notes?: string
}

function normalizeTaskHistory(raw: TaskHistoryRow[]): NormalizedTaskEvent[] {
  return raw.map(r => ({
    label: r.action ?? (r.type ? r.type.replace('task_', '') : 'unknown'),
    agent: r.agent ?? null,
    taskId: r.task ?? r.task_id ?? null,
    ts: r.ts ?? r.ts_iso ?? null,
    notes: r.notes ?? null,
  }))
}

// -- Overlay signals ------------------------------------------------

export const selectedTask = signal<Task | null>(null)
export const taskEvents = signal<NormalizedTaskEvent[]>([])
export const taskEventsLoading = signal(false)
export const taskEventsError = signal<string | null>(null)

const eventsFetchToken = signal(0)

// -- State lifecycle ------------------------------------------------

function resetState(): void {
  taskEvents.value = []
  taskEventsLoading.value = false
  taskEventsError.value = null
}

export function openTaskDetail(task: Task): void {
  resetState()
  selectedTask.value = task
  void loadTaskEvents(task.id)
}

export function closeTaskDetail(): void {
  selectedTask.value = null
  eventsFetchToken.value++
  resetState()
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

// -- Goal relationship (keeper's active goals) ----------------------

export function assigneeGoalIds(task: Task): string[] {
  const keeper = findKeeper(task.assignee)
  return (keeper as Record<string, unknown>)?.active_goal_ids as string[] ?? []
}

export function goalById(id: string): Goal | undefined {
  return goals.value.find(g => g.id === id)
}
