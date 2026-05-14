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

interface DevTokenBootstrapPayload {
  token?: unknown
  actor?: unknown
  scope?: unknown
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
  // a borrowed non-dashboard token (for example an old codex paste/URL token).
  return meta == null || meta.actor == null || meta.actor !== actor
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
    const storedToken = getStoredToken()
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
        return
      }
      const payload = (await res.json()) as DevTokenBootstrapPayload
      const token = typeof payload.token === 'string' ? payload.token.trim() : ''
      if (!token) return
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
    } catch {
      /* Loopback endpoint unavailable (LAN bind, strict auth, offline).
         Leave auth headers empty; caller will surface the 401 as before. */
    }
  })()
  return devTokenBootstrapPromise
}

export function resetDevTokenBootstrap(): void {
  devTokenBootstrapPromise = null
}
