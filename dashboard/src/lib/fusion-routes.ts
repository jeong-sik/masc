// Route candidates for a Fusion preset seat.
//
// A seat (panel model, meta judge, first-pass judge model) names a route: a
// `[runtime.lanes.<name>]` lane id or a runtime id. The server refuses a preset
// whose seat resolves to neither (route_unresolved), so the editor offers only
// what GET /api/v1/runtime/resolved reports, lanes first. A lane the document
// lists as undeclared is one a bare runtime id already stands for, so it is
// left to the runtime entry rather than shown twice.

import type { RuntimeResolvedResponse } from '../api/dashboard'

export type FusionRouteKind = 'lane' | 'runtime'

export interface FusionRouteOption {
  readonly id: string
  readonly kind: FusionRouteKind
}

export function routeOptionsFromResolved(resolved: RuntimeResolvedResponse): FusionRouteOption[] {
  const seen = new Set<string>()
  const options: FusionRouteOption[] = []
  const add = (id: string, kind: FusionRouteKind) => {
    if (id === '' || seen.has(id)) return
    seen.add(id)
    options.push({ id, kind })
  }
  for (const lane of resolved.lanes) {
    if (lane.declared) add(lane.id, 'lane')
  }
  for (const runtime of resolved.runtimes) add(runtime.id, 'runtime')
  return options
}
