import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/preact'
import '@testing-library/jest-dom'
import { h } from 'preact'
import { showGoalCreate, resetGoalCreateForm, goalCreateError } from './goal-create-state'
import { GoalCreateForm, resetGoalCreateFormLocal } from './goal-create-form'

describe('GoalCreateForm side panel', () => {
  beforeEach(() => {
    showGoalCreate.value = true
    resetGoalCreateForm()
    resetGoalCreateFormLocal()
  })

  afterEach(() => {
    showGoalCreate.value = false
  })

  it('renders the side panel header and eyebrow', () => {
    render(h(GoalCreateForm, {}))
    expect(screen.getByTestId('goal-create-panel')).toBeTruthy()
    expect(screen.getByText('goal store · create')).toBeTruthy()
    expect(screen.getByText('새 목표')).toBeTruthy()
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

  it('does not fabricate a derived execution status', () => {
    render(h(GoalCreateForm, {}))
    expect(screen.queryByText('Safe')).toBeNull()
    expect(screen.queryByText('가드 통과 · 자율 실행')).toBeNull()
  })

  it('does not render removed horizon or lead keeper fields', () => {
    render(h(GoalCreateForm, {}))
    expect(screen.queryByRole('radiogroup', { name: '호라이즌' })).toBeNull()
    expect(screen.queryByText('리드 KEEPER')).toBeNull()
  })

  it('closes the panel when the close button is clicked', () => {
    render(h(GoalCreateForm, {}))
    fireEvent.click(screen.getByTestId('goal-create-close'))
    expect(showGoalCreate.value).toBe(false)
  })

  it('renders a title-empty error by discriminant instead of string matching', () => {
    goalCreateError.value = { kind: 'title_empty' }
    render(h(GoalCreateForm, {}))
    expect(screen.getByTestId('goal-create-title-error')).toHaveTextContent('제목을 입력하세요')
    expect(screen.queryByTestId('goal-create-error')).toBeNull()
  })

  it('renders a submit error by discriminant and hides the title-empty error', () => {
    goalCreateError.value = { kind: 'submit', message: 'backend rejected goal' }
    render(h(GoalCreateForm, {}))
    expect(screen.getByTestId('goal-create-error')).toHaveTextContent('backend rejected goal')
    expect(screen.queryByTestId('goal-create-title-error')).toBeNull()
  })
})
