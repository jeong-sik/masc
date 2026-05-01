import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { ObservatoryFilterBar } from './observatory-filter-bar'

const mockStore = {
  hasActive: false,
  keeper: null as string | null,
  namespace: null as string | null,
  operation: null as string | null,
  range: null as string | null,
  setFilter: vi.fn(),
  clearFilters: vi.fn(),
  timeRangeLabel: vi.fn((r: string) => r),
}

vi.mock('../../observatory-filter-store', () => ({
  currentKeeperFilter: () => mockStore.keeper,
  currentNamespaceFilter: () => mockStore.namespace,
  currentOperationFilter: () => mockStore.operation,
  currentTimeRangeFilter: () => mockStore.range,
  hasActiveObservatoryFilter: () => mockStore.hasActive,
  setObservatoryFilter: (...args: any[]) => mockStore.setFilter(...args),
  clearObservatoryFilters: () => mockStore.clearFilters(),
  timeRangeLabel: (r: string) => mockStore.timeRangeLabel(r),
}))

describe('ObservatoryFilterBar', () => {
  beforeEach(() => {
    mockStore.hasActive = false
    mockStore.keeper = null
    mockStore.namespace = null
    mockStore.operation = null
    mockStore.range = null
    mockStore.setFilter.mockReset()
    mockStore.clearFilters.mockReset()
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('returns null when no active filter', () => {
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    expect(container.firstElementChild).toBeNull()
  })

  it('renders keeper chip', () => {
    mockStore.hasActive = true
    mockStore.keeper = 'keeper-a'
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    expect(container.textContent).toContain('keeper-a')
    expect(container.textContent).toContain('Keeper')
  })

  it('renders namespace chip', () => {
    mockStore.hasActive = true
    mockStore.namespace = 'ns-1'
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    expect(container.textContent).toContain('ns-1')
    expect(container.textContent).toContain('Namespace')
  })

  it('renders operation chip', () => {
    mockStore.hasActive = true
    mockStore.operation = 'op-x'
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    expect(container.textContent).toContain('op-x')
    expect(container.textContent).toContain('Operation')
  })

  it('renders range chip with label', () => {
    mockStore.hasActive = true
    mockStore.range = '1h'
    mockStore.timeRangeLabel.mockReturnValue('1시간')
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    expect(container.textContent).toContain('1시간')
    expect(container.textContent).toContain('Range')
  })

  it('calls setObservatoryFilter on chip clear', () => {
    mockStore.hasActive = true
    mockStore.keeper = 'k1'
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    const btn = container.querySelector('[aria-label="Clear Keeper filter"]') as HTMLButtonElement
    btn?.click()
    expect(mockStore.setFilter).toHaveBeenCalledWith({ keeper: null })
  })

  it('calls clearObservatoryFilters on clear all', () => {
    mockStore.hasActive = true
    mockStore.keeper = 'k1'
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    const clearAll = Array.from(container.querySelectorAll('button')).find(
      (b) => b.textContent?.includes('Clear all'),
    )
    clearAll?.click()
    expect(mockStore.clearFilters).toHaveBeenCalled()
  })

  it('has region role and aria-label', () => {
    mockStore.hasActive = true
    mockStore.keeper = 'k1'
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('Active observability filters')
  })
})
