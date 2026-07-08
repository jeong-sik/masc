import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import type { RouteState } from '../types'

const mockRoute = await vi.hoisted(async () => {
  const { signal } = await import('@preact/signals')
  return signal<RouteState>({ tab: 'monitoring', params: {}, postId: null })
})

vi.mock('./keeper-detail-page', () => ({
  KeeperDetailPage: () => h('div', { 'data-testid': 'keeper-detail-page' }, 'KeeperDetailPage'),
}))
vi.mock('./agent-profile', () => ({
  AgentProfile: ({ name }: { name: string }) => h('div', { 'data-testid': 'agent-profile', 'data-name': name }, 'AgentProfile'),
}))
vi.mock('./fsm-hub', () => ({
  FsmHub: ({ selectedName }: { selectedName?: string }) => h('div', { 'data-testid': 'fsm-hub', 'data-selected': selectedName }, 'FsmHub'),
}))
vi.mock('./fleet-fsm-matrix', () => ({
  FleetFsmMatrix: () => h('div', { 'data-testid': 'fleet-fsm-matrix' }, 'FleetFsmMatrix'),
}))
vi.mock('./composite-fsm-flowchart', () => ({
  CompositeFsmFlowchart: () => h('div', { 'data-testid': 'composite-fsm-flowchart' }, 'CompositeFsmFlowchart'),
}))
vi.mock('./agent-roster', () => ({
  AgentRoster: ({ keeperFilter }: { keeperFilter: string }) => h('div', { 'data-testid': 'agent-roster', 'data-filter': keeperFilter }, 'AgentRoster'),
}))

vi.mock('./keeper-spawn/keeper-spawn-panel', () => ({
  KeeperSpawnPanel: () => h('div', { 'data-testid': 'keeper-spawn-panel' }, 'KeeperSpawnPanel'),
}))

vi.mock('../router', () => ({
  route: mockRoute,
}))

import { AgentsUnified } from './agents-unified'


describe('AgentsUnified', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mockRoute.value = { tab: 'monitoring', params: {}, postId: null }
    vi.clearAllMocks()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders keeper detail page when keeper param is present', () => {
    mockRoute.value = { tab: 'monitoring', params: { keeper: 'alpha' }, postId: null }
    render(h(AgentsUnified, null), container)
    expect(container.querySelector('[data-testid="keeper-detail-page"]')).not.toBeNull()
  })

  it('renders agent profile when agent param is present', () => {
    mockRoute.value = { tab: 'monitoring', params: { agent: 'beta' }, postId: null }
    render(h(AgentsUnified, null), container)
    const el = container.querySelector('[data-testid="agent-profile"]')
    expect(el).not.toBeNull()
    expect(el!.getAttribute('data-name')).toBe('beta')
  })

  it('defaults to all view and shows roster', () => {
    render(h(AgentsUnified, null), container)
    const roster = container.querySelector('[data-testid="agent-roster"]')
    expect(roster).not.toBeNull()
    expect(roster!.getAttribute('data-filter')).toBe('all')
    expect(container.querySelector('[data-testid="filter-chips"]')).toBeNull()
    // Keeper creation lives at the top of the fleet roster (all / keepers views).
    expect(container.querySelector('[data-testid="keeper-spawn-panel"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="keeper-multi-select"]')).toBeNull()
    expect(container.querySelector('[data-testid="keeper-token-stats"]')).toBeNull()
  })

  it('honors agents view deep link without showing the old top switcher', async () => {
    mockRoute.value = { tab: 'monitoring', params: { view: 'agents' }, postId: null }
    render(h(AgentsUnified, null), container)
    const roster = container.querySelector('[data-testid="agent-roster"]')
    expect(roster!.getAttribute('data-filter')).toBe('agent-only')
    expect(container.querySelector('[data-testid="filter-chips"]')).toBeNull()
    // Agents view lists workspace agents, not keepers — no keeper-create entry here.
    expect(container.querySelector('[data-testid="keeper-spawn-panel"]')).toBeNull()
  })

  it('renders keepers view as a narrowed roster without multi-select stats', () => {
    mockRoute.value = { tab: 'monitoring', params: { view: 'keepers' }, postId: null }
    render(h(AgentsUnified, null), container)
    expect(container.querySelector('[data-testid="keeper-spawn-panel"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="keeper-multi-select"]')).toBeNull()
    expect(container.querySelector('[data-testid="keeper-token-stats"]')).toBeNull()
    const roster = container.querySelector('[data-testid="agent-roster"]')
    expect(roster!.getAttribute('data-filter')).toBe('keeper-only')
  })

  it('renders FSM hub panel when view is fsm', () => {
    mockRoute.value = { tab: 'monitoring', params: { view: 'fsm' }, postId: null }
    render(h(AgentsUnified, null), container)
    expect(container.querySelector('[data-testid="fleet-fsm-matrix"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="composite-fsm-flowchart"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="fsm-hub"]')).not.toBeNull()
  })

  it('marks the FSM hub panel with the v2 monitoring panel class', () => {
    mockRoute.value = { tab: 'monitoring', params: { view: 'fsm' }, postId: null }
    render(h(AgentsUnified, null), container)
    const panel = container.querySelector('.v2-monitoring-panel')
    expect(panel).not.toBeNull()
    expect(panel!.contains(container.querySelector('[data-testid="fleet-fsm-matrix"]'))).toBe(true)
  })

})
