import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import '@testing-library/jest-dom'
import { TaskBacklog, buildBacklogPressureRows, resetTaskBacklogState } from './kanban-components'
import { executionError, executionLoaded, executionLoading, tasks } from '../../store'
import { resetTaskSearch } from './goal-helpers'
import type { Task } from '../../types'

vi.mock('@formkit/auto-animate', () => ({
  default: vi.fn(),
}))

function makeDoneTask(index: number): Task {
  const day = String(26 - index).padStart(2, '0')
  const timestamp = `2026-04-${day}T00:00:00Z`
  return {
    id: `done-${index}`,
    title: `Done task ${index}`,
    status: 'done',
    priority: 3,
    description: `Description ${index}`,
    created_at: timestamp,
    updated_at: timestamp,
    completed_at: timestamp,
  }
}

describe('TaskBacklog', () => {
  beforeEach(() => {
    resetTaskBacklogState()
    resetTaskSearch()
    executionLoaded.value = true
    executionLoading.value = false
    executionError.value = null
    tasks.value = Array.from({ length: 25 }, (_value, index) => makeDoneTask(index + 1))
  })

  afterEach(() => {
    cleanup()
    vi.useRealTimers()
    tasks.value = []
    executionLoaded.value = false
    executionLoading.value = false
    executionError.value = null
    resetTaskSearch()
    resetTaskBacklogState()
  })

  it('summarizes unclaimed priority pressure by oldest task age', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-05-06T12:00:00Z'))
    const criticalTodo: Task = {
      id: 'task-critical',
      title: 'Critical task',
      status: 'todo',
      priority: 1,
      description: 'Needs prompt claim.',
      created_at: '2026-05-06T10:00:00Z',
    }
    const newerCriticalTodo: Task = {
      id: 'task-critical-newer',
      title: 'Newer critical task',
      status: 'todo',
      priority: 1,
      created_at: '2026-05-06T11:30:00Z',
    }
    const claimedCritical: Task = {
      id: 'task-claimed',
      title: 'Claimed critical task',
      status: 'claimed',
      priority: 1,
      created_at: '2026-05-06T08:00:00Z',
    }
    tasks.value = [criticalTodo, newerCriticalTodo, claimedCritical]

    render(h(TaskBacklog, {}))

    const pressure = screen.getByLabelText('Backlog pressure')
    const p1 = within(pressure).getByRole('button', { name: 'P1 backlog pressure: 2 unclaimed' })
    expect(p1).toHaveTextContent('2h')
    expect(p1).toHaveTextContent('breached 1h')
    expect(within(pressure).getByRole('button', { name: 'P2 backlog pressure: 0 unclaimed' })).toBeDisabled()
  })

  it('builds pressure rows without counting claimed tasks', () => {
    const rows = buildBacklogPressureRows([
      {
        id: 'todo-p2',
        title: 'Todo P2',
        status: 'todo',
        priority: 2,
        created_at: '2026-05-06T00:00:00Z',
      },
      {
        id: 'assigned-todo-p2',
        title: 'Assigned todo P2',
        status: 'todo',
        priority: 2,
        assignee: 'keeper-alpha',
        created_at: '2026-05-05T00:00:00Z',
      },
      {
        id: 'blank-assignee-p2',
        title: 'Blank assignee P2',
        status: 'todo',
        priority: 2,
        assignee: ' ',
        created_at: '2026-05-06T01:00:00Z',
      },
    ], Date.parse('2026-05-06T07:00:00Z'))

    const p2 = rows.find(row => row.priority === 2)
    expect(p2?.count).toBe(2)
    expect(p2?.tone).toBe('warn')
    expect(p2?.oldestTask?.id).toBe('todo-p2')
  })

  it('normalizes out-of-range priorities into P4 pressure', () => {
    const rows = buildBacklogPressureRows([
      {
        id: 'todo-p0',
        title: 'Todo P0',
        status: 'todo',
        priority: 0,
        created_at: '2026-05-06T00:00:00Z',
      },
      {
        id: 'todo-p5',
        title: 'Todo P5',
        status: 'todo',
        priority: 5,
        created_at: '2026-05-06T01:00:00Z',
      },
    ], Date.parse('2026-05-06T07:00:00Z'))

    const p4 = rows.find(row => row.priority === 4)
    expect(p4?.count).toBe(2)
    expect(p4?.oldestTask?.id).toBe('todo-p0')
  })

  it('preserves expanded done pagination after clearing search', async () => {
    render(h(TaskBacklog, {}))

    expect(screen.queryByText('Done task 25')).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /완료 태스크 5개 더 보기/ }))

    await waitFor(() => {
      expect(screen.getByText('Done task 25')).toBeInTheDocument()
    })

    fireEvent.input(screen.getByLabelText('태스크 검색'), {
      target: { value: 'Done task 25' },
    })

    await waitFor(() => {
      expect(screen.getByText('Done task 25')).toBeInTheDocument()
      expect(screen.queryByText('Done task 24')).not.toBeInTheDocument()
    })

    fireEvent.click(screen.getByRole('button', { name: '검색 초기화' }))

    await waitFor(() => {
      expect(screen.getByText('Done task 25')).toBeInTheDocument()
      expect(screen.getByText('Done task 24')).toBeInTheDocument()
      expect(screen.queryByRole('button', { name: /완료 태스크 .*더 보기/ })).not.toBeInTheDocument()
    })
  })

  it('renders awaiting_verification column with task card and pill', async () => {
    const awaitingTask: Task = {
      id: 'task-awaiting-001',
      title: 'Awaiting verification task',
      status: 'awaiting_verification',
      priority: 2,
      description: 'Verifier keeper is measuring completion contract.',
      created_at: '2026-04-18T00:00:00Z',
      updated_at: '2026-04-18T00:05:00Z',
    }
    tasks.value = [awaitingTask]

    render(h(TaskBacklog, {}))

    await waitFor(() => {
      expect(screen.getByRole('heading', { name: '검증 대기' })).toBeInTheDocument()
      expect(screen.getByText('Awaiting verification task')).toBeInTheDocument()
    })

    // Both the column header and the card pill include "검증 대기"; assert two
    // occurrences so a regression that drops either surface fails loudly.
    const matches = screen.getAllByText(/검증 대기/)
    expect(matches.length).toBeGreaterThanOrEqual(2)
  })

  it('does not infer external issue links from task title strings', () => {
    render(h(TaskBacklog, {}))
    expect(screen.queryByRole('link', { name: /관련 이슈 검색/ })).toBeNull()
  })
})
