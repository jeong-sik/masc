import { describe, expect, it } from 'vitest'
import { KEEPER_RUNTIME_BLOCKER_CLASSES } from '../types'
import {
  asKeeperRuntimeBlockerClass,
  isKeeperRuntimeBlockerClass,
} from './runtime-blocker-class'

describe('asKeeperRuntimeBlockerClass', () => {
  it('accepts every literal listed in KEEPER_RUNTIME_BLOCKER_CLASSES (SSOT round-trip)', () => {
    for (const cls of KEEPER_RUNTIME_BLOCKER_CLASSES) {
      expect(asKeeperRuntimeBlockerClass(cls), `should accept ${cls}`).toBe(cls)
    }
  })

  it('rejects unknown strings — the over-permissive `as` cast trap is closed', () => {
    expect(asKeeperRuntimeBlockerClass('sdk_future_unmapped_variant')).toBeNull()
    expect(asKeeperRuntimeBlockerClass('typoed_blocker')).toBeNull()
    expect(asKeeperRuntimeBlockerClass('')).toBeNull()
  })

  it('rejects non-string values', () => {
    expect(asKeeperRuntimeBlockerClass(null)).toBeNull()
    expect(asKeeperRuntimeBlockerClass(undefined)).toBeNull()
    expect(asKeeperRuntimeBlockerClass(42)).toBeNull()
    expect(asKeeperRuntimeBlockerClass({})).toBeNull()
    expect(asKeeperRuntimeBlockerClass([])).toBeNull()
  })
})

describe('isKeeperRuntimeBlockerClass', () => {
  it('narrows known literals to KeeperRuntimeBlockerClass', () => {
    const candidate: string = 'cascade_exhausted'
    if (isKeeperRuntimeBlockerClass(candidate)) {
      const narrowed: typeof candidate = candidate
      expect(narrowed).toBe('cascade_exhausted')
    } else {
      throw new Error('expected narrowing to succeed')
    }
  })

  it('returns false for unknown strings', () => {
    expect(isKeeperRuntimeBlockerClass('not_in_set')).toBe(false)
  })
})
