import type { KeeperConversationEntry } from '../../types'

export const UNREAD_DIVIDER_LABEL = '여기까지 읽음'

// ISO timestamp -> ms, or null for rows with no observable position (live
// placeholders / checkpoints). Kept standalone so the divider logic is unit
// testable without pulling in the full chat primitive layer.
export function entryTimestampMs(entry: Pick<KeeperConversationEntry, 'timestamp'>): number | null {
  if (!entry.timestamp) return null
  const ms = Date.parse(entry.timestamp)
  return Number.isFinite(ms) ? ms : null
}

// Resolve the render key BEFORE which the "read up to here" divider should sit.
// - null unreadAfterTs (non-keeper surfaces) -> no divider.
// - null-ts items (placeholders/checkpoints) are skipped, never anchor.
// - The first item newer than the cursor anchors the divider, but only if a read
//   (<= cursor) item was seen first. If the very first non-null item is already
//   unread, the read/unread boundary was trimmed by the 200-row cap: no divider
//   (the digest card carries the true counts instead).
export function unreadDividerAnchorKey(
  items: readonly { key: string; tsMs: number | null }[],
  unreadAfterTs: number | null,
): string | null {
  if (unreadAfterTs === null) return null
  const cutoffMs = unreadAfterTs * 1000
  let seenReadItem = false
  for (const item of items) {
    if (item.tsMs === null) continue
    if (item.tsMs > cutoffMs) return seenReadItem ? item.key : null
    seenReadItem = true
  }
  return null
}

// Entry-level convenience: the anchor entry id, computed before render grouping.
// The render loop groups tool rows into units but a unit's representative ts is
// its first entry's ts, so the entry-level and unit-level anchors coincide.
export function unreadDividerAnchorEntryId(
  entries: readonly KeeperConversationEntry[],
  unreadAfterTs: number | null,
): string | null {
  return unreadDividerAnchorKey(
    entries.map(entry => ({ key: entry.id, tsMs: entryTimestampMs(entry) })),
    unreadAfterTs,
  )
}
