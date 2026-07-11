import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import {
  _clearBoardMentionsLastSeenForTests,
  advanceBoardMentionsLastSeen,
  boardMentionsLastSeenMs,
  hydrateBoardMentionsLastSeen,
  markBoardMentionsSeen,
  unseenMentionCount,
  type MentionTimestampRow,
} from './board-mentions-last-seen'

const STORAGE_KEY = 'masc_board_mentions_last_seen_v1'

function row(timestampMs: number | null): MentionTimestampRow {
  return { timestampMs }
}

describe('board mentions last-seen cursor', () => {
  beforeEach(() => {
    window.localStorage.clear()
    _clearBoardMentionsLastSeenForTests()
  })

  afterEach(() => {
    _clearBoardMentionsLastSeenForTests()
    window.localStorage.clear()
  })

  it('advances monotonically and persists to localStorage', () => {
    advanceBoardMentionsLastSeen(1000)
    expect(boardMentionsLastSeenMs.value).toBe(1000)

    // A backward advance is a no-op — the operator cannot "un-see" a mention.
    advanceBoardMentionsLastSeen(500)
    expect(boardMentionsLastSeenMs.value).toBe(1000)

    // A forward advance moves the cursor and rewrites storage.
    advanceBoardMentionsLastSeen(2000)
    expect(boardMentionsLastSeenMs.value).toBe(2000)
    expect(window.localStorage.getItem(STORAGE_KEY)).toBe('2000')
  })

  it('ignores non-finite / non-positive advances', () => {
    advanceBoardMentionsLastSeen(Number.NaN)
    advanceBoardMentionsLastSeen(Number.POSITIVE_INFINITY)
    advanceBoardMentionsLastSeen(0)
    advanceBoardMentionsLastSeen(-5)
    expect(boardMentionsLastSeenMs.value).toBe(0)
  })

  it('hydrates from localStorage and drops malformed values on read', () => {
    window.localStorage.setItem(STORAGE_KEY, 'not-a-number')
    expect(hydrateBoardMentionsLastSeen()).toBe(0)

    window.localStorage.setItem(STORAGE_KEY, '1234')
    expect(hydrateBoardMentionsLastSeen()).toBe(1234)
    expect(boardMentionsLastSeenMs.value).toBe(1234)
  })

  it('clears the signal and storage for tests', () => {
    advanceBoardMentionsLastSeen(1000)
    expect(window.localStorage.getItem(STORAGE_KEY)).not.toBeNull()
    _clearBoardMentionsLastSeenForTests()
    expect(boardMentionsLastSeenMs.value).toBe(0)
    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull()
  })

  it('counts for-me rows newer than the cursor, ignoring null timestamps', () => {
    advanceBoardMentionsLastSeen(1000)
    const rows = [row(500), row(null), row(1500), row(2000)]
    expect(unseenMentionCount(rows)).toBe(2)
  })

  it('marks seen by advancing the cursor to the newest known row', () => {
    const rows = [row(500), row(1500), row(null), row(2000)]
    expect(unseenMentionCount(rows)).toBe(3)
    markBoardMentionsSeen(rows)
    expect(boardMentionsLastSeenMs.value).toBe(2000)
    expect(unseenMentionCount(rows)).toBe(0)
  })

  it('marking seen with no rows is a no-op (never regresses the cursor)', () => {
    advanceBoardMentionsLastSeen(1000)
    markBoardMentionsSeen([])
    expect(boardMentionsLastSeenMs.value).toBe(1000)
  })
})
