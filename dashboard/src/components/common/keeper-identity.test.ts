import { describe, expect, it } from 'vitest'

import {
  canonicalKeeperName,
  canonicalKeeperNameFromAgentName,
  keeperIdentityKeys,
  keeperPrincipalKey,
  keeperPrimaryName,
  keeperSecondaryIdentity,
  runtimeAgentName,
} from './keeper-identity'

describe('keeper identity helpers', () => {
  it('prefers keeper name as the primary identity', () => {
    expect(keeperPrimaryName('sangsu', 'keeper-sangsu-agent')).toBe('sangsu')
  })

  it('collapses the keeper-X-agent wrapper into the primary identity (same keeper, not a second identity)', () => {
    // 'keeper-sangsu-agent' canonicalizes to 'sangsu' — this is the wrapper
    // form of the same keeper, not a distinct runtime identity.
    expect(runtimeAgentName('sangsu', 'keeper-sangsu-agent')).toBeNull()
  })

  it('keeps runtime name as secondary identity when it genuinely differs', () => {
    expect(runtimeAgentName('sangsu', 'codex-worker-7')).toBe('codex-worker-7')
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

  it('canonicalizes board runtime aliases to keeper names', () => {
    expect(canonicalKeeperNameFromAgentName('keeper-analyst-agent')).toBe('analyst')
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

describe('keeperSecondaryIdentity — fleet roster namespace line', () => {
  // Table-driven: each row is [keeperId, keeperName, agentName, expected].
  // The "collapse" rows are the ones the fleet roster used to render as a
  // second, redundant identity line under the already-shown display name.
  const cases: Array<[string | null, string | null, string | null, string | null]> = [
    // keeper_id == name (backend emits this): collapse, no second identity.
    ['sangsu', 'sangsu', 'keeper-sangsu-agent', null],
    // keeper-X-agent wrapper of the same name: collapse.
    [null, 'sangsu', 'keeper-sangsu-agent', null],
    // generated nickname wrapper of the same name: collapse.
    [null, 'ramarama', 'ramarama-fierce-panda', null],
    // keeper_id is a genuinely distinct handle (uuid): shown.
    ['sangsu-uuid-77', 'sangsu', 'keeper-sangsu-agent', 'sangsu-uuid-77'],
    // no keeper_id; agent_name genuinely differs from the keeper name: shown.
    [null, 'sangsu', 'codex-worker-7', 'codex-worker-7'],
    // no keeper name at all: primary falls back to the raw agent name, which
    // then canonicalizes to itself — nothing distinct left to show.
    [null, null, 'foo-bar', null],
  ]

  it.each(cases)(
    'keeperSecondaryIdentity(%s, %s, %s) -> %s',
    (keeperId, keeperName, agentName, expected) => {
      expect(keeperSecondaryIdentity(keeperId, keeperName, agentName)).toBe(expected)
    },
  )

  it('returns null when there is no primary display name to compare against', () => {
    expect(keeperSecondaryIdentity('some-id', null, null)).toBeNull()
  })
})
