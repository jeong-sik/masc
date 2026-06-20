import type { RouteState } from './types'

export type RouteRefreshTarget = 'execution' | 'board' | 'operator' | 'activity' | 'fusion'

export function routeWantsRefreshTarget(
  routeState: Pick<RouteState, 'tab' | 'params'>,
  target: RouteRefreshTarget,
): boolean {
  switch (target) {
    case 'execution':
      return routeWantsExecution(routeState)
    case 'board':
      return routeState.tab === 'board' || (routeState.tab === 'workspace' && routeState.params.section === 'board')
    case 'operator':
      return routeState.tab === 'command' && routeState.params.view !== 'inspector'
    case 'activity':
      return routeState.tab === 'monitoring' && routeState.params.section === 'observatory'
    case 'fusion':
      // The fusion run-status panel only mounts on the top-level fusion surface,
      // so its registry refetch is scoped to that route (RFC-0266 Phase 4).
      return routeState.tab === 'fusion'
  }
}

function routeWantsExecution(routeState: Pick<RouteState, 'tab' | 'params'>): boolean {
  if (routeState.tab === 'keepers') return true

  if (routeState.tab === 'workspace') {
    return routeState.params.section === 'planning'
  }

  if (routeState.tab !== 'monitoring') return false

  const section = routeState.params.section
  if (section === 'journey' || section === 'agents' || section === 'cognition') {
    return true
  }

  if (section === 'observatory') {
    return false
  }

  return section === 'fleet-health' && routeState.params.view === 'comparison'
}
