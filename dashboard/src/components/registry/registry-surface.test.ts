// Registry surface — pure helper contracts (A4 skeleton).
// parsePersonaList must accept both masc_persona_list payload shapes
// (detailed summaries and bare name strings) and refuse malformed input
// without throwing; keeperGroup is a projection of live signals, not a
// new state machine.

import { describe, expect, it } from 'vitest'
import type { Keeper } from '../../types'
import { keeperGroup, parsePersonaList } from './registry-surface'

const keeper = (overrides: Partial<Keeper>): Keeper =>
  ({ name: 'k', status: 'idle', ...overrides }) as Keeper

describe('parsePersonaList', () => {
  it('parses detailed persona summaries', () => {
    const raw = JSON.stringify({
      count: 1,
      personas: [{
        persona_name: 'sonsukku',
        display_name: '손석구',
        trait: '집요함',
        has_keeper_defaults: true,
        profile_path: '/x/profile.json',
      }],
    })
    expect(parsePersonaList(raw)).toEqual([{
      persona_name: 'sonsukku',
      display_name: '손석구',
      trait: '집요함',
      has_keeper_defaults: true,
    }])
  })

  it('parses the bare-name payload shape', () => {
    const raw = JSON.stringify({ count: 2, personas: ['a', 'b'] })
    expect(parsePersonaList(raw).map(p => p.persona_name)).toEqual(['a', 'b'])
  })

  it('returns [] for malformed payloads instead of throwing', () => {
    expect(parsePersonaList('not json')).toEqual([])
    expect(parsePersonaList('42')).toEqual([])
    expect(parsePersonaList(JSON.stringify({ personas: 'nope' }))).toEqual([])
    expect(parsePersonaList(JSON.stringify({ personas: [{ display_name: 'no-name' }] }))).toEqual([])
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
