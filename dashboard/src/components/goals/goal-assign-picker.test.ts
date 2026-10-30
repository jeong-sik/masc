// @vitest-environment happy-dom
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/preact'
import '@testing-library/jest-dom'
import { h } from 'preact'
import type { Goal } from '../../types'

const assignTaskToGoal = vi.hoisted(() => vi.fn<(t: string, g: string) => Promise<boolean>>(
  () => Promise.resolve(true),
))
vi.mock('../task-manage/task-manage-state', () => ({ assignTaskToGoal }))

import { goals } from '../../store'
import { GoalAssignPicker, activeGoals } from './goal-assign-picker'

function goal(id: string, phase: string, title = id): Goal {
  return {
    id, title, phase, priority: 0,
    created_at: '2026-09-08T00:00:00Z',
    updated_at: '2026-09-08T00:00:00Z',
  }
}

describe('activeGoals', () => {
  it('drops completed and dropped goals', () => {
    const kept = activeGoals([
      goal('g1', 'executing'),
      goal('g2', 'completed'),
      goal('g3', 'verifying'),
      goal('g4', 'dropped'),
    ])
    expect(kept.map(g => g.id)).toEqual(['g1', 'g3'])
  })

  it('keeps a phase this build does not model', () => {
    // The phase vocabulary is the server's. An unknown phase is not evidence
    // the goal is closed, so hiding it would hide a valid destination.
    expect(activeGoals([goal('g9', 'blocked')]).map(g => g.id)).toEqual(['g9'])
  })
})

describe('GoalAssignPicker', () => {
  beforeEach(() => {
    goals.value = []
    assignTaskToGoal.mockClear()
  })

  it('renders nothing when no goal is open', () => {
    goals.value = [goal('g2', 'completed')]
    const { container } = render(h(GoalAssignPicker, { taskId: 'task-1' }))
    expect(container.querySelector('[data-testid="assign-goal"]')).toBeNull()
  })

  it('offers one option per active goal', () => {
    goals.value = [goal('g1', 'executing', '결제 안정화'), goal('g2', 'completed')]
    render(h(GoalAssignPicker, { taskId: 'task-1' }))
    const select = screen.getByTestId('assign-goal') as HTMLSelectElement
    expect([...select.options].map(o => o.textContent)).toEqual(['goal에 배정', '결제 안정화'])
  })

  it('assigns the picked goal and clears the control', () => {
    goals.value = [goal('g1', 'executing')]
    render(h(GoalAssignPicker, { taskId: 'task-7' }))
    const select = screen.getByTestId('assign-goal') as HTMLSelectElement
    fireEvent.change(select, { target: { value: 'g1' } })
    expect(assignTaskToGoal).toHaveBeenCalledWith('task-7', 'g1')
    expect(select.value).toBe('')
  })

  it('does nothing when the placeholder is re-selected', () => {
    goals.value = [goal('g1', 'executing')]
    render(h(GoalAssignPicker, { taskId: 'task-7' }))
    fireEvent.change(screen.getByTestId('assign-goal'), { target: { value: '' } })
    expect(assignTaskToGoal).not.toHaveBeenCalled()
  })
})
