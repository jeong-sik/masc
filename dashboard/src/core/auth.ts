/**
 * Core Auth Session, Capability-Gated Bootstrap, Monotonic Epoch Fence & Workspace Registry.
 *
 * Invariants:
 * - Closed union `AuthSession` (fail-closed; no stringly-typed fallback).
 * - TUI v2.6 `/health` compatibility: absent or `null` `account_mode` => `single_user`;
 *   `"Multi_account"` (or `"multi_account"`) => `multi_account`; any unknown value => `unavailable`.
 * - ONLY probes `/api/v1/dashboard/dev-token` when `health.auth_methods?.dev_token === true`.
 * - Monotonic `sessionEpoch` increments on every Account change, Workspace switch, sign-out,
 *   or credential rotation so in-flight reads and HITL actions fail closed when stale.
 * - Cross-tab storage/visibility detection catches account switches across tabs.
 * - `pagehide` wipes transient in-memory secrets cleanly.
 */

import { signal, computed } from '@preact/signals'

export type AccountMode = 'single_user' | 'multi_account'
export type UserRole = 'admin' | 'worker' | 'viewer'

export interface AuthMethods {
  readonly google: boolean
  readonly github: boolean
  readonly dev_token: boolean
}

export interface WorkspaceTarget {
  readonly id: string
  readonly label: string
  readonly baseUrl?: string
  readonly workspaceRoot?: string
}

export type AuthSession =
  | { readonly kind: 'probing' }
  | {
      readonly kind: 'single_user_local'
      readonly mode: 'single_user'
      readonly tokenPresent: boolean
      readonly authMethods: AuthMethods
      readonly workspaceId: string
    }
  | {
      readonly kind: 'single_user_auth_required'
      readonly mode: 'single_user'
      readonly authMethods: AuthMethods
      readonly reason: string
    }
  | {
      readonly kind: 'multi_account_signed_out'
      readonly mode: 'multi_account'
      readonly authMethods: AuthMethods
    }
  | {
      readonly kind: 'multi_account_signed_in'
      readonly mode: 'multi_account'
      readonly accountId: string
      readonly email: string | null
      readonly displayName: string
      readonly role: UserRole
      readonly csrfToken: string
      readonly authMethods: AuthMethods
      readonly workspaceId: string
    }
  | {
      readonly kind: 'account_changed'
      readonly mode: 'multi_account'
      readonly previousAccountId: string | null
      readonly nextAccountId: string | null
      readonly authMethods: AuthMethods
    }
  | {
      readonly kind: 'unavailable'
      readonly reason: string
    }

const ACCOUNT_MARKER_STORAGE_KEY = 'masc.core.account_marker'
const DEFAULT_AUTH_METHODS: AuthMethods = Object.freeze({
  google: false,
  github: false,
  dev_token: false,
})

// Volatile in-memory secrets — wiped on pagehide / sign-out / epoch change
let singleUserBearerToken: string | null = null
let activeCsrfToken: string | null = null

export const authSession = signal<AuthSession>({ kind: 'probing' })
export const sessionEpoch = signal<number>(1)
export const workspaceTargets = signal<readonly WorkspaceTarget[]>([
  { id: 'default', label: 'Default Workspace' },
])
export const activeWorkspaceId = signal<string>('default')

export const isAuthenticated = computed<boolean>(() => {
  const s = authSession.value
  return s.kind === 'single_user_local' || s.kind === 'multi_account_signed_in'
})

export const currentAccountMode = computed<AccountMode | null>(() => {
  const s = authSession.value
  if (s.kind === 'probing' || s.kind === 'unavailable') return null
  return s.mode
})

export function currentSessionEpoch(): number {
  return sessionEpoch.peek()
}

export function isEpochCurrent(epoch: number): boolean {
  return sessionEpoch.peek() === epoch
}

export function bumpSessionEpoch(): number {
  const next = sessionEpoch.peek() + 1
  sessionEpoch.value = next
  return next
}

