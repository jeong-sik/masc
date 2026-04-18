import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import '@testing-library/jest-dom'
import { TaskBacklog, resetTaskBacklogState } from './kanban-components'
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
    tasks.value = []
    executionLoaded.value = false
    executionLoading.value = false
    executionError.value = null
    resetTaskSearch()
    resetTaskBacklogState()
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
})
