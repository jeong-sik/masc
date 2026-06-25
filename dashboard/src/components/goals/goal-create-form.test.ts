import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/preact'
import '@testing-library/jest-dom'
import { h } from 'preact'
import { keepers } from '../../store'
import { showGoalCreate, resetGoalCreateForm } from './goal-create-state'
import { GoalCreateForm, resetGoalCreateFormLocal } from './goal-create-form'

// Mock KeeperBadge so tests don't depend on avatar internals.
vi.mock('../keeper-badge', () => ({
  KeeperBadge: ({ id }: { id: string }) => h('span', { 'data-testid': `keeper-badge-${id}` }, id[0]?.toUpperCase()),
}))

describe('GoalCreateForm side panel', () => {
  beforeEach(() => {
    showGoalCreate.value = true
    resetGoalCreateForm()
    resetGoalCreateFormLocal()
    keepers.value = [
      { name: 'alpha', agent_name: 'alpha-agent', status: 'active' },
      { name: 'beta', agent_name: 'beta-agent', status: 'active' },
    ]
  })

  afterEach(() => {
    showGoalCreate.value = false
    keepers.value = []
  })

  it('renders the side panel header and eyebrow', () => {
    render(h(GoalCreateForm, {}))
    expect(screen.getByTestId('goal-create-panel')).toBeTruthy()
    expect(screen.getByText('goal store · create')).toBeTruthy()
    expect(screen.getByText('새 목표')).toBeTruthy()
  })

  it('selects 장기 horizon by default', () => {
    render(h(GoalCreateForm, {}))
    const longButton = screen.getByRole('radio', { name: '장기' })
    expect(longButton).toHaveAttribute('aria-checked', 'true')
  })

  it('switches horizon chips on click', () => {
    render(h(GoalCreateForm, {}))
    const shortButton = screen.getByRole('radio', { name: '단기' })
    fireEvent.click(shortButton)
    expect(shortButton).toHaveAttribute('aria-checked', 'true')
    expect(screen.getByRole('radio', { name: '장기' })).toHaveAttribute('aria-checked', 'false')
  })

  it('renders a priority slider with default P3', () => {
    render(h(GoalCreateForm, {}))
    const slider = screen.getByTestId('goal-create-priority') as HTMLInputElement
    expect(slider).toBeTruthy()
    expect(slider.type).toBe('range')
    expect(slider.value).toBe('3')
  })

  it('updates the priority label when the slider moves', () => {
    render(h(GoalCreateForm, {}))
    const slider = screen.getByTestId('goal-create-priority') as HTMLInputElement
    fireEvent.input(slider, { target: { value: '1' } })
    expect(slider.value).toBe('1')
    expect(screen.getByText('P1')).toBeTruthy()
  })

  it('shows the risk readout', () => {
    render(h(GoalCreateForm, {}))
    expect(screen.getByText('Safe')).toBeTruthy()
    expect(screen.getByText('가드 통과 · 자율 실행')).toBeTruthy()
  })

  it('renders the lead keeper grid with an unassigned option', () => {
    render(h(GoalCreateForm, {}))
    expect(screen.getByRole('button', { name: '미지정' })).toBeTruthy()
    expect(screen.getByText('alpha')).toBeTruthy()
    expect(screen.getByText('beta')).toBeTruthy()
  })

  it('selects a lead keeper on click', () => {
    render(h(GoalCreateForm, {}))
    const alphaButton = screen.getByRole('button', { name: 'alpha' })
    fireEvent.click(alphaButton)
    expect(alphaButton.className).toContain('on')
  })

  it('closes the panel when the close button is clicked', () => {
    render(h(GoalCreateForm, {}))
    fireEvent.click(screen.getByTestId('goal-create-close'))
    expect(showGoalCreate.value).toBe(false)
  })
})
