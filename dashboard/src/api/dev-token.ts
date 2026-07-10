import { signal, type ReadonlySignal } from '@preact/signals'
import {
  clearStoredToken,
  currentDashboardActor,
  fetchWithTimeout,
  getStoredToken,
  getStoredTokenMeta,
  isRemoteAccess,
  setStoredToken,
} from './core'

const DEV_TOKEN_FETCH_TIMEOUT_MS = 3000

let devTokenBootstrapPromise: Promise<void> | null = null

/**
 * Tracks the outcome of the loopback dev-token bootstrap so the UI can
 * distinguish "auth required but no token" from "network error" etc.
 *   idle       — not yet attempted
 *   fetching   — in-flight
 *   ok         — token stored
 *   no_endpoint — /dev-token returned 404 (loopback disabled or strict auth)
 *   network    — fetch threw (server down, CORS, DNS)
 */
export type DevTokenBootstrapStatus =
  | 'idle'
  | 'fetching'
  | 'ok'
  | 'no_endpoint'
  | 'network'

export const devTokenBootstrapStatus: ReadonlySignal<DevTokenBootstrapStatus> =
  signal<DevTokenBootstrapStatus>('idle')

interface DevTokenBootstrapPayload {
  token?: unknown
  actor?: unknown
  scope?: unknown
}

function isRetryableDevTokenStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500
}

function shouldRefreshDevToken(): boolean {
  const token = getStoredToken()
  const meta = getStoredTokenMeta()
  if (!token) return true
  if (meta?.source === 'dev') return true
  // A manually-pasted token should never be silently overwritten by the
  // loopback dev-token bootstrapper.  (Issue: token appeared reset after
  // page refresh because ensureDevToken() re-fetched and replaced it.)
  if (meta?.source === 'manual') return false
  const actor = currentDashboardActor()
  if (isRemoteAccess() || actor !== 'dashboard') return false
  // Loopback dashboard sessions should self-heal if they are still holding
  // a borrowed non-dashboard token (for example an old MCP-client paste).
  return meta == null || meta.actor == null || meta.actor !== actor
}

/** Fetch the loopback-only dev token once per page load and stash it so
    subsequent `/mcp` requests include `Authorization: Bearer ...`. The server
    only exposes `/api/v1/dashboard/dev-token` when bound to loopback with
    strict-auth overrides disabled; in every other case this quietly no-ops
    and manually supplied credentials remain untouched. */
export async function ensureDevToken(): Promise<void> {
  if (!shouldRefreshDevToken()) return
  if (devTokenBootstrapPromise) return devTokenBootstrapPromise
  devTokenBootstrapPromise = (async () => {
    const storedMeta = getStoredTokenMeta()
    const storedToken = getStoredToken()
    ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'fetching'
    try {
      const res = await fetchWithTimeout(
        '/api/v1/dashboard/dev-token',
        { method: 'GET', headers: { Accept: 'application/json' } },
        DEV_TOKEN_FETCH_TIMEOUT_MS,
      )
      if (!res.ok) {
        if (res.status === 404 && storedMeta?.source === 'dev') {
          clearStoredToken()
        }
        ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'no_endpoint'
        if (isRetryableDevTokenStatus(res.status)) {
          devTokenBootstrapPromise = null
        }
        return
      }
      const payload = (await res.json()) as DevTokenBootstrapPayload
      const token = typeof payload.token === 'string' ? payload.token.trim() : ''
      if (!token) {
        ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'no_endpoint'
        devTokenBootstrapPromise = null
        return
      }
      const actor = typeof payload.actor === 'string' ? payload.actor.trim() : 'dashboard'
      const scope =
        typeof payload.scope === 'string' && payload.scope.trim() !== ''
          ? payload.scope.trim()
          : null
      if (
        token !== storedToken
        || storedMeta?.source !== 'dev'
        || storedMeta.actor !== actor
        || (storedMeta.scope ?? null) !== scope
      ) {
        setStoredToken(token, {
          source: 'dev',
          actor,
          scope,
        })
      }
      ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'ok'
    } catch {
      ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'network'
      devTokenBootstrapPromise = null
    }
  })()
  return devTokenBootstrapPromise
}

export function resetDevTokenBootstrap(): void {
  devTokenBootstrapPromise = null
}
