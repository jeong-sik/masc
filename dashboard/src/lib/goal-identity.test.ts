import { describe, expect, it } from 'vitest'
import { exactGoalId, exactGoalIds, goalIdComparisonKey, isCanonicalGoalId, isUnambiguousGoalId, nonblankGoalId, observeGoalIds } from './goal-identity'

describe('Goal identity', () => {
  it('preserves raw IDs without turning non-strings into identity', () => {
    expect(exactGoalId(' goal ')).toBe(' goal ')
    expect(exactGoalId('\u00a0')).toBe('\u00a0')
    expect(exactGoalId(42)).toBeUndefined()
    expect(exactGoalIds([' goal ', '\u00a0', '', 42])).toEqual([' goal ', '\u00a0'])
  })
  it.each([' ', '\t', '\n', '\r', '\f'])('treats boundary %j like OCaml String.trim', space => {
    expect(goalIdComparisonKey(`${space}goal${space}`)).toBe('goal')
    expect(isCanonicalGoalId(`${space}goal`)).toBe(false)
    expect(isCanonicalGoalId(space)).toBe(false)
  })

  it('preserves other characters even when JavaScript trim would remove them', () => {
    for (const id of ['\u00a0goal\u00a0', '\u000bgoal\u000b']) {
      expect(goalIdComparisonKey(id)).toBe(id)
      expect(isCanonicalGoalId(id)).toBe(true)
    }
    expect(isCanonicalGoalId('')).toBe(false)
  })

  it('rejects only an OCaml-blank observed ID without changing nonblank IDs', () => {
    expect(nonblankGoalId(' \t\n')).toBeUndefined()
    expect(nonblankGoalId('\u00a0')).toBe('\u00a0')
    expect(nonblankGoalId(' goal ')).toBe(' goal ')
  })

  it('refuses observed duplicates and padded aliases while allowing unrelated IDs', () => {
    const ids = ['goal-a', ' goal-a ', 'goal-b', 'goal-c', 'goal-c']
    expect(isUnambiguousGoalId('goal-a', ids)).toBe(false)
    expect(isUnambiguousGoalId(' goal-a ', ids)).toBe(false)
    expect(isUnambiguousGoalId('goal-b', ids)).toBe(true)
    expect(isUnambiguousGoalId('goal-c', ids)).toBe(false)
    expect(isUnambiguousGoalId('missing', ids)).toBe(false)
  })

  it('records IDs before display decoding and refuses incomplete identity observations', () => {
    expect(observeGoalIds([{ id: 'a' }, { id: 'a', title: '' }, { id: 'b', children: [{ id: 'c' }] }], true))
      .toEqual({ ids: ['a', 'a', 'b', 'c'], complete: true })
    expect(observeGoalIds([{ id: 'a' }, { title: 'unknown ID' }])).toEqual({ ids: ['a'], complete: false })
    expect(observeGoalIds([{ id: 'a', children: 'invalid' }], true)).toEqual({ ids: ['a'], complete: false })
  })
})
