import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/preact'
import '@testing-library/jest-dom'
import { h } from 'preact'
import { showGoalCreate, resetGoalCreateForm, goalCreateError, goalCreating } from './goal-create-state'
import { GoalCreateForm, resetGoalCreateFormLocal } from './goal-create-form'

const api = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
  refreshGoals: vi.fn(),
  showToast: vi.fn(),
}))
vi.mock('../../api/mcp', () => ({ callMcpTool: api.callMcpTool }))
vi.mock('../../store', () => ({ refreshGoals: api.refreshGoals }))
vi.mock('../common/toast', () => ({ showToast: api.showToast }))

function fillField(id: string, value: string) {
  fireEvent.input(screen.getByTestId(id), { target: { value } })
}

describe('GoalCreateForm side panel', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    api.callMcpTool.mockResolvedValue({ goal: { id: "goal-created" } })
    api.refreshGoals.mockResolvedValue(undefined)
    goalCreating.value = false
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
    expect(screen.getByText('성공 기준이 있는 목표')).toBeTruthy()
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
  it('collects a complete success criterion before enabling creation', () => {
    render(h(GoalCreateForm, {}))
    const submit = screen.getByTestId('goal-create-submit')
    expect(submit).toBeDisabled()
    fillField('goal-create-title-input', 'Keep the scheduler responsive')
    expect(submit).toBeDisabled()
    fillField('goal-create-metric', 'scheduler p99 over 24 hours')
    expect(submit).toBeDisabled()
    fillField('goal-create-target', '   ')
    expect(submit).toBeDisabled()
    fillField('goal-create-target', '400 ms or less')
    expect(submit).not.toBeDisabled()
    expect(screen.getByLabelText(/측정 지표/)).toBeRequired()
    expect(screen.getByLabelText(/목표 값/)).toBeRequired()
    expect(api.callMcpTool).not.toHaveBeenCalled()
  })

  it('submits the operator criterion under the real tool field names and refreshes goals', async () => {
    render(h(GoalCreateForm, {}))
    fillField('goal-create-title-input', '  No dropped events  ')
    fillField('goal-create-metric', '  dropped event count in 24h  ')
    fillField('goal-create-target', '  0  ')
    fillField('goal-create-priority', '2')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.refreshGoals).toHaveBeenCalledOnce())
    expect(api.callMcpTool).toHaveBeenCalledExactlyOnceWith('masc_goal_upsert', {
      title: 'No dropped events', metric: 'dropped event count in 24h',
      target_value: '0', priority: 2,
    })
    expect(showGoalCreate.value).toBe(false)
    expect(goalCreating.value).toBe(false)
    showGoalCreate.value = true
    await screen.findByTestId('goal-create-panel')
    expect(screen.getByTestId('goal-create-title-input')).toHaveValue('')
    expect(screen.getByTestId('goal-create-metric')).toHaveValue('')
    expect(screen.getByTestId('goal-create-target')).toHaveValue('')
    expect(screen.getByTestId('goal-create-submit')).toBeDisabled()
  })

  it('keeps the entered criterion after a server refusal so the operator can correct and resubmit', async () => {
    api.callMcpTool.mockRejectedValueOnce(new Error('criterion cannot be persisted'))
    render(h(GoalCreateForm, {}))
    fillField('goal-create-title-input', 'Verify continuity')
    fillField('goal-create-metric', 'successful ten-turn runs')
    fillField('goal-create-target', 'all configured runtimes')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(screen.getByTestId('goal-create-error')).toHaveTextContent('criterion cannot be persisted'))
    expect(showGoalCreate.value).toBe(true)
    expect(screen.getByTestId('goal-create-metric')).toHaveValue('successful ten-turn runs')
    expect(screen.getByTestId('goal-create-target')).toHaveValue('all configured runtimes')
    expect(api.refreshGoals).not.toHaveBeenCalled()
    fillField('goal-create-target', '47 successful runs of ten turns each')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.refreshGoals).toHaveBeenCalledOnce())
    expect(api.callMcpTool).toHaveBeenLastCalledWith('masc_goal_upsert', {
      title: 'Verify continuity', metric: 'successful ten-turn runs',
      target_value: '47 successful runs of ten turns each', priority: 3,
    })
  })

  it.each(['created', 'rejected'] as const)('keeps a newer submitted draft when the closed draft is %s', async outcome => {
    let resolveOld!: () => void
    let rejectOld!: (error: Error) => void
    let resolveNew!: () => void
    api.callMcpTool
      .mockImplementationOnce(() => new Promise<void>((resolve, reject) => {
        resolveOld = resolve; rejectOld = reject
      }))
      .mockImplementationOnce(() => new Promise<void>(resolve => { resolveNew = resolve }))
    render(h(GoalCreateForm, {}))
    fillField('goal-create-title-input', 'Old draft')
    fillField('goal-create-metric', 'old metric')
    fillField('goal-create-target', '10')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    expect(goalCreating.value).toBe(true)
    fireEvent.click(screen.getByTestId('goal-create-close'))
    showGoalCreate.value = true
    await screen.findByTestId('goal-create-panel')
    fillField('goal-create-title-input', 'New draft')
    fillField('goal-create-metric', 'new metric')
    fillField('goal-create-target', '20')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    expect(api.callMcpTool).toHaveBeenCalledTimes(2)
    if (outcome === 'created') resolveOld()
    else rejectOld(new Error('old request rejected'))
    await waitFor(() => expect(api.showToast).toHaveBeenCalled())
    expect(showGoalCreate.value).toBe(true)
    expect(goalCreating.value).toBe(true)
    expect(goalCreateError.value).toBeNull()
    expect(screen.getByTestId('goal-create-title-input')).toHaveValue('New draft')
    expect(screen.getByTestId('goal-create-metric')).toHaveValue('new metric')
    expect(screen.getByTestId('goal-create-target')).toHaveValue('20')
    resolveNew()
    await waitFor(() => expect(showGoalCreate.value).toBe(false))
    await waitFor(() => expect(goalCreating.value).toBe(false))
    expect(api.refreshGoals).toHaveBeenCalledTimes(outcome === 'created' ? 2 : 1)
  })

})
