// Tab-scoped bearer credentials used by the dashboard shell and API clients.
import { setCanonicalDashboardActor } from './dashboard-session-actor'

const TOKEN_STORAGE_KEY = 'masc_bearer_token'
const TOKEN_META_STORAGE_KEY = 'masc_bearer_token_meta'

export type StoredTokenMeta =
  | { source: 'dev'; actor: 'dashboard'; role: 'admin' }
  | { source: 'manual' }
  | { source: 'url' }

export interface StoredTokenChange {
  token: string | null
  meta: StoredTokenMeta | null
}

type StoredTokenChangeListener = (change: StoredTokenChange) => void

const storedTokenChangeListeners = new Set<StoredTokenChangeListener>()
let storedTokenRevision = 0

function notifyStoredTokenChange(change: StoredTokenChange): void {
  storedTokenRevision += 1
  for (const listener of storedTokenChangeListeners) {
    try {
      listener(change)
    } catch (err) {
      console.warn('[dashboard-auth] token change listener failed', err)
    }
  }
}

export function currentStoredTokenRevision(): number {
  return storedTokenRevision
}

export function subscribeStoredTokenChanges(
  listener: StoredTokenChangeListener,
): () => void {
  storedTokenChangeListeners.add(listener)
  return () => {
    storedTokenChangeListeners.delete(listener)
  }
}

function normalizeStoredTokenMeta(value: unknown): StoredTokenMeta | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null
  const record = value as Record<string, unknown>
  if (record.source === 'manual') return { source: 'manual' }
  if (record.source === 'url') return { source: 'url' }
  if (
    record.source === 'dev'
    && record.actor === 'dashboard'
    && record.role === 'admin'
  ) {
    return { source: 'dev', actor: 'dashboard', role: 'admin' }
  }
  // A stored 'worker' dev meta from an older build parses as null, which
  // shouldRefreshDevToken treats as "re-bootstrap" — the migration is a
  // single silent re-fetch.
  return null
}

function storedTokenMetaEquals(
  left: StoredTokenMeta | null,
  right: StoredTokenMeta | null,
): boolean {
  if (left === null || right === null) return left === right
  if (left.source !== right.source) return false
  if (left.source !== 'dev' || right.source !== 'dev') return true
  return left.actor === right.actor && left.role === right.role
}

/**
 * Extracts `?token=<bearer>` emitted by `masc login` (`MASC_DASHBOARD_URL`),
 * strips `token` from the URL bar/history via `history.replaceState`, and
 * returns the trimmed token (or null if absent/empty).
 */
export function consumeUrlBearerToken(): string | null {
  try {
    if (typeof window === 'undefined' || !window.location) return null
    const params = new URLSearchParams(window.location.search)
    if (!params.has('token')) return null
    const raw = params.get('token')
    const normalized = typeof raw === 'string' && raw.trim().length > 0 ? raw.trim() : null
    params.delete('token')
    const cleaned = params.toString()
    const nextUrl = window.location.pathname + (cleaned ? `?${cleaned}` : '') + window.location.hash
    if (typeof window.history?.replaceState === 'function') {
      window.history.replaceState(null, '', nextUrl)
    }
    return normalized
  } catch {
    return null
  }
}

export function getStoredToken(): string | null {
  try {
    const token = sessionStorage.getItem(TOKEN_STORAGE_KEY)
    return typeof token === 'string' && token.trim() !== '' ? token : null
  } catch {
    return null
  }
}

export function getStoredTokenMeta(): StoredTokenMeta | null {
  try {
    const raw = sessionStorage.getItem(TOKEN_META_STORAGE_KEY)
    if (!raw) return null
    return normalizeStoredTokenMeta(JSON.parse(raw))
  } catch {
    return null
  }
}

export function setStoredToken(
  token: string,
  meta: StoredTokenMeta = { source: 'manual' },
): void {
  const normalizedToken = token.trim()
  if (!normalizedToken) {
    clearStoredToken()
    return
  }
  const previousToken = getStoredToken()
  const previousMeta = getStoredTokenMeta()
  const nextMeta = normalizeStoredTokenMeta(meta)
  sessionStorage.setItem(TOKEN_STORAGE_KEY, normalizedToken)
  if (nextMeta) {
    sessionStorage.setItem(TOKEN_META_STORAGE_KEY, JSON.stringify(nextMeta))
  } else {
    sessionStorage.removeItem(TOKEN_META_STORAGE_KEY)
  }
  setCanonicalDashboardActor(null)
  if (previousToken !== normalizedToken || !storedTokenMetaEquals(previousMeta, nextMeta)) {
    notifyStoredTokenChange({
      token: normalizedToken,
      meta: nextMeta,
    })
  }
}

export function clearStoredToken(): void {
  const previousToken = getStoredToken()
  const previousMeta = getStoredTokenMeta()
  sessionStorage.removeItem(TOKEN_STORAGE_KEY)
  sessionStorage.removeItem(TOKEN_META_STORAGE_KEY)
  setCanonicalDashboardActor(null)
  if (previousToken !== null || previousMeta !== null) {
    notifyStoredTokenChange({
      token: null,
      meta: null,
    })
  }
}
