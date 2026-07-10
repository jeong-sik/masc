// Goal-related types, signals, derived data, and helper functions

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import {
  goals,
  tasks,
} from '../../store'
import type { Goal, Task } from '../../types'

// -- Filter state ------------------------------------------------

export type GoalPhaseFilter =
  | 'all'
  | 'executing'
  | 'awaiting_verification'
  | 'awaiting_approval'
  | 'blocked'
  | 'paused'
  | 'completed'
  | 'dropped'

// -- Task-level search (case-insensitive, title + description + assignee) --

export const taskSearchQuery = signal<string>('')

export function resetTaskSearch() {
  taskSearchQuery.value = ''
}

export function filterTasksByQuery<T extends { title?: string; description?: string | null; assignee?: string | null }>(
  tasks: readonly T[],
  query: string,
): T[] {
  const q = query.trim().toLowerCase()
  if (!q) return [...tasks]
  return tasks.filter(t => {
    const title = (t.title ?? '').toLowerCase()
    if (title.includes(q)) return true
    const description = (t.description ?? '').toLowerCase()
    if (description.includes(q)) return true
    const assignee = (t.assignee ?? '').toLowerCase()
    return assignee.includes(q)
  })
}

// -- Expand state for task description previews ------------------

export const expandedTasks = signal<Set<string>>(new Set())

