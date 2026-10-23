import type { RouteState } from './types'

/** Consumers gated on the accepted execution workspace need both an initial
 * HTTP observation and subsequent execution publications from the push stream. */
export function routeRequiresExecutionAuthority(route: Pick<RouteState, 'tab' | 'params'>): boolean {
  return route.tab === 'workspace' && route.params.section === 'artifacts'
}
