import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  PIN_CAP,
  clearPins,
  headPinnedKeeper,
  pinKeeper,
  pinnedKeepers,
  unpinKeeper,
} from './multi-keeper-pin-store'

beforeEach(() => {
  clearPins()
  vi.useFakeTimers()
  vi.setSystemTime(new Date('2026-05-06T00:00:00Z'))
})

afterEach(() => {
  clearPins()
  vi.useRealTimers()
})

describe('multi-keeper-pin-store', () => {
  it('starts empty with the configured cap', () => {
    expect(pinnedKeepers.value.entries).toHaveLength(0)
    expect(pinnedKeepers.value.cap).toBe(PIN_CAP)
    expect(headPinnedKeeper.value).toBeNull()
  })

  it('adds a single pin to the head', () => {
    pinKeeper('scholar', 42)
    expect(pinnedKeepers.value.entries).toHaveLength(1)
    expect(pinnedKeepers.value.entries[0]).toEqual({
      keeperName: 'scholar',
      pinnedAtMs: Date.now(),
      line: 42,
    })
    expect(headPinnedKeeper.value?.keeperName).toBe('scholar')
  })

  it('rejects empty / whitespace-only keeper names', () => {
    pinKeeper('')
    pinKeeper('   ')
    expect(pinnedKeepers.value.entries).toHaveLength(0)
  })

  it('trims keeper name on insertion', () => {
    pinKeeper('  brass-owl  ', 7)
    expect(pinnedKeepers.value.entries[0]?.keeperName).toBe('brass-owl')
  })

  it('inserts new pins at the head, preserving order otherwise', () => {
    pinKeeper('scholar', 1)
    vi.advanceTimersByTime(1000)
    pinKeeper('moth', 2)
    vi.advanceTimersByTime(1000)
    pinKeeper('luna', 3)

    const names = pinnedKeepers.value.entries.map(e => e.keeperName)
    expect(names).toEqual(['luna', 'moth', 'scholar'])
  })

  it('moves an existing pin to the head and refreshes timestamp + line', () => {
    pinKeeper('scholar', 1)
    vi.advanceTimersByTime(5_000)
    pinKeeper('moth', 2)
    vi.advanceTimersByTime(5_000)

    const before = pinnedKeepers.value.entries.find(e => e.keeperName === 'scholar')
    pinKeeper('scholar', 99)
    const after = pinnedKeepers.value.entries[0]

    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['scholar', 'moth'])
    expect(after?.line).toBe(99)
    expect(after?.pinnedAtMs).toBeGreaterThan(before?.pinnedAtMs ?? 0)
    // No duplicates introduced.
    const occurrences = pinnedKeepers.value.entries.filter(e => e.keeperName === 'scholar').length
    expect(occurrences).toBe(1)
  })

  it('drops the LRU (oldest) entry when the cap would be exceeded', () => {
    const names = ['a', 'b', 'c', 'd', 'e']
    names.forEach((name, idx) => {
      vi.setSystemTime(new Date(`2026-05-06T00:00:${String(idx).padStart(2, '0')}Z`))
      pinKeeper(name, idx)
    })

    expect(pinnedKeepers.value.entries).toHaveLength(PIN_CAP)
    // Oldest 'a' evicted; head is the most recently pinned 'e'.
    const remaining = pinnedKeepers.value.entries.map(e => e.keeperName)
    expect(remaining).toEqual(['e', 'd', 'c', 'b'])
    expect(remaining).not.toContain('a')
  })

  it('unpins a keeper without disturbing the others', () => {
    pinKeeper('a', 1)
    pinKeeper('b', 2)
    pinKeeper('c', 3)

    unpinKeeper('b')

    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['c', 'a'])
  })

  it('unpinKeeper is a no-op for unknown name and does not allocate a new state', () => {
    pinKeeper('a', 1)
    const stateBefore = pinnedKeepers.value
    unpinKeeper('does-not-exist')
    expect(pinnedKeepers.value).toBe(stateBefore)
  })

  it('clearPins drops every entry', () => {
    pinKeeper('a', 1)
    pinKeeper('b', 2)
    clearPins()
    expect(pinnedKeepers.value.entries).toHaveLength(0)
    expect(headPinnedKeeper.value).toBeNull()
  })

  it('clearPins is idempotent on an already-empty store', () => {
    const stateBefore = pinnedKeepers.value
    clearPins()
    expect(pinnedKeepers.value).toBe(stateBefore)
  })

  it('headPinnedKeeper tracks the latest pin reactively', () => {
    pinKeeper('a', 1)
    expect(headPinnedKeeper.value?.keeperName).toBe('a')
    pinKeeper('b', 2)
    expect(headPinnedKeeper.value?.keeperName).toBe('b')
    unpinKeeper('b')
    expect(headPinnedKeeper.value?.keeperName).toBe('a')
    clearPins()
    expect(headPinnedKeeper.value).toBeNull()
  })

  it('preserves source line as null when not provided', () => {
    pinKeeper('a')
    expect(pinnedKeepers.value.entries[0]?.line).toBeNull()
  })
})
