import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  PIN_CAP,
  clearPins,
  headPinnedKeeper,
  pinKeeper,
  pinnedKeepers,
  promotePinAt,
  reorderPins,
  unpinHead,
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

describe('multi-keeper-pin-store — reorderPins', () => {
  function seed4(): void {
    pinKeeper('a', 1)
    pinKeeper('b', 2)
    pinKeeper('c', 3)
    pinKeeper('d', 4)
    // After 4 inserts, head-promote ordering yields: ['d','c','b','a']
  }

  it('moves a middle entry to the head', () => {
    seed4()
    reorderPins('b', 0)
    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['b', 'd', 'c', 'a'])
  })

  it('moves the head to the tail', () => {
    seed4()
    reorderPins('d', 3)
    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['c', 'b', 'a', 'd'])
  })

  it('preserves pinnedAtMs and line on the moved entry (NOT a fresh pin)', () => {
    pinKeeper('a', 11)
    vi.advanceTimersByTime(5_000)
    pinKeeper('b', 22)
    const aBefore = pinnedKeepers.value.entries.find(e => e.keeperName === 'a')!
    reorderPins('a', 0)
    const aAfter = pinnedKeepers.value.entries[0]!
    expect(aAfter.keeperName).toBe('a')
    expect(aAfter.pinnedAtMs).toBe(aBefore.pinnedAtMs) // timestamp unchanged
    expect(aAfter.line).toBe(11)                         // line unchanged
  })

  it('is a no-op when fromName is not pinned', () => {
    seed4()
    const before = pinnedKeepers.value
    reorderPins('not-here', 0)
    expect(pinnedKeepers.value).toBe(before) // identity-preserved (no allocation)
  })

  it('is a no-op when fromIdx === clampedTo', () => {
    seed4()
    const before = pinnedKeepers.value
    // 'd' is at idx 0; reorder to 0 → no-op.
    reorderPins('d', 0)
    expect(pinnedKeepers.value).toBe(before)
  })

  it('clamps toIdx to the upper bound (entries.length - 1)', () => {
    seed4()
    reorderPins('d', 999)
    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['c', 'b', 'a', 'd'])
  })

  it('clamps toIdx to 0 when negative', () => {
    seed4()
    reorderPins('a', -3)
    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['a', 'd', 'c', 'b'])
  })

  it('rejects empty / whitespace fromName', () => {
    seed4()
    const before = pinnedKeepers.value
    reorderPins('', 0)
    reorderPins('   ', 1)
    expect(pinnedKeepers.value).toBe(before)
  })

  it('preserves the cap (does not change entries.length)', () => {
    seed4()
    expect(pinnedKeepers.value.entries.length).toBe(PIN_CAP)
    reorderPins('a', 0)
    expect(pinnedKeepers.value.entries.length).toBe(PIN_CAP)
    reorderPins('c', 3)
    expect(pinnedKeepers.value.entries.length).toBe(PIN_CAP)
  })
})

describe('multi-keeper-pin-store — promotePinAt keyboard shortcut', () => {
  function seed4(): void {
    pinKeeper('a')
    pinKeeper('b')
    pinKeeper('c')
    pinKeeper('d')
    // pinKeeper inserts at head, so post-seed order is [d, c, b, a].
  }

  it('promotePinAt(2) moves the slot-2 entry to head', () => {
    seed4()
    promotePinAt(2)
    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['c', 'd', 'b', 'a'])
  })

  it('promotePinAt(4) moves the slot-4 entry to head', () => {
    seed4()
    promotePinAt(4)
    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['a', 'd', 'c', 'b'])
  })

  it('promotePinAt(1) is a no-op (already head)', () => {
    seed4()
    const before = pinnedKeepers.value
    promotePinAt(1)
    expect(pinnedKeepers.value).toBe(before)
  })

  it('promotePinAt(0) is a no-op (1-indexed; idx<1 rejected)', () => {
    seed4()
    const before = pinnedKeepers.value
    promotePinAt(0)
    expect(pinnedKeepers.value).toBe(before)
  })

  it('promotePinAt(idx > entries.length) is a no-op', () => {
    seed4()
    const before = pinnedKeepers.value
    promotePinAt(5)
    promotePinAt(99)
    expect(pinnedKeepers.value).toBe(before)
  })

  it('promotePinAt preserves pinnedAtMs (position-only, not fresh pin)', () => {
    seed4()
    const slot2Before = pinnedKeepers.value.entries[1]!
    const tsBefore = slot2Before.pinnedAtMs
    vi.advanceTimersByTime(120000)
    promotePinAt(2)
    const head = pinnedKeepers.value.entries[0]!
    expect(head.keeperName).toBe(slot2Before.keeperName)
    expect(head.pinnedAtMs).toBe(tsBefore)
  })

  it('promotePinAt is a no-op on empty pin list', () => {
    const before = pinnedKeepers.value
    promotePinAt(1)
    promotePinAt(2)
    expect(pinnedKeepers.value).toBe(before)
  })
})

describe('multi-keeper-pin-store — unpinHead keyboard shortcut', () => {
  it('removes the head entry, leaving the rest in order', () => {
    pinKeeper('a')
    pinKeeper('b')
    pinKeeper('c')
    // order = [c, b, a]
    unpinHead()
    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['b', 'a'])
  })

  it('updates headPinnedKeeper to the new head', () => {
    pinKeeper('a')
    pinKeeper('b')
    expect(headPinnedKeeper.value?.keeperName).toBe('b')
    unpinHead()
    expect(headPinnedKeeper.value?.keeperName).toBe('a')
  })

  it('is a no-op when nothing is pinned', () => {
    const before = pinnedKeepers.value
    unpinHead()
    expect(pinnedKeepers.value).toBe(before)
  })

  it('clears the collection when called repeatedly', () => {
    pinKeeper('a')
    pinKeeper('b')
    unpinHead()
    unpinHead()
    expect(pinnedKeepers.value.entries.length).toBe(0)
    expect(headPinnedKeeper.value).toBeNull()
  })
})
