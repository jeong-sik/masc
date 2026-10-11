// Unsent composer drafts, owned by credential epoch and Keeper.
import { currentStoredTokenRevision } from './api/core'

const drafts = new Map<number, Map<string, string>>()

export function readKeeperDraft(keeperName: string, authRevision = currentStoredTokenRevision()): string {
  return drafts.get(authRevision)?.get(keeperName.trim()) ?? ''
}

export function writeKeeperDraft(keeperName: string, value: string, authRevision = currentStoredTokenRevision()): void {
  const key = keeperName.trim()
  if (!key) return
  if (value === '') {
    clearKeeperDraft(key, authRevision)
    return
  }
  let owned = drafts.get(authRevision)
  if (!owned) {
    owned = new Map()
    drafts.set(authRevision, owned)
  }
  owned.set(key, value)
}

export function clearKeeperDraft(keeperName: string, authRevision = currentStoredTokenRevision()): void {
  const owned = drafts.get(authRevision)
  owned?.delete(keeperName.trim())
  if (owned?.size === 0) drafts.delete(authRevision)
}

export function _draftCountForTests(): number {
  return [...drafts.values()].reduce((count, owned) => count + owned.size, 0)
}

export function _resetChatStoreForTests(): void {
  drafts.clear()
}
