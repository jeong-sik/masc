// Per-keeper composer draft persistence.
//
// Holds the unsent composer text per keeper. ChatComposer is keyed by
// keeper name (key=${keeperName}) and therefore remounts on a keeper
// switch; reading from this map on mount preserves a half-typed message,
// and — unlike the old single shared `draft` state on the panel — one
// keeper's text never leaks into another's composer (which previously
// risked sending to the wrong recipient). Plain Map, not a signal, so the
// per-keystroke write does not re-render the conversation panel.
const _drafts = new Map<string, string>()

/** Read the persisted unsent draft for a keeper ('' when none). */
export function readKeeperDraft(keeperName: string): string {
  return _drafts.get(keeperName.trim()) ?? ''
}

/** Persist the unsent draft for a keeper. An empty value deletes the entry
 *  so the map does not accumulate blank drafts after a send. */
export function writeKeeperDraft(keeperName: string, value: string): void {
  const key = keeperName.trim()
  if (!key) return
  if (value === '') _drafts.delete(key)
  else _drafts.set(key, value)
}

/** Drop a keeper's persisted draft. */
export function clearKeeperDraft(keeperName: string): void {
  _drafts.delete(keeperName.trim())
}

/** Test-only: number of persisted drafts. Lets a test observe that an empty
 *  write deletes the entry rather than storing a blank string (which
 *  readKeeperDraft cannot distinguish, since both read back as ''). */
export function _draftCountForTests(): number {
  return _drafts.size
}

export function _resetChatStoreForTests(): void {
  _drafts.clear()
}
