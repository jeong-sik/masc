// Task detail overlay state — signals, fetch, normalization

import { signal } from '@preact/signals'
import { selectedTask } from './task-detail-selection'
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

// -- Activity lineage (ownership chain + lifecycle rail) ------------
//
// The keeper-v2 prototype (work.jsx TaskLineage) renders task history as an
// ownership chain (first actor + every handoff target, de-duplicated) plus a
// vertical rail of lifecycle events. masc_task_history carries the per-event
// actor (`agent`) but no explicit handoff *target*, so the chain is derived
// from the actor sequence rather than fabricated per-event `→ target` arrows.

export interface TaskLineageStage {
  readonly key: string
  readonly glyph: string
  readonly cls: string
  readonly lbl: string
}

const TASK_LINEAGE_STAGES: Readonly<Record<string, TaskLineageStage>> = {
  created: { key: 'created', glyph: '○', cls: 'dim', lbl: '생성' },
  claimed: { key: 'claimed', glyph: '◉', cls: 'claimed', lbl: '클레임' },
  started: { key: 'started', glyph: '▶', cls: 'wip', lbl: '착수' },
  handoff: { key: 'handoff', glyph: '⇄', cls: 'volt', lbl: '핸드오프' },
  submitted: { key: 'submitted', glyph: '◪', cls: 'verify', lbl: '검증 제출' },
  approved: { key: 'approved', glyph: '✓', cls: 'done', lbl: '검증 승인' },
  rejected: { key: 'rejected', glyph: '✕', cls: 'bad', lbl: '반려' },
  blocked: { key: 'blocked', glyph: '⚠', cls: 'bad', lbl: '차단' },
  done: { key: 'done', glyph: '✓', cls: 'done', lbl: '완료' },
  cancelled: { key: 'cancelled', glyph: '◌', cls: 'dim', lbl: '취소' },
  transition: { key: 'transition', glyph: '·', cls: 'dim', lbl: '전이' },
}

/** Map a raw masc_task_history label to a lifecycle stage spec. */
export function taskLineageStage(label: string): TaskLineageStage {
  switch (label.trim().toLowerCase()) {
    case 'created':
    case 'create': return TASK_LINEAGE_STAGES.created!
    case 'claimed':
    case 'claim': return TASK_LINEAGE_STAGES.claimed!
    case 'started':
    case 'start':
    case 'in_progress': return TASK_LINEAGE_STAGES.started!
    case 'handoff':
    case 'hand_off':
    case 'handed_off': return TASK_LINEAGE_STAGES.handoff!
    case 'submitted':
    case 'submit':
    case 'submit_for_verification':
    case 'awaiting_verification': return TASK_LINEAGE_STAGES.submitted!
    case 'approved':
    case 'approve': return TASK_LINEAGE_STAGES.approved!
    case 'rejected':
    case 'reject': return TASK_LINEAGE_STAGES.rejected!
    case 'blocked':
    case 'block': return TASK_LINEAGE_STAGES.blocked!
    case 'done':
    case 'completed':
    case 'complete': return TASK_LINEAGE_STAGES.done!
    case 'cancelled':
    case 'canceled':
    case 'cancel': return TASK_LINEAGE_STAGES.cancelled!
    default: return TASK_LINEAGE_STAGES.transition!
  }
}

export interface TaskLineageRow {
  readonly stage: TaskLineageStage
  readonly actor: string | null
  readonly ts: string | null
  readonly notes: string | null
}

export interface TaskLineage {
  readonly chain: readonly string[]
  readonly rows: readonly TaskLineageRow[]
  readonly synthesized: boolean
}

// Minimal flow synthesized from the current status when no history exists yet
// (mirrors work.jsx taskLineage fallback). Keyed by the live 6-state lifecycle.
const SYNTHESIZED_STAGE_KEYS: Readonly<Record<string, readonly string[]>> = {
  todo: ['created'],
  claimed: ['created', 'claimed'],
  in_progress: ['created', 'claimed', 'started'],
  awaiting_verification: ['created', 'started', 'submitted'],
  done: ['created', 'done'],
  cancelled: ['created', 'cancelled'],
}

/**
 * Build the ownership chain + lifecycle rail for a task.
 *
 * - With history: each event becomes a rail row (stage/actor/ts/notes); the
 *   chain is the de-duplicated actor sequence in event order.
 * - Without history: a minimal flow is synthesized from `status` + `assignee`
 *   so the rail is never empty for an assigned/active task.
 */
export function buildTaskLineage(
  events: readonly NormalizedTaskEvent[],
  task: Pick<Task, 'status' | 'assignee'>,
): TaskLineage {
  if (events.length > 0) {
    const rows: TaskLineageRow[] = events.map(event => ({
      stage: taskLineageStage(event.label),
      actor: event.agent,
      ts: event.ts,
      notes: event.notes,
    }))
    const chain: string[] = []
    for (const row of rows) {
      if (row.actor && !chain.includes(row.actor)) chain.push(row.actor)
    }
    return { chain, rows, synthesized: false }
  }

  const assignee = task.assignee ?? null
  const stageKeys = SYNTHESIZED_STAGE_KEYS[task.status ?? 'todo'] ?? SYNTHESIZED_STAGE_KEYS.todo!
  const rows: TaskLineageRow[] = stageKeys.map(key => ({
    stage: TASK_LINEAGE_STAGES[key]!,
    actor: assignee,
    ts: null,
    notes: null,
  }))
  return { chain: assignee ? [assignee] : [], rows, synthesized: true }
}

function describeTaskEventsError(err: unknown): string {
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
    const isKeeper = task.assignee_kind === 'keeper' || keeper !== null
    const trajectoryName = isKeeper ? task.assignee : null

    const [timeline, trajectory] = await Promise.all([
      fetchAgentTimeline(timelineName, 24, 200),
      trajectoryName ? fetchKeeperTrajectory(trajectoryName, 100).catch(() => null) : Promise.resolve(null),
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
  return task.assignee_kind === 'keeper' || (task.assignee ? findKeeper(task.assignee) !== null : false)
}

// -- Goal relationship (keeper's active goals) ----------------------

export function assigneeGoalIds(task: Task): string[] {
  const keeper = findKeeper(task.assignee)
  return keeper?.active_goal_ids ?? []
}
