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
  beforeEach(() => setRoute())
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
})
