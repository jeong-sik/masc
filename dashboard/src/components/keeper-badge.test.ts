import { describe, it, expect } from 'vitest'
import {
  kSlot,
  kSigil,
  KEEPER_REGISTRY,
  normalizeKeeperRegistry,
} from './keeper-badge'

interface TestMascWindow extends Window {
  MASC_DATA?: {
    keeper_registry?: unknown
    keeperRegistry?: unknown
  }
}

function withMascData(data: TestMascWindow['MASC_DATA'], fn: () => void) {
  const w = window as TestMascWindow
  const previous = w.MASC_DATA
  w.MASC_DATA = data
  try {
    fn()
  } finally {
    if (previous === undefined) {
      delete w.MASC_DATA
    } else {
      w.MASC_DATA = previous
    }
  }
}

describe('kSlot', () => {
  it('uses runtime keeper_registry overrides when present', () => {
    withMascData({ keeper_registry: { runtime_keeper: { slot: 7, sigil: 'RK' } } }, () => {
      expect(kSlot('runtime_keeper')).toBe(7)
    })
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
  it('uses runtime keeper_registry sigils when present', () => {
    withMascData({ keeper_registry: { runtime_keeper: { slot: 7, sigil: 'RK' } } }, () => {
      expect(kSigil('runtime_keeper')).toBe('RK')
    })
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

describe('normalizeKeeperRegistry', () => {
  it('keeps valid runtime entries and drops invalid entries', () => {
    expect(
      normalizeKeeperRegistry({
        good: { slot: 12, sigil: 'GK' },
        low: { slot: 0, sigil: 'LO' },
        high: { slot: 13, sigil: 'HI' },
        sigil: { slot: 1, sigil: '?' },
      }),
    ).toEqual({ good: { slot: 12, sigil: 'GK' } })
  })

  it('accepts camelCase runtime key for browser data', () => {
    withMascData({ keeperRegistry: { camel: { slot: 4, sigil: 'CM' } } }, () => {
      expect(kSlot('camel')).toBe(4)
      expect(kSigil('camel')).toBe('CM')
    })
  })
})

describe('KEEPER_REGISTRY', () => {
  it('ships with no baked-in keeper names', () => {
    expect(Object.keys(KEEPER_REGISTRY)).toHaveLength(0)
  })
})
