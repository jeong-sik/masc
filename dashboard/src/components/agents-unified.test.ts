import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { h, type ComponentChildren } from 'preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import type { RouteState } from '../types'

const mockRoute = await vi.hoisted(async () => {
  const { signal } = await import('@preact/signals')
  return signal<RouteState>({ tab: 'monitoring', params: {}, postId: null })
})

type FilterChip = { key: string; label: ComponentChildren }
type FilterChipWithCount = FilterChip & { count?: ComponentChildren }

vi.mock('./keeper-detail-page', () => ({
  KeeperDetailPage: () => h('div', { 'data-testid': 'keeper-detail-page' }, 'KeeperDetailPage'),
}))
vi.mock('./agent-profile', () => ({
  AgentProfile: ({ name }: { name: string }) => h('div', { 'data-testid': 'agent-profile', 'data-name': name }, 'AgentProfile'),
}))
vi.mock('./keeper-spawn/keeper-spawn-panel', () => ({
  KeeperSpawnPanel: () => h('div', { 'data-testid': 'keeper-spawn-panel' }, 'KeeperSpawnPanel'),
}))
vi.mock('./keeper-token-stats', () => ({
  KeeperTokenStats: () => h('div', { 'data-testid': 'keeper-token-stats' }, 'KeeperTokenStats'),
}))
vi.mock('./keeper-multi-select', () => ({
  KeeperMultiSelect: ({ hint }: { hint?: string }) => h('div', { 'data-testid': 'keeper-multi-select', 'data-hint': hint }, 'KeeperMultiSelect'),
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
vi.mock('./common/filter-chips', () => ({
  FilterChips: ({ chips, value, onChange }: {
    chips: FilterChipWithCount[]
    value: string
    onChange: (key: string) => void
  }) =>
    h('div', { 'data-testid': 'filter-chips', 'data-value': value },
      chips.map((chip) => h('button', { key: chip.key, onClick: () => onChange(chip.key) }, [
        chip.label,
        chip.count != null ? h('span', { 'data-testid': `chip-count-${chip.key}` }, chip.count) : null,
      ]))
    ),
}))
vi.mock('./agent-roster', () => ({
  AgentRoster: ({ keeperFilter }: { keeperFilter: string }) => h('div', { 'data-testid': 'agent-roster', 'data-filter': keeperFilter }, 'AgentRoster'),
  countRuntimeKinds: vi.fn(() => ({ agents: 0, keepers: 0, pausedKeepers: 0, transientKeepers: 0, offlineKeepers: 0, keeperRows: 0, totalRuntimes: 0 })),
}))

vi.mock('../router', () => ({
  route: mockRoute,
  navigate: vi.fn((tab: RouteState['tab'], params?: Record<string, string>) => {
    mockRoute.value = { tab, params: params ?? {}, postId: null }
  }),
}))

vi.mock('../store', () => ({
  agents: { value: [] },
  keepers: { value: [] },
  executionLoaded: { value: false },
  shellCounts: { value: null },
  shellRuntimeResolution: { value: null },
}))
vi.mock('../namespace-truth-store', () => ({
  namespaceTruth: { value: null },
}))
vi.mock('../runtime-counts', () => ({
  formatKeeperRosterCount: vi.fn(() => 'keeper 행 16 / keeper 실행 fiber 4 / 일시정지 keeper 12 / configured keeper 16'),
  formatRuntimeRosterCount: vi.fn(() => 'runtime 행 20 / keeper 실행 fiber 4 / workspace agents 4 / 일시정지 keeper 12 / configured keeper 16'),
  resolveRuntimeCounts: vi.fn(() => ({
    live: { agents: 4, keepers: 4, pausedKeepers: 12, transientKeepers: 0, offlineKeepers: 0, keeperRows: 16, tasks: 0, totalRuntimes: 8, available: true },
    configured: { keepers: 16, totalRuntimes: 8, source: 'namespace-truth' },
    source: 'execution',
  })),
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
    expect(container.querySelector('[data-testid="keeper-spawn-panel"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="chip-count-all"]')?.textContent)
      .toBe('runtime 행 20 / keeper 실행 fiber 4 / workspace agents 4 / 일시정지 keeper 12 / configured keeper 16')
    expect(container.querySelector('[data-testid="chip-count-keepers"]')?.textContent)
      .toBe('keeper 행 16 / keeper 실행 fiber 4 / 일시정지 keeper 12 / configured keeper 16')
    expect(container.querySelector('[data-testid="chip-count-agents"]')?.textContent)
      .toBe('workspace agents 4')
  })

  it('switches to agents view via filter chips', async () => {
    render(h(AgentsUnified, null), container)
    const btn = Array.from(container.querySelectorAll('button')).find(
      b => b.textContent?.includes('Workspace Agents'),
    )
    expect(btn).not.toBeUndefined()
    await act(async () => {
      btn!.click()
    })
    render(h(AgentsUnified, null), container)
    const roster = container.querySelector('[data-testid="agent-roster"]')
    expect(roster!.getAttribute('data-filter')).toBe('agent-only')
  })

  it('renders keepers view with multi-select and token stats', () => {
    mockRoute.value = { tab: 'monitoring', params: { view: 'keepers' }, postId: null }
    render(h(AgentsUnified, null), container)
    expect(container.querySelector('[data-testid="keeper-spawn-panel"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="keeper-multi-select"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="keeper-token-stats"]')).not.toBeNull()
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
