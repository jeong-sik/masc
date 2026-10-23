import type { RouteState } from './types'

/** Consumers gated on the accepted execution workspace need both an initial
 * HTTP observation and subsequent execution publications from the push stream. */
export function routeRequiresExecutionAuthority(route: Pick<RouteState, 'tab' | 'params'>): boolean {
  const { tab, params } = route
  switch (tab) {
    case 'workspace': return params.section === 'artifacts'
    case 'monitoring':
      switch (params.section) {
        case 'skills':
        case 'lane-inventory':
        case 'lane-addons': return true
        case 'runtime': return params.view === 'config'
        default: return false
      }
    case 'settings':
      switch (params.section) {
        case 'runtime':
        case 'routing':
        case 'paths':
        case 'runtimes': return true
        default: return false
      }
    default: return false
  }
}