export function toggleTaskExpand(id: string) {
  const next = new Set(expandedTasks.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedTasks.value = next
}

// -- Lookups -----------------------------------------------------

export function goalById(id: string): Goal | undefined {
  return goals.value.find(g => g.id === id)
}

// -- Task completion counts --------------------------------------
// This is not a goal-attainment metric. It is a count of linked tasks from
// the planning store, used only where the richer dashboard goal-tree summary
// is not available yet. Metric/attainment truth belongs to the goal-tree API.

export interface GoalProgress {
  done: number
  total: number
  ratio: number
}

const ZERO_PROGRESS: GoalProgress = { done: 0, total: 0, ratio: 0 }

function isCountedTask(t: Task): boolean {
  return t.status !== 'cancelled'
}

function isDoneTask(t: Task): boolean {
  return t.status === 'done'
}

const goalProgressMap = computed<Map<string, GoalProgress>>(() => {
  const map = new Map<string, GoalProgress>()
  for (const g of goals.value) {
    map.set(g.id, { done: 0, total: 0, ratio: 0 })
  }
  for (const t of tasks.value) {
    const gid = t.goal_id
    if (!gid) continue
    const entry = map.get(gid)
    if (!entry) continue
    if (!isCountedTask(t)) continue
    entry.total += 1
    if (isDoneTask(t)) entry.done += 1
  }
  for (const v of map.values()) {
    v.ratio = v.total > 0 ? v.done / v.total : 0
  }
  return map
})

export function goalProgressFor(goalId: string): GoalProgress {
  return goalProgressMap.value.get(goalId) ?? ZERO_PROGRESS
}

export function formatProgressPct(p: GoalProgress): string {
  if (p.total === 0) return 'no linked tasks'
  return `${p.done}/${p.total} tasks`
}

export function TaskProgressBar({ done, total, size = 'md' }: { done: number; total: number; size?: 'sm' | 'md' }) {
  const ratio = total > 0 ? done / total : 0
  const pct = Math.round(ratio * 100)
  const h = size === 'sm' ? 'h-1.5' : 'h-2.5'
  return html`
    <div class="flex items-center gap-2">
      <div
        class="flex-1 ${h} rounded-[var(--r-0)] bg-[var(--color-bg-hover)] overflow-hidden"
        title="Linked task completion count. This is not a goal-attainment metric."
        data-task-count-meter
        data-task-count-meter-pct=${pct}
      >
        <div class="${h} rounded-[var(--r-0)] transition-[width] duration-[var(--t-xslow)] bg-[var(--color-accent-fg)]" style="width:${pct}%"></div>
      </div>
      <span class="text-2xs font-semibold tabular-nums text-text-muted w-14 text-right">${done}/${total}</span>
    </div>
  `
}

// -- Helpers -----------------------------------------------------

export function priorityStars(n: number): string {
  return '\u2605'.repeat(Math.min(n, 5)) + '\u2606'.repeat(Math.max(0, 5 - n))
}

export function goalPhaseLabel(phase: string): string {
  switch (phase) {
    case 'executing': return '실행 중'
    case 'awaiting_verification': return 'Goal 검증 대기'
    case 'awaiting_approval': return '승인 대기'
    case 'blocked': return '차단됨'
    case 'paused': return '일시정지'
    case 'completed': return '완료'
    case 'dropped': return '중단'
    default: return phase
  }
}

export function goalPhaseStatus(phase: string): string {
  switch (phase) {
    case 'awaiting_verification': return 'awaiting_verification'
    case 'awaiting_approval': return 'interrupted'
    case 'completed': return 'completed'
    case 'blocked': return 'error'
    case 'paused': return 'paused'
    case 'dropped': return 'offline'
    case 'executing':
    default:
      return 'active'
  }
}

export function priorityLabel(p: number): string {
  switch (p) {
    case 1: return 'P1'
    case 2: return 'P2'
    case 3: return 'P3'
    default: return 'P4'
  }
}

export function matchesGoalPhaseFilter(
  phase: string,
  filter: GoalPhaseFilter,
): boolean {
  return filter === 'all' || phase === filter
}

export function phaseFilterLabel(value: GoalPhaseFilter): string {
  switch (value) {
    case 'executing': return '실행 중'
    case 'awaiting_verification': return 'Goal 검증 대기'
    case 'awaiting_approval': return '승인 대기'
    case 'blocked': return '차단됨'
    case 'paused': return '일시정지'
    case 'completed': return '완료'
    case 'dropped': return '중단'
    default: return '전체'
  }
}

// Priority is 1 (highest) .. N; a task with no priority set sorts as the
// lowest urgency. Kept as one constant so every sort/filter/badge agrees on the
// fallback (previously the literal 4 was copied across 5 task sites).
export const DEFAULT_TASK_PRIORITY = 4
// Priority at or below this is surfaced as "high priority" (the red planning KPI).
export const HIGH_TASK_PRIORITY_MAX = 2

/** Effective priority for sorting/filtering: the task's own priority, or the
 * default when unset. */
export function effectiveTaskPriority(task: { priority?: number | null }): number {
  return task.priority ?? DEFAULT_TASK_PRIORITY
}

export function sortByPriority(a: Task, b: Task): number {
  return effectiveTaskPriority(a) - effectiveTaskPriority(b)
}

export function sortByTimeDesc(a: Task, b: Task): number {
  const ta = a.updated_at ?? a.created_at ?? ''
  const tb = b.updated_at ?? b.created_at ?? ''
  return tb.localeCompare(ta)
}

// -- Goal tree verification helpers ----------------------------

interface StatusBearer {
  status: string
}

export function countAwaitingVerificationTasks(tasks: readonly StatusBearer[]): number {
  let n = 0
  for (const t of tasks) if (t.status === 'awaiting_verification') n++
  return n
}

interface TreeNodeLike {
  pending_verification_count?: number
  tasks: readonly StatusBearer[]
  children: readonly TreeNodeLike[]
}

export function countAwaitingVerificationInTree(nodes: readonly TreeNodeLike[]): number {
  let n = 0
  for (const node of nodes) {
    n += countAwaitingVerificationTasks(node.tasks)
    if (node.children.length > 0) n += countAwaitingVerificationInTree(node.children)
  }
  return n
}

export function countGoalVerificationInTree(nodes: readonly TreeNodeLike[]): number {
  let n = 0
  for (const node of nodes) {
    n += node.pending_verification_count ?? 0
    if (node.children.length > 0) n += countGoalVerificationInTree(node.children)
  }
  return n
}
