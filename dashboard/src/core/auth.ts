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

import { batch, signal, computed } from '@preact/signals'
import {
  clearStoredToken,
  consumeUrlBearerToken,
  currentStoredTokenRevision,
  getStoredToken,
  getStoredTokenMeta,
  normalizeBearerToken,
  setStoredToken,
  subscribeStoredTokenChanges,
  type BearerTokenValidation,
  type StoredTokenMeta,
} from '../lib/dashboard-bearer'

export { normalizeBearerToken, type BearerTokenValidation }

export type AccountMode = 'single_user' | 'multi_account'
export type UserRole = 'admin' | 'worker' | 'viewer'
export type SingleUserRole = 'admin' | 'worker' | 'player'

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
      readonly role?: SingleUserRole
      readonly canTokenAdmin?: boolean
      readonly canTokenRead?: boolean
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
const DEFAULT_BOOTSTRAP_TIMEOUT_MS = 12_000
const FORBIDDEN_RECHECK_COOLDOWN_MS = 5_000
const DEFAULT_AUTH_METHODS: AuthMethods = Object.freeze({
  google: false,
  github: false,
  dev_token: false,
})

// Volatile in-memory secrets — wiped on pagehide / sign-out / epoch change.
// Single-user operator bearers are mirrored into tab-scoped sessionStorage
// (never localStorage) so `masc login` ?token= URLs and page reloads survive
// without leaking across tabs or surviving tab close.
let singleUserBearerToken: string | null = null
let activeCsrfToken: string | null = null
let internalBearerWriteDepth = 0
let lastForbiddenRecheckAt = 0
let forbiddenRecheckInFlight: Promise<void> | null = null

function withInternalBearerWrite<T>(fn: () => T): T {
  internalBearerWriteDepth += 1
  try {
    return fn()
  } finally {
    internalBearerWriteDepth -= 1
  }
}

function isSessionStorageReadable(): boolean {
  try {
    if (typeof sessionStorage === 'undefined') return false
    sessionStorage.getItem('masc_bearer_token')
    return true
  } catch {
    return false
  }
}

function readSessionBearerToken(): string | null {
  return getStoredToken()?.trim() ?? null
}

function writeSessionBearerToken(
  token: string | null,
  meta: StoredTokenMeta = { source: 'manual' },
): void {
  withInternalBearerWrite(() => {
    try {
      if (token === null) clearStoredToken()
      else setStoredToken(token, meta)
    } catch { /* storage unavailable */ }
  })
}

export const authSession = signal<AuthSession>({ kind: 'probing' })
export const sessionEpoch = signal<number>(1)
export const workspaceTargets = signal<readonly WorkspaceTarget[]>([
  { id: 'default', label: 'Default Workspace' },
])
export const activeWorkspaceId = signal<string>('default')

