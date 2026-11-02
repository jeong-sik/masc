import { html } from 'htm/preact'
import { computed, signal } from '@preact/signals'
import { cleanup, fireEvent, render, screen, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

const routeSignal = signal<{
  tab: string
  params: Record<string, string>
  postId: null
}>({
  tab: 'workspace',
  params: { section: 'board' },
  postId: null,
})

const navigateMock = vi.hoisted(() => vi.fn())
const callMcpToolMock = vi.hoisted(() => vi.fn<(name: string, args: Record<string, unknown>) => Promise<string>>())
const assignmentSourceMock = vi.hoisted(() => vi.fn())
const refreshGoalTreeMock = vi.hoisted(() => vi.fn())

vi.mock('../api/mcp', () => ({
  callMcpTool: callMcpToolMock,
  callMcpToolAtIdentity: (name: string, args: Record<string, unknown>) => callMcpToolMock(name, args),
  mcpCallFailureDisposition: () => 'outcome_unknown',
  mcpStructuredContentFromError: () => null,
}))
vi.mock('../api/published-artifacts', async original => ({
  ...await original<typeof import('../api/published-artifacts')>(),
  captureArtifactWorkspace: async () => ({ basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }),
}))

// Only the two entry points this file drives are replaced. The rest of the
// module stays real because the surface renders RouteLink, which calls
// hashForRoute: a mock listing just route and navigate left that undefined,
// and every case here failed on the call once Work mounted its section nav.
vi.mock('../router', async (importOriginal) => ({
  ...await importOriginal<typeof import('../router')>(),
  get route() { return routeSignal },
  navigate: navigateMock,
}))

vi.mock('../store', () => ({
  goals: signal([]),
  goalIdentityObservation: signal(null),
  tasks: signal([]),
  keepers: signal([]),
  executionTaskTotal: signal<number | null>(null),
  executionWorkspaceAuthority: signal({ epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 1 }),
  refreshGoals: vi.fn().mockResolvedValue(undefined),
}))

vi.mock('./board/board-surface', () => ({
  BoardSurface: () => html`<div data-testid="board-surface">Board</div>`,
}))

vi.mock('./board/sub-board-surface', () => ({
  SubBoardSurface: () => html`<div data-testid="sub-board-surface">Sub-Boards</div>`,
}))

vi.mock('./planning-panel', () => ({
  PlanningPanel: () => html`<div data-testid="planning-panel">Planning</div>`,
}))

vi.mock('./goals/goal-tree', () => ({
  useGoalTreeDecisionObservation: () => ({ data: fixtureBoundTree.value,
    authority: fixtureAuthorityAvailable.value ? {} : null, authorityError: fixtureAuthorityError.value,
    decisionBinding: { workspace: { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' },
      authRevision: 1, actor: 'dashboard' },
    error: goalTreeError.value, unavailable: fixtureOwnedUnavailable.value,
    unconfirmed: fixtureTreeUnconfirmed.value,
    loading: fixtureTreeLoading.value, refresh: refreshGoalTreeMock,
    isStoreUnavailableNow: () => fixtureOwnedUnavailable.value !== null && !fixtureTreeLoading.value,
    isCurrent: () => fixtureTreeAvailable.value, isOwnerCurrent: () => fixtureAuthorityAvailable.value,
    isRecoveryCurrent: () => fixtureTreeAvailable.value,
    refreshAfterWrite: () => true }),
}))

vi.mock('./goals/goal-assign-picker', async original => {
  const actual = await original<typeof import('./goals/goal-assign-picker')>()
  return { ...actual, GoalAssignPicker: (props: Parameters<typeof actual.GoalAssignPicker>[0]) => {
    assignmentSourceMock(props.source)
    return actual.GoalAssignPicker(props)
  } }
})

vi.mock('./verification-requests-panel', () => ({
  VerificationRequestsPanel: () => html`<div data-testid="verification-panel">Verification</div>`,
}))

vi.mock('./verification-runs-panel', () => ({
  VerificationRunsPanel: () => html`<div data-testid="verification-runs-panel">Verification runs</div>`,
}))

vi.mock('./goal-verification-runs-panel', () => ({
  GoalVerificationRunsPanel: () => html`<div data-testid="goal-verification-runs-panel">Goal verification runs</div>`,
}))

vi.mock('./repository-management', () => ({
  RepositoryManagement: () => html`<div data-testid="repository-panel">Repositories</div>`,
}))

import { executionTaskTotal, goals, goalIdentityObservation, keepers, tasks } from '../store'
import { normalizeTask } from '../store-normalizers'
import { goalStoreUnavailable, goalTreeData, goalTreeError } from '../goal-tree-state'
import { selectedTask } from './goals/task-detail-selection'
import { showGoalCreate } from './goals/goal-create-state'
import { Work } from './work'
import { setCanonicalDashboardActor } from '../lib/dashboard-session-actor'
import type { GoalTreeNode, GoalTreeTask, GoalTreeSummary } from '../types'
import type { GoalStoreUnavailable } from '../types/goal-store-unavailable'

const GOAL_FIXTURE_OK_COLOR = '#4ade80'

function emptyGoalTreeSummary(overrides: Partial<GoalTreeSummary> = {}): GoalTreeSummary {
  return {
    total_goals: 0,
    active_goals: 0,
    phase_counts: {},
    total_tasks: 0,
    done_tasks: 0,
    pending_approvals: 0,
    ...overrides,
  }
}

function goalTreeTask(overrides: Partial<GoalTreeTask> = {}): GoalTreeTask {
  return {
    id: 'task-tree',
    title: 'Tree task',
    status: 'done',
    status_color: GOAL_FIXTURE_OK_COLOR,
    priority: 2,
    assignee: null,
    goal_id: 'G-1',
    is_terminal: true,
    created_at: '2026-01-01',
    updated_at: '2026-01-02',
    ...overrides,
  }
}

function goalTreeNode(overrides: Partial<GoalTreeNode> = {}): GoalTreeNode {
  const phase = overrides.phase ?? 'executing'
  return {
    id: 'G-1',
    title: 'Goal One',
    phase,
    phase_color: GOAL_FIXTURE_OK_COLOR,
    goal_fsm: {
      state: phase,
      source: 'goal.phase',
      next_actions: [],
      activity_observation: 'goal_metadata',
    },
    priority: 1,
    metric: null,
    target_value: null,
    due_date: null,
    criterion_revision: 'revision-default',
    measurement: { state: 'not_recorded' },
    tasks: [],
    task_count: 0,
    task_done_count: 0,
    timeline_events: [],
    children: [],
    child_count: 0,
    last_activity_at: '2026-01-02',
    stagnation_seconds: 0,
    activity_observation: 'goal_metadata',
    linked_keeper_names: [],
    pending_approval_count: 0,
    created_at: '2026-01-01',
    updated_at: '2026-01-02',
    ...overrides,
  }
}

function expandGoalCard(card: HTMLElement): void {
  const button = card.querySelector<HTMLButtonElement>('.wk-goal-h')!
  if (button.getAttribute('aria-expanded') !== 'true') fireEvent.click(button)
}

// Legacy surface fixtures specify Goal rows directly. Treat those rows as a
// synthetic bound tree only when a test has not supplied an explicit tree.
const fixtureTreeAvailable = signal(true)
const fixtureTreeLoading = signal(false)
const fixtureTreeUnconfirmed = signal(false)
const fixtureAuthorityAvailable = signal(true)
const fixtureAuthorityError = signal<string | null>(null)
const fixtureOwnedUnavailable = signal<GoalStoreUnavailable | null>(null)
const fixtureBoundTree = computed(() => {
  if (!fixtureTreeAvailable.value || goalTreeError.value) return null
  const explicit = goalTreeData.value
  const tree = explicit?.tree ?? goals.value.map(goal => goalTreeNode({
    ...goal, phase: goal.phase as GoalTreeNode['phase'],
  }))
  const allIds = (nodes: readonly GoalTreeNode[]): string[] => nodes.flatMap(node => [node.id, ...allIds(node.children)])
  const ids = allIds(tree)
  return {
    tree,
    summary: explicit?.summary ?? emptyGoalTreeSummary({ total_goals: ids.length,
      active_goals: tree.filter(goal => goal.phase === 'executing').length }),
    identity_observation: explicit?.identity_observation ?? { ids, complete: true },
  }
})

describe('Work', () => {
  afterEach(() => {
    cleanup()
    navigateMock.mockClear()
    selectedTask.value = null
    showGoalCreate.value = false
    goalTreeData.value = null
    goalTreeError.value = null
    goalIdentityObservation.value = null
    fixtureTreeAvailable.value = true
    fixtureTreeLoading.value = false
    fixtureTreeUnconfirmed.value = false
    fixtureAuthorityAvailable.value = true
    fixtureAuthorityError.value = null
    fixtureOwnedUnavailable.value = null
    goalStoreUnavailable.value = null
    refreshGoalTreeMock.mockClear()
    assignmentSourceMock.mockClear()
    setCanonicalDashboardActor(null)
  })

  beforeEach(() => {
    goals.value = []
    goalIdentityObservation.value = null
    tasks.value = []
    keepers.value = []
    // Reset the reported backlog total too: it is a signal, so a value left by
    // one test would silently drive every KPI assertion after it.
    executionTaskTotal.value = null
    goalTreeData.value = null
    goalTreeError.value = null
    fixtureTreeAvailable.value = true
    fixtureTreeLoading.value = false
    fixtureTreeUnconfirmed.value = false
    fixtureAuthorityAvailable.value = true
    fixtureAuthorityError.value = null
    fixtureOwnedUnavailable.value = null
    goalStoreUnavailable.value = null
    showGoalCreate.value = false
  })

  it('renders the SubBoard surface for the workspace sub-boards section', () => {
    routeSignal.value = {
      tab: 'workspace',
      params: { section: 'sub-boards' },
      postId: null,
    }

    render(html`<${Work} />`)

    expect(screen.getByTestId('sub-board-surface')).toBeTruthy()
    expect(screen.queryByTestId('work-kpis')).toBeNull()
  })

  it('renders the board feed surface for the workspace board section', () => {
    routeSignal.value = {
      tab: 'workspace',
      params: { section: 'board' },
      postId: null,
    }

    render(html`<${Work} />`)

    expect(screen.getByTestId('board-surface')).toBeTruthy()
    expect(screen.queryByTestId('work-kpis')).toBeNull()
  })

  it('renders the verification panel for the workspace verification section', () => {
    routeSignal.value = {
      tab: 'workspace',
      params: { section: 'verification' },
      postId: null,
    }

    render(html`<${Work} />`)

    expect(screen.getByTestId('verification-panel')).toBeTruthy()
    expect(screen.getByTestId('verification-runs-panel')).toBeTruthy()
    expect(screen.getByTestId('goal-verification-runs-panel')).toBeTruthy()
    expect(screen.queryByTestId('work-kpis')).toBeNull()
  })

  it('falls back to the v2 work surface for unknown workspace sections', () => {
    routeSignal.value = {
      tab: 'workspace',
      params: { section: 'unknown' },
      postId: null,
    }

    render(html`<${Work} />`)

    expect(screen.getByTestId('work-kpis')).toBeTruthy()
  })

  describe('v2 work surface', () => {
    beforeEach(() => {
      routeSignal.value = {
        tab: 'workspace',
        params: { section: 'work' },
        postId: null,
      }
    })

    it('keeps a decoded Task under its exact Goal ID', () => {
      goals.value = [
        { id: 'goal-a', title: 'Canonical Goal', priority: 1, phase: 'executing', created_at: 'now', updated_at: 'now' },
        { id: '\u00a0goal-a\u00a0', title: 'Unicode Goal', priority: 1, phase: 'executing', created_at: 'now', updated_at: 'now' },
      ]
      tasks.value = [normalizeTask({ id: 'task-a', title: 'Unicode Goal Task', goal_id: '\u00a0goal-a\u00a0', status: 'todo' })!]
      render(html`<${Work} />`)
      const cards = screen.getAllByTestId('goal-card')
      const canonical = cards.find(card => card.textContent?.includes('Canonical Goal'))!
      const unicode = cards.find(card => card.textContent?.includes('Unicode Goal'))!
      expect(unicode.textContent).toContain('Unicode Goal Task')
      expect(canonical.textContent).not.toContain('Unicode Goal Task')
    })

    it.each(['goals.json: criterion_revision is missing', 'goal_task_links: primary registry is missing'])('shows source failure instead of zero goals: %s', detail => {
      goals.value = []
      goalTreeData.value = null
      goalTreeError.value = detail
      render(html`<${Work} />`)
      expect(screen.getByTestId('work-goal-source-error').textContent).toContain(detail)
      expect(screen.getByTestId('kpi-goals').textContent).toBe('—')
      expect(screen.queryByTestId('wka-flagged-calm')).toBeNull()
      expect(screen.queryByText('주의 목표 없음 · 정상 순환')).toBeNull()
      goalTreeError.value = null
    })

    it.each([
      ['idle', { state: 'current', completion: { state: 'idle' } }, '검증 · 원장에 현재 요청 없음'],
      ['stale', { state: 'stale', historical: { state: 'proven',
        criterion: { revision: 'old', title: 'Old goal', metric: null, target_value: null },
        requestId: 'old-request', runId: 'old-run', evidence: 'old evidence',
        recordedAt: '2026-09-08', actor: 'verifier_exact' } }, '검증 · 이전 기준의 기록'],
      ['unreadable', { state: 'unreadable', detail: 'primary ledger failed' }, '검증 · 확인 불가'],
    ] as const)('shows %s proof independently of a completed Goal phase', (_state, verification, label) => {
      goals.value = [{ id: 'proof-goal', title: 'Measured goal', priority: 1,
        phase: 'completed', created_at: '2026-09-08', updated_at: '2026-09-09', verification }]
      goalIdentityObservation.value = { goals: goals.value, observation: { ids: ['proof-goal'], complete: true } }
      render(html`<${Work} />`)
      const card = screen.getByTestId('goal-card')
      expect(within(card).getByText(label)).toBeTruthy()
      expect(card.querySelector('.wk-goal-phase')?.textContent).toBe('completed')
      expect(card.querySelector('[data-goal-proof]')?.getAttribute('data-goal-proof')).toBe(_state)
    })

    it('uses the bound tree Goal and proof instead of an older planning Goal with the same ID', () => {
      goals.value = [{ id: 'G-1', title: 'Old workspace Goal', priority: 1, phase: 'executing',
        created_at: '2026-01-01', updated_at: '2026-01-02',
        verification: { state: 'current', completion: { state: 'proven',
          criterion: { revision: 'old', title: 'Old workspace Goal', metric: null, target_value: null },
          requestId: 'r', runId: 'run', evidence: 'old evidence', recordedAt: 'now', actor: 'verifier' } } }]
      goalIdentityObservation.value = { goals: goals.value, observation: { ids: ['G-1'], complete: true } }
      goalTreeData.value = {
        tree: [goalTreeNode({ id: 'G-1', title: 'Current workspace Goal',
          verification: { state: 'current', completion: { state: 'idle' } } })],
        summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1 }),
      }
      render(html`<${Work} />`)
      const card = screen.getByTestId('goal-card')
      expect(card.querySelector('[data-goal-proof]')?.getAttribute('data-goal-proof')).toBe('idle')
      expect(card.textContent).toContain('Current workspace Goal')
      expect(card.textContent).not.toContain('Old workspace Goal')
    })

    it('offers Goal assignment from the same bound tree as the displayed card', () => {
      goals.value = [{ id: 'G-1', title: 'Old workspace Goal', priority: 1, phase: 'executing',
        created_at: 'now', updated_at: 'now' }]
      goalIdentityObservation.value = { goals: goals.value, observation: { ids: ['G-1'], complete: true } }
      goalTreeData.value = { tree: [goalTreeNode({ id: 'G-1', title: 'Current workspace Goal' })],
        summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1 }) }
      tasks.value = [{ id: 'task-a', title: 'Unassigned Task', status: 'todo' }]
      render(html`<${Work} />`)
      const select = screen.getByTestId('assign-goal') as HTMLSelectElement
      expect([...select.options].map(option => option.textContent)).toEqual(['goal에 배정', 'Current workspace Goal'])
    })

    it('passes the actual tokenless operator to a Goal assignment', () => {
      setCanonicalDashboardActor('alice')
      goalTreeData.value = { tree: [goalTreeNode({ id: 'G-1', title: 'Current workspace Goal' })],
        summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1 }) }
      tasks.value = [{ id: 'task-a', title: 'Unassigned Task', status: 'todo' }]
      render(html`<${Work} />`)
      const source = assignmentSourceMock.mock.lastCall?.[0]
      expect(source?.identity).toEqual({ revision: 1, actor: 'alice' })
      expect(source?.isCurrent()).toBe(true)
      expect(source?.isRecoveryCurrent()).toBe(true)
      const select = screen.getByTestId('assign-goal') as HTMLSelectElement
      select.value = 'G-1'
      // The Preact compat test helper maps fireEvent.change to input, while
      // a select's real change handler listens to the native change event.
      fireEvent(select, new Event('change', { bubbles: true }))
      expect(select.value).toBe('')
      expect(callMcpToolMock).toHaveBeenCalledWith('masc_task_set_goal', expect.objectContaining({ goal_id: 'G-1' }))
    })

    it('withholds partial Goal warning counts while keeping an independently identified option', () => {
      localStorage.removeItem('v2.wkAsideCollapsed')
      const good = goalTreeNode({ id: 'G-good', title: 'Identified Goal', phase: 'blocked' })
      const duplicate = goalTreeNode({ id: 'G-duplicate', title: 'Duplicate Goal' })
      goalTreeData.value = { tree: [good, duplicate, duplicate],
        summary: emptyGoalTreeSummary({ total_goals: 3 }),
        identity_observation: { ids: ['G-good', 'G-duplicate', 'G-duplicate'], complete: true } }
      tasks.value = [{ id: 'task-a', title: 'Unassigned Task', status: 'todo' }]
      render(html`<${Work} />`)
      expect(screen.getByTestId('work-goal-source-error')).toBeTruthy()
      expect(screen.getByTestId('work-aside').querySelector('#wka-h-flagged .wka-h-n')).toBeNull()
      const select = screen.getByTestId('assign-goal') as HTMLSelectElement
      expect([...select.options].map(option => option.value)).toEqual(['', 'G-good'])
      fireEvent.click(screen.getByRole('button', { name: '운영 상태 패널 접기' }))
      const railCount = screen.getByTestId('work-aside-collapsed').querySelector('.wka-rail-stat:last-child')!
      expect(railCount.querySelector('b')?.textContent).toBe('—')
      expect(railCount.classList.contains('bad')).toBe(false)
      localStorage.removeItem('v2.wkAsideCollapsed')
    })

    it.each([
      { tree: [goalTreeNode({ id: 'G-duplicate' }), goalTreeNode({ id: 'G-duplicate' })],
        ids: ['G-duplicate', 'G-duplicate'] },
      { tree: [], ids: ['G-hidden'] },
    ])('explains unavailable assignment when Goal rows are ambiguous or discarded', ({ tree, ids }) => {
      goalTreeData.value = { tree, summary: emptyGoalTreeSummary({ total_goals: ids.length }),
        identity_observation: { ids, complete: true } }
      tasks.value = [{ id: 'task-a', title: 'Unassigned Task', status: 'todo' }]
      render(html`<${Work} />`)
      expect(screen.queryByTestId('assign-goal')).toBeNull()
      expect(screen.getByText(/Goal ID 또는 목록을 확인할 수 없어 배정할 수 없습니다/)).toBeTruthy()
    })

    it('does not show an assignment warning for a complete list of closed Goals', () => {
      goalTreeData.value = { tree: [goalTreeNode({ id: 'G-closed', phase: 'completed' })],
        summary: emptyGoalTreeSummary({ total_goals: 1 }),
        identity_observation: { ids: ['G-closed'], complete: true } }
      tasks.value = [{ id: 'task-a', title: 'Unassigned Task', status: 'todo' }]
      render(html`<${Work} />`)
      expect(screen.queryByTestId('assign-goal')).toBeNull()
      expect(screen.queryByText(/Goal ID 또는 목록을 확인할 수 없어 배정할 수 없습니다/)).toBeNull()
    })

    it.each([
      { ids: ['G-1', 'G-1'], complete: true },
      { ids: ['G-1'], complete: false },
    ])('does not display a Goal when the bound tree identity observation is ambiguous or incomplete', observation => {
      goals.value = [{ id: 'G-1', title: 'Current Goal', priority: 1, phase: 'executing',
        created_at: 'now', updated_at: 'now', verification: { state: 'current', completion: { state: 'idle' } } }]
      goalIdentityObservation.value = { goals: goals.value, observation }
      goalTreeData.value = { tree: [goalTreeNode({ id: 'G-1' })],
        summary: emptyGoalTreeSummary({ total_goals: 1 }),
        identity_observation: observation }
      render(html`<${Work} />`)
      expect(screen.queryByTestId('goal-card')).toBeNull()
      expect(screen.getByTestId('work-goal-source-error').textContent).toContain('ID를 구분할 수 없습니다')
    })

    it('does not use a retained planning Goal while the workspace-bound tree is unavailable', () => {
      goals.value = [{ id: 'G-1', title: 'Old workspace Goal', priority: 1, phase: 'executing',
        created_at: 'now', updated_at: 'now', verification: { state: 'current', completion: { state: 'idle' } } }]
      fixtureTreeAvailable.value = false
      render(html`<${Work} />`)
      expect(screen.queryByTestId('goal-card')).toBeNull()
      expect(screen.getByTestId('kpi-goals').textContent).toBe('—')
      expect(screen.getByTestId('work-goal-source-error').textContent).toContain('현재 workspace')
    })

    it('shows a pending Goal observation without an error or a false zero', () => {
      fixtureTreeAvailable.value = false
      fixtureTreeLoading.value = true
      render(html`<${Work} />`)
      expect(screen.getByTestId('work-goal-source-loading').textContent).toContain('확인하고 있습니다')
      expect(screen.queryByTestId('work-goal-source-error')).toBeNull()
      expect(screen.getByTestId('kpi-goals').textContent).toBe('—')
      expect(screen.queryByTestId('wka-flagged-calm')).toBeNull()
    })

    it('offers a retry when the workspace has not been confirmed', () => {
      fixtureTreeAvailable.value = false
      fixtureAuthorityAvailable.value = false
      render(html`<${Work} />`)
      const status = screen.getByTestId('work-goal-source-unconfirmed')
      expect(screen.queryByTestId('work-goal-source-error')).toBeNull()
      expect(screen.getByTestId('kpi-goals').textContent).toBe('—')
      expect(screen.queryByTestId('wka-flagged-calm')).toBeNull()
      fireEvent.click(within(status).getByRole('button', { name: '다시 확인' }))
      expect(refreshGoalTreeMock).toHaveBeenCalledTimes(1)
    })

    it('offers a retry without claiming to be loading after an unbound observation', () => {
      fixtureTreeAvailable.value = false
      fixtureTreeUnconfirmed.value = true
      render(html`<${Work} />`)
      const status = screen.getByTestId('work-goal-source-unconfirmed')
      expect(status.textContent).toContain('Goal 상태를 다시 확인')
      expect(screen.queryByTestId('work-goal-source-loading')).toBeNull()
      fireEvent.click(within(status).getByRole('button', { name: '다시 확인' }))
      expect(refreshGoalTreeMock).toHaveBeenCalledTimes(1)
    })

    it('reports workspace connection failure without exposing its raw detail', () => {
      fixtureTreeAvailable.value = false
      fixtureAuthorityAvailable.value = false
      fixtureAuthorityError.value = 'private error detail'
      render(html`<${Work} />`)
      expect(screen.getByTestId('work-goal-source-error').textContent).toContain('workspace 연결')
      expect(screen.getByTestId('work-goal-source-error').textContent).not.toContain('private error detail')
    })

    it('does not show a previous workspace store error in the Goal creation form', () => {
      goalStoreUnavailable.value = { kind: 'unavailable', reason: 'not_json', field: null,
        file: '/old-workspace/.masc/goals.json', mirror: { status: 'mirror_absent', goalCount: null },
        resetStep: 'reset_goal_store' }
      fixtureOwnedUnavailable.value = null
      showGoalCreate.value = true
      render(html`<${Work} />`)
      expect(screen.queryByTestId('goal-create-source-unavailable')).toBeNull()
      expect(screen.getByTestId('goal-create-panel').textContent).not.toContain('/old-workspace/')
    })

    it.each(['approval queue unavailable', 'Goal-task links unavailable'])(
      'allows Goal creation when the tree is unavailable because %s', failure => {
        fixtureTreeAvailable.value = false
        goalTreeError.value = failure
        showGoalCreate.value = true
        render(html`<${Work} />`)
        fireEvent.input(screen.getByTestId('goal-create-title-input'), { target: { value: 'A new goal' } })
        fireEvent.input(screen.getByTestId('goal-create-metric'), { target: { value: 'metric' } })
        fireEvent.input(screen.getByTestId('goal-create-target'), { target: { value: 'target' } })
        expect(screen.getByTestId('goal-create-source-unconfirmed')).toBeTruthy()
        expect(screen.getByTestId('goal-create-submit')).not.toBeDisabled()
      },
    )

    it('does not present a complete Goal count if the tree decoder omitted an observed row', () => {
      goalTreeData.value = { tree: [goalTreeNode({ id: 'G-1' })],
        summary: emptyGoalTreeSummary({ total_goals: 2, active_goals: 2 }),
        identity_observation: { ids: ['G-1', 'G-hidden'], complete: true } }
      render(html`<${Work} />`)
      expect(screen.getByTestId('kpi-goals').textContent).toBe('—')
      expect(screen.getByTestId('work-goal-source-error').textContent).toContain('ID를 구분할 수 없습니다')
    })

    it('uses the tree identity observation for a tree-only Goal', () => {
      goalTreeData.value = { tree: [goalTreeNode({ id: 'G-1',
        verification: { state: 'current', completion: { state: 'idle' } } })],
        summary: emptyGoalTreeSummary({ total_goals: 1 }),
        identity_observation: { ids: ['G-1'], complete: true } }
      render(html`<${Work} />`)
      expect(screen.getByTestId('goal-card').querySelector('[data-goal-proof]')?.getAttribute('data-goal-proof'))
        .toBe('idle')
    })

    it('renders the reference 5 KPI counts from goals and tasks', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-2', title: 'Goal Two', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Job one', goal_id: 'G-1', status: 'done' },
        { id: 'J-2', title: 'Job two', goal_id: 'G-1', status: 'in_progress' },
        { id: 'J-3', title: 'Job three', goal_id: 'G-2', status: 'awaiting_verification' },
        { id: 'J-4', title: 'Job four', goal_id: 'G-2', status: 'todo' },
        { id: 'J-5', title: 'Orphan job', status: 'todo' },
      ]

      render(html`<${Work} />`)

      expect(screen.getByTestId('kpi-goals').textContent).toBe('2')
      expect(screen.getByTestId('kpi-tasks').textContent).toBe('5')
      expect(screen.getByTestId('kpi-wip').textContent).toBe('1')
      expect(screen.getByTestId('kpi-verify').textContent).toBe('1')
      expect(screen.getByTestId('kpi-backlog').textContent).toBe('2')
      // Five KPI summary cells
      expect(screen.getByTestId('work-kpis').children.length).toBe(5)
      expect(screen.getByText(/미배정 task는 백로그에서 claim/).textContent).toContain('claim')
      expect(screen.getByTestId('work-goal-list')).toBeTruthy()
    })

    it('avoids repeating Task scope labels across the KPI row and kanban columns', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'T-todo', title: 'Todo item', goal_id: 'G-1', status: 'todo' },
        { id: 'T-claim', title: 'Claimed item', goal_id: 'G-1', status: 'claimed', assignee: 'keeper-x' },
      ]

      render(html`<${Work} />`)

      const kpis = screen.getByTestId('work-kpis')
      expect(kpis.textContent).toContain('활성 목표')
      expect(kpis.textContent).toContain('전체 작업')
      expect(kpis.textContent).toContain('백로그')
      expect(kpis.textContent).not.toContain('목표 TASK')
      expect(kpis.textContent).not.toContain('Task')
      expect(kpis.textContent).not.toContain('TASK')

      fireEvent.click(screen.getByTestId('work-view-kanban'))

      const section = screen.getByTestId('work-board-section')
      expect(section.textContent).toContain('칸반 · 상태별')
      expect(section.textContent).toContain('todo → claimed → in_progress → verify → blocked/paused/unknown → done')

      const todoCol = screen.getByTestId('kanban-col-todo')
      const claimedCol = screen.getByTestId('kanban-col-claimed')
      expect(todoCol.querySelector('.wk-kcol-dot.todo')).toBeTruthy()
      expect(todoCol.querySelector('.wk-kcol-title')?.textContent).toBe('예정')
      expect(todoCol.querySelector('.wk-kcol-n')?.textContent).toBe('1')
      expect(todoCol.textContent).not.toContain('TASK')
      expect(claimedCol.querySelector('.wk-kcol-dot.claimed')).toBeTruthy()
      expect(claimedCol.querySelector('.wk-kcol-title')?.textContent).toBe('점유됨')
      expect(claimedCol.querySelector('.wk-kcol-n')?.textContent).toBe('1')
      expect(claimedCol.textContent).not.toContain('TASK')

      fireEvent.click(screen.getByTestId('work-view-list'))
      expect(screen.getByTestId('work-view-list').classList.contains('on')).toBe(true)
    })

    it('renders the new-goal button as enabled and opens the form on click', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]

      render(html`<${Work} />`)

      const button = screen.getByTestId('work-new-goal')
      expect(button.textContent).toContain('새 목표')
      expect(button).not.toBeDisabled()

      // Form is hidden initially
      expect(screen.queryByTestId('goal-create-panel')).toBeNull()

      fireEvent.click(button)

      // Side panel appears after click and WorkAside is hidden
      expect(screen.getByTestId('goal-create-panel')).toBeTruthy()
      expect(screen.queryByTestId('work-aside')).toBeNull()
    })

    it('renders a collapsed goal card per goal and expands on click', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Job one', goal_id: 'G-1', status: 'in_progress' },
      ]

      render(html`<${Work} />`)

      const card = screen.getByTestId('goal-card')
      expect(card).toBeTruthy()
      expect(screen.queryByTestId('job-row')).toBeNull()

      fireEvent.click(card.querySelector('.wk-goal-h')!)

      expect(screen.getByTestId('job-row')).toBeTruthy()
      expect(screen.getByText('Job one')).toBeTruthy()
    })

    it('renders goals as a flat priority-sorted list', () => {
      goals.value = [
        { id: 'G-X', title: 'Goal visible in flat list', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      render(html`<${Work} />`)

      expect(screen.getByTestId('work-goal-list')).toBeTruthy()
      expect(screen.getByText('Goal visible in flat list')).toBeTruthy()
    })

    it('renders job rows with state, id, title, and blocker note', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Blocked job', goal_id: 'G-1', status: 'cancelled', handoff_context: { summary: '', reason: 'dependency missing' } },
      ]

      const { container } = render(html`<${Work} />`)

      const card = container.querySelector('[data-goal-id="G-1"]')
      expect(card).toBeTruthy()
      fireEvent.click(card!.querySelector('.wk-goal-h')!)
      expect(card?.querySelector('.wk-tasks')).toBeTruthy()

      const row = screen.getByTestId('job-row')
      expect(row).toBeTruthy()
      expect(row.classList.contains('wk-task')).toBe(true)
      // Scope text search to the goal card — the WorkAside also surfaces this
      // task as a blocker, so screen.getByText() would find multiple matches.
      expect(within(card! as HTMLElement).getByText('Blocked job')).toBeTruthy()
      expect(screen.getByTestId('job-blocker').textContent).toContain('dependency missing')
      expect(screen.queryByTestId('job-detail')).toBeNull()
    })

    it('marks the goal list with the design tree class and shows the raw phase chip', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      const { container } = render(html`<${Work} />`)

      expect(container.querySelector('main.ov-flush')).toBeTruthy()
      expect(screen.getByTestId('work-goal-list').classList.contains('wk-tree')).toBe(true)
      expect(container.querySelector('.wk-goal-phase')?.textContent).toBe('executing')
    })

    it('renders a re-run chip on task rows carrying predecessor_task_id (RFC-0323)', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Rerun job', goal_id: 'G-1', status: 'todo', predecessor_task_id: 'J-0' },
        { id: 'J-2', title: 'Plain job', goal_id: 'G-1', status: 'todo' },
      ]

      const { container } = render(html`<${Work} />`)

      const card = container.querySelector('[data-goal-id="G-1"]')
      fireEvent.click(card!.querySelector('.wk-goal-h')!)

      const rerun = screen.getByTestId('job-rerun')
      expect(rerun.textContent).toContain('J-0')
      expect(rerun.getAttribute('title')).toContain('predecessor_task_id = J-0')
      // Only the re-run task carries the chip.
      expect(card?.querySelectorAll('[data-testid="job-rerun"]').length).toBe(1)
    })

    it('navigates to keeper workspace when keeper assignment is clicked', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Assigned job', goal_id: 'G-1', status: 'in_progress', assignee: 'sangsu' },
      ]
      keepers.value = [
        { name: 'sangsu', status: 'idle' },
      ]

      render(html`<${Work} />`)

      fireEvent.click(screen.getByTestId('goal-card').querySelector('.wk-goal-h')!)

      const keeperButton = screen.getByTestId('job-keeper')
      expect(keeperButton).toBeTruthy()
      fireEvent.click(keeperButton)

      expect(navigateMock).toHaveBeenCalledWith('monitoring', { section: 'agents', view: 'keepers', keeper: 'sangsu' })
    })

    it('surfaces claimable backlog tasks in a dedicated backlog section', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Linked job', goal_id: 'G-1', status: 'todo' },
        { id: 'U-1', title: 'Orphan job', status: 'todo' },
        { id: 'U-2', title: 'Another orphan', status: 'in_progress' },
      ]

      render(html`<${Work} />`)

      expect(screen.getByTestId('kpi-backlog').textContent).toBe('2')

      const backlog = screen.getByTestId('work-backlog')
      expect(backlog).toBeTruthy()
      expect(backlog.textContent).toContain('클레임 가능 백로그')
      expect(backlog.textContent).toContain('2')
      expect(backlog.querySelectorAll('.wk-task-claim').length).toBe(2)
      expect(screen.getByText('Orphan job')).toBeTruthy()
      expect(screen.getByText('Linked job')).toBeTruthy()
    })

    it('keeps every live backlog task in a scrollable region without a numeric preview policy', () => {
      tasks.value = Array.from({ length: 8 }, (_, index) => ({
        id: `U-${index + 1}`,
        title: `Backlog task ${index + 1}`,
        status: 'todo' as const,
      }))

      render(html`<${Work} />`)

      const backlog = screen.getByTestId('work-backlog')
      const list = backlog.querySelector('.wk-backlog-list')
      expect(list?.getAttribute('aria-label')).toBe('클레임 가능 백로그 목록')
      expect(backlog.querySelectorAll('.wk-task-claim')).toHaveLength(8)
      expect(backlog.querySelector('.wk-backlog-toggle')).toBeNull()
      expect(screen.getByText('Backlog task 8')).toBeTruthy()
    })

    it('virtualizes a large backlog while preserving the full live count', () => {
      tasks.value = Array.from({ length: 100 }, (_, index) => ({
        id: `U-${index + 1}`,
        title: `Backlog task ${index + 1}`,
        status: 'todo' as const,
      }))

      render(html`<${Work} />`)

      const backlog = screen.getByTestId('work-backlog')
      expect(backlog.querySelector('.wk-backlog-h')?.textContent).toContain('100')
      expect(backlog.querySelector('.virtual-list-spacer')).not.toBeNull()
      expect(backlog.querySelectorAll('.wk-task-claim').length).toBeGreaterThan(0)
      expect(backlog.querySelectorAll('.wk-task-claim').length).toBeLessThan(100)
      expect(backlog.textContent).toContain('Backlog task 1')
    })

    it('expands inline task detail for handoff context', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        {
          id: 'J-1',
          title: 'Detail job',
          goal_id: 'G-1',
          status: 'todo',
          assignee: 'dev',
          handoff_context: {
            summary: 'Handoff summary text',
            next_step: 'Deploy to staging',
          },
        },
      ]

      render(html`<${Work} />`)

      fireEvent.click(screen.getByTestId('goal-card').querySelector('.wk-goal-h')!)

      expect(screen.queryByTestId('work-task-detail')).toBeNull()

      fireEvent.click(screen.getByText('Detail job'))

      const detail = screen.getByTestId('job-row').querySelector('.wk-task-detail')
      expect(detail).toBeTruthy()
      expect(detail?.textContent).toContain('Handoff summary text')
      expect(detail?.textContent).toContain('Deploy to staging')
    })

    it('expands inline task detail for execution links and contract evidence without synthetic lineage', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        {
          id: 'J-ledger',
          title: 'Ledger job',
          goal_id: 'G-1',
          status: 'in_progress',
          created_at: '2026-01-02T00:00:00Z',
          updated_at: '2026-01-02T01:00:00Z',
          execution_links: {
            session_id: 'sess-ledger',
            operation_id: 'op-ledger',
          },
          contract: {
            strict: true,
            completion_contract: ['merge-ready proof'],
            required_evidence: ['typed test evidence'],
          },
          handoff_context: {
            summary: '',
            evidence_refs: ['receipt-1'],
            updated_by: 'sangsu',
            updated_at: '2026-01-02T02:00:00Z',
          },
        },
      ]

      const { container } = render(html`<${Work} />`)

      fireEvent.click(screen.getByTestId('goal-card').querySelector('.wk-goal-h')!)
      fireEvent.click(container.querySelector('[data-job-id="J-ledger"] .wk-task-main')!)

      const ledger = within(screen.getByTestId('job-row')).getByTestId('task-evidence-ledger')
      expect(ledger.textContent).toContain('sess-ledger')
      expect(ledger.textContent).toContain('op-ledger')
      expect(ledger.textContent).toContain('strict')
      expect(ledger.textContent).toContain('merge-ready proof')
      expect(ledger.textContent).toContain('typed test evidence')
      expect(ledger.textContent).toContain('receipt-1')
      expect(ledger.textContent).toContain('sangsu')
      expect(ledger.textContent).toContain('2026-01-02T00:00:00Z')
      expect(ledger.textContent).not.toContain('활동 흐름')
    })

    it('maps known goal phase IDs to Korean labels', () => {
      goals.value = [
        { id: 'G-1', title: 'Active goal', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-2', title: 'Completed goal', priority: 3, phase: 'completed', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      render(html`<${Work} />`)

      const cards = screen.getAllByTestId('goal-card')
      expect(cards[0]?.textContent).toContain('실행 중')
      expect(cards[1]?.textContent).toContain('완료')
    })

    it('styles only explicit stored goal phases', () => {
      goals.value = [
        { id: 'G-ok', title: 'Active', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-done', title: 'Completed', priority: 2, phase: 'completed', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-warn', title: 'Paused', priority: 2, phase: 'paused', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-bad', title: 'Cancelled', priority: 2, phase: 'dropped', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      const { container } = render(html`<${Work} />`)

      const chipFor = (id: string) =>
        container.querySelector(`[data-goal-id="${id}"] .wk-gstatus`)
      expect(chipFor('G-ok')?.classList.contains('neutral')).toBe(true)
      expect(chipFor('G-done')?.classList.contains('ok')).toBe(true)
      expect(chipFor('G-warn')?.classList.contains('warn')).toBe(true)
      expect(chipFor('G-bad')?.classList.contains('bad')).toBe(true)
    })

    it('keeps unknown goal phases neutral', () => {
      goals.value = [
        { id: 'G-x', title: 'Mystery', priority: 2, phase: 'something_new', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      const { container } = render(html`<${Work} />`)

      const chip = container.querySelector('[data-goal-id="G-x"] .wk-gstatus')
      expect(chip?.classList.contains('neutral')).toBe(true)
      // unknown phase text is passed through verbatim
      expect(chip?.textContent).toContain('something_new')
    })

    it('does not render a task dossier sidebar for route-selected tasks', () => {
      routeSignal.value = {
        tab: 'workspace',
        params: { section: 'work', task: 'J-1' },
        postId: null,
      }
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Selectable job', goal_id: 'G-1', status: 'todo' },
      ]

      render(html`<${Work} />`)

      expect(screen.queryByTestId('work-task-detail')).toBeNull()
      expect(screen.queryByTestId('job-detail')).toBeNull()
    })

    // ── Goal-create composer ─────────────────────────────────────────────────
    describe('goal-create composer', () => {
      beforeEach(async () => {
        callMcpToolMock.mockReset()
        // Reset the goal-create signals and local form state before each test
        const { showGoalCreate, _testResetGoalCreateOutcomes } = await import('./goals/goal-create-state')
        const { resetGoalCreateFormLocal } = await import('./goals/goal-create-form')
        showGoalCreate.value = false
        resetGoalCreateFormLocal()
        _testResetGoalCreateOutcomes()
      })

      it('calls masc_goal_upsert with the entered success criterion and priority', async () => {
        callMcpToolMock.mockImplementation(async (_name, args) => JSON.stringify({
          status: 'ok', action: 'created', goal_id: args.id, goal: { id: args.id },
        }))

        goals.value = []
        tasks.value = []

        render(html`<${Work} />`)

        // Open the form
        fireEvent.click(screen.getByTestId('work-new-goal'))
        expect(screen.getByTestId('goal-create-panel')).toBeTruthy()

        // Fill in the title
        const titleInput = screen.getByTestId('goal-create-title-input')
        fireEvent.input(titleInput, { target: { value: 'SLO 400ms 회복' } })
        fireEvent.input(screen.getByTestId('goal-create-metric'), { target: { value: 'scheduler p99 over 24 hours' } })
        fireEvent.input(screen.getByTestId('goal-create-target'), { target: { value: '400 ms or less' } })

        // Submit
        fireEvent.click(screen.getByTestId('goal-create-submit'))

        // Wait for async createGoal to resolve
        await vi.waitFor(() => expect(callMcpToolMock).toHaveBeenCalledTimes(1))

        expect(callMcpToolMock).toHaveBeenCalledWith('masc_goal_upsert', expect.objectContaining({
          title: 'SLO 400ms 회복',
          metric: 'scheduler p99 over 24 hours',
          target_value: '400 ms or less',
          priority: expect.any(Number),
          id: expect.stringMatching(/^goal-/), if_absent: true,
          expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
        }))
        // masc_goal_upsert rejects lifecycle fields; the form must not send them.
        const rawCalls = callMcpToolMock.mock.calls as unknown as [string, Record<string, unknown>][]
        const callArgs = rawCalls[0]?.[1] ?? {}
        expect(callArgs).not.toHaveProperty('status')
        expect(callArgs).not.toHaveProperty('phase')
      })

      it('does not call masc_goal_upsert when title is empty or whitespace', async () => {
        callMcpToolMock.mockResolvedValue('ok')

        goals.value = []
        tasks.value = []

        render(html`<${Work} />`)

        // Open the form
        fireEvent.click(screen.getByTestId('work-new-goal'))

        // Leave title empty and click submit
        fireEvent.click(screen.getByTestId('goal-create-submit'))

        await new Promise(resolve => setTimeout(resolve, 0))

        expect(callMcpToolMock).not.toHaveBeenCalled()
      })
    })

    // ── WorkAside operator triage panel ─────────────────────────────────────
    describe('WorkAside operator triage panel', () => {
      // All WorkAside tests use section: 'work' (set in beforeEach above)

      it('renders the aside panel alongside the main goal list', () => {
        goals.value = [
          { id: 'G-1', title: 'Active Goal', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []

        render(html`<${Work} />`)

        // The main goal list and KPI strip should still be present
        expect(screen.getByTestId('work-kpis')).toBeTruthy()
        // The aside panel should be present
        expect(screen.getByTestId('work-aside')).toBeTruthy()
      })

      it('shows calm empty state when no flagged goals, no todos, and no recent tasks', () => {
        goals.value = [
          { id: 'G-1', title: 'Normal Goal', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        expect(aside.querySelector('.wka-hud')?.textContent).toContain('백로그')
        // "지금 상황" calm state
        expect(aside.querySelector('[data-testid="wka-flagged-calm"]')?.textContent).toContain('주의 목표 없음')
        // "해야 할 일" calm state
        expect(aside.querySelector('[data-testid="wka-todo-calm"]')?.textContent).toContain('대기 중인 작업 없음')
        // "최근 한 일" calm state
        expect(aside.querySelector('[data-testid="wka-recent-calm"]')?.textContent).toContain('완료된 task 없음')
      })

      it('flags blocked and paused goals without synthetic verification phases', () => {
        goals.value = [
          { id: 'G-ok', title: 'Executing Goal', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
          { id: 'G-bl', title: 'Blocked Goal', priority: 2, phase: 'blocked', created_at: '2026-01-01', updated_at: '2026-01-01' },
          { id: 'G-pa', title: 'Paused Goal', priority: 3, phase: 'paused', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        const flaggedItems = aside.querySelectorAll('[data-testid="wka-flagged-item"]')
        // G-ok (executing) must NOT appear; blocked and paused do.
        expect(flaggedItems.length).toBe(2)
        const titles = Array.from(flaggedItems).map(el => el.textContent ?? '')
        expect(titles.some(t => t.includes('Blocked Goal'))).toBe(true)
        expect(titles.some(t => t.includes('Paused Goal'))).toBe(true)
        expect(titles.some(t => t.includes('Executing Goal'))).toBe(false)
        // No calm state should be shown
        expect(aside.querySelector('[data-testid="wka-flagged-calm"]')).toBeNull()
      })

      it('surfaces verify tasks (awaiting_verification status)', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          {
            id: 'J-vf',
            title: 'Verify Me',
            goal_id: 'G-1',
            status: 'awaiting_verification',
          },
        ]

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        const verifyItems = aside.querySelectorAll('[data-testid="wka-verify-item"]')
        expect(verifyItems.length).toBe(1)
        expect(verifyItems[0]?.classList.contains('verify')).toBe(true)
        expect(verifyItems[0]?.textContent).toContain('Verify Me')
        expect(verifyItems[0]?.textContent).toContain('검증 대기')
      })

      it('surfaces tasks with a blocker note (cancelled with handoff_context.reason)', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          {
            id: 'J-bl',
            title: 'Blocked Task',
            goal_id: 'G-1',
            status: 'cancelled',
            handoff_context: { summary: '', reason: 'dependency unavailable' },
          },
        ]

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        const blockerItems = aside.querySelectorAll('[data-testid="wka-blocker-item"]')
        expect(blockerItems.length).toBe(1)
        expect(blockerItems[0]?.classList.contains('block')).toBe(true)
        expect(blockerItems[0]?.textContent).toContain('Blocked Task')
        expect(blockerItems[0]?.textContent).toContain('dependency unavailable')
      })

      it('labels a cancellation 취소 and names the canceller, distinct from 차단', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        // Both rows land in the same aside list. Before, both read 차단 with no
        // actor, so an operator could not tell a stalled task from one another
        // keeper deliberately ended.
        tasks.value = [
          {
            id: 'J-blocked',
            title: 'Stalled Task',
            goal_id: 'G-1',
            status: 'blocked',
            handoff_context: { summary: '', reason: 'dependency unavailable' },
          },
          {
            // The canceller's reason arrives top-level, the way the API
            // flattens it out of the task status. Putting it in
            // handoff_context here would pass even if the top-level reason
            // were dropped on the way in.
            id: 'J-cancelled',
            title: 'Ended Task',
            goal_id: 'G-1',
            status: 'cancelled',
            cancelled_by: 'keeper-rondo-agent',
            reason: 'BLOCKED: service absent from sandbox',
          },
        ]

        render(html`<${Work} />`)

        const items = Array.from(
          screen.getByTestId('work-aside').querySelectorAll('[data-testid="wka-blocker-item"]'),
        )
        expect(items.length).toBe(2)

        const blocked = items.find(el => el.textContent?.includes('Stalled Task'))
        const cancelled = items.find(el => el.textContent?.includes('Ended Task'))
        expect(blocked?.textContent).toContain('차단')
        expect(blocked?.textContent).not.toContain('취소')
        expect(cancelled?.textContent).toContain('취소')
        expect(cancelled?.textContent).toContain('keeper-rondo-agent')
        expect(cancelled?.textContent).toContain('BLOCKED: service absent from sandbox')
      })

      it('labels a cancellation 취소 even when no canceller is carried', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        // Not every projection feeding this list carries the actor. Deriving
        // the label from the actor rather than the status relabelled those
        // cancellations as blocks, which is the separation this row exists for.
        tasks.value = [
          {
            id: 'J-actorless',
            title: 'Ended Without Actor',
            goal_id: 'G-1',
            status: 'cancelled',
            reason: 'superseded by G-2',
          },
        ]

        render(html`<${Work} />`)

        const item = screen
          .getByTestId('work-aside')
          .querySelector('[data-testid="wka-blocker-item"]')
        expect(item?.textContent).toContain('취소')
        expect(item?.textContent).not.toContain('차단')
        expect(item?.textContent).toContain('superseded by G-2')
      })

      it('shows a summary-only handoff as the cancellation explanation', () => {
        // A strict transition is rejected without handoff_context.summary while
        // reason stays optional, and the backend publishes that summary as the
        // stated reason. Skipping it here made this surface disagree with the
        // broadcast and the author wake.
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          {
            id: 'J-summary',
            title: 'Ended Task',
            goal_id: 'G-1',
            status: 'cancelled',
            cancelled_by: 'keeper-rondo-agent',
            handoff_context: { summary: 'returning to backlog until the sandbox ships it' },
          },
        ]

        render(html`<${Work} />`)

        const item = screen
          .getByTestId('work-aside')
          .querySelector('[data-testid="wka-blocker-item"]')
        expect(item?.textContent).toContain('returning to backlog until the sandbox ships it')
        expect(item?.textContent).not.toContain('cancelled')
      })

      it('prefers the task reason over an older handoff note on a cancellation', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        // handoff_context is a note the assignee left while working; the task
        // reason is why the cancellation happened. Showing the note would
        // answer a question the operator did not ask.
        tasks.value = [
          {
            id: 'J-both',
            title: 'Ended Task',
            goal_id: 'G-1',
            status: 'cancelled',
            cancelled_by: 'keeper-rondo-agent',
            reason: 'superseded by G-2',
            handoff_context: { summary: '', reason: 'waiting on sandbox' },
          },
        ]

        render(html`<${Work} />`)

        const item = screen
          .getByTestId('work-aside')
          .querySelector('[data-testid="wka-blocker-item"]')
        expect(item?.textContent).toContain('superseded by G-2')
        expect(item?.textContent).not.toContain('waiting on sandbox')
      })

      it('leaves cancelled tasks out of the goal progress denominator', () => {
        // Cancelled tasks were skipped for every numerator bucket while still
        // counted in the total, so a goal whose only other task is complete
        // sat at 1/2 and could never reach 1/1. Work called off is not work
        // left to do.
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          { id: 'J-done', title: 'Finished', goal_id: 'G-1', status: 'done' },
          { id: 'J-cancelled', title: 'Called off', goal_id: 'G-1', status: 'cancelled', cancelled_by: 'keeper-rondo-agent' },
        ]

        render(html`<${Work} />`)

        const card = screen.getByTestId('goal-card')
        expect(card.textContent).toContain('1/1')
        expect(card.textContent).not.toContain('1/2')
      })

      it('uses the reported backlog total over the rows the payload sent', () => {
        // The payload sends active tasks plus a bounded window of recent
        // terminal ones. Counting those rows understates a tile labelled
        // 전체 작업 for every task that has left the window — which is where
        // cancellations end up.
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          { id: 'J-1', title: 'Visible', goal_id: 'G-1', status: 'in_progress' },
        ]
        executionTaskTotal.value = 137

        render(html`<${Work} />`)

        expect(screen.getByTestId('kpi-tasks')).toHaveTextContent('137')
      })

      it('falls back to the visible rows when no backlog total is reported', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          { id: 'J-1', title: 'One', goal_id: 'G-1', status: 'in_progress' },
          { id: 'J-2', title: 'Two', goal_id: 'G-1', status: 'cancelled', cancelled_by: 'keeper-rondo-agent' },
        ]
        executionTaskTotal.value = null

        render(html`<${Work} />`)

        expect(screen.getByTestId('kpi-tasks')).toHaveTextContent('2')
      })

      it('counts cancelled tasks in the 전체 작업 total', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        // done and cancelled are both terminal. The total counted done and
        // dropped cancelled, so a tile labelled 전체 was short by exactly the
        // tasks this view was hiding elsewhere.
        tasks.value = [
          { id: 'J-1', title: 'Todo', goal_id: 'G-1', status: 'todo' },
          { id: 'J-2', title: 'Done', goal_id: 'G-1', status: 'done' },
          { id: 'J-3', title: 'Cancelled', goal_id: 'G-1', status: 'cancelled', cancelled_by: 'keeper-rondo-agent' },
        ]

        render(html`<${Work} />`)

        expect(screen.getByTestId('kpi-tasks').textContent).toBe('3')
        // Sub-counts filter on status, so none of them absorb the cancellation.
        expect(screen.getByTestId('kpi-wip').textContent).toBe('0')
        expect(screen.getByTestId('kpi-verify').textContent).toBe('0')
      })

      it('surfaces claimable backlog tasks as a single aggregate claim button', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          { id: 'J-1', title: 'Unassigned A', goal_id: 'G-1', status: 'todo' },
          { id: 'J-2', title: 'Unassigned B', goal_id: 'G-1', status: 'todo' },
          { id: 'J-3', title: 'Assigned', goal_id: 'G-1', status: 'todo', assignee: 'sangsu' },
        ]

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        const backlogItem = aside.querySelector('[data-testid="wka-backlog-item"]')
        expect(backlogItem).toBeTruthy()
        expect(backlogItem?.classList.contains('claim')).toBe(true)
        expect(backlogItem?.textContent).toContain('미배정 task 2건')
      })

      it('surfaces done tasks in the 최근 한 일 section', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          { id: 'J-done1', title: 'Finished Task', goal_id: 'G-1', status: 'done' },
          { id: 'J-done2', title: 'Another Done', goal_id: 'G-1', status: 'done' },
          { id: 'J-wip', title: 'In Progress', goal_id: 'G-1', status: 'in_progress' },
        ]

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        const recentItems = aside.querySelectorAll('[data-testid="wka-recent-item"]')
        expect(recentItems.length).toBe(2)
        const texts = Array.from(recentItems).map(el => el.textContent ?? '')
        expect(texts.some(t => t.includes('Finished Task'))).toBe(true)
        expect(texts.some(t => t.includes('Another Done'))).toBe(true)
        expect(aside.querySelector('[data-testid="wka-recent-calm"]')).toBeNull()
      })

      it('toggles to collapsed rail on collapse button click and back on railbtn click', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []

        // Clear any persisted collapsed state from other tests
        try { localStorage.removeItem('v2.wkAsideCollapsed') } catch (_) { /* noop */ }

        render(html`<${Work} />`)

        // Expanded state: main aside is visible
        expect(screen.getByTestId('work-aside')).toBeTruthy()
        expect(screen.queryByTestId('work-aside-collapsed')).toBeNull()

        // Click collapse button
        const collapseBtn = screen.getByTestId('work-aside').querySelector('.wka-collapse')
        expect(collapseBtn).toBeTruthy()
        fireEvent.click(collapseBtn!)

        // Collapsed rail should now render
        expect(screen.queryByTestId('work-aside')).toBeNull()
        expect(screen.getByTestId('work-aside-collapsed')).toBeTruthy()

        // Click expand
        const railBtn = screen.getByTestId('work-aside-collapsed').querySelector('.wka-railbtn')
        expect(railBtn).toBeTruthy()
        fireEvent.click(railBtn!)

        // Back to expanded
        expect(screen.getByTestId('work-aside')).toBeTruthy()
        expect(screen.queryByTestId('work-aside-collapsed')).toBeNull()
      })

      it('does not mix phase classification with string substring matching', () => {
        // Regression guard: goals in `executing` phase must never appear as flagged,
        // even if their title/status string contains substrings like 'blocked'.
        goals.value = [
          { id: 'G-tricky', title: 'Not blocked — just named oddly', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        // No flagged items — executing goals are not flagged
        expect(aside.querySelectorAll('[data-testid="wka-flagged-item"]').length).toBe(0)
        expect(aside.querySelector('[data-testid="wka-flagged-calm"]')).toBeTruthy()
      })
    })

    // ── Kanban view ─────────────────────────────────────────────────────────
    describe('kanban view toggle', () => {
      beforeEach(() => {
        // Reset persisted view state so tests start from the default 'list' view
        try { localStorage.removeItem('v2.workView') } catch (_) { /* noop */ }
      })

      it('renders the view toggle with list active by default', () => {
        goals.value = []
        tasks.value = []

        render(html`<${Work} />`)

        const seg = screen.getByTestId('work-viewseg')
        expect(seg).toBeTruthy()
        const listBtn = screen.getByTestId('work-view-list')
        const kanbanBtn = screen.getByTestId('work-view-kanban')
        expect(listBtn.classList.contains('on')).toBe(true)
        expect(kanbanBtn.classList.contains('on')).toBe(false)
        // List view: goal list container present (even if empty)
        expect(screen.queryByTestId('work-kanban')).toBeNull()
      })

      it('switches to kanban board on clicking the 칸반 button', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          { id: 'J-1', title: 'Todo task', goal_id: 'G-1', status: 'todo' },
          { id: 'J-2', title: 'In progress', goal_id: 'G-1', status: 'in_progress' },
          { id: 'J-3', title: 'Done task', goal_id: 'G-1', status: 'done' },
          { id: 'J-4', title: 'Cancelled task', goal_id: 'G-1', status: 'cancelled', cancelled_by: 'keeper-rondo-agent' },
        ]

        render(html`<${Work} />`)

        // Initially in list view
        expect(screen.queryByTestId('work-kanban')).toBeNull()
        expect(screen.getByTestId('work-goal-list')).toBeTruthy()

        // Switch to kanban
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        // Kanban board present; list view gone
        expect(screen.getByTestId('work-board-section').textContent).toContain('칸반 · 상태별')
        const board = screen.getByTestId('work-kanban')
        expect(board).toBeTruthy()
        expect(screen.queryByTestId('work-goal-list')).toBeNull()

        // Toggle button state updated
        expect(screen.getByTestId('work-view-kanban').classList.contains('on')).toBe(true)
        expect(screen.getByTestId('work-view-list').classList.contains('on')).toBe(false)

        // The 5 KANBAN_COLUMNS are rendered
        expect(screen.getByTestId('kanban-col-todo')).toBeTruthy()
        expect(screen.getByTestId('kanban-col-claimed')).toBeTruthy()
        expect(screen.getByTestId('kanban-col-in_progress')).toBeTruthy()
        expect(screen.getByTestId('kanban-col-awaiting_verification')).toBeTruthy()
        expect(screen.getByTestId('kanban-col-done')).toBeTruthy()
        expect(screen.getByTestId('kanban-col-cancelled')).toBeTruthy()

        // Tasks appear in the correct columns (by data-testid selector)
        const todoCol = screen.getByTestId('kanban-col-todo')
        const wipCol  = screen.getByTestId('kanban-col-in_progress')
        const doneCol = screen.getByTestId('kanban-col-done')
        expect(todoCol.querySelector('.wk-kcol-dot.todo')).toBeTruthy()
        expect(wipCol.querySelector('.wk-kcol-dot.wip')).toBeTruthy()
        expect(doneCol.querySelector('.wk-kcol-dot.done')).toBeTruthy()
        expect(todoCol.querySelector('.wk-kcol-n')?.textContent).toBe('1')
        expect(todoCol.textContent).toContain('Todo task')
        expect(wipCol.textContent).toContain('In progress')
        expect(doneCol.textContent).toContain('Done task')

        // A cancellation is terminal like done, and gets a column for the same
        // reason: hiding it made an ended task indistinguishable from one that
        // was never picked up.
        const cancelledCol = screen.getByTestId('kanban-col-cancelled')
        expect(cancelledCol.querySelector('.wk-kcol-dot.cancelled')).toBeTruthy()
        expect(cancelledCol.textContent).toContain('Cancelled task')
      })

      it('switches back to list view on clicking the 리스트 button', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []

        render(html`<${Work} />`)

        // Go to kanban
        fireEvent.click(screen.getByTestId('work-view-kanban'))
        expect(screen.getByTestId('work-kanban')).toBeTruthy()

        // Back to list
        fireEvent.click(screen.getByTestId('work-view-list'))
        expect(screen.queryByTestId('work-kanban')).toBeNull()
        expect(screen.getByTestId('work-view-list').classList.contains('on')).toBe(true)
      })

      it('places tasks in the correct column by status using typed KANBAN_COLUMNS (no string-match classification)', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        // One task per status
        tasks.value = [
          { id: 'T-todo',   title: 'Todo item',   goal_id: 'G-1', status: 'todo' },
          { id: 'T-claim',  title: 'Claimed item', goal_id: 'G-1', status: 'claimed', assignee: 'keeper-x' },
          { id: 'T-wip',    title: 'WIP item',    goal_id: 'G-1', status: 'in_progress', assignee: 'keeper-y' },
          { id: 'T-verify', title: 'Verify item', goal_id: 'G-1', status: 'awaiting_verification', assignee: 'keeper-z' },
          { id: 'T-done',   title: 'Done item',   goal_id: 'G-1', status: 'done', assignee: 'keeper-w' },
          { id: 'T-cancel', title: 'Cancelled item', goal_id: 'G-1', status: 'cancelled', cancelled_by: 'keeper-rondo-agent' },
        ]

        render(html`<${Work} />`)
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        const board = screen.getByTestId('work-kanban')
        const cards = board.querySelectorAll('[data-testid="kanban-card"]')
        expect(cards.length).toBe(6)

        // Each card sits inside the correct column
        const colFor = (status: string) => board.querySelector(`[data-testid="kanban-col-${status}"]`)
        expect(colFor('todo')?.querySelector('[data-kanban-task-id="T-todo"]')).toBeTruthy()
        expect(colFor('claimed')?.querySelector('[data-kanban-task-id="T-claim"]')).toBeTruthy()
        expect(colFor('in_progress')?.querySelector('[data-kanban-task-id="T-wip"]')).toBeTruthy()
        expect(colFor('awaiting_verification')?.querySelector('[data-kanban-task-id="T-verify"]')).toBeTruthy()
        expect(colFor('done')?.querySelector('[data-kanban-task-id="T-done"]')).toBeTruthy()
        expect(colFor('cancelled')?.querySelector('[data-kanban-task-id="T-cancel"]')).toBeTruthy()
      })

      it('renders an owning-goal jump button on kanban cards that returns to the list view', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          { id: 'J-1', title: 'Todo task', goal_id: 'G-1', status: 'todo' },
        ]

        render(html`<${Work} />`)
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        const board = screen.getByTestId('work-kanban')
        const jump = board.querySelector('[data-kanban-goal-jump="G-1"]')
        expect(jump).toBeTruthy()
        expect(jump?.textContent).toContain('Goal One')

        // Goal cards only exist in the list view, so the jump switches back to it.
        fireEvent.click(jump as Element)
        expect(screen.queryByTestId('work-kanban')).toBeNull()
        expect(screen.getByTestId('work-goal-list')).toBeTruthy()
        expect(screen.getByTestId('work-view-list').classList.contains('on')).toBe(true)
      })

      it('renders re-run chip and handoff marker on kanban cards from live task fields', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          {
            id: 'J-1',
            title: 'Rerun with handoff',
            goal_id: 'G-1',
            status: 'in_progress',
            assignee: 'keeper-x',
            predecessor_task_id: 'J-0',
            handoff_context: { summary: 'handed off from keeper-y' },
          },
          { id: 'J-2', title: 'Plain task', goal_id: 'G-1', status: 'todo' },
        ]

        render(html`<${Work} />`)
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        const board = screen.getByTestId('work-kanban')
        const card = board.querySelector('[data-kanban-task-id="J-1"]')
        const rerun = card?.querySelector('[data-testid="kanban-rerun"]')
        expect(rerun?.textContent).toContain('J-0')
        expect(card?.querySelector('[data-testid="kanban-handoff"]')).toBeTruthy()

        const plain = board.querySelector('[data-kanban-task-id="J-2"]')
        expect(plain?.querySelector('[data-testid="kanban-rerun"]')).toBeNull()
        expect(plain?.querySelector('[data-testid="kanban-handoff"]')).toBeNull()
      })

      // The tree used to speak its own status spelling ("completed" for done,
      // "pending" for todo) and the frontend translated it. Both sides now use
      // Masc_domain.task_status_to_string, so the fixture carries the spelling
      // the backend actually emits and no translation is involved.
      it('surfaces an unrecognised tree status as unknown instead of translating it', () => {
        // The removed map silently rewrote a second vocabulary into the first.
        // With one spelling there is nothing to translate, so a status the
        // domain never produces must read as unknown and keep its raw text
        // rather than being guessed into a neighbouring state.
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [goalTreeTask({ id: 'T-legacy', title: 'Legacy spelling', status: 'completed' })],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, total_tasks: 1 }),
        }

        render(html`<${Work} />`)
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        const doneCol = screen.getByTestId('kanban-col-done')
        expect(doneCol.textContent).not.toContain('Legacy spelling')
      })

      it('includes recursive goal tree tasks in KPIs and kanban', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
          { id: 'G-child', title: 'Child Goal', priority: 2, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [
                goalTreeTask({ id: 'T-root', title: 'Root completed task', goal_id: 'G-1', status: 'done' }),
              ],
              children: [
                goalTreeNode({
                  id: 'G-child',
                  title: 'Child Goal',
                  tasks: [
                    goalTreeTask({ id: 'T-child', title: 'Child completed task', goal_id: 'G-child', status: 'done' }),
                  ],
                }),
              ],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 2, total_tasks: 2, done_tasks: 2 }),
        }

        render(html`<${Work} />`)

        expect(screen.getByTestId('kpi-tasks')).toHaveTextContent('2')
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        const doneCol = screen.getByTestId('kanban-col-done')
        expect(doneCol.textContent).toContain('Root completed task')
        expect(doneCol.textContent).toContain('Child completed task')
        const rootCard = doneCol.querySelector('[data-kanban-task-id="T-root"]') as HTMLElement
        fireEvent.click(rootCard)
        expect(selectedTask.value?.status).toBe('done')
        expect(selectedTask.value?.completed_at).toBe('2026-01-02')
      })

      it('shows the canceller and reason on a tree-only cancellation', () => {
        // Aged-out cancellations reach Work through the tree alone. Without
        // these fields the card degrades to a bare 취소 with no actor and no
        // explanation, while the status it was built from holds both.
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [
                goalTreeTask({
                  id: 'T-aged',
                  title: 'Aged out cancellation',
                  goal_id: null,
                  status: 'cancelled',
                  cancelled_by: 'keeper-rondo-agent',
                  reason: 'superseded by G-2',
                }),
              ],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, total_tasks: 1, done_tasks: 0 }),
        }

        render(html`<${Work} />`)

        const item = screen
          .getByTestId('work-aside')
          .querySelector('[data-testid="wka-blocker-item"]')
        expect(item?.textContent).toContain('취소')
        expect(item?.textContent).toContain('keeper-rondo-agent')
        expect(item?.textContent).toContain('superseded by G-2')
      })

      it('links a tree task to its containing node when the projection carries no goal_id', () => {
        // The backend tree projection has no per-task goal_id. A task that
        // reaches the surface only through the tree — anything older than the
        // execution snapshot window — would otherwise render unlinked, with a
        // dead jump to its owning goal. The containing node is that goal.
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [
                goalTreeTask({
                  id: 'T-orphan',
                  title: 'Tree only cancellation',
                  goal_id: null,
                  status: 'cancelled',
                }),
              ],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, total_tasks: 1, done_tasks: 0 }),
        }

        render(html`<${Work} />`)
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        const col = screen.getByTestId('kanban-col-cancelled')
        const card = col.querySelector('[data-kanban-task-id="T-orphan"]') as HTMLElement
        expect(card).toBeTruthy()
        fireEvent.click(card)
        expect(selectedTask.value?.goal_id).toBe('G-1')
      })

      it('keeps unscoped execution tasks visible in kanban instead of requiring a goal_id', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [
                goalTreeTask({ id: 'T-goal', title: 'Goal store task', goal_id: 'G-1', status: 'done' }),
              ],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, total_tasks: 1, done_tasks: 1 }),
        }
        tasks.value = [
          { id: 'T-live', title: 'Live unscoped task', goal_id: null, status: 'in_progress', assignee: 'keeper-a' },
        ]

        render(html`<${Work} />`)

        expect(screen.getByTestId('kpi-tasks')).toHaveTextContent('2')
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        const wipCol = screen.getByTestId('kanban-col-in_progress')
        expect(wipCol.querySelector('[data-kanban-task-id="T-live"]')).toBeTruthy()
        expect(wipCol.textContent).toContain('Live unscoped task')
      })

      it('uses Goal Store fields as nullable fallback when merging execution tasks', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [
                goalTreeTask({ id: 'T-shared', title: 'Goal store title', goal_id: 'G-1', status: 'todo' }),
              ],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1, total_tasks: 1 }),
        }
        tasks.value = [
          { id: 'T-shared', title: 'Live shared task', goal_id: null, status: 'in_progress', assignee: 'keeper-a' },
        ]

        render(html`<${Work} />`)

        const goalCard = screen.getByTestId('goal-card')
        if (!goalCard.querySelector('[data-job-id="T-shared"]')) {
          fireEvent.click(within(goalCard).getByRole('button'))
        }
        const row = goalCard.querySelector('[data-job-id="T-shared"]')
        expect(row).toBeTruthy()
        expect(row?.textContent).toContain('Live shared task')
      })

      it('shows task titles on kanban cards and hides the backlog strip in kanban view', () => {
        goals.value = [
          { id: 'G-1', title: 'Target Goal', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          { id: 'J-1', title: 'Some task', goal_id: 'G-1', status: 'in_progress', assignee: 'keeper-a' },
          // Claimable todo to verify backlog strip hidden
          { id: 'J-2', title: 'Claimable', goal_id: 'G-1', status: 'todo' },
        ]

        render(html`<${Work} />`)
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        // Task titles appear on cards
        const board = screen.getByTestId('work-kanban')
        expect(board.textContent).toContain('Some task')
        expect(board.textContent).toContain('Claimable')

        // Backlog strip (.wk-backlog) must NOT be present in kanban view
        expect(screen.queryByTestId('work-backlog')).toBeNull()
      })

      it('opens the shared task detail overlay when a kanban card is clicked', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          { id: 'T-todo', title: 'Todo item', goal_id: 'G-1', status: 'todo' },
        ]

        render(html`<${Work} />`)
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        const card = screen
          .getByTestId('work-kanban')
          .querySelector('[data-kanban-task-id="T-todo"]') as HTMLElement
        expect(selectedTask.value).toBeNull()
        fireEvent.click(card)
        // openTaskDetail() set the shared selection signal (TaskDetailOverlay is
        // mounted globally in app.ts and renders off this signal).
        expect(selectedTask.value?.id).toBe('T-todo')
      })
    })

    describe('Goal Store tree edge cases', () => {
      it('guards against cyclic goal tree references when collecting tasks', () => {
        goals.value = []
        tasks.value = []
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [goalTreeTask({ id: 'T-1', goal_id: 'G-1', status: 'done' })],
              children: [
                goalTreeNode({
                  id: 'G-1',
                  tasks: [goalTreeTask({ id: 'T-2', goal_id: 'G-1', status: 'done' })],
                }),
              ],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, total_tasks: 1, done_tasks: 1 }),
        }

        render(html`<${Work} />`)

        expect(screen.getByTestId('kpi-tasks')).toHaveTextContent('1')
      })

      it('uses Goal Store tree titles for tasks linked to tree-only goals', () => {
        goals.value = []
        tasks.value = []
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-tree',
              title: 'Tree Only Goal',
              tasks: [goalTreeTask({ id: 'T-tree', goal_id: 'G-tree', status: 'todo' })],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, total_tasks: 1 }),
        }

        render(html`<${Work} />`)
        fireEvent.click(screen.getByTestId('work-view-list'))

        expect(screen.getByTestId('work-backlog').textContent).toContain('Tree Only Goal')
      })

      it('renders the declared completion criteria and the operator context on a goal card', () => {
        goals.value = [
          {
            id: 'G-1',
            title: 'Goal One',
            priority: 5,
            phase: 'executing',
            created_at: '2026-01-01',
            updated_at: '2026-01-04',
            last_review_note: 'metric 미충족 — merged PR은 1건뿐',
            metric: 'merged PR count',
            target_value: '5 PRs',
          },
        ]
        tasks.value = []
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              title: 'Goal One',
              priority: 5,
              phase: 'executing',
              last_review_note: 'metric 미충족 — merged PR은 1건뿐',
              metric: 'merged PR count',
              target_value: '5 PRs',
              task_summary: {
                total: 4,
                done: 3,
                open: 0,
                terminal: 4,
                awaiting_verification: 0,
                cancelled: 1,
                unassigned: 0,
                completion_pct: 75,
                by_status: {},
              },
              timeline_events: [{
                ts: '2026-01-04T10:00:00Z',
                kind: 'goal_owner',
                lane: 'goal',
                title: 'Goal Owner',
                summary: 'owner: <unassigned> -> dancer by operator',
                severity: 'ok',
              }],
              last_activity_at: '2026-01-04T10:00:00Z',
              stagnation_seconds: 3600,
              linked_keeper_names: ['sangsu'],
              pending_approval_count: 2,
              latest_keeper_ref: 'sangsu',
              latest_turn_ref: 42,
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1 }),
        }

        render(html`<${Work} />`)

        const goalCard = screen.getByTestId('goal-card')
        expandGoalCard(goalCard)

        const dossier = within(goalCard).getByTestId('goal-dossier')
        expect(dossier).toHaveAttribute('data-goal-dossier', 'G-1')
        expect(dossier).toHaveAttribute('data-goal-dossier-phase', 'executing')
        expect(dossier).toHaveAttribute('data-goal-dossier-timeline-count', '1')

        const text = dossier.textContent ?? ''
        // Why the goal sits where it does.
        expect(text).toContain('metric 미충족 — merged PR은 1건뿐')
        // Where to go next.
        expect(text).toContain('sangsu')
        expect(text).toContain('2건 승인 대기')
        // What the card header already states is not restated below it: the id
        // rides `data-goal-id` on the card, and the goals endpoint serves no
        // owner, so there is no 담당 row to fill or to excuse as empty.
        expect(dossier.querySelector('[data-goal-detail-row="id"]')).toBeNull()
        expect(dossier.querySelector('[data-goal-detail-row="owner"]')).toBeNull()
        expect(text).not.toContain('G-1')
        expect(text).not.toContain('담당')
        // The latest keeper/turn pair is not a row of its own; the keeper link
        // above is the way to that keeper.
        expect(dossier.querySelector('[data-goal-detail-row="latest-run"]')).toBeNull()
        expect(text).not.toContain('턴 42')
        expect(text).not.toContain('최근 실행')

        // What counts as done is declared once, in the card header, next to the
        // progress bar it qualifies.
        expect(goalCard.querySelector('[data-goal-metric]')?.textContent?.trim())
          .toBe('merged PR count · 5 PRs')
        expect(text).not.toContain('merged PR count')
      })

      it('declares the metric once in the header and never a second task tally', () => {
        goals.value = [
          {
            id: 'G-1', title: 'Goal One', priority: 5, phase: 'blocked',
            created_at: '2026-01-01', updated_at: '2026-01-04',
            metric: 'merged PR count', target_value: '5 PRs',
          },
        ]
        // Six done, one cancelled. The header excludes cancelled from the
        // denominator on purpose (see goalProgressCounts) and reads 6/6.
        tasks.value = [
          ...Array.from({ length: 6 }, (_, i) => ({
            id: `J-${i}`, title: `Done ${i}`, goal_id: 'G-1', status: 'done' as const,
          })),
          { id: 'J-X', title: 'Called off', goal_id: 'G-1', status: 'cancelled' as const },
        ]
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              phase: 'blocked',
              metric: 'merged PR count',
              target_value: '5 PRs',
              task_count: 7,
              task_done_count: 6,
              // task_summary keeps cancelled in `total`. The panel used to
              // print this alongside the header's 6/6, so one card answered
              // "how many tasks" twice, with 6 and with 7, and nothing said
              // which rule applied. The panel no longer answers it at all.
              task_summary: {
                total: 7, done: 6, open: 0, terminal: 7, awaiting_verification: 0,
                cancelled: 1, unassigned: 0, completion_pct: 85, by_status: {},
              },
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1 }),
        }

        render(html`<${Work} />`)
        const goalCard = screen.getByTestId('goal-card')
        expandGoalCard(goalCard)

        // The declaration sits next to the bar it qualifies, stated once.
        expect(goalCard.querySelector('[data-goal-metric]')?.textContent?.trim())
          .toBe('merged PR count · 5 PRs')
        expect(goalCard.querySelector('.wk-prog-lbl')?.textContent).toContain('6/6')

        const dossier = screen.getByTestId('goal-dossier')
        const text = dossier.textContent ?? ''
        expect(text).not.toContain('merged PR count')
        expect(text).not.toContain('5 PRs')
        expect(text).not.toContain('전체 7')
        expect(dossier.querySelector('[data-goal-detail-row="metric"]')).toBeNull()
        expect(dossier.querySelector('[data-goal-detail-row="target"]')).toBeNull()
        expect(dossier.querySelector('[data-goal-detail-row="tasks"]')).toBeNull()

        // No verdict. The backend used to answer `attained` at 100% here, from
        // observed=6 (finished linked tasks) against a target scraped out of
        // "5 PRs" — a task count wearing the metric's name. Nothing computes
        // that any more, and nothing in this panel may reintroduce it.
        expect(dossier.querySelector('[data-goal-detail-row="verdict"]')).toBeNull()
        expect(dossier.querySelector('[data-goal-detail-row="basis"]')).toBeNull()
        expect(dossier.querySelector('[data-goal-detail-row="observed"]')).toBeNull()
        expect(dossier.querySelector('[data-goal-detail-row="ready"]')).toBeNull()
        expect(dossier.querySelector('[data-goal-detail-caveat]')).toBeNull()
        expect(text).not.toContain('%')
        expect(text).not.toContain('달성')
      })

      it('shows no metric chip at all when the goal declares none', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 5, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-04' },
        ]
        tasks.value = []
        goalTreeData.value = {
          tree: [goalTreeNode({ id: 'G-1' })],
          summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1 }),
        }

        render(html`<${Work} />`)
        const goalCard = screen.getByTestId('goal-card')
        expandGoalCard(goalCard)

        // A goal with nothing declared gets no chip. There is no "정해진 지표가
        // 없어요" row any more — a placeholder telling the operator a field is
        // empty costs a line and settles nothing.
        expect(goalCard.querySelector('[data-goal-metric]')).toBeNull()
        const dossier = screen.getByTestId('goal-dossier')
        expect(dossier.querySelector('[data-goal-detail-row="metric"]')).toBeNull()
        expect(dossier.querySelector('[data-goal-detail-row="target"]')).toBeNull()
      })

      it('drops the goal_fsm projection tokens from the goal detail panel', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 5, phase: 'blocked', created_at: '2026-01-01', updated_at: '2026-01-04' },
        ]
        tasks.value = []
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              phase: 'blocked',
              goal_fsm: {
                state: 'blocked',
                source: 'goal.phase',
                next_actions: ['unblock', 'drop'],
                activity_observation: 'runtime',
              },
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1 }),
        }

        render(html`<${Work} />`)
        expandGoalCard(screen.getByTestId('goal-card'))

        // `source` was the constant `goal.phase` on every node, and the
        // next_actions strings named transitions this panel does not perform.
        const text = screen.getByTestId('goal-dossier').textContent ?? ''
        expect(text).not.toContain('goal.phase')
        expect(text).not.toContain('unblock')
        expect(text).not.toContain('drop')
        expect(text).not.toContain('activity runtime')
      })

      it('opens the keeper workspace from a linked keeper in the goal detail panel', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 5, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-04' },
        ]
        tasks.value = []
        goalTreeData.value = {
          tree: [goalTreeNode({ id: 'G-1', linked_keeper_names: ['polisher', 'rondo'] })],
          summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1 }),
        }

        render(html`<${Work} />`)
        expandGoalCard(screen.getByTestId('goal-card'))

        const link = screen.getByTestId('goal-dossier')
          .querySelector<HTMLButtonElement>('[data-goal-detail-keeper="rondo"]')
        expect(link).not.toBeNull()
        fireEvent.click(link!)

        expect(navigateMock).toHaveBeenCalledWith(
          'monitoring',
          { section: 'agents', view: 'keepers', keeper: 'rondo' },
        )
      })

      it('expands the goal detail timeline events behind the toggle', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 5, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-04' },
        ]
        tasks.value = []
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              title: 'Goal One',
              priority: 5,
              phase: 'executing',
              timeline_events: [{
                ts: '2026-01-04T10:00:00Z',
                kind: 'goal_owner',
                lane: 'goal',
                title: 'Goal Owner',
                summary: 'owner: <unassigned> -> dancer by operator',
                severity: 'ok',
              }],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1 }),
        }

        render(html`<${Work} />`)

        const goalCard = screen.getByTestId('goal-card')
        expandGoalCard(goalCard)

        const dossier = within(goalCard).getByTestId('goal-dossier')
        const toggle = dossier.querySelector('[data-goal-dossier-timeline-toggle="G-1"]')
        expect(toggle).not.toBeNull()
        expect(toggle).toHaveAttribute('aria-expanded', 'false')
        expect(toggle!.textContent).toContain('기록 1건 보기')
        expect(dossier.querySelectorAll('[data-goal-dossier-timeline-event]')).toHaveLength(0)

        fireEvent.click(toggle!)

        expect(toggle).toHaveAttribute('aria-expanded', 'true')
        const rows = dossier.querySelectorAll('[data-goal-dossier-timeline-event]')
        expect(rows).toHaveLength(1)
        expect(rows[0]!.textContent).toContain('goal_owner')
        expect(rows[0]!.textContent).toContain('2026-01-04T10:00:00Z')
        expect(rows[0]!.textContent).toContain('owner: <unassigned> -> dancer by operator')
        // The count hook stays put while the list opens.
        expect(dossier).toHaveAttribute('data-goal-dossier-timeline-count', '1')
      })

      it('folds created, last changed and last active into one relative-time activity row', () => {
        const now = Date.now()
        const createdAt = new Date(now - 3 * 24 * 60 * 60 * 1000)
        const updatedAt = new Date(now - 2 * 60 * 60 * 1000)
        const lastActivityAt = new Date(now - 5 * 60 * 1000)
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 5, phase: 'executing', created_at: createdAt.toISOString(), updated_at: updatedAt.toISOString() },
        ]
        tasks.value = []
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              created_at: createdAt.toISOString(),
              updated_at: updatedAt.toISOString(),
              last_activity_at: lastActivityAt.toISOString(),
              // The live maximum (#29472). It is not printed anywhere.
              stagnation_seconds: 2154748,
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1 }),
        }

        render(html`<${Work} />`)
        const goalCard = screen.getByTestId('goal-card')
        expandGoalCard(goalCard)

        const dossier = within(goalCard).getByTestId('goal-dossier')
        const activity = dossier.querySelector('[data-goal-detail-row="activity"]')
        expect(activity).not.toBeNull()
        // Three instants on the one row, each a <time> carrying the absolute
        // instant while the row text reads relative.
        expect(Array.from(activity!.querySelectorAll('[data-goal-detail-when]'), el => el.getAttribute('data-goal-detail-when')))
          .toEqual(['created', 'updated', 'last-activity'])
        expect(Array.from(activity!.querySelectorAll('time'), el => el.getAttribute('datetime')))
          .toEqual([createdAt.toISOString(), updatedAt.toISOString(), lastActivityAt.toISOString()])
        const text = activity!.textContent ?? ''
        expect(text).toContain('만든 날 3일 전')
        expect(text).toContain('마지막 변경 2시간 전')
        expect(text).toContain('마지막 활동 5분 전')
        expect(text).not.toContain(createdAt.toISOString())
        // No raw-seconds stagnation figure, and no separate created/changed rows.
        expect(text).not.toContain('초째')
        expect(text).not.toContain('2154748')
        expect(dossier.querySelector('[data-goal-detail-row="created"]')).toBeNull()
        expect(dossier.querySelector('[data-goal-detail-row="updated"]')).toBeNull()
        expect(dossier.querySelectorAll('[data-goal-detail-row]')).toHaveLength(2)
        expect(dossier.querySelector('[data-goal-detail-row="candle"]')).not.toBeNull()
      })

      it('renders tree-only Goal Store goals in the list without an execution goal mirror', () => {
        goals.value = []
        tasks.value = []
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-tree',
              title: 'Tree Only Goal',
              priority: 4,
              phase: 'blocked',
              tasks: [goalTreeTask({ id: 'T-tree', goal_id: 'G-tree', status: 'todo' })],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1, total_tasks: 1 }),
        }

        render(html`<${Work} />`)

        const goalCard = screen.getByTestId('goal-card')
        expect(goalCard).toHaveAttribute('data-goal-id', 'G-tree')
        expect(goalCard.textContent).toContain('Tree Only Goal')
        expandGoalCard(goalCard)

        const dossier = within(goalCard).getByTestId('goal-dossier')
        expect(dossier).toHaveAttribute('data-goal-dossier', 'G-tree')
        expect(screen.getByTestId('work-backlog').textContent).toContain('Tree Only Goal')
      })
      it('preserves blocked and unknown Goal Store task statuses instead of remapping them', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [
                goalTreeTask({ id: 'T-blocked', goal_id: 'G-1', status: 'blocked' }),
                goalTreeTask({ id: 'T-unknown', goal_id: 'G-1', status: 'weird_status' }),
              ],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, total_tasks: 2 }),
        }

        render(html`<${Work} />`)

        expect(screen.getByTestId('kpi-wip')).toHaveTextContent('0')
        expect(screen.getByTestId('kpi-backlog')).toHaveTextContent('0')
        const goalCard = screen.getByTestId('goal-card')
        expect(within(goalCard).getByText('차단됨')).toBeTruthy()
        expect(within(goalCard).getByText('확인 필요')).toBeTruthy()
        expect(goalCard.textContent).toContain('unknown status: weird_status')
      })

      it('falls back to Goal Store fields when execution fields are empty strings', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [goalTreeTask({ id: 'T-shared', goal_id: 'G-1', status: 'todo', title: 'Goal store title' })],
            }),
          ],
          summary: emptyGoalTreeSummary({ total_goals: 1, active_goals: 1, total_tasks: 1 }),
        }
        tasks.value = [
          { id: 'T-shared', title: '', goal_id: null, status: 'in_progress', assignee: '' },
        ]

        render(html`<${Work} />`)
        fireEvent.click(screen.getByTestId('work-view-list'))

        const goalCard = screen.getByTestId('goal-card')
        if (!goalCard.querySelector('[data-job-id="T-shared"]')) {
          fireEvent.click(within(goalCard).getByRole('button'))
        }
        const row = goalCard.querySelector('[data-job-id="T-shared"]')
        expect(row?.textContent).toContain('Goal store title')
      })
    })
  })
})