export function getSingleUserToken(): string | null {
  return singleUserBearerToken
}

export function getActiveCsrfToken(): string | null {
  const s = authSession.peek()
  if (s.kind === 'multi_account_signed_in') {
    return activeCsrfToken ?? s.csrfToken
  }
  return null
}

export function setSingleUserToken(token: string | null): void {
  const normalized = token && token.trim().length > 0 ? token.trim() : null
  if (singleUserBearerToken === normalized) return
  singleUserBearerToken = normalized
  bumpSessionEpoch()
  const cur = authSession.peek()
  if (cur.kind === 'single_user_local' || cur.kind === 'single_user_auth_required') {
    if (normalized !== null) {
      authSession.value = {
        kind: 'single_user_local',
        mode: 'single_user',
        tokenPresent: true,
        authMethods: cur.authMethods,
        workspaceId: activeWorkspaceId.peek(),
      }
    } else {
      authSession.value = {
        kind: 'single_user_auth_required',
        mode: 'single_user',
        authMethods: cur.authMethods,
        reason: 'Token cleared',
      }
    }
  }
}

export function wipeTransientSecrets(): void {
  singleUserBearerToken = null
  activeCsrfToken = null
}

export function registerWorkspaceTargets(targets: readonly WorkspaceTarget[]): void {
  const list = targets.length > 0 ? [...targets] : [{ id: 'default', label: 'Default Workspace' }]
  workspaceTargets.value = Object.freeze(list)
  if (!list.some(t => t.id === activeWorkspaceId.peek())) {
    selectWorkspace(list[0]!.id)
  }
}

export function selectWorkspace(workspaceId: string): boolean {
  const trimmed = workspaceId.trim()
  if (!trimmed || trimmed === activeWorkspaceId.peek()) return false
  activeWorkspaceId.value = trimmed
  bumpSessionEpoch()
  const cur = authSession.peek()
  if (cur.kind === 'single_user_local') {
    authSession.value = { ...cur, workspaceId: trimmed }
  } else if (cur.kind === 'multi_account_signed_in') {
    authSession.value = { ...cur, workspaceId: trimmed }
  }
  return true
}

/**
 * Resolves a dashboard API/SSE path against the active `WorkspaceTarget.baseUrl`
 * when configured as a same-origin path prefix (e.g. `"/ws/alpha"`).
 * Cross-origin `baseUrl` values are refused fail-closed so same-origin session
 * cookies and CSRF headers are never leaked across origins.
 */
export function resolveWorkspaceUrl(path: string): string {
  const activeId = activeWorkspaceId.peek()
  const target = workspaceTargets.peek().find((t) => t.id === activeId)
  const rawBase = target?.baseUrl?.trim()
  if (!rawBase) return path

  const normalizedPath = path.startsWith('/') ? path : `/${path}`
  if (rawBase.startsWith('/')) {
    const cleanPrefix = rawBase.replace(/\/+$/, '')
    return `${cleanPrefix}${normalizedPath}`
  }
  if (typeof window !== 'undefined' && window.location?.origin) {
    try {
      const parsed = new URL(rawBase, window.location.origin)
      if (parsed.origin !== window.location.origin) {
        return normalizedPath
      }
      const cleanPrefix = parsed.pathname.replace(/\/+$/, '')
      return `${cleanPrefix}${normalizedPath}`
    } catch {
      return normalizedPath
    }
  }
  return normalizedPath
}

function parseAccountMode(raw: unknown): AccountMode | 'invalid' {
  if (raw === undefined || raw === null) return 'single_user'
  if (raw === 'Multi_account' || raw === 'multi_account') return 'multi_account'
  if (raw === 'Single_user' || raw === 'single_user') return 'single_user'
  return 'invalid'
}

function parseAuthMethods(raw: unknown): AuthMethods {
  if (typeof raw !== 'object' || raw === null) return DEFAULT_AUTH_METHODS
  const rec = raw as Record<string, unknown>
  return Object.freeze({
    google: rec.google === true,
    github: rec.github === true,
    dev_token: rec.dev_token === true,
  })
}