// Keep the shell's in-memory bearer cache, epoch fence, and single-user session
// synchronized whenever API modules (e.g. api/dev-token.ts) clear or replace
// the shared tab-scoped bearer store.
subscribeStoredTokenChanges(({ token, meta }) => {
  if (internalBearerWriteDepth > 0) return
  const prevToken = singleUserBearerToken
  singleUserBearerToken = token
  if (prevToken === token) return
  batch(() => {
    bumpSessionEpoch()
    const cur = authSession.peek()
    if (cur.kind === 'single_user_local' || cur.kind === 'single_user_auth_required') {
      if (token !== null) {
        const isVerifiedDevAdmin = meta?.source === 'dev' && meta.role === 'admin'
        authSession.value = {
          kind: 'single_user_local',
          mode: 'single_user',
          tokenPresent: true,
          role: isVerifiedDevAdmin ? 'admin' : 'worker',
          canTokenAdmin: isVerifiedDevAdmin,
          canTokenRead: isVerifiedDevAdmin,
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
  })
})

export const isAuthenticated = computed<boolean>(() => {
  const s = authSession.value
  return s.kind === 'single_user_local' || s.kind === 'multi_account_signed_in'
})

export const currentAccountMode = computed<AccountMode | null>(() => {
  const s = authSession.value
  if (s.kind === 'probing' || s.kind === 'unavailable') return null
  return s.mode
})

/**
 * Fail-closed admin capability check across both modes:
 * - `multi_account_signed_in`: requires `role === 'admin'`.
 * - `single_user_local`: requires `role === 'admin'` (or omitted `role` in legacy fixtures).
 * - ALL unauthenticated / probing / unavailable / account_changed states return `false`.
 */
export function canAccessAdmin(session: AuthSession): boolean {
  switch (session.kind) {
    case 'multi_account_signed_in':
      return session.role === 'admin'
    case 'single_user_local':
      return session.role === undefined || session.role === 'admin'
    case 'probing':
    case 'unavailable':
    case 'account_changed':
    case 'multi_account_signed_out':
    case 'single_user_auth_required':
      return false
  }
}

/**
 * Checks whether the current session may access member workspace routes and
 * `CanReadState` endpoints (`/pulse`, `/work`, `/knowledge`, `/keepers`, `/runtime`,
 * observer SSE, HITL queues).
 * - `multi_account_signed_in`: allowed (`admin`/`worker`/`viewer`).
 * - `single_user_local`: allowed ONLY when `role !== 'player'` (`Player` holds
 *   only `CanPlayMachine` in `lib/types/types_auth.ml:482-484`).
 * - All unauthenticated / probing / unavailable / account_changed states: denied.
 */
export function canAccessMemberWorkspace(session: AuthSession): boolean {
  switch (session.kind) {
    case 'multi_account_signed_in':
      return true
    case 'single_user_local':
      return session.role !== 'player'
    case 'probing':
    case 'unavailable':
    case 'account_changed':
    case 'multi_account_signed_out':
    case 'single_user_auth_required':
      return false
  }
}

/**
 * Checks whether the current session is an authenticated non-player single-user
 * local session (`single_user_local` with `role !== 'player'`).
 */
export function isSingleUserMember(session: AuthSession): boolean {
  return session.kind === 'single_user_local' && session.role !== 'player'
}

/**
 * Checks whether the current session satisfies single-user `Token_permission CanReadState`
 * (`enabled && require_token && token_valid && role !== 'player'`, server_auth.ml:1187-1225).
 */
export function canUseSingleUserTokenRead(session: AuthSession): boolean {
  if (session.kind !== 'single_user_local') return false
  if (session.canTokenRead !== undefined) return session.canTokenRead
  return session.role !== 'player'
}

/**
 * Checks whether the current session satisfies single-user `Token_permission CanAdmin`
 * (`enabled && require_token && token_valid && effective_admin`, server_auth.ml:1187-1225).
 */
export function canUseSingleUserTokenAdmin(session: AuthSession): boolean {
  if (session.kind !== 'single_user_local') return false
  if (session.canTokenAdmin !== undefined) return session.canTokenAdmin
  return session.role === undefined || session.role === 'admin'
}

/**
 * Checks whether the current session satisfies `Token_permission CanAdmin` in
 * single-user mode OR `Admin_only` in multi-account mode (e.g. `/api/v1/config/schema`,
 * `/api/v1/config/patch`, `/api/v1/infra/sandboxes/probe`, `PUT /api/v1/wiki/:slug`,
 * `/api/v1/dashboard/exact-lane-runs`). Prevents speculative 401s when single-user
 * `shell.auth` reports `enabled=false` or `require_token=false` (`canTokenAdmin=false`).
 */
export function canAccessTokenAdmin(session: AuthSession): boolean {
  switch (session.kind) {
    case 'multi_account_signed_in':
      return session.role === 'admin'
    case 'single_user_local':
      return canUseSingleUserTokenAdmin(session)
    case 'probing':
    case 'unavailable':
    case 'account_changed':
    case 'multi_account_signed_out':
    case 'single_user_auth_required':
      return false
  }
}

/**
 * Checks whether the current session satisfies routes that are `Public_read` or
 * `Permission CanReadState` in single-user mode (Admin + Worker, even when auth is
 * disabled) and `Admin_only` in multi-account bridge (e.g. `GET /api/v1/infra/sandboxes`,
 * `GET /api/v1/dashboard/logs`, `GET /api/v1/repositories`).
 */
export function canReadSuOrMaAdmin(session: AuthSession): boolean {
  switch (session.kind) {
    case 'multi_account_signed_in':
      return session.role === 'admin'
    case 'single_user_local':
      return session.role !== 'player'
    case 'probing':
    case 'unavailable':
    case 'account_changed':
    case 'multi_account_signed_out':
    case 'single_user_auth_required':
      return false
  }
}

export function currentSessionEpoch(): number {
  return sessionEpoch.peek()
}

export function isEpochCurrent(epoch: number): boolean {
  return sessionEpoch.peek() === epoch
}

export function bumpSessionEpoch(): number {
  clearBootstrapHandoffs()
  const next = sessionEpoch.peek() + 1
  sessionEpoch.value = next
  return next
}

interface BootstrapHealthHandoff {
  readonly epoch: number
  readonly payload: Record<string, unknown>
  readonly capturedAt: number
}

interface BootstrapShellHandoff {
  readonly epoch: number
  readonly token: string | null
  readonly workspaceId: string
  readonly payload: unknown
  readonly etag: string | null
  readonly capturedAt: number
}

const BOOTSTRAP_HANDOFF_TTL_MS = 5_000
let bootstrapHealthHandoff: BootstrapHealthHandoff | null = null
let bootstrapShellHandoff: BootstrapShellHandoff | null = null

function clearBootstrapHandoffs(): void {
  bootstrapHealthHandoff = null
  bootstrapShellHandoff = null
}

export function clearBootstrapShellHandoff(): void {
  bootstrapShellHandoff = null
}

/** One-shot handoff of the `/health` JSON parsed during `bootstrapAuthSession`. */
export function consumeBootstrapHealthPayload(epoch: number): Record<string, unknown> | null {
  const entry = bootstrapHealthHandoff
  if (!entry || entry.epoch !== epoch || Date.now() - entry.capturedAt > BOOTSTRAP_HANDOFF_TTL_MS) {
    return null
  }
  bootstrapHealthHandoff = null
  return entry.payload
}

/** One-shot handoff of the `/api/v1/dashboard/shell` response probed during single-user boot. */
export function consumeBootstrapShellPayload(
  epoch: number,
  token: string | null,
  workspaceId: string,
): { readonly payload: unknown; readonly etag: string | null } | null {
  const entry = bootstrapShellHandoff
  if (
    !entry
    || entry.epoch !== epoch
    || entry.token !== token
    || entry.workspaceId !== workspaceId
    || Date.now() - entry.capturedAt > BOOTSTRAP_HANDOFF_TTL_MS
  ) {
    return null
  }
  bootstrapShellHandoff = null
  return { payload: entry.payload, etag: entry.etag }
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
  const parsed = normalizeBearerToken(token)
  if (!parsed.ok) return
  const normalized = parsed.token
  const storedSource = getStoredTokenMeta()?.source ?? null
  const nextSource = normalized === null ? null : 'manual'
  if (singleUserBearerToken === normalized && readSessionBearerToken() === normalized
      && storedSource === nextSource) return
  batch(() => {
    const tokenChanged = singleUserBearerToken !== normalized
    singleUserBearerToken = normalized
    bumpSessionEpoch()
    const cur = authSession.peek()
    if (cur.kind === 'single_user_local' || cur.kind === 'single_user_auth_required') {
      if (normalized !== null) {
        // Fail closed for an unverified manual token until verified via
        // `verifyAndApplySingleUserToken` / `bootstrapAuthSession`; preserve
        // verified capabilities only when the token value itself did not change.
        const preserveVerified = !tokenChanged && cur.kind === 'single_user_local'
        authSession.value = {
          kind: 'single_user_local',
          mode: 'single_user',
          tokenPresent: true,
          role: preserveVerified ? cur.role : 'worker',
          canTokenAdmin: preserveVerified ? cur.canTokenAdmin : false,
          canTokenRead: preserveVerified ? cur.canTokenRead : false,
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
    writeSessionBearerToken(normalized)
  })
}

export function wipeTransientSecrets(): void {
  singleUserBearerToken = null
  activeCsrfToken = null
}

export function registerWorkspaceTargets(targets: readonly WorkspaceTarget[]): void {
  const list = targets.length > 0 ? [...targets] : [{ id: 'default', label: 'Default Workspace' }]
  batch(() => {
    workspaceTargets.value = Object.freeze(list)
    if (!list.some(t => t.id === activeWorkspaceId.peek())) {
      selectWorkspace(list[0]!.id)
    }
  })
}

export function selectWorkspace(workspaceId: string): boolean {
  const trimmed = workspaceId.trim()
  if (!trimmed || trimmed === activeWorkspaceId.peek()) return false
  batch(() => {
    activeWorkspaceId.value = trimmed
    bumpSessionEpoch()
    const cur = authSession.peek()
    if (cur.kind === 'single_user_local') {
      authSession.value = { ...cur, workspaceId: trimmed }
    } else if (cur.kind === 'multi_account_signed_in') {
      authSession.value = { ...cur, workspaceId: trimmed }
    }
  })
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
  if (rawBase.startsWith('/') && !rawBase.startsWith('//')) {
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

type ParsedSingleUserShellAuth =
  | {
      readonly kind: 'ok'
      readonly role: SingleUserRole
      readonly canTokenAdmin: boolean
      readonly canTokenRead: boolean
    }
  | { readonly kind: 'auth_required'; readonly reason: string }
  | { readonly kind: 'malformed'; readonly reason: string }

function parseSingleUserRoleValue(raw: unknown): SingleUserRole | null {
  const val = typeof raw === 'string' ? raw.trim().toLowerCase() : ''
  if (val === 'admin') return 'admin'
  if (val === 'worker') return 'worker'
  if (val === 'player') return 'player'
  return null
}

/**
 * Parses `shell.auth` returned by single-user `GET /api/v1/dashboard/shell`
 * (`lib/server/server_dashboard_http_core.ml:628-760`).
 *
 * Fail-closed rules:
 * - Non-object response body (`null` from HTML 200 / JSON parse failure, array,
 *   primitive) or malformed non-undefined `auth` field returns `malformed`,
 *   preventing captive portals or broken proxies from opening the dashboard.
 * - Omitted `auth` (`rec.auth === undefined`) falls back to lowest capability
 *   (`worker`, `canTokenAdmin: false`, `canTokenRead: false`) and never elevates
 *   to admin.
 * - Non-strict loopback rule (`server_auth.ml:1359-1366`):
 *   When `enabled && require_token && !token_valid`, loopback `Public_read` returns
 *   HTTP 200 with `token_valid=false, effective_role=null`. Reject it as `auth_required`
 *   instead of accepting the unauthenticated/invalid token.
 */
function parseSingleUserShellAuth(body: unknown): ParsedSingleUserShellAuth {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    return {
      kind: 'malformed',
      reason: 'GET /api/v1/dashboard/shell returned malformed payload',
    }
  }
  const rec = body as Record<string, unknown>
  const rawAuth = rec.auth
  if (rawAuth === undefined) {
    return { kind: 'ok', role: 'worker', canTokenAdmin: false, canTokenRead: false }
  }
  if (typeof rawAuth !== 'object' || rawAuth === null || Array.isArray(rawAuth)) {
    return {
      kind: 'malformed',
      reason: 'GET /api/v1/dashboard/shell returned malformed auth metadata',
    }
  }
  const auth = rawAuth as Record<string, unknown>
  const enabled = auth.enabled === true
  const requireToken = auth.require_token === true
  const tokenValid = auth.token_valid === true
  const effectiveAdmin = auth.effective_admin === true
  const effectiveRole = parseSingleUserRoleValue(auth.effective_role)

  if (enabled && requireToken && !tokenValid) {
    const detail = nonEmptyString(auth.auth_error_detail)
    const code = nonEmptyString(auth.auth_error_code)
    return {
      kind: 'auth_required',
      reason: detail ?? code ?? 'Authorization required (missing or invalid bearer token)',
    }
  }

  const role: SingleUserRole = effectiveRole !== null
    ? effectiveRole
    : effectiveAdmin
      ? 'admin'
      : !enabled
        ? 'admin'
        : 'worker'
  const canTokenAdmin = enabled && requireToken && tokenValid && effectiveAdmin
  const canTokenRead = enabled && requireToken && tokenValid && role !== 'player'
  return { kind: 'ok', role, canTokenAdmin, canTokenRead }
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
  timeoutMs: number = DEFAULT_BOOTSTRAP_TIMEOUT_MS,
  isCurrent: () => boolean = () => true,
): Promise<AuthSession> {
  // 1. Live OCaml Server_login_http route: GET /auth/session -> { user_id, expires_at_ms, csrf_token }
  const res = await fetchWithBootstrapTimeout(
    fetchImpl,
    '/auth/session',
    {
      method: 'GET',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    },
    timeoutMs,
  )
  if (!isCurrent()) return authSession.peek()
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
  const sessionBody = (await res.json().catch(() => null)) as AuthSessionWirePayload | null
  if (!isCurrent()) return authSession.peek()
  const userId = nonEmptyString(sessionBody?.user_id)
  const csrfToken = nonEmptyString(sessionBody?.csrf_token)
  if (sessionBody === null || userId === null || csrfToken === null) {
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
  const whoRes = await fetchWithBootstrapTimeout(
    fetchImpl,
    '/api/v1/auth/whoami',
    {
      method: 'GET',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    },
    timeoutMs,
  )
  if (!isCurrent()) return authSession.peek()
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
  const whoBody = (await whoRes.json().catch(() => null)) as AuthWhoamiWirePayload | null
  if (!isCurrent()) return authSession.peek()
  if (whoBody === null) {
    activeCsrfToken = null
    return { kind: 'unavailable', reason: 'GET /api/v1/auth/whoami returned malformed payload' }
  }
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

  if (!isCurrent()) return authSession.peek()
  activeCsrfToken = csrfToken
  const prevWorkspaceId = activeWorkspaceId.peek()
  const serverWorkspaceId = nonEmptyString(whoBody.workspace_id) ?? nonEmptyString(sessionBody.workspace_id)
  const workspaceId = serverWorkspaceId ?? prevWorkspaceId
  if (workspaceId !== prevWorkspaceId) {
    batch(() => {
      activeWorkspaceId.value = workspaceId
      bumpSessionEpoch()
    })
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
  readonly timeoutMs?: number
}

async function fetchWithBootstrapTimeout(
  fetchImpl: typeof fetch,
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  if (typeof AbortController === 'undefined' || timeoutMs <= 0) {
    return fetchImpl(url, init)
  }
  const controller = new AbortController()
  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    controller.abort()
  }, timeoutMs)
  try {
    return await fetchImpl(url, { ...init, signal: controller.signal })
  } catch (error) {
    if (timedOut) {
      const secs = Math.max(1, Math.round(timeoutMs / 1000))
      throw new Error(`서버 응답 시간 초과 (${secs}초) — 서버가 일시적으로 바쁘거나 read_pool이 포화 상태일 수 있습니다.`)
    }
    throw error
  } finally {
    clearTimeout(timer)
  }
}

export type VerifySingleUserTokenResult =
  | { readonly ok: true; readonly session: Extract<AuthSession, { readonly kind: 'single_user_local' }> }
  | { readonly ok: false; readonly error: string }

/**
 * Verifies a candidate single-user operator Bearer token against `/health` and
 * `/api/v1/dashboard/shell` with an explicit timeout BEFORE committing it to
 * `authSession` or `sessionStorage`, preventing premature green badges,
 * non-ASCII `fetch()` header crashes, or infinite `Verifying…` locks.
 */
export async function verifyAndApplySingleUserToken(
  rawToken: string,
  opts: BootstrapAuthOptions = {},
): Promise<VerifySingleUserTokenResult> {
  const parsed = normalizeBearerToken(rawToken)
  if (!parsed.ok) return { ok: false, error: parsed.error }
  if (parsed.token === null) {
    return { ok: false, error: '토큰을 입력한 뒤 적용해 주세요.' }
  }
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch
  const timeoutMs = opts.timeoutMs ?? DEFAULT_BOOTSTRAP_TIMEOUT_MS
  const candidate = parsed.token
  const epoch = currentSessionEpoch()
  const bearerRevision = currentStoredTokenRevision()

  try {
    const healthRes = await fetchWithBootstrapTimeout(
      fetchImpl,
      '/health',
      { method: 'GET', credentials: 'same-origin', headers: { Accept: 'application/json' } },
      timeoutMs,
    )
    if (!healthRes.ok) {
      return { ok: false, error: `GET /health 실패 (HTTP ${healthRes.status})` }
    }
    const health = (await healthRes.json()) as Record<string, unknown>
    const mode = parseAccountMode(health.account_mode)
    if (mode !== 'single_user') {
      return { ok: false, error: '현재 서버는 싱글유저 Bearer 토큰 모드가 아닙니다.' }
    }
    const authMethods = parseAuthMethods(health.auth_methods)
    const shellRes = await fetchWithBootstrapTimeout(
      fetchImpl,
      '/api/v1/dashboard/shell',
      {
        method: 'GET',
        credentials: 'same-origin',
        headers: {
          Accept: 'application/json',
          Authorization: `Bearer ${candidate}`,
        },
      },
      timeoutMs,
    )
    if (!isEpochCurrent(epoch) || currentStoredTokenRevision() !== bearerRevision) {
      return { ok: false, error: '검증 중 다른 인증 변경이 발생했습니다. 다시 시도하세요.' }
    }
    if (shellRes.status === 401 || shellRes.status === 403) {
      return {
        ok: false,
        error: `토큰 인증 실패 (HTTP ${shellRes.status}) — 유효한 오퍼레이터 토큰인지 확인하세요.`,
      }
    }
    if (!shellRes.ok) {
      return { ok: false, error: `서버 상태 오류 (HTTP ${shellRes.status})` }
    }
    const shellBody = await shellRes.json().catch(() => null)
    if (!isEpochCurrent(epoch) || currentStoredTokenRevision() !== bearerRevision) {
      return { ok: false, error: '검증 중 다른 인증 변경이 발생했습니다. 다시 시도하세요.' }
    }
    const parsedShellAuth = parseSingleUserShellAuth(shellBody)
    if (parsedShellAuth.kind === 'auth_required') {
      return {
        ok: false,
        error: `토큰 인증 실패 (${parsedShellAuth.reason}) — 유효한 토큰인지 확인하세요.`,
      }
    }
    if (parsedShellAuth.kind === 'malformed') {
      return {
        ok: false,
        error: parsedShellAuth.reason,
      }
    }

    const next: Extract<AuthSession, { readonly kind: 'single_user_local' }> = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      role: parsedShellAuth.role,
      canTokenAdmin: parsedShellAuth.canTokenAdmin,
      canTokenRead: parsedShellAuth.canTokenRead,
      authMethods,
      workspaceId: activeWorkspaceId.peek(),
    }
    batch(() => {
      singleUserBearerToken = candidate
      bumpSessionEpoch()
      authSession.value = next
      writeSessionBearerToken(candidate, { source: 'manual' })
    })
    return { ok: true, session: next }
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    }
  }
}

/**
 * Capability-gated auth bootstrap:
 * 1. Reads `GET /health` to determine `account_mode` and `auth_methods`.
 * 2. In `single_user`: ONLY calls `/api/v1/dashboard/dev-token` if `auth_methods.dev_token === true`.
 * 3. In `multi_account`: reads `/auth/session` + `/api/v1/auth/whoami` with `credentials: 'same-origin'`.
 */
export async function bootstrapAuthSession(
  opts: BootstrapAuthOptions = {},
): Promise<AuthSession> {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch
  const timeoutMs = opts.timeoutMs ?? DEFAULT_BOOTSTRAP_TIMEOUT_MS
  const prev = authSession.peek()
  const prevAccountId = prev.kind === 'multi_account_signed_in' ? prev.accountId : null
  const epoch = currentSessionEpoch()
  let bearerRevision = currentStoredTokenRevision()
  const ownsCredential = () =>
    isEpochCurrent(epoch) && currentStoredTokenRevision() === bearerRevision
  const persistBearer = (token: string | null, meta?: StoredTokenMeta): void => {
    singleUserBearerToken = token
    writeSessionBearerToken(token, meta)
    bearerRevision = currentStoredTokenRevision()
  }
  const urlToken = consumeUrlBearerToken()

  try {
    const healthRes = await fetchWithBootstrapTimeout(
      fetchImpl,
      '/health',
      {
        method: 'GET',
        credentials: 'same-origin',
        headers: { Accept: 'application/json' },
      },
      timeoutMs,
    )
    const health = (healthRes.ok ? await healthRes.json() : {}) as Record<string, unknown>
    if (!ownsCredential()) return authSession.peek()
    if (!healthRes.ok) {
      const next: AuthSession = { kind: 'unavailable', reason: `GET /health failed (${healthRes.status})` }
      authSession.value = next
      return next
    }
    if (fetchImpl === globalThis.fetch) {
      bootstrapHealthHandoff = { epoch, payload: health, capturedAt: Date.now() }
    }
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
      persistBearer(null)
      const prevWs = activeWorkspaceId.peek()
      const next = await readMultiAccountSession(
        fetchImpl,
        authMethods,
        prevAccountId,
        timeoutMs,
        ownsCredential,
      )
      // readMultiAccountSession itself may bump sessionEpoch when the server
      // workspace differs from prevWs; only bail when an external epoch or
      // credential change preempted this bootstrap.
      const workspaceBumpedBySelf = activeWorkspaceId.peek() !== prevWs && currentStoredTokenRevision() === bearerRevision
      if (!ownsCredential() && !workspaceBumpedBySelf) return authSession.peek()
      if (next.kind === 'account_changed') {
        batch(() => {
          bumpSessionEpoch()
          authSession.value = next
        })
      } else {
        authSession.value = next
      }
      return next
    }

    // Single-user mode: hydrate from `?token=` (`masc login` URL) or tab-scoped
    // sessionStorage, and ONLY probe /api/v1/dashboard/dev-token if explicitly advertised.
    activeCsrfToken = null
    if (urlToken !== null) {
      persistBearer(urlToken, { source: 'url' })
    } else {
      const stored = withInternalBearerWrite(() => readSessionBearerToken())
      bearerRevision = currentStoredTokenRevision()
      if (stored !== null) {
        singleUserBearerToken = stored
      } else if (singleUserBearerToken !== null) {
        if (isSessionStorageReadable()) {
          singleUserBearerToken = null
        } else {
          const rechecked = normalizeBearerToken(singleUserBearerToken)
          if (!rechecked.ok) {
            persistBearer(null)
          }
        }
      }
    }
    if (authMethods.dev_token && singleUserBearerToken === null) {
      let devToken: string | null = null
      try {
        const devRes = await fetchWithBootstrapTimeout(
          fetchImpl,
          '/api/v1/dashboard/dev-token',
          {
            method: 'GET',
            credentials: 'same-origin',
            headers: { Accept: 'application/json' },
          },
          timeoutMs,
        )
        if (devRes.ok) {
          const payload = (await devRes.json()) as { token?: unknown } | null
          const parsedDev = typeof payload?.token === 'string' ? normalizeBearerToken(payload.token) : null
          devToken = parsedDev?.ok ? parsedDev.token : null
        }
      } catch { /* dev token optional */ }
      if (!ownsCredential()) return authSession.peek()
      if (devToken !== null) {
        persistBearer(devToken, { source: 'dev', actor: 'dashboard', role: 'admin' })
      }
    }

    if (!ownsCredential()) return authSession.peek()
    let resolvedRole: SingleUserRole = 'worker'
    let resolvedCanTokenAdmin = false
    let resolvedCanTokenRead = false
    if (opts.probeShell !== false) {
      const headers: Record<string, string> = { Accept: 'application/json' }
      if (singleUserBearerToken) headers.Authorization = `Bearer ${singleUserBearerToken}`
      const shellRes = await fetchWithBootstrapTimeout(
        fetchImpl,
        '/api/v1/dashboard/shell',
        {
          method: 'GET',
          credentials: 'same-origin',
          headers,
        },
        timeoutMs,
      )
      if (!ownsCredential()) return authSession.peek()
      if (shellRes.status === 401 || shellRes.status === 403) {
        persistBearer(null)
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
      const shellBody = await shellRes.json().catch(() => null)
      if (!ownsCredential()) return authSession.peek()
      const parsedShellAuth = parseSingleUserShellAuth(shellBody)
      if (parsedShellAuth.kind === 'auth_required') {
        persistBearer(null)
        const next: AuthSession = {
          kind: 'single_user_auth_required',
          mode: 'single_user',
          authMethods,
          reason: parsedShellAuth.reason,
        }
        authSession.value = next
        return next
      }
      if (parsedShellAuth.kind === 'malformed') {
        const next: AuthSession = {
          kind: 'unavailable',
          reason: parsedShellAuth.reason,
        }
        authSession.value = next
        return next
      }
      resolvedRole = parsedShellAuth.role
      resolvedCanTokenAdmin = parsedShellAuth.canTokenAdmin
      resolvedCanTokenRead = parsedShellAuth.canTokenRead
      if (fetchImpl === globalThis.fetch && shellBody !== null) {
        bootstrapShellHandoff = {
          epoch,
          token: singleUserBearerToken,
          workspaceId: activeWorkspaceId.peek(),
          payload: shellBody,
          etag: shellRes.headers.get('etag'),
          capturedAt: Date.now(),
        }
      }
    }

    const next: AuthSession = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: singleUserBearerToken !== null,
      role: resolvedRole,
      canTokenAdmin: resolvedCanTokenAdmin,
      canTokenRead: resolvedCanTokenRead,
      authMethods,
      workspaceId: activeWorkspaceId.peek(),
    }
    authSession.value = next
    return next
  } catch (error) {
    if (!ownsCredential()) return authSession.peek()
    const next: AuthSession = {
      kind: 'unavailable',
      reason: error instanceof Error ? error.message : String(error),
    }
    authSession.value = next
    return next
  }
}

function applyMultiAccountTransition(
  cur: Extract<AuthSession, { readonly kind: 'multi_account_signed_in' }>,
  next: AuthSession,
): void {
  if (next.kind === 'account_changed' || next.kind === 'multi_account_signed_out') {
    activeCsrfToken = null
    batch(() => {
      bumpSessionEpoch()
      authSession.value = next
    })
    return
  }
  if (next.kind === 'multi_account_signed_in') {
    const roleChanged = cur.role !== next.role
    batch(() => {
      if (roleChanged) {
        bumpSessionEpoch()
      }
      authSession.value = next
    })
  }
}

/**
 * Re-reads `/auth/session` and `/api/v1/auth/whoami` to refresh an expired CSRF token
 * or detect role/account changes in `multi_account` mode.
 * Returns the fresh token or null if the account changed or session expired.
 */
export async function refreshMultiAccountCsrf(
  fetchImpl: typeof fetch = globalThis.fetch,
): Promise<string | null> {
  const cur = authSession.peek()
  if (cur.kind !== 'multi_account_signed_in') return null
  const startEpoch = currentSessionEpoch()
  const prevWs = activeWorkspaceId.peek()
  const next = await readMultiAccountSession(
    fetchImpl,
    cur.authMethods,
    cur.accountId,
    DEFAULT_BOOTSTRAP_TIMEOUT_MS,
    () => isEpochCurrent(startEpoch),
  ).catch(() => null)
  if (next === null) return null
  const workspaceBumpedBySelf = activeWorkspaceId.peek() !== prevWs
  if (!isEpochCurrent(startEpoch) && !workspaceBumpedBySelf) return null
  if (next.kind === 'unavailable') {
    authSession.value = next
    return null
  }
  applyMultiAccountTransition(cur, next)
  return next.kind === 'multi_account_signed_in' ? next.csrfToken : null
}

/**
 * Triggers a throttled background `GET /api/v1/auth/whoami` recheck after a non-CSRF
 * HTTP 403 in `multi_account_signed_in` mode so freshly demoted admins transition
 * promptly and bump `sessionEpoch` (aborting in-flight admin reads and clearing cache)
 * without touching `/auth/session` (no CSRF refresh on ordinary RBAC 403).
 */
export function scheduleForbiddenRoleRecheck(
  fetchImpl: typeof fetch = globalThis.fetch,
): void {
  const cur = authSession.peek()
  if (cur.kind !== 'multi_account_signed_in') return
  const now = Date.now()
  if (forbiddenRecheckInFlight !== null || now - lastForbiddenRecheckAt < FORBIDDEN_RECHECK_COOLDOWN_MS) {
    return
  }
  lastForbiddenRecheckAt = now
  const startEpoch = currentSessionEpoch()
  forbiddenRecheckInFlight = fetchWithBootstrapTimeout(
    fetchImpl,
    '/api/v1/auth/whoami',
    {
      method: 'GET',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    },
    DEFAULT_BOOTSTRAP_TIMEOUT_MS,
  ).then(async (whoRes) => {
    if (!isEpochCurrent(startEpoch)) return
    if (whoRes.status === 401) {
      activeCsrfToken = null
      writeAccountMarker(null)
      batch(() => {
        bumpSessionEpoch()
        authSession.value = {
          kind: 'multi_account_signed_out',
          mode: 'multi_account',
          authMethods: cur.authMethods,
        }
      })
      return
    }
    if (!whoRes.ok) return
    const whoBody = (await whoRes.json().catch(() => null)) as AuthWhoamiWirePayload | null
    if (!isEpochCurrent(startEpoch) || whoBody === null) return
    const principalKind = whoBody.principal?.kind
    const principalId = nonEmptyString(whoBody.principal?.id)
    if (principalKind !== 'human' || principalId === null) return
    if (principalId !== cur.accountId) {
      activeCsrfToken = null
      writeAccountMarker(principalId)
      batch(() => {
        bumpSessionEpoch()
        authSession.value = {
          kind: 'account_changed',
          mode: 'multi_account',
          previousAccountId: cur.accountId,
          nextAccountId: principalId,
          authMethods: cur.authMethods,
        }
      })
      return
    }
    const nextRole = parseRole(whoBody.role)
    if (nextRole !== cur.role) {
      batch(() => {
        bumpSessionEpoch()
        authSession.value = { ...cur, role: nextRole }
      })
    }
  }).catch(() => {
    // Transient network error while probing role; keep current session state.
  }).finally(() => {
    forbiddenRecheckInFlight = null
  })
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
      batch(() => {
        bumpSessionEpoch()
        authSession.value = {
          kind: 'account_changed',
          mode: 'multi_account',
          previousAccountId: cur.accountId,
          nextAccountId,
          authMethods: cur.authMethods,
        }
      })
    }
  }

  const onVisibilityChange = () => {
    if (document.visibilityState !== 'visible') return
    const cur = authSession.peek()
    if (cur.kind !== 'multi_account_signed_in') return
    const startEpoch = currentSessionEpoch()
    const prevWs = activeWorkspaceId.peek()
    void readMultiAccountSession(
      fetchImpl,
      cur.authMethods,
      cur.accountId,
      DEFAULT_BOOTSTRAP_TIMEOUT_MS,
      () => isEpochCurrent(startEpoch),
    ).then((next) => {
      const workspaceBumpedBySelf = activeWorkspaceId.peek() !== prevWs
      if (!isEpochCurrent(startEpoch) && !workspaceBumpedBySelf) return
      applyMultiAccountTransition(cur, next)
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
  clearBootstrapHandoffs()
  wipeTransientSecrets()
  writeSessionBearerToken(null)
  lastForbiddenRecheckAt = 0
  forbiddenRecheckInFlight = null
  batch(() => {
    authSession.value = { kind: 'probing' }
    sessionEpoch.value = 1
    activeWorkspaceId.value = 'default'
    workspaceTargets.value = Object.freeze([{ id: 'default', label: 'Default Workspace' }])
  })
  writeAccountMarker(null)
}
