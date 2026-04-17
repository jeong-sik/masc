import { describe, it, expect } from 'vitest'
import { filterOwnedTasks, filterTaskHistories } from './agent-detail'
import type { Task } from '../types'
import type { TaskHistoryRow } from './agent-detail-state'

function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'PK-1',
    title: 'default title',
    status: 'todo',
    ...overrides,
  }
}

describe('filterOwnedTasks', () => {
  const tasks: readonly Task[] = [
    makeTask({ id: 'PK-100', title: 'refactor dashboard filter', status: 'in_progress', description: 'split filter helper' }),
    makeTask({ id: 'PK-200', title: 'OAS cascade retry', status: 'done', description: 'stabilise retry loop' }),
    makeTask({ id: 'PK-300', title: 'heartbeat audit', status: 'claimed', description: undefined }),
  ]

  it('returns input reference unchanged on empty query', () => {
    expect(filterOwnedTasks(tasks, '')).toBe(tasks)
  })

  it('returns input reference unchanged on whitespace query', () => {
    expect(filterOwnedTasks(tasks, '   ')).toBe(tasks)
  })

  it('is case-insensitive', () => {
    expect(filterOwnedTasks(tasks, 'OAS').map(t => t.id)).toEqual(['PK-200'])
    expect(filterOwnedTasks(tasks, 'oas').map(t => t.id)).toEqual(['PK-200'])
  })

  it('trims leading/trailing whitespace', () => {
    expect(filterOwnedTasks(tasks, '  heartbeat  ').map(t => t.id)).toEqual(['PK-300'])
  })

  it('matches across id, title, status, and description', () => {
    // id hit
    expect(filterOwnedTasks(tasks, 'PK-100').map(t => t.id)).toEqual(['PK-100'])
    // title hit
    expect(filterOwnedTasks(tasks, 'refactor').map(t => t.id)).toEqual(['PK-100'])
    // status hit (claimed)
    expect(filterOwnedTasks(tasks, 'claimed').map(t => t.id)).toEqual(['PK-300'])
    // description hit
    expect(filterOwnedTasks(tasks, 'stabilise').map(t => t.id)).toEqual(['PK-200'])
  })

  it('returns empty array when nothing matches', () => {
    expect(filterOwnedTasks(tasks, 'nonexistent-token')).toEqual([])
  })

  it('does not mutate the input', () => {
    const snapshot = tasks.map(t => ({ ...t }))
    filterOwnedTasks(tasks, 'oas')
    expect(tasks).toEqual(snapshot)
  })
})

describe('filterTaskHistories', () => {
  const rows: readonly TaskHistoryRow[] = [
    { taskId: 'PK-100', text: 'refactor dashboard filter complete' },
    { taskId: 'PK-200', text: 'OAS cascade stabilised after retry loop' },
    { taskId: 'PK-300', text: '' },
  ]

  it('returns input reference unchanged on empty query', () => {
    expect(filterTaskHistories(rows, '')).toBe(rows)
  })

  it('returns input reference unchanged on whitespace query', () => {
    expect(filterTaskHistories(rows, '   ')).toBe(rows)
  })

  it('is case-insensitive', () => {
    expect(filterTaskHistories(rows, 'OAS').map(r => r.taskId)).toEqual(['PK-200'])
    expect(filterTaskHistories(rows, 'oas').map(r => r.taskId)).toEqual(['PK-200'])
  })

  it('trims leading/trailing whitespace', () => {
    expect(filterTaskHistories(rows, '  dashboard  ').map(r => r.taskId)).toEqual(['PK-100'])
  })

  it('matches across taskId and text', () => {
    // taskId hit
    expect(filterTaskHistories(rows, 'PK-300').map(r => r.taskId)).toEqual(['PK-300'])
    // text hit
    expect(filterTaskHistories(rows, 'stabilised').map(r => r.taskId)).toEqual(['PK-200'])
  })

  it('returns empty array when nothing matches', () => {
    expect(filterTaskHistories(rows, 'nonexistent-token')).toEqual([])
  })

  it('does not mutate the input', () => {
    const snapshot = rows.map(r => ({ ...r }))
    filterTaskHistories(rows, 'oas')
    expect(rows).toEqual(snapshot)
  })
})
