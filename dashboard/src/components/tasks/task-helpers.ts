import { signal } from '@preact/signals'
import type { Task } from '../../types'

export const taskSearchQuery = signal<string>('')

export function resetTaskSearch(): void {
  taskSearchQuery.value = ''
}

export function filterTasksByQuery<T extends { title?: string; description?: string | null; assignee?: string | null }>(
  tasks: readonly T[],
  query: string,
): T[] {
  const needle = query.trim().toLowerCase()
  if (!needle) return [...tasks]
  return tasks.filter(task => {
    if ((task.title ?? '').toLowerCase().includes(needle)) return true
    if ((task.description ?? '').toLowerCase().includes(needle)) return true
    return (task.assignee ?? '').toLowerCase().includes(needle)
  })
}

export const expandedTasks = signal<Set<string>>(new Set())

export function toggleTaskExpand(id: string): void {
  const next = new Set(expandedTasks.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedTasks.value = next
}

export function priorityLabel(priority: number): string {
  switch (priority) {
    case 1: return 'P1'
    case 2: return 'P2'
    case 3: return 'P3'
    default: return 'P4'
  }
}

export const DEFAULT_TASK_PRIORITY = 4
export const HIGH_TASK_PRIORITY_MAX = 2

export function effectiveTaskPriority(task: { priority?: number | null }): number {
  return task.priority ?? DEFAULT_TASK_PRIORITY
}

export function sortByPriority(a: Task, b: Task): number {
  return effectiveTaskPriority(a) - effectiveTaskPriority(b)
}

export function sortByTimeDesc(a: Task, b: Task): number {
  const left = a.updated_at ?? a.created_at ?? ''
  const right = b.updated_at ?? b.created_at ?? ''
  return right.localeCompare(left)
}
