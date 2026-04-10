import { describe, expect, it } from 'vitest'

import {
  keeperIdentitySearchTerms,
  keeperPrimaryName,
  runtimeAgentName,
} from './keeper-identity'

describe('keeper identity helpers', () => {
  it('prefers keeper name as the primary identity', () => {
    expect(keeperPrimaryName('sangsu', 'keeper-sangsu-agent')).toBe('sangsu')
  })

  it('keeps runtime name as secondary identity when it differs', () => {
    expect(runtimeAgentName('sangsu', 'keeper-sangsu-agent')).toBe('keeper-sangsu-agent')
  })

  it('returns both keeper and runtime names for search matching', () => {
    expect(keeperIdentitySearchTerms('sangsu', 'keeper-sangsu-agent')).toEqual([
      'sangsu',
      'keeper-sangsu-agent',
    ])
  })
})
