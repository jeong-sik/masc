import { signal } from '@preact/signals'

// Minimal structural dependency (not the full MentionInboxRow from
// mention-inbox.ts) — this module only ever reads the timestamp, so it
// depends on exactly that, not the row's message/mentionTargets/isForMe
// fields. Any `MentionInboxModel['forMe']` row is assignable here.
export interface MentionTimestampRow {
  readonly timestampMs: number | null
}

// Board "mentions for me" unread cursor — single global watermark (unlike
// keeper-last-seen.ts's per-keeper map: there is exactly one operator-facing
// mention inbox, not one per surface). Storage/normalize conventions cloned
// from keeper-last-seen.ts (try/catch storage() wrapper, drop malformed
// values on read, monotonic forward-only advance, a _clear...ForTests reset).
//
// Unit is unix milliseconds, not seconds: MentionInboxRow.timestampMs (the
// only thing this cursor is ever compared against) is already `Date.parse`
// milliseconds, and unlike keeper-last-seen.ts there is no server-echoed
// since_unix contract to match — so no seconds conversion is introduced.

const STORAGE_KEY = 'masc_board_mentions_last_seen_v1'

function storage(): Storage | null {
  try {
    return typeof window === 'undefined' ? null : window.localStorage
  } catch {
    return null
  }
}

function readStored(): number {
  const store = storage()
  if (!store) return 0
  try {
    const raw = store.getItem(STORAGE_KEY)
    if (!raw) return 0
    const parsed = Number(raw)
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
  } catch {
    return 0
  }
}

function writeStored(value: number): void {
  const store = storage()
  if (!store) return
  try {
    if (value <= 0) {
      store.removeItem(STORAGE_KEY)
    } else {
      store.setItem(STORAGE_KEY, String(value))
    }
  } catch {
    // Best-effort persistence only; the in-memory signal remains authoritative
    // for this session even if localStorage is unavailable (private mode, quota).
  }
}

export const boardMentionsLastSeenMs = signal<number>(0)

/** Re-read the persisted cursor into the signal. Called once at module load;
 *  exposed so a cross-tab storage event (or a test) can re-hydrate on demand. */
export function hydrateBoardMentionsLastSeen(): number {
  const value = readStored()
  boardMentionsLastSeenMs.value = value
  return value
}

hydrateBoardMentionsLastSeen()

// Monotonic forward-only advance: the operator cannot "un-see" a mention, so
// the cursor never moves backwards. Writes to storage only when it actually
// advances.
export function advanceBoardMentionsLastSeen(unixMs: number): void {
  if (!Number.isFinite(unixMs) || unixMs <= 0) return
  if (boardMentionsLastSeenMs.value >= unixMs) return
  boardMentionsLastSeenMs.value = unixMs
  writeStored(unixMs)
}

/** Count of for-me mention rows newer than the last-seen cursor. `forMe` is
 *  `buildMentionInboxModel(...).forMe` — the exact rows the board's own
 *  MentionInboxPanel already renders, so this introduces no new data source. */
export function unseenMentionCount(forMe: readonly MentionTimestampRow[]): number {
  const cursor = boardMentionsLastSeenMs.value
  return forMe.filter(row => row.timestampMs !== null && row.timestampMs > cursor).length
}

/** Advance the cursor to the newest for-me mention currently known. Call on
 *  board-route visit (app.ts) — mirrors keeper-last-seen.ts's
 *  newestConversationEntryUnix + advance pairing. */
export function markBoardMentionsSeen(forMe: readonly MentionTimestampRow[]): void {
  let newest = 0
  for (const row of forMe) {
    if (row.timestampMs !== null && row.timestampMs > newest) newest = row.timestampMs
  }
  if (newest > 0) advanceBoardMentionsLastSeen(newest)
}

export function _clearBoardMentionsLastSeenForTests(): void {
  boardMentionsLastSeenMs.value = 0
  writeStored(0)
}
