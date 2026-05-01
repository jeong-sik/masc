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

vi.mock('./keeper-detail', () => ({
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
vi.mock('./handoff-timeline', () => ({
  HandoffTimeline: ({ selectedKeeper }: { selectedKeeper?: string }) => h('div', { 'data-testid': 'handoff-timeline', 'data-selected': selectedKeeper }, 'HandoffTimeline'),
}))
vi.mock('./composite-fsm-flowchart', () => ({
  CompositeFsmFlowchart: () => h('div', { 'data-testid': 'composite-fsm-flowchart' }, 'CompositeFsmFlowchart'),
}))
vi.mock('./common/filter-chips', () => ({
  FilterChips: ({ chips, value, onChange }: {
    chips: FilterChip[]
    value: string
    onChange: (key: string) => void
  }) =>
    h('div', { 'data-testid': 'filter-chips', 'data-value': value },
      chips.map((chip) => h('button', { key: chip.key, onClick: () => onChange(chip.key) }, chip.label))
    ),
}))
vi.mock('./common/route-link', () => ({
  RouteLink: ({ children }: { children?: ComponentChildren }) => h('a', null, children),
}))
vi.mock('./agent-roster', () => ({
  AgentRoster: ({ keeperFilter }: { keeperFilter: string }) => h('div', { 'data-testid': 'agent-roster', 'data-filter': keeperFilter }, 'AgentRoster'),
  countRuntimeKinds: vi.fn(() => ({ agents: 0, keepers: 0 })),
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
}))
vi.mock('../namespace-truth-store', () => ({
  namespaceTruth: { value: null },
}))
vi.mock('../runtime-counts', () => ({
  resolveRuntimeCounts: vi.fn(() => ({
    totalRuntimes: 0,
    keepers: 0,
    agents: 0,
    configuredKeepers: 0,
  })),
}))

import { AgentsUnified } from './agents-unified'
import { resolveRuntimeCounts } from '../runtime-counts'

const mockResolveRuntimeCounts = vi.mocked(resolveRuntimeCounts)
const runtimeCounts = (
  overrides: Partial<ReturnType<typeof resolveRuntimeCounts>>,
): ReturnType<typeof resolveRuntimeCounts> => ({
  agents: 0,
  keepers: 0,
  tasks: 0,
  totalRuntimes: 0,
  configuredKeepers: 0,
  source: 'execution',
  ...overrides,
})

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
  })

  it('switches to agents view via filter chips', async () => {
    render(h(AgentsUnified, null), container)
    const btn = Array.from(container.querySelectorAll('button')).find(
      b => b.textContent?.includes('에이전트'),
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
    expect(container.querySelector('[data-testid="handoff-timeline"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="composite-fsm-flowchart"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="fsm-hub"]')).not.toBeNull()
  })

  it('shows runtime truth banner when configuredKeeperDelta > 0', () => {
    mockResolveRuntimeCounts.mockReturnValue(runtimeCounts({
      totalRuntimes: 5,
      keepers: 2,
      agents: 3,
      configuredKeepers: 4,
    }))
    render(h(AgentsUnified, null), container)
    expect(container.textContent).toContain('runtime truth')
  })

  it('does not show runtime truth banner when configuredKeeperDelta is 0', () => {
    mockResolveRuntimeCounts.mockReturnValue(runtimeCounts({
      totalRuntimes: 5,
      keepers: 2,
      agents: 3,
      configuredKeepers: 2,
    }))
    render(h(AgentsUnified, null), container)
    expect(container.textContent).not.toContain('runtime truth')
  })
})
