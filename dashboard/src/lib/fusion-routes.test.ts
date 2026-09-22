import { describe, expect, it } from 'vitest'
import type { RuntimeResolvedResponse } from '../api/dashboard'
import { routeOptionsFromResolved } from './fusion-routes'

function runtime(id: string): RuntimeResolvedResponse['runtimes'][number] {
  return {
    id,
    provider: 'p',
    model: 'm',
    effective_max_context: 1,
    max_context_source: 'capability',
    max_output_tokens: null,
    is_local: false,
    is_default: false,
  }
}

const RESOLVED: RuntimeResolvedResponse = {
  config_path: null,
  default_runtime: null,
  runtimes: [runtime('p.two'), runtime('p.one')],
  lanes: [
    { id: 'lane.fast', declared: true, runtime_ids: ['p.one', 'p.two'] },
    // A bare runtime id an assignment dispatches through; the runtime entry
    // already names it.
    { id: 'p.one', declared: false, runtime_ids: ['p.one'] },
  ],
  assignments: [],
}

describe('routeOptionsFromResolved', () => {
  it('lists declared lanes first, then runtimes, each id once', () => {
    expect(routeOptionsFromResolved(RESOLVED)).toEqual([
      { id: 'lane.fast', kind: 'lane' },
      { id: 'p.two', kind: 'runtime' },
      { id: 'p.one', kind: 'runtime' },
    ])
  })

  it('offers nothing when the resolver reports nothing', () => {
    expect(routeOptionsFromResolved({ ...RESOLVED, runtimes: [], lanes: [] })).toEqual([])
  })
})