function parseRole(raw: unknown): UserRole {
  const val = typeof raw === 'string' ? raw.trim().toLowerCase() : ''
  if (val === 'admin') return 'admin'
  if (val === 'worker') return 'worker'
  return 'viewer'
}

function writeAccountMarker(accountId: string | null): void {
  try {
    if (typeof localStorage === 'undefined') return
    if (accountId === null) localStorage.removeItem(ACCOUNT_MARKER_STORAGE_KEY)
    else localStorage.setItem(ACCOUNT_MARKER_STORAGE_KEY, accountId)
  } catch { /* storage unavailable */ }
}

interface AuthSessionWirePayload {
  readonly user_id?: unknown
  readonly expires_at_ms?: unknown
  readonly csrf_token?: unknown
  readonly workspace_id?: unknown
}

interface AuthWhoamiWirePayload {
  readonly principal?: {
    readonly kind?: unknown
    readonly id?: unknown
  }
  readonly role?: unknown
  readonly binding?: unknown
  readonly workspace_id?: unknown
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null
}

async function readMultiAccountSession(
  fetchImpl: typeof fetch,
  authMethods: AuthMethods,
  previousAccountId: string | null,
): Promise<AuthSession> {
  // 1. Live OCaml Server_login_http route: GET /auth/session -> { user_id, expires_at_ms, csrf_token }
  const res = await fetchImpl('/auth/session', {
    method: 'GET',
    credentials: 'same-origin',
    headers: { Accept: 'application/json' },
  })
  if (res.status === 401 || res.status === 403) {
    activeCsrfToken = null
    writeAccountMarker(null)
    if (previousAccountId !== null) {
      return {
        kind: 'account_changed',
        mode: 'multi_account',
        previousAccountId,
        nextAccountId: null,
        authMethods,
      }
    }
    return { kind: 'multi_account_signed_out', mode: 'multi_account', authMethods }
  }
  if (!res.ok) {
    return { kind: 'unavailable', reason: `GET /auth/session failed (${res.status})` }
  }
  const sessionBody = (await res.json()) as AuthSessionWirePayload
  const userId = nonEmptyString(sessionBody.user_id)
  const csrfToken = nonEmptyString(sessionBody.csrf_token)
  if (userId === null || csrfToken === null) {
    activeCsrfToken = null
    return { kind: 'unavailable', reason: 'GET /auth/session returned malformed payload' }
  }

  if (previousAccountId !== null && previousAccountId !== userId) {
    activeCsrfToken = null
    writeAccountMarker(userId)
    return {
      kind: 'account_changed',
      mode: 'multi_account',
      previousAccountId,
      nextAccountId: userId,
      authMethods,
    }
  }

  // 2. Live OCaml Auth_preview route: GET /api/v1/auth/whoami -> { principal: { kind: "human", id }, role, binding }
  const whoRes = await fetchImpl('/api/v1/auth/whoami', {
    method: 'GET',
    credentials: 'same-origin',
    headers: { Accept: 'application/json' },
  })
  if (whoRes.status === 401 || whoRes.status === 403) {
    activeCsrfToken = null
    writeAccountMarker(null)
    if (previousAccountId !== null) {
      return {
        kind: 'account_changed',
        mode: 'multi_account',
        previousAccountId,
        nextAccountId: null,
        authMethods,
      }
    }
    return { kind: 'multi_account_signed_out', mode: 'multi_account', authMethods }
  }
  if (!whoRes.ok) {
    activeCsrfToken = null
    return { kind: 'unavailable', reason: `GET /api/v1/auth/whoami failed (${whoRes.status})` }
  }
  const whoBody = (await whoRes.json()) as AuthWhoamiWirePayload
  const principalKind = whoBody.principal?.kind
  const principalId = nonEmptyString(whoBody.principal?.id)
  if (principalKind !== 'human' || principalId === null) {
    activeCsrfToken = null
    return { kind: 'unavailable', reason: 'GET /api/v1/auth/whoami did not return a human principal' }
  }
  if (principalId !== userId) {
    activeCsrfToken = null
    writeAccountMarker(principalId)
    return {
      kind: 'account_changed',
      mode: 'multi_account',
      previousAccountId: userId,
      nextAccountId: principalId,
      authMethods,
    }
  }

  activeCsrfToken = csrfToken
  const prevWorkspaceId = activeWorkspaceId.peek()
  const serverWorkspaceId = nonEmptyString(whoBody.workspace_id) ?? nonEmptyString(sessionBody.workspace_id)
  const workspaceId = serverWorkspaceId ?? prevWorkspaceId
  if (workspaceId !== prevWorkspaceId) {
    activeWorkspaceId.value = workspaceId
    bumpSessionEpoch()
  }
  writeAccountMarker(userId)
  return {
    kind: 'multi_account_signed_in',
    mode: 'multi_account',
    accountId: userId,
    email: null,
    displayName: userId,
    role: parseRole(whoBody.role),
    csrfToken,
    authMethods,
    workspaceId,
  }
}

