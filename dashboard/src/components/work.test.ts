import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
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

vi.mock('../router', () => ({
  get route() { return routeSignal },
  navigate: navigateMock,
}))

vi.mock('../store', () => ({
  goals: signal([]),
  tasks: signal([]),
  keepers: signal([]),
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
import { Work } from './work'

describe('Work', () => {
  afterEach(() => {
    cleanup()
    navigateMock.mockClear()
  })

  beforeEach(() => {
    goals.value = []
    tasks.value = []
    keepers.value = []
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

    it('renders KPI counts from goals and tasks', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-2', horizon: 'mid', title: 'Goal Two', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Job one', goal_id: 'G-1', status: 'done' },
        { id: 'J-2', title: 'Job two', goal_id: 'G-1', status: 'in_progress' },
        { id: 'J-3', title: 'Job three', goal_id: 'G-2', status: 'cancelled' },
        { id: 'J-4', title: 'Review job', goal_id: 'G-2', status: 'awaiting_verification' },
        { id: 'J-5', title: 'Claimable job', goal_id: 'G-2', status: 'todo' },
      ]

      render(html`<${Work} />`)

      expect(screen.getByTestId('kpi-goals').textContent).toBe('2')
      expect(screen.getByTestId('kpi-jobs').textContent).toBe('5')
      expect(screen.getByTestId('kpi-wip').textContent).toBe('1')
      expect(screen.getByTestId('kpi-review').textContent).toBe('1')
      expect(screen.getByTestId('kpi-done').textContent).toBe('1')
      expect(screen.getByTestId('kpi-backlog').textContent).toBe('1')
      expect(screen.getByText(/Goal → job → keeper/).textContent).toContain('누르면')
    })

    it('routes the header goal action to the backed planning surface', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]

      render(html`<${Work} />`)

      expect(screen.queryByText('＋ 새 목표')).toBeNull()
      fireEvent.click(screen.getByTestId('work-planning-link'))

      expect(navigateMock).toHaveBeenCalledWith('workspace', { section: 'planning' })
    })

    it('renders a collapsed goal card per goal and expands on click', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Job one', goal_id: 'G-1', status: 'todo' },
      ]

      render(html`<${Work} />`)

      const card = screen.getByTestId('goal-card')
      expect(card).toBeTruthy()
      expect(screen.queryByTestId('job-row')).toBeNull()

      fireEvent.click(card.querySelector('.wk-goal-h')!)

      expect(screen.getByTestId('job-row')).toBeTruthy()
      expect(screen.getByText('Job one')).toBeTruthy()
    })

    it('renders job rows with state, id, title, and blocker note', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Blocked job', goal_id: 'G-1', status: 'cancelled', handoff_context: { summary: '', reason: 'dependency missing' } },
      ]

      const { container } = render(html`<${Work} />`)

      // Cancelled tasks make this goal auto-expand and add the has-block border.
      const card = container.querySelector('[data-goal-id="G-1"]')
      expect(card).toBeTruthy()
      expect(card?.querySelector('.wk-jobs')).toBeTruthy()

      const row = screen.getByTestId('job-row')
      expect(row).toBeTruthy()
      expect(screen.getByText('Blocked job')).toBeTruthy()
      expect(screen.getByTestId('job-blocker').textContent).toContain('dependency missing')
    })

    it('navigates to keeper workspace when keeper assignment is clicked', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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

    it('surfaces tasks without a goal_id in a dedicated unassigned section', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Linked job', goal_id: 'G-1', status: 'todo' },
        { id: 'U-1', title: 'Orphan job', goal_id: null, status: 'in_progress' },
        { id: 'U-2', title: 'Another orphan', status: 'todo' },
      ]

      render(html`<${Work} />`)

      // KPI counts every task regardless of goal linkage.
      expect(screen.getByTestId('kpi-jobs').textContent).toBe('3')

      const unassigned = screen.getByTestId('work-unassigned')
      expect(unassigned).toBeTruthy()
      expect(unassigned.textContent).toContain('미배정 작업')
      expect(unassigned.textContent).toContain('(2)')
      expect(screen.getByTestId('work-unassigned-claimable').textContent).toBe('클레임 가능 1')
      expect(screen.getByTestId('kpi-backlog').textContent).toBe('2')
      expect(screen.getByText('Orphan job')).toBeTruthy()
      expect(screen.getByText('Another orphan')).toBeTruthy()
    })

    it('omits the unassigned section when every task has a goal', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Linked job', goal_id: 'G-1', status: 'todo' },
      ]

      render(html`<${Work} />`)

      expect(screen.queryByTestId('work-unassigned')).toBeNull()
    })

    it('auto-expands high-priority goals and goals with blocked jobs', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Normal goal', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-2', horizon: 'mid', title: 'High goal', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-3', horizon: 'long', title: 'Blocked goal', priority: 3, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Blocked job', goal_id: 'G-3', status: 'cancelled' },
      ]

      const { container } = render(html`<${Work} />`)

      // G-2 (high priority) and G-3 (blocked) should be expanded; G-1 should be collapsed.
      expect(container.querySelector('[data-goal-id="G-1"]')?.querySelector('.wk-jobs')).toBeNull()
      expect(container.querySelector('[data-goal-id="G-2"]')?.querySelector('.wk-jobs')).toBeTruthy()
      expect(container.querySelector('[data-goal-id="G-3"]')?.querySelector('.wk-jobs')).toBeTruthy()
    })

    it('deep-links a route-selected task into the read-only task dossier', () => {
      routeSignal.value = {
        tab: 'workspace',
        params: { section: 'work', task: 'J-1' },
        postId: null,
      }
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        {
          id: 'J-1',
          title: 'Verify dossier fields',
          goal_id: 'G-1',
          status: 'awaiting_verification',
          priority: 1,
          assignee: 'verifier',
          assignee_kind: 'keeper',
          description: 'Render contract and handoff from live task data.',
          contract: {
            strict: true,
            completion_contract: ['prove current behavior'],
            required_evidence: ['screenshot'],
          },
          handoff_context: {
            summary: 'Run the rendered smoke before closing.',
            next_step: 'open dashboard route',
            evidence_refs: ['trace-1'],
          },
          execution_links: {
            session_id: 'session-1',
            operation_id: 'op-1',
          },
        },
      ]

      render(html`<${Work} />`)

      const dossier = screen.getByTestId('work-task-detail')
      expect(dossier).toHaveAttribute('data-task-id', 'J-1')
      expect(dossier.textContent).toContain('Verify dossier fields')
      expect(dossier.textContent).toContain('G-1 · Goal One')
      expect(dossier.textContent).toContain('verifier · keeper')
      expect(dossier.textContent).toContain('prove current behavior')
      expect(dossier.textContent).toContain('screenshot')
      expect(dossier.textContent).toContain('Run the rendered smoke before closing.')
      expect(dossier.textContent).toContain('session-1')
      expect(screen.getByTestId('job-row')).toHaveClass('selected')
      expect(dossier.querySelector('[data-testid="work-task-claim"]')).toBeNull()
    })

    it('opens and closes the task dossier through route navigation', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Selectable job', goal_id: 'G-1', status: 'todo' },
      ]

      render(html`<${Work} />`)

      fireEvent.click(screen.getByTestId('job-detail'))
      expect(navigateMock).toHaveBeenCalledWith('workspace', { section: 'work', task: 'J-1' })

      routeSignal.value = {
        tab: 'workspace',
        params: { section: 'work', task: 'J-1' },
        postId: null,
      }
      cleanup()
      render(html`<${Work} />`)

      fireEvent.click(screen.getByLabelText('태스크 상세 닫기'))
      expect(navigateMock).toHaveBeenCalledWith('workspace', { section: 'work' })
    })

    it('routes awaiting-verification tasks to the backed verification panel', () => {
      routeSignal.value = {
        tab: 'workspace',
        params: { section: 'work', task: 'J-1' },
        postId: null,
      }
      tasks.value = [
        { id: 'J-1', title: 'Needs verification', status: 'awaiting_verification' },
      ]

      render(html`<${Work} />`)

      fireEvent.click(screen.getByText('검증 패널'))
      expect(navigateMock).toHaveBeenCalledWith('workspace', { section: 'verification', task: 'J-1' })
    })
  })
})
