import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

const routeSignal = signal({
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
    it('renders KPI counts from goals and tasks', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-2', horizon: 'mid', title: 'Goal Two', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Job one', goal_id: 'G-1', status: 'done' },
        { id: 'J-2', title: 'Job two', goal_id: 'G-1', status: 'in_progress' },
        { id: 'J-3', title: 'Job three', goal_id: 'G-2', status: 'cancelled' },
      ]

      render(html`<${Work} />`)

      expect(screen.getByTestId('kpi-goals').textContent).toBe('2')
      expect(screen.getByTestId('kpi-jobs').textContent).toBe('3')
      expect(screen.getByTestId('kpi-done').textContent).toBe('1')
      expect(screen.getByTestId('kpi-blocked').textContent).toBe('1')
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
  })
})
