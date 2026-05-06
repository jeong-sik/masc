import { describe, expect, it } from 'vitest'

import {
  cascadeEventKey,
  cascadeInspectorRouteParams,
  isCascadeInspectorFocus,
} from './cascade-inspector'

describe('isCascadeInspectorFocus', () => {
  it.each([
    ['deep-dive', true],
    ['compare', true],
    ['trace', false],
    ['providers', false],
    ['', false],
    [undefined, false],
  ])('classifies %s as %s', (value, expected) => {
    expect(isCascadeInspectorFocus(value)).toBe(expected)
  })
})

describe('cascadeInspectorRouteParams', () => {
  it('routes trace to the unfocused inspector', () => {
    expect(cascadeInspectorRouteParams('trace')).toEqual({
      section: 'runtime',
      view: 'inspector',
    })
  })

  it('routes deep-dive and compare to inspector focus states', () => {
    expect(cascadeInspectorRouteParams('deep-dive')).toEqual({
      section: 'runtime',
      view: 'inspector',
      focus: 'deep-dive',
    })
    expect(cascadeInspectorRouteParams('compare')).toEqual({
      section: 'runtime',
      view: 'inspector',
      focus: 'compare',
    })
  })
})

describe('cascadeEventKey', () => {
  it('keeps tuple boundaries distinct', () => {
    const base = {
      strategy: 'fallback',
      candidates_in: 4,
      candidates_out: 2,
      backoff_ms: 0,
      kind: 'ordered' as const,
    }

    expect(cascadeEventKey({ ...base, ts: 1, cascade_name: '23', cycle: 4 }))
      .not.toBe(cascadeEventKey({ ...base, ts: 12, cascade_name: '3', cycle: 4 }))
  })
})
