import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/preact'
import '@testing-library/jest-dom'
import { h } from 'preact'
import { createGoal, showGoalCreate, resetGoalCreateForm, goalCreateError, goalCreating, goalCreateOutcomes, _testResetGoalCreateOutcomes } from './goal-create-state'
import { GoalCreateForm, resetGoalCreateFormLocal } from './goal-create-form'
import { executionWorkspaceAuthority } from '../../store'
import { clearStoredToken, currentStoredTokenRevision, setStoredToken } from '../../api/core'
import { recordManagedCredentialRefusal, resetDashboardSessionActorForTests, setCanonicalDashboardActor } from '../../lib/dashboard-session-actor'

const api = vi.hoisted(() => ({
  callMcpToolAtIdentity: vi.fn(),
  mcpCallFailureDisposition: vi.fn(),
  mcpStructuredContentFromError: vi.fn(),
  captureArtifactWorkspace: vi.fn(),
  refreshGoals: vi.fn(),
  showToast: vi.fn(),
}))
vi.mock('../../api/mcp', () => ({ callMcpToolAtIdentity: api.callMcpToolAtIdentity,
  mcpCallFailureDisposition: api.mcpCallFailureDisposition, mcpStructuredContentFromError: api.mcpStructuredContentFromError }))
vi.mock('../../api/published-artifacts', async original => ({
  ...await original<typeof import('../../api/published-artifacts')>(), captureArtifactWorkspace: api.captureArtifactWorkspace,
}))
vi.mock('../../store', async () => {
  const { signal } = await import('@preact/signals')
  return { refreshGoals: api.refreshGoals, executionWorkspaceAuthority: signal(null) }
})
vi.mock('../common/toast', () => ({ showToast: api.showToast }))

function fillField(id: string, value: string) {
  fireEvent.input(screen.getByTestId(id), { target: { value } })
}

