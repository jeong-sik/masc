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
import type { Goal } from '../types'
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
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-2', horizon: 'mid', title: 'Goal Two', priority: 1, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
      expect(screen.getByText(/백로그에서 claim/).textContent).toContain('claim')
      expect(screen.getAllByTestId('work-horizon').map(section => section.getAttribute('data-horizon'))).toEqual(['short', 'mid'])
    })

    it('themes the verify KPI and horizon count to match the prototype', () => {
      // Prototype work.jsx:180 — 검증 대기 KPI uses the volt accent (not warn).
      // Prototype work.jsx:206 — horizon count renders the number only.
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-2', horizon: 'short', title: 'Goal Two', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Awaiting', goal_id: 'G-1', status: 'awaiting_verification' },
      ]

      const { container } = render(html`<${Work} />`)

      const verifyKpi = screen.getByTestId('kpi-verify')
      expect(verifyKpi.classList.contains('volt')).toBe(true)
      expect(verifyKpi.classList.contains('warn')).toBe(false)

      const hzCount = container.querySelector('[data-horizon="short"] .wk-hz-n')
      expect(hzCount?.textContent?.trim()).toBe('2')
    })

    it('renders the awaiting_verification task state with the volt verify class', () => {
      // Prototype v2.css:835/848 — verify state is volt-strong (folded into .review).
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Awaiting verify', goal_id: 'G-1', status: 'awaiting_verification' },
      ]

      const { container } = render(html`<${Work} />`)
      fireEvent.click(screen.getByTestId('goal-card').querySelector('.wk-goal-h')!)

      const state = container.querySelector('[data-job-id="J-1"] .wk-task-state')
      expect(state?.classList.contains('review')).toBe(true)
      expect(state?.textContent).toContain('검증 대기')
    })

    it('renders the reference new-goal placeholder button', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]

      render(html`<${Work} />`)

      const button = screen.getByTestId('work-new-goal')
      expect(button.textContent).toContain('새 목표')
      expect(button).toBeDisabled()
    })

    it('renders a collapsed goal card per goal and expands on click', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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

    it('keeps goals with unexpected wire horizons visible in the fallback bucket', () => {
      goals.value = [
        { id: 'G-X', horizon: 'quarterly' as unknown as Goal['horizon'], title: 'Unexpected horizon goal', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      render(html`<${Work} />`)

      const horizon = screen.getByTestId('work-horizon')
      expect(horizon.getAttribute('data-horizon')).toBe('long')
      expect(screen.getByText('Unexpected horizon goal')).toBeTruthy()
      expect(horizon.textContent).toContain('장기')
    })

    it('renders job rows with state, id, title, and blocker note', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
      expect(screen.getByText('Blocked job')).toBeTruthy()
      expect(screen.getByTestId('job-blocker').textContent).toContain('dependency missing')
      expect(screen.queryByTestId('job-detail')).toBeNull()
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

    it('surfaces claimable backlog tasks in a dedicated backlog section', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
      expect(backlog.textContent).toContain('클\uB808\uC784 가능 백로그')
      expect(backlog.textContent).toContain('2')
      expect(backlog.querySelectorAll('.wk-task-claim').length).toBe(2)
      expect(screen.getByText('Orphan job')).toBeTruthy()
      expect(screen.getByText('Linked job')).toBeTruthy()
    })

    it('expands inline task detail for gate evidence and handoff context', () => {
      goals.value = [
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
        { id: 'G-1', horizon: 'short', title: 'Active goal', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-2', horizon: 'mid', title: 'Completed goal', priority: 3, status: 'completed', phase: 'done', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = []

      render(html`<${Work} />`)

      const cards = screen.getAllByTestId('goal-card')
      // Prototype data.jsx:355 GOAL_STATUS active label is '진행' (not '진행 중').
      expect(cards[0]?.textContent).toContain('진행')
      expect(cards[1]?.textContent).toContain('완료')
    })

    // Pixel-match: .wk-gstatus carries a semantic status variant class so the
    // prototype's ok/warn/bad/volt color rules (work-v2.css) apply.
    it('applies the semantic status variant class to the goal status chip', () => {
      goals.value = [
        { id: 'G-ok', horizon: 'short', title: 'Active', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-warn', horizon: 'short', title: 'At risk', priority: 2, status: 'at_risk', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-bad', horizon: 'short', title: 'Blocked', priority: 2, status: 'blocked', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
        { id: 'G-volt', horizon: 'short', title: 'Verifying', priority: 2, status: 'verifying', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
        { id: 'G-x', horizon: 'short', title: 'Mystery', priority: 2, status: 'something_new', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
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
          horizon: 'short',
          title: 'Goal needing approval',
          priority: 9,
          status: 'verifying',
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
        { id: 'G-1', horizon: 'short', title: 'Goal One', priority: 2, status: 'active', phase: 'executing', created_at: '2026-01-01', updated_at: '2026-01-01' },
      ]
      tasks.value = [
        { id: 'J-1', title: 'Selectable job', goal_id: 'G-1', status: 'todo' },
      ]

      render(html`<${Work} />`)

      expect(screen.queryByTestId('work-task-detail')).toBeNull()
      expect(screen.queryByTestId('job-detail')).toBeNull()
    })
  })
})
