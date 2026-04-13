import { describe, expect, it } from 'vitest'
import { topKeepers } from './oas-health-chip'
import type { OasKeeperSnapshot } from '../types/oas'

function snap(name: string, ts: number, extras: Partial<OasKeeperSnapshot> = {}): OasKeeperSnapshot {
  return {
    keeper_name: name,
    generation: 1,
    context_ratio: 0.1,
    message_count: 0,
    timestamp: ts,
    ...extras,
  }
}

describe('topKeepers', () => {
  it('returns keepers sorted by timestamp descending', () => {
    const map = new Map<string, OasKeeperSnapshot>([
      ['a', snap('a', 100)],
      ['b', snap('b', 300)],
      ['c', snap('c', 200)],
    ])
    const result = topKeepers(map, 10)
    expect(result.map(k => k.keeper_name)).toEqual(['b', 'c', 'a'])
  })

  it('clamps to limit', () => {
    const map = new Map<string, OasKeeperSnapshot>([
      ['a', snap('a', 1)],
      ['b', snap('b', 2)],
      ['c', snap('c', 3)],
      ['d', snap('d', 4)],
    ])
    expect(topKeepers(map, 2)).toHaveLength(2)
    expect(topKeepers(map, 2).map(k => k.keeper_name)).toEqual(['d', 'c'])
  })

  it('returns empty for empty map', () => {
    expect(topKeepers(new Map(), 3)).toEqual([])
  })

  it('returns all when limit exceeds size', () => {
    const map = new Map<string, OasKeeperSnapshot>([
      ['only', snap('only', 42)],
    ])
    expect(topKeepers(map, 10)).toHaveLength(1)
  })
})
