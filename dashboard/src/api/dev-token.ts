import { signal, type ReadonlySignal } from '@preact/signals'
import type { DashboardAuthErrorCode } from '../types/dashboard-execution'
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
const DEV_TOKEN_WARMUP_RETRY_MS = 1_000

let devTokenBootstrapPromise: Promise<void> | null = null
let devTokenRefreshPromise: Promise<boolean> | null = null

/**
 * Tracks the outcome of the loopback dev-token bootstrap so the UI can
 * distinguish "auth required but no token" from "network error" etc.
 *   idle       — not yet attempted
 *   fetching   — in-flight
 *   warming    — server accepted HTTP but has not installed runtime state yet
 *   ok         — token stored
 *   no_endpoint — /dev-token returned 404 (loopback disabled or strict auth)
 *   invalid_response — endpoint response violated the exact token contract
 *   network    — fetch threw (server down, CORS, DNS)
 */
export type DevTokenBootstrapStatus =
  | 'idle'
  | 'fetching'
  | 'warming'
  | 'ok'
  | 'no_endpoint'
  | 'invalid_response'
  | 'network'

export const devTokenBootstrapStatus: ReadonlySignal<DevTokenBootstrapStatus> =
  signal<DevTokenBootstrapStatus>('idle')

interface DevTokenBootstrapPayload {
  token?: unknown
  actor?: unknown
  role?: unknown
  status?: unknown
}

function waitForWarmupRetry(): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, DEV_TOKEN_WARMUP_RETRY_MS))
}

const REFRESHABLE_AUTH_CODES: ReadonlySet<DashboardAuthErrorCode> = new Set([
  'invalid_token',
  'token_expired',
  'actor_mismatch',
])

export function isRefreshableDashboardAuthCode(
  value: unknown,
): value is DashboardAuthErrorCode {
  return typeof value === 'string'
    && REFRESHABLE_AUTH_CODES.has(value as DashboardAuthErrorCode)
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
  // a borrowed non-dashboard token (for example an old MCP-client paste/URL token).
  return meta == null || meta.source === 'url'
}

/** Fetch the loopback-only dev token once per page load and stash it so
    subsequent `/mcp` requests include `Authorization: Bearer ...`. The server
    only exposes `/api/v1/dashboard/dev-token` when bound to loopback with
    strict-auth overrides disabled; in every other case this quietly no-ops
    and existing flows (URL `?token=...`, manual paste) continue to work. */
export async function ensureDevToken(): Promise<void> {
  if (!shouldRefreshDevToken()) return
  if (devTokenBootstrapPromise) return devTokenBootstrapPromise
  devTokenBootstrapPromise = (async () => {
    const storedMeta = getStoredTokenMeta()
    ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'fetching'
    while (true) {
      if (getStoredTokenMeta()?.source === 'manual' && getStoredToken()) return
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
        if (payload.status === 'initializing') {
          ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'warming'
          await waitForWarmupRetry()
          continue
        }
        const token = typeof payload.token === 'string' ? payload.token.trim() : ''
        if (!token || payload.actor !== 'dashboard' || payload.role !== 'worker') {
          ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'invalid_response'
          devTokenBootstrapPromise = null
          return
        }
        const currentMeta = getStoredTokenMeta()
        const currentToken = getStoredToken()
        // Same rule as the pre-fetch guard above: a manually-pasted token is
        // never silently overwritten. It needs the token as well as the meta —
        // meta alone can outlive the token it described, and then there is
        // nothing to protect while this return would block the bootstrap
        // forever. shouldRefreshDevToken already admits that case (`!token`
        // returns true), so dropping the token from this check contradicted it.
        if (currentMeta?.source === 'manual' && currentToken) return
        if (
          token !== currentToken
          || currentMeta?.source !== 'dev'
        ) {
          setStoredToken(token, {
            source: 'dev',
            actor: 'dashboard',
            role: 'worker',
          })
        }
        ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'ok'
        return
      } catch {
        ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'network'
        devTokenBootstrapPromise = null
        return
      }
    }
  })()
  return devTokenBootstrapPromise
}

export function resetDevTokenBootstrap(): void {
  devTokenBootstrapPromise = null
}

export async function refreshDevTokenAfterAuthError(code: unknown): Promise<boolean> {
  if (!isRefreshableDashboardAuthCode(code)) return false
  if (isRemoteAccess()) return false
  if (getStoredTokenMeta()?.source === 'manual') return false
  if (devTokenRefreshPromise) return devTokenRefreshPromise
  if (!getStoredToken()) return false

  const refresh = (async () => {
    clearStoredToken()
    resetDevTokenBootstrap()
    await ensureDevToken()
    return getStoredTokenMeta()?.source === 'dev' && getStoredToken() !== null
  })()
  devTokenRefreshPromise = refresh
  try {
    return await refresh
  } finally {
    if (devTokenRefreshPromise === refresh) devTokenRefreshPromise = null
  }
}
