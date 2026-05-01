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
    expect(container.textContent).toContain('키퍼')
  })

  it('renders namespace chip', () => {
    mockStore.hasActive = true
    mockStore.namespace = 'ns-1'
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    expect(container.textContent).toContain('ns-1')
    expect(container.textContent).toContain('네임스페이스')
  })

  it('renders operation chip', () => {
    mockStore.hasActive = true
    mockStore.operation = 'op-x'
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    expect(container.textContent).toContain('op-x')
    expect(container.textContent).toContain('작업')
  })

  it('renders range chip with label', () => {
    mockStore.hasActive = true
    mockStore.range = '1h'
    mockStore.timeRangeLabel.mockReturnValue('1시간')
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    expect(container.textContent).toContain('1시간')
    expect(container.textContent).toContain('기간')
  })

  it('calls setObservatoryFilter on chip clear', () => {
    mockStore.hasActive = true
    mockStore.keeper = 'k1'
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    const btn = container.querySelector('[aria-label="키퍼 필터 제거"]') as HTMLButtonElement
    btn?.click()
    expect(mockStore.setFilter).toHaveBeenCalledWith({ keeper: null })
  })

  it('calls clearObservatoryFilters on clear all', () => {
    mockStore.hasActive = true
    mockStore.keeper = 'k1'
    const container = document.createElement('div')
    render(h(ObservatoryFilterBar, {}), container)
    const clearAll = Array.from(container.querySelectorAll('button')).find(
      (b) => b.textContent?.includes('모두 해제'),
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
    expect(region?.getAttribute('aria-label')).toBe('활성 관찰 필터')
  })
})
