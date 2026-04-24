import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const routeSignal = signal<{ tab: string; params: Record<string, string>; postId: string | null }>({
  tab: 'workspace',
  params: { section: 'planning' },
  postId: null,
})

vi.mock('../router', () => ({
  get route() { return routeSignal },
}))

const coordinationSignal = signal<unknown>(null)

vi.mock('../store', () => ({
  get coordinationFsmSnapshot() { return coordinationSignal },
}))

vi.mock('./goals', () => ({
  Planning: () => html`<div data-testid="planning">Planning</div>`,
}))
vi.mock('./goals/goal-tree', () => ({
  GoalTree: () => html`<div data-testid="goal-tree">GoalTree</div>`,
}))

import { PlanningPanel } from './planning-panel'

function setRoute(view?: string) {
  const params: Record<string, string> = { section: 'planning' }
  if (view) params.view = view
  routeSignal.value = { tab: 'workspace', params, postId: null }
}

describe('PlanningPanel', () => {
  beforeEach(() => {
    setRoute()
    coordinationSignal.value = null
  })
  afterEach(() => cleanup())

  it('renders GoalTree by default', () => {
    render(html`<${PlanningPanel} />`)
    expect(screen.getByTestId('goal-tree')).toBeTruthy()
    expect(screen.queryByTestId('planning')).toBeNull()
  })

  it('renders Planning when view=default', () => {
    setRoute('default')
    render(html`<${PlanningPanel} />`)
    expect(screen.getByTestId('planning')).toBeTruthy()
    expect(screen.queryByTestId('goal-tree')).toBeNull()
  })

  it('renders FilterChips with 2 options', () => {
    render(html`<${PlanningPanel} />`)
    expect(screen.getByText('Goal Manager')).toBeTruthy()
    expect(screen.getByText('Backlog')).toBeTruthy()
  })

  it('falls back to goal-tree for unknown view', () => {
    setRoute('nonexistent')
    render(html`<${PlanningPanel} />`)
    expect(screen.getByTestId('goal-tree')).toBeTruthy()
  })

  it('renders coordination health violations', () => {
    coordinationSignal.value = {
      mode: 'advisory',
      summary: {
        products: 1,
        violations: 1,
        evidence: 2,
        severity_counts: { info: 0, warn: 0, error: 1 },
      },
      evidence: [
        {
          source: 'telemetry',
          kind: 'task_completed',
          label: 'task completed',
          detail: 'success=true; duration_ms=42',
          refs: { goal_id: 'goal-1', task_ids: ['task-1'] },
        },
        {
          source: 'board',
          kind: 'post',
          label: 'Board post',
          detail: 'author=keeper',
          refs: { goal_id: 'goal-1' },
        },
      ],
      violations: [
        {
          severity: 'error',
          code: 'reward_without_evidence',
          message: 'Reward missing evidence',
          refs: { goal_id: 'goal-1', task_ids: ['task-1'] },
          evidence: [
            {
              source: 'telemetry',
              kind: 'task_completed',
              label: 'task completed',
              detail: 'success=true; duration_ms=42',
            },
          ],
        },
      ],
    }

    render(html`<${PlanningPanel} />`)

    expect(screen.getByText('Coordination Health')).toBeTruthy()
    expect(screen.getByText('reward_without_evidence')).toBeTruthy()
    expect(screen.getByText(/Reward missing evidence/)).toBeTruthy()
    expect(screen.getByText(/goal: goal-1/)).toBeTruthy()
    expect(screen.getAllByText('telemetry/task_completed').length).toBeGreaterThan(0)
    expect(screen.getByText('board/post')).toBeTruthy()
    expect(screen.getAllByText('task completed').length).toBeGreaterThan(0)
  })
})
