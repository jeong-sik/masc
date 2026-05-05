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
  navigate: vi.fn((tab: string, params?: Record<string, string>) => {
    routeSignal.value = { tab, params: params ?? {}, postId: null }
  }),
  replaceRoute: vi.fn((tab: string, params?: Record<string, string>) => {
    routeSignal.value = { tab, params: params ?? {}, postId: null }
  }),
}))

const coordinationSignal = signal<unknown>(null)
const tasksSignal = signal<unknown[]>([])
const goalsSignal = signal<unknown[]>([])

vi.mock('../store', () => ({
  get coordinationFsmSnapshot() { return coordinationSignal },
  get tasks() { return tasksSignal },
  get goals() { return goalsSignal },
}))

vi.mock('./goals', () => ({
  Planning: () => html`<div data-testid="planning">Planning</div>`,
}))
vi.mock('./goals/goal-tree', () => ({
  GoalTree: () => html`<div data-testid="goal-tree">GoalTree</div>`,
}))

import { PlanningPanel } from './planning-panel'

function setRoute(view?: string, focus?: string) {
  const params: Record<string, string> = { section: 'planning' }
  if (view) params.view = view
  if (focus) params.focus = focus
  routeSignal.value = { tab: 'workspace', params, postId: null }
}

describe('PlanningPanel', () => {
  beforeEach(() => {
    setRoute()
    coordinationSignal.value = null
    tasksSignal.value = []
    goalsSignal.value = []
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
    expect(screen.getByText('목표 관리자')).toBeTruthy()
    expect(screen.getByText('백로그')).toBeTruthy()
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

    expect(screen.getByText('협력 상태')).toBeTruthy()
    expect(screen.getByText('reward_without_evidence')).toBeTruthy()
    expect(screen.getByText(/Reward missing evidence/)).toBeTruthy()
    expect(screen.getByText(/goal: goal-1/)).toBeTruthy()
    expect(screen.getAllByText('telemetry/task_completed').length).toBeGreaterThan(0)
    expect(screen.getByText('board/post')).toBeTruthy()
    expect(screen.getAllByText('task completed').length).toBeGreaterThan(0)
  })

  it('renders stale task focus from route param', () => {
    setRoute('default', 'stale')
    tasksSignal.value = [
      {
        id: 'task-stale-001',
        title: 'Review blocked planning handoff',
        status: 'claimed',
        assignee: 'sangsu',
        goal_id: 'goal-1',
        updated_at: '2020-01-01T00:00:00Z',
      },
    ]

    render(html`<${PlanningPanel} />`)

    expect(screen.getByTestId('planning-focus-stale')).toBeTruthy()
    expect(screen.getByText('오래된 태스크 점유')).toBeTruthy()
    expect(screen.getByText('Review blocked planning handoff')).toBeTruthy()
    expect(screen.getByText('@sangsu')).toBeTruthy()
  })

  it('renders accountability ledger focus from route param', () => {
    setRoute(undefined, 'accountability-ledger')
    tasksSignal.value = [
      {
        id: 'task-ledger-001',
        title: 'Patch verifier gate',
        status: 'awaiting_verification',
        assignee: 'keeper-alpha',
        goal_id: 'goal-ledger',
        updated_at: '2026-05-06T00:00:00Z',
      },
    ]
    goalsSignal.value = [
      {
        id: 'goal-ledger',
        horizon: 'short',
        title: 'Verifier readiness',
        priority: 1,
        status: 'active',
        phase: 'execute',
        created_at: '2026-05-06T00:00:00Z',
        updated_at: '2026-05-06T00:00:00Z',
      },
    ]

    render(html`<${PlanningPanel} />`)

    expect(screen.getByTestId('planning-focus-ledger')).toBeTruthy()
    expect(screen.getAllByText('책임 원장').length).toBeGreaterThan(0)
    expect(screen.getByText('keeper-alpha')).toBeTruthy()
    expect(screen.getByText('Patch verifier gate')).toBeTruthy()
    expect(screen.getAllByText('verify').length).toBeGreaterThan(0)
  })

  it('renders accountability matrix focus from route param', () => {
    setRoute(undefined, 'accountability-matrix')
    tasksSignal.value = [
      { id: 'task-matrix-1', title: 'A', status: 'todo', assignee: 'keeper-alpha', updated_at: '2026-05-06T00:00:00Z' },
      { id: 'task-matrix-2', title: 'B', status: 'done', assignee: 'keeper-alpha', updated_at: '2026-05-06T00:00:00Z' },
      { id: 'task-matrix-3', title: 'C', status: 'claimed', assignee: 'keeper-beta', updated_at: '2020-01-01T00:00:00Z' },
    ]

    render(html`<${PlanningPanel} />`)

    expect(screen.getByTestId('planning-focus-matrix')).toBeTruthy()
    expect(screen.getAllByText('책임 매트릭스').length).toBeGreaterThan(0)
    expect(screen.getByText('keeper-alpha')).toBeTruthy()
    expect(screen.getByText('keeper-beta')).toBeTruthy()
  })
})
