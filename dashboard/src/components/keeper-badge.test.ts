import { describe, it, expect } from 'vitest'
import { kSlot, kSigil } from './keeper-badge'

describe('kSlot', () => {
  it('returns deterministic slot 1..12 for unknown ids', () => {
    const slot = kSlot('unknown-keeper-7')
    expect(slot).toBeGreaterThanOrEqual(1)
    expect(slot).toBeLessThanOrEqual(12)
    expect(kSlot('unknown-keeper-7')).toBe(slot)
  })

  it('distributes 100 random ids across at least 8 of 12 slots', () => {
    const seen = new Set<number>()
    for (let i = 0; i < 100; i++) seen.add(kSlot(`id-${i}`))
    expect(seen.size).toBeGreaterThanOrEqual(8)
  })
})

describe('kSigil', () => {
  it('extracts first letter + first letter after hyphen for hyphenated ids', () => {
    expect(kSigil('foo-bar')).toBe('FB')
    expect(kSigil('alpha-beta-gamma')).toBe('AB')
  })

  it('falls back to first 2 letters for non-hyphenated ids', () => {
    expect(kSigil('agentcode')).toBe('AG')
    expect(kSigil('providerf')).toBe('PR')
  })

  it('uppercases lowercase ids', () => {
    expect(kSigil('alice')).toBe('AL')
  })

  it('strips non-alphanumeric chars before deriving', () => {
    expect(kSigil('ab.cd')).toBe('AB')
    expect(kSigil('foo!bar')).toBe('FO')
  })
})
