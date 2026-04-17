import { describe, it, expect } from 'vitest'
import {
  priorityStars,
  horizonLabel,
  horizonColor,
  priorityLabel,
  statusFilterLabel,
  sortByPriority,
  sortByTimeDesc,
  filterTasksByQuery,
  resetTaskSearch,
  taskSearchQuery,
} from './goal-helpers'
import type { Task } from '../../types'

// ================================================================
// priorityStars
// ================================================================

describe('priorityStars', () => {
  it('returns 5 filled stars for 5', () => {
    expect(priorityStars(5)).toBe('\u2605\u2605\u2605\u2605\u2605')
  })

  it('returns 1 filled + 4 empty for 1', () => {
    expect(priorityStars(1)).toBe('\u2605\u2606\u2606\u2606\u2606')
  })

  it('returns 0 filled + 5 empty for 0', () => {
    expect(priorityStars(0)).toBe('\u2606\u2606\u2606\u2606\u2606')
  })

  it('caps at 5 for values > 5', () => {
    expect(priorityStars(10)).toBe('\u2605\u2605\u2605\u2605\u2605')
  })

  it('returns 3 filled + 2 empty for 3', () => {
    expect(priorityStars(3)).toBe('\u2605\u2605\u2605\u2606\u2606')
  })
})

// ================================================================
// horizonLabel
// ================================================================

describe('horizonLabel', () => {
  it('returns 단기 for short', () => {
    expect(horizonLabel('short')).toBe('단기')
  })

  it('returns 중기 for mid', () => {
    expect(horizonLabel('mid')).toBe('중기')
  })

  it('returns 장기 for long', () => {
    expect(horizonLabel('long')).toBe('장기')
  })

  it('returns raw value for unknown', () => {
    expect(horizonLabel('custom')).toBe('custom')
  })
})

// ================================================================
// horizonColor
// ================================================================

describe('horizonColor', () => {
  it('returns green for short', () => {
    expect(horizonColor('short')).toBe('#4ade80')
  })

  it('returns amber for mid', () => {
    expect(horizonColor('mid')).toBe('#f59e0b')
  })

  it('returns indigo for long', () => {
    expect(horizonColor('long')).toBe('#818cf8')
  })

  it('returns gray for unknown', () => {
    expect(horizonColor('unknown')).toBe('#888')
  })
})

// ================================================================
// priorityLabel
// ================================================================

describe('priorityLabel', () => {
  it('returns P1 for 1', () => {
    expect(priorityLabel(1)).toBe('P1')
  })

  it('returns P2 for 2', () => {
    expect(priorityLabel(2)).toBe('P2')
  })

  it('returns P3 for 3', () => {
    expect(priorityLabel(3)).toBe('P3')
  })

  it('returns P4 for 0', () => {
    expect(priorityLabel(0)).toBe('P4')
  })

  it('returns P4 for 5', () => {
    expect(priorityLabel(5)).toBe('P4')
  })
})

// ================================================================
// statusFilterLabel
// ================================================================

describe('statusFilterLabel', () => {
  it('returns 전체 for all', () => {
    expect(statusFilterLabel('all')).toBe('전체')
  })

  it('returns 진행 중 for active', () => {
    expect(statusFilterLabel('active')).toBe('진행 중')
  })

  it('returns 완료 for completed', () => {
    expect(statusFilterLabel('completed')).toBe('완료')
  })

  it('returns 일시정지 for paused', () => {
    expect(statusFilterLabel('paused')).toBe('일시정지')
  })

  it('returns 전체 for unknown', () => {
    expect(statusFilterLabel('custom' as any)).toBe('전체')
  })
})

// ================================================================
// sortByPriority
// ================================================================

describe('sortByPriority', () => {
  function makeTask(priority: number): Task {
    return { id: 't', title: 'test', priority } as Task
  }

  it('sorts lower priority number first', () => {
    const a = makeTask(1)
    const b = makeTask(3)
    expect(sortByPriority(a, b)).toBeLessThan(0)
  })

  it('defaults missing priority to 4', () => {
    const a = makeTask(undefined as any)
    const b = makeTask(2)
    expect(sortByPriority(a, b)).toBeGreaterThan(0)
  })

  it('returns 0 for equal priority', () => {
    const a = makeTask(2)
    const b = makeTask(2)
    expect(sortByPriority(a, b)).toBe(0)
  })
})

// ================================================================
// sortByTimeDesc
// ================================================================

describe('sortByTimeDesc', () => {
  function makeTask(updated_at?: string, created_at?: string): Task {
    return { id: 't', title: 'test', updated_at, created_at } as Task
  }

  it('sorts newer first', () => {
    const a = makeTask('2026-04-17')
    const b = makeTask('2026-04-16')
    expect(sortByTimeDesc(a, b)).toBeLessThan(0)
  })

  it('falls back to created_at', () => {
    const a = makeTask(undefined, '2026-04-17')
    const b = makeTask(undefined, '2026-04-16')
    expect(sortByTimeDesc(a, b)).toBeLessThan(0)
  })

  it('handles empty strings', () => {
    const a = makeTask('', '')
    const b = makeTask('', '')
    expect(sortByTimeDesc(a, b)).toBe(0)
  })
})

// ================================================================
// filterTasksByQuery
// ================================================================

describe('filterTasksByQuery', () => {
  type Searchable = { id: string; title: string; description?: string | null; assignee?: string | null }
  const tasks: Searchable[] = [
    { id: 't1', title: '[masc-mcp] Fix keeper heartbeat', description: 'Eio timeout regression', assignee: 'claude' },
    { id: 't2', title: '[oas] Add Groq provider', description: null, assignee: 'codex' },
    { id: 't3', title: 'Dashboard polish', description: 'Tailwind migration cleanup', assignee: null },
    { id: 't4', title: 'Write evidence record', description: 'BFCL 67 verification', assignee: 'gemini' },
  ]

  it('returns a copy of all tasks for an empty query', () => {
    const result = filterTasksByQuery(tasks, '')
    expect(result).toHaveLength(tasks.length)
    expect(result).not.toBe(tasks)
  })

  it('treats whitespace-only query as empty', () => {
    expect(filterTasksByQuery(tasks, '   ')).toHaveLength(tasks.length)
  })

  it('matches on title (case-insensitive)', () => {
    const result = filterTasksByQuery(tasks, 'KEEPER')
    expect(result.map(t => t.id)).toEqual(['t1'])
  })

  it('matches on description', () => {
    const result = filterTasksByQuery(tasks, 'tailwind')
    expect(result.map(t => t.id)).toEqual(['t3'])
  })

  it('matches on assignee', () => {
    const result = filterTasksByQuery(tasks, 'codex')
    expect(result.map(t => t.id)).toEqual(['t2'])
  })

  it('returns empty array on miss', () => {
    expect(filterTasksByQuery(tasks, 'zzzz')).toEqual([])
  })

  it('handles null description and assignee without throwing', () => {
    const result = filterTasksByQuery(tasks, 'dashboard')
    expect(result.map(t => t.id)).toEqual(['t3'])
  })

  it('trims query before matching', () => {
    expect(filterTasksByQuery(tasks, '  groq  ').map(t => t.id)).toEqual(['t2'])
  })
})

// ================================================================
// resetTaskSearch
// ================================================================

describe('resetTaskSearch', () => {
  it('clears taskSearchQuery to empty string', () => {
    taskSearchQuery.value = 'something'
    resetTaskSearch()
    expect(taskSearchQuery.value).toBe('')
  })
})