const ownedWorkspace = { currentWorkspace: { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' },
  isWorkspaceCurrent: () => true }

describe('GoalCreateForm side panel', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    clearStoredToken()
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 1 }
    api.captureArtifactWorkspace.mockResolvedValue({ basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' })
    api.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    api.callMcpToolAtIdentity.mockImplementation(async (_name, args) => JSON.stringify({
      status: 'ok', action: 'created', goal_id: args.id, goal: { id: args.id },
    }))
    api.refreshGoals.mockResolvedValue(undefined)
    goalCreating.value = false
    showGoalCreate.value = true
    resetGoalCreateForm()
    resetGoalCreateFormLocal()
    _testResetGoalCreateOutcomes()
  })

  afterEach(() => {
    showGoalCreate.value = false
    resetDashboardSessionActorForTests()
  })

  it('renders the side panel header and eyebrow', () => {
    render(h(GoalCreateForm, ownedWorkspace))
    expect(screen.getByTestId('goal-create-panel')).toBeTruthy()
    expect(screen.getByText('성공 기준이 있는 목표')).toBeTruthy()
    expect(screen.getByText('새 목표')).toBeTruthy()
  })

  it('renders a priority slider with default P3', () => {
    render(h(GoalCreateForm, ownedWorkspace))
    const slider = screen.getByTestId('goal-create-priority') as HTMLInputElement
    expect(slider).toBeTruthy()
    expect(slider.type).toBe('range')
    expect(slider.value).toBe('3')
  })

  it('updates the priority label when the slider moves', () => {
    render(h(GoalCreateForm, ownedWorkspace))
    const slider = screen.getByTestId('goal-create-priority') as HTMLInputElement
    fireEvent.input(slider, { target: { value: '1' } })
    expect(slider.value).toBe('1')
    expect(screen.getByText('P1')).toBeTruthy()
  })

  it('does not fabricate a derived execution status', () => {
    render(h(GoalCreateForm, ownedWorkspace))
    expect(screen.queryByText('Safe')).toBeNull()
    expect(screen.queryByText('가드 통과 · 자율 실행')).toBeNull()
  })

  it.each([{ isComposing: true }, { keyCode: 229 }, { consumed: true }])('keeps the goal draft when Escape is owned (%o)', async (flags) => {
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Draft goal')
    await new Promise(resolve => setTimeout(resolve, 0))
    const input = screen.getByTestId('goal-create-title-input') as HTMLInputElement
    const event = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true, ...flags })
    if ('consumed' in flags) event.preventDefault()
    fireEvent(input, event)
    expect(showGoalCreate.value).toBe(true)
    expect(input.value).toBe('Draft goal')
    expect(api.callMcpToolAtIdentity).not.toHaveBeenCalled()
    fireEvent.keyDown(input, { key: 'Escape' })
    expect(showGoalCreate.value).toBe(false)
  })

  it('closes the panel when the close button is clicked', () => {
    render(h(GoalCreateForm, ownedWorkspace))
    fireEvent.click(screen.getByTestId('goal-create-close'))
    expect(showGoalCreate.value).toBe(false)
  })

  it('renders a title-empty error by discriminant instead of string matching', () => {
    goalCreateError.value = { kind: 'title_empty' }
    render(h(GoalCreateForm, ownedWorkspace))
    expect(screen.getByTestId('goal-create-title-error')).toHaveTextContent('제목을 입력하세요')
    expect(screen.queryByTestId('goal-create-error')).toBeNull()
  })

  it('renders a submit error by discriminant and hides the title-empty error', () => {
    goalCreateError.value = { kind: 'submit', message: 'backend rejected goal' }
    render(h(GoalCreateForm, ownedWorkspace))
    expect(screen.getByTestId('goal-create-error')).toHaveTextContent('backend rejected goal')
    expect(screen.queryByTestId('goal-create-title-error')).toBeNull()
  })
  it('collects a complete success criterion before enabling creation', () => {
    render(h(GoalCreateForm, ownedWorkspace))
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
    expect(api.callMcpToolAtIdentity).not.toHaveBeenCalled()
  })

  it('rechecks an owned store refusal when the submit event fires', () => {
    let unavailable = false
    render(h(GoalCreateForm, { source: { kind: 'ready' }, isStoreUnavailableNow: () => unavailable }))
    fillField('goal-create-title-input', 'A goal')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    expect(screen.getByTestId('goal-create-submit')).not.toBeDisabled()
    unavailable = true
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    expect(api.callMcpToolAtIdentity).not.toHaveBeenCalled()
  })

  it('submits the operator criterion under the real tool field names and refreshes goals', async () => {
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', '  No dropped events  ')
    fillField('goal-create-metric', '  dropped event count in 24h  ')
    fillField('goal-create-target', '  0  ')
    fillField('goal-create-priority', '2')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.refreshGoals).toHaveBeenCalledOnce())
    expect(api.callMcpToolAtIdentity).toHaveBeenCalledExactlyOnceWith('masc_goal_upsert', expect.objectContaining({
      id: expect.stringMatching(/^goal-/), if_absent: true,
      expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
      title: 'No dropped events', metric: 'dropped event count in 24h',
      target_value: '0', priority: 2,
    }), { revision: expect.any(Number), actor: expect.any(String) }, expect.any(Function), expect.any(Function), expect.any(Function))
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
    api.mcpCallFailureDisposition.mockReturnValue('known_pre_effect')
    api.callMcpToolAtIdentity.mockRejectedValueOnce(new Error('criterion cannot be persisted'))
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Verify continuity')
    fillField('goal-create-metric', 'successful ten-turn runs')
    fillField('goal-create-target', 'all configured runtimes')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(screen.getByTestId('goal-create-error')).toHaveTextContent('생성 전에 요청이 거절'))
    expect(showGoalCreate.value).toBe(true)
    expect(screen.getByTestId('goal-create-metric')).toHaveValue('successful ten-turn runs')
    expect(screen.getByTestId('goal-create-target')).toHaveValue('all configured runtimes')
    expect(api.refreshGoals).not.toHaveBeenCalled()
    fillField('goal-create-target', '47 successful runs of ten turns each')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.refreshGoals).toHaveBeenCalledOnce())
    expect(api.callMcpToolAtIdentity).toHaveBeenLastCalledWith('masc_goal_upsert', expect.objectContaining({
      title: 'Verify continuity', metric: 'successful ten-turn runs',
      target_value: '47 successful runs of ten turns each', priority: 3,
    }), expect.any(Object), expect.any(Function), expect.any(Function), expect.any(Function))
  })

  it('does not send if the workspace or source changes during capture', async () => {
    let resolveWorkspace!: (workspace: { basePath: string; mascRoot: string }) => void
    api.captureArtifactWorkspace.mockImplementationOnce(() => new Promise(resolve => { resolveWorkspace = resolve }))
    let unavailable = false
    render(h(GoalCreateForm, { source: { kind: 'ready' }, isStoreUnavailableNow: () => unavailable }))
    fillField('goal-create-title-input', 'Captured goal')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.captureArtifactWorkspace).toHaveBeenCalledTimes(1))
    unavailable = true
    resolveWorkspace({ basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' })
    await waitFor(() => expect(goalCreating.value).toBe(false))
    expect(api.callMcpToolAtIdentity).not.toHaveBeenCalled()
    expect(screen.getByTestId('goal-create-title-input')).toHaveValue('Captured goal')
  })

  it('does not treat a late creation as current after the actor changes away and back', async () => {
    setCanonicalDashboardActor('actor-a')
    let resolveCreate!: (value: string) => void
    let sentId = ''
    api.callMcpToolAtIdentity.mockImplementationOnce((_name, args) => {
      sentId = args.id
      return new Promise(resolve => { resolveCreate = resolve })
    })
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Actor-owned draft')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1))
    setCanonicalDashboardActor('actor-b')
    setCanonicalDashboardActor('actor-a')
    resolveCreate(JSON.stringify({ status: 'ok', action: 'created', goal_id: sentId, goal: { id: sentId } }))
    await waitFor(() => expect(goalCreating.value).toBe(false))
    expect(goalCreateOutcomes.value[0]?.state).toBe('created')
    expect(showGoalCreate.value).toBe(true)
    expect(screen.getByTestId('goal-create-title-input')).toHaveValue('Actor-owned draft')
    expect(screen.queryByTestId('goal-create-outcome')).toBeNull()
    expect(screen.getByTestId('goal-create-earlier-outcome')).not.toHaveTextContent(sentId)
    expect(screen.getByTestId('goal-create-submit')).toBeDisabled()
    await expect(createGoal({ title: 'Actor-owned draft', metric: 'metric', targetValue: 'target', priority: 3 }))
      .resolves.toBe(false)
    expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1)
    expect(api.refreshGoals).not.toHaveBeenCalled()
  })

  it('keeps the same managed creation current when its actor is hydrated', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let resolveCreate!: (value: string) => void
    let sentId = ''
    api.callMcpToolAtIdentity.mockImplementationOnce((_name, args) => {
      sentId = args.id
      return new Promise(resolve => { resolveCreate = resolve })
    })
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'One managed Goal')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1))
    setCanonicalDashboardActor('dashboard')
    await screen.findByTestId('goal-create-outcome')
    expect(screen.getByTestId('goal-create-submit')).toBeDisabled()
    expect(screen.getByTestId('goal-create-outcome')).toHaveTextContent(sentId)
    resolveCreate(JSON.stringify({ status: 'ok', action: 'created', goal_id: sentId, goal: { id: sentId } }))
    await waitFor(() => expect(goalCreating.value).toBe(false))
    expect(showGoalCreate.value).toBe(false)
    expect(api.refreshGoals).toHaveBeenCalledOnce()
    expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1)
  })

  it('continues a managed creation when its actor is hydrated during the workspace read', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let resolveWorkspace!: (workspace: { basePath: string; mascRoot: string }) => void
    api.captureArtifactWorkspace.mockImplementationOnce(() => new Promise(resolve => { resolveWorkspace = resolve }))
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Managed workspace read')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.captureArtifactWorkspace).toHaveBeenCalledTimes(1))
    setCanonicalDashboardActor('dashboard')
    resolveWorkspace({ basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' })
    await waitFor(() => expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(showGoalCreate.value).toBe(false))
    expect(api.refreshGoals).toHaveBeenCalledOnce()
  })

  it.each(['unverified', 'verified'] as const)('retires a managed creation after a %s credential is refused', async initial => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    if (initial === 'verified') setCanonicalDashboardActor('dashboard')
    let resolveCreate!: (value: string) => void
    let sentId = ''
    api.callMcpToolAtIdentity.mockImplementationOnce((_name, args) => {
      sentId = args.id
      return new Promise(resolve => { resolveCreate = resolve })
    })
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Refused owner')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1))
    setCanonicalDashboardActor(null, { tokenRevision: currentStoredTokenRevision(), rejected: true })
    await screen.findByTestId('goal-create-earlier-outcome')
    resolveCreate(JSON.stringify({ status: 'ok', action: 'created', goal_id: sentId, goal: { id: sentId } }))
    await waitFor(() => expect(goalCreating.value).toBe(false))
    expect(showGoalCreate.value).toBe(true)
    expect(screen.getByTestId('goal-create-earlier-outcome')).not.toHaveTextContent(sentId)
    expect(screen.getByTestId('goal-create-submit')).toBeDisabled()
    expect(api.refreshGoals).not.toHaveBeenCalled()
  })

  it('does not dispatch a new draft with a refused managed credential', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    recordManagedCredentialRefusal(currentStoredTokenRevision())
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'New draft')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    expect(screen.getByTestId('goal-create-submit')).toBeDisabled()
    await expect(createGoal({ title: 'New draft', metric: 'metric', targetValue: 'target', priority: 3 })).resolves.toBe(false)
    expect(api.callMcpToolAtIdentity).not.toHaveBeenCalled()
  })

  it.each(['same', 'different', 'retired'] as const)('checks the %s workspace before recovering a refused creation', async result => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let view: 'current' | 'unconfirmed' = 'current'
    let recovered = false
    api.captureArtifactWorkspace.mockResolvedValueOnce({ basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' })
      .mockImplementationOnce(async () => {
        if (result === 'retired') {
          ;(executionWorkspaceAuthority as { value: unknown }).value =
            { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
        }
        return { basePath: '/workspace-a', mascRoot: result === 'different' ? '/different/.masc' : '/workspace-a/.masc' }
      })
    api.callMcpToolAtIdentity.mockImplementationOnce(async (_name, _args, _identity, _canSend, recoveryCurrent, waitForRecoveryCurrent) => {
      recordManagedCredentialRefusal(currentStoredTokenRevision())
      view = 'unconfirmed'
      expect(recoveryCurrent()).toBe(false)
      recovered = await waitForRecoveryCurrent()
      expect(recoveryCurrent()).toBe(result === 'same')
      throw new Error('refused')
    })
    await createGoal({ title: 'Recovery', metric: 'metric', targetValue: 'target', priority: 3 }, () => false, () => view)
    expect(recovered).toBe(result === 'same')
    expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1)
    expect(api.captureArtifactWorkspace).toHaveBeenCalledTimes(2)
    expect(api.refreshGoals).not.toHaveBeenCalled()
  })

  it('does not send to the captured root after the view moves under the same connection', async () => {
    let resolveWorkspace!: (workspace: { basePath: string; mascRoot: string }) => void
    api.captureArtifactWorkspace.mockImplementationOnce(() => new Promise(resolve => { resolveWorkspace = resolve }))
    const { rerender } = render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Captured goal')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.captureArtifactWorkspace).toHaveBeenCalledTimes(1))
    rerender(h(GoalCreateForm, { currentWorkspace: { basePath: '/workspace-b', mascRoot: '/workspace-b/.masc' },
      isWorkspaceCurrent: () => true }))
    resolveWorkspace({ basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' })
    await waitFor(() => expect(goalCreating.value).toBe(false))
    expect(api.callMcpToolAtIdentity).not.toHaveBeenCalled()
    expect(screen.getByTestId('goal-create-title-input')).toHaveValue('Captured goal')
  })

  it('allows correction after a typed pre-commit validation refusal', async () => {
    api.callMcpToolAtIdentity.mockRejectedValueOnce(new Error('rejected'))
    api.mcpCallFailureDisposition.mockReturnValue('known_tool_response')
    api.mcpStructuredContentFromError.mockReturnValue({ status: 'error', error_code: 'validation_error', message: 'criterion is required' })
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Refused goal')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(screen.getByTestId('goal-create-error')).toHaveTextContent('criterion is required'))
    expect(screen.getByTestId('goal-create-submit')).not.toBeDisabled()
    expect(screen.queryByTestId('goal-create-outcome')).toBeNull()
    expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1)
  })

  it.each(['malformed', 'timeout'] as const)('keeps a %s outcome uncertain and prevents automatic resubmission', async kind => {
    if (kind === 'malformed') api.callMcpToolAtIdentity.mockResolvedValueOnce('{"status":"ok","action":"updated"}')
    else api.callMcpToolAtIdentity.mockRejectedValueOnce(new Error('connection closed'))
    const workspace = { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }
    render(h(GoalCreateForm, { currentWorkspace: workspace, isWorkspaceCurrent: () => true }))
    fillField('goal-create-title-input', 'Uncertain goal')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(screen.getByTestId('goal-create-error')).toHaveTextContent('생성 결과를 확인하지 못했습니다'))
    expect(screen.getByTestId('goal-create-submit')).toBeDisabled()
    expect(screen.getByTestId('goal-create-outcome').textContent).toContain('요청한 Goal ID: goal-')
    expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1)
    expect(api.refreshGoals).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: '안내 닫기' }))
    expect(screen.getByTestId('goal-create-submit')).not.toBeDisabled()
    expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1)
  })

  it('keeps a newer workspace draft after an earlier workspace returns success', async () => {
    let resolveOld!: (value: string) => void
    let sentId = ''
    api.callMcpToolAtIdentity.mockImplementationOnce((_name, args) => {
      sentId = args.id
      return new Promise(resolve => { resolveOld = resolve })
    })
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Original workspace draft')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    resolveOld(JSON.stringify({ status: 'ok', action: 'created', goal_id: sentId, goal: { id: sentId } }))
    await waitFor(() => expect(goalCreating.value).toBe(false))
    expect(showGoalCreate.value).toBe(true)
    expect(screen.getByTestId('goal-create-title-input')).toHaveValue('Original workspace draft')
    expect(screen.queryByTestId('goal-create-outcome')).toBeNull()
    expect(api.refreshGoals).not.toHaveBeenCalled()
    expect(api.showToast).not.toHaveBeenCalledWith(expect.anything(), 'success')
  })

  it('does not close or refresh a different workspace under the same connection', async () => {
    let resolveOld!: (value: string) => void
    let sentId = ''
    api.callMcpToolAtIdentity.mockImplementationOnce((_name, args) => {
      sentId = args.id
      return new Promise(resolve => { resolveOld = resolve })
    })
    const { rerender } = render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Workspace A goal')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1))
    rerender(h(GoalCreateForm, { currentWorkspace: { basePath: '/workspace-b', mascRoot: '/workspace-b/.masc' },
      isWorkspaceCurrent: () => true }))
    resolveOld(JSON.stringify({ status: 'ok', action: 'created', goal_id: sentId, goal: { id: sentId } }))
    await waitFor(() => expect(goalCreating.value).toBe(false))
    expect(showGoalCreate.value).toBe(true)
    expect(screen.getByTestId('goal-create-title-input')).toHaveValue('Workspace A goal')
    expect(screen.getByTestId('goal-create-submit')).toBeDisabled()
    expect(screen.getByTestId('goal-create-outcome')).not.toHaveTextContent(sentId)
    expect(api.refreshGoals).not.toHaveBeenCalled()
  })

  it('retains a successful receipt when the current workspace is unconfirmed', async () => {
    render(h(GoalCreateForm, { source: { kind: 'unconfirmed' } }))
    fillField('goal-create-title-input', 'Unconfirmed view goal')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(goalCreating.value).toBe(false))
    expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1)
    expect(showGoalCreate.value).toBe(true)
    expect(screen.getByTestId('goal-create-outcome')).toHaveTextContent('서버가 목표 생성 요청에 응답했습니다')
    expect(screen.getByTestId('goal-create-submit')).toBeDisabled()
    expect(api.refreshGoals).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: '안내 닫기' }))
    expect(screen.getByTestId('goal-create-submit')).not.toBeDisabled()
  })

  it('blocks the same draft after a connection changes until the previous outcome is acknowledged', async () => {
    api.callMcpToolAtIdentity.mockRejectedValueOnce(new Error('connection closed'))
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Old connection goal')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(screen.getByTestId('goal-create-error')).toHaveTextContent('생성 결과를 확인하지 못했습니다'))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(screen.getByTestId('goal-create-earlier-outcome')).toBeInTheDocument())
    expect(screen.getByTestId('goal-create-submit')).toBeDisabled()
    expect(screen.queryByTestId('goal-create-error')).toBeNull()
    expect(screen.queryByTestId('goal-create-outcome')).toBeNull()
    expect(screen.getByTestId('goal-create-earlier-outcome').textContent).not.toContain('connection closed')
    fireEvent.click(screen.getByRole('button', { name: '이전 요청 확인 후 안내 닫기' }))
    expect(screen.getByTestId('goal-create-submit')).not.toBeDisabled()
    expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1)
  })

  it('does not turn a successful creation into a failure when refresh rejects', async () => {
    api.refreshGoals.mockRejectedValueOnce(new Error('refresh unavailable'))
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Created goal')
    fillField('goal-create-metric', 'metric')
    fillField('goal-create-target', 'target')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(showGoalCreate.value).toBe(false))
    expect(goalCreateError.value).toBeNull()
    expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1)
  })

  it.each(['created', 'rejected'] as const)('keeps a newer submitted draft when the closed draft is %s', async outcome => {
    let resolveOld!: () => void
    let rejectOld!: (error: Error) => void
    let resolveNew!: () => void
    api.callMcpToolAtIdentity
      .mockImplementationOnce((_name, args) => new Promise<string>((resolve, reject) => {
        resolveOld = () => resolve(JSON.stringify({ status: 'ok', action: 'created', goal_id: args.id, goal: { id: args.id } }))
        rejectOld = reject
      }))
      .mockImplementationOnce((_name, args) => new Promise<string>(resolve => {
        resolveNew = () => resolve(JSON.stringify({ status: 'ok', action: 'created', goal_id: args.id, goal: { id: args.id } }))
      }))
    render(h(GoalCreateForm, ownedWorkspace))
    fillField('goal-create-title-input', 'Old draft')
    fillField('goal-create-metric', 'old metric')
    fillField('goal-create-target', '10')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    expect(goalCreating.value).toBe(true)
    await waitFor(() => expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(1))
    fireEvent.click(screen.getByTestId('goal-create-close'))
    showGoalCreate.value = true
    await screen.findByTestId('goal-create-panel')
    fillField('goal-create-title-input', 'New draft')
    fillField('goal-create-metric', 'new metric')
    fillField('goal-create-target', '20')
    fireEvent.click(screen.getByTestId('goal-create-submit'))
    await waitFor(() => expect(api.callMcpToolAtIdentity).toHaveBeenCalledTimes(2))
    if (outcome === 'created') resolveOld()
    else rejectOld(new Error('old request rejected'))
    await waitFor(() => expect(goalCreateOutcomes.value.some(item => item.state === (outcome === 'created' ? 'created' : 'uncertain'))).toBe(true))
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
