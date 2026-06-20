// Keeper chat input queue — messages typed while a keeper is still
// streaming, drained sequentially by the conversation panel.
//
// This module used to also hold a per-keeper ChatMessage buffer with
// localStorage persistence for the secondary KeeperChatPanel surface.
// That surface was unified into KeeperConversationPanel, whose state
// lives in the keeperThreads signal (keeper-state.ts) and is rehydrated
// from the server SSOT (.masc/keeper_chat/<name>.jsonl via
// GET /chat/history), so the duplicate client-side store was deleted.

import type { KeeperConversationAttachment } from './types'

export interface QueuedMessage {
  id: string
  content: string
  timestamp: number
  sent: boolean
  attachments?: KeeperConversationAttachment[]
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

/** Enqueue a message typed while the keeper is streaming. Attachments
 *  selected at enqueue time ride along so draining does not drop them. */
export function enqueueInput(
  keeperName: string,
  content: string,
  attachments?: KeeperConversationAttachment[],
  clientActionId?: string,
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
  updates: Partial<Pick<QueuedMessage, 'content' | 'attachments'>>,
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
}
