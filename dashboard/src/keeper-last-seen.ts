import { signal } from '@preact/signals'
import type { KeeperConversationEntry } from './types'

// Per-keeper "last-seen" cursor. The stored value is the newest chat entry
// `ts` (unix seconds) the operator has actually observed in that keeper's
// transcript — NOT wall-clock time. Anchoring on the entry ts (rather than
// Date.now()) keeps the cursor immune to client/server clock skew and makes
// the since-last-seen digest deterministic: the server echoes the same
// since_unix it was queried with.
//
// Storage/normalize conventions are cloned from keeper-chat-pending.ts
// (try/catch storage() wrapper, normalize-on-read dropping malformed values,
// a _clear...ForTests reset). The reactive signal is the render source of
// truth; localStorage is the durability layer.

const STORAGE_KEY = 'masc_keeper_chat_last_seen_v1'

function storage(): Storage | null {
  try {
    return typeof window === 'undefined' ? null : window.localStorage
  } catch {
    return null
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

// Drop any entry whose value is not a finite, positive unix timestamp. A
// non-finite or non-positive cursor cannot describe a real observed entry, so
// treating it as "unseen" is safer than persisting garbage.
function normalizeLastSeen(raw: unknown): Record<string, number> {
  if (!isRecord(raw)) return {}
  const out: Record<string, number> = {}
  for (const [key, value] of Object.entries(raw)) {
    const name = key.trim()
    if (!name) continue
    if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
      out[name] = value
    }
  }
  return out
}

function readAll(): Record<string, number> {
  const store = storage()
  if (!store) return {}
  try {
    const raw = store.getItem(STORAGE_KEY)
    if (!raw) return {}
    return normalizeLastSeen(JSON.parse(raw) as unknown)
  } catch {
    return {}
  }
}

function writeAll(record: Record<string, number>): void {
  const store = storage()
  if (!store) return
  try {
    if (Object.keys(record).length === 0) {
      store.removeItem(STORAGE_KEY)
    } else {
      store.setItem(STORAGE_KEY, JSON.stringify(record))
    }
  } catch {
    // Best-effort persistence only; the in-memory signal remains authoritative
    // for this session even if localStorage is unavailable (private mode, quota).
  }
}

export const keeperLastSeen = signal<Record<string, number>>({})

// Re-read the persisted cursor map into the signal, normalizing away malformed
// values. Called once at module load; exposed so a cross-tab/storage event (or a
// test) can re-hydrate the in-memory signal from localStorage on demand.
export function hydrateKeeperLastSeen(): Record<string, number> {
  const record = readAll()
  keeperLastSeen.value = record
  return record
}

hydrateKeeperLastSeen()

export function getKeeperLastSeen(keeperName: string): number | null {
  const name = keeperName.trim()
  if (!name) return null
  const value = keeperLastSeen.value[name]
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

// Monotonic forward-only advance: the operator cannot "un-see" a message, so a
// cursor never moves backwards. Writes to localStorage only when it actually
// advances, so pinned-transcript churn does not thrash storage.
export function advanceKeeperLastSeen(keeperName: string, entryUnixTs: number): void {
  const name = keeperName.trim()
  if (!name || !Number.isFinite(entryUnixTs) || entryUnixTs <= 0) return
  const current = keeperLastSeen.value[name]
  if (typeof current === 'number' && current >= entryUnixTs) return
  const next = { ...keeperLastSeen.value, [name]: entryUnixTs }
  keeperLastSeen.value = next
  writeAll(next)
}

// Convert a rendered conversation entry's ISO timestamp to the unix-seconds unit
// the cursor stores. Null-timestamp rows (live placeholders, checkpoints) have
// no observable position and return null.
export function conversationEntryUnix(
  entry: Pick<KeeperConversationEntry, 'timestamp'>,
): number | null {
  if (!entry.timestamp) return null
  const ms = Date.parse(entry.timestamp)
  return Number.isFinite(ms) ? ms / 1000 : null
}

export function newestConversationEntryUnix(
  entries: readonly Pick<KeeperConversationEntry, 'timestamp'>[],
): number | null {
  let newest: number | null = null
  for (const entry of entries) {
    const unix = conversationEntryUnix(entry)
    if (unix === null) continue
    if (newest === null || unix > newest) newest = unix
  }
  return newest
}

export function _clearKeeperLastSeenForTests(): void {
  keeperLastSeen.value = {}
  writeAll({})
}
