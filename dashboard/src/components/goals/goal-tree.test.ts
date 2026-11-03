import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  DashboardGoalDetailResponse,
  DashboardGoalsTreeResponse,
  GoalTreeNode,
} from '../../types'
import { hydrateGoalTreeError, hydrateGoalTreeSnapshot } from '../../goal-tree-state'
import { observeGoalIds } from '../../lib/goal-identity'

const mocks = vi.hoisted(() => ({
  fetchDashboardGoalDetail: vi.fn(),
  fetchDashboardGoalsTree: vi.fn(),
  get: vi.fn(),
  getWithResponse: vi.fn(),
  post: vi.fn(),
  callMcpTool: vi.fn(),
  callIdentity: vi.fn(),
  captureTaskDispatch: vi.fn(),
  useRealMcp: false,
  refreshExecution: vi.fn(),
  refreshShell: vi.fn(),
  readGoalCandle: vi.fn(),
  mcpCallFailureDisposition: vi.fn(() => 'known_tool_response'),
  mcpIdentityRequiresGoalRefresh: vi.fn(() => false),
  captureArtifactWorkspace: vi.fn(),
  currentDashboardActor: vi.fn(() => 'dashboard-test'),
  route: {
    value: {
      tab: 'workspace',
      params: { section: 'planning' } as Record<string, string>,
      postId: null,
    },
  },
}))

vi.mock('../../api/dashboard', () => ({
  fetchDashboardGoalDetail: mocks.fetchDashboardGoalDetail,
  fetchDashboardGoalsTree: async (...args: unknown[]) => {
    const payload = await mocks.fetchDashboardGoalsTree(...args)
    return payload && typeof payload === 'object' && !('identity_observation' in payload)
      ? { ...payload, identity_observation: observeGoalIds(payload.tree, true) } : payload
  },
}))

vi.mock('../../api/goal-candle', () => ({
  readGoalCandle: mocks.readGoalCandle,
  GoalCandleEpochMismatchError: class extends Error {},
  GoalCandleWorkspaceRefusalError: class extends Error {},
}))

vi.mock('../../api/published-artifacts', async original => ({
  ...await original<typeof import('../../api/published-artifacts')>(),
  captureArtifactWorkspace: mocks.captureArtifactWorkspace,
}))

vi.mock('../../api/core', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/core')>(),
  currentDashboardActor: mocks.currentDashboardActor,
  get: mocks.get,
  getWithResponse: mocks.getWithResponse,
  post: mocks.post,
}))

// GoalCreateForm reaches the store and the toast through goal-create-state;
// neither is under test here.
vi.mock('../../store', async () => {
  const { signal } = await import('@preact/signals')
  return { refreshGoals: vi.fn(), executionWorkspaceAuthority: signal(null), executionError: signal(null), executionLoading: signal(false),
    refreshExecution: mocks.refreshExecution, refreshShell: mocks.refreshShell }
})

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
}))

vi.mock('../../api/mcp', async importOriginal => {
  const actual = await importOriginal<typeof import('../../api/mcp')>()
  return {
    callMcpToolAtIdentity: (...args: Parameters<typeof actual.callMcpToolAtIdentity>) => {
      const [name, toolArgs, identity] = args
      mocks.callIdentity(identity)
      return mocks.useRealMcp ? actual.callMcpToolAtIdentity(...args) : mocks.callMcpTool(name, toolArgs)
    },
    mcpCallFailureDisposition: mocks.mcpCallFailureDisposition,
    mcpStructuredContentFromError: () => null,
    mcpIdentityRequiresGoalRefresh: mocks.mcpIdentityRequiresGoalRefresh,
  }
})

vi.mock('../../router', () => ({
  route: mocks.route,
  replaceRoute: (tab: string, params: Record<string, string>) => { mocks.route.value = { tab, params, postId: null } },
}))

vi.mock('../task-manage/task-create-form', () => ({
  TaskCreateForm: (props: { goalDispatch: unknown }) => {
    mocks.captureTaskDispatch(props.goalDispatch)
    return html`<div data-testid="goal-task-create" />`
  },
}))

import { GoalTree, _testResetGoalActionReceipts, useGoalTreeDecisionObservation } from './goal-tree'
import { _testResetConfirmationReceipts } from './goal-confirmation'
import { executionError, executionWorkspaceAuthority } from '../../store'
import { ApiRequestError, clearStoredToken, currentStoredTokenRevision, getStoredToken, setStoredToken } from '../../api/core'
import { currentManagedRefusalObservation, recordManagedCredentialRefusal, resetDashboardSessionActorForTests,
  setCanonicalDashboardActor } from '../../lib/dashboard-session-actor'
import { showToast } from '../common/toast'
import { GoalCreateForm, resetGoalCreateFormLocal } from './goal-create-form'
import { showGoalCreate } from './goal-create-state'
import { fetchDashboardGoalDetail as decodeGoalDetail, fetchDashboardGoalsTree as decodeGoalTree,
  GoalSourceUnavailableError } from '../../api/dashboard-goals'

const measurementFixture = JSON.parse(readFileSync(
  resolve(__dirname, '../../api/fixtures/goal-measurement-tree.json'), 'utf8',
))

function transitionResponse(goalId: string, action: string, reconciled = false): string {
  return JSON.stringify({ status: 'ok', goal_id: goalId, action, ...(reconciled ? { reconciled } : {}),
    ...(action === 'drop' ? { noop: false, phase: 'dropped', goal: { id: goalId, phase: 'dropped' },
      effect_delivery: { status: 'delivered' } } : {}) })
}

function emptySummary(): DashboardGoalsTreeResponse['summary'] {
  return {
    total_goals: 0,
    active_goals: 0,
    phase_counts: {},
    total_tasks: 0,
    done_tasks: 0,
    pending_approvals: 0,
  }
}

function makeGoal(id: string, title: string, children: GoalTreeNode[] = []): GoalTreeNode {
  return {
    id,
    title,
    phase: 'executing',
    phase_color: '',
    goal_fsm: {
      state: 'executing',
      source: 'goal.phase',
      next_actions: ['request_complete', 'drop', 'pause', 'block'],
      activity_observation: 'goal_metadata',
    },
    priority: 3,
    metric: null,
    target_value: null,
    due_date: null,
    criterion_revision: 'revision-default',
    verification: { state: 'current', completion: { state: 'idle' } },
    measurement: { state: 'not_recorded' },
    tasks: [],
    task_count: 0,
    task_done_count: 0,
    timeline_events: [],
    children,
    child_count: children.length,
    last_activity_at: '2026-05-25T00:00:00Z',
    stagnation_seconds: 0,
    activity_observation: 'goal_metadata',
    linked_keeper_names: [],
    pending_approval_count: 0,
    created_at: '2026-05-25T00:00:00Z',
    updated_at: '2026-05-25T00:00:00Z',
  }
}

function ObservationProbe() {
  const observed = useGoalTreeDecisionObservation()
  return html`<div>
    <span data-testid="bound-tree">${observed.data?.tree.map(goal => goal.title).join(',') ?? ''}</span>
    <span data-testid="bound-tree-error">${observed.error ?? ''}</span>
    <span data-testid="bound-tree-unconfirmed">${observed.unconfirmed ? 'unconfirmed' : ''}</span>
    <button type="button" disabled=${observed.loading} onClick=${() => { void observed.refresh() }}>조회 재시도</button>
  </div>`
}

function OwnedGoalCreate() {
  const observation = useGoalTreeDecisionObservation()
  const source = observation.unavailable ? { kind: 'unavailable', unavailable: observation.unavailable }
    : observation.data ? { kind: 'ready' } : { kind: 'unconfirmed' }
  return html`<${GoalCreateForm} source=${source} isStoreUnavailableNow=${observation.isStoreUnavailableNow} />`
}

