import { describe, expect, it } from 'vitest'

import {
  canonicalKeeperName,
  keeperIdentityHint,
  keeperIdentityKeys,
  keeperPrimaryName,
  keeperPrincipalKey,
} from './keeper-identity'

describe('keeper identity helpers', () => {
  it('accepts a keeper name as-is — nothing is parsed out of the string', () => {
    expect(canonicalKeeperName('sangsu')).toBe('sangsu')
    expect(canonicalKeeperName('keeper-sangsu-agent')).toBe('keeper-sangsu-agent')
    expect(canonicalKeeperName('ramarama-fierce-panda')).toBe('ramarama-fierce-panda')
  })

  it('rejects empty and non-identifier strings', () => {
    expect(canonicalKeeperName(null)).toBeNull()
    expect(canonicalKeeperName('   ')).toBeNull()
    expect(canonicalKeeperName('two words')).toBeNull()
  })

  it('trims surrounding whitespace', () => {
    expect(keeperPrimaryName('  sangsu  ')).toBe('sangsu')
  })

  it('prefers keeper_id for principal keys', () => {
    expect(keeperPrincipalKey('uuid-1', 'ramarama')).toBe('keeper_id:uuid-1')
  })

  it('falls back to the lowercased keeper name for principal keys', () => {
    expect(keeperPrincipalKey(null, 'RamaRama')).toBe('keeper:ramarama')
    expect(keeperPrincipalKey(null, null)).toBeNull()
  })

  it('emits lookup keys for keeper id and keeper name only', () => {
    expect(keeperIdentityKeys('uuid-1', 'RamaRama')).toEqual([
      'keeper_id:uuid-1',
      'ramarama',
    ])
  })

  it('deduplicates when only the name is available', () => {
    expect(keeperIdentityKeys(null, 'foo-bar')).toEqual(['keeper:foo-bar', 'foo-bar'])
  })

  it('labels the hint with the keeper name', () => {
    expect(keeperIdentityHint('sangsu')).toBe('키퍼 · sangsu')
    expect(keeperIdentityHint(null)).toBeNull()
  })
})
