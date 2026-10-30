import { describe, expect, it } from 'vitest'

import type { KeeperConversationEntry } from '../../types'
import {
  entryTimestampMs,
  unreadDividerAnchorEntryId,
  unreadDividerAnchorKey,
} from './unread-divider'

// Minimal entry factory — only id/timestamp matter for divider placement.
function entry(id: string, timestamp: string | null): KeeperConversationEntry {
  return {
    id,
    role: 'assistant',
    source: 'direct_assistant',
    label: id,
    text: id,
    timestamp,
    delivery: 'history',
  } as KeeperConversationEntry
}

// Fixed cutoff of 1000s; entries below are "read", above are "unread".
const CURSOR = 1000
function iso(unix: number): string {
  return new Date(unix * 1000).toISOString()
}

describe('unreadDividerAnchorKey', () => {
  it('returns null when there is no cursor (non-keeper surfaces)', () => {
    expect(unreadDividerAnchorKey([{ key: 'a', tsMs: 2000_000 }], null)).toBeNull()
  })

  it('anchors before the first unread item when a read item precedes it', () => {
    const anchor = unreadDividerAnchorKey(
      [
        { key: 'read', tsMs: 900 * 1000 },
        { key: 'first-unread', tsMs: 1100 * 1000 },
        { key: 'later-unread', tsMs: 1200 * 1000 },
      ],
      CURSOR,
    )
    expect(anchor).toBe('first-unread')
  })

  it('skips null-ts items (live placeholders / checkpoints)', () => {
    const anchor = unreadDividerAnchorKey(
      [
        { key: 'read', tsMs: 900 * 1000 },
        { key: 'placeholder', tsMs: null },
        { key: 'first-unread', tsMs: 1100 * 1000 },
      ],
      CURSOR,
    )
    expect(anchor).toBe('first-unread')
  })

  it('returns null when the boundary was trimmed (first non-null item already unread)', () => {
    const anchor = unreadDividerAnchorKey(
      [
        { key: 'placeholder', tsMs: null },
        { key: 'oldest-visible', tsMs: 1100 * 1000 },
        { key: 'newer', tsMs: 1200 * 1000 },
      ],
      CURSOR,
    )
    expect(anchor).toBeNull()
  })

  it('returns null when every item is already read', () => {
    const anchor = unreadDividerAnchorKey(
      [
        { key: 'a', tsMs: 800 * 1000 },
        { key: 'b', tsMs: 900 * 1000 },
      ],
      CURSOR,
    )
    expect(anchor).toBeNull()
  })
})

describe('unreadDividerAnchorEntryId', () => {
  it('finds the first unread entry id in the normal case', () => {
    const entries = [
      entry('read', iso(900)),
      entry('unread', iso(1100)),
    ]
    expect(unreadDividerAnchorEntryId(entries, CURSOR)).toBe('unread')
  })

  it('yields no divider when the anchor was trimmed by the 200-row cap', () => {
    // The operator last saw ts=1000, but the oldest surviving row is 1100 —
    // every visible row is unread, so the read/unread boundary is above the
    // window and no divider should render.
    const entries = [
      entry('oldest-visible', iso(1100)),
      entry('newer', iso(1200)),
    ]
    expect(unreadDividerAnchorEntryId(entries, CURSOR)).toBeNull()
  })

  it('skips null-timestamp entries defensively', () => {
    const entries = [
      entry('read', iso(900)),
      entry('live-placeholder', null),
      entry('unread', iso(1100)),
    ]
    expect(unreadDividerAnchorEntryId(entries, CURSOR)).toBe('unread')
  })
})

describe('entryTimestampMs', () => {
  it('parses ISO timestamps and returns null for missing/invalid ones', () => {
    expect(entryTimestampMs({ timestamp: iso(1234) })).toBe(1234 * 1000)
    expect(entryTimestampMs({ timestamp: null })).toBeNull()
    expect(entryTimestampMs({ timestamp: 'garbage' })).toBeNull()
  })
})
