// Goal-related types, signals, derived data, and helper functions

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import {
  goals,
  tasks,
} from '../../store'
import type { Goal, Task } from '../../types'

// -- Filter state ------------------------------------------------

type HorizonFilter = 'all' | 'short' | 'mid' | 'long'
export type GoalPhaseFilter =
  | 'all'
  | 'executing'
  | 'awaiting_verification'
  | 'awaiting_approval'
  | 'blocked'
  | 'paused'
  | 'completed'
  | 'dropped'

const horizonFilter = signal<HorizonFilter>('all')
export const phaseFilter = signal<GoalPhaseFilter>('all')

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

// -- Derived data ------------------------------------------------

const filteredGoals = computed(() => {
  let list = goals.value
  if (horizonFilter.value !== 'all') {
    list = list.filter(g => g.horizon === horizonFilter.value)
  }
  if (phaseFilter.value !== 'all') {
    list = list.filter(g => g.phase === phaseFilter.value)
  }
  return list
})

export const groupedByHorizon = computed(() => {
  const groups: Record<string, Goal[]> = { short: [], mid: [], long: [] }
  for (const g of filteredGoals.value) {
    const bucket = groups[g.horizon]
    if (bucket) bucket.push(g)
  }
  return groups
})

// -- Lookups -----------------------------------------------------

export function goalById(id: string): Goal | undefined {
  return goals.value.find(g => g.id === id)
}

// -- Derived progress (Phase F-G1) -------------------------------
// Phase 2 spec (`design-system/preview/cb-group-d.jsx:GoalHorizonTrack`)
// expects per-goal `progress` / `total`. Backend `Goal` does not surface
// these — we derive them from linked tasks. `cancelled` tasks are excluded
// from the denominator so cancelling a task moves the ratio up rather than
// counting it as failed work.

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

export const goalProgressMap = computed<Map<string, GoalProgress>>(() => {
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

export const horizonProgress = computed<Record<'short' | 'mid' | 'long', GoalProgress>>(() => {
  const goalsByHorizon: Record<'short' | 'mid' | 'long', Set<string>> = {
    short: new Set(),
    mid: new Set(),
    long: new Set(),
  }
  for (const g of goals.value) {
    const bucket = goalsByHorizon[g.horizon as 'short' | 'mid' | 'long']
    if (bucket) bucket.add(g.id)
  }
  const acc: Record<'short' | 'mid' | 'long', GoalProgress> = {
    short: { done: 0, total: 0, ratio: 0 },
    mid: { done: 0, total: 0, ratio: 0 },
    long: { done: 0, total: 0, ratio: 0 },
  }
  for (const t of tasks.value) {
    const gid = t.goal_id
    if (!gid || !isCountedTask(t)) continue
    for (const h of ['short', 'mid', 'long'] as const) {
      if (goalsByHorizon[h].has(gid)) {
        acc[h].total += 1
        if (isDoneTask(t)) acc[h].done += 1
        break
      }
    }
  }
  for (const h of ['short', 'mid', 'long'] as const) {
    const bucket = acc[h]
    bucket.ratio = bucket.total > 0 ? bucket.done / bucket.total : 0
  }
  return acc
})

export function formatProgressPct(p: GoalProgress): string {
  if (p.total === 0) return '0%'
  return `${Math.round(p.ratio * 100)}%`
}

export function TaskProgressBar({ done, total, size = 'md' }: { done: number; total: number; size?: 'sm' | 'md' }) {
  const ratio = total > 0 ? done / total : 0
  const pct = Math.round(ratio * 100)
  const barColor =
    pct >= 80 ? 'var(--color-status-ok)'
    : pct >= 50 ? 'var(--amber-bright)'
    : pct >= 20 ? 'var(--color-orange-400)'
    : 'var(--color-status-err)'

  const h = size === 'sm' ? 'h-1.5' : 'h-2.5'
  return html`
    <div class="flex items-center gap-2">
      <div class="flex-1 ${h} rounded-[var(--r-0)] bg-[var(--color-bg-hover)] overflow-hidden">
        <div class="${h} rounded-[var(--r-0)] transition-all duration-[var(--t-xslow)]" style="width:${pct}%;background:${barColor}"></div>
      </div>
      <span class="text-2xs font-semibold tabular-nums text-text-muted w-14 text-right">${done}/${total}</span>
    </div>
  `
}

// -- Helpers -----------------------------------------------------

export function priorityStars(n: number): string {
  return '\u2605'.repeat(Math.min(n, 5)) + '\u2606'.repeat(Math.max(0, 5 - n))
}

export function horizonLabel(h: string): string {
  switch (h) {
    case 'short': return '단기'
    case 'mid': return '중기'
    case 'long': return '장기'
    default: return h
  }
}

export function horizonColor(h: string): string {
  switch (h) {
    case 'short': return 'var(--color-status-ok)'
    case 'mid': return 'var(--amber-bright)'
    case 'long': return 'var(--indigo)'
    default: return 'var(--color-fg-muted)'
  }
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

export function sortByPriority(a: Task, b: Task): number {
  return (a.priority ?? 4) - (b.priority ?? 4)
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
