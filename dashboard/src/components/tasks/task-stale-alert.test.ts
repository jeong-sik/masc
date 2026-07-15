import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { tasks } from '../../store'
import type { Task } from '../../types'

vi.mock('../../router', () => ({
  navigate: vi.fn(),
}))

import { navigate } from '../../router'
import { TaskStaleAlert } from './task-stale-alert'

const mockedNavigate = vi.mocked(navigate)

function makeTask(overrides: Partial<Task>): Task {
  return {
    id: 'task-default-001',
    title: 'Default task',
    status: 'claimed',
    priority: 3,
    created_at: '2026-05-06T00:00:00Z',
    updated_at: '2026-05-06T00:00:00Z',
    ...overrides,
  }
}

describe('TaskStaleAlert', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-05-06T01:00:00Z'))
    tasks.value = []
    mockedNavigate.mockClear()
  })

  afterEach(() => {
    cleanup()
    tasks.value = []
    mockedNavigate.mockClear()
    vi.useRealTimers()
  })

  it('renders only claimed or in-progress tasks older than the stale threshold', () => {
    tasks.value = [
      makeTask({
        id: 'task-stale-claimed',
        title: 'Stale claimed work',
        status: 'claimed',
        assignee: 'keeper-alpha',
        updated_at: '2026-05-06T00:20:00Z',
      }),
      makeTask({
        id: 'task-stale-progress',
        title: 'Stale in progress work',
        status: 'in_progress',
        assignee: 'keeper-beta',
        updated_at: '2026-05-05T23:00:00Z',
      }),
      makeTask({
        id: 'task-recent-claimed',
        title: 'Recent claim',
        status: 'claimed',
        assignee: 'keeper-alpha',
        updated_at: '2026-05-06T00:45:00Z',
      }),
      makeTask({
        id: 'task-old-todo',
        title: 'Old todo',
        status: 'todo',
        assignee: 'keeper-alpha',
        updated_at: '2026-05-05T23:00:00Z',
      }),
    ]

    render(h(TaskStaleAlert, {}))

    const region = screen.getByRole('region', { name: '오래된 태스크 점유' })
    expect(region).toHaveAttribute('aria-live', 'polite')
    expect(screen.getByRole('heading', { name: '오래 점유 중인 태스크 (2)' })).toBeInTheDocument()
    expect(screen.getByText('Stale claimed work')).toBeInTheDocument()
    expect(screen.getByText('Stale in progress work')).toBeInTheDocument()
    expect(screen.queryByText('Recent claim')).not.toBeInTheDocument()
    expect(screen.queryByText('Old todo')).not.toBeInTheDocument()
  })

  it('routes nudge and detail actions to their owning surfaces', () => {
    tasks.value = [
      makeTask({
        id: 'task-stale-claimed',
        title: 'Stale claimed work',
        status: 'claimed',
        assignee: 'keeper-alpha',
        updated_at: '2026-05-06T00:20:00Z',
      }),
    ]

    render(h(TaskStaleAlert, {}))

    fireEvent.click(screen.getByRole('button', { name: 'keeper-alpha 키퍼 상세에서 task-stale-claimed nudge' }))
    expect(mockedNavigate).toHaveBeenCalledWith('monitoring', {
      section: 'agents',
      view: 'keepers',
      keeper: 'keeper-alpha',
    })

    fireEvent.click(screen.getByRole('button', { name: '태스크 상세 패널 열기: task-stale-claimed' }))
    expect(mockedNavigate).toHaveBeenLastCalledWith('workspace', {
      section: 'planning',
      task: 'task-stale-claimed',
    })
  })

  it('does not render without stale claims', () => {
    tasks.value = [
      makeTask({
        id: 'task-recent',
        title: 'Recent task',
        status: 'claimed',
        updated_at: '2026-05-06T00:55:00Z',
      }),
    ]

    render(h(TaskStaleAlert, {}))

    expect(screen.queryByRole('region', { name: '오래된 태스크 점유' })).not.toBeInTheDocument()
  })
})