export interface BootstrapAuthOptions {
  readonly fetchImpl?: typeof fetch
  readonly probeShell?: boolean
}

/**
 * Capability-gated auth bootstrap:
 * 1. Reads `GET /health` to determine `account_mode` and `auth_methods`.
 * 2. In `single_user`: ONLY calls `/api/v1/dashboard/dev-token` if `auth_methods.dev_token === true`.
 * 3. In `multi_account`: reads `/api/v1/auth/session` with `credentials: 'same-origin'`.
 */
export async function bootstrapAuthSession(
  opts: BootstrapAuthOptions = {},
): Promise<AuthSession> {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch
  const prev = authSession.peek()
  const prevAccountId = prev.kind === 'multi_account_signed_in' ? prev.accountId : null

  try {
    const healthRes = await fetchImpl('/health', {
      method: 'GET',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    })
    if (!healthRes.ok) {
      const next: AuthSession = { kind: 'unavailable', reason: `GET /health failed (${healthRes.status})` }
      authSession.value = next
      return next
    }
    const health = (await healthRes.json()) as Record<string, unknown>
    const mode = parseAccountMode(health.account_mode)
    if (mode === 'invalid') {
      const next: AuthSession = {
        kind: 'unavailable',
        reason: `Unsupported account_mode: ${String(health.account_mode)}`,
      }
      authSession.value = next
      return next
    }
    const authMethods = parseAuthMethods(health.auth_methods)

    if (mode === 'multi_account') {
      singleUserBearerToken = null
      const next = await readMultiAccountSession(fetchImpl, authMethods, prevAccountId)
      if (next.kind === 'account_changed') bumpSessionEpoch()
      authSession.value = next
      return next
    }

    // Single-user mode: ONLY probe /api/v1/dashboard/dev-token if explicitly advertised
    activeCsrfToken = null
    if (authMethods.dev_token && singleUserBearerToken === null) {
      try {
        const devRes = await fetchImpl('/api/v1/dashboard/dev-token', {
          method: 'GET',
          credentials: 'same-origin',
          headers: { Accept: 'application/json' },
        })
        if (devRes.ok) {
          const payload = (await devRes.json()) as { token?: unknown }
          if (typeof payload.token === 'string' && payload.token.trim().length > 0) {
            singleUserBearerToken = payload.token.trim()
          }
        }
      } catch { /* dev token optional */ }
    }

    if (opts.probeShell !== false) {
      const headers: Record<string, string> = { Accept: 'application/json' }
      if (singleUserBearerToken) headers.Authorization = `Bearer ${singleUserBearerToken}`
      const shellRes = await fetchImpl('/api/v1/dashboard/shell', {
        method: 'GET',
        credentials: 'same-origin',
        headers,
      })
      if (shellRes.status === 401 || shellRes.status === 403) {
        const next: AuthSession = {
          kind: 'single_user_auth_required',
          mode: 'single_user',
          authMethods,
          reason: `Authorization required (${shellRes.status})`,
        }
        authSession.value = next
        return next
      }
      if (!shellRes.ok) {
        const next: AuthSession = {
          kind: 'unavailable',
          reason: `GET /api/v1/dashboard/shell failed (${shellRes.status})`,
        }
        authSession.value = next
        return next
      }
    }

    const next: AuthSession = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: singleUserBearerToken !== null,
      authMethods,
      workspaceId: activeWorkspaceId.peek(),
    }
    authSession.value = next
    return next
  } catch (error) {
    const next: AuthSession = {
      kind: 'unavailable',
      reason: error instanceof Error ? error.message : String(error),
    }
    authSession.value = next
    return next
  }
}

