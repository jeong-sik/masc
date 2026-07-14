// Registry surface — pure helper contracts (A4 skeleton).
// normalizeRegistryPersonas must accept both masc_persona_list payload
// shapes (detailed summaries and bare name strings), and must distinguish
// a schema mismatch (null — surfaced as an error) from a genuinely empty
// roster ([]); keeperGroup is a projection of live signals, not a new
// state machine.

import { describe, expect, it } from 'vitest'
import type { Keeper } from '../../types'
import { keeperGroup, normalizeRegistryPersonas } from './registry-surface'

const keeper = (overrides: Partial<Keeper>): Keeper =>
  ({ name: 'k', status: 'idle', ...overrides }) as Keeper

describe('normalizeRegistryPersonas', () => {
  it('normalizes detailed persona summaries', () => {
    const payload = {
      count: 1,
      personas: [{
        persona_name: 'sonsukku',
        display_name: '손석구',
        trait: '집요함',
        has_keeper_defaults: true,
        profile_path: '/x/profile.json',
      }],
    }
    expect(normalizeRegistryPersonas(payload)).toEqual([{
      persona_name: 'sonsukku',
      display_name: '손석구',
      trait: '집요함',
      has_keeper_defaults: true,
    }])
  })

  it('normalizes the bare-name payload shape', () => {
    const payload = { count: 2, personas: ['a', 'b'] }
    expect(normalizeRegistryPersonas(payload)?.map(p => p.persona_name)).toEqual(['a', 'b'])
  })

  it('returns null for schema mismatches (not a fake empty roster)', () => {
    expect(normalizeRegistryPersonas(42)).toBeNull()
    expect(normalizeRegistryPersonas(null)).toBeNull()
    expect(normalizeRegistryPersonas({ personas: 'nope' })).toBeNull()
  })

  it('skips junk entries but keeps the rest', () => {
    const payload = { personas: [{ display_name: 'no-name' }, 'ok'] }
    expect(normalizeRegistryPersonas(payload)).toEqual([
      { persona_name: 'ok', display_name: 'ok', trait: null, has_keeper_defaults: false },
    ])
  })

  it('distinguishes an empty roster from a mismatch', () => {
    expect(normalizeRegistryPersonas({ count: 0, personas: [] })).toEqual([])
  })
})

describe('keeperGroup', () => {
  it('groups paused keepers as pause even when the fiber is alive', () => {
    expect(keeperGroup(keeper({ paused: true, keepalive_running: true }))).toBe('pause')
  })

  it('groups live keepalive fibers as run', () => {
    expect(keeperGroup(keeper({ keepalive_running: true }))).toBe('run')
  })

  it('groups configured-only and stopped keepers as off', () => {
    expect(keeperGroup(keeper({ registered: false }))).toBe('off')
    expect(keeperGroup(keeper({ keepalive_running: false }))).toBe('off')
  })
})
