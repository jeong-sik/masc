// Goal-related types, signals, derived data, and helper functions

import { signal, computed } from '@preact/signals'
import {
  goals,
} from '../../store'
import type { Goal, Task } from '../../types'

// -- Filter state ------------------------------------------------

type HorizonFilter = 'all' | 'short' | 'mid' | 'long'
export type StatusFilter = 'all' | 'active' | 'completed' | 'paused'

const horizonFilter = signal<HorizonFilter>('all')
export const statusFilter = signal<StatusFilter>('all')

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
  if (statusFilter.value !== 'all') {
    list = list.filter(g => g.status === statusFilter.value)
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
    case 'short': return '#4ade80'
    case 'mid': return '#f59e0b'
    case 'long': return '#818cf8'
    default: return '#888'
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

export function statusFilterLabel(value: StatusFilter): string {
  switch (value) {
    case 'active': return '진행 중'
    case 'completed': return '완료'
    case 'paused': return '일시정지'
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
