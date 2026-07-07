import { html } from 'htm/preact'
import { signal } from '@preact/signals'
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
const callMcpToolMock = vi.hoisted(() => vi.fn<() => Promise<string>>())

vi.mock('../api/mcp', () => ({
  callMcpTool: callMcpToolMock,
}))

vi.mock('../router', () => ({
  get route() { return routeSignal },
  navigate: navigateMock,
}))

vi.mock('../store', () => ({
  goals: signal([]),
  tasks: signal([]),
  keepers: signal([]),
  refreshGoals: vi.fn().mockResolvedValue(undefined),
}))

vi.mock('./board/board-moderation-surface', () => ({
  BoardModerationSurface: () => html`<div data-testid="board-moderation-surface">Moderation</div>`,
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

vi.mock('./verification-requests-panel', () => ({
  VerificationRequestsPanel: () => html`<div data-testid="verification-panel">Verification</div>`,
}))

vi.mock('./repository-management', () => ({
  RepositoryManagement: () => html`<div data-testid="repository-panel">Repositories</div>`,
}))

import { goals, keepers, tasks } from '../store'
import { goalTreeData } from '../goal-tree-state'
import { selectedTask } from './goals/task-detail-selection'
import { showGoalCreate } from './goals/goal-create-state'
import { Work } from './work'
import type { GoalTreeNode, GoalTreeTask, GoalTreeSummary } from '../types'

const GOAL_FIXTURE_OK_COLOR = '#4ade80'

function emptyGoalTreeSummary(overrides: Partial<GoalTreeSummary> = {}): GoalTreeSummary {
  return {
    total_goals: 0,
    active_goals: 0,
    on_track_goals: 0,
    done_goals: 0,
    paused_goals: 0,
    at_risk_goals: 0,
    blocked_goals: 0,
    total_tasks: 0,
    done_tasks: 0,
    pending_approvals: 0,
    infra_risk_count: 0,
    overall_convergence: 0,
    overall_convergence_pct: 0,
    ...overrides,
  }
}

function goalTreeTask(overrides: Partial<GoalTreeTask> = {}): GoalTreeTask {
  return {
    id: 'task-tree',
    title: 'Tree task',
    status: 'completed',
    status_color: GOAL_FIXTURE_OK_COLOR,
    priority: 2,
    assignee: null,
    goal_id: 'G-1',
    linkage_source: 'explicit',
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
    status: 'active',
    status_color: GOAL_FIXTURE_OK_COLOR,
    phase,
    phase_color: GOAL_FIXTURE_OK_COLOR,
    goal_fsm: {
      state: phase,
      source: 'goal.phase',
      next_actions: [],
      activity_observation: 'goal_metadata',
      stagnation_status: 'recent',
    },
    health: 'on_track',
    health_color: GOAL_FIXTURE_OK_COLOR,
    badges: [],
    status_reason: '',
    priority: 1,
    metric: null,
    target_value: null,
    require_completion_approval: false,
    due_date: null,
    parent_goal_id: null,
    convergence: 0,
    convergence_pct: 0,
    attainment: {
      state: 'unmeasured',
      basis: 'unmeasured',
      metric: null,
      metric_evaluation: 'absent',
      target_value: null,
      target_parse_status: 'absent',
      unit: 'unknown',
      observed_value: null,
      target_numeric: null,
      attainment_pct: null,
      task_done_count: 0,
      task_count: 0,
      note: '',
    },
    tasks: [],
    task_count: 0,
    task_done_count: 0,
    verification_summary: {
      effective_policy: null,
      open_request: null,
      latest_request: null,
      approve_count: 0,
      reject_count: 0,
      remaining_possible: 0,
    },
    pending_verification_count: 0,
    timeline_events: [],
    children: [],
    child_count: 0,
    last_activity_at: '2026-01-02',
    stagnation_seconds: 0,
    activity_observation: 'goal_metadata',
    stagnation_status: 'recent',
    linked_keeper_names: [],
    pending_approval_count: 0,
    infra_risk_count: 0,
    linkage_source: 'explicit',
    linkage_warning_count: 0,
    blocking_source: 'none',
    blocking_reason: '',
    created_at: '2026-01-01',
    updated_at: '2026-01-02',
    ...overrides,
  }
}

describe('Work', () => {
  afterEach(() => {
    cleanup()
    navigateMock.mockClear()
    selectedTask.value = null
    showGoalCreate.value = false
    goalTreeData.value = null
  })

  beforeEach(() => {
    goals.value = []
    tasks.value = []
    keepers.value = []
    goalTreeData.value = null
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

  it('renders the board moderation surface for the workspace moderation section', () => {
    routeSignal.value = {
      tab: 'workspace',
      params: { section: 'moderation' },
      postId: null,
    }

    render(html`<${Work} />`)

    expect(screen.getByTestId('board-moderation-surface')).toBeTruthy()
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

    it('renders the reference 5 KPI counts from goals and tasks', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-2', title: 'Goal Two', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
      expect(screen.getByText(/미배정 task는 claim/).textContent).toContain('claim')
      expect(screen.getByTestId('work-goal-list')).toBeTruthy()
    })

    it('avoids repeating Task scope labels across the KPI row and kanban columns', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'T-todo', title: 'Todo item', goal_id: 'G-1', status: 'todo' },
        { id: 'T-claim', title: 'Claimed item', goal_id: 'G-1', status: 'claimed', assignee: 'keeper-x' },
      ]

      render(html`<${Work} />`)

      const kpis = screen.getByTestId('work-kpis')
      expect(kpis.textContent).toContain('활성 목표')
      expect(kpis.textContent).toContain('전체 작업')
      expect(kpis.textContent).not.toContain('목표 TASK')
      expect(kpis.textContent).not.toContain('Task')
      expect(kpis.textContent).not.toContain('TASK')

      fireEvent.click(screen.getByTestId('work-view-kanban'))

      const todoCol = screen.getByTestId('kanban-col-todo')
      const claimedCol = screen.getByTestId('kanban-col-claimed')
      expect(todoCol.querySelector('.wk-kcol-title')?.textContent).toBe('미배정')
      expect(todoCol.textContent).not.toContain('TASK')
      expect(claimedCol.querySelector('.wk-kcol-title')?.textContent).toBe('클레임됨')
      expect(claimedCol.textContent).not.toContain('TASK')

      fireEvent.click(screen.getByTestId('work-view-list'))
      expect(screen.getByTestId('work-view-list').classList.contains('on')).toBe(true)
    })

    it('renders the new-goal button as enabled and opens the form on click', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
        { id: 'G-1', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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

    it('renders all goals in a flat list regardless of any legacy horizon field', () => {
      goals.value = [
        { id: 'G-X', title: 'Goal visible in flat list', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      render(html`<${Work} />`)

      expect(screen.getByTestId('work-goal-list')).toBeTruthy()
      expect(screen.getByText('Goal visible in flat list')).toBeTruthy()
    })

    it('renders job rows with state, id, title, and blocker note', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Blocked job', goal_id: 'G-1', status: 'cancelled', handoff_context: { summary: '', reason: 'dependency missing' } },
      ]

      const { container } = render(html`<${Work} />`)

      const card = container.querySelector('[data-goal-id="G-1"]')
      expect(card).toBeTruthy()
      fireEvent.click(card!.querySelector('.wk-goal-h')!)
      expect(card?.querySelector('.wk-jobs')).toBeTruthy()

      const row = screen.getByTestId('job-row')
      expect(row).toBeTruthy()
      expect(row.classList.contains('wk-task')).toBe(true)
      // Scope text search to the goal card — the WorkAside also surfaces this
      // task as a blocker, so screen.getByText() would find multiple matches.
      expect(within(card! as HTMLElement).getByText('Blocked job')).toBeTruthy()
      expect(screen.getByTestId('job-blocker').textContent).toContain('dependency missing')
      expect(screen.queryByTestId('job-detail')).toBeNull()
    })

    it('navigates to keeper workspace when keeper assignment is clicked', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
        { id: 'G-1', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
      expect(backlog.textContent).toContain('미배정 Task')
      expect(backlog.textContent).toContain('2')
      expect(backlog.querySelectorAll('.wk-task-claim').length).toBe(2)
      expect(screen.getByText('Orphan job')).toBeTruthy()
      expect(screen.getByText('Linked job')).toBeTruthy()
    })

    it('expands inline task detail for gate evidence and handoff context', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        {
          id: 'J-1',
          title: 'Detail job',
          goal_id: 'G-1',
          status: 'todo',
          assignee: 'dev',
          gate: {
            done: {
              status: 'ready',
              checks: [{ evidence: 'unit tests pass', outcome: 'satisfied', detail: 'ci green' }],
            },
          },
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
      expect(detail?.textContent).toContain('unit tests pass')
      expect(detail?.textContent).toContain('Handoff summary text')
      expect(detail?.textContent).toContain('Deploy to staging')
    })

    it('renders all defined gate evaluations including verify_to_review', () => {
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        {
          id: 'J-1',
          title: 'Gated job',
          goal_id: 'G-1',
          status: 'todo',
          gate: {
            done: { status: 'ready', checks: [{ evidence: 'done check', outcome: 'satisfied', detail: 'done detail' }] },
            inspect_to_implement: { status: 'blocked', checks: [{ evidence: 'inspect check', outcome: 'failed', detail: 'inspect detail' }] },
            verify_to_review: { status: 'inconclusive', checks: [{ evidence: 'verify check', outcome: 'missing', detail: 'verify detail' }] },
          },
        },
      ]

      const { container } = render(html`<${Work} />`)

      fireEvent.click(screen.getByTestId('goal-card').querySelector('.wk-goal-h')!)
      fireEvent.click(container.querySelector('[data-job-id="J-1"] .wk-task-main')!)

      const detail = screen.getByTestId('job-row').querySelector('.wk-task-detail')
      expect(detail?.textContent).toContain('done gate')
      expect(detail?.textContent).toContain('inspect gate')
      expect(detail?.textContent).toContain('verify gate')
      expect(detail?.textContent).toContain('verify check')
    })

    it('maps known goal status IDs to Korean labels', () => {
      goals.value = [
        { id: 'G-1', title: 'Active goal', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-2', title: 'Completed goal', priority: 3, status: 'completed', phase: 'done', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      render(html`<${Work} />`)

      const cards = screen.getAllByTestId('goal-card')
      expect(cards[0]?.textContent).toContain('진행 중')
      expect(cards[1]?.textContent).toContain('완료')
    })

    // Pixel-match: .wk-gstatus carries a semantic status variant class so the
    // prototype's ok/warn/bad/volt color rules (work-v2.css) apply.
    it('applies the semantic status variant class to the goal status chip', () => {
      goals.value = [
        { id: 'G-ok', title: 'Active', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-warn', title: 'At risk', priority: 2, status: 'at_risk', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-bad', title: 'Blocked', priority: 2, status: 'blocked', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-volt', title: 'Verifying', priority: 2, status: 'verifying', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      const { container } = render(html`<${Work} />`)

      const chipFor = (id: string) =>
        container.querySelector(`[data-goal-id="${id}"] .wk-gstatus`)
      expect(chipFor('G-ok')?.classList.contains('ok')).toBe(true)
      expect(chipFor('G-warn')?.classList.contains('warn')).toBe(true)
      expect(chipFor('G-bad')?.classList.contains('bad')).toBe(true)
      expect(chipFor('G-volt')?.classList.contains('volt')).toBe(true)
    })

    it('falls back to the ok status variant for unknown goal statuses', () => {
      goals.value = [
        { id: 'G-x', title: 'Mystery', priority: 2, status: 'something_new', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      const { container } = render(html`<${Work} />`)

      const chip = container.querySelector('[data-goal-id="G-x"] .wk-gstatus')
      expect(chip?.classList.contains('ok')).toBe(true)
      // unknown status text is passed through verbatim
      expect(chip?.textContent).toContain('something_new')
    })

    // Pixel-match: the completion-approval pill (.wk-approval, volt theme) and
    // verifier chips (.wk-vchip, mono) render when a goal requires approval.
    it('renders the completion-approval pill and verifier chips', () => {
      goals.value = [
        {
          id: 'G-1',
          title: 'Goal needing approval',
          priority: 9,
          // 'active' status does not auto-expand on mount (work.ts:403 only
          // auto-expands priority===1 / at_risk / verifying / blocked). A
          // 'verifying' goal would start open, so the click below would CLOSE
          // it and drop the .wk-vchip chips. approval pill is status-independent
          // (driven by require_completion_approval), so it still renders.
          status: 'active',
          phase: 'executing',
          require_completion_approval: true,
          verifier_policy: {
            inherit_mode: 'replace',
            principals: [{ id: 'operator' }, { id: 'sangsu' }],
          },
          created_at: '2026-01-01',
          updated_at: '2026-01-01',
        },
      ]
      tasks.value = []

      const { container } = render(html`<${Work} />`)

      const approval = container.querySelector('[data-goal-id="G-1"] .wk-approval')
      expect(approval).toBeTruthy()
      expect(approval?.textContent).toContain('완료 승인')

      // open the card to expose the verifier policy chips
      fireEvent.click(container.querySelector('[data-goal-id="G-1"] .wk-goal-h')!)
      const chips = Array.from(container.querySelectorAll('[data-goal-id="G-1"] .wk-vchip'))
      expect(chips.map(c => c.textContent)).toEqual(['operator', 'sangsu'])
      expect(chips.every(c => c.classList.contains('mono'))).toBe(true)
    })

    it('does not render a task dossier sidebar for route-selected tasks', () => {
      routeSignal.value = {
        tab: 'workspace',
        params: { section: 'work', task: 'J-1' },
        postId: null,
      }
      goals.value = [
        { id: 'G-1', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
        const { showGoalCreate } = await import('./goals/goal-create-state')
        const { resetGoalCreateFormLocal } = await import('./goals/goal-create-form')
        showGoalCreate.value = false
        resetGoalCreateFormLocal()
      })

      it('calls masc_goal_upsert with title and priority when form is submitted', async () => {
        callMcpToolMock.mockResolvedValue('ok')

        goals.value = []
        tasks.value = []

        render(html`<${Work} />`)

        // Open the form
        fireEvent.click(screen.getByTestId('work-new-goal'))
        expect(screen.getByTestId('goal-create-panel')).toBeTruthy()

        // Fill in the title
        const titleInput = screen.getByTestId('goal-create-title-input')
        fireEvent.input(titleInput, { target: { value: 'SLO 400ms 회복' } })

        // Submit
        fireEvent.click(screen.getByTestId('goal-create-submit'))

        // Wait for async createGoal to resolve
        await new Promise(resolve => setTimeout(resolve, 0))

        expect(callMcpToolMock).toHaveBeenCalledWith('masc_goal_upsert', expect.objectContaining({
          title: 'SLO 400ms 회복',
          priority: expect.any(Number),
        }))
        // No horizon field: extract args from the first call via toHaveBeenCalledWith
        const rawCalls = callMcpToolMock.mock.calls as unknown as [string, Record<string, unknown>][]
        const callArgs = rawCalls[0]?.[1] ?? {}
        expect(callArgs).not.toHaveProperty('horizon')
        expect(callArgs).not.toHaveProperty('lead_keeper')
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
          { id: 'G-1', title: 'Active Goal', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
          { id: 'G-1', title: 'Normal Goal', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        // "지금 상황" calm state
        expect(aside.querySelector('[data-testid="wka-flagged-calm"]')?.textContent).toContain('주의 목표 없음')
        // "해야 할 일" calm state
        expect(aside.querySelector('[data-testid="wka-todo-calm"]')?.textContent).toContain('대기 중인 작업 없음')
        // "최근 한 일" calm state
        expect(aside.querySelector('[data-testid="wka-recent-calm"]')?.textContent).toContain('완료된 task 없음')
      })

      it('flags goals whose phase is not executing (blocked, paused, awaiting_verification, awaiting_approval)', () => {
        goals.value = [
          { id: 'G-ok', title: 'Executing Goal', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
          { id: 'G-bl', title: 'Blocked Goal', priority: 2, status: 'active', phase: 'blocked', created_at: '2026-01-01', updated_at: '2026-01-01' },
          { id: 'G-pa', title: 'Paused Goal', priority: 3, status: 'active', phase: 'paused', created_at: '2026-01-01', updated_at: '2026-01-01' },
          { id: 'G-vf', title: 'Verify Goal', priority: 4, status: 'active', phase: 'awaiting_verification', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        const flaggedItems = aside.querySelectorAll('[data-testid="wka-flagged-item"]')
        // G-ok (executing) must NOT appear; the other 3 must appear
        expect(flaggedItems.length).toBe(3)
        const titles = Array.from(flaggedItems).map(el => el.textContent ?? '')
        expect(titles.some(t => t.includes('Blocked Goal'))).toBe(true)
        expect(titles.some(t => t.includes('Paused Goal'))).toBe(true)
        expect(titles.some(t => t.includes('Verify Goal'))).toBe(true)
        expect(titles.some(t => t.includes('Executing Goal'))).toBe(false)
        // No calm state should be shown
        expect(aside.querySelector('[data-testid="wka-flagged-calm"]')).toBeNull()
      })

      it('surfaces approval items for goals with require_completion_approval=true and phase=awaiting_approval', () => {
        goals.value = [
          {
            id: 'G-ap',
            title: 'Approval Goal',
            priority: 1,
            status: 'active',
            phase: 'awaiting_approval',
            require_completion_approval: true,
            verifier_policy: {
              inherit_mode: 'replace' as const,
              principals: [{ id: 'lead-keeper' }],
            },
            created_at: '2026-01-01',
            updated_at: '2026-01-01',
          },
          // require_completion_approval=true but NOT awaiting_approval phase → no approval item
          {
            id: 'G-ex',
            title: 'Executing With Approval Policy',
            priority: 2,
            status: 'active',
            phase: 'executing',
            require_completion_approval: true,
            created_at: '2026-01-01',
            updated_at: '2026-01-01',
          },
        ]
        tasks.value = []

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        const approvalItems = aside.querySelectorAll('[data-testid="wka-approval-item"]')
        expect(approvalItems.length).toBe(1)
        expect(approvalItems[0]?.textContent).toContain('Approval Goal')
        expect(approvalItems[0]?.textContent).toContain('lead-keeper')
      })

      it('surfaces verify tasks (awaiting_verification status) with unsatisfied gate count', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          {
            id: 'J-vf',
            title: 'Verify Me',
            goal_id: 'G-1',
            status: 'awaiting_verification',
            gate: {
              done: { status: 'blocked', checks: [], reasons: ['ci failing'] },
              inspect_to_implement: { status: 'ready', checks: [], reasons: [] },
            },
          },
        ]

        render(html`<${Work} />`)

        const aside = screen.getByTestId('work-aside')
        const verifyItems = aside.querySelectorAll('[data-testid="wka-verify-item"]')
        expect(verifyItems.length).toBe(1)
        expect(verifyItems[0]?.textContent).toContain('Verify Me')
        // 1 unsatisfied gate (done=blocked, inspect=ready → 1 open)
        expect(verifyItems[0]?.textContent).toContain('1 미충족')
      })

      it('surfaces tasks with a blocker note (cancelled with handoff_context.reason)', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
        expect(blockerItems[0]?.textContent).toContain('Blocked Task')
        expect(blockerItems[0]?.textContent).toContain('dependency unavailable')
      })

      it('surfaces claimable backlog tasks as a single aggregate claim button', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
        expect(backlogItem?.textContent).toContain('미배정 task 2건')
      })

      it('surfaces done tasks in the 최근 한 일 section', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
          { id: 'G-tricky', title: 'Not blocked — just named oddly', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = [
          { id: 'J-1', title: 'Todo task', goal_id: 'G-1', status: 'todo' },
          { id: 'J-2', title: 'In progress', goal_id: 'G-1', status: 'in_progress' },
          { id: 'J-3', title: 'Done task', goal_id: 'G-1', status: 'done' },
          // Cancelled tasks must not appear in kanban
          { id: 'J-4', title: 'Cancelled task', goal_id: 'G-1', status: 'cancelled' },
        ]

        render(html`<${Work} />`)

        // Initially in list view
        expect(screen.queryByTestId('work-kanban')).toBeNull()
        expect(screen.getByTestId('work-goal-list')).toBeTruthy()

        // Switch to kanban
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        // Kanban board present; list view gone
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

        // Tasks appear in the correct columns (by data-testid selector)
        const todoCol = screen.getByTestId('kanban-col-todo')
        const wipCol  = screen.getByTestId('kanban-col-in_progress')
        const doneCol = screen.getByTestId('kanban-col-done')
        expect(todoCol.textContent).toContain('Todo task')
        expect(wipCol.textContent).toContain('In progress')
        expect(doneCol.textContent).toContain('Done task')

        // Cancelled task must be absent from all columns
        expect(board.textContent).not.toContain('Cancelled task')
      })

      it('switches back to list view on clicking the 리스트 button', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        // One task per non-cancelled status
        tasks.value = [
          { id: 'T-todo',   title: 'Todo item',   goal_id: 'G-1', status: 'todo' },
          { id: 'T-claim',  title: 'Claimed item', goal_id: 'G-1', status: 'claimed', assignee: 'keeper-x' },
          { id: 'T-wip',    title: 'WIP item',    goal_id: 'G-1', status: 'in_progress', assignee: 'keeper-y' },
          { id: 'T-verify', title: 'Verify item', goal_id: 'G-1', status: 'awaiting_verification', assignee: 'keeper-z' },
          { id: 'T-done',   title: 'Done item',   goal_id: 'G-1', status: 'done', assignee: 'keeper-w' },
        ]

        render(html`<${Work} />`)
        fireEvent.click(screen.getByTestId('work-view-kanban'))

        const board = screen.getByTestId('work-kanban')
        const cards = board.querySelectorAll('[data-testid="kanban-card"]')
        // All 5 non-cancelled tasks present
        expect(cards.length).toBe(5)

        // Each card sits inside the correct column
        const colFor = (status: string) => board.querySelector(`[data-testid="kanban-col-${status}"]`)
        expect(colFor('todo')?.querySelector('[data-kanban-task-id="T-todo"]')).toBeTruthy()
        expect(colFor('claimed')?.querySelector('[data-kanban-task-id="T-claim"]')).toBeTruthy()
        expect(colFor('in_progress')?.querySelector('[data-kanban-task-id="T-wip"]')).toBeTruthy()
        expect(colFor('awaiting_verification')?.querySelector('[data-kanban-task-id="T-verify"]')).toBeTruthy()
        expect(colFor('done')?.querySelector('[data-kanban-task-id="T-done"]')).toBeTruthy()
      })

      it('renders an owning-goal jump button on kanban cards that returns to the list view', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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

      it('includes recursive goal tree tasks in KPIs and kanban, normalizing completed to done', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
          { id: 'G-child', title: 'Child Goal', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        tasks.value = []
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [
                goalTreeTask({ id: 'T-root', title: 'Root completed task', goal_id: 'G-1', status: 'completed' }),
              ],
              children: [
                goalTreeNode({
                  id: 'G-child',
                  title: 'Child Goal',
                  tasks: [
                    goalTreeTask({ id: 'T-child', title: 'Child completed task', goal_id: 'G-child', status: 'completed' }),
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

      it('keeps unscoped execution tasks visible in kanban instead of requiring a goal_id', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        ]
        goalTreeData.value = {
          tree: [
            goalTreeNode({
              id: 'G-1',
              tasks: [
                goalTreeTask({ id: 'T-goal', title: 'Goal store task', goal_id: 'G-1', status: 'completed' }),
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
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
          { id: 'G-1', title: 'Target Goal', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
              tasks: [goalTreeTask({ id: 'T-1', goal_id: 'G-1', status: 'completed' })],
              children: [
                goalTreeNode({
                  id: 'G-1',
                  tasks: [goalTreeTask({ id: 'T-2', goal_id: 'G-1', status: 'completed' })],
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

      it('maps unknown Goal Store task statuses to a fallback instead of dropping them', () => {
        goals.value = []
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

        expect(screen.getByTestId('kpi-wip')).toHaveTextContent('1')
        expect(screen.getByTestId('kpi-backlog')).toHaveTextContent('1')
      })

      it('falls back to Goal Store fields when execution fields are empty strings', () => {
        goals.value = [
          { id: 'G-1', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
