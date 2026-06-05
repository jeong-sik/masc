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

import { signal, type Signal } from '@preact/signals'

export type ChatMessageRole = 'user' | 'assistant'
export type ChatMessageSource = 'dashboard' | 'discord' | 'slack' | 'api'

export interface ChatMessage {
  role: ChatMessageRole
  content: string
  timestamp: number
  source?: ChatMessageSource
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

export function _resetChatStoreForTests(): void {
  _buffers.clear()
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
