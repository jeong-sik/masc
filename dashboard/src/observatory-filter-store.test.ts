import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('./router', async () => {
  const { signal } = await import('@preact/signals')
  const routeSignal = signal<{ tab: string; params: Record<string, string>; postId: null }>({
    tab: 'overview',
    params: {},
    postId: null,
  })
  return {
    route: routeSignal,
    navigate: vi.fn((nextTab: string, nextParams?: Record<string, string>) => {
      routeSignal.value = { tab: nextTab, params: { ...(nextParams ?? {}) }, postId: null }
    }),
    __setRoute: (nextTab: string, nextParams: Record<string, string>) => {
      routeSignal.value = { tab: nextTab, params: { ...nextParams }, postId: null }
    },
  }
})

import * as router from './router'
import {
  currentKeeperFilter,
  currentNamespaceFilter,
  currentOperationFilter,
  currentTimeRangeFilter,
  hasActiveObservatoryFilter,
  setObservatoryFilter,
  clearObservatoryFilters,
  setKeeperFilter,
  setTimeRangeFilter,
  timeRangeLabel,
  timeRangeShortLabel,
  timeRangeToMs,
} from './observatory-filter-store'

const setRoute = (router as unknown as {
  __setRoute: (t: string, p: Record<string, string>) => void
}).__setRoute

describe('observatory-filter-store', () => {
  beforeEach(() => {
    setRoute('overview', {})
    vi.clearAllMocks()
  })

  it('returns null for all filters when URL has no relevant params', () => {
    expect(currentKeeperFilter()).toBeNull()
    expect(currentNamespaceFilter()).toBeNull()
    expect(currentOperationFilter()).toBeNull()
    expect(currentTimeRangeFilter()).toBeNull()
    expect(hasActiveObservatoryFilter()).toBe(false)
  })

  it('reads keeper/ns/op/range from URL params', () => {
    setRoute('monitoring', { section: 'fleet-health', keeper: 'nova', ns: 'team-a', op: 'op-42', range: '1h' })

    expect(currentKeeperFilter()).toBe('nova')
    expect(currentNamespaceFilter()).toBe('team-a')
    expect(currentOperationFilter()).toBe('op-42')
    expect(currentTimeRangeFilter()).toBe('1h')
    expect(hasActiveObservatoryFilter()).toBe(true)
  })

  it('rejects invalid time range preset', () => {
    setRoute('monitoring', { range: 'invalid' })
    expect(currentTimeRangeFilter()).toBeNull()
  })

  it('setObservatoryFilter writes to URL via navigate', () => {
    setObservatoryFilter({ keeper: 'luna', range: '5m' })
    expect(router.navigate).toHaveBeenCalledWith('overview', { keeper: 'luna', range: '5m' })
  })

  it('setObservatoryFilter with null value deletes the param', () => {
    setRoute('monitoring', { keeper: 'nova', range: '1h' })
    setObservatoryFilter({ keeper: null })
    expect(router.navigate).toHaveBeenLastCalledWith('monitoring', { range: '1h' })
  })

  it('setObservatoryFilter preserves unrelated params (section, session_id)', () => {
    setRoute('monitoring', { section: 'fleet-health', session_id: 's-1' })
    setObservatoryFilter({ keeper: 'nova' })
    expect(router.navigate).toHaveBeenLastCalledWith('monitoring', {
      section: 'fleet-health',
      session_id: 's-1',
      keeper: 'nova',
    })
  })

  it('clearObservatoryFilters removes all 4 filter params', () => {
    setRoute('monitoring', {
      section: 'fleet-health',
      keeper: 'nova',
      ns: 'team-a',
      op: 'op-42',
      range: '1h',
    })
    clearObservatoryFilters()
    expect(router.navigate).toHaveBeenLastCalledWith('monitoring', { section: 'fleet-health' })
  })

  it('setKeeperFilter is a shortcut for keeper-only update', () => {
    setKeeperFilter('orion')
    expect(router.navigate).toHaveBeenCalledWith('overview', { keeper: 'orion' })
  })

  it('setTimeRangeFilter is a shortcut for range-only update', () => {
    setTimeRangeFilter('24h')
    expect(router.navigate).toHaveBeenCalledWith('overview', { range: '24h' })
  })

  it('timeRangeLabel returns human-readable Korean label', () => {
    expect(timeRangeLabel('5m')).toBe('최근 5분')
    expect(timeRangeLabel('1h')).toBe('최근 1시간')
    expect(timeRangeLabel('6h')).toBe('최근 6시간')
    expect(timeRangeLabel('24h')).toBe('최근 24시간')
    expect(timeRangeLabel('7d')).toBe('최근 7일')
  })

  it('timeRangeShortLabel returns short label without prefix', () => {
    expect(timeRangeShortLabel('5m')).toBe('5분')
    expect(timeRangeShortLabel('1h')).toBe('1시간')
    expect(timeRangeShortLabel('6h')).toBe('6시간')
    expect(timeRangeShortLabel('24h')).toBe('24시간')
    expect(timeRangeShortLabel('7d')).toBe('7일')
  })

  it('timeRangeToMs converts presets to milliseconds', () => {
    expect(timeRangeToMs('5m')).toBe(5 * 60_000)
    expect(timeRangeToMs('1h')).toBe(60 * 60_000)
    expect(timeRangeToMs('6h')).toBe(6 * 60 * 60_000)
    expect(timeRangeToMs('24h')).toBe(24 * 60 * 60_000)
    expect(timeRangeToMs('7d')).toBe(7 * 24 * 60 * 60_000)
  })

  it('accepts 6h as valid time range preset', () => {
    setRoute('monitoring', { range: '6h' })
    expect(currentTimeRangeFilter()).toBe('6h')
  })
})