describe('GoalTree', () => {
  beforeEach(() => {
    _testResetGoalActionReceipts()
    _testResetConfirmationReceipts()
    ;(executionError as { value: string | null }).value = null
    mocks.refreshExecution.mockResolvedValue(undefined)
    mocks.refreshShell.mockResolvedValue(true)
    mocks.readGoalCandle.mockResolvedValue({ config: 'off', ledger: { state: 'missing' } })
    clearStoredToken()
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 1 }
    mocks.captureArtifactWorkspace.mockImplementation(async (basePath: string) => ({ basePath, mascRoot: `${basePath}/.masc` }))
    mocks.route.value = {
      tab: 'workspace',
      params: { section: 'planning' },
      postId: null,
    }
    hydrateGoalTreeSnapshot({
      approval_queue_state: { state: 'ready' },
      tree: [],
      summary: emptySummary(),
    })
  })

  afterEach(() => {
    cleanup()
    showGoalCreate.value = false
    resetGoalCreateFormLocal()
    mocks.callMcpTool.mockReset()
    mocks.callIdentity.mockReset()
    mocks.captureTaskDispatch.mockReset()
    mocks.useRealMcp = false
    mocks.refreshExecution.mockReset()
    mocks.refreshShell.mockReset()
    mocks.readGoalCandle.mockReset()
    mocks.mcpCallFailureDisposition.mockReset().mockReturnValue('known_tool_response')
    mocks.mcpIdentityRequiresGoalRefresh.mockReset().mockReturnValue(false)
    mocks.captureArtifactWorkspace.mockReset()
    mocks.currentDashboardActor.mockReset()
    mocks.currentDashboardActor.mockReturnValue('dashboard-test')
    mocks.fetchDashboardGoalDetail.mockReset()
    mocks.fetchDashboardGoalsTree.mockReset()
    mocks.get.mockReset()
    mocks.getWithResponse.mockReset()
    mocks.post.mockReset()
    clearStoredToken()
    resetDashboardSessionActorForTests()
    vi.unstubAllGlobals()
  })

  it('treats the first render before the read effect as loading', async () => {
    let resolveRead!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockImplementationOnce(() => new Promise(resolve => { resolveRead = resolve }))
    const observations: boolean[] = []
    function InitialLoadingProbe() {
      observations.push(useGoalTreeDecisionObservation().loading)
      return null
    }
    render(html`<${InitialLoadingProbe} />`)
    expect(observations[0]).toBe(true)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1))
    resolveRead({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await waitFor(() => expect(observations.at(-1)).toBe(false))
  })

  it('withholds an earlier visit on first render and rechecks it on remount', async () => {
    const oldGoal = makeGoal('goal-a', 'Earlier visit')
    const newGoal = makeGoal('goal-b', 'Current visit')
    let resolveRead!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree
      .mockResolvedValueOnce({ approval_queue_state: { state: 'ready' }, tree: [oldGoal],
        summary: { ...emptySummary(), total_goals: 1 } })
      .mockImplementationOnce(() => new Promise(resolve => { resolveRead = resolve }))
    const first = render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(screen.getByTestId('bound-tree').textContent).toBe('Earlier visit'))
    first.unmount()
    const seen: Array<{ title: string; current: boolean; binding: boolean }> = []
    function RemountProbe() {
      const observation = useGoalTreeDecisionObservation()
      seen.push({ title: observation.data?.tree[0]?.title ?? '', current: observation.isCurrent(),
        binding: observation.decisionBinding !== null })
      return html`<span data-testid="remounted-tree">${observation.data?.tree[0]?.title ?? ''}</span>`
    }
    render(html`<${RemountProbe} />`)
    expect(seen[0]).toEqual({ title: '', current: false, binding: false })
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    expect(screen.getByTestId('remounted-tree').textContent).toBe('')
    resolveRead({ approval_queue_state: { state: 'ready' }, tree: [newGoal],
      summary: { ...emptySummary(), total_goals: 1 } })
    await waitFor(() => expect(screen.getByTestId('remounted-tree').textContent).toBe('Current visit'))
  })

  it('shares a pending read and retains its refusal after another observation is published', async () => {
    let rejectRead!: (error: Error) => void
    mocks.fetchDashboardGoalsTree.mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectRead = reject }))
    const first = render(html`<${ObservationProbe} />`)
    const second = render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1))
    first.unmount()
    rejectRead(new ApiRequestError({ method: 'GET', path: '/api/v1/dashboard/goals', status: 401, detail: 'private refusal' }))
    await waitFor(() => expect(screen.getByTestId('bound-tree-error').textContent).toContain('인증 또는 권한이 거부'))
    hydrateGoalTreeSnapshot({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await waitFor(() => expect(screen.getByTestId('bound-tree-unconfirmed').textContent).toBe('unconfirmed'))
    expect(screen.getByTestId('bound-tree-error').textContent).toBe('')
    expect((screen.getByRole('button', { name: '조회 재시도' }) as HTMLButtonElement).disabled).toBe(false)
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
    second.unmount()
    const goal = makeGoal('goal-retry', 'New visit')
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce({ approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } })
    render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(screen.getByTestId('bound-tree').textContent).toBe('New visit'))
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2)
  })

  it.each(['success', 'refusal'] as const)('ignores an old %s after the last consumer leaves', async outcome => {
    let resolveOld!: (value: DashboardGoalsTreeResponse) => void
    let rejectOld!: (error: Error) => void
    let resolveNew!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree
      .mockImplementationOnce(() => new Promise((resolve, reject) => { resolveOld = resolve; rejectOld = reject }))
      .mockImplementationOnce(() => new Promise(resolve => { resolveNew = resolve }))
    const first = render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1))
    const oldSignal = mocks.fetchDashboardGoalsTree.mock.calls[0]![1] as AbortSignal
    first.unmount()
    expect(oldSignal.aborted).toBe(true)
    render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    if (outcome === 'success') {
      resolveOld({ approval_queue_state: { state: 'ready' }, tree: [makeGoal('old', 'Old visit')], summary: emptySummary() })
    } else {
      rejectOld(new ApiRequestError({ method: 'GET', path: '/api/v1/dashboard/goals', status: 401, detail: 'old refusal' }))
    }
    await Promise.resolve()
    expect(screen.getByTestId('bound-tree').textContent).toBe('')
    expect(screen.getByTestId('bound-tree-error').textContent).toBe('')
    resolveNew({ approval_queue_state: { state: 'ready' }, tree: [makeGoal('new', 'New visit')], summary: emptySummary() })
    await waitFor(() => expect(screen.getByTestId('bound-tree').textContent).toBe('New visit'))
  })

  it('withholds an owned snapshot during refresh and when authority changes', async () => {
    const goal = makeGoal('goal-a', 'Workspace A')
    let resolveRefresh!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree
      .mockResolvedValueOnce({ approval_queue_state: { state: 'ready' }, tree: [goal],
        summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } })
      .mockImplementationOnce(() => new Promise(resolve => { resolveRefresh = resolve }))
      .mockImplementation(() => new Promise(() => {}))
    render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(screen.getByTestId('bound-tree').textContent).toBe('Workspace A'))
    fireEvent.click(screen.getByRole('button', { name: '조회 재시도' }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    expect(screen.getByTestId('bound-tree').textContent).toBe('')
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(screen.getByTestId('bound-tree').textContent).toBe(''))
    resolveRefresh({ approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } })
    await Promise.resolve()
    expect(screen.getByTestId('bound-tree').textContent).toBe('')
  })

  it('replaces an in-flight read when another observation is published', async () => {
    const oldGoal = makeGoal('goal-old', 'Old bound result')
    const newGoal = makeGoal('goal-new', 'New bound result')
    let resolveOld!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockImplementationOnce(() => new Promise(resolve => { resolveOld = resolve }))
      .mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [newGoal],
        summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } })
    render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1))
    const oldSignal = mocks.fetchDashboardGoalsTree.mock.calls[0]![1] as AbortSignal
    hydrateGoalTreeSnapshot({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    expect(oldSignal.aborted).toBe(true)
    await waitFor(() => expect(screen.getByTestId('bound-tree').textContent).toBe('New bound result'))
    resolveOld({ approval_queue_state: { state: 'ready' }, tree: [oldGoal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } })
    await Promise.resolve()
    expect(screen.getByTestId('bound-tree').textContent).toBe('New bound result')
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2)
  })

  it.each([401, 403])('keeps a %s refusal from automatically retrying after an unbound update', async status => {
    mocks.fetchDashboardGoalsTree.mockRejectedValueOnce(new ApiRequestError({
      method: 'GET', path: '/api/v1/dashboard/goals', status, detail: 'private refusal detail',
    }))
    render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(screen.getByTestId('bound-tree-error').textContent).toContain('인증 또는 권한이 거부'))
    expect(screen.getByTestId('bound-tree-error').textContent).not.toContain('private refusal detail')
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
    hydrateGoalTreeSnapshot({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await waitFor(() => expect(screen.getByTestId('bound-tree-unconfirmed').textContent).toBe('unconfirmed'))
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
    expect((screen.getByRole('button', { name: '조회 재시도' }) as HTMLButtonElement).disabled).toBe(false)
    const goal = makeGoal('goal-retry', 'Retry succeeded')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } })
    fireEvent.click(screen.getByRole('button', { name: '조회 재시도' }))
    await waitFor(() => expect(screen.getByTestId('bound-tree').textContent).toBe('Retry succeeded'))
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2)
  })

  it('recovers a current expired credential on a bound tree read', async () => {
    setStoredToken('expired-token', { source: 'manual' })
    mocks.fetchDashboardGoalsTree.mockRejectedValueOnce(new ApiRequestError({
      method: 'GET', path: '/api/v1/dashboard/goals', status: 401, authErrorCode: 'token_expired',
    })).mockImplementation(() => new Promise(() => {}))
    render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(getStoredToken()).toBeNull())
  })

  it('withdraws detail until a new tree is bound after a detail refresh', async () => {
    const goal = makeGoal('goal-detail-refresh', 'Refresh goal')
    const tree: DashboardGoalsTreeResponse = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } }
    const detail: DashboardGoalDetailResponse = {
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }
    let resolveTree!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree)
      .mockImplementationOnce(() => new Promise(resolve => { resolveTree = resolve }))
    mocks.fetchDashboardGoalDetail.mockResolvedValue(detail)
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(1))
    fireEvent.click(await screen.findByRole('button', { name: 'detail 새로고침' }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    expect(screen.queryByTestId('goal-detail-panel')).toBeNull()
    expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(1)
    resolveTree(tree)
    await waitFor(() => expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(2))
    expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(goal.id)
  })

  it('ignores a delayed detail response after the tree refresh starts', async () => {
    const goal = makeGoal('goal-old-detail', 'Detail response')
    const tree: DashboardGoalsTreeResponse = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } }
    const detail: DashboardGoalDetailResponse = {
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }
    let resolveTree!: (value: DashboardGoalsTreeResponse) => void
    let resolveOldDetail!: (value: DashboardGoalDetailResponse) => void
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree)
      .mockImplementationOnce(() => new Promise(resolve => { resolveTree = resolve }))
    mocks.fetchDashboardGoalDetail.mockImplementationOnce(() => new Promise(resolve => { resolveOldDetail = resolve }))
      .mockResolvedValueOnce(detail)
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(1))
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    resolveOldDetail(detail)
    await Promise.resolve()
    expect(screen.queryByTestId('goal-detail-panel')).toBeNull()
    resolveTree(tree)
    await waitFor(() => expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(2))
    expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(goal.id)
  })

  it('recovers an expired credential refused by the current detail read', async () => {
    setStoredToken('expired-token', { source: 'manual' })
    const goal = makeGoal('goal-detail-auth', 'Detail auth')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } })
    mocks.fetchDashboardGoalDetail.mockRejectedValueOnce(new ApiRequestError({
      method: 'GET', path: '/api/v1/dashboard/goals/detail', status: 401, authErrorCode: 'token_expired',
    })).mockImplementation(() => new Promise(() => {}))
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(getStoredToken()).toBeNull())
  })

  it('does not recover a detail refusal from a previous workspace', async () => {
    setStoredToken('same-token', { source: 'manual' })
    const goal = makeGoal('goal-detail-auth-old', 'Detail auth old')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let rejectOld!: (error: Error) => void
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectOld = reject }))
      .mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(1))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(2))
    rejectOld(new ApiRequestError({ method: 'GET', path: '/api/v1/dashboard/goals/detail', status: 401,
      authErrorCode: 'token_expired' }))
    await Promise.resolve()
    expect(getStoredToken()).toBe('same-token')
  })

  it('keeps a successful response visible if the following tree refresh fails', async () => {
    const goal = makeGoal('goal-notice-private', 'Notice goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let rejectRefresh!: (error: Error) => void
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree)
      .mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectRefresh = reject }))
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    mocks.callMcpTool.mockResolvedValue(transitionResponse(goal.id, 'request_complete'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    let notice = screen.getByTestId('goal-operation-notice')
    expect(notice.textContent).toContain('서버가 Goal 변경 요청에 응답했습니다')
    expect(notice.textContent).not.toContain(goal.id)
    expect(within(notice).queryByRole('button', { name: '같은 ID의 현재 Goal 열기' })).toBeNull()
    rejectRefresh(new Error('tree unavailable'))
    await screen.findByText('tree unavailable')
    notice = screen.getByTestId('goal-operation-notice')
    expect(notice.textContent).toContain('서버가 Goal 변경 요청에 응답했습니다')
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('hides an in-flight transition notice and its late result after credential refusal', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const goal = makeGoal('goal-refused-notice', 'Refused notice')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementationOnce(() => new Promise(resolve => { resolveAction = resolve }))
    vi.mocked(showToast).mockClear()
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    expect(screen.getByTestId('goal-operation-notice').textContent).toContain('처리 중')
    recordManagedCredentialRefusal(currentStoredTokenRevision())
    await screen.findByText('인증이 거부되었습니다. 인증을 갱신한 뒤 다시 확인해 주세요.')
    expect(screen.queryByTestId('goal-operation-notice')).toBeNull()
    await act(async () => { resolveAction(transitionResponse(goal.id, 'request_complete')) })
    expect(screen.queryByTestId('goal-operation-notice')).toBeNull()
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
    expect(JSON.stringify(vi.mocked(showToast).mock.calls)).not.toContain('applied')
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('withdraws a retained Goal observation owner immediately after credential refusal', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    mocks.fetchDashboardGoalsTree.mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    let retainedCurrent = () => false
    let retainedOwnerCurrent = () => false
    let retainedRecoveryCurrent = () => false
    function RetainedObservationProbe() {
      const observed = useGoalTreeDecisionObservation()
      return html`<div>
        <span data-testid="retained-observation">${observed.isCurrent() ? 'ready' : 'pending'}</span>
        <button type="button" onClick=${() => { retainedCurrent = observed.isCurrent; retainedOwnerCurrent = observed.isOwnerCurrent;
          retainedRecoveryCurrent = observed.isRecoveryCurrent }}>capture</button>
      </div>`
    }
    render(html`<${RetainedObservationProbe} />`)
    await waitFor(() => expect(screen.getByTestId('retained-observation').textContent).toBe('ready'))
    fireEvent.click(screen.getByRole('button', { name: 'capture' }))
    expect(retainedCurrent()).toBe(true)
    expect(retainedOwnerCurrent()).toBe(true)
    expect(retainedRecoveryCurrent()).toBe(true)
    recordManagedCredentialRefusal(currentStoredTokenRevision())
    expect(retainedCurrent()).toBe(false)
    expect(retainedOwnerCurrent()).toBe(false)
    expect(retainedRecoveryCurrent()).toBe(true)
    const originalAuthority = executionWorkspaceAuthority.peek()
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    ;(executionWorkspaceAuthority as { value: unknown }).value = originalAuthority
    expect(retainedRecoveryCurrent()).toBe(false)
  })

  it.each(['tree', 'detail'] as const)('records a %s 401 header only while its workspace is current', async kind => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const goal = makeGoal('goal-status-owner', 'Status owner')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let onStatus: ((status: number) => void) | undefined
    if (kind === 'tree') {
      mocks.fetchDashboardGoalsTree.mockImplementationOnce((_workspace, _signal, callback) => {
        onStatus = callback
        return new Promise(() => {})
      })
    } else {
      mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
      mocks.fetchDashboardGoalDetail.mockImplementationOnce((_id, _workspace, callback) => {
        onStatus = callback
        return new Promise(() => {})
      })
    }
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(onStatus).toBeTypeOf('function'))
    const before = currentManagedRefusalObservation()
    onStatus?.(401)
    expect(currentManagedRefusalObservation()).toBeGreaterThan(before)
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    const afterRetirement = currentManagedRefusalObservation()
    onStatus?.(401)
    expect(currentManagedRefusalObservation()).toBe(afterRetirement)
  })

  it('does not recover a token for a 401 before the workspace is known', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    mocks.captureArtifactWorkspace.mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/health?full=1',
      status: 401, authErrorCode: 'token_expired' }))
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${GoalTree} />`)
    await screen.findByText(/인증 또는 권한이 거부되었습니다/)
    expect(fetchMock).not.toHaveBeenCalled()
    expect(mocks.fetchDashboardGoalsTree).not.toHaveBeenCalled()
    expect(getStoredToken()).toBe('dev-token')
  })

  it('ignores an earlier detail 401 after selection changes and returns', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const first = makeGoal('goal-status-first', 'First status goal')
    const second = makeGoal('goal-status-second', 'Second status goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2 } })
    let oldStatus: ((status: number) => void) | undefined
    mocks.fetchDashboardGoalDetail.mockImplementation((id, _workspace, callback) => {
      if (id === first.id && !oldStatus) oldStatus = callback
      return new Promise(() => {})
    })
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(oldStatus).toBeTypeOf('function'))
    fireEvent.click(screen.getByRole('button', { name: /Second status goal/ }))
    fireEvent.click(screen.getByRole('button', { name: /First status goal/ }))
    const before = currentManagedRefusalObservation()
    oldStatus?.(401)
    expect(currentManagedRefusalObservation()).toBe(before)
  })

  it('keeps a Goal Task recovery owner through refusal but retires it across selection changes', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const first = makeGoal('goal-task-first', 'First Task goal')
    const second = makeGoal('goal-task-second', 'Second Task goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2 } })
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({ goal: id === first.id ? first : second,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] }))
    render(html`<${GoalTree} />`)
    await screen.findByTestId('goal-task-create')
    const original = mocks.captureTaskDispatch.mock.calls.at(-1)![0] as { isRecoveryCurrent: () => boolean }
    expect(original.isRecoveryCurrent()).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: /Second Task goal/ }))
    fireEvent.click(screen.getByRole('button', { name: /First Task goal/ }))
    expect(original.isRecoveryCurrent()).toBe(false)
    await waitFor(() => expect(mocks.captureTaskDispatch.mock.calls.length).toBeGreaterThan(1))
    const current = mocks.captureTaskDispatch.mock.calls.at(-1)![0] as { isCurrent: () => boolean; isRecoveryCurrent: () => boolean }
    expect(current.isRecoveryCurrent()).toBe(true)
    recordManagedCredentialRefusal(currentStoredTokenRevision())
    expect(current.isCurrent()).toBe(false)
    expect(current.isRecoveryCurrent()).toBe(true)
  })

  it('lets the operator recheck refused authentication without replaying a Goal action', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const goal = makeGoal('goal-auth-retry', 'Auth retry')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    let resolveToken!: (response: Response) => void
    const fetchMock = vi.fn((_path: string) => new Promise<Response>(resolve => { resolveToken = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${GoalTree} />`)
    await screen.findByRole('button', { name: 'Request completion' })
    recordManagedCredentialRefusal(currentStoredTokenRevision())
    const retry = await screen.findByRole('button', { name: '인증 다시 확인' })
    fireEvent.click(retry)
    fireEvent.click(retry)
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    const renewal = new URL(fetchMock.mock.calls[0]![0], window.location.origin)
    expect(renewal.searchParams.get('expected_base_path')).toBe('/workspace-a')
    expect(renewal.searchParams.get('expected_masc_root')).toBe('/workspace-a/.masc')
    resolveToken(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    await waitFor(() => expect(mocks.refreshShell).toHaveBeenCalledExactlyOnceWith({ force: true, recoverAuth: false }))
    await waitFor(() => expect(getStoredToken()).toBe('fresh-dev-token'))
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    expect(mocks.post).not.toHaveBeenCalled()
  })

  it('does not apply an explicit authentication retry after the workspace changes and returns', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const goal = makeGoal('goal-auth-retry-aba', 'Auth retry ABA')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    let resolveToken!: (response: Response) => void
    const fetchMock = vi.fn((_path: string) => new Promise<Response>(resolve => { resolveToken = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${GoalTree} />`)
    await screen.findByRole('button', { name: 'Request completion' })
    const originalAuthority = executionWorkspaceAuthority.peek()
    recordManagedCredentialRefusal(currentStoredTokenRevision())
    fireEvent.click(await screen.findByRole('button', { name: '인증 다시 확인' }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    ;(executionWorkspaceAuthority as { value: unknown }).value = originalAuthority
    await act(async () => resolveToken(new Response(JSON.stringify({ token: 'stale-dev-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    })))
    expect(getStoredToken()).toBe('dev-token')
    expect(mocks.refreshShell).not.toHaveBeenCalled()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('only rechecks shell authentication when no Goal workspace has been observed', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    recordManagedCredentialRefusal(currentStoredTokenRevision())
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: '인증 다시 확인' }))
    await waitFor(() => expect(mocks.refreshShell).toHaveBeenCalledExactlyOnceWith({ force: true, recoverAuth: false }))
    expect(fetchMock).not.toHaveBeenCalled()
    expect(getStoredToken()).toBe('dev-token')
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('withholds Goal actions at an owned 401 header until shell authentication is rechecked', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = currentStoredTokenRevision()
    const goal = makeGoal('goal-header-auth', 'Header auth')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    mocks.useRealMcp = true
    let finishBody!: (body: string) => void
    let bodyStarted!: () => void
    const bodyPending = new Promise<void>(resolve => { bodyStarted = resolve })
    const response = new Response('', { status: 401 })
    response.text = () => { bodyStarted(); return new Promise(resolve => { finishBody = resolve }) }
    const fetchMock = vi.fn(() => Promise.resolve(response))
    vi.stubGlobal('fetch', fetchMock)
    mocks.refreshShell.mockImplementation(async () => {
      setCanonicalDashboardActor('dashboard', { tokenRevision: revision, rejected: false, verifiedAfterRefusal: true })
      return true
    })
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Pause' }))
    await bodyPending
    await screen.findByText('인증 상태를 확인할 수 없습니다. 인증을 다시 확인해 주세요.')
    expect(screen.queryByRole('button', { name: 'Pause' })).toBeNull()
    expect(screen.queryByTestId('goal-operation-notice')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: '인증 다시 확인' }))
    await waitFor(() => expect(mocks.refreshShell).toHaveBeenCalledExactlyOnceWith({ force: true, recoverAuth: false }))
    await screen.findByRole('button', { name: 'Pause' })
    await act(async () => finishBody(JSON.stringify({ auth_error_code: 'actor_mismatch' })))
    expect(getStoredToken()).toBe('dev-token')
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(screen.queryByTestId('goal-operation-notice')).toBeNull()
  })

  it('keeps an uncertain tool response visible while the tree is being refreshed', async () => {
    const goal = makeGoal('goal-notice-unknown', 'Unknown notice')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let resolveRefresh!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree)
      .mockImplementationOnce(() => new Promise(resolve => { resolveRefresh = resolve }))
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    mocks.callMcpTool.mockRejectedValue(new Error('tool reported failure'))
    mocks.mcpCallFailureDisposition.mockReturnValue('known_tool_response')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    await waitFor(() => expect(screen.getByTestId('goal-operation-notice').textContent).toContain('결과를 확인하지 못했습니다'))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    const notice = screen.getByTestId('goal-operation-notice')
    expect(notice.textContent).toContain('결과를 확인하지 못했습니다')
    expect(notice.textContent).not.toContain(goal.id)
    expect(within(notice).queryByRole('button', { name: '같은 ID의 현재 Goal 열기' })).toBeNull()
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
    resolveRefresh(tree)
  })

  it.each([
    { complete: false, ids: ['goal-notice-ambiguous'] },
    { complete: true, ids: ['goal-notice-ambiguous', ' goal-notice-ambiguous '] },
  ])('does not open a result when the current Goal identity observation is incomplete or ambiguous: %o', async identity_observation => {
    const goal = makeGoal('goal-notice-ambiguous', 'Ambiguous notice')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree).mockResolvedValueOnce({ ...tree, identity_observation })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    mocks.callMcpTool.mockResolvedValue(transitionResponse(goal.id, 'request_complete'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    await waitFor(() => expect(screen.getByTestId('goal-operation-notice').textContent)
      .toContain('서버가 Goal 변경 요청에 응답했습니다'))
    await screen.findByText('현재 Goal 목록에서 ID를 구분할 수 없어 변경을 사용할 수 없습니다.')
    expect(within(screen.getByTestId('goal-operation-notice'))
      .queryByRole('button', { name: '같은 ID의 현재 Goal 열기' })).toBeNull()
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('opens the same current Goal from a result after its phase leaves the filter', async () => {
    const executing = makeGoal('goal-notice-filtered', 'Filtered notice')
    const paused: GoalTreeNode = { ...executing, phase: 'paused',
      goal_fsm: { ...executing.goal_fsm, state: 'paused', next_actions: ['resume'] } }
    let committed = false
    mocks.fetchDashboardGoalsTree.mockImplementation(async () => ({ approval_queue_state: { state: 'ready' },
      tree: [committed ? paused : executing], summary: { ...emptySummary(), total_goals: 1 } }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async () => ({ goal: committed ? paused : executing,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] }))
    mocks.callMcpTool.mockImplementation(async () => { committed = true; return transitionResponse(executing.id, 'pause') })
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('tab', { name: /실행 중/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Pause' }))
    await waitFor(() => expect(screen.getByTestId('goal-operation-notice').textContent)
      .toContain('서버가 Goal 변경 요청에 응답했습니다'))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    const open = await screen.findByRole('button', { name: '같은 ID의 현재 Goal 열기' })
    fireEvent.click(open)
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(executing.id))
    expect(screen.getByTestId('goal-operation-notice').textContent).toContain('서버가 Goal 변경 요청에 응답했습니다')
  })

  it('keeps concurrent results separate and restores a dismissed pending notice on completion', async () => {
    const first = makeGoal('goal-notice-first', 'First notice')
    const second = makeGoal('goal-notice-second', 'Second notice')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2 } } satisfies DashboardGoalsTreeResponse
    let resolveFirst!: (value: string) => void
    let resolveSecond!: (value: string) => void
    let resolveEarlierRefresh!: (value: DashboardGoalsTreeResponse) => void
    let resolveLatestRefresh!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree)
      .mockImplementationOnce(() => new Promise(resolve => { resolveEarlierRefresh = resolve }))
      .mockImplementationOnce(() => new Promise(resolve => { resolveLatestRefresh = resolve }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({ goal: id === first.id ? first : second,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] }))
    mocks.callMcpTool.mockImplementationOnce(() => new Promise(resolve => { resolveFirst = resolve }))
      .mockImplementationOnce(() => new Promise(resolve => { resolveSecond = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    fireEvent.click(within(screen.getByTestId('goal-operation-notice')).getByRole('button', { name: '안내 닫기' }))
    fireEvent.click(screen.getByRole('button', { name: /Second notice/ }))
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(second.id))
    fireEvent.click(screen.getByRole('button', { name: 'Request completion' }))
    resolveSecond(transitionResponse(second.id, 'request_complete'))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    resolveFirst(transitionResponse(first.id, 'request_complete'))
    await waitFor(() => expect(screen.getAllByTestId('goal-operation-notice')).toHaveLength(2))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(3))
    expect((mocks.fetchDashboardGoalsTree.mock.calls[1]![1] as AbortSignal).aborted).toBe(true)
    for (const notice of screen.getAllByTestId('goal-operation-notice')) {
      expect(notice.textContent).toContain('서버가 Goal 변경 요청에 응답했습니다')
    }
    fireEvent.click(within(screen.getAllByTestId('goal-operation-notice')[0]!).getByRole('button', { name: '안내 닫기' }))
    expect(screen.getAllByTestId('goal-operation-notice')).toHaveLength(1)
    resolveEarlierRefresh(tree)
    await Promise.resolve()
    expect(screen.queryByTestId('goal-detail-panel')).toBeNull()
    const latest = { ...tree, tree: [{ ...first, title: 'First after both changes' }, second] }
    resolveLatestRefresh(latest)
    await screen.findByRole('button', { name: /First after both changes/ })
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel')).toBeTruthy())
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(2)
  })

  it.each([true, false])('waits to identify an in-flight workspace before replacing its read (same root: %s)', async sameRoot => {
    const first = makeGoal('goal-root-first', 'Root first')
    const second = makeGoal('goal-root-second', 'Root second')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2 } } satisfies DashboardGoalsTreeResponse
    let resolveCapture!: (workspace: { basePath: string; mascRoot: string }) => void
    mocks.captureArtifactWorkspace.mockResolvedValueOnce({ basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' })
      .mockImplementationOnce(() => new Promise(resolve => { resolveCapture = resolve }))
      .mockResolvedValue({ basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' })
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({ goal: id === first.id ? first : second,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] }))
    let resolveFirst!: (value: string) => void
    let resolveSecond!: (value: string) => void
    mocks.callMcpTool.mockImplementationOnce(() => new Promise(resolve => { resolveFirst = resolve }))
      .mockImplementationOnce(() => new Promise(resolve => { resolveSecond = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: /Root first/ }))
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(first.id))
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    fireEvent.click(screen.getByRole('button', { name: /Root second/ }))
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(second.id))
    fireEvent.click(screen.getByRole('button', { name: 'Request completion' }))
    resolveFirst(transitionResponse(first.id, 'request_complete'))
    await waitFor(() => expect(mocks.captureArtifactWorkspace).toHaveBeenCalledTimes(2))
    const signal = mocks.captureArtifactWorkspace.mock.calls[1]![1] as AbortSignal
    resolveSecond(transitionResponse(second.id, 'request_complete'))
    await waitFor(() => expect(screen.getAllByTestId('goal-operation-notice')).toHaveLength(2))
    expect(signal.aborted).toBe(false)
    resolveCapture({ basePath: '/workspace-a', mascRoot: sameRoot ? '/workspace-a/.masc' : '/other/.masc' })
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    expect(signal.aborted).toBe(sameRoot)
    expect(mocks.captureArtifactWorkspace).toHaveBeenCalledTimes(sameRoot ? 3 : 2)
    expect(mocks.fetchDashboardGoalsTree.mock.calls[1]![0]).toEqual({
      basePath: '/workspace-a', mascRoot: sameRoot ? '/workspace-a/.masc' : '/other/.masc',
    })
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(2)
  })

  it('retains a post-write refresh intent when an unrelated tree observation supersedes it', async () => {
    const goal = makeGoal('goal-postwrite-observation', 'Post-write observation')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let resolveSuperseded!: (value: DashboardGoalsTreeResponse) => void
    let resolveCurrent!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree)
      .mockImplementationOnce(() => new Promise(resolve => { resolveSuperseded = resolve }))
      .mockImplementationOnce(() => new Promise(resolve => { resolveCurrent = resolve }))
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    mocks.callMcpTool.mockResolvedValue(transitionResponse(goal.id, 'request_complete'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    hydrateGoalTreeSnapshot({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(3))
    resolveSuperseded(tree)
    await Promise.resolve()
    expect(screen.queryByTestId('goal-detail-panel')).toBeNull()
    resolveCurrent(tree)
    await screen.findByTestId('goal-detail-panel')
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('does not loop on an authorization refusal during post-write observation', async () => {
    const goal = makeGoal('goal-postwrite-refused', 'Post-write refusal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree).mockRejectedValueOnce(new ApiRequestError({
      method: 'GET', path: '/api/v1/dashboard/goals', status: 401, detail: 'private refusal',
    }))
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    mocks.callMcpTool.mockResolvedValue(transitionResponse(goal.id, 'request_complete'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    await screen.findByText(/인증 또는 권한이 거부되었습니다/)
    hydrateGoalTreeSnapshot(tree)
    await waitFor(() => expect(screen.getByText(/현재 Goal 상태를 다시 확인/)).toBeTruthy())
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2)
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('does not start a post-write read after the last consumer leaves', async () => {
    vi.mocked(showToast).mockClear()
    const goal = makeGoal('goal-postwrite-unmounted', 'Unmounted request')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise(resolve => { resolveAction = resolve }))
    const view = render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    view.unmount()
    resolveAction(transitionResponse(goal.id, 'request_complete'))
    await waitFor(() => expect(showToast).toHaveBeenCalled())
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('reobserves after a confirmation response arrives during an earlier tree read', async () => {
    const goal: GoalTreeNode = { ...makeGoal('goal-confirm-refresh', 'Confirm refresh'), phase: 'awaiting_confirmation',
      goal_fsm: { state: 'awaiting_confirmation', source: 'goal.phase', next_actions: ['drop'], activity_observation: 'goal_metadata' } }
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    const criterion = { revision: goal.criterion_revision, title: goal.title, metric: null, target_value: null }
    const verdict = { criterion, request_id: 'request-confirm-refresh', verification_run_id: 'run-confirm-refresh',
      outcome: 'proven', reason: null, authority: { kind: 'system_llm_agent', actor: 'verifier' },
      evidence: 'verified', recorded_at: '2026-11-01T00:00:00Z' }
    const evidence = (confirmed: boolean) => ({ inspection_operator_id: 'operator', goal: { id: goal.id,
      phase: confirmed ? 'completed' : 'awaiting_confirmation', criterion_revision: criterion.revision,
      title: criterion.title, metric: criterion.metric, target_value: criterion.target_value },
    verification: { goal_id: goal.id, updated_at: '2026-11-01T00:00:00Z', completion: confirmed
      ? { state: 'human_confirmed', verdict, operator_id: 'operator', confirmed_at: '2026-11-01T01:00:00Z' }
      : { state: 'proof_proven', verdict } } })
    mocks.getWithResponse.mockResolvedValue({ data: evidence(false), headers: new Headers({
      'x-masc-workspace-read': 'matched-v1', 'x-masc-execution-publication-epoch': 'fixture-a',
      'x-masc-runtime-instance-id': '018f83d7-93a4-7f5d-9a72-123456789abc',
    }) })
    let resolvePost!: (value: unknown) => void
    mocks.post.mockImplementation(() => new Promise(resolve => { resolvePost = resolve }))
    let resolveEarlier!: (value: DashboardGoalsTreeResponse) => void
    let resolveLater!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree)
      .mockImplementationOnce(() => new Promise(resolve => { resolveEarlier = resolve }))
      .mockImplementationOnce(() => new Promise(resolve => { resolveLater = resolve }))
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await waitFor(() => expect(mocks.post).toHaveBeenCalledTimes(1))
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    resolvePost(evidence(true))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(3))
    expect((mocks.fetchDashboardGoalsTree.mock.calls[1]![1] as AbortSignal).aborted).toBe(true)
    expect(screen.getByTestId('goal-operation-notice').textContent).toContain('최종 확인 결과를 확인하지 못했습니다')
    resolveEarlier(tree)
    await Promise.resolve()
    expect(screen.queryByTestId('goal-detail-panel')).toBeNull()
    resolveLater(tree)
    await screen.findByTestId('goal-detail-panel')
    expect(mocks.post).toHaveBeenCalledTimes(1)
  })

  it('withdraws lifecycle actions while a confirmation readback refusal is recovering', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const goal: GoalTreeNode = { ...makeGoal('goal-confirm-auth', 'Confirm auth'), phase: 'awaiting_confirmation',
      goal_fsm: { state: 'awaiting_confirmation', source: 'goal.phase', next_actions: ['drop'], activity_observation: 'goal_metadata' } }
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    const criterion = { revision: goal.criterion_revision, title: goal.title, metric: null, target_value: null }
    const verdict = { criterion, request_id: 'request-auth', verification_run_id: 'run-auth',
      outcome: 'proven', reason: null, authority: { kind: 'system_llm_agent', actor: 'verifier' },
      evidence: 'verified', recorded_at: '2026-11-01T00:00:00Z' }
    const evidence = (confirmed: boolean) => ({ inspection_operator_id: 'operator', goal: { id: goal.id,
      phase: confirmed ? 'completed' : 'awaiting_confirmation', criterion_revision: criterion.revision,
      title: criterion.title, metric: criterion.metric, target_value: criterion.target_value },
    verification: { goal_id: goal.id, updated_at: '2026-11-01T00:00:00Z', completion: confirmed
      ? { state: 'human_confirmed', verdict, operator_id: 'operator', confirmed_at: '2026-11-01T01:00:00Z' }
      : { state: 'proof_proven', verdict } } })
    mocks.getWithResponse.mockResolvedValueOnce({ data: evidence(false), headers: new Headers({
      'x-masc-workspace-read': 'matched-v1', 'x-masc-execution-publication-epoch': 'fixture-a',
      'x-masc-runtime-instance-id': '018f83d7-93a4-7f5d-9a72-123456789abc',
    }) }).mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/api/v1/goals/confirmation',
      status: 401, authErrorCode: 'token_expired' }))
    mocks.post.mockResolvedValueOnce(evidence(true))
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree).mockImplementation(() => new Promise(() => {}))
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    let resolveRefresh!: (response: Response) => void
    const fetchMock = vi.fn(() => new Promise<Response>(resolve => { resolveRefresh = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    await screen.findByText('인증이 거부되었습니다. 인증을 갱신한 뒤 다시 확인해 주세요.')
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('button', { name: 'Drop' })).toBeNull()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    expect(mocks.post).toHaveBeenCalledTimes(1)
    resolveRefresh(new Response(JSON.stringify({ token: 'old-dev-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
  })

  it('recovers a managed credential refused by the initial confirmation evidence read', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const goal: GoalTreeNode = { ...makeGoal('goal-evidence-auth', 'Evidence auth'), phase: 'awaiting_confirmation',
      goal_fsm: { state: 'awaiting_confirmation', source: 'goal.phase', next_actions: ['drop'], activity_observation: 'goal_metadata' } }
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    const core = await vi.importActual<typeof import('../../api/core')>('../../api/core')
    mocks.getWithResponse.mockImplementationOnce(core.getWithResponse).mockImplementation(() => new Promise(() => {}))
    let resolveRenewal!: (response: Response) => void
    const fetchMock = vi.fn((path: string) => path.startsWith('/api/v1/goals/confirmation?')
      ? Promise.resolve(new Response(JSON.stringify({ auth_error_code: 'token_expired' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })) : new Promise<Response>(resolve => { resolveRenewal = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    await screen.findByText('인증이 거부되었습니다. 인증을 갱신한 뒤 다시 확인해 주세요.')
    resolveRenewal(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    await waitFor(() => expect(getStoredToken()).toBe('fresh-dev-token'))
    expect(fetchMock).toHaveBeenCalledTimes(2)
    const evidencePath = fetchMock.mock.calls.find(([path]) => path.startsWith('/api/v1/goals/confirmation?'))?.[0]
    expect(evidencePath).toBeDefined()
    const evidence = new URL(evidencePath!, window.location.origin)
    expect(evidence.searchParams.get('goal_id')).toBe(goal.id)
    expect(evidence.searchParams.get('expected_base_path')).toBe('/workspace-a')
    const renewalPath = fetchMock.mock.calls.find(([path]) => path.startsWith('/api/v1/dashboard/dev-token?'))?.[0]
    expect(renewalPath).toBeDefined()
    const renewal = new URL(renewalPath!, window.location.origin)
    expect(renewal.pathname).toBe('/api/v1/dashboard/dev-token')
    expect(renewal.searchParams.get('expected_base_path')).toBe('/workspace-a')
    expect(renewal.searchParams.get('expected_masc_root')).toBe('/workspace-a/.masc')
    expect(mocks.post).not.toHaveBeenCalled()
  })

  it('recovers a managed credential refused by a Goal detail read', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const goal = makeGoal('goal-detail-auth', 'Detail auth')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    const core = await vi.importActual<typeof import('../../api/core')>('../../api/core')
    mocks.getWithResponse.mockImplementationOnce(core.getWithResponse)
    mocks.fetchDashboardGoalDetail.mockImplementationOnce(decodeGoalDetail)
      .mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    let resolveRenewal!: (response: Response) => void
    const fetchMock = vi.fn((path: string) => path.startsWith('/api/v1/dashboard/goals/detail?')
      ? Promise.resolve(new Response(JSON.stringify({ auth_error_code: 'token_expired' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })) : new Promise<Response>(resolve => { resolveRenewal = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    await screen.findByText('인증이 거부되었습니다. 인증을 갱신한 뒤 다시 확인해 주세요.')
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: '인증 다시 확인' })) })
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(mocks.refreshShell).not.toHaveBeenCalled()
    resolveRenewal(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    await waitFor(() => expect(getStoredToken()).toBe('fresh-dev-token'))
    const renewalPath = fetchMock.mock.calls.find(([path]) => path.startsWith('/api/v1/dashboard/dev-token?'))?.[0]
    expect(renewalPath).toBeDefined()
    const renewal = new URL(renewalPath!, window.location.origin)
    expect(renewal.searchParams.get('expected_base_path')).toBe('/workspace-a')
    expect(renewal.searchParams.get('expected_masc_root')).toBe('/workspace-a/.masc')
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('recovers a managed credential refused by a Goal transition without replaying it', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const goal = makeGoal('goal-transition-auth', 'Transition auth')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
    mocks.useRealMcp = true
    let resolveRenewal!: (response: Response) => void
    const fetchMock = vi.fn((path: string) => path === '/mcp'
      ? Promise.resolve(new Response(JSON.stringify({ error: 'refused', auth_error_code: 'token_expired' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })) : new Promise<Response>(resolve => { resolveRenewal = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Pause' }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    await screen.findByText('인증이 거부되었습니다. 인증을 갱신한 뒤 다시 확인해 주세요.')
    resolveRenewal(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    await waitFor(() => expect(getStoredToken()).toBe('fresh-dev-token'))
    expect(fetchMock.mock.calls.filter(([path]) => path === '/mcp')).toHaveLength(1)
    const renewalPath = fetchMock.mock.calls.find(([path]) => path !== '/mcp')?.[0]
    expect(renewalPath).toBeDefined()
    const renewal = new URL(renewalPath!, window.location.origin)
    expect(renewal.searchParams.get('expected_base_path')).toBe('/workspace-a')
    expect(renewal.searchParams.get('expected_masc_root')).toBe('/workspace-a/.masc')
  })

  it.each(['same', 'late-token', 'other', 'failed', 'retired', 'manual', 'replaced', 'selection-aba',
    'managed-hydration', 'recovery-hydration'] as const)(
    'settles confirmation recovery only after the %s workspace observation', async outcome => {
      if (outcome === 'manual') setStoredToken('old-manual-token', { source: 'manual' })
      else setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
      const goal: GoalTreeNode = { ...makeGoal('goal-confirm-recovery', 'Confirm recovery'), phase: 'awaiting_confirmation',
        goal_fsm: { state: 'awaiting_confirmation', source: 'goal.phase', next_actions: ['drop'], activity_observation: 'goal_metadata' } }
      const otherGoal = makeGoal('goal-other-recovery', 'Other recovery goal')
      const tree = { approval_queue_state: { state: 'ready' }, tree: outcome === 'selection-aba' ? [goal, otherGoal] : [goal],
        summary: { ...emptySummary(), total_goals: outcome === 'selection-aba' ? 2 : 1 } } satisfies DashboardGoalsTreeResponse
      const criterion = { revision: goal.criterion_revision, title: goal.title, metric: null, target_value: null }
      const verdict = { criterion, request_id: 'request-recovery', verification_run_id: 'run-recovery',
        outcome: 'proven', reason: null, authority: { kind: 'system_llm_agent', actor: 'verifier' },
        evidence: 'verified', recorded_at: '2026-11-01T00:00:00Z' }
      const evidence = (confirmed: boolean) => ({ inspection_operator_id: 'operator', goal: { id: goal.id,
        phase: confirmed ? 'completed' : 'awaiting_confirmation', criterion_revision: criterion.revision,
        title: criterion.title, metric: criterion.metric, target_value: criterion.target_value },
      verification: { goal_id: goal.id, updated_at: '2026-11-01T00:00:00Z', completion: confirmed
        ? { state: 'human_confirmed', verdict, operator_id: 'operator', confirmed_at: '2026-11-01T01:00:00Z' }
        : { state: 'proof_proven', verdict } } })
      mocks.getWithResponse.mockResolvedValueOnce({ data: evidence(false), headers: new Headers({
        'x-masc-workspace-read': 'matched-v1', 'x-masc-execution-publication-epoch': 'fixture-a',
        'x-masc-runtime-instance-id': '018f83d7-93a4-7f5d-9a72-123456789abc',
      }) }).mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/api/v1/goals/confirmation',
        status: 401, authErrorCode: 'token_expired' }))
      let rejectPost!: (error: Error) => void
      let resolvePost!: (value: unknown) => void
      if (outcome === 'selection-aba') {
        mocks.getWithResponse.mockReset().mockResolvedValue({ data: evidence(false), headers: new Headers({
          'x-masc-workspace-read': 'matched-v1', 'x-masc-execution-publication-epoch': 'fixture-a',
          'x-masc-runtime-instance-id': '018f83d7-93a4-7f5d-9a72-123456789abc',
        }) })
        mocks.post.mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectPost = reject }))
      } else if (outcome === 'managed-hydration') {
        const headers = new Headers({ 'x-masc-workspace-read': 'matched-v1',
          'x-masc-execution-publication-epoch': 'fixture-a',
          'x-masc-runtime-instance-id': '018f83d7-93a4-7f5d-9a72-123456789abc' })
        mocks.getWithResponse.mockReset().mockResolvedValueOnce({ data: evidence(false), headers })
          .mockResolvedValueOnce({ data: evidence(true), headers })
        mocks.post.mockImplementationOnce(() => new Promise(resolve => { resolvePost = resolve }))
      } else mocks.post.mockResolvedValueOnce(evidence(true))
      mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree).mockRejectedValue(new Error('tree unavailable'))
      mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({ goal: id === otherGoal.id ? otherGoal : goal,
        linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] }))
      let resolveWorkspace!: (value: { basePath: string; mascRoot: string }) => void
      let rejectWorkspace!: (error: Error) => void
      mocks.captureArtifactWorkspace.mockResolvedValueOnce({ basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' })
        .mockImplementationOnce(() => new Promise((resolve, reject) => { resolveWorkspace = resolve; rejectWorkspace = reject }))
        .mockResolvedValue({ basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' })
      let resolveToken!: (response: Response) => void
      const tokenResponse = () => new Response(JSON.stringify({
        token: 'fresh-dev-token', actor: 'dashboard', role: 'admin',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      const fetchMock = vi.fn(() => outcome === 'late-token' || outcome === 'recovery-hydration'
        ? new Promise<Response>(resolve => { resolveToken = resolve }) : Promise.resolve(tokenResponse()))
      vi.stubGlobal('fetch', fetchMock)
      render(html`<${GoalTree} />`)
      fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
      if (outcome === 'managed-hydration') {
        await waitFor(() => expect(mocks.post).toHaveBeenCalledTimes(1))
        setCanonicalDashboardActor('dashboard')
        resolvePost(evidence(true))
        await waitFor(() => expect(screen.getByTestId('goal-operation-notice').textContent)
          .toContain('확인 응답과 재조회에서 완료 기록이 일치했습니다'))
        expect(mocks.post).toHaveBeenCalledTimes(1)
        return
      }
      if (outcome === 'selection-aba') {
        await waitFor(() => expect(mocks.post).toHaveBeenCalledTimes(1))
        fireEvent.click(await screen.findByRole('button', { name: /Other recovery goal/ }))
        await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(otherGoal.id))
        fireEvent.click(screen.getByRole('button', { name: /Confirm recovery/ }))
        await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(goal.id))
        rejectPost(new ApiRequestError({ method: 'POST', path: '/api/v1/goals/confirmation',
          status: 401, authErrorCode: 'token_expired' }))
        await waitFor(() => expect(mocks.captureArtifactWorkspace).toHaveBeenCalledTimes(2))
        expect(fetchMock).not.toHaveBeenCalled()
        expect(getStoredToken()).toBe('old-dev-token')
        expect(mocks.post).toHaveBeenCalledTimes(1)
        return
      }
      if (outcome === 'manual') {
        await waitFor(() => expect(getStoredToken()).toBeNull())
        expect(fetchMock).not.toHaveBeenCalled()
        expect(mocks.post).toHaveBeenCalledTimes(1)
        return
      }
      await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
      await waitFor(() => expect(mocks.captureArtifactWorkspace).toHaveBeenCalledTimes(2))
      expect(getStoredToken()).toBe('old-dev-token')
      expect(screen.queryByRole('button', { name: 'Drop' })).toBeNull()
      if (outcome === 'replaced') {
        // The first health transport ignores abort. An independent observation
        // supersedes it and the replacement must unblock recovery on its own.
        hydrateGoalTreeSnapshot(tree)
        await waitFor(() => expect(mocks.captureArtifactWorkspace.mock.calls.length).toBeGreaterThanOrEqual(3))
        await waitFor(() => expect(getStoredToken()).toBe('fresh-dev-token'))
        expect(mocks.post).toHaveBeenCalledTimes(1)
        return
      }
      if (outcome === 'recovery-hydration') setCanonicalDashboardActor('dashboard')
      if (outcome === 'retired') {
        ;(executionWorkspaceAuthority as { value: unknown }).value =
          { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
      }
      if (outcome === 'failed') rejectWorkspace(new Error('workspace unavailable'))
      else resolveWorkspace({ basePath: '/workspace-a',
        mascRoot: outcome === 'other' ? '/other/.masc' : '/workspace-a/.masc' })
      if (outcome === 'late-token' || outcome === 'recovery-hydration') {
        await screen.findByText('인증이 거부되었습니다. 인증을 갱신한 뒤 다시 확인해 주세요.')
        expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
        expect(getStoredToken()).toBe('old-dev-token')
        resolveToken(tokenResponse())
      }
      if (outcome === 'same' || outcome === 'late-token' || outcome === 'recovery-hydration') {
        await waitFor(() => expect(getStoredToken()).toBe('fresh-dev-token'))
      }
      else {
        await screen.findByText('인증이 거부되었습니다. 인증을 갱신한 뒤 다시 확인해 주세요.')
        expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
        expect(getStoredToken()).toBe('old-dev-token')
      }
      expect(mocks.post).toHaveBeenCalledTimes(1)
    },
  )

  it('rechecks execution authority when retrying without a workspace', async () => {
    let resolveOld!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockImplementationOnce(() => new Promise(resolve => { resolveOld = resolve }))
    mocks.refreshExecution.mockImplementation(async () => {
      ;(executionWorkspaceAuthority as { value: unknown }).value =
        { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    })
    const goal = makeGoal('goal-recovered', 'Recovered workspace')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } })
    render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1))
    ;(executionWorkspaceAuthority as { value: unknown }).value = null
    await waitFor(() => expect((screen.getByRole('button', { name: '조회 재시도' }) as HTMLButtonElement).disabled).toBe(false))
    fireEvent.click(screen.getByRole('button', { name: '조회 재시도' }))
    await waitFor(() => expect(mocks.refreshExecution).toHaveBeenCalledWith({ force: true }))
    await waitFor(() => expect(screen.getByTestId('bound-tree').textContent).toBe('Recovered workspace'))
    resolveOld({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await Promise.resolve()
    expect(screen.getByTestId('bound-tree').textContent).toBe('Recovered workspace')
  })

  it('ignores a late refusal after an A to B to A authority change', async () => {
    setStoredToken('same-token', { source: 'manual' })
    let rejectOld!: (error: Error) => void
    const goalB = makeGoal('goal-b', 'Workspace B')
    const goalA = makeGoal('goal-a', 'Current workspace A')
    mocks.fetchDashboardGoalsTree.mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectOld = reject }))
      .mockResolvedValueOnce({ approval_queue_state: { state: 'ready' }, tree: [goalB],
        summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } })
      .mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [goalA],
        summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } })
    render(html`<${ObservationProbe} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(screen.getByTestId('bound-tree').textContent).toBe('Workspace B'))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 3 }
    await waitFor(() => expect(screen.getByTestId('bound-tree').textContent).toBe('Current workspace A'))
    rejectOld(new ApiRequestError({ method: 'GET', path: '/api/v1/dashboard/goals', status: 401,
      authErrorCode: 'token_expired', detail: 'old refusal' }))
    await Promise.resolve()
    expect(screen.getByTestId('bound-tree').textContent).toBe('Current workspace A')
    expect(screen.getByTestId('bound-tree-error').textContent).toBe('')
    expect(getStoredToken()).toBe('same-token')
  })

  it('renders the decoded wire measurement with its criterion and evidence', async () => {
    mocks.get.mockResolvedValue(measurementFixture)
    const decoded = await decodeGoalTree()
    const measured = decoded.tree[0]!
    mocks.route.value = {
      tab: 'workspace',
      params: { section: 'planning', goal: measured.id },
      postId: null,
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue(decoded)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal: measured, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    } satisfies DashboardGoalDetailResponse)

    render(html`<${GoalTree} />`)
    await waitFor(() => {
      expect(screen.getByTestId('goal-measurement-detail').getAttribute('data-state')).toBe('reported')
    })
    expect(screen.getByTestId('goal-observed-value').textContent).toBe('7')
    expect(screen.getByTestId('goal-measurement-evidence').textContent).toContain('artifact:seven-passing-cases')
    expect(screen.getByTestId('goal-criterion-revision').textContent).toContain(measured.criterion_revision)
    expect(screen.getByTestId('goal-measurement-badge-goal-measured').textContent).toContain('관측 7')
    expect(screen.getByTestId('goal-measurement-badge-goal-unavailable').textContent).toContain('측정 저장소 읽기 실패')
  })

  it('keeps the measurement detail in sync with a refreshed tree', async () => {
    mocks.get.mockResolvedValue(measurementFixture)
    const first = await decodeGoalTree()
    const updated = structuredClone(first)
    const measurement = updated.tree[0]!.measurement
    if (measurement.state !== 'reported') throw new Error('fixture needs a reported measurement')
    updated.tree[0]!.measurement = {
      state: 'reported', record: { ...measurement.record, observed_value: '8' },
    }
    mocks.route.value = {
      tab: 'workspace', params: { section: 'planning', goal: first.tree[0]!.id }, postId: null,
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(first).mockResolvedValueOnce(updated)
    // Detail remains on the earlier response while the tree refreshes.
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal: first.tree[0]!, linked_tasks: [], linked_keepers: [], approvals: [],
      execution_receipts: [], timeline: [],
    } satisfies DashboardGoalDetailResponse)

    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByTestId('goal-observed-value').textContent).toBe('7'))
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(screen.getByTestId('goal-observed-value').textContent).toBe('8'))
    expect(screen.getByTestId('goal-measurement-badge-goal-measured').textContent).toContain('관측 8')
  })

  it('selects and expands the goal from the planning route focus', async () => {
    const child = makeGoal('goal-child', 'Child goal')
    const parent = makeGoal('goal-parent', 'Parent goal', [child])
    const treePayload: DashboardGoalsTreeResponse = {
      approval_queue_state: { state: 'ready' },
      tree: [parent],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 },
    }
    const detailPayload: DashboardGoalDetailResponse = {
      goal: child,
      linked_tasks: [],
      linked_keepers: [],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    }
    mocks.route.value = {
      tab: 'workspace',
      params: { section: 'planning', goal: 'goal-child' },
      postId: null,
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue(treePayload)
    mocks.fetchDashboardGoalDetail.mockResolvedValue(detailPayload)

    const { container } = render(html`<${GoalTree} />`)

    expect(container.querySelector('.v2-workspace-surface')).not.toBeNull()
    await waitFor(() => {
      expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id'))
        .toBe('goal-child')
    })
    expect(screen.getAllByText('Child goal').length).toBeGreaterThan(0)
    await waitFor(() => {
      expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledWith('goal-child',
        { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }, expect.any(Function))
    })
    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: 'no matching goal' } })
    await waitFor(() => expect(screen.queryByTestId('goal-detail-panel')).toBeNull())
    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: '' } })
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(child.id))
    expect(screen.getByRole('button', { name: /Parent goal/ }).getAttribute('aria-expanded')).toBe('true')
    expect(screen.getByRole('button', { name: /Child goal/ })).toBeTruthy()
  })

  it('keeps a routed padded ID exact and blocks observed aliases even when filtered', async () => {
    const canonical = makeGoal('goal-a', 'Canonical goal')
    const padded = makeGoal(' goal-a ', 'Padded goal')
    const independent = makeGoal('goal-b', 'Independent goal')
    mocks.get.mockResolvedValueOnce({
      approval_queue_state: { state: 'ready' }, tree: [canonical, padded, independent], summary: { ...emptySummary(), total_goals: 3 },
    })
    const decoded = await decodeGoalTree()
    mocks.route.value = { tab: 'workspace', params: { section: 'planning', goal: padded.id }, postId: null }
    mocks.fetchDashboardGoalsTree.mockResolvedValue(decoded)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal: independent, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(padded.id))
    expect(screen.queryByRole('button', { name: 'Pause' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Drop' })).toBeNull()
    expect(mocks.fetchDashboardGoalDetail).not.toHaveBeenCalled()
    expect(mocks.readGoalCandle).not.toHaveBeenCalled()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    expect(screen.queryByTestId('goal-task-create')).toBeNull()

    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: 'Canonical goal' } })
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(canonical.id))
    expect(screen.queryByRole('button', { name: 'Pause' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Drop' })).toBeNull()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    expect(screen.queryByTestId('goal-task-create')).toBeNull()

    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: 'Independent goal' } })
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(independent.id))
    expect(screen.getByRole('button', { name: 'Pause' })).toBeTruthy()
    expect(screen.getByTestId('goal-task-create')).toBeTruthy()
    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: '' } })
  })

  it('withholds decisions when the decoder discarded a duplicate ID with a blank title', async () => {
    const visible = makeGoal('goal-a', 'Visible goal')
    const hidden = { ...makeGoal('goal-a', ''), title: '' }
    mocks.get.mockResolvedValueOnce({
      approval_queue_state: { state: 'ready' }, tree: [visible, hidden], summary: { ...emptySummary(), total_goals: 2 },
    })
    const decoded = await decodeGoalTree()
    expect(decoded.tree).toHaveLength(1)
    expect(decoded.identity_observation).toEqual({ complete: true, ids: ['goal-a', 'goal-a'] })
    mocks.fetchDashboardGoalsTree.mockResolvedValue(decoded)
    render(html`<${GoalTree} />`)
    await screen.findByTestId('goal-detail-panel')
    expect(screen.queryByRole('button', { name: 'Pause' })).toBeNull()
    expect(mocks.fetchDashboardGoalDetail).not.toHaveBeenCalled()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('withholds decisions when the tree contains fewer IDs than the server total', async () => {
    mocks.get.mockResolvedValueOnce({ approval_queue_state: { state: 'ready' },
      tree: [makeGoal('goal-a', 'Visible goal')], summary: { ...emptySummary(), total_goals: 2 } })
    const decoded = await decodeGoalTree()
    expect(decoded.identity_observation?.complete).toBe(false)
    mocks.fetchDashboardGoalsTree.mockResolvedValue(decoded)
    render(html`<${GoalTree} />`)
    await screen.findByTestId('goal-detail-panel')
    expect(screen.queryByRole('button', { name: 'Pause' })).toBeNull()
    expect(mocks.fetchDashboardGoalDetail).not.toHaveBeenCalled()
  })

  it('clears a previous filter when a Work link opens a different Goal, then permits new filtering', async () => {
    const first = { ...makeGoal('goal-active', 'Active target'), priority: 2 }
    const second = { ...makeGoal('goal-done', 'Completed target'), phase: 'completed', priority: 1 }
    const tree = { approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === first.id ? first : second, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    const initial = render(html`<${GoalTree} />`)
    await screen.findByTestId('goal-detail-panel')
    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: 'Completed target' } })
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(second.id))
    initial.unmount()
    mocks.readGoalCandle.mockClear()
    mocks.route.value = { tab: 'workspace', params: { section: 'planning', goal: first.id }, postId: null }
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(first.id))
    expect((screen.getByLabelText('목표 트리 필터') as HTMLInputElement).value).toBe('')
    await waitFor(() => expect(mocks.readGoalCandle.mock.calls.map(args => args.slice(0, 4))).toContainEqual([
      first.id, { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }, 'fixture-a', expect.any(Function),
    ]))
    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: 'no matching target' } })
    await waitFor(() => expect(screen.queryByTestId('goal-detail-panel')).toBeNull())
    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: '' } })
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(first.id))
    expect(mocks.route.value.params.goal).toBe(first.id)
    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: 'Completed target' } })
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(second.id))
    expect(mocks.route.value.params.goal).toBeUndefined()
    expect(mocks.route.value.params.section).toBe('planning')
  })

  it.each(['completed', 'dropped'])('does not offer task creation for a %s Goal', async phase => {
    const initial = makeGoal('goal-closed', 'Closed goal')
    const goal = { ...initial, phase, goal_fsm: { ...initial.goal_fsm, state: phase, next_actions: [] } }
    mocks.route.value = { tab: 'workspace', params: { section: 'planning', goal: goal.id }, postId: null }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1 } })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({ goal, linked_tasks: [], linked_keepers: [], approvals: [],
      execution_receipts: [], timeline: [] })
    render(html`<${GoalTree} />`)
    await screen.findByTestId('goal-detail-panel')
    expect(screen.queryByTestId('goal-task-create')).toBeNull()
    expect(screen.getByText(/종료된 Goal에는 새 태스크를 연결할 수 없습니다/)).toBeTruthy()
  })

  it('does not substitute a different Goal when the routed Goal is absent in a new workspace', async () => {
    const first = makeGoal('goal-routed', 'Routed goal')
    const other = makeGoal('goal-other', 'Other workspace goal')
    mocks.route.value = { tab: 'workspace', params: { section: 'planning', goal: first.id }, postId: null }
    mocks.fetchDashboardGoalsTree.mockImplementation(async (workspace: { basePath: string }) => ({
      approval_queue_state: { state: 'ready' }, tree: [workspace.basePath === '/workspace-a' ? first : other],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === first.id ? first : other, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(first.id))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledWith({ basePath: '/workspace-b', mascRoot: '/workspace-b/.masc' }, expect.any(AbortSignal), expect.any(Function)))
    await screen.findByRole('button', { name: /Other workspace goal/ })
    expect(screen.queryByTestId('goal-detail-panel')).toBeNull()
    expect(mocks.readGoalCandle.mock.calls.filter(([id, workspace]) => id === other.id && workspace.basePath === '/workspace-b')).toHaveLength(0)
    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: 'nothing matches' } })
    await waitFor(() => expect(screen.queryByRole('button', { name: /Other workspace goal/ })).toBeNull())
    fireEvent.input(screen.getByLabelText('목표 트리 필터'), { target: { value: '' } })
    await screen.findByRole('button', { name: /Other workspace goal/ })
    expect(screen.queryByTestId('goal-detail-panel')).toBeNull()
    expect(mocks.route.value.params.goal).toBe(first.id)
    fireEvent.click(screen.getByRole('button', { name: /Other workspace goal/ }))
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(other.id))
  })

  it.each([
    ['executing', 'Request completion'],
    ['verifying', 'Retry verification'],
  ] as const)('explains unavailable proof for a %s Goal', async (phase, completionLabel) => {
    const goal: GoalTreeNode = {
      ...makeGoal('goal-unavailable-proof', 'Goal with unavailable proof'),
      phase,
      verification: { state: 'unreadable', detail: 'proof backend unavailable' },
      goal_fsm: { state: phase, source: 'goal.phase', next_actions: ['request_complete', 'pause'],
        activity_observation: 'goal_metadata' },
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    await screen.findByText(/서버의 저장소와 실행 환경을 확인하거나/)
    expect(screen.queryByRole('button', { name: completionLabel })).toBeNull()
    expect(screen.getByRole('button', { name: 'Pause' })).toBeTruthy()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it.each([
    ['missing', undefined],
    ['idle', { state: 'current', completion: { state: 'idle' } }],
    ['stale', { state: 'stale', historical: { state: 'pending', requestId: 'old-request',
      requestedAt: '2026-10-30T07:45:56Z', criterion: { revision: 'old-revision',
        title: 'Old goal', metric: null, target_value: null } } }],
    ['confirmed', { state: 'current', completion: { state: 'proven', requestId: 'confirmed-request',
      runId: 'confirmed-run', evidence: 'proof', recordedAt: '2026-10-30T07:45:56Z', actor: 'verifier',
      criterion: { revision: 'revision-default', title: 'Uncertain proof', metric: null, target_value: null },
      confirmation: { operatorId: 'operator', confirmedAt: '2026-10-30T08:00:00Z' } } }],
  ] satisfies Array<[string, GoalTreeNode['verification']]>)
  ('does not offer a retry for a verifying Goal with %s proof', async (_description, verification) => {
    const goal: GoalTreeNode = {
      ...makeGoal('goal-uncertain-proof', 'Uncertain proof'), phase: 'verifying', verification,
      goal_fsm: { state: 'verifying', source: 'goal.phase', next_actions: ['request_complete', 'pause'],
        activity_observation: 'goal_metadata' },
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    await screen.findByRole('button', { name: 'Pause' })
    expect(screen.queryByRole('button', { name: 'Retry verification' })).toBeNull()
    if (_description === 'idle') {
      expect(screen.getByText('검증 · 원장에 현재 요청 없음').getAttribute('title'))
        .toContain('이전 실행의 종료 여부는 확인되지 않았습니다')
    }
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('requests goal completion through the goal transition tool and refreshes goal data', async () => {
    const goal = {
      ...makeGoal('goal-ready', 'Ready goal'),
      task_count: 1,
      task_done_count: 1,
    } satisfies GoalTreeNode
    const treePayload: DashboardGoalsTreeResponse = {
      approval_queue_state: { state: 'ready' },
      tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1, total_tasks: 1, done_tasks: 1 },
    }
    const detailPayload: DashboardGoalDetailResponse = {
      goal,
      linked_tasks: [],
      linked_keepers: [],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue(treePayload)
    mocks.fetchDashboardGoalDetail.mockResolvedValue(detailPayload)
    mocks.callMcpTool.mockResolvedValue(transitionResponse('goal-ready', 'request_complete'))

    render(html`<${GoalTree} />`)

    await waitFor(() => {
      expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id'))
        .toBe('goal-ready')
    })
    fireEvent.click(screen.getByRole('button', { name: 'Request completion' }))

    await waitFor(() => {
      expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_transition', {
        goal_id: 'goal-ready',
        action: 'request_complete',
        expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
        expected_verification: { phase: 'executing', criterion_revision: 'revision-default' },
      })
    })
    expect(mocks.callIdentity).toHaveBeenCalledWith({ revision: expect.any(Number), actor: 'dashboard-test' })
    await waitFor(() => {
      expect(mocks.fetchDashboardGoalsTree.mock.calls.length).toBeGreaterThanOrEqual(2)
      expect(mocks.fetchDashboardGoalDetail.mock.calls.length).toBeGreaterThanOrEqual(2)
    })
    expect(screen.getByTestId('goal-lifecycle-action-status').textContent)
      .toContain('Request completion applied')
  })

  it('drops a Goal only with the reason the operator writes', async () => {
    const goal = makeGoal('goal-drop', 'Goal to drop')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue(transitionResponse('goal-drop', 'drop'))
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Drop' })).toBeTruthy())

    fireEvent.click(screen.getByRole('button', { name: 'Drop' }))
    const reason = document.querySelector<HTMLTextAreaElement>('[data-goal-drop-reason] textarea')
    expect(reason).not.toBeNull()
    const submit = screen.getByRole('button', { name: 'Drop goal' }) as HTMLButtonElement
    expect(submit.disabled).toBe(true)
    fireEvent.input(reason!, { target: { value: '   ' } })
    expect(submit.disabled).toBe(true)
    expect(mocks.callMcpTool).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: '사유 초안 지우기' }))
    expect(document.querySelector('[data-goal-drop-reason]')).toBeNull()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!,
      { target: { value: '  superseded by goal-next  ' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_transition', {
      goal_id: 'goal-drop', action: 'drop', note: 'superseded by goal-next',
      expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
    }))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-warning')).toBeTruthy())
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('  superseded by goal-next  ')
    fireEvent.click(screen.getByRole('button', { name: '사유 초안 지우기' }))
    expect(document.querySelector('[data-goal-drop-reason]')).toBeNull()
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['deferred delivery',
      { noop: false, effect_delivery: { status: 'deferred', durable_retry: true, detail: 'audit unavailable' } },
      ['요청 당시 Goal Drop이 적용되었다고 응답했습니다', 'audit unavailable']],
    ['already dropped', { noop: true, effect_delivery: { status: 'delivered' } },
      ['요청 당시 Goal이 이미 Dropped 상태였다고 응답했습니다', '입력한 사유는 이 요청으로 저장되지 않았습니다']],
    ['missing Goal change indicator', { effect_delivery: { status: 'delivered' } }, ['Goal 변경 여부를 확인할 수 없습니다']],
    ['contradictory Goal phase', { noop: false, phase: 'executing', goal: { id: 'goal-drop-partial', phase: 'executing' },
      effect_delivery: { status: 'delivered' } },
      ['Drop 응답에서 Goal 상태를 확인할 수 없습니다']],
    ['missing delivery status', { noop: false },
      ['요청 당시 Goal Drop이 적용되었다고 응답했습니다', 'Goal 기록·알림 일괄 전달 상태를 확인할 수 없습니다']],
  ])('shows a partial or unknown Drop result: %s', async (_label, fields, expected) => {
    const goal = makeGoal('goal-drop-partial', 'Partial drop')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue(JSON.stringify({ status: 'ok', goal_id: goal.id, action: 'drop',
      phase: 'dropped', goal: { id: goal.id, phase: 'dropped' }, ...fields }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'No longer needed' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    const receipt = await screen.findByTestId('goal-lifecycle-action-warning')
    for (const text of expected) expect(receipt.textContent).toContain(text)
    if (_label === 'contradictory Goal phase' || _label === 'missing Goal change indicator') {
      expect(receipt.textContent).not.toContain('요청 당시 Goal Drop이 적용되었다고 응답했습니다')
    }
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('No longer needed')
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
    expect(screen.queryByTestId('goal-lifecycle-action-error')).toBeNull()
  })

  it('retains a partial Drop result on its original Goal after selection changes', async () => {
    const first = makeGoal('goal-drop-origin', 'Drop origin')
    const second = makeGoal('goal-drop-other', 'Other goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 },
    })
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === first.id ? first : second,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Replace it' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    fireEvent.click(screen.getByRole('button', { name: /Other goal/ }))
    resolveAction(JSON.stringify({ status: 'ok', goal_id: first.id, action: 'drop', noop: false,
      phase: 'dropped', goal: { id: first.id, phase: 'dropped' },
      effect_delivery: { status: 'deferred', detail: '<span data-injected>bad</span>' } }))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(
      'Drop 시도 결과에 확인할 항목이 있습니다. 원래 workspace에서 확인하세요.', 'warning'))
    expect(screen.queryByTestId('goal-lifecycle-action-warning')).toBeNull()
    expect((await screen.findByTestId('goal-drop-detached-receipt')).textContent).toContain('<span data-injected>bad</span>')
    fireEvent.click(screen.getByRole('button', { name: /Drop origin/ }))
    const receipt = await screen.findByTestId('goal-lifecycle-action-warning')
    expect(receipt.textContent).toContain('<span data-injected>bad</span>')
    expect(document.querySelector('[data-injected]')).toBeNull()
  })

  it('keeps a Drop result accessible when the refreshed phase no longer matches the filter', async () => {
    const executing = makeGoal('goal-filter-drop', 'Filtered drop')
    const dropped: GoalTreeNode = { ...executing, phase: 'dropped',
      goal_fsm: { ...executing.goal_fsm, state: 'dropped', next_actions: ['reopen'] } }
    let committed = false
    mocks.fetchDashboardGoalsTree.mockImplementation(async () => ({
      approval_queue_state: { state: 'ready' }, tree: [committed ? dropped : executing],
      summary: { ...emptySummary(), total_goals: 1, active_goals: committed ? 0 : 1 },
    }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async () => ({
      goal: committed ? dropped : executing,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    mocks.callMcpTool.mockImplementation(async () => {
      committed = true
      return JSON.stringify({ status: 'ok', goal_id: executing.id, action: 'drop', noop: false,
        phase: 'dropped', goal: { id: executing.id, phase: 'dropped' },
        effect_delivery: { status: 'deferred', detail: 'candidate read failed' } })
    })
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('tab', { name: /실행 중/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'No longer relevant' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    const detached = await screen.findByTestId('goal-drop-detached-receipt')
    expect(detached.textContent).toContain('goal-filter-drop')
    expect(detached.textContent).toContain('candidate read failed')
    fireEvent.click(screen.getByRole('button', { name: '같은 ID Goal 열기' }))
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(executing.id))
    expect((await screen.findByTestId('goal-lifecycle-action-warning')).textContent).toContain('candidate read failed')
    expect(screen.queryByTestId('goal-drop-detached-receipt')).toBeNull()
  })

  it('labels a retained Drop response when a different Goal reuses the same id', async () => {
    const original = makeGoal('goal-reused', 'Original goal')
    const replacement = { ...makeGoal('goal-reused', 'Replacement goal'), created_at: '2026-11-02T09:00:00Z' }
    let current = original
    mocks.fetchDashboardGoalsTree.mockImplementation(async () => ({
      approval_queue_state: { state: 'ready' }, tree: [current],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async () => ({
      goal: current, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    mocks.callMcpTool.mockResolvedValue(JSON.stringify({ status: 'ok', goal_id: original.id, action: 'drop', noop: false,
      phase: 'dropped', goal: { id: original.id, phase: 'dropped' },
      effect_delivery: { status: 'deferred', detail: 'old-task' } }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Original reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    await screen.findByTestId('goal-lifecycle-action-warning')
    current = replacement
    fireEvent.click(await screen.findByRole('button', { name: '새로고침' }))
    await screen.findByRole('button', { name: /Replacement goal/ })
    const receipt = screen.getByTestId('goal-lifecycle-action-warning')
    expect(receipt.textContent).toContain('과거 Drop 시도 기록입니다')
    expect(receipt.textContent).toContain('같은 ID의 현재 Goal과 동일한 인스턴스인지는 확인되지 않았습니다')
    expect(receipt.textContent).toContain('요청 당시 Goal Drop이 적용되었다고 응답했습니다')
    expect(receipt.textContent).toContain('old-task')
  })

  it('redacts an earlier Drop result while the workspace root is unverified or has changed', async () => {
    const goal = makeGoal('goal-root-drop', 'Root drop')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue(JSON.stringify({ status: 'ok', goal_id: goal.id, action: 'drop', noop: false,
      phase: 'dropped', goal: { id: goal.id, phase: 'dropped' },
      effect_delivery: { status: 'deferred', detail: 'private-root-a-task' } }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    expect((await screen.findByTestId('goal-lifecycle-action-warning')).textContent).toContain('private-root-a-task')
    let resolveWorkspace!: (value: { basePath: string; mascRoot: string }) => void
    mocks.captureArtifactWorkspace.mockImplementation(() => new Promise(resolve => { resolveWorkspace = resolve }))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    await screen.findByTestId('goal-drop-receipt-owner-unverified')
    expect(document.body.textContent).not.toContain('private-root-a-task')
    await waitFor(() => expect(resolveWorkspace).toBeTypeOf('function'))
    resolveWorkspace({ basePath: '/workspace-a', mascRoot: '/workspace-a/new-masc' })
    await waitFor(() => expect(screen.queryByTestId('goal-drop-receipt-owner-unverified')).toBeNull())
    expect(document.body.textContent).not.toContain('private-root-a-task')
    expect(screen.queryByTestId('goal-drop-detached-receipt')).toBeNull()
  })

  it('offers an older connection\'s Drop result without attributing it to the current server', async () => {
    const first = makeGoal('goal-old-drop', 'Old connection goal')
    const second = makeGoal('goal-new-selection', 'New selection')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 },
    })
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === first.id ? first : second,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-restarted', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree.mock.calls.length).toBeGreaterThanOrEqual(2))
    fireEvent.click(await screen.findByRole('button', { name: /New selection/ }))
    resolveAction(JSON.stringify({ status: 'ok', goal_id: first.id, action: 'drop', noop: false,
      phase: 'dropped', goal: { id: first.id, phase: 'dropped' },
      effect_delivery: { status: 'deferred', detail: 'old-connection-detail' } }))
    const earlier = await screen.findByTestId('goal-drop-earlier-connection')
    expect(earlier.textContent).toContain('같은 ID Goal이 동일한 인스턴스인지는 확인되지 않았습니다')
    expect(earlier.textContent).not.toContain('old-connection-detail')
    fireEvent.click(screen.getByRole('button', { name: '같은 ID Goal 열기' }))
    const prior = await screen.findByTestId('goal-lifecycle-previous-connection')
    expect(prior.textContent).not.toContain('old-connection-detail')
    fireEvent.click(screen.getByRole('button', { name: '이전 연결 결과 보기' }))
    expect(prior.textContent).toContain('old-connection-detail')
    expect(prior.textContent).toContain('같은 workspace인지는 확인되지 않았습니다')
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-third', workspaceRoot: '/workspace-a', connectionGeneration: 3 }
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree.mock.calls.length).toBeGreaterThanOrEqual(3))
    const third = await screen.findByTestId('goal-lifecycle-previous-connection')
    expect(third.textContent).not.toContain('old-connection-detail')
    fireEvent.click(screen.getByRole('button', { name: '이전 연결 결과 보기' }))
    expect(third.textContent).toContain('old-connection-detail')
  })

  it('treats a new connection generation as a previous Drop owner even with the same epoch', async () => {
    const goal = makeGoal('goal-generation-drop', 'Generation goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue(JSON.stringify({ status: 'ok', goal_id: goal.id, action: 'drop', noop: false,
      phase: 'dropped', goal: { id: goal.id, phase: 'dropped' },
      effect_delivery: { status: 'deferred', detail: 'generation-private-detail' } }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    await screen.findByTestId('goal-lifecycle-action-warning')
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    const previous = await screen.findByTestId('goal-lifecycle-previous-connection')
    expect(previous.textContent).not.toContain('generation-private-detail')
    fireEvent.click(screen.getByRole('button', { name: '이전 연결 결과 보기' }))
    expect(previous.textContent).toContain('generation-private-detail')
  })

  it('treats a withdrawn and readmitted authority as previous even when all values match', async () => {
    const goal = makeGoal('goal-authority-drop', 'Authority goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue(JSON.stringify({ status: 'ok', goal_id: goal.id, action: 'drop', noop: false,
      phase: 'dropped', goal: { id: goal.id, phase: 'dropped' },
      effect_delivery: { status: 'deferred', detail: 'old-authority-detail' } }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    await screen.findByTestId('goal-lifecycle-action-warning')
    ;(executionWorkspaceAuthority as { value: unknown }).value = null
    await waitFor(() => expect(screen.queryByTestId('goal-lifecycle-action-warning')).toBeNull())
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 1 }
    const previous = await screen.findByTestId('goal-lifecycle-previous-connection')
    expect(previous.textContent).not.toContain('old-authority-detail')
    await waitFor(() => expect((screen.getByRole('button', { name: '새로고침' }) as HTMLButtonElement).disabled).toBe(false))
    fireEvent.click(screen.getByRole('button', { name: '이전 연결 결과 보기' }))
    expect(screen.getByTestId('goal-lifecycle-previous-connection').textContent).toContain('old-authority-detail')
  })

  it('can inspect an older connection\'s Drop result even if that Goal is no longer in the tree', async () => {
    const original = makeGoal('goal-old-deleted', 'Deleted goal')
    const remaining = makeGoal('goal-remains', 'Remaining goal')
    let restarted = false
    mocks.fetchDashboardGoalsTree.mockImplementation(async () => ({
      approval_queue_state: { state: 'ready' }, tree: restarted ? [remaining] : [original, remaining],
      summary: { ...emptySummary(), total_goals: restarted ? 1 : 2, active_goals: restarted ? 1 : 2 },
    }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === original.id ? original : remaining,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    restarted = true
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-restarted', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    await screen.findByRole('button', { name: /Remaining goal/ })
    const pending = await screen.findByTestId('goal-drop-earlier-connection')
    expect(pending.textContent).toContain('이전 연결의 Drop 시도가 진행 중입니다')
    expect(pending.textContent).not.toContain('Drop 결과가 있습니다')
    resolveAction(JSON.stringify({ status: 'ok', goal_id: original.id, action: 'drop', noop: false,
      phase: 'dropped', goal: { id: original.id, phase: 'dropped' },
      effect_delivery: { status: 'deferred', detail: 'deleted-goal-task-detail' } }))
    const earlier = await screen.findByTestId('goal-drop-earlier-connection')
    await waitFor(() => expect(earlier.textContent).toContain('이전 연결의 Drop 결과가 있습니다'))
    expect(earlier.textContent).toContain('goal-old-deleted')
    expect(earlier.textContent).not.toContain('deleted-goal-task-detail')
    expect(screen.queryByRole('button', { name: '같은 ID Goal 열기' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: '이전 연결 결과 보기' }))
    expect(earlier.textContent).toContain('deleted-goal-task-detail')
    expect(earlier.textContent).toContain('같은 workspace인지')
    expect(earlier.textContent).toContain('현재 Drop 사유 초안(이 시도 당시와 다를 수 있음): Reason')
    fireEvent.click(screen.getByRole('button', { name: '이 목록에서 숨기기' }))
    expect(screen.queryByTestId('goal-drop-earlier-connection')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: '숨긴 Drop 기록 다시 보기' }))
    const restored = await screen.findByTestId('goal-drop-earlier-connection')
    expect(restored.textContent).toContain('deleted-goal-task-detail')
    fireEvent.click(screen.getByRole('button', { name: '이 초안 지우기' }))
    expect(restored.textContent).not.toContain('현재 Drop 사유 초안(이 시도 당시와 다를 수 있음): Reason')
  })

  it('does not disclose a Drop result to a different credential but indicates that a result needs review', async () => {
    setStoredToken('credential-a')
    const goal = makeGoal('goal-auth-drop', 'Credential drop')
    const other = makeGoal('goal-auth-other', 'Other credential goal')
    let currentGoal = goal
    mocks.fetchDashboardGoalsTree.mockImplementation(async () => ({
      approval_queue_state: { state: 'ready' }, tree: [currentGoal, other],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 },
    }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === goal.id ? currentGoal : other, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    mocks.callMcpTool.mockResolvedValue(JSON.stringify({ status: 'ok', goal_id: goal.id, action: 'drop', noop: false,
      phase: 'dropped', goal: { id: goal.id, phase: 'dropped' },
      effect_delivery: { status: 'deferred', detail: 'credential-a-private-task' } }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    await screen.findByTestId('goal-lifecycle-action-warning')
    fireEvent.click(screen.getByRole('button', { name: /Other credential goal/ }))
    currentGoal = { ...goal, phase: 'dropped', goal_fsm: { ...goal.goal_fsm, state: 'dropped', next_actions: [] } }
    setStoredToken('credential-b')
    await screen.findByTestId('goal-drop-other-auth-unverified')
    expect(document.body.textContent).not.toContain('credential-a-private-task')
    fireEvent.click(await screen.findByRole('button', { name: /Credential drop/ }))
    await screen.findByText(/다른 연결 또는 인증의 Goal 요청에 확인이 필요한 항목이 있습니다/)
    expect(document.body.textContent).not.toContain('credential-a-private-task')
    expect(screen.queryByTestId('goal-drop-detached-receipt')).toBeNull()
  })

  it('asks for Goal inspection when a Drop response is lost after possible effects', async () => {
    const goal = makeGoal('goal-drop-timeout', 'Timed out drop')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    mocks.callMcpTool.mockRejectedValue(new Error('connection closed'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    const receipt = await screen.findByTestId('goal-lifecycle-action-error')
    expect(receipt.textContent).toContain('요청 결과를 확인하지 못했습니다. 다시 시도하기 전에 원래 Goal 상태를 확인하세요.')
  })

  it('does not put another Goal\'s Drop error in the global toast', async () => {
    vi.mocked(showToast).mockClear()
    const goal = makeGoal('goal-secret-drop', 'Secret drop')
    const other = makeGoal('goal-other-selected', 'Other selected goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal, other],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 },
    })
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === goal.id ? goal : other, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    fireEvent.click(screen.getByRole('button', { name: /Other selected goal/ }))
    rejectAction(new Error('sensitive error'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith('Drop 시도의 결과를 원래 workspace에서 확인하세요.', 'warning'))
    const calls = JSON.stringify(vi.mocked(showToast).mock.calls)
    expect(calls).not.toContain('goal-secret-drop')
    expect(calls).not.toContain('sensitive error')
    expect((await screen.findByTestId('goal-drop-detached-receipt')).textContent).toContain('sensitive error')
  })

  it('does not put the Drop Goal id in a global toast after the credential changes', async () => {
    vi.mocked(showToast).mockClear()
    setStoredToken('credential-before')
    const goal = makeGoal('goal-secret-previous-auth', 'Previous credential goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    setStoredToken('credential-after')
    resolveAction(transitionResponse(goal.id, 'drop'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(
      '이전 연결의 Goal 변경 결과가 도착했습니다. 원래 workspace에서 확인하세요.', 'warning'))
    expect(JSON.stringify(vi.mocked(showToast).mock.calls)).not.toContain('goal-secret-previous-auth')
  })

  it('does not claim a pre-dispatch Drop attempt was sent', async () => {
    const goal = makeGoal('goal-drop-predispatch', 'Pre-dispatch drop')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.mcpCallFailureDisposition.mockReturnValue('known_pre_effect')
    mocks.callMcpTool.mockRejectedValue(new Error('changed before dispatch'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    const receipt = await screen.findByTestId('goal-lifecycle-action-error')
    expect(receipt.textContent).toContain('과거 Drop 시도 기록입니다')
    expect(receipt.textContent).toContain('changed before dispatch')
    expect(receipt.textContent).not.toContain('보낸 과거 Drop')
  })

  it('retains a pre-dispatch error when its Goal leaves the current tree', async () => {
    const goal = makeGoal('goal-rejected-deleted', 'Rejected goal')
    const other = makeGoal('goal-rejected-other', 'Other goal')
    let includeOriginal = true
    mocks.fetchDashboardGoalsTree.mockImplementation(async () => ({
      approval_queue_state: { state: 'ready' }, tree: includeOriginal ? [goal, other] : [other],
      summary: { ...emptySummary(), total_goals: includeOriginal ? 2 : 1, active_goals: includeOriginal ? 2 : 1 },
    }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === goal.id ? goal : other, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    mocks.mcpCallFailureDisposition.mockReturnValue('known_pre_effect')
    mocks.callMcpTool.mockRejectedValue(new Error('rejected before dispatch'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Preserved reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    await screen.findByTestId('goal-lifecycle-action-error')
    includeOriginal = false
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    const detached = await screen.findByTestId('goal-drop-detached-receipt')
    expect(detached.textContent).toContain('rejected before dispatch')
    expect(detached.textContent).toContain('현재 Drop 사유 초안(이 시도 당시와 다를 수 있음): Preserved reason')
  })

  it('preserves a Drop reason when a later lifecycle action is requested', async () => {
    const goal = makeGoal('goal-drop-draft-pause', 'Draft and pause')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValueOnce(JSON.stringify({ status: 'ok', goal_id: goal.id, action: 'drop',
      phase: 'dropped', goal: { id: goal.id, phase: 'dropped' },
      effect_delivery: { status: 'delivered' } }))
      .mockResolvedValueOnce(transitionResponse(goal.id, 'pause'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Keep this reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    await screen.findByTestId('goal-lifecycle-action-warning')
    await waitFor(() => expect((screen.getByRole('button', { name: 'Pause' }) as HTMLButtonElement).disabled).toBe(false))
    fireEvent.click(screen.getByRole('button', { name: 'Pause' }))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-status').textContent).toContain('Pause applied'))
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('Keep this reason')
  })

  it('keeps an unsubmitted Drop draft accessible when its Goal leaves the tree', async () => {
    const goal = makeGoal('goal-unsent-deleted', 'Unsent goal')
    const other = makeGoal('goal-unsent-other', 'Other remaining goal')
    let includeOriginal = true
    mocks.fetchDashboardGoalsTree.mockImplementation(async () => ({
      approval_queue_state: { state: 'ready' }, tree: includeOriginal ? [goal, other] : [other],
      summary: { ...emptySummary(), total_goals: includeOriginal ? 2 : 1, active_goals: includeOriginal ? 2 : 1 },
    }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === goal.id ? goal : other, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Unsent reason' } })
    includeOriginal = false
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    const draft = await screen.findByTestId('goal-drop-detached-draft')
    expect(draft.textContent).toContain('goal-unsent-deleted')
    expect(draft.textContent).toContain('Unsent reason')
    expect(draft.textContent).toContain('동일한 인스턴스인지는 확인되지 않았습니다')
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('offers an anonymous draft after dashboard bootstrap even when its Goal was removed', async () => {
    mocks.currentDashboardActor.mockReturnValue('dashboard')
    const goal = makeGoal('goal-bootstrap-deleted', 'Bootstrap goal')
    const other = makeGoal('goal-bootstrap-other', 'Remaining bootstrap goal')
    let includeOriginal = true
    mocks.fetchDashboardGoalsTree.mockImplementation(async () => ({
      approval_queue_state: { state: 'ready' }, tree: includeOriginal ? [goal, other] : [other],
      summary: { ...emptySummary(), total_goals: includeOriginal ? 2 : 1, active_goals: includeOriginal ? 2 : 1 },
    }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === goal.id ? goal : other, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Anonymous reason' } })
    includeOriginal = false
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const draft = await screen.findByTestId('goal-drop-detached-draft')
    expect(draft.textContent).not.toContain('Anonymous reason')
    fireEvent.click(screen.getByRole('button', { name: '이전 연결 초안 보기' }))
    expect(draft.textContent).toContain('Anonymous reason')
    expect(draft.textContent).toContain('같은 workspace인지는 확인되지 않았습니다')
  })

  it('keeps a sent Drop attempt visible while its original Goal is absent', async () => {
    const goal = makeGoal('goal-pending-deleted', 'Pending goal')
    const other = makeGoal('goal-pending-other', 'Other pending goal')
    let includeOriginal = true
    mocks.fetchDashboardGoalsTree.mockImplementation(async () => ({
      approval_queue_state: { state: 'ready' }, tree: includeOriginal ? [goal, other] : [other],
      summary: { ...emptySummary(), total_goals: includeOriginal ? 2 : 1, active_goals: includeOriginal ? 2 : 1 },
    }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === goal.id ? goal : other, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Pending reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    includeOriginal = false
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    const receipt = await screen.findByTestId('goal-drop-detached-receipt')
    expect(receipt.textContent).toContain('Drop 시도가 진행 중입니다')
    expect(receipt.textContent).toContain('서버 수신 여부는 확인되지 않았습니다')
    expect(receipt.textContent).toContain('Pending reason')
    expect(screen.queryByRole('button', { name: '이 초안 지우기' })).toBeNull()
    resolveAction(transitionResponse(goal.id, 'drop'))
    await waitFor(() => expect(screen.getByTestId('goal-drop-detached-receipt').textContent)
      .toContain('요청 당시 Goal Drop이 적용되었다고 응답했습니다'))
  })

  it('distinguishes the submitted reason from a later edited draft', async () => {
    const goal = makeGoal('goal-reason-history', 'Reason history')
    const other = makeGoal('goal-reason-other', 'Other reason goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal, other],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 },
    })
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === goal.id ? goal : other, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    mocks.callMcpTool.mockResolvedValue(transitionResponse(goal.id, 'drop'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Attempt reason A' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    await screen.findByTestId('goal-lifecycle-action-warning')
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Edited draft B' } })
    fireEvent.click(screen.getByRole('button', { name: /Other reason goal/ }))
    const receipt = await screen.findByTestId('goal-drop-detached-receipt')
    expect(receipt.textContent).toContain('이 시도에서 입력한 사유(앞뒤 공백 제거): Attempt reason A')
    expect(receipt.textContent).toContain('현재 Drop 사유 초안(이 시도 당시와 다를 수 있음): Edited draft B')
  })

  it('keeps a Drop draft visible without enabling submission when the refreshed Goal has no actions', async () => {
    const goal = makeGoal('goal-draft-no-actions', 'Draft without actions')
    let current = goal
    mocks.fetchDashboardGoalsTree.mockImplementation(async () => ({
      approval_queue_state: { state: 'ready' }, tree: [current],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    }))
    mocks.fetchDashboardGoalDetail.mockImplementation(async () => ({
      goal: current, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Still needed' } })
    current = { ...goal, phase: 'dropped', goal_fsm: { ...goal.goal_fsm, state: 'dropped', next_actions: [] } }
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect((screen.getByRole('button', { name: 'Drop goal' }) as HTMLButtonElement).disabled).toBe(true))
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('Still needed')
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it.each([
    [transitionResponse('goal-verifying-retry', 'request_complete'), 'Verification retry requested'],
    [transitionResponse('goal-verifying-retry', 'request_complete', true), 'Existing verification reconciled'],
  ])('shows the server outcome for a verifying Goal: %s', async (response, status) => {
    const goal: GoalTreeNode = {
      ...makeGoal('goal-verifying-retry', 'Goal awaiting verification'), phase: 'verifying',
      verification: { state: 'current', completion: { state: 'pending', requestId: 'proof-request-1',
        requestedAt: '2026-10-30T07:45:56Z', criterion: { revision: 'revision-default',
          title: 'Goal awaiting verification', metric: null, target_value: null } } },
      goal_fsm: {
        state: 'verifying', source: 'goal.phase',
        next_actions: ['request_complete', 'drop', 'reopen', 'pause', 'block'],
        activity_observation: 'goal_metadata',
      },
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue(response)
    render(html`<${GoalTree} />`)

    fireEvent.click(await screen.findByRole('button', { name: 'Retry verification' }))
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_transition', {
      goal_id: 'goal-verifying-retry', action: 'request_complete',
      expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
      expected_verification: { phase: 'verifying', criterion_revision: 'revision-default', request_id: 'proof-request-1' },
    }))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-status').textContent)
      .toContain(status))
  })

  it.each([
    ['empty object', '{}'],
    ['wrong Goal', transitionResponse('another-goal', 'request_complete')],
    ['wrong action', transitionResponse('goal-untrusted-response', 'pause')],
    ['non-JSON', 'accepted'],
  ])('keeps a %s transition response as an unknown outcome', async (_description, response) => {
    const goal = makeGoal('goal-untrusted-response', 'Untrusted response goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    mocks.callMcpTool.mockResolvedValue(response)
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    expect((await screen.findByTestId('goal-lifecycle-action-error')).textContent)
      .toContain('요청 결과를 확인하지 못했습니다')
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('does not claim a retry when the original execution is unresolved', async () => {
    const goal: GoalTreeNode = {
      ...makeGoal('goal-unknown', 'Unknown verification'), phase: 'verifying',
      verification: { state: 'current', completion: { state: 'pending', requestId: 'request-unknown',
        requestedAt: '2026-10-30T07:45:56Z', criterion: { revision: 'revision-default',
          title: 'Unknown verification', metric: null, target_value: null } } },
      goal_fsm: { state: 'verifying', source: 'goal.phase', next_actions: ['request_complete', 'reopen'],
        activity_observation: 'goal_metadata' },
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockRejectedValue(new Error('original outcome is unknown; no new review was started'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Retry verification' }))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-error').textContent)
      .toContain('original outcome is unknown'))
    expect(screen.getByTestId('goal-lifecycle-action-binding').textContent).toContain('request-unknown')
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
  })

  it('retains an unknown transport outcome for the original Goal after navigation', async () => {
    const first = makeGoal('goal-transport-origin', 'Transport origin')
    const second = makeGoal('goal-transport-other', 'Transport other')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 },
    })
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === first.id ? first : second,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    fireEvent.click(screen.getByRole('button', { name: /Transport other/ }))
    rejectAction(new Error('POST /mcp: timeout'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(expect.stringContaining('요청 결과를 확인하지 못했습니다'), 'error'))
    fireEvent.click(await screen.findByRole('button', { name: /Transport origin/ }))
    const receipt = await screen.findByTestId('goal-lifecycle-action-error')
    expect(receipt.textContent).toContain('다시 시도하기 전에 원래 Goal 상태를 확인하세요')
    expect(receipt.textContent).toContain('POST /mcp: timeout')
  })

  it('keeps an earlier unknown proof result when a later Goal action completes', async () => {
    const goal: GoalTreeNode = {
      ...makeGoal('goal-history', 'Goal with history'), phase: 'verifying',
      verification: { state: 'current', completion: { state: 'pending', requestId: 'proof-original',
        requestedAt: '2026-10-30T07:45:56Z', criterion: { revision: 'revision-default',
          title: 'Goal with history', metric: null, target_value: null } } },
      goal_fsm: { state: 'verifying', source: 'goal.phase',
        next_actions: ['request_complete', 'pause'], activity_observation: 'goal_metadata' },
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockRejectedValueOnce(new Error('original outcome unknown')).mockResolvedValueOnce(transitionResponse('goal-history', 'pause'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Retry verification' }))
    await screen.findByTestId('goal-lifecycle-action-error')
    fireEvent.click(screen.getByRole('button', { name: 'Pause' }))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-status').textContent).toContain('Pause applied'))
    expect(screen.getByTestId('goal-lifecycle-action-history').textContent).toContain('original outcome unknown')
    expect(screen.getByTestId('goal-lifecycle-action-history').textContent).toContain('proof-original')
  })

  it.each(['success', 'failure'] as const)('keeps a %s response with its original Goal after navigation', async outcome => {
    const first = makeGoal('goal-origin', 'Origin goal')
    const second = makeGoal('goal-selected', 'Selected goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === first.id ? first : second,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    let resolveAction!: (value: string) => void
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((resolve, reject) => {
      resolveAction = resolve
      rejectAction = reject
    }))
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(first.id))
    fireEvent.click(screen.getByRole('button', { name: 'Request completion' }))
    fireEvent.click(screen.getByRole('button', { name: /Selected goal/ }))
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(second.id))
    const firstReads = mocks.fetchDashboardGoalDetail.mock.calls.filter(([id]) => id === first.id).length
    if (outcome === 'success') resolveAction(transitionResponse(first.id, 'request_complete'))
    else rejectAction(new Error('original outcome is unknown'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(
      outcome === 'success' ? 'Goal goal-origin: Request completion applied' : expect.stringContaining('Goal goal-origin: original outcome is unknown'),
      ...(outcome === 'success' ? [] : ['error']),
    ))
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(second.id))
    expect(mocks.fetchDashboardGoalDetail.mock.calls.filter(([id]) => id === first.id)).toHaveLength(firstReads)
    fireEvent.click(screen.getByRole('button', { name: /Origin goal/ }))
    const result = await screen.findByTestId(outcome === 'success' ? 'goal-lifecycle-action-status' : 'goal-lifecycle-action-error')
    expect(result.textContent).toContain(outcome === 'success' ? 'Request completion applied' : 'original outcome is unknown')
  })

  it('does not apply an old workspace response to the same Goal id in a new workspace', async () => {
    const goal = makeGoal('goal-same-id', 'Workspace goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(1))
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    expect(screen.getByTestId('goal-operation-notice').textContent).toContain('처리 중')
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect((screen.getByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(false))
    await waitFor(() => expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledWith(goal.id,
      { basePath: '/workspace-b', mascRoot: '/workspace-b/.masc' }, expect.any(Function)))
    expect(screen.queryByTestId('goal-operation-notice')).toBeNull()
    const reads = mocks.fetchDashboardGoalDetail.mock.calls.length
    resolveAction(transitionResponse(goal.id, 'request_complete'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(
      '이전 연결의 Goal 변경 결과가 도착했습니다. 원래 workspace에서 확인하세요.', 'warning',
    ))
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
    expect(screen.queryByTestId('goal-operation-notice')).toBeNull()
    expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(reads)
  })

  it('keeps the original request result when the server restarts on the same workspace', async () => {
    const goal = makeGoal('goal-restarted-server', 'Restarted server goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-restarted', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    await waitFor(() => expect((screen.getByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(true))
    rejectAction(new Error('connection closed'))
    const prior = await screen.findByTestId('goal-lifecycle-previous-connection')
    await waitFor(() => expect(prior.textContent).toContain('요청 결과를 확인하지 못했습니다'))
    expect(prior.textContent).toContain('connection closed')
    expect(prior.textContent).toContain('revision-default')
    expect(prior.textContent).toContain('같은 workspace인지는 확인되지 않았습니다')
    expect(screen.queryByTestId('goal-lifecycle-action-error')).toBeNull()
  })

  it('keeps a managed dev actor receipt and draft across token rotation', async () => {
    setStoredToken('dev-token-one', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const goal = makeGoal('goal-dev-rotation', 'Dev rotation goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Retain this reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    setStoredToken('dev-token-two', { source: 'dev', actor: 'dashboard', role: 'admin' })
    rejectAction(new Error('connection closed'))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-error').textContent).toContain('connection closed'))
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('Retain this reason')
  })

  it('blocks a different credential during an earlier request without exposing its result', async () => {
    setStoredToken('manual-token-a', { source: 'manual' })
    const goal = makeGoal('goal-credential-pending', 'Credential pending goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    setStoredToken('manual-token-b', { source: 'manual' })
    const button = await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement
    await waitFor(() => expect(button.disabled).toBe(true))
    rejectAction(new Error('private prior result'))
    await screen.findByText(/다른 연결 또는 인증의 Goal 요청에 확인이 필요한 항목이 있습니다/)
    expect(screen.queryByText(/private prior result/)).toBeNull()
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('reports when bootstrap changes the credential before sending', async () => {
    const goal = makeGoal('goal-before-dispatch', 'Before dispatch goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('known_pre_effect')
    mocks.mcpIdentityRequiresGoalRefresh.mockReturnValue(true)
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    rejectAction(new Error('changed before dispatch'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(expect.stringContaining('Goal을 변경하지 않았습니다'), 'warning'))
  })

  it('reloads an initial read when the unauthenticated actor changes', async () => {
    const goal = makeGoal('goal-actor-read', 'Actor read goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let actor = 'actor-a'
    let resolveOld!: (tree: DashboardGoalsTreeResponse) => void
    mocks.currentDashboardActor.mockImplementation(() => actor)
    mocks.fetchDashboardGoalsTree.mockImplementation(() => actor === 'actor-a'
      ? new Promise(resolve => { resolveOld = resolve }) : Promise.resolve(tree))
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalled())
    actor = 'actor-b'
    setCanonicalDashboardActor('actor-b')
    await screen.findByRole('button', { name: 'Request completion' })
    resolveOld(tree)
    await waitFor(() => expect((screen.getByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(false))
  })

  it('rechecks a pending bearer request when its canonical actor changes', async () => {
    setStoredToken('manual-bearer', { source: 'manual' })
    const goal = makeGoal('goal-actor-hint', 'Actor hint goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    mocks.currentDashboardActor.mockReturnValue('alice')
    setCanonicalDashboardActor('alice')
    await waitFor(() => expect((screen.getByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(true))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    resolveAction(transitionResponse(goal.id, 'request_complete'))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(3))
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('keeps a drop reason with its originating workspace', async () => {
    const goal = makeGoal('goal-drop-owner', 'Drop owner goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'A reason' } })
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledWith(
      { basePath: '/workspace-b', mascRoot: '/workspace-b/.masc' }, expect.any(AbortSignal), expect.any(Function)))
    await waitFor(() => expect(document.querySelector('[data-goal-drop-reason]')).toBeNull())
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('')
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('offers an explicit copy of an unsent draft from a previous server connection', async () => {
    const goal = makeGoal('goal-draft-restart', 'Draft restart goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Original reason' } })
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-restarted', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    const previousDraft = await screen.findByTestId('goal-drop-previous-drafts')
    expect(previousDraft.textContent).not.toContain('Original reason')
    fireEvent.click(screen.getByRole('button', { name: '이전 연결 초안 보기' }))
    expect(previousDraft.textContent).toContain('Original reason')
    expect(document.querySelector('[data-goal-drop-reason]')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: '이 사유를 현재 입력에 복사' }))
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('Original reason')
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Current draft' } })
    expect((screen.getByRole('button', { name: '이 사유를 현재 입력에 복사' }) as HTMLButtonElement).disabled).toBe(true)
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('Current draft')
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('offers an anonymous dashboard draft after dev-token bootstrap', async () => {
    mocks.currentDashboardActor.mockReturnValue('dashboard')
    const goal = makeGoal('goal-draft-bootstrap', 'Bootstrap draft goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('known_pre_effect')
    mocks.mcpIdentityRequiresGoalRefresh.mockReturnValue(true)
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Saved before login' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    rejectAction(new Error('changed before dispatch'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(expect.stringContaining('Goal을 변경하지 않았습니다'), 'warning'))
    await screen.findByTestId('goal-drop-previous-drafts')
    fireEvent.click(screen.getByRole('button', { name: '이전 연결 초안 보기' }))
    expect(screen.getByTestId('goal-drop-previous-drafts').textContent).toContain('Saved before login')
    expect(document.querySelector('[data-goal-drop-reason]')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: '이 사유를 현재 입력에 복사' }))
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('Saved before login')
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('blocks a new dev action while an anonymous dashboard request remains pending', async () => {
    mocks.currentDashboardActor.mockReturnValue('dashboard')
    const goal = makeGoal('goal-pending-bootstrap', 'Pending bootstrap goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Pending reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    await screen.findByTestId('goal-lifecycle-previous-connection')
    expect((screen.getByRole('button', { name: 'Drop' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: '이전 연결 초안 보기' }))
    expect((screen.getByRole('button', { name: '이 사유를 현재 입력에 복사' }) as HTMLButtonElement).disabled).toBe(true)
    rejectAction(new Error('connection closed'))
    await screen.findByRole('button', { name: '이전 연결 결과 보기' })
    fireEvent.click(screen.getByRole('button', { name: '이전 연결 결과 보기' }))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-previous-connection').textContent).toContain('connection closed'))
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('does not send an action from the previous workspace tree while the new tree is loading', async () => {
    const goal = makeGoal('goal-cloned', 'Cloned goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let resolveNext!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree)
      .mockImplementationOnce(() => new Promise(resolve => { resolveNext = resolve }))
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    const button = await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement
    await waitFor(() => expect(button.disabled).toBe(false))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    expect(screen.queryByRole('button', { name: 'Request completion' })).toBeNull()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    resolveNext(tree)
    expect((await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(false)
  })

  it('keeps an action with the captured masc root when the same base changes roots', async () => {
    const goal = makeGoal('goal-root-swap', 'Root swap goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let root = '/root-a'
    mocks.captureArtifactWorkspace.mockImplementation(async () => ({ basePath: '/workspace-a', mascRoot: root }))
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    const button = await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement
    await waitFor(() => expect(button.disabled).toBe(false))
    fireEvent.click(button)
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_transition', expect.objectContaining({
      expected_workspace: { base_path: '/workspace-a', masc_root: '/root-a' },
    })))
    root = '/root-b'
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledWith(
      { basePath: '/workspace-a', mascRoot: '/root-b' }, expect.any(AbortSignal), expect.any(Function)))
    await waitFor(() => expect((screen.getByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(false))
    resolveAction(transitionResponse(goal.id, 'request_complete'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(
      '이전 연결의 Goal 변경 결과가 도착했습니다. 원래 workspace에서 확인하세요.', 'warning',
    ))
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
  })

  it('does not refresh or acknowledge an old assignment against a changed root', async () => {
    let root = '/root-a'
    let oldOwnerCurrent = () => false
    let oldRefreshAfterWrite = () => false
    mocks.captureArtifactWorkspace.mockImplementation(async () => ({ basePath: '/workspace-a', mascRoot: root }))
    mocks.fetchDashboardGoalsTree.mockResolvedValue({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    function AssignmentObservationProbe() {
      const observed = useGoalTreeDecisionObservation()
      return html`<div>
        <span data-testid="assignment-observation">${observed.isCurrent() ? 'ready' : 'pending'}</span>
        <button type="button" onClick=${() => { oldOwnerCurrent = observed.isOwnerCurrent; oldRefreshAfterWrite = observed.refreshAfterWrite }}>capture</button>
        <button type="button" onClick=${() => { void observed.refresh() }}>refresh</button>
      </div>`
    }
    render(html`<${AssignmentObservationProbe} />`)
    await waitFor(() => expect(screen.getByTestId('assignment-observation').textContent).toBe('ready'))
    fireEvent.click(screen.getByRole('button', { name: 'capture' }))
    expect(oldOwnerCurrent()).toBe(true)
    root = '/root-b'
    fireEvent.click(screen.getByRole('button', { name: 'refresh' }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledWith(
      { basePath: '/workspace-a', mascRoot: '/root-b' }, expect.any(AbortSignal), expect.any(Function)))
    await waitFor(() => expect(screen.getByTestId('assignment-observation').textContent).toBe('ready'))
    const reads = mocks.fetchDashboardGoalsTree.mock.calls.length
    expect(oldOwnerCurrent()).toBe(false)
    expect(oldRefreshAfterWrite()).toBe(false)
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(reads)
  })

  it.each(['empty', 'url'] as const)('does not expose a %s credential receipt after switching to a dev token', async initial => {
    if (initial === 'url') {
      mocks.currentDashboardActor.mockReturnValue('dashboard')
      setStoredToken('test-url-token', { source: 'url' })
    }
    const goal = makeGoal('goal-bootstrap', 'Bootstrap goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    setStoredToken('test-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    resolveAction(transitionResponse(goal.id, 'request_complete'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(expect.stringContaining('이전 연결의 Goal 변경 결과'), 'warning'))
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
    expect(screen.queryByTestId('goal-lifecycle-previous-connection')).toBeNull()
  })

  it('waits for the initial workspace observation before sending an action', async () => {
    ;(executionWorkspaceAuthority as { value: unknown }).value = null
    const goal = makeGoal('goal-wait', 'Waiting goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue(transitionResponse(goal.id, 'request_complete'))
    render(html`<${GoalTree} />`)
    await screen.findByText(/workspace를 확인할 수 없습니다/)
    expect(screen.queryByRole('button', { name: 'Request completion' })).toBeNull()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 1 }
    const button = await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement
    await waitFor(() => expect(button.disabled).toBe(false))
    fireEvent.click(button)
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledTimes(1))
  })

  it('shows a workspace observation failure and retries its source', async () => {
    ;(executionWorkspaceAuthority as { value: unknown }).value = null
    ;(executionError as { value: string | null }).value = 'execution unavailable'
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary(),
    })
    render(html`<${GoalTree} />`)
    await screen.findByText(/execution unavailable/)
    fireEvent.click(screen.getByRole('button', { name: '다시 확인' }))
    expect(mocks.refreshExecution).toHaveBeenCalledWith({ force: true })
  })

  it('rechecks the workspace after another source replaces the shared tree', async () => {
    const goal = makeGoal('goal-shared-refresh', 'Shared refresh goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    const button = await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement
    await waitFor(() => expect(button.disabled).toBe(false))
    const reads = mocks.fetchDashboardGoalsTree.mock.calls.length
    hydrateGoalTreeSnapshot(tree)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree.mock.calls.length).toBeGreaterThan(reads))
    await waitFor(() => expect(button.disabled).toBe(false))
  })

  it.each([
    ['paused', 'resume', 'Resume', 'verifying'],
    ['blocked', 'unblock', 'Unblock', 'awaiting_confirmation'],
  ] as const)('restores a %s Goal using server actions', async (phase, action, label, restore) => {
    const goal = {
      ...makeGoal('goal-suspended', 'Suspended goal'), phase, resume_phase: restore,
      goal_fsm: { state: phase, source: 'goal.phase', next_actions: [action, 'drop', 'reopen'], activity_observation: 'goal_metadata' },
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, phase_counts: { [phase]: 1 } },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue(transitionResponse(goal.id, action))
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByRole('button', { name: label })).toBeTruthy())
    expect(document.querySelector('[data-goal-resume-phase]')?.textContent).toContain('재개 시')
    expect(screen.queryByRole('button', { name: 'Request completion' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: label }))
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_transition', {
      goal_id: 'goal-suspended', action, expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
    }))
  })

  it('renders a verifying goal with phase label, filter chip, and summary count', async () => {
    const goal = { ...makeGoal('goal-verifying', 'Verifying goal'), phase: 'verifying' }
    const treePayload: DashboardGoalsTreeResponse = {
      approval_queue_state: { state: 'ready' },
      tree: [goal],
      summary: {
        ...emptySummary(),
        total_goals: 1,
        active_goals: 1,
        phase_counts: { verifying: 1 },
      },
    }
    const detailPayload: DashboardGoalDetailResponse = {
      goal,
      linked_tasks: [],
      linked_keepers: [],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue(treePayload)
    mocks.fetchDashboardGoalDetail.mockResolvedValue(detailPayload)

    render(html`<${GoalTree} />`)

    await waitFor(() => {
      expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id'))
        .toBe('goal-verifying')
    })
    // Tree node badge and the phase filter chip both render the Korean label.
    expect(screen.getAllByText('검증 중').length).toBeGreaterThanOrEqual(2)
  })

  it('renders a loading indicator while the goal tree is refreshing', async () => {
    const goal = makeGoal('goal-loading', 'Loading goal')
    const treePayload: DashboardGoalsTreeResponse = {
      approval_queue_state: { state: 'ready' },
      tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    }
    const detailPayload: DashboardGoalDetailResponse = {
      goal,
      linked_tasks: [],
      linked_keepers: [],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    }
    let resolveTree: (value: unknown) => void = () => {}
    mocks.fetchDashboardGoalsTree.mockImplementation(() => new Promise(resolve => { resolveTree = resolve }))
    mocks.fetchDashboardGoalDetail.mockResolvedValue(detailPayload)

    render(html`<${GoalTree} />`)

    expect(screen.getByText('goal manager 로드 중...')).toBeTruthy()
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1))
    resolveTree(treePayload)
    await waitFor(() => {
      expect(screen.queryByTestId('goal-tree-loading')).toBeNull()
    })
  })

  // RFC-0444 §2.3 row 4 / criterion 9: a Goal store this build cannot read is
  // drawn as an alert with file · reason · mirror · reset step, and the create
  // form refuses to submit while that state stands.
  it('keeps a Goal store error from an earlier workspace out of the new workspace view', async () => {
    const failure = new GoalSourceUnavailableError({
      kind: 'unavailable', reason: 'not_json', field: null, file: '/workspace-a/private-goals.json',
      mirror: { status: 'mirror_absent', goalCount: null }, resetStep: 'reset_goal_store',
    })
    mocks.fetchDashboardGoalsTree.mockImplementation((workspace: { basePath: string }) =>
      workspace.basePath === '/workspace-a' ? Promise.reject(failure) : new Promise(() => {}))
    render(html`<${GoalTree} />`)
    expect((await screen.findByTestId('goal-store-unavailable')).textContent).toContain('/workspace-a/private-goals.json')
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(screen.queryByTestId('goal-store-unavailable')).toBeNull())
  })

  it('shows a workspace-bound Goal store failure returned by detail', async () => {
    const goal = makeGoal('goal-detail-store-failure', 'Detail store failure')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockRejectedValue(new GoalSourceUnavailableError({
      kind: 'unavailable', reason: 'not_json', field: null, file: '/workspace-a/detail-goals.json',
      mirror: { status: 'mirror_absent', goalCount: null }, resetStep: 'reset_goal_store',
    }))
    render(html`<${GoalTree} />`)
    expect((await screen.findByTestId('goal-store-unavailable')).textContent).toContain('/workspace-a/detail-goals.json')
  })

  it('rechecks an unowned shared Goal store error without showing its contents', async () => {
    const goal = makeGoal('goal-shared-error', 'Shared error goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    await screen.findByRole('button', { name: 'Request completion' })
    const count = mocks.fetchDashboardGoalsTree.mock.calls.length
    mocks.fetchDashboardGoalsTree.mockImplementation(() => new Promise(() => {}))
    hydrateGoalTreeError(new GoalSourceUnavailableError({
      kind: 'unavailable', reason: 'not_json', field: null, file: '/other-workspace/private.json',
      mirror: { status: 'mirror_absent', goalCount: null }, resetStep: 'reset_goal_store',
    }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree.mock.calls.length).toBeGreaterThan(count))
    expect(screen.queryByText('/other-workspace/private.json')).toBeNull()
  })

  it('draws the Goal store failure as an alert and refuses goal creation', async () => {
    mocks.fetchDashboardGoalsTree.mockRejectedValue(new GoalSourceUnavailableError({
      kind: 'unavailable',
      reason: 'schema_rejected',
      field: 'criterion_revision',
      file: '/srv/masc/.masc/goals.json',
      mirror: { status: 'mirror_decodes', goalCount: 97 },
      resetStep: 'repair_field',
    }))
    showGoalCreate.value = true

    render(html`<div><${GoalTree} /><${GoalCreateForm} /></div>`)

    const alert = await waitFor(() => screen.getByTestId('goal-store-unavailable'))
    expect(alert.getAttribute('role')).toBe('alert')
    expect(alert.getAttribute('data-reason')).toBe('schema_rejected')
    expect(alert.getAttribute('data-reset-step')).toBe('repair_field')
    expect(alert.textContent).toContain('Goal store 를 읽을 수 없습니다')
    expect(screen.getByTestId('goal-store-unavailable-file').textContent).toBe('/srv/masc/.masc/goals.json')
    expect(screen.getByTestId('goal-store-unavailable-reason').textContent)
      .toBe('이 빌드의 goal 스키마가 파일을 거절했습니다 (위치: criterion_revision)')
    expect(screen.getByTestId('goal-store-unavailable-mirror').textContent)
      .toBe('.last-good 미러는 읽힘 · goal 97개 (서빙하지 않음)')
    expect(screen.getByTestId('goal-store-unavailable-reset-step').textContent)
      .toBe('파일의 criterion_revision 위치를 확인하고 수정한 뒤 다시 조회하세요')
    // The generic ErrorState line is not drawn beside the structured block.
    expect(container_alerts()).toEqual(['goal-store-unavailable', 'goal-create-source-unavailable'])

    fireEvent.input(screen.getByTestId('goal-create-title-input'), { target: { value: 'Recover the store' } })
    fireEvent.input(screen.getByTestId('goal-create-metric'), { target: { value: 'readable goals' } })
    fireEvent.input(screen.getByTestId('goal-create-target'), { target: { value: '97' } })
    const submit = screen.getByTestId('goal-create-submit') as HTMLButtonElement
    expect(submit.disabled).toBe(true)
    fireEvent.click(submit)
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    expect(screen.getByTestId('goal-create-source-unavailable').getAttribute('role')).toBe('alert')
    expect(screen.getByTestId('goal-create-source-unavailable').textContent).toContain('/srv/masc/.masc/goals.json')
    expect(screen.getByTestId('goal-create-source-unavailable').textContent).toContain('criterion_revision')
  })

  it('marks the store unconfirmed while a superseded retry is replaced', async () => {
    let resolveSuperseded!: (value: DashboardGoalsTreeResponse) => void
    let resolveCurrent!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockRejectedValueOnce(new GoalSourceUnavailableError({
      kind: 'unavailable',
      reason: 'not_json',
      field: null,
      file: '/srv/masc/.masc/goals.json',
      mirror: { status: 'mirror_absent', goalCount: null },
      resetStep: 'reset_goal_store',
    })).mockImplementationOnce(() => new Promise(resolve => { resolveSuperseded = resolve }))
      .mockImplementationOnce(() => new Promise(resolve => { resolveCurrent = resolve }))
    showGoalCreate.value = true
    render(html`<div><${GoalTree} /><${OwnedGoalCreate} /></div>`)
    await waitFor(() => screen.getByTestId('goal-store-unavailable'))
    fireEvent.input(screen.getByTestId('goal-create-title-input'), { target: { value: 'Recover the store' } })
    fireEvent.input(screen.getByTestId('goal-create-metric'), { target: { value: 'readable goals' } })
    fireEvent.input(screen.getByTestId('goal-create-target'), { target: { value: '1' } })
    hydrateGoalTreeSnapshot({
      approval_queue_state: { state: 'ready' },
      tree: [],
      summary: emptySummary(),
    })
    await waitFor(() => expect(screen.getByTestId('goal-tree-unconfirmed')).toBeTruthy())
    expect(screen.queryByTestId('goal-store-unavailable')).toBeNull()
    expect((screen.getByTestId('goal-create-submit') as HTMLButtonElement).disabled).toBe(false)
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    expect(screen.queryByTestId('goal-store-unavailable')).toBeNull()
    expect(screen.getByTestId('goal-create-source-unconfirmed')).toBeTruthy()
    expect((screen.getByTestId('goal-create-submit') as HTMLButtonElement).disabled).toBe(false)
    hydrateGoalTreeSnapshot({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(3))
    resolveSuperseded({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await Promise.resolve()
    expect((screen.getByTestId('goal-create-submit') as HTMLButtonElement).disabled).toBe(false)
    resolveCurrent({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await waitFor(() => expect(screen.queryByTestId('goal-create-source-unconfirmed')).toBeNull())
    expect(screen.queryByTestId('goal-create-source-unavailable')).toBeNull()
    expect((screen.getByTestId('goal-create-submit') as HTMLButtonElement).disabled).toBe(false)
  })

  it('rechecks a changed masc root on remount, including after an unbound observation', async () => {
    let mascRoot = '/real-a/.masc'
    let resolveOld!: (value: DashboardGoalsTreeResponse) => void
    let resolveCurrent!: (value: DashboardGoalsTreeResponse) => void
    mocks.captureArtifactWorkspace.mockImplementation(async (basePath: string) => ({ basePath, mascRoot }))
    mocks.fetchDashboardGoalsTree.mockRejectedValueOnce(new GoalSourceUnavailableError({
      kind: 'unavailable', reason: 'not_json', field: null, file: '/old-private/goals.json',
      mirror: { status: 'mirror_absent', goalCount: null }, resetStep: 'reset_goal_store',
    })).mockImplementationOnce(() => new Promise(resolve => { resolveOld = resolve }))
      .mockImplementationOnce(() => new Promise(resolve => { resolveCurrent = resolve }))
    showGoalCreate.value = true
    const first = render(html`<div><${GoalTree} /><${OwnedGoalCreate} /></div>`)
    await screen.findByTestId('goal-store-unavailable')
    first.unmount()
    mascRoot = '/real-b/.masc'
    render(html`<div><${GoalTree} /><${OwnedGoalCreate} /></div>`)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    expect(mocks.fetchDashboardGoalsTree.mock.calls[1]![0]).toEqual({ basePath: '/workspace-a', mascRoot: '/real-b/.masc' })
    expect(document.body.textContent).not.toContain('/old-private/goals.json')
    expect(screen.getByTestId('goal-create-source-unconfirmed')).toBeTruthy()
    hydrateGoalTreeSnapshot({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(3))
    resolveOld({ approval_queue_state: { state: 'ready' }, tree: [makeGoal('old', 'Old root')], summary: emptySummary() })
    await Promise.resolve()
    expect(screen.queryByText('Old root')).toBeNull()
    resolveCurrent({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await waitFor(() => expect(screen.queryByTestId('goal-create-source-unconfirmed')).toBeNull())
    expect(screen.queryByTestId('goal-store-unavailable')).toBeNull()
  })

  it('hides the earlier store failure if a retry fails for another reason', async () => {
    mocks.fetchDashboardGoalsTree.mockRejectedValueOnce(new GoalSourceUnavailableError({
      kind: 'unavailable', reason: 'not_json', field: null, file: '/workspace-a/.masc/goals.json',
      mirror: { status: 'mirror_absent', goalCount: null }, resetStep: 'reset_goal_store',
    })).mockRejectedValueOnce(new ApiRequestError({
      method: 'GET', path: '/api/v1/dashboard/goals', status: 401, detail: 'private refusal',
    }))
    showGoalCreate.value = true
    render(html`<div><${GoalTree} /><${OwnedGoalCreate} /></div>`)
    await waitFor(() => screen.getByTestId('goal-store-unavailable'))
    fireEvent.input(screen.getByTestId('goal-create-title-input'), { target: { value: 'Recover the store' } })
    fireEvent.input(screen.getByTestId('goal-create-metric'), { target: { value: 'readable goals' } })
    fireEvent.input(screen.getByTestId('goal-create-target'), { target: { value: '1' } })
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(screen.getByText(/인증 또는 권한이 거부되었습니다/)).toBeTruthy())
    expect(screen.queryByTestId('goal-store-unavailable')).toBeNull()
    expect(screen.queryByTestId('goal-create-source-unavailable')).toBeNull()
    expect(screen.getByTestId('goal-create-source-unconfirmed')).toBeTruthy()
    expect(document.body.textContent).not.toContain('/workspace-a/.masc/goals.json')
    expect((screen.getByTestId('goal-create-submit') as HTMLButtonElement).disabled).toBe(false)
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2)
    hydrateGoalTreeSnapshot({ approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary() })
    await waitFor(() => expect(screen.getByTestId('goal-tree-unconfirmed')).toBeTruthy())
    expect(screen.queryByText(/인증 또는 권한이 거부되었습니다/)).toBeNull()
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2)
  })
})

function container_alerts(): string[] {
  return Array.from(document.querySelectorAll('[role="alert"]'))
    .map(node => node.getAttribute('data-testid') ?? '<no testid>')
}
