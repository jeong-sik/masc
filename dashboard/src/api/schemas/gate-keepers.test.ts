import { describe, expect, it } from 'vitest'

import {
  GateKeepersSchemaDriftError,
  parseGateKeepersData,
} from './gate-keepers'

describe('parseGateKeepersData', () => {
  it('accepts an empty payload', () => {
    const out = parseGateKeepersData({})
    expect(out.count).toBe(0)
    expect(out.keepers).toHaveLength(0)
  })

  it('accepts a minimal keeper with only name', () => {
    const out = parseGateKeepersData({
      count: 1,
      keepers: [{ name: 'greeter' }],
    })
    expect(out.keepers).toHaveLength(1)
    expect(out.keepers[0]!.name).toBe('greeter')
    expect(out.keepers[0]!.status).toBeUndefined()
    // last_turn_ago_s collapses absent → null (matches prior decoder);
    // downstream renders '—' uniformly whether the field is absent or
    // explicitly null.
    expect(out.keepers[0]!.last_turn_ago_s).toBeNull()
  })

  it('preserves explicit null last_turn_ago_s separate from absent', () => {
    const out = parseGateKeepersData({
      count: 1,
      keepers: [{ name: 'cold-start', last_turn_ago_s: null }],
    })
    expect(out.keepers[0]!.last_turn_ago_s).toBeNull()
  })

  it('parses a populated keeper with all metadata', () => {
    const out = parseGateKeepersData({
      count: 1,
      keepers: [
        {
          name: 'planner',
          agent_name: 'planner',
          status: 'running',
          model: 'claude-opus-4-7',
          active_model: 'claude-opus-4-7',
          primary_model: 'claude-opus-4-7',
          keepalive_running: true,
          last_turn_ago_s: 42,
        },
      ],
    })
    expect(out.keepers[0]!.keepalive_running).toBe(true)
    expect(out.keepers[0]!.last_turn_ago_s).toBe(42)
  })

  it('drops entries without name (lenient-per-entry)', () => {
    const out = parseGateKeepersData({
      count: 2,
      keepers: [{ name: 'greeter' }, { status: 'orphan' }],
    })
    expect(out.keepers).toHaveLength(1)
    expect(out.keepers[0]!.name).toBe('greeter')
  })

  it('tolerates non-array keepers field by returning empty list', () => {
    const out = parseGateKeepersData({ count: 0, keepers: null })
    expect(out.keepers).toHaveLength(0)
  })

  it('defaults count to 0 when backend omits it', () => {
    const out = parseGateKeepersData({ keepers: [{ name: 'k1' }] })
    expect(out.count).toBe(0)
  })

  it('throws on non-object payload', () => {
    expect(() => parseGateKeepersData(null)).toThrow(GateKeepersSchemaDriftError)
    expect(() => parseGateKeepersData('oops')).toThrow(GateKeepersSchemaDriftError)
  })
})
