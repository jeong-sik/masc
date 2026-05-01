import type { RouteState } from './types'

export type RouteRefreshTarget = 'execution' | 'board' | 'operator' | 'activity'

export function routeWantsRefreshTarget(
  routeState: Pick<RouteState, 'tab' | 'params'>,
  target: RouteRefreshTarget,
): boolean {
  switch (target) {
    case 'execution':
      return routeWantsExecution(routeState)
    case 'board':
      return routeState.tab === 'workspace' && routeState.params.section === 'board'
    case 'operator':
      return routeState.tab === 'command' && routeState.params.view !== 'inspector'
    case 'activity':
      return routeState.tab === 'monitoring' && routeState.params.section === 'observatory'
  }
}

function routeWantsExecution(routeState: Pick<RouteState, 'tab' | 'params'>): boolean {
  if (routeState.tab === 'workspace') {
    return routeState.params.section === 'planning'
  }

  if (routeState.tab !== 'monitoring') return false

  const section = routeState.params.section
  if (section === 'observatory' || section === 'journey' || section === 'agents' || section === 'cognition') {
    return true
  }

  return section === 'fleet-health' && routeState.params.view === 'comparison'
}
