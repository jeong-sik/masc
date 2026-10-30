import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import {
  _clearKeeperLastSeenForTests,
  advanceKeeperLastSeen,
  conversationEntryUnix,
  getKeeperLastSeen,
  hydrateKeeperLastSeen,
  keeperLastSeen,
  newestConversationEntryUnix,
} from './keeper-last-seen'

const STORAGE_KEY = 'masc_keeper_chat_last_seen_v1'

describe('keeper last-seen cursor', () => {
  beforeEach(() => {
    window.localStorage.clear()
    _clearKeeperLastSeenForTests()
  })

  afterEach(() => {
    _clearKeeperLastSeenForTests()
    window.localStorage.clear()
  })

  it('advances monotonically and persists to localStorage', () => {
    advanceKeeperLastSeen('garnet', 1000)
    expect(getKeeperLastSeen('garnet')).toBe(1000)

    // A backward advance is a no-op — the operator cannot "un-see" a message.
    advanceKeeperLastSeen('garnet', 500)
    expect(getKeeperLastSeen('garnet')).toBe(1000)

    // A forward advance moves the cursor and rewrites storage.
    advanceKeeperLastSeen('garnet', 2000)
    expect(getKeeperLastSeen('garnet')).toBe(2000)

    const persisted = JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? '{}') as Record<string, number>
    expect(persisted).toEqual({ garnet: 2000 })
  })

  it('ignores non-finite / non-positive advances', () => {
    advanceKeeperLastSeen('echo', Number.NaN)
    advanceKeeperLastSeen('echo', Number.POSITIVE_INFINITY)
    advanceKeeperLastSeen('echo', 0)
    advanceKeeperLastSeen('echo', -5)
    expect(getKeeperLastSeen('echo')).toBeNull()
  })

  it('hydrates from localStorage and drops malformed values on read', () => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({
      garnet: 1234.5,
      zero_cursor: 0,
      negative_cursor: -5,
      stringy_cursor: 'nope',
      nullish_cursor: null,
    }))

    const hydrated = hydrateKeeperLastSeen()
    expect(hydrated).toEqual({ garnet: 1234.5 })
    expect(keeperLastSeen.value).toEqual({ garnet: 1234.5 })
    expect(getKeeperLastSeen('garnet')).toBe(1234.5)
    expect(getKeeperLastSeen('zero_cursor')).toBeNull()
    expect(getKeeperLastSeen('stringy_cursor')).toBeNull()
  })

  it('clears the signal and storage for tests', () => {
    advanceKeeperLastSeen('garnet', 1000)
    expect(window.localStorage.getItem(STORAGE_KEY)).not.toBeNull()
    _clearKeeperLastSeenForTests()
    expect(keeperLastSeen.value).toEqual({})
    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull()
  })

  it('converts entry ISO timestamps to unix seconds and finds the newest', () => {
    expect(conversationEntryUnix({ timestamp: '2026-07-02T00:00:00.000Z' })).toBe(
      Date.parse('2026-07-02T00:00:00.000Z') / 1000,
    )
    expect(conversationEntryUnix({ timestamp: null })).toBeNull()
    expect(conversationEntryUnix({ timestamp: 'not-a-date' })).toBeNull()

    const newest = newestConversationEntryUnix([
      { timestamp: '2026-07-01T00:00:00.000Z' },
      { timestamp: null },
      { timestamp: '2026-07-03T00:00:00.000Z' },
      { timestamp: '2026-07-02T00:00:00.000Z' },
    ])
    expect(newest).toBe(Date.parse('2026-07-03T00:00:00.000Z') / 1000)
    expect(newestConversationEntryUnix([{ timestamp: null }])).toBeNull()
    expect(newestConversationEntryUnix([])).toBeNull()
  })
})
