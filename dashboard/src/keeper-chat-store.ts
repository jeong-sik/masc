// Keeper chat input queue — messages typed while a keeper is still
// streaming, drained sequentially by the conversation panel.
//
// This module used to also hold a per-keeper ChatMessage buffer with
// localStorage persistence for the secondary KeeperChatPanel surface.
// That surface was unified into KeeperConversationPanel, whose state
// lives in the keeperThreads signal (keeper-state.ts) and is rehydrated
// from the server SSOT (.masc/keeper_chat/<name>.jsonl via
// GET /chat/history), so the duplicate client-side store was deleted.

import type { ChatBlock, KeeperConversationAttachment, KeeperUserInputBlock } from './types'

export interface QueuedMessage {
  id: string
  content: string
  timestamp: number
  sent: boolean
  attachments?: KeeperConversationAttachment[]
  blocks?: ChatBlock[]
  userBlocks?: KeeperUserInputBlock[]
  clientActionId?: string
}

export interface InputQueue {
  items: QueuedMessage[]
  sending: boolean
}

const _queues = new Map<string, InputQueue>()

function _ensureQueue(keeperName: string): InputQueue {
  let q = _queues.get(keeperName)
  if (!q) {
    q = { items: [], sending: false }
    _queues.set(keeperName, q)
  }
  return q
}

// ── Per-keeper composer draft persistence ──────────────────────────────
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

/** Enqueue a message typed while the keeper is streaming. Attachments
 *  selected at enqueue time ride along so draining does not drop them. */
export function enqueueInput(
  keeperName: string,
  content: string,
  attachments?: KeeperConversationAttachment[],
  clientActionId?: string,
  blocks?: ChatBlock[],
  userBlocks?: KeeperUserInputBlock[],
): QueuedMessage {
  const q = _ensureQueue(keeperName)
  const actionId = clientActionId?.trim()
  if (actionId) {
    const existing = q.items.find(item => item.clientActionId === actionId)
    if (existing) return existing
  }
  const msg: QueuedMessage = {
    id: `${keeperName}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    content,
    timestamp: Date.now(),
    sent: false,
    ...(attachments && attachments.length > 0 ? { attachments } : {}),
    ...(blocks && blocks.length > 0 ? { blocks } : {}),
    ...(userBlocks && userBlocks.length > 0 ? { userBlocks } : {}),
    ...(actionId ? { clientActionId: actionId } : {}),
  }
  q.items.push(msg)
  return msg
}

export function hasQueuedInputClientAction(
  keeperName: string,
  clientActionId: string | undefined,
): boolean {
  const actionId = clientActionId?.trim()
  if (!actionId) return false
  const q = _queues.get(keeperName)
  return q ? q.items.some(item => item.clientActionId === actionId) : false
}

/** Return all queued items for a keeper (newest last). */
export function getQueuedMessages(keeperName: string): QueuedMessage[] {
  const q = _queues.get(keeperName)
  return q ? q.items.slice() : []
}

/** Update the content/attachments of a queued message. */
export function updateQueuedMessage(
  keeperName: string,
  id: string,
  updates: Partial<Pick<QueuedMessage, 'content' | 'attachments' | 'blocks' | 'userBlocks'>>,
): QueuedMessage | null {
  const q = _queues.get(keeperName)
  if (!q) return null
  const item = q.items.find(i => i.id === id)
  if (!item) return null
  let changed = false
  if (typeof updates.content === 'string') item.content = updates.content
  if (typeof updates.content === 'string') changed = true
  if ('attachments' in updates) {
    if (updates.attachments && updates.attachments.length > 0) {
      item.attachments = updates.attachments
    } else {
      delete item.attachments
    }
    changed = true
  }
  if (changed) delete item.clientActionId
  if (changed) {
    if ('blocks' in updates && updates.blocks && updates.blocks.length > 0) {
      item.blocks = updates.blocks
    } else {
      delete item.blocks
    }
    if ('userBlocks' in updates && updates.userBlocks && updates.userBlocks.length > 0) {
      item.userBlocks = updates.userBlocks
    } else {
      delete item.userBlocks
    }
  }
  return item
}

/** Remove a specific queued message. */
export function removeQueuedMessage(keeperName: string, id: string): boolean {
  const q = _queues.get(keeperName)
  if (!q) return false
  const before = q.items.length
  q.items = q.items.filter(i => i.id !== id)
  return q.items.length < before
}

/** Pop the front queued message. Returns null if empty or already sending. */
export function dequeueInput(keeperName: string): QueuedMessage | null {
  const q = _queues.get(keeperName)
  if (!q || q.sending || q.items.length === 0) return null
  q.sending = true
  const msg = q.items.shift()!
  return msg
}

/** Put an unsent/deferred message back at the front of the queue. */
export function requeueInputFront(keeperName: string, msg: QueuedMessage): void {
  const q = _ensureQueue(keeperName)
  q.sending = false
  if (q.items.some(item => item.id === msg.id)) return
  q.items.unshift({ ...msg, sent: false })
}

/** Mark the current sending item as done and clear the sending flag. */
export function markInputSent(keeperName: string): void {
  const q = _queues.get(keeperName)
  if (q) q.sending = false
}

/** Clear all queued items for a keeper. */
export function clearInputQueue(keeperName: string): void {
  _queues.delete(keeperName)
}

/** Number of items waiting (excluding the one currently being sent). */
export function getQueueLength(keeperName: string): number {
  const q = _queues.get(keeperName)
  return q ? q.items.length : 0
}

/** Total count including the item currently being sent. */
export function getQueueTotal(keeperName: string): number {
  const q = _queues.get(keeperName)
  if (!q) return 0
  return q.items.length + (q.sending ? 1 : 0)
}

export function _resetChatStoreForTests(): void {
  _queues.clear()
  _drafts.clear()
}
