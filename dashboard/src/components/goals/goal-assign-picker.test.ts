// @vitest-environment happy-dom
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/preact'
import '@testing-library/jest-dom'
import { h } from 'preact'
import type { Goal } from '../../types'

const assignTaskToGoal = vi.hoisted(() => vi.fn<(t: string, g: string, source: unknown) => Promise<boolean>>(
  () => Promise.resolve(true),
))
const showToast = vi.hoisted(() => vi.fn())
vi.mock('../task-manage/task-manage-state', () => ({ assignTaskToGoal }))
vi.mock('../common/toast', () => ({ showToast }))

import { goals, goalIdentityObservation } from '../../store'
import { GoalAssignAvailability, GoalAssignPicker, activeGoals } from './goal-assign-picker'
import { observeGoalIds } from '../../lib/goal-identity'

function goal(id: string, phase: string, title = id): Goal {
  return {
    id, title, phase, priority: 0,
    created_at: '2026-09-08T00:00:00Z',
    updated_at: '2026-09-08T00:00:00Z',
  }
}

function setGoals(rows: Goal[], raw: unknown = rows) {
  goals.value = rows
  goalIdentityObservation.value = { goals: rows, observation: observeGoalIds(raw) }
}

function observedActiveGoals(rows: Goal[]): Goal[] {
  return activeGoals(rows, observeGoalIds(rows))
}

function assignmentSource() {
  const identity = goalIdentityObservation.value!
  return { goals: identity.goals, observation: identity.observation,
    workspace: { basePath: '/workspace', mascRoot: '/workspace/.masc' },
    identity: { revision: 1, actor: 'dashboard' },
    isOwnerCurrent: () => true, refreshAfterWrite: () => true,
    isCurrent: () => goalIdentityObservation.value === identity && goals.value === identity.goals }
}

describe('activeGoals', () => {
  it('drops completed and dropped goals', () => {
    const kept = observedActiveGoals([
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
    expect(observedActiveGoals([goal('g9', 'blocked')]).map(g => g.id)).toEqual(['g9'])
  })

  it('withholds both sides of an observed alias, including a closed alias', () => {
    const kept = observedActiveGoals([
      goal('g1', 'executing'), goal(' g1 ', 'completed'), goal('g2', 'executing'),
      goal('g3', 'executing'), goal('g3', 'executing'),
    ])
    expect(kept.map(g => g.id)).toEqual(['g2'])
  })
})

describe('GoalAssignPicker', () => {
  beforeEach(() => {
    setGoals([])
    assignTaskToGoal.mockClear()
    showToast.mockClear()
  })

  it('renders nothing when no goal is open', () => {
    setGoals([goal('g2', 'completed')])
    const { container } = render(h(GoalAssignPicker, { taskId: 'task-1', source: assignmentSource() }))
    expect(container.querySelector('[data-testid="assign-goal"]')).toBeNull()
  })

  it('explains when incomplete or ambiguous identity observations prevent assignment', () => {
    const rows = [goal('g1', 'executing')]
    setGoals(rows, [{ id: 'g1' }, { title: 'missing id' }])
    const { rerender } = render(h(GoalAssignAvailability, { source: assignmentSource() }))
    expect(screen.getByRole('status').textContent).toContain('Goal ID')
    expect(screen.queryByTestId('assign-goal')).toBeNull()
    setGoals(rows, [{ id: 'g1' }, { id: ' g1 ' }])
    rerender(h(GoalAssignAvailability, { source: assignmentSource() }))
    expect(screen.getByRole('status').textContent).toContain('Goal ID')
    expect(assignTaskToGoal).not.toHaveBeenCalled()
  })

  it('offers one option per active goal', () => {
    setGoals([goal('g1', 'executing', '결제 안정화'), goal('g2', 'completed')])
    render(h(GoalAssignPicker, { taskId: 'task-1', source: assignmentSource() }))
    const select = screen.getByTestId('assign-goal') as HTMLSelectElement
    expect([...select.options].map(o => o.textContent)).toEqual(['goal에 배정', '결제 안정화'])
  })

  it('assigns the picked goal and clears the control', () => {
    setGoals([goal('g1', 'executing')])
    const source = assignmentSource()
    render(h(GoalAssignPicker, { taskId: 'task-7', source }))
    const select = screen.getByTestId('assign-goal') as HTMLSelectElement
    fireEvent.change(select, { target: { value: 'g1' } })
    expect(assignTaskToGoal).toHaveBeenCalledWith('task-7', 'g1', source)
    expect(select.value).toBe('')
  })

  it('does nothing when the placeholder is re-selected', () => {
    setGoals([goal('g1', 'executing')])
    render(h(GoalAssignPicker, { taskId: 'task-7', source: assignmentSource() }))
    fireEvent.change(screen.getByTestId('assign-goal'), { target: { value: '' } })
    expect(assignTaskToGoal).not.toHaveBeenCalled()
  })

  it('rechecks the observed list before acting on a stale selection', () => {
    setGoals([goal('g1', 'executing')])
    render(h(GoalAssignPicker, { taskId: 'task-7', source: assignmentSource() }))
    const select = screen.getByTestId('assign-goal') as HTMLSelectElement
    setGoals([goal('g1', 'executing'), goal(' g1 ', 'completed')])
    fireEvent.change(select, { target: { value: 'g1' } })
    expect(assignTaskToGoal).not.toHaveBeenCalled()
    expect(showToast).toHaveBeenCalledWith(expect.stringContaining('목록이 바뀌었거나'), 'warning')
  })

  it('does not offer an ID duplicated by a row discarded during display decoding', () => {
    setGoals([goal('g1', 'executing'), goal('g2', 'executing')],
      [{ id: 'g1' }, { id: 'g1', title: '' }, { id: 'g2' }])
    render(h(GoalAssignPicker, { taskId: 'task-7', source: assignmentSource() }))
    const select = screen.getByTestId('assign-goal') as HTMLSelectElement
    expect([...select.options].map(option => option.value)).toEqual(['', 'g2'])
  })
})
