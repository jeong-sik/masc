import { describe, expect, it } from 'vitest'

import {
  canonicalKeeperName,
  canonicalKeeperNameFromAgentName,
  keeperIdentityKeys,
  keeperPrincipalKey,
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

  it('canonicalizes generated keeper-owned sub-op aliases to the stable keeper name', () => {
    expect(canonicalKeeperNameFromAgentName('ramarama-fierce-panda')).toBe('ramarama')
  })

  it('does not canonicalize arbitrary hyphenated runtime names', () => {
    expect(canonicalKeeperNameFromAgentName('foo-bar')).toBeNull()
    expect(keeperPrimaryName(null, 'foo-bar')).toBe('foo-bar')
  })

  it('canonicalizes keeper alias names', () => {
    expect(canonicalKeeperName('keeper-sangsu-agent')).toBe('sangsu')
  })

  it('prefers keeper_id for principal keys', () => {
    expect(keeperPrincipalKey('uuid-1', 'ramarama', 'ramarama-fierce-panda')).toBe('keeper_id:uuid-1')
  })

  it('emits lookup keys for keeper id, canonical keeper name, and runtime alias', () => {
    expect(keeperIdentityKeys('uuid-1', 'ramarama', 'ramarama-fierce-panda')).toEqual([
      'keeper_id:uuid-1',
      'ramarama',
      'ramarama-fierce-panda',
    ])
  })

  it('does not add the first segment as a keeper lookup key for arbitrary hyphenated runtime names', () => {
    const keys = keeperIdentityKeys(null, null, 'foo-bar')

    expect(keys).toContain('foo-bar')
    expect(keys).not.toContain('foo')
    expect(keys).not.toContain('keeper:foo')
  })
})
