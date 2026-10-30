import { h } from 'preact'
import { cleanup, fireEvent, render, screen, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { tasks } from '../../store'
import type { Task } from '../../types'

vi.mock('../../router', () => ({
  navigate: vi.fn(),
}))

import { navigate } from '../../router'
import { TaskWall } from './task-wall'

const mockedNavigate = vi.mocked(navigate)

function makeTask(overrides: Partial<Task>): Task {
  return {
    id: 'task-default-001',
    title: 'Default task',
    status: 'todo',
    priority: 3,
    created_at: '2026-05-06T00:00:00Z',
    updated_at: '2026-05-06T00:00:00Z',
    ...overrides,
  }
}

describe('TaskWall', () => {
  beforeEach(() => {
    tasks.value = []
    mockedNavigate.mockClear()
  })

  afterEach(() => {
    cleanup()
    tasks.value = []
    mockedNavigate.mockClear()
  })

  it('groups active tasks by keeper and hides historical tasks', () => {
    tasks.value = [
      makeTask({
        id: 'task-alpha-low',
        title: 'Alpha lower priority',
        status: 'in_progress',
        priority: 4,
        assignee: 'keeper-alpha',
      }),
      makeTask({
        id: 'task-alpha-high',
        title: 'Alpha higher priority',
        status: 'claimed',
        priority: 1,
        assignee: 'keeper-alpha',
      }),
      makeTask({
        id: 'task-unassigned',
        title: 'Needs owner',
        status: 'todo',
        priority: 2,
      }),
      makeTask({
        id: 'task-hidden-done',
        title: 'Done should not be visible',
        status: 'done',
        assignee: 'keeper-beta',
      }),
      makeTask({
        id: 'task-hidden-cancelled',
        title: 'Cancelled should not be visible',
        status: 'cancelled',
        assignee: 'keeper-beta',
      }),
    ]

    render(h(TaskWall, {}))

    const region = screen.getByRole('region', { name: '키퍼별 태스크 월' })
    expect(region).toBeInTheDocument()
    expect(region).toHaveClass('v2-workspace-panel')
    expect(screen.getByText('2 키퍼 · 진행 중 3 건')).toBeInTheDocument()
    expect(screen.getByLabelText('keeper-alpha 태스크 2건')).toBeInTheDocument()
    expect(screen.getByLabelText('미할당 태스크 1건')).toBeInTheDocument()
    expect(screen.queryByText('Done should not be visible')).not.toBeInTheDocument()
    expect(screen.queryByText('Cancelled should not be visible')).not.toBeInTheDocument()

    const alphaColumn = screen.getByLabelText('keeper-alpha 태스크 2건')
    const alphaButtons = within(alphaColumn).getAllByRole('button')
    expect(alphaButtons[0]).toHaveAccessibleName(
      '태스크 task-alpha-high 열기: Alpha higher priority',
    )
    expect(alphaButtons[1]).toHaveAccessibleName('태스크 task-alpha-low 열기: Alpha lower priority')
  })

  it('opens the selected task in planning', () => {
    tasks.value = [
      makeTask({
        id: 'task-open-target',
        title: 'Open target',
        status: 'claimed',
        assignee: 'keeper-alpha',
      }),
    ]

    render(h(TaskWall, {}))

    fireEvent.click(screen.getByRole('button', { name: '태스크 task-open-target 열기: Open target' }))

    expect(mockedNavigate).toHaveBeenCalledWith('workspace', {
      section: 'planning',
      task: 'task-open-target',
    })
  })

  it('does not render when no active task is assigned or queued', () => {
    tasks.value = [
      makeTask({
        id: 'task-only-done',
        title: 'Only done',
        status: 'done',
      }),
    ]

    render(h(TaskWall, {}))

    expect(screen.queryByRole('region', { name: '키퍼별 태스크 월' })).not.toBeInTheDocument()
  })
})
