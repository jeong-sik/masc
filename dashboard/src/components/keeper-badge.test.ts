import { describe, it, expect } from 'vitest'
import { kSlot, kSigil, KEEPER_REGISTRY } from './keeper-badge'

describe('kSlot', () => {
  it('returns pinned slot for KEEPER_REGISTRY ids', () => {
    expect(kSlot('nick0cave')).toBe(3)
    expect(kSlot('masc-improver')).toBe(6)
    expect(kSlot('sangsu')).toBe(9)
    expect(kSlot('qa-king')).toBe(2)
    expect(kSlot('rama')).toBe(11)
  })

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
  it('returns pinned sigil for KEEPER_REGISTRY ids', () => {
    expect(kSigil('nick0cave')).toBe('NK')
    expect(kSigil('masc-improver')).toBe('MS')
    expect(kSigil('rama')).toBe('RM')
  })

  it('extracts first letter + first letter after hyphen for hyphenated ids', () => {
    expect(kSigil('foo-bar')).toBe('FB')
    expect(kSigil('alpha-beta-gamma')).toBe('AB')
  })

  it('falls back to first 2 letters for non-hyphenated ids', () => {
    expect(kSigil('codex')).toBe('CO')
    expect(kSigil('gemini')).toBe('GE')
  })

  it('uppercases lowercase ids', () => {
    expect(kSigil('alice')).toBe('AL')
  })

  it('strips non-alphanumeric chars before deriving', () => {
    expect(kSigil('ab.cd')).toBe('AB')
    expect(kSigil('foo!bar')).toBe('FO')
  })
})

describe('KEEPER_REGISTRY', () => {
  it('has 5 pinned canonical ids', () => {
    expect(Object.keys(KEEPER_REGISTRY)).toHaveLength(5)
  })

  it('all pinned slots are within 1..12', () => {
    for (const entry of Object.values(KEEPER_REGISTRY)) {
      expect(entry.slot).toBeGreaterThanOrEqual(1)
      expect(entry.slot).toBeLessThanOrEqual(12)
    }
  })

  it('all sigils are exactly 2 uppercase chars', () => {
    for (const entry of Object.values(KEEPER_REGISTRY)) {
      expect(entry.sigil).toMatch(/^[A-Z]{2}$/)
    }
  })

  it('all pinned slots are unique', () => {
    const slots = Object.values(KEEPER_REGISTRY).map((e) => e.slot)
    expect(new Set(slots).size).toBe(slots.length)
  })
})
