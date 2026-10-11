// Canonical unsent authored input, owned by credential epoch and Keeper.
import { signal, type Signal } from '@preact/signals'
import { currentStoredTokenRevision } from './api/core'
import type { KeeperConversationAttachment } from './types'

export interface KeeperDraftSnapshot {
  readonly revision: number
  readonly pendingFiles: readonly symbol[]
  readonly text: string
  readonly attachments: readonly KeeperConversationAttachment[]
  readonly voiceDraft: { readonly transcript: string } | null
}
const emptyDraft: KeeperDraftSnapshot = Object.freeze({ revision: 0, pendingFiles: Object.freeze([]), text: '', attachments: Object.freeze([]), voiceDraft: null })
const drafts = new Map<number, Map<string, Signal<KeeperDraftSnapshot>>>()

function ownedDraft(keeperName: string, authRevision: number): Signal<KeeperDraftSnapshot> {
  let owned = drafts.get(authRevision)
  if (!owned) {
    owned = new Map()
    drafts.set(authRevision, owned)
  }
  let draft = owned.get(keeperName)
  if (!draft) {
    draft = signal(emptyDraft)
    owned.set(keeperName, draft)
  }
  return draft
}

export function readKeeperDraftSnapshot(keeperName: string, authRevision = currentStoredTokenRevision()): KeeperDraftSnapshot {
  const key = keeperName.trim()
  return key ? ownedDraft(key, authRevision).value : emptyDraft
}

export function readKeeperDraft(keeperName: string, authRevision = currentStoredTokenRevision()): string {
  return readKeeperDraftSnapshot(keeperName, authRevision).text
}

export function updateKeeperDraft(
  keeperName: string,
  update: (draft: KeeperDraftSnapshot) => Omit<KeeperDraftSnapshot, 'revision'>,
  authRevision = currentStoredTokenRevision(),
): void {
  const key = keeperName.trim()
  if (!key) return
  const draft = ownedDraft(key, authRevision)
  const previous = draft.peek()
  const next = update(previous)
  draft.value = Object.freeze({
    revision: previous.revision + 1,
    pendingFiles: Object.freeze([...next.pendingFiles]),
    text: next.text,
    attachments: Object.freeze(next.attachments.map(attachment => Object.freeze({ ...attachment }))),
    voiceDraft: next.voiceDraft ? Object.freeze({ ...next.voiceDraft }) : null,
  })
}

export function writeKeeperDraft(keeperName: string, text: string, authRevision = currentStoredTokenRevision()): void {
  updateKeeperDraft(keeperName, draft => ({ ...draft, text }), authRevision)
}

export function clearKeeperDraft(keeperName: string, authRevision = currentStoredTokenRevision(), expectedRevision?: number, content: 'text' | 'all' = 'all'): boolean {
  const draft = drafts.get(authRevision)?.get(keeperName.trim())
  if (!draft || (content === 'all' && draft.peek().pendingFiles.length > 0) || (expectedRevision !== undefined && draft.peek().revision !== expectedRevision)) return false
  const current = draft.peek()
  draft.value = Object.freeze({ ...(content === 'text' ? current : emptyDraft), text: '', revision: current.revision + 1 })
  return true
}

export function _resetChatStoreForTests(): void {
  drafts.clear()
}