/**
 * Re-reads `/api/v1/auth/session` to refresh an expired CSRF token in `multi_account` mode.
 * Returns the fresh token or null if the account changed or session expired.
 */
export async function refreshMultiAccountCsrf(
  fetchImpl: typeof fetch = globalThis.fetch,
): Promise<string | null> {
  const cur = authSession.peek()
  if (cur.kind !== 'multi_account_signed_in') return null
  const next = await readMultiAccountSession(fetchImpl, cur.authMethods, cur.accountId)
  if (next.kind === 'account_changed') {
    bumpSessionEpoch()
    authSession.value = next
    return null
  }
  authSession.value = next
  return next.kind === 'multi_account_signed_in' ? next.csrfToken : null
}

/**
 * Installs cross-tab storage & visibility account-change detection plus `pagehide` secret-wiping.
 * Returns a disposer function.
 */
export function installAuthLifecycleGuards(
  fetchImpl: typeof fetch = globalThis.fetch,
): () => void {
  if (typeof window === 'undefined' || typeof document === 'undefined') {
    return () => {}
  }

  const onPageHide = () => {
    wipeTransientSecrets()
  }

  const onStorage = (event: StorageEvent) => {
    if (event.key !== ACCOUNT_MARKER_STORAGE_KEY) return
    const cur = authSession.peek()
    if (cur.kind !== 'multi_account_signed_in') return
    const nextAccountId = event.newValue
    if (nextAccountId !== cur.accountId) {
      activeCsrfToken = null
      bumpSessionEpoch()
      authSession.value = {
        kind: 'account_changed',
        mode: 'multi_account',
        previousAccountId: cur.accountId,
        nextAccountId,
        authMethods: cur.authMethods,
      }
    }
  }

  const onVisibilityChange = () => {
    if (document.visibilityState !== 'visible') return
    const cur = authSession.peek()
    if (cur.kind !== 'multi_account_signed_in') return
    void readMultiAccountSession(fetchImpl, cur.authMethods, cur.accountId).then((next) => {
      if (next.kind === 'account_changed' || next.kind === 'multi_account_signed_out') {
        activeCsrfToken = null
        bumpSessionEpoch()
        authSession.value = next
      } else if (next.kind === 'multi_account_signed_in') {
        authSession.value = next
      }
    }).catch(() => { /* transient offline on tab focus */ })
  }

  window.addEventListener('pagehide', onPageHide)
  window.addEventListener('storage', onStorage)
  document.addEventListener('visibilitychange', onVisibilityChange)

  return () => {
    window.removeEventListener('pagehide', onPageHide)
    window.removeEventListener('storage', onStorage)
    document.removeEventListener('visibilitychange', onVisibilityChange)
  }
}

export function resetAuthStateForTests(): void {
  wipeTransientSecrets()
  authSession.value = { kind: 'probing' }
  sessionEpoch.value = 1
  activeWorkspaceId.value = 'default'
  workspaceTargets.value = Object.freeze([{ id: 'default', label: 'Default Workspace' }])
  writeAccountMarker(null)
}
