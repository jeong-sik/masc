import { describe, expect, it } from 'vitest'
import { routeWantsRefreshTarget } from './refresh-scope'
import type { RouteState } from './types'

function route(tab: RouteState['tab'], params: Record<string, string> = {}): Pick<RouteState, 'tab' | 'params'> {
  return { tab, params }
}

describe('routeWantsRefreshTarget', () => {
  it('does not wake hidden heavy surfaces from the overview route', () => {
    const current = route('overview')

    expect(routeWantsRefreshTarget(current, 'execution')).toBe(false)
    expect(routeWantsRefreshTarget(current, 'operator')).toBe(false)
    expect(routeWantsRefreshTarget(current, 'board')).toBe(false)
    expect(routeWantsRefreshTarget(current, 'activity')).toBe(false)
  })

  it('matches execution-backed routes without broadening fleet-health defaults', () => {
    expect(routeWantsRefreshTarget(route('monitoring', { section: 'agents' }), 'execution')).toBe(true)
    expect(routeWantsRefreshTarget(route('monitoring', { section: 'cognition' }), 'execution')).toBe(true)
    expect(routeWantsRefreshTarget(route('monitoring', { section: 'journey' }), 'execution')).toBe(true)
    expect(routeWantsRefreshTarget(route('workspace', { section: 'planning' }), 'execution')).toBe(true)
    expect(routeWantsRefreshTarget(route('monitoring', { section: 'fleet-health' }), 'execution')).toBe(false)
    expect(routeWantsRefreshTarget(route('monitoring', { section: 'fleet-health', view: 'comparison' }), 'execution')).toBe(true)
  })

  it('keeps operator, board, and activity refreshes scoped to their visible surfaces', () => {
    expect(routeWantsRefreshTarget(route('command'), 'operator')).toBe(true)
    expect(routeWantsRefreshTarget(route('command', { view: 'inspector' }), 'operator')).toBe(false)
    expect(routeWantsRefreshTarget(route('workspace', { section: 'board' }), 'board')).toBe(true)
    expect(routeWantsRefreshTarget(route('monitoring', { section: 'observatory' }), 'activity')).toBe(true)
    expect(routeWantsRefreshTarget(route('monitoring', { section: 'fleet-health' }), 'activity')).toBe(false)
  })
})
