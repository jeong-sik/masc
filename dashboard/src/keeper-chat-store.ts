// Keeper Chat Store — per-keeper message buffer with sessionStorage persistence.
//
// The web dashboard is one connector among many (Discord, Slack, etc.).
// All connectors share the same server-side history (keeper_chat_store.ml).
// This module provides the *local connector cache* so messages survive
// tab navigation and page refreshes without a server round-trip.
//
// Design constraints:
// - Server changes: zero.  All persistence is client-side.
// - useEffect: not used for data init.  External system sync only.
// - Component unmount: messages are preserved, not cleared.

export type ChatMessageRole = 'user' | 'assistant'
export type ChatMessageSource = 'dashboard' | 'discord' | 'slack' | 'api'

export interface Attachment {
  id: string
  type: 'image' | 'file'
  name: string
  size: number
  mimeType: string
  data: string
}

export interface ChatMessage {
  role: ChatMessageRole
  content: string
  timestamp: number
  source?: ChatMessageSource
  attachments?: Attachment[]
}

interface StoredSession {
  version: 1
  messages: ChatMessage[]
}

const STORAGE_VERSION = 1
const STORAGE_KEY_PREFIX = 'masc.keeper.chat.v1'

// --- In-memory buffer (survives component unmount) ---

const _buffers = new Map<string, ChatMessage[]>()

// --- sessionStorage helpers ---

function _storage(): Storage | null {
  if (typeof sessionStorage === 'undefined') return null
  try {
    return sessionStorage
  } catch {
    return null
  }
}

function _storageKey(keeperName: string): string {
  return `${STORAGE_KEY_PREFIX}.${keeperName}`
}

function _loadFromStorage(keeperName: string): ChatMessage[] {
  const storage = _storage()
  if (!storage) return []
  try {
    const raw = storage.getItem(_storageKey(keeperName))
    if (!raw) return []
    const parsed = JSON.parse(raw) as StoredSession
    if (parsed.version !== STORAGE_VERSION || !Array.isArray(parsed.messages)) {
      return []
    }
    return parsed.messages
  } catch {
    return []
  }
}

function _saveToStorage(keeperName: string, messages: ChatMessage[]): void {
  const storage = _storage()
  if (!storage) return
  try {
    const session: StoredSession = { version: STORAGE_VERSION, messages }
    storage.setItem(_storageKey(keeperName), JSON.stringify(session))
  } catch {
    // QuotaExceeded or private-mode failures are best-effort.
    // The in-memory buffer remains the source of truth for the session.
  }
}

function _removeFromStorage(keeperName: string): void {
  const storage = _storage()
  if (!storage) return
  try {
    storage.removeItem(_storageKey(keeperName))
  } catch {
    // Ignore
  }
}

// --- Buffer sync ---

function _sync(keeperName: string): void {
  const buf = _buffers.get(keeperName)
  if (buf) {
    _saveToStorage(keeperName, buf)
  }
}

// --- Public API ---

/** Return the message buffer for [keeperName], hydrating from sessionStorage
 *  if the in-memory buffer is empty.  Never returns a fresh array reference
 *  that would break signal reactivity — callers must mutate via store API. */
export function getChatMessageBuffer(keeperName: string): ChatMessage[] {
  let buf = _buffers.get(keeperName)
  if (!buf) {
    buf = _loadFromStorage(keeperName)
    _buffers.set(keeperName, buf)
  }
  return buf
}

/** Append a single message and persist. */
export function appendChatMessage(keeperName: string, message: ChatMessage): void {
  const buf = getChatMessageBuffer(keeperName)
  buf.push(message)
  _sync(keeperName)
}

/** Replace the entire buffer and persist. */
export function setChatMessages(keeperName: string, messages: ChatMessage[]): void {
  _buffers.set(keeperName, messages.slice())
  _sync(keeperName)
}

/** Clear both in-memory buffer and sessionStorage. */
export function clearChatMessages(keeperName: string): void {
  _buffers.delete(keeperName)
  _removeFromStorage(keeperName)
}

/** Merge server-fetched history with local buffer.
 *  Deduplication uses (role, timestamp, content) equality.
 *  Result is sorted by timestamp ascending. */
export function mergeServerHistory(
  keeperName: string,
  serverMessages: ChatMessage[],
): void {
  const local = getChatMessageBuffer(keeperName)
  const seen = new Set<string>()
  const merged: ChatMessage[] = []

  function key(m: ChatMessage): string {
    return `${m.role}:${m.timestamp}:${m.content}`
  }

  for (const m of local) {
    const k = key(m)
    if (!seen.has(k)) {
      seen.add(k)
      merged.push(m)
    }
  }

  for (const m of serverMessages) {
    const k = key(m)
    if (!seen.has(k)) {
      seen.add(k)
      merged.push(m)
    }
  }

  merged.sort((a, b) => a.timestamp - b.timestamp)
  setChatMessages(keeperName, merged)
}

/** Flush an incomplete streaming buffer as an assistant message.
 *  Call from component cleanup when a stream was in progress. */
export function flushStreamBuffer(keeperName: string, buffer: string): void {
  const text = buffer.trim()
  if (!text) return
  appendChatMessage(keeperName, {
    role: 'assistant',
    content: text,
    timestamp: Date.now(),
    source: 'dashboard',
  })
}

// --- Test helpers ---

// --- Input Queue (transient, not persisted) ---

export interface QueuedMessage {
  id: string
  content: string
  timestamp: number
  sent: boolean
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

/** Enqueue a message typed while the keeper is streaming. */
export function enqueueInput(keeperName: string, content: string): QueuedMessage {
  const q = _ensureQueue(keeperName)
  const msg: QueuedMessage = {
    id: `${keeperName}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    content,
    timestamp: Date.now(),
    sent: false,
  }
  q.items.push(msg)
  return msg
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

export function _resetChatStoreForTests(clearStorage = true): void {
  _buffers.clear()
  _queues.clear()
  if (!clearStorage) return
  const storage = _storage()
  if (!storage) return
  try {
    const keys: string[] = []
    for (let i = 0; i < storage.length; i++) {
      const k = storage.key(i)
      if (k?.startsWith(STORAGE_KEY_PREFIX)) keys.push(k)
    }
    for (const k of keys) storage.removeItem(k)
  } catch {
    // Ignore
  }
}
